# Copyright (C) 2017-2018 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

package OpenQA::Worker::Cache;

use strict;
use warnings;

use Carp 'croak';
use File::Basename;
use Fcntl ':flock';
use Mojo::UserAgent;
use OpenQA::Utils
  qw(log_error log_info log_debug get_channel_handle add_log_channel append_channel_to_defaults remove_channel_from_defaults);
use OpenQA::Worker::Settings;
use Mojo::SQLite;
use Mojo::File 'path';
use Mojo::Base -base;
use Exporter 'import';
use POSIX;

use constant STATUS_PROCESSED   => 1;
use constant STATUS_ENQUEUED    => 2;
use constant STATUS_DOWNLOADING => 3;
use constant STATUS_IGNORE      => 4;
use constant STATUS_ERROR       => 5;

our @EXPORT_OK = qw(STATUS_PROCESSED STATUS_ENQUEUED STATUS_DOWNLOADING STATUS_IGNORE STATUS_ERROR);

has [qw(host cache location db_file dsn cache_real_size)];
has limit      => 50 * (1024**3);
has sleep_time => 5;
has sqlite     => sub { Mojo::SQLite->new(shift->dsn) };

sub new {
    shift->SUPER::new(@_)->init;
}

sub from_worker {
    my $global_settings = OpenQA::Worker::Settings->new->global_settings;
    __PACKAGE__->new(
        host     => 'localhost',
        location => ($ENV{OPENQA_CACHE_DIR} || $global_settings->{CACHEDIRECTORY}),
        exists $global_settings->{CACHELIMIT} ? (limit => int($global_settings->{CACHELIMIT}) * (1024**3)) : ());
}

sub DESTROY {
    my $self = shift;

    $self->sqlite->db->disconnect() if $self->sqlite;
}

sub deploy_cache {
    my $self = shift;

    log_info "Creating cache directory tree for " . $self->location;
    path($self->location)->remove_tree({keep_root => 1});
    path($self->location)->make_path;
    path($self->location, 'tmp')->make_path;
}

sub init {
    my $self = shift;
    my ($host, $location) = ($self->host, $self->location);

    my $db_file = path($location, 'cache.sqlite');
    $self->db_file($db_file);
    log_info(__PACKAGE__ . ': loading database from ' . $db_file);
    $self->dsn("sqlite:$db_file");
    $self->deploy_cache unless -e $db_file;
    eval { $self->sqlite->migrations->name('cache_service')->from_data->migrate };
    croak qq{Deploying SQLite "$db_file" failed (Maybe the file is corrupted and needs to be deleted?): $@} if $@;

    $self->cache_real_size(0);
    $self->cache_sync();

    # Ideally we only need $limit, and $need no extra space
    $self->check_limits(0);
    log_info(__PACKAGE__ . ": Initialized with $host at $location, current size is " . $self->cache_real_size);
    return $self;
}

