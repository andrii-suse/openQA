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
use threads::shared;
use IPC::System::Simple qw(system $EXITVAL);

sub newRunner {
    my $counter : shared = 0;
    return \$counter;
}

sub _tryIncCounter {
    my ($pointer, $limit) = @_;
    lock $$pointer;
    if ($$pointer >= $limit) {
        return 0;
    }
    $$pointer = $$pointer + 1;
}

sub _decCounter {
    my $pointer = shift;
    lock $$pointer;
    $$pointer = $$pointer - 1;
}

my $lock_timeout = 3600;

sub Run {
    my ($pointer, $app, $home, $limit, $retry_timeout, $folder) = @_;
    my @args = ($home . "/rsync.sh", $folder);
    if (!_tryIncCounter($pointer, $limit)) {
        return 1 unless $retry_timeout;
        sleep $retry_timeout;
        return 1 unless _tryIncCounter($pointer, $limit);
    }
    async {
        eval { system([0], "bash", @args); 1 };
        _decCounter($pointer);
    }
    ->detach();
    return 0;
}

1;
