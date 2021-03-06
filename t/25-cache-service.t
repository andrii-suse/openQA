#! /usr/bin/perl

# Copyright (c) 2018-2019 SUSE LLC
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

use strict;
use warnings;

my $tempdir;
BEGIN {
    unshift @INC, 't/lib';
    use Mojo::File qw(path tempdir);
    use FindBin;

    $tempdir = tempdir;
    my $basedir = $tempdir->child('t', 'cache.d');
    $ENV{OPENQA_CACHE_DIR} = path($basedir, 'cache');
    $ENV{OPENQA_BASEDIR}   = $basedir;
    $ENV{OPENQA_CONFIG}    = path($basedir, 'config')->make_path;
    path($ENV{OPENQA_CONFIG})->child("workers.ini")->spurt('
[global]
CACHEDIRECTORY = ' . $ENV{OPENQA_CACHE_DIR} . '
CACHEWORKERS = 10
CACHELIMIT = 100');
}

# Avoid warning error: Name "Config::IniFiles::t/cache.d/cache/config/workers.ini" used only once
use OpenQA::Worker::Cache;
OpenQA::Worker::Cache->from_worker;

use Test::More;
use Test::Warnings;
use OpenQA::Utils;
use File::Spec::Functions qw(catdir catfile);
use Cwd qw(abs_path getcwd);
use Mojolicious;
use IO::Socket::INET;
use Mojo::Server::Daemon;
use Mojo::IOLoop::Server;
use POSIX '_exit';
use Mojo::IOLoop::ReadWriteProcess qw(queue process);
use Mojo::IOLoop::ReadWriteProcess::Session 'session';
use OpenQA::Test::Utils qw(fake_asset_server cache_minion_worker cache_worker_service);
use OpenQA::Test::FakeWebSocketTransaction;
use Mojo::Util qw(md5_sum);
use OpenQA::Worker::Cache::Request;
use Test::MockModule;

my $sql;
my $sth;
my $result;
my $dbh;
my $filename;
my $serverpid;
my $openqalogs;
my $cachedir = $ENV{OPENQA_CACHE_DIR};

my $db_file = "$cachedir/cache.sqlite";
my $logdir  = path(getcwd(), 't', 'cache.d', 'logs')->make_path;
my $logfile = $logdir->child('cache.log');
my $port    = Mojo::IOLoop::Server->generate_port;
my $host    = "http://localhost:$port";

use OpenQA::Worker::Cache::Client;

my $cache_client = OpenQA::Worker::Cache::Client->new();

sub _port { IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => shift) }

END { session->clean }

my $daemon;
my $cache_service        = cache_worker_service;
my $worker_cache_service = cache_minion_worker;

my $server_instance = process sub {
    # Connect application with web server and start accepting connections
    $daemon = Mojo::Server::Daemon->new(app => fake_asset_server, listen => [$host])->silent(1);
    $daemon->run;
    _exit(0);
};

sub start_server {
    $server_instance->set_pipes(0)->separate_err(0)->blocking_stop(1)->channels(0)->restart;
    $cache_service->set_pipes(0)->separate_err(0)->blocking_stop(1)->channels(0)->restart->restart;
    $worker_cache_service->restart;
    sleep 2 and diag "Wait server to be reachable." until $cache_client->available;
    return;
}

sub test_default_usage {
    my ($id, $a) = @_;
    my $asset_request = $cache_client->request->asset(id => $id, asset => $a, type => 'hdd', host => $host);

    if ($asset_request->enqueue) {
        sleep .5 until $asset_request->processed;
    }
    ok($cache_client->asset_exists('localhost', $a), "Asset $a downloaded");
    ok($asset_request->minion_id, "Minion job id recorded in the request object") or die diag explain $asset_request;
}

sub test_sync {
    my $dir           = tempdir;
    my $dir2          = tempdir;
    my $rsync_request = $cache_client->request->rsync(from => $dir, to => $dir2);

    my $t_dir = int(rand(13432432));
    my $data  = int(rand(348394280934820842093));
    $dir->child($t_dir)->spurt($data);
    my $expected = $dir2->child('tests')->child($t_dir);

    ok $rsync_request->enqueue;

    sleep .5 until $rsync_request->processed;

    is $rsync_request->result, 0;
    ok $rsync_request->output;

    like $rsync_request->output, qr/100\%/ or die diag $rsync_request->output;

    ok -e $expected;
    is $expected->slurp, $data;
}