sub download_asset {
    my $self = shift;
    my ($id, $type, $asset, $etag) = @_;

    if (get_channel_handle('autoinst')) {
        append_channel_to_defaults('autoinst');
    }
    else {
        add_log_channel('autoinst', path => 'autoinst-log.txt', level => 'debug', default => 'append');
    }

    my $ua = Mojo::UserAgent->new(max_redirects => 2);
    $ua->max_response_size(0);
    my $url = sprintf '%s/tests/%d/asset/%s/%s', $self->host, $id, $type, basename($asset);
    log_info("Downloading " . basename($asset) . " from $url");
    my $tx = $ua->build_tx(GET => $url);
    my $headers;

    $ua->on(
        start => sub {
            my ($ua, $tx) = @_;
            my $progress     = 0;
            my $last_updated = time;
            if (-e $asset) {    # Assets might be deleted by a sysadmin
                $tx->req->headers->header('If-None-Match' => qq{$etag}) if $etag;
            }
            $tx->res->on(
                progress => sub {
                    my $msg = shift;
                    $msg->finish if $msg->code == 304;
                    return unless my $len = $msg->headers->content_length;

                    my $size = $msg->content->progress;
                    $headers = $msg->headers if !$headers;
                    my $current = int($size / ($len / 100));
                    # Don't spam the webui, update only every 5 seconds
                    if (time - $last_updated > 5) {
                        $last_updated = time;
                        if ($progress < $current) {
                            $progress = $current;
                            log_debug("CACHE: Downloading $asset: " . ($size == $len ? 100 : $progress) . "%");
                        }
                    }
                });
        });

    $tx = $ua->start($tx);
    my $code = ($tx->res->code) ? $tx->res->code : 521;    # Used by cloudflare to indicate web server is down.
    my $size;
    if ($code eq 304) {
        if ($self->_update_asset_last_use($asset)) {
            log_debug("CACHE: Content has not changed, not downloading the $asset but updating last use");
        }
        else {
            log_debug("CACHE: Abnormal situation, code 304. Retrying download");
            $asset = 520;
        }
    }
    elsif ($tx->res->is_server_error) {
        log_debug("CACHE: Could not download the asset, triggering a retry for $code.");
        log_debug("CACHE: Abnormal situation, server error. Retrying download");
        $asset = $code;
    }
    elsif ($tx->res->is_success) {
        $etag = $headers->etag;
        unlink($asset);
        $self->cache_sync;
        my $size = $tx->res->content->asset->move_to($asset)->size;
        if ($size == $headers->content_length) {
            $self->check_limits($size);
            my $att = 0;
            my $ok;
            # This needs to go in to the database at any cost - we have the lock and we succeeded in download
            # We can't just throw it away if database locks.
            ++$att and sleep 1 and log_debug("CACHE: Error updating Cache: attempting again: $att")
              until ($ok = $self->update_asset($asset, $etag, $size)) || $att > 5;
            log_error("CACHE: FAIL Could not update DB - purging asset")
              and $self->purge_asset($asset)
              and $asset = undef
              unless $ok;
            log_debug("CACHE: Asset download successful to $asset, Cache size is: " . $self->cache_real_size) if $ok;
        }
        else {
            log_debug(
                "CACHE: Size of $asset differs, Expected: " . $headers->content_length . " / Downloaded: " . "$size");
            $asset = 598;    # 598 (Informal convention) Network read timeout error
        }
    }
    else {
        my $message = $tx->res->error->{message};
        log_debug("CACHE: Download of $asset failed with: $code - $message");
        $self->purge_asset($asset);
        $asset = undef;
    }
    remove_channel_from_defaults('autoinst');
    return $asset;
}

sub _base_host { Mojo::URL->new($_[0])->host || shift }
sub _host      { _base_host(shift->host) }

sub get_asset {
    my $self = shift;
    my ($job, $asset_type, $asset) = @_;
    my $type;
    my $result;
    my $ret;

    my $location = path($self->location, $self->_host);
    $location->make_path unless -d $location;
    $asset = $location->child(path($asset)->basename);

    my $n = 5;
    while () {
        $self->track_asset($asset);    # Track asset - make sure it's in DB
        $result = $self->_asset($asset);
        local $@;
        eval {
            $ret
              = $self->download_asset($job->{id}, lc($asset_type), $asset, ($result->{etag}) ? $result->{etag} : undef);
        };
        if (!$ret) {
            $asset = undef;
            last;
        }
        elsif ($ret =~ /^5[0-9]{2}$/ && --$n) {
            log_debug "CACHE: Error $ret, retrying download for $n more tries";
            log_debug "CACHE: Waiting " . $self->sleep_time . " seconds for the next retry";

            sleep $self->sleep_time;
            next;
        }
        elsif (!$n) {
            log_debug "CACHE: Too many download errors, aborting";
            $asset = undef;
            last;
        }
        last;
    }
    return $asset;
}

sub _asset {
    my ($self, $asset) = @_;
    my $result = $self->sqlite->db->select('assets', [qw(etag size last_use)], {filename => $asset})->hashes;

    return {} if $result->size == 0 || $@;
    return $result->first;
}

sub track_asset {
    my ($self, $asset) = @_;

    my $res;
    my $sql = "INSERT OR IGNORE INTO assets (filename, size, last_use) VALUES (?, 0,  strftime('%s','now'));";

    eval {
        my $db = $self->sqlite->db;
        my $tx = $db->begin('exclusive');
        $res = $db->query($sql, $asset)->arrays;
        $tx->commit;
    };
    if ($@) {
        log_error "track_asset: Failed: $@";
    }

    return !!0 if $res->size == 0 || $@;
    return !!1 if $res->size > 0;
}

