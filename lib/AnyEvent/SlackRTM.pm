package AnyEvent::SlackRTM;

use v5.14;

use AnyEvent;
use AnyEvent::WebSocket::Client 0.12;
use Carp;
use Furl;
use JSON;
use Try::Tiny;

our $START_URL = 'https://slack.com/api/rtm.start';

sub new {
    my ($class, $token) = @_;

    my $client = AnyEvent::WebSocket::Client->new;

    return bless {
        token    => $token,
        client   => $client,
        registry => {},
    }, $class;
}

sub start {
    my $self = shift;

    use vars qw( $VERSION );
    $VERSION //= '*-devel';

    my $furl = Furl->new(
        agent => "AnyEvent::SlackRTM/$VERSION",
    );

    my $res = $furl->get($START_URL . '?token=' . $self->{token});
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

            $conn->on(each_message => sub { $self->handle_incoming(@_) });
            $conn->on(finish => sub { $self->handle_finish(@_) });
        });
}

sub metadata { shift->{metadata} // {} }
sub quiet {
    my $self = shift;

    if (@_) {
        $self->{quiet} = shift;
    }

    return $self->{quiet} // '';
}

sub on {
    my ($self, $type, $cb) = @_;
    $self->{registry}{$type} = $cb;
}

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

sub ping {
    my ($self, $msg) = @_;

    $self->send({ 
        %$msg,
        type => 'ping' 
    });
}

sub handle_incoming {
    my ($self, $conn, $raw) = @_;

    my $msg = decode_json($raw->body);

    # Handle the initial hello
    if ($msg->{type} eq 'hello') {
        $self->handle_hello($conn, $msg);
    }
    elsif ($msg->{type} eq 'error') {
        $self->handle_error($conn, $msg);
    }
    elsif ($msg->{type} eq 'pong') {
        $self->handle_pong($conn, $msg);
    }
    else {
        $self->handle_other($conn, $msg);
    }
}

sub said_hello { shift->{said_hello} // '' }
sub finished { shift->{finished} // '' }

sub handle_hello {
    my ($self, $conn, $msg) = @_;

    $self->{said_hello}++;

    $self->_do(hello => $msg);
}

sub handle_error {
    my ($self, $conn, $msg) = @_;

    carp "Error #$msg->{error}{code}: $msg->{error}{msg}"
}

sub handle_pong {
    my ($self, $conn, $msg) = @_;

    $self->_do($msg->{type}, $msg);
}

sub handle_other {
    my ($self, $conn, $msg) = @_;

    $self->_do($msg->{type}, $msg);
}

sub handle_finish {
    my ($self, $conn) = @_;

    # Cancel the pinger
    undef $self->{pinger};

    $self->{finished}++;

    $self->_do('finish');
}

sub close { shift->{conn}->close }

1;