sub test_download {
    my ($id, $a) = @_;
    unlink path($cachedir)->child($a);
    my $asset_request = $cache_client->request->asset(id => $id, asset => $a, type => 'hdd', host => $host);

    my $resp = $asset_request->execute_task();
    is($resp, OpenQA::Worker::Cache::STATUS_ENQUEUED) or die diag explain $resp;

    my $state = $asset_request->status;
    $state = $asset_request->status until ($state ne OpenQA::Worker::Cache::STATUS_IGNORE);

    # After IGNORE, only DOWNLOAD status could follow, but it could be fast enough to not catch it
    $state = $asset_request->status;
    $state = $asset_request->status until ($state ne OpenQA::Worker::Cache::STATUS_DOWNLOADING);

    # And then goes to PROCESSED state
    is($state, OpenQA::Worker::Cache::STATUS_PROCESSED) or die diag explain $state;

    ok($cache_client->asset_exists('localhost', $a), 'Asset downloaded');
    ok($asset_request->minion_id, "Minion job id recorded in the request object") or die diag explain $asset_request;
}

subtest 'Availability check and worker status' => sub {
    my $client_mock = Test::MockModule->new('OpenQA::Worker::Cache::Client');

    is($cache_client->availability_error, 'Cache service not reachable.', 'cache service not available');

    $client_mock->mock(available         => sub { return 1; });
    $client_mock->mock(available_workers => sub { return 0; });
    is($cache_client->availability_error, 'No workers active in the cache service.', 'nor workers active');

    $client_mock->mock(available_workers => sub { return 1; });
    is($cache_client->availability_error, undef, 'no error');

    $client_mock->unmock_all();
};

