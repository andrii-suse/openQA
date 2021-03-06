#!/usr/bin/perl

# Copyright (C) 2017-2019 SUSE LLC
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

use 5.018;
use Test::More;
use POSIX;
use FindBin;
use lib ("$FindBin::Bin/lib", "../lib", "lib");
use OpenQA::Client;
use OpenQA::WebSockets;
use OpenQA::WebSockets::Model::Status;
use OpenQA::Constants 'WEBSOCKET_API_VERSION';
use OpenQA::Test::Database;
use OpenQA::Test::FakeWebSocketTransaction;
use Test::Output;
use Test::MockModule;
use Test::Mojo;
use Mojo::JSON;

my $schema = OpenQA::Test::Database->new->create;
my $t      = Test::Mojo->new('OpenQA::WebSockets');

subtest 'Authentication' => sub {
    my $app = $t->app;

    combined_like(
        sub {
            $t->get_ok('/test')->status_is(404);
            $t->get_ok('/')->status_is(200)->json_is({name => $app->defaults('appname')});
            local $t->app->config->{no_localhost_auth} = 0;
            $t->get_ok('/')->status_is(403)->json_is({error => 'Not authorized'});
            $t->ua(OpenQA::Client->new(apikey => 'PERCIVALKEY02', apisecret => 'PERCIVALSECRET02')
                  ->ioloop(Mojo::IOLoop->singleton))->app($app);
            $t->get_ok('/')->status_is(200)->json_is({name => $app->defaults('appname')});
        },
        qr/auth by user: percival/,
        'auth logged'
    );

    my $c = $t->app->build_controller;
    $c->tx->remote_address('127.0.0.1');
    ok $c->is_local_request, 'is localhost';
    $c->tx->remote_address('::1');
    ok $c->is_local_request, 'is localhost';
    $c->tx->remote_address('192.168.2.1');
    ok !$c->is_local_request, 'not localhost';
};

subtest 'API' => sub {
    $t->tx($t->ua->start($t->ua->build_websocket_tx('/ws/23')))->status_is(400)->content_like(qr/Unknown worker/);
    $t->get_ok('/api/is_worker_connected/1')->status_is(200)->json_is({connected => Mojo::JSON::false});
    local $t->app->status->workers->{1} = {tx => OpenQA::Test::FakeWebSocketTransaction->new};
    $t->get_ok('/api/is_worker_connected/1')->status_is(200)->json_is({connected => Mojo::JSON::true});
};

subtest 'workers_checker' => sub {
    my $mock_schema = Test::MockModule->new('OpenQA::Schema');
    my $mock_singleton_called;
    $mock_schema->mock(singleton => sub { $mock_singleton_called++; bless({}); });
    combined_like(
        sub { OpenQA::WebSockets::Model::Status->singleton->workers_checker; },
        qr/Failed dead job detection/,
        'failure logged'
    );
    ok $mock_singleton_called, 'mocked singleton method has been called';
};

my $workers   = $schema->resultset('Workers');
my $worker    = $workers->search({host => 'localhost', instance => 1})->first;
my $worker_id = $worker->id;
OpenQA::WebSockets::Model::Status->singleton->workers->{$worker_id} = {
    id        => $worker_id,
    db        => $worker,
    last_seen => '0001-01-01',
};

subtest 'get_stale_worker_jobs' => sub {
    combined_like(
        sub { OpenQA::WebSockets::Model::Status->singleton->get_stale_worker_jobs(-9999999999); },
        qr/Worker localhost:1 not seen since \d+ seconds/,
        'not seen message logged'
    );
};

subtest 'web socket message handling' => sub {
    subtest 'unexpected message' => sub {
        combined_like(
            sub {
                $t->websocket_ok('/ws/1', 'establish ws connection');
                $t->send_ok('');
                $t->finished_ok(1003, 'connection closed on unexpected message');
            },
            qr/Received unexpected WS message .* from worker 1/s,
            'unexpected message logged'
        );
    };

    subtest 'incompatible version' => sub {
        combined_like(
            sub {
                $t->websocket_ok('/ws/1', 'establish ws connection');
                $t->send_ok('{}');
                $t->message_ok('message received');
                $t->json_message_is({type => 'incompatible'});
                $t->finished_ok(1008, 'connection closed when version incompatible');
            },
            qr/Received a message from an incompatible worker 1/s,
            'incompatible version logged'
        );
    };

    # make sure the API version matches in subsequent tests
    $worker->set_property('WEBSOCKET_API_VERSION', WEBSOCKET_API_VERSION);
    $worker->{_websocket_api_version_} = WEBSOCKET_API_VERSION;

    subtest 'unknown type' => sub {
        combined_like(
            sub {
                $t->websocket_ok('/ws/1', 'establish ws connection');
                $t->send_ok('{"type":"foo"}');
                $t->finish_ok(1000, 'finished ws connection');
            },
            qr/Received unknown message type "foo" from worker 1/s,
            'unknown type logged'
        );
    };

    subtest 'accepted' => sub {
        combined_like(
            sub {
                $t->websocket_ok('/ws/1', 'establish ws connection');
                $t->send_ok('{"type":"accepted","jobid":42}');
                $t->finish_ok(1000, 'finished ws connection');
            },
            qr/Worker: 1 accepted job 42/s,
            'job accept logged'
        );
    };

    $t->websocket_ok('/ws/1', 'establish ws connection');

    subtest 'job status' => sub {
        $t->send_ok({json => {type => 'status', jobid => 42}});
        $t->message_ok('message received');
        $t->json_message_is({result => 'nack'});

        $t->send_ok({json => {type => 'status', jobid => 99963, data => {uploading => 1}}});
        $t->message_ok('message received');
        $t->json_message_is({result => 1});
    };

    subtest 'worker status' => sub {
        combined_like(
            sub {
                $t->send_ok({json => {type => 'worker_status', status => 'broken', reason => 'test'}});
                $t->message_ok('message received');
                $t->json_message_is({type => 'info', population => $workers->count});
                is($workers->find($worker_id)->error, 'test', 'broken message set');
            },
            qr/Received .* worker_status message.*Updating worker seen from worker_status/s,
            'update logged'
        );

        # assume no job is assigned
        combined_like(
            sub {
                $workers->find($worker_id)->update({job_id => undef});
                $t->send_ok({json => {type => 'worker_status', status => 'idle'}});
                $t->message_ok('message received');
                $t->json_message_is({type => 'info', population => $workers->count});
                is($workers->find($worker_id)->error, undef, 'broken status unset');
            },
            qr/Received .* worker_status message.*Updating worker seen from worker_status/s,
            'update logged'
        );
    };

    combined_like(
        sub {
            $t->finish_ok(1000, 'finished ws connection');
        },
        qr/Worker 1 websocket connection closed - 1000/s,
        'connection closed logged'
    );
};

done_testing();

1;
