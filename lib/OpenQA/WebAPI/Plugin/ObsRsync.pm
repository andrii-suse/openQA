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

package OpenQA::WebAPI::Plugin::ObsRsync;
use Mojo::Base 'Mojolicious::Plugin';
use Mojo::File;

sub register {
    my ($self, $app, $config) = @_;
    my $admin_r = $config->{route} // $app->routes->any('/admin/plugin');

    # Templates
    push @{$app->renderer->paths}, Mojo::File->new(__FILE__)->dirname->child('ObsRsync')->child('templates')->to_string;

    $admin_r->get('/obs_rsync/#folder/runs/#subfolder/download/#filename')->name('plugin_obs_rsync_download_file')
      ->to('Plugin::ObsRsync::Controller#download_file');
    $admin_r->get('/obs_rsync/#folder/runs/#subfolder')->name('plugin_obs_rsync_logfiles')
      ->to('Plugin::ObsRsync::Controller#logfiles');
    $admin_r->get('/obs_rsync/#folder/runs')->name('plugin_obs_rsync_logs')->to('Plugin::ObsRsync::Controller#logs');
    $admin_r->get('/obs_rsync/#folder')->name('plugin_obs_rsync_folder')->to('Plugin::ObsRsync::Controller#folder');
    $admin_r->get('/obs_rsync/')->name('plugin_obs_rsync_index')->to('Plugin::ObsRsync::Controller#index');

    $admin_r->put('/obs_rsync/#folder/runs')->name('plugin_obs_rsync_run')->to('Plugin::ObsRsync::Controller#run');
}

1;