subtest 'Configurable minion workers' => sub {
    require OpenQA::Worker::Cache::Service;

    is_deeply([OpenQA::Worker::Cache::Service::_setup_workers(qw(minion test))],   [qw(minion test)]);
    is_deeply([OpenQA::Worker::Cache::Service::_setup_workers(qw(minion worker))], [qw(minion worker -j 10)]);
    is_deeply([OpenQA::Worker::Cache::Service::_setup_workers(qw(minion daemon))], [qw(minion daemon)]);

    path($ENV{OPENQA_CONFIG})->child("workers.ini")->spurt("
[global]
CACHEDIRECTORY = $cachedir
CACHELIMIT = 100");

    is_deeply([OpenQA::Worker::Cache::Service::_setup_workers(qw(minion worker))], [qw(minion worker -j 5)]);
};

subtest 'Cache Requests' => sub {
    my $asset_request = $cache_client->request->asset(id => 922756, asset => 'test', type => 'hdd', host => 'open.qa');
    my $rsync_request = $cache_client->request->rsync(from => 'foo', to => 'bar');

    is $rsync_request->lock, join('.', 'foo',  'bar');
    is $asset_request->lock, join('.', 'test', 'open.qa');

    my $req = $cache_client->request;
    is $cache_client, $req->client;
    my $asset_req = $req->asset();
    is $cache_client, $asset_req->client;

    is_deeply $rsync_request->to_hash, {from => 'foo', to => 'bar'};
    is_deeply $asset_request->to_hash, {id => 922756, asset => 'test', type => 'hdd', host => 'open.qa'};

    is_deeply $rsync_request->to_array, [qw(foo bar)];
    is_deeply $asset_request->to_array, [qw(922756 hdd test open.qa)];

    my $base = $cache_client->request;
    local $@;
    eval { $base->lock };
    like $@, qr/lock\(\) not implemented in OpenQA::Worker::Cache::Request/, 'lock() not implemented in base request';
    eval { $base->to_hash };
    like $@, qr/to_hash\(\) not implemented in OpenQA::Worker::Cache::Request/,
      'to_hash() not implemented in base request';
    eval { $base->to_array };
    like $@, qr/to_array\(\) not implemented in OpenQA::Worker::Cache::Request/,
      'to_array() not implemented in base request';
};

start_server;

subtest 'Invalid requests' => sub {
    my $url             = $cache_client->_url('/status');
    my $invalid_request = $cache_client->ua->post($url => json => {lock => "some lock"});
    my $json            = $invalid_request->result->json;
    is_deeply($json, {status => 1}, 'no job ID accepted') or diag explain $json;

    $url             = $cache_client->_url('/status');
    $invalid_request = $cache_client->ua->post($url => json => {id => "foo", lock => "some lock"});
    $json            = $invalid_request->result->json;
    is_deeply($json, {error => 'Specified job ID is invalid.'}, 'invalid job ID') or diag explain $json;

    $url             = $cache_client->_url('/status');
    $invalid_request = $cache_client->ua->post($url => json => {});
    $json            = $invalid_request->result->json;
    is_deeply($json, {error => 'No lock specified.'}, 'no lock') or diag explain $json;
};

subtest 'Asset exists' => sub {

    ok(!$cache_client->asset_exists('localhost', 'foobar'), 'Asset absent');
    path($cachedir, 'localhost')->make_path->child('foobar')->spurt('test');

    ok($cache_client->asset_exists('localhost', 'foobar'), 'Asset exists');
    unlink path($cachedir, 'localhost')->child('foobar')->to_string;
    ok(!$cache_client->asset_exists('localhost', 'foobar'), 'Asset absent')
      or die diag explain path($cachedir, 'localhost')->list_tree;

};

subtest 'different token between restarts' => sub {
    my $token = $cache_client->session_token;
    ok(defined $token);
    ok($token ne "");
    diag "Session token: $token";

    start_server;
    isnt($cache_client->session_token, $token) or die diag $cache_client->session_token;

    $token = $cache_client->session_token;
    ok(defined $token);
    ok($token ne "");
};

subtest 'enqueued' => sub {
    require OpenQA::Worker::Cache::Service;

    OpenQA::Worker::Cache::Service::enqueue('bar');
    ok !OpenQA::Worker::Cache::Service::enqueued('foo'), "Queue works" or die;
    OpenQA::Worker::Cache::Service::enqueue('foo');
    ok OpenQA::Worker::Cache::Service::enqueued('foo'), "Queue works";
    OpenQA::Worker::Cache::Service::dequeue('foo');
    ok !OpenQA::Worker::Cache::Service::enqueued('foo'), "Dequeue works";
};

subtest '_gen_guard_name' => sub {
    require OpenQA::Worker::Cache::Service;

    ok !OpenQA::Worker::Cache::Service::SESSION_TOKEN(), "Session token is not there" or die;
    OpenQA::Worker::Cache::Service::_gen_session_token();
    ok OpenQA::Worker::Cache::Service::SESSION_TOKEN(), "Session token is there" or die;
    is OpenQA::Worker::Cache::Service::_gen_guard_name('foo'),
      OpenQA::Worker::Cache::Service::SESSION_TOKEN() . '.foo', "Session token is there"
      or die;
};

subtest '_exists' => sub {
    require OpenQA::Worker::Cache::Service;

    ok !OpenQA::Worker::Cache::Service::_exists();
    ok !OpenQA::Worker::Cache::Service::_exists({total => 0});
    ok OpenQA::Worker::Cache::Service::_exists({total => 1});
    ok OpenQA::Worker::Cache::Service::_exists({total => 100});
};

subtest 'Client can check if there are available workers' => sub {
    $cache_client->session_token;
    $worker_cache_service->stop;
    $cache_service->stop;
    ok !$cache_client->available, 'Cache server is not available';
    $cache_service->restart;
    sleep .5 until $cache_client->available;
    ok $cache_client->available, 'Cache server is available';
    ok !$cache_client->available_workers, 'No available workers at the moment';
    $worker_cache_service->start;
    sleep 5 and diag "waiting for minion worker to be available" until $cache_client->available_workers;
    ok $cache_client->available_workers, 'Workers are available now';
};

subtest 'Asset download' => sub {
    test_download(922756, 'sle-12-SP3-x86_64-0368-200_2900@64bit.qcow2');
    test_download(922756, 'sle-12-SP3-x86_64-0368-200_2700@64bit.qcow2');
    test_download(922756, 'sle-12-SP3-x86_64-0368-200_5500@64bit.qcow2');
    test_download(922756, 'sle-12-SP3-x86_64-0368-200_12200@64bit.qcow2');
    test_download(922756, 'sle-12-SP3-x86_64-0368-200_15200@64bit.qcow2');
    test_download(922756, 'sle-12-SP3-x86_64-0368-200_123200@64bit.qcow2');
};

subtest 'Race for same asset' => sub {

    my $a = 'sle-12-SP3-x86_64-0368-200_123200@64bit.qcow2';

    my $asset_request = $cache_client->request->asset(id => 922756, asset => $a, type => 'hdd', host => $host);

    my $sum = md5_sum(path($cachedir, 'localhost')->child($a)->slurp);
    unlink path($cachedir, 'localhost')->child($a)->to_string;
    ok(!$cache_client->asset_exists('localhost', $a), 'Asset absent') or die diag "Asset already exists - abort test";

    my $tot_proc   = $ENV{STRESS_TEST} ? 100 : 10;
    my $concurrent = $ENV{STRESS_TEST} ? 30  : 2;
    my $q          = queue;
    $q->pool->maximum_processes($concurrent);
    $q->queue->maximum_processes($tot_proc);

    my $concurrent_test = sub {
        if ($cache_client->enqueue($asset_request)) {
            sleep .5 until $cache_client->processed($asset_request);
            Devel::Cover::report() if Devel::Cover->can('report');

            return 1 if $cache_client->asset_exists('localhost', $a);
            return 0;
        }
    };

    $q->add(process($concurrent_test)->set_pipes(0)->internal_pipes(1)) for 1 .. $tot_proc;

    $q->consume();
    is $q->done->size, $tot_proc, 'Queue consumed ' . $tot_proc . ' processes';
    $q->done->each(
        sub {
            is $_->return_status, 1, "Asset exists after worker got released from cache service" or die diag explain $_;
        });

    ok($cache_client->asset_exists('localhost', $a), 'Asset downloaded') or die diag "Failed - no asset is there";
    is($sum, md5_sum(path($cachedir, 'localhost')->child($a)->slurp), 'Download not corrupted');
};

subtest 'Default usage' => sub {
    my $a             = 'sle-12-SP3-x86_64-0368-200_1000@64bit.qcow2';
    my $asset_request = $cache_client->request->asset(id => 922756, asset => $a, type => 'hdd', host => $host);

    unlink path($cachedir)->child($a);
    ok(!$cache_client->asset_exists('localhost', $a), 'Asset absent') or die diag "Asset already exists - abort test";

    if ($asset_request->enqueue) {
        sleep .5 until $asset_request->processed;
        my $out = $asset_request->output();
        ok($out, 'Output should be present') or die diag $out;
        like $out, qr/Downloading $a from/, "Asset download attempt logged";
        ok(-e path($cachedir, 'localhost')->child($a), 'Asset downloaded') or die diag "Failed - no asset is there";
    }
    else {
        fail("Failed enqueuing download");
    }

    ok(-e path($cachedir, 'localhost')->child($a), 'Asset downloaded') or die diag "Failed - no asset is there";
};

subtest 'Small assets causes racing when releasing locks' => sub {
    my $a             = 'sle-12-SP3-x86_64-0368-200_1@64bit.qcow2';
    my $asset_request = $cache_client->request->asset(id => 922756, asset => $a, type => 'hdd', host => $host);

    unlink path($cachedir)->child($a);
    ok(!$cache_client->asset_exists('localhost', $a), 'Asset absent') or die diag "Asset already exists - abort test";

    if ($asset_request->enqueue) {
        1 until $asset_request->processed;
        my $out = $asset_request->output;
        ok($out, 'Output should be present') or die diag $out;
        like $out, qr/Downloading $a from/, "Asset download attempt logged";
        ok($cache_client->asset_exists('localhost', $a), 'Asset downloaded') or die diag "Failed - no asset is there";
    }
    else {
        fail("Failed enqueuing download");
    }

    ok($cache_client->asset_exists('localhost', $a), 'Asset downloaded') or die diag "Failed - no asset is there";
};

subtest 'Asset download with default usage' => sub {
    my $tot_proc = $ENV{STRESS_TEST} ? 100 : 10;
    test_default_usage(922756, "sle-12-SP3-x86_64-0368-200_$_\@64bit.qcow2") for 1 .. $tot_proc;
};

subtest 'Multiple minion workers (parallel downloads, almost simulating real scenarios)' => sub {
    my $tot_proc = $ENV{STRESS_TEST} ? 100 : 10;

    # We want 3 parallel downloads
    my $worker_2 = cache_minion_worker;
    my $worker_3 = cache_minion_worker;
    my $worker_4 = cache_minion_worker;

    $_->start for ($worker_2, $worker_3, $worker_4);

    my @assets = map { "sle-12-SP3-x86_64-0368-200_$_\@64bit.qcow2" } 1 .. $tot_proc;
    unlink path($cachedir)->child($_) for @assets;
    ok(
        $cache_client->enqueue(
            OpenQA::Worker::Cache::Request->new(client => $cache_client)
              ->asset(id => 922756, asset => $_, type => 'hdd', host => $host)
        ),
        "Download enqueued for $_"
    ) for @assets;

    sleep 1
      until (
        grep { $_ == 1 } map {
            $cache_client->processed(OpenQA::Worker::Cache::Request->new(client => $cache_client)
                  ->asset(id => 922756, asset => $_, type => 'hdd', host => $host))
        } @assets
      ) == @assets;

    ok($cache_client->asset_exists('localhost', $_), "Asset $_ downloaded correctly") for @assets;

    @assets = map { "sle-12-SP3-x86_64-0368-200_88888\@64bit.qcow2" } 1 .. $tot_proc;
    unlink path($cachedir)->child($_) for @assets;
    ok(
        $cache_client->enqueue(
            OpenQA::Worker::Cache::Request->new(client => $cache_client)
              ->asset(id => 922756, asset => $_, type => 'hdd', host => $host)
        ),
        "Download enqueued for $_"
    ) for @assets;

    sleep 1
      until (
        grep { $_ == 1 } map {
            $cache_client->processed(OpenQA::Worker::Cache::Request->new(client => $cache_client)
                  ->asset(id => 922756, asset => $_, type => 'hdd', host => $host))
        } @assets
      ) == @assets;

    ok($cache_client->asset_exists('localhost', "sle-12-SP3-x86_64-0368-200_88888\@64bit.qcow2"),
        "Asset $_ downloaded correctly")
      for @assets;

    $_->stop for ($worker_2, $worker_3, $worker_4);
};

subtest 'Test Minion task registration and execution' => sub {
    my $a = 'sle-12-SP3-x86_64-0368-200_133333@64bit.qcow2';

    use Minion;
    my $minion = Minion->new(SQLite => "sqlite:" . OpenQA::Worker::Cache->from_worker->db_file);
    use Mojolicious;
    my $app = Mojolicious->new;
    $app->attr(minion => sub { $minion });

    my $task = OpenQA::Worker::Cache::Task::Asset->new();
    $task->register($app);
    my $req = OpenQA::Worker::Cache::Request->new(client => $cache_client)
      ->asset(id => 922756, asset => $a, type => 'hdd', host => $host);
    $req->enqueue;
    my $worker = $app->minion->repair->worker->register;
    ok($worker->id, 'worker has an ID');
    my $job = $worker->dequeue(0);
    ok($job, 'job enqueued');
    $job->execute;
    ok $req->processed;
    ok $req->output;
    like $req->output, qr/Initialized with localhost/;
    ok $cache_client->asset_exists('localhost', $a);
};

subtest 'Test Minion Sync task' => sub {
    my $a = 'sle-12-SP3-x86_64-0368-200_133333@64bit.qcow2';

    use Minion;
    use OpenQA::Worker::Cache::Task::Sync;
    my $minion = Minion->new(SQLite => "sqlite:" . OpenQA::Worker::Cache->from_worker->db_file);
    use Mojolicious;
    my $app = Mojolicious->new;
    $app->helper(minion => sub { $minion });
    my $dir  = tempdir;
    my $dir2 = tempdir;

    $dir->child('test')->spurt('foobar');
    my $expected = $dir2->child('tests')->child('test');
    my $req      = $cache_client->request->rsync(from => $dir, to => $dir2);
    my $task     = OpenQA::Worker::Cache::Task::Sync->new();
    $task->register($app);
    ok $req->enqueue;
    my $worker = $app->minion->repair->worker->register;
    ok($worker->id, 'worker has an ID');
    my $job = $worker->dequeue(0);
    ok($job, 'job enqueued');
    $job->execute;
    ok $req->processed;
    is $req->result, 0;
    diag $req->output;

    ok -e $expected;
    is $expected->slurp, 'foobar';
};

subtest 'OpenQA::Worker::Cache::Task::Sync' => sub {
    my $worker_2 = cache_minion_worker;
    $worker_cache_service->stop;

    $worker_2->start;

    test_sync;
    test_sync;
    test_sync;
    test_sync;

    $worker_2->stop;
};

done_testing();

1;
