# Copyright (C) 2019 SUSE Linux GmbH
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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

package OpenQA::WebAPI::Controller::API::V1::ObsRsync;
use Mojo::Base 'Mojolicious::Controller';

sub _grep_and_stash_scalar {
    my ($self, $files, $mask, $var) = @_;
    my $r = "";
    my @r = grep(/$mask/, @$files);
    if (@r) {
        $r = $r[0];
    }
    $self->stash($var, $r);
}

sub _grep_and_stash_list {
    my ($self, $files, $mask, $var) = @_;
    my @r = grep(/$mask/, @$files);
    $self->stash($var, \@r);
}

sub _stash_files {
    my ($self, $files) = @_;
    $self->_grep_and_stash_list($files, 'files_.*\.lst', 'lst_files');
    $self->_grep_and_stash_scalar($files, 'read_files\.sh', 'read_files_sh');

    $self->_grep_and_stash_list($files, 'rsync_.*\.cmd',      'rsync_commands');
    $self->_grep_and_stash_list($files, 'print_rsync_.*\.sh', 'rsync_sh');

    $self->_grep_and_stash_scalar($files, 'openqa.cmd',       'openqa_commands');
    $self->_grep_and_stash_scalar($files, 'print_openqa\.sh', 'openqa_sh');
}

sub index {
    my ($self) = @_;
    return if (!$self->is_admin());

    my $schema      = $self->schema;
    my $group       = $schema->resultset("JobGroups")->find($self->param('groupid'));
    my $full        = $self->app->config->{obs_rsync_integration}->{home};
    my $obs_project = $self->app->config->{obs_rsync_integration}->{mapping}->{$group->id};
    $full = $full . '/' . $obs_project;
    my $last_run = $full . '/.run_last';
    my @files;
    if (-d $last_run) {
        opendir my $dirh, $last_run or die "Cannot open directory {$last_run}: $!";
        @files = sort readdir $dirh;
        closedir $dirh;
    }
    $self->_stash_files(\@files);
    $self->stash('group',       $group);
    $self->stash('obs_project', $obs_project);
    $self->render('obs_rsync/index');
}

sub logs {
    my ($self) = @_;
    return if (!$self->is_admin());
    my $folder = $self->param('folder');
    if (CORE::index($folder, '/') != -1 || !$folder) {
        return $self->render(json => {error => 'Incorrect name'}, status => 404);
    }

    my $full = $self->app->config->{obs_rsync_integration}->{home} . '/' . $folder;
    opendir my $dirh, $full or die "Cannot open directory {$full}: $!";
    my @files = sort { $b cmp $a } readdir $dirh;
    closedir $dirh;
    $self->_grep_and_stash_list(\@files, '.run_.*', 'subfolders');
    $self->stash('folder', $folder);
    $self->stash('full',   $full);
    $self->render('obs_rsync/logs');
}

sub logfiles {
    my ($self) = @_;
    return if (!$self->is_admin());
    my $folder = $self->param('folder');
    if (CORE::index($folder, '/') != -1 || !$folder) {
        return $self->render(json => {error => 'Incorrect name'}, status => 400);
    }
    my $subfolder = $self->param('subfolder');
    my $full      = $self->app->config->{obs_rsync_integration}->{home} . '/' . $folder . '/' . $subfolder;
    if (!-d $full && -s $full) {
        return $self->download_file();
    }
    if (CORE::index($subfolder, '/') != -1) {
        return $self->render(json => {error => 'Incorrect subfolder name'}, status => 400);
    }
    opendir my $dirh, "$full" or die "Cannot open directory {$full}: $!";
    my @files = sort { $b cmp $a } readdir $dirh;
    closedir $dirh;
    $self->_grep_and_stash_list(\@files, '[a-z]', 'files');
    $self->stash('folder',    $folder);
    $self->stash('full',      $full);
    $self->stash('subfolder', $subfolder);
    $self->render('obs_rsync/logfiles');
}

sub download_file {
    my ($self) = @_;
    return if (!$self->is_admin());
    my $folder = $self->param('folder');
    if (CORE::index($folder, '/') != -1 || !$folder) {
        return $self->render(json => {error => 'Incorrect name'}, status => 404);
    }
    my $subfolder = $self->param('subfolder');
    if (CORE::index($subfolder, '/') != -1) {
        return $self->render(json => {error => 'Incorrect subfolder name'}, status => 404);
    }
    my $filename = $self->param('filename');
    if ($filename && CORE::index($filename, '/') != -1) {
        return $self->render(json => {error => 'Incorrect file name'}, status => 404);
    }
    my $full = $self->app->config->{obs_rsync_integration}->{home} . '/' . $folder;
    # if $filename is empty and $subfolder is a regular file - swap them
    if (!-d $full . $subfolder && !$filename && -s $full . $subfolder) {
        $filename  = $subfolder;
        $subfolder = 0;
    }
    $full = $full . '/' . $subfolder if $subfolder;

    my $static = Mojolicious::Static->new;
    $static->paths([$full]);
    return $self->rendered if $static->serve($self, $filename);
}

1;
