#!/usr/bin/env perl
use v5.14;
use warnings;

use Test::More;
use AnyEvent::SlackRTM;
use Furl;

$ENV{http_proxy} = "https://aesrtm.test";
my $furl_env_proxy_set = 0;

no warnings qw< redefine >;
local *Furl::get = sub {
    $furl_env_proxy_set = ${ $_[0] }->{proxy} eq 'https://aesrtm.test';
    die 'Skipped the get';
};
use warnings qw< redefine >;

my $token = 'fake';
{
    $furl_env_proxy_set = undef;
    my $rtm = AnyEvent::SlackRTM->new($token);
    ok !$rtm->{client}->env_proxy, "No proxy on the websocket client";

    eval { $rtm->start };
    like $@, qr/^Skipped the get /, "Didn't actually make a request";
    ok !$furl_env_proxy_set, "Furl did not get proxy settings from %ENV";
}

{
    $furl_env_proxy_set = undef;
    my $rtm = AnyEvent::SlackRTM->new( $token, { env_proxy => 1 } );
    ok $rtm->{client}->env_proxy, "Set the env_proxy from the passed in opt";

    eval { $rtm->start };
    like $@, qr/^Skipped the get /, "Didn't actually make a request";
    ok $furl_env_proxy_set, "Furl got proxy settings from %ENV";
}

done_testing();
