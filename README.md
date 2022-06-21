[![Build Status](https://travis-ci.org/zostay/AnyEvent-SlackRTM.svg?branch=master)](https://travis-ci.org/zostay/AnyEvent-SlackRTM)
[![GitHub issues](https://img.shields.io/github/issues/zostay/AnyEvent-SlackRTM.svg)](https://github.com/zostay/AnyEvent-SlackRTM/issues)
[![Kwalitee status](https://cpants.cpanauthors.org/dist/AnyEvent-SlackRTM.png)](https://cpants.cpanauthors.org/dist/AnyEvent-SlackRTM)
[![Coverage Status](https://coveralls.io/repos/zostay/AnyEvent-SlackRTM/badge.svg?branch=master)](https://coveralls.io/r/zostay/AnyEvent-SlackRTM?branch=master)

# NAME

AnyEvent::SlackRTM - AnyEvent module for interacting with the Slack RTM API

# VERSION

version 1.3

# SYNOPSIS

    use AnyEvent;
    use AnyEvent::SlackRTM;

    my $access_token = "<user or bot token>";
    my $channel_id = "<channel/group/DM id>";

    my $cond = AnyEvent->condvar;
    my $rtm = AnyEvent::SlackRTM->new($access_token);

    my $i = 1;
    my $keep_alive;
    my $counter;
    $rtm->on('hello' => sub {
        print "Ready\n";

        $keep_alive = AnyEvent->timer(interval => 60, cb => sub {
            print "Ping\n";
            $rtm->ping;
        });

        $counter = AnyEvent->timer(interval => 5, cb => sub {
            print "Send\n";
            $rtm->send({
                type => 'message',
                channel => $channel_id,
                text => "".$i++,
            });
        });
    });
    $rtm->on('message' => sub {
        my ($rtm, $message) = @_;
        print "> $message->{text}\n";
    });
    $rtm->on('finish' => sub {
        print "Done\n";
        $cond->send;
    });

    $rtm->start;
    AnyEvent->condvar->recv;

# DESCRIPTION

This provides an [AnyEvent](https://metacpan.org/pod/AnyEvent)-based interface to the [Slack Real-Time Messaging API](https://api.slack.com/rtm). This allows a program to interactively send and receive messages of a WebSocket connection and takes care of a few of the tedious details of encoding and decoding messages.

As of this writing, the library is still a fairly low-level experience, but more pieces may be automated or simplified in the future.

**Disclaimer:** Note also that this API is subject to rate limits and any service limitations and fees associated with your Slack service. Please make sure you understand those limitations before using this library.

# METHODS

## new

    method new($token, $client_opts)

Constructs a [AnyEvent::SlackRTM](https://metacpan.org/pod/AnyEvent%3A%3ASlackRTM) object and returns it.

The `$token` option is the access token from Slack to use. This may be either of the following type of tokens:

- [User Token](https://api.slack.com/tokens). This is a token to perform actions on behalf of a user account.
- [Bot Token](https://slack.com/services/new/bot). If you configure a bot integration, you may use the access token on the bot configuration page to use this library to act on behalf of the bot account. Bot accounts may not have the same features as a user account, so please be sure to read the Slack documentation to understand any differences or limitations.

The `$client_opts` is an optional HashRef of [AnyEvent::WebSocket::Client](https://metacpan.org/pod/AnyEvent%3A%3AWebSocket%3A%3AClient)'s configuration options, e.g. `env_proxy`, `max_payload_size`, `timeout`, etc.

## start

    method start()

This will establish the WebSocket connection to the Slack RTM service.

You should have registered any events using ["on"](#on) before doing this or you may miss some events that arrive immediately.

Sets up a "keep alive" timer,
which triggers every 15 seconds to send a `ping` message
if there hasn't been any activity in the past 10 seconds.
The `ping` will trigger a `pong` response,
so there should be at least one message every 15 seconds.
This will disconnect if no messages have been received in the past 30 seconds;
however, it should trigger an automatic reconnect to keep the connection alive.

## metadata

    method metadata() returns HashRef

The initial connection is established after calling the [rtm.start](https://api.slack.com/methods/rtm.start) method on the web API. This returns some useful information, which is available here.

This will only contain useful information _after_ ["start"](#start) is called.

## quiet

    method quiet($quiet?) returns Bool

Normally, errors are sent to standard error. If this flag is set, that does not happen. It is recommended that you provide an error handler if you set the quiet flag.

## on

    method on($type, \&cb, ...)

This sets up a callback handler for the named message type. The available message types are available in the [Slack Events](https://api.slack.com/events) documentation. Only one handler may be setup for each event. Setting a new handler with this method will replace any previously set handler. Events with no handler will be ignored/unhandled.

You can specify multiple type/callback pairs to make multiple registrations at once.

## off

    method off(@types)

This removes the handler for the named `@types`.

## send

    method send(\%msg)

This sends the given message over the RTM socket. Slack requires that every message sent over this socket must have a unique ID set in the "id" key. You, however, do not need to worry about this as the ID will be set for you.

## ping

    method ping(\%msg)

This sends a ping message over the Slack RTM socket. You may add any paramters you like to `%msg` and the return "pong" message will echo back those parameters.

## said\_hello

    method said_hello() returns Bool

Returns true after the "hello" message has been received from the server.

## finished

    method finished() returns Bool

Returns true after the "finish" message has been received from the server (meaning the connection has been closed). If this is true, this object should be discarded.

## close

    method close()

This closes the WebSocket connection to the Slack RTM API.

# CAVEATS

This is a low-level API. Therefore, this only aims to handle the basic message
handling. You must make sure that any messages you send to Slack are formatted
correctly. You must make sure any you receive are handled appropriately. Be sure
to read the Slack documentation basic message formatting, attachment formatting,
rate limits, etc.

1;

# AUTHOR

Andrew Sterling Hanenkamp <hanenkamp@cpan.org>

# COPYRIGHT AND LICENSE

This software is copyright (c) 2022 by Qubling Software LLC.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.
