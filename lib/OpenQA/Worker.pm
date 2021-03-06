# Copyright (C) 2015-2019 SUSE LLC
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

package OpenQA::Worker;
use Mojo::Base -base;

use POSIX 'uname';
use Fcntl;
use File::Path qw(make_path remove_tree);
use File::Spec::Functions 'catdir';
use Mojo::IOLoop;
use Mojo::File 'path';
use Try::Tiny;
use Scalar::Util 'looks_like_number';
use OpenQA::Constants qw(WEBSOCKET_API_VERSION MAX_TIMER MIN_TIMER);
use OpenQA::Client;
use OpenQA::Utils qw(log_error log_info log_debug add_log_channel remove_log_channel);
use OpenQA::Worker::WebUIConnection;
use OpenQA::Worker::Settings;
use OpenQA::Worker::Job;
use OpenQA::Setup;

has 'instance_number';
has 'pool_directory';
has 'no_cleanup';
has 'app';
has 'settings';
has 'clients_by_webui_host';
has 'current_webui_host';
has 'current_job';
has 'current_error';
has 'worker_hostname';
has 'isotovideo_interface_version';

sub new {
    my ($class, $cli_options) = @_;

    # determine uname info
    my ($sysname, $hostname, $release, $version, $machine) = POSIX::uname();

    # determine instance number
    my $instance_number = $cli_options->{instance};
    die 'no instance number specified' unless defined $instance_number;
    die "the specified instance number \"$instance_number\" is no number" unless looks_like_number($instance_number);

    # determine settings and create app
    my $settings = OpenQA::Worker::Settings->new($instance_number, $cli_options);
    my $app      = OpenQA::Setup->new(
        mode     => 'production',
        log_name => 'worker',
        instance => $instance_number,
    );
    $settings->apply_to_app($app);

    # setup the isotovideo engine
    # FIXME: Get rid of the concept of engines in the worker.
    my $isotovideo_interface_version = OpenQA::Worker::Engines::isotovideo::set_engine_exec($cli_options->{isotovideo});

    my $self = $class->SUPER::new(
        instance_number              => $instance_number,
        no_cleanup                   => $cli_options->{'no-cleanup'},
        pool_directory               => "$OpenQA::Utils::prjdir/pool/$instance_number",
        app                          => $app,
        settings                     => $settings,
        clients_by_webui_host        => undef,
        worker_hostname              => $hostname,
        isotovideo_interface_version => $isotovideo_interface_version,
    );
    $self->{_cli_options}            = $cli_options;
    $self->{_pool_directory_lock_fd} = undef;
    $self->{_shall_terminate}        = 0;

    return $self;
}