sub _update_asset_last_use {
    my ($self, $asset) = @_;

    eval {
        my $db  = $self->sqlite->db;
        my $tx  = $db->begin('exclusive');
        my $sql = q(UPDATE assets set last_use = strftime('%s','now') where filename = ?;);
        $db->query($sql, $asset);
        $tx->commit;
    };

    if ($@) {
        log_error "Update asset failed: $@";
        return !!0;
    }

    log_info "CACHE: updating the $asset last usage";
    return !!1;
}

sub update_asset {
    my ($self, $asset, $etag, $size) = @_;
    eval {
        my $db  = $self->sqlite->db;
        my $tx  = $db->begin('exclusive');
        my $sql = q(UPDATE assets set etag =? , size = ?, last_use = strftime('%s','now') where filename = ?;);
        $db->query($sql, $etag, $size, $asset);
        $tx->commit;
    };
    if ($@) {
        log_error "Update asset $asset failed. Rolling back $@";
        return !!0;
    }
    else {
        log_info "CACHE: updating the $asset with $etag and $size";
    }

    $self->increase($size);
    return !!1;
}

sub purge_asset {
    my ($self, $asset) = @_;
    eval {
        my $db = $self->sqlite->db;
        my $tx = $db->begin();
        $db->delete('assets', {filename => $asset});
        $tx->commit;
        if (-e $asset) {
            unlink($asset) or eval { log_error "CACHE: Could not remove $asset" if -e $asset };
            log_debug "CACHE: removed $asset";
        }
        else {
            log_debug "CACHE: requested to remove nonexisting asset $asset";
        }
    };

    if ($@) {
        log_error "purge_asset: $@";
        return !!0;
    }
    return !!1;
}

sub file_size { (stat(pop))[7] }

sub cache_sync {
    my $self     = shift;
    my $location = $self->location;
    my $ext;
    $ext .= "-o -name '*.$_' " for qw(qcow2 iso vhd vhdx);
    my @assets = `find $location -maxdepth 2 -type f -name '*.img' $ext`;
    chomp @assets;
    $self->cache_real_size(0);
    foreach my $file (@assets) {
        my $asset_size = $self->file_size($file);
        next if !defined $asset_size;
        $self->increase($asset_size) if $self->asset_lookup($file);
    }
}

sub asset_lookup {
    my ($self, $asset) = @_;
    my $sth;
    my $result;
    eval {
        my $db = $self->sqlite->db;
        my $tx = $db->begin('exclusive');
        $result = $db->select('assets', [qw(filename etag last_use size)], {filename => $asset});
        $tx->commit;
    };
    if ($@) {
        return !!0;
    }

    if ($result->arrays->size == 0) {
        log_info "CACHE: Purging non registered $asset";
        $self->purge_asset($asset);
        return !!0;
    }

    return !!1;
}

sub exceeds_limit { !!($_[0]->cache_real_size + $_[1] > $_[0]->limit) }
sub limit_reached { !!($_[0]->cache_real_size > shift->limit) }
sub decrease {
    my ($self, $size) = @_;
    log_debug "Current cache size: " . $self->cache_real_size;
    $self->cache_real_size(
        !defined $size ? $self->cache_real_size : $size > $self->cache_real_size ? 0 : $self->cache_real_size - $size);
    log_debug "Reclaiming " . $size . " from " . $self->cache_real_size . " to make space for " . $self->limit;
}

sub increase { $_[0]->cache_real_size($_[0]->cache_real_size + pop) }

sub check_limits {
    my ($self, $needed) = @_;
    my $db = $self->sqlite->db;
    eval {
        my $sth = $db->select('assets', [qw(filename size last_use)], undef, {-asc => 'last_use'});
        while (my $asset = $sth->hash) {
            my $asset_size = $asset->{size} || $self->file_size($asset->{filename});
            $self->decrease($asset_size)
              if $self->exceeds_limit($needed) && $self->purge_asset($asset->{filename}) && defined $asset_size;
        }
    } if $self->exceeds_limit($needed) || $self->limit_reached;
    log_error "CACHE: check_limit failed: $@" if $@;
    log_debug "CACHE: Health: Real size: " . $self->cache_real_size . ", Configured limit: " . $self->limit;
}

1;

__DATA__
@@ cache_service
-- 1 up
CREATE TABLE IF NOT EXISTS assets (
    `etag` TEXT,
    `size` INTEGER,
    `last_use` DATETIME NOT NULL,
    `filename` TEXT NOT NULL UNIQUE,
    PRIMARY KEY(`filename`)
);

-- 1 down
DROP TABLE assets;
