#!/usr/bin/env perl
use v5.14;

use Test::More;
use AnyEvent;
use AnyEvent::SlackRTM;
use Try::Tiny;

my $token = $ENV{SLACK_TOKEN};
if ($token) {
    plan tests => 1;
}
else {
    plan skip_all => 'No SLACK_TOKEN configured for testing.';
}

my $rtm = AnyEvent::SlackRTM->new($token . 'badtoken');

my $c = AnyEvent->condvar;
try {
    $rtm->start;
}
catch {
    like $_, qr{^unable to start, Slack call failed:},
        'got an error message when using bad token';
};
$c->recv;