# logs the basic configuration of the worker instance
sub log_setup_info {
    my ($self) = @_;

    my $instance = $self->instance_number;
    my $settings = $self->settings;
    my $msg      = "worker $instance:";
    $msg .= "\n - config file:           " . ($settings->file_path // 'not found');
    $msg .= "\n - worker hostname:       " . $self->worker_hostname;
    $msg .= "\n - isotovideo version:    " . $self->isotovideo_interface_version;
    $msg .= "\n - websocket API version: " . WEBSOCKET_API_VERSION;
    $msg .= "\n - web UI hosts:          " . join(',', @{$settings->webui_hosts});
    $msg .= "\n - class:                 " . ($settings->global_settings->{WORKER_CLASS} // '?');
    $msg .= "\n - no cleanup:            " . ($self->no_cleanup ? 'yes' : 'no');
    $msg .= "\n - pool directory:        " . $self->pool_directory;
    log_info($msg);

    my $parse_errors = $settings->parse_errors;
    log_error(join("\n - ", 'Errors occurred when reading config file:', @$parse_errors)) if (@$parse_errors);

    return $msg;
}

# determines the worker's capabilities
sub capabilities {
    my ($self) = @_;

    my $cached_caps = $self->{_caps};
    my $caps        = $cached_caps // {
        host                         => $self->worker_hostname,
        instance                     => $self->instance_number,
        websocket_api_version        => WEBSOCKET_API_VERSION,
        isotovideo_interface_version => $self->isotovideo_interface_version,
    };

    # pass current job if executing one; this should prevent the web UI to mark the current job as
    # incomplete despite the re-registration
    my $current_job = $self->current_job;
    my $job_state   = $current_job ? $current_job->status : undef;
    if ($job_state && $job_state ne 'new' && $job_state ne 'stopped') {
        $caps->{job_id} = $current_job->id;
    }
    else {
        delete $caps->{job_id};
    }

    # do not update subsequent values; just return the previously cached values
    return $caps if $cached_caps;

    # determine CPU info
    my $global_settings = $self->settings->global_settings;
    if (my $arch = $global_settings->{ARCH}) {
        $caps->{cpu_arch} = $arch;
    }
    else {
        open(my $LSCPU, "-|", "LC_ALL=C lscpu");
        for my $line (<$LSCPU>) {
            chomp $line;
            if ($line =~ m/Model name:\s+(.+)$/) {
                $caps->{cpu_modelname} = $1;
            }
            if ($line =~ m/Architecture:\s+(.+)$/) {
                $caps->{cpu_arch} = $1;
            }
            if ($line =~ m/CPU op-mode\(s\):\s+(.+)$/) {
                $caps->{cpu_opmode} = $1;
            }
        }
        close($LSCPU);
    }

    # determine memory limit
    open(my $MEMINFO, "<", "/proc/meminfo");
    for my $line (<$MEMINFO>) {
        chomp $line;
        if ($line =~ m/MemTotal:\s+(\d+).+kB/) {
            my $mem_max = $1 ? $1 : '';
            $caps->{mem_max} = int($mem_max / 1024) if $mem_max;
        }
    }
    close($MEMINFO);

    # determine worker class ...
    if (my $worker_class = $global_settings->{WORKER_CLASS}) {
        # ... from settings
        $caps->{worker_class} = $worker_class;
    }
    else {
        # ... from CPU architecture
        my %supported_archs_by_cpu_archs = (
            i586   => ['i586'],
            i686   => ['i686', 'i586'],
            x86_64 => ['x86_64', 'i686', 'i586'],

            ppc     => ['ppc'],
            ppc64   => ['ppc64le', 'ppc64', 'ppc'],
            ppc64le => ['ppc64le', 'ppc64', 'ppc'],

            s390  => ['s390'],
            s390x => ['s390x', 's390'],

            aarch64 => ['aarch64'],
        );
        $caps->{worker_class}
          = join(',', map { 'qemu_' . $_ } @{$supported_archs_by_cpu_archs{$caps->{cpu_arch}} // [$caps->{cpu_arch}]});
        # TODO: check installed qemu and kvm?
    }

    return $self->{_caps} = $caps;
}

sub status {
    my ($self) = @_;

    my $current_job = $self->current_job;
    $self->check_availability unless $current_job;

    my %status = (type => 'worker_status');
    if ($current_job) {
        $status{status}             = 'working';
        $status{current_webui_host} = $self->current_webui_host;
        $status{job}                = $current_job->info;
    }
    elsif (my $current_error = $self->current_error) {
        $status{status} = 'broken';
        $status{reason} = $current_error;
    }
    else {
        $status{status} = 'free';
    }
    return \%status;
}

# initializes the worker so it does its thing when the Mojo::IOLoop is started
# note: Do not change the settings - especially the web UI hosts after calling this function.
sub init {
    my ($self) = @_;
    my $return_code = 0;

    # instantiate a client for each web UI we need to connect to
    my $settings    = $self->settings;
    my $webui_hosts = $settings->webui_hosts;
    die 'no web UI hosts configured' unless @$webui_hosts;

    my %clients_by_webui_host
      = map { $_ => OpenQA::Worker::WebUIConnection->new($_, $self->{_cli_options}) } @$webui_hosts;
    $self->clients_by_webui_host(\%clients_by_webui_host);

    # register event handler
    for my $host (@$webui_hosts) {
        $clients_by_webui_host{$host}->on(
            status_changed => sub {
                $self->_handle_client_status_changed(@_);
            });
    }

    # check the setup (pool directory, worker cache, ...)
    # note: This assigns $self->current_error if there's an error and therefore prevents us from grabbing
    #       a job while broken. The error is propagated to the web UIs.
    $self->check_availability();

    # register error handler to stop the current job when a critical/unhandled error occurs
    Mojo::IOLoop->singleton->reactor->on(
        error => sub {
            my ($reactor, $err) = @_;
            $return_code = 1;

            # try to stop gracefully
            if (!$self->{_shall_terminate}) {
                try {
                    # log error using print because logging utils might have caused the exception
                    # (no need to repeat $err, it is printed anyways)
                    log_error('Stopping because a critical error occurred.');

                    # try to stop the job nicely
                    return $self->stop('exception');
                };
            }

            # kill if stopping gracefully does not work
            log_error('Another error occurred when trying to stop gracefully due to an error. '
                  . 'Trying to kill ourself forcefully now.');
            $self->kill();
            Mojo::IOLoop->stop();
        });

    # initialize clients to connect to the web UIs
    my $global_settings              = $settings->global_settings;
    my $webui_host_specific_settings = $settings->webui_host_specific_settings;
    for my $host (@$webui_hosts) {
        die "settings for $host not correctly initialized\n"
          unless my $host_settings = $webui_host_specific_settings->{$host};
        die "client for $host not correctly initialized\n" unless my $client = $clients_by_webui_host{$host};
        next unless $client->status eq 'new';

        # check if host's working directory exists if caching is not enabled
        if ($global_settings->{CACHEDIRECTORY}) {
            $client->cache_directory(_prepare_cache_directory($host, $global_settings->{CACHEDIRECTORY}));
        }

        # find working directory for host
        # note: This is being also duplicated by OpenQA::Test::Utils since 49c06362d.
        my @working_dirs = ($host_settings->{SHARE_DIRECTORY}, catdir($OpenQA::Utils::prjdir, 'share'));
        my ($working_dir) = grep { $_ && -d } @working_dirs;
        unless ($working_dir) {
            $_ and log_debug("Found possible working directory for $host: $_") for @working_dirs;
            log_error("Ignoring host '$host': Working directory does not exist.");
            next;
        }
        $client->working_directory($working_dir);
        log_info("Project dir for host $host is $working_dir");

        # assign other properties of the client
        $client->worker($self);
        $client->testpool_server($host_settings->{TESTPOOLSERVER});

        # schedule registration of the web UI host
        Mojo::IOLoop->next_tick(
            sub {
                $client->register();
            });
    }

    return $return_code;
}

sub exec {
    my ($self) = @_;

    my $return_code = $self->init;

    # start event loop - this will block until stop is called
    Mojo::IOLoop->start;

    return $return_code;
}

sub _prepare_cache_directory {
    my ($webui_host, $cachedirectory) = @_;
    die 'No cachedir' unless $cachedirectory;

    my $host_to_cache = Mojo::URL->new($webui_host)->host || $webui_host;
    my $shared_cache  = File::Spec->catdir($cachedirectory, $host_to_cache);
    File::Path::make_path($shared_cache);
    log_info("CACHE: caching is enabled, setting up $shared_cache");

    # make sure the downloads are in the same file system - otherwise
    # asset->move_to becomes a bit more expensive than it should
    my $tmpdir = File::Spec->catdir($cachedirectory, 'tmp');
    File::Path::make_path($tmpdir);
    $ENV{MOJO_TMPDIR} = $tmpdir;

    return $shared_cache;
}

sub accept_job {
    my ($self, $client, $job_info) = @_;

    die 'attempt to accept a new job although there is already a job running' if $self->current_job;

    # instantiate new job
    my $webui_host = $client->webui_host;
    my $job        = OpenQA::Worker::Job->new($self, $client, $job_info);
    $job->on(
        status_changed => sub {
            $self->_handle_job_status_changed(@_);
        });

    remove_log_channel('autoinst');
    remove_log_channel('worker');
    add_log_channel('autoinst', path => 'autoinst-log.txt', level => 'debug');
    add_log_channel(
        'worker',
        path    => 'worker-log.txt',
        level   => $self->settings->global_settings->{LOG_LEVEL} // 'info',
        default => 'append',
    );

    # ensure the pool directory is cleaned up before starting a new job
    # note: The cleanup after finishing the last job might have been prevented via --no-cleanup.
    $self->_clean_pool_directory unless $self->no_cleanup;

    $self->current_job($job);
    $self->current_webui_host($webui_host);
    $job->accept();
}

# stops the current job and (if there is one) and terminates the worker
sub stop {
    my ($self, $reason) = @_;

    $self->{_shall_terminate} = 1;

    my $current_job = $self->current_job;
    if (!$current_job) {
        # FIXME: better stop gracefully?
        Mojo::IOLoop->stop;
        return undef;
    }

    if ($current_job->status eq 'setup') {
        # stop job directly during setup because the IO loop is blocked by isotovideo.pm during setup
        return $current_job->stop($reason);
    }
    Mojo::IOLoop->next_tick(
        sub {
            $current_job->stop($reason);
        });
}

# stops the current job if there's one and it is running
sub stop_current_job {
    my ($self, $reason) = @_;

    if (my $current_job = $self->current_job) { $current_job->stop($reason); }
}

sub kill {
    my ($self) = @_;

    if (my $current_job = $self->current_job) { $current_job->kill; }
    Mojo::IOLoop->stop;
}

sub is_stopping {
    my ($self) = @_;

    return 1 if $self->{_shall_terminate};
    my $current_job = $self->current_job or return 0;
    return $current_job->status eq 'stopping';
}

# checks whether a qemu instance using the current pool directory is running and returns its PID if that's the case
sub is_qemu_running {
    my ($self) = @_;

    return undef unless my $pool_directory = $self->pool_directory;
    return undef unless open(my $fh, '<', my $pid_file = "$pool_directory/qemu.pid");

    my $pid = <$fh>;
    chomp($pid);
    close($fh);
    return undef unless $pid;

    my $link = readlink("/proc/$pid/exe");
    if (!$link || !($link =~ /\/qemu-[^\/]+$/)) {
        # delete the obsolete PID file (it might have been spared on cleanup if QEMU was still running)
        unlink($pid_file) unless $self->no_cleanup;
        return undef;
    }
    return undef unless $link;
    return undef unless $link =~ /\/qemu-[^\/]+$/;

    return $pid;
}

# checks whether the worker is available
# note: This is used to check certain error conditions *before* starting a job to prevent incompletes and
#       being able to propagate the brokenness to the web UIs.
sub check_availability {
    my ($self) = @_;

    # clear previously detected errors (which might be gone)
    $self->current_error(undef);

    # check whether the cache service is available if caching enabled
    if ($self->settings->global_settings->{CACHEDIRECTORY}) {
        my $error = OpenQA::Worker::Cache::Client->new->availability_error;
        if ($error) {
            log_error('Worker cache not available: ' . $error);
            $self->current_error($error);
            return 0;
        }
    }

    # check whether qemu is still running
    if (my $qemu_pid = $self->is_qemu_running) {
        $self->current_error("A QEMU instance using the current pool directory is still running (PID: $qemu_pid)");
        log_error($self->current_error);
        return 0;
    }

    # ensure pool directory is locked
    unless (defined $self->_setup_pool_directory) {
        # note: $self->current_error is set within $self->_ensure_pool_directory in the error case.
        log_error($self->current_error);
        return 0;
    }

    return 1;
}

sub _handle_client_status_changed {
    my ($self, $client, $event_data) = @_;

    my $status        = $event_data->{status};
    my $error_message = $event_data->{error_message};

    # log registration attempts
    if ($status eq 'registering') {
        log_info('Registering with openQA ' . $client->webui_host);
    }
    # log ws connection attempts
    elsif ($status eq 'establishing_ws') {
        log_info('Establishing ws connection via ' . $event_data->{url});
    }
    # log ws connection attempts
    elsif ($status eq 'connected') {
        my $webui_host = $client->webui_host;
        my $worker_id  = $client->worker_id;
        log_info("Registered and connected via websockets with openQA host $webui_host and worker ID $worker_id");
    }
    # handle case when trying to connect to web UI should *not* be attempted again
    elsif ($status eq 'disabled') {
        log_error("$error_message - ignoring server");
        # shut down if there are no web UIs left
        my $clients_by_webui_host = $self->clients_by_webui_host;
        my $webui_hosts           = $self->settings->webui_hosts;
        for my $host (@$webui_hosts) {
            my $client = $clients_by_webui_host->{$host};
            if ($client && $client->status ne 'disabled') {
                return undef;
            }
        }
        log_error('Failed registration with all configured web UI hosts');
        $self->stop('api_error');
    }
    # handle failures where it makes sense to reconnect
    elsif ($status eq 'failed') {
        log_error("$error_message - trying again in 10 seconds");
        Mojo::IOLoop->timer(
            10 => sub {
                $client->register();
            });
    }
    # FIXME: Avoid so much elsif like in CommandHandler.pm.
}

sub _handle_job_status_changed {
    my ($self, $job, $event_data) = @_;

    my $job_id   = $job->id   // '?';
    my $job_name = $job->name // '?';
    my $client   = $job->client;
    my $webui_host  = $client->webui_host;
    my $status      = $event_data->{status};
    my $reason      = $event_data->{reason};
    my $current_job = $self->current_job;
    if (!$current_job || $job != $current_job) {
        die "Received job status update for job $job_id ($status) which is not the current one.";
    }

    if ($status eq 'accepting') {
        log_debug("Accepting job $job_id from $webui_host.");
    }
    elsif ($status eq 'accepted') {
        $job->start();
    }
    elsif ($status eq 'setup') {
        log_debug("Setting job $job_id from $webui_host up");
    }
    elsif ($status eq 'running') {
        log_debug("Running job $job_id from $webui_host: $job_name.");
    }
    elsif ($status eq 'stopping') {
        log_debug("Stopping job $job_id from $webui_host: $job_name - reason: $reason");
    }
    elsif ($status eq 'stopped') {
        if (my $error_message = $event_data->{error_message}) {
            log_error($error_message);
        }
        log_debug("Job $job_id from $webui_host finished - reason: $reason");
        $self->current_job(undef);
        $self->current_webui_host(undef);

        # handle case when the worker should not continue to run e.g. because the user stopped it or
        # a critical error occurred
        if ($self->{_shall_terminate}) {
            return $self->stop;
        }

        unless ($self->no_cleanup) {
            log_debug('Cleaning up for next job');
            $self->_clean_pool_directory;
        }
    }
    # FIXME: Avoid so much elsif like in CommandHandler.pm.
}

sub _setup_pool_directory {
    my ($self) = @_;

    # skip if we have already locked the pool directory
    my $pool_directory_fd = $self->{_pool_directory_lock_fd};
    return $pool_directory_fd if defined $pool_directory_fd;

    my $pool_directory = $self->pool_directory;
    if (!$pool_directory) {
        $self->current_error('No pool directory assigned.');
        return undef;
    }

    try {
        $self->{_pool_directory_lock_fd} = $pool_directory_fd = $self->_lock_pool_directory;
    }
    catch {
        $self->current_error('Unable to lock pool directory: ' . $_);
    };
    return $pool_directory_fd;
}

sub _lock_pool_directory {
    my ($self) = @_;

    die 'no pool directory assigned' unless my $pool_directory = $self->pool_directory;
    make_path($pool_directory) unless -e $pool_directory;

    chdir $pool_directory || die "cannot change directory to $pool_directory: $!\n";
    open(my $lockfd, '>>', '.locked') or die "cannot open lock file: $!\n";
    unless (fcntl($lockfd, F_SETLK, pack('ssqql', F_WRLCK, 0, 0, 0, $$))) {
        die "$pool_directory already locked\n";
    }
    $lockfd->autoflush(1);
    truncate($lockfd, 0);
    print $lockfd "$$\n";
    return $lockfd;
}

sub _clean_pool_directory {
    my ($self) = @_;

    return undef unless my $pool_directory = $self->pool_directory;

    # prevent cleanup of "qemu.pid" file if QEMU is still running so is_qemu_running() continues to work
    my %excludes;
    $excludes{"$pool_directory/qemu.pid"} = 1 if $self->is_qemu_running;

    for my $file (glob "$pool_directory/*") {
        next if $excludes{$file};
        if (-d $file) {
            remove_tree($file);
        }
        else {
            unlink($file);
        }
    }
}

1;
