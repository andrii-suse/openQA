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

package OpenQA::WebAPI::Plugin::ObsRsync::Runner;
use strict;
use warnings;
use threads;
use IPC::System::Simple qw(system $EXITVAL);
use Parallel::ForkManager;

my $job_limit = 12;
my $pm        = Parallel::ForkManager->new($job_limit);

sub Run {
    my ($home, $folder) = @_;

    my @args = ($home . "/rsync.sh", $folder);
    $pm->reap_finished_children;
    my @pids         = $pm->running_procs;
    my $current_jobs = @pids;
    return $current_jobs if $current_jobs >= $job_limit;
    $pm->start and return 0;
    eval { system([0], "bash", @args); 1 };
    $pm->finish;
}

1;
