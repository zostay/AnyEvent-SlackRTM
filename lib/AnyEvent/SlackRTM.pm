package AnyEvent::SlackRTM;

use v5.14;

# ABSTRACT: AnyEvent module for interacting with the Slack RTM API

use AnyEvent;
use AnyEvent::WebSocket::Client 0.12;
use Carp;
use Furl;
use JSON;
use Try::Tiny;

our $START_URL = 'https://slack.com/api/rtm.connect';

=head1 SYNOPSIS

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

=head1 DESCRIPTION

This provides an L<AnyEvent>-based interface to the L<Slack Real-Time Messaging API|https://api.slack.com/rtm>. This allows a program to interactively send and receive messages of a WebSocket connection and takes care of a few of the tedious details of encoding and decoding messages.

As of this writing, the library is still a fairly low-level experience, but more pieces may be automated or simplified in the future.

B<Disclaimer:> Note also that this API is subject to rate limits and any service limitations and fees associated with your Slack service. Please make sure you understand those limitations before using this library.

=head1 METHODS

=head2 new

    method new($token, $client_opts)

Constructs a L<AnyEvent::SlackRTM> object and returns it.

The C<$token> option is the access token from Slack to use. This may be either of the following type of tokens:

=over

=item *

L<User Token|https://api.slack.com/tokens>. This is a token to perform actions on behalf of a user account.

=item *

L<Bot Token|https://slack.com/services/new/bot>. If you configure a bot integration, you may use the access token on the bot configuration page to use this library to act on behalf of the bot account. Bot accounts may not have the same features as a user account, so please be sure to read the Slack documentation to understand any differences or limitations.

=back

The C<$client_opts> is an optional HashRef of L<AnyEvent::WebSocket::Client>'s configuration options, e.g. C<env_proxy>, C<max_payload_size>, C<timeout>, etc.

=cut

sub new {
    my ($class, $token, $client_opts) = @_;

    $client_opts //= {};
    croak "Client options must be passed as a HashRef" unless ref $client_opts eq 'HASH';

    my $client;
    try {
        $client = AnyEvent::WebSocket::Client->new(%$client_opts);
    } catch {
        croak "Can't create client object: $_";
    };

    return bless {
        token    => $token,
        client   => $client,
        registry => {},
    }, $class;
}

=head2 start

    method start()

This will establish the WebSocket connection to the Slack RTM service.

You should have registered any events using L</on> before doing this or you may miss some events that arrive immediately.

Sets up a "keep alive" timer,
which triggers every 15 seconds to send a C<ping> message
if there hasn't been any activity in the past 10 seconds.
The C<ping> will trigger a C<pong> response,
so there should be at least one message every 15 seconds.
This will disconnect if no messages have been received in the past 30 seconds;
however, it should trigger an automatic reconnect to keep the connection alive.

=cut

sub start {
    my $self = shift;

    use vars qw( $VERSION );
    $VERSION //= '*-devel';

    my $furl = Furl->new(
        agent   => "AnyEvent::SlackRTM/$VERSION",
        timeout => $self->{client}->timeout,
    );

    my $res = $furl->get($START_URL . '?token=' . $self->{token});
    my $start = try {
        decode_json($res->content);
    }
    catch {
        my $status = $res->status;
        my $message = $res->content;
        croak "unable to start, Slack call failed: $status $message";
    };

    my $ok  = $start->{ok};
    croak "unable to start, Slack returned an error: $start->{error}"
    unless $ok;

    # Store this stuff in case we want it
    $self->{metadata} = $start;

    # We've now asked to re-open the connection,
    # so don't close again on timeout.
    delete $self->{closed};

    $self->{client}->connect( $start->{url} )->cb( sub {
        my $client = shift;

        delete $self->{finished};
        $self->{started}++;
        $self->{id} = 1;

        my $conn = $self->{conn} = $client->recv;
        $conn->on( each_message => sub { $self->_handle_incoming(@_) } );
        $conn->on( finish       => sub { $self->_handle_finish(@_) } );

        my $started = localtime;
        $self->{_last_keep_alive} = time;
        $self->{keep_alive}       = AnyEvent->timer(
            after    => 15,
            interval => 15,
            cb       => sub {
                my $id    = $self->{id};
                my $now   = time;
                my $since = $now - $self->{_last_keep_alive};
                if ( $since > 30 ) {
                    # will trigger a finish, which will reconnect
                    # if $self->{closed} is not set.
                    $conn->close;
                }
                elsif ( $since > 10 ) {
                    $self->ping( { keep_alive => $now } );
                }
            },
        );
    } );
}

=head2 metadata

    method metadata() returns HashRef

The initial connection is established after calling the
L<rtm.connect|https://api.slack.com/methods/rtm.connect> method on the web API.
This returns some useful information, which is available here.

