package AnyEvent::SlackRTM;

use v5.14;

# ABSTRACT: AnyEvent module for interacting with the Slack RTM API

use AnyEvent;
use AnyEvent::WebSocket::Client 0.12;
use Carp;
use Furl;
use JSON;
use Try::Tiny;

our $START_URL = 'https://slack.com/api/rtm.start';

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

B<Somewhat Experimental:> The API here is not set in stone yet, so watch for surprises if you upgrade.

B<Disclaimer:> Note also that this API is subject to rate limits and any service limitations and fees associated with your Slack service. Please make sure you understand those limitations before using this library.

=head1 METHODS

=head2 new

    method new($token)

Constructs a L<AnyEvent::SlackRTM> object and returns it.

The C<$token> option is the access token from Slack to use. This may be either of the following type of tokens:

=over

=item *

L<User Token|https://api.slack.com/tokens>. This is a token to perform actions on behalf of a user account.

=item *

L<Bot Token|https://slack.com/services/new/bot>. If you configure a bot integration, you may use the access token on the bot configuration page to use this library to act on behalf of the bot account. Bot accounts may not have the same features as a user account, so please be sure to read the Slack documentation to understand any differences or limitations.

=back

=cut

sub new {
    my ($class, $token) = @_;

    my $client = AnyEvent::WebSocket::Client->new;

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

=cut

sub start {
    my $self = shift;

    use vars qw( $VERSION );
    $VERSION //= '*-devel';

    my $furl = Furl->new(
        agent => "AnyEvent::SlackRTM/$VERSION",
    );

    my $res = $furl->get($START_URL . '?token=' . $self->{token});
    croak "unable to start, Slack call failed: $res->{code} $res->{message}"
        unless $res->{code} =~ m/^2/;
    my $start = decode_json($res->content);

    my $ok  = $start->{ok};
    croak "unable to start, Slack returned an error: $start->{error}"
    unless $ok;

    # Store this stuff in case we want it
    $self->{metadata} = $start;

    my $wss    = $start->{url};
    my $client = $self->{client};

    $client->connect($wss)->cb(sub {
            my $client = shift;

            my $conn = try {
                $client->recv;
            }
            catch {
                die $_;
            };

            $self->{started}++;
            $self->{id} = 1;

            $self->{conn} = $conn;

            $self->{pinger} = AnyEvent->timer(
                after    => 60,
                interval => 60,
                cb       => sub { $self->ping },
            );

            $conn->on(each_message => sub { $self->_handle_incoming(@_) });
            $conn->on(finish => sub { $self->_handle_finish(@_) });
        });
}

=head2 metadata

    method metadata() returns HashRef

The initial connection is established after calling the L<rtm.start|https://api.slack.com/methods/rtm.start> method on the web API. This returns some useful information, which is available here.

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

    method on($type, \&cb)

This sets up a callback handler for the named message type. The available message types are available in the L<Slack Events|https://api.slack.com/events> documentation. Only one handler may be setup for each event. Setting a new handler with this method will replace any previously set handler. Events with no handler will be ignored/unhandled.

=cut

sub on {
    my ($self, $type, $cb) = @_;
    $self->{registry}{$type} = $cb;
}

=head2 off

    method off($type)

This removes the handler for the named C<$type>.

=cut

sub off {
    my ($self, $type) = @_;
    delete $self->{registry}{$type};
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

    my $msg = decode_json($raw->body);

    # Handle the initial hello
    if ($msg->{type} eq 'hello') {
        $self->_handle_hello($conn, $msg);
    }
    elsif ($msg->{type} eq 'error') {
        $self->_handle_error($conn, $msg);
    }
    elsif ($msg->{type} eq 'pong') {
        $self->_handle_pong($conn, $msg);
    }
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

    # Cancel the pinger
    undef $self->{pinger};

    $self->{finished}++;

    $self->_do('finish');
}

=head2 close

    method close()

This closes the WebSocket connection to the Slack RTM API.

=cut

sub close { shift->{conn}->close }

1;