This will only contain useful information I<after> L</start> is called.

=head2 quiet

    method quiet($quiet?) returns Bool

Normally, errors are sent to standard error. If this flag is set, that does not happen. It is recommended that you provide an error handler if you set the quiet flag.

=cut

sub metadata { shift->{metadata} // {} }
sub quiet {
    my $self = shift;

    if (@_) {
        $self->{quiet} = shift;
    }

    return $self->{quiet} // '';
}

=head2 on

    method on($type, \&cb, ...)

This sets up a callback handler for the named message type. The available message types are available in the L<Slack Events|https://api.slack.com/events> documentation. Only one handler may be setup for each event. Setting a new handler with this method will replace any previously set handler. Events with no handler will be ignored/unhandled.

You can specify multiple type/callback pairs to make multiple registrations at once.

=cut

sub on {
    my ($self, %registrations) = @_;

    for my $type (keys %registrations) {
        my $cb = $registrations{ $type };
        $self->{registry}{$type} = $cb;
    }
}

=head2 off

    method off(@types)

This removes the handler for the named C<@types>.

=cut

sub off {
    my ($self, @types) = @_;
    delete $self->{registry}{$_} for @types;
}

sub _do {
    my ($self, $type, @args) = @_;

    if (defined $self->{registry}{$type}) {
        $self->{registry}{$type}->($self, @args);
    }
}

=head2 send

    method send(\%msg)

This sends the given message over the RTM socket. Slack requires that every message sent over this socket must have a unique ID set in the "id" key. You, however, do not need to worry about this as the ID will be set for you.

=cut

sub send {
    my ($self, $msg) = @_;

    croak "Cannot send because the Slack connection is not started"
    unless $self->{started};
    croak "Cannot send because Slack has not yet said hello"
    unless $self->{said_hello};
    croak "Cannot send because the connection is finished"
    if $self->{finished};

    $msg->{id} = $self->{id}++;

    $self->{conn}->send(encode_json($msg));
}

=head2 ping

    method ping(\%msg)

This sends a ping message over the Slack RTM socket. You may add any paramters you like to C<%msg> and the return "pong" message will echo back those parameters.

=cut

sub ping {
    my ($self, $msg) = @_;

    $self->send({
        %{ $msg // {} },
        type => 'ping'
    });
}

sub _handle_incoming {
    my ($self, $conn, $raw) = @_;

    my $msg = try {
        decode_json($raw->body);
    }
    catch {
        my $message = $raw->body;
        croak "unable to decode incoming message: $message";
    };

    $self->{_last_keep_alive} = time;

    # Handle errors when they occur
    if ($msg->{error}) {
        $self->_handle_error($conn, $msg);
    }

    # Handle the initial hello
    elsif ($msg->{type} eq 'hello') {
        $self->_handle_hello($conn, $msg);
    }

    # Periodic response to our pings
    elsif ($msg->{type} eq 'pong') {
        $self->_handle_pong($conn, $msg);
    }

    # And anything else...
    else {
        $self->_handle_other($conn, $msg);
    }
}

=head2 said_hello

    method said_hello() returns Bool

Returns true after the "hello" message has been received from the server.

=head2 finished

    method finished() returns Bool

Returns true after the "finish" message has been received from the server (meaning the connection has been closed). If this is true, this object should be discarded.

=cut

sub said_hello { shift->{said_hello} // '' }
sub finished { shift->{finished} // '' }

sub _handle_hello {
    my ($self, $conn, $msg) = @_;

    $self->{said_hello}++;

    $self->_do(hello => $msg);
}

sub _handle_error {
    my ($self, $conn, $msg) = @_;

    carp "Error #$msg->{error}{code}: $msg->{error}{msg}"
        unless $self->{quiet};

    $self->_do(error => $msg);
}

sub _handle_pong {
    my ($self, $conn, $msg) = @_;

    $self->_do($msg->{type}, $msg);
}

sub _handle_other {
    my ($self, $conn, $msg) = @_;

    $self->_do($msg->{type}, $msg);
}

sub _handle_finish {
    my ($self, $conn) = @_;

    # Cancel the keep_alive watchdog
    undef $self->{keep_alive};

    $self->{finished}++;

    $self->_do('finish');

    $self->start unless $self->{closed};
}

=head2 close

    method close()

This closes the WebSocket connection to the Slack RTM API.

=cut

sub close {
    my ($self) = @_;
    $self->{closed}++;
    $self->{conn}->close;
}

=head1 CAVEATS

This is a low-level API. Therefore, this only aims to handle the basic message
handling. You must make sure that any messages you send to Slack are formatted
correctly. You must make sure any you receive are handled appropriately. Be sure
to read the Slack documentation basic message formatting, attachment formatting,
rate limits, etc.

1;
