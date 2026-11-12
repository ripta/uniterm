# Relays frames between its standard streams and a uniterm socket, so a test can hold a
# connection whose connecting process has exited while another process keeps the socket.
#
# Each input line is a command. "send HEX" writes the bytes. "read" reads one frame and prints
# "frame HEX", or "closed". "orphan" forks, the connecting process exits, and the child keeps the
# socket and prints "orphaned PID" once the parent is gone. "exec" starts perl again in the same
# process, keeping the socket open across the exec, and the new program prints "execed PID".
# "forksend HEX" forks, and the child writes the bytes while the parent stays, then prints
# "childsent PID" and waits.
#
# With "nested" after the socket path, the first process prints "root PID" and stays, a middle
# process stays under it, and the middle's child connects. "unparent" then ends the middle, so the
# connecting process is moved to launchd, and it prints "unparented PID". Each process that only
# waits gives up after 60 seconds, so a failed test leaves nothing running for long.
use strict;
use warnings;
use IO::Handle;
use Fcntl;
use Socket;

STDOUT->autoflush(1);

if (@ARGV > 1 && $ARGV[1] eq 'nested') {
    print "root $$\n";

    for (1 .. 2) {
        my $child = fork();
        die "fork: $!" unless defined $child;

        if ($child) {
            sleep 60;
            exit 0;
        }
    }
}

my $socket;

if ($ARGV[0] eq '--fd') {
    open($socket, '+<&=', $ARGV[1]) or die "fd: $!";
    print "execed $$\n";
} else {
    socket($socket, PF_UNIX, SOCK_STREAM, 0) or die "socket: $!";
    connect($socket, pack_sockaddr_un($ARGV[0])) or die "connect: $!";
    print "connected $$\n";
}

sub read_exactly {
    my ($count) = @_;
    my $buffer = '';

    while (length($buffer) < $count) {
        my $got = sysread($socket, $buffer, $count - length($buffer), length($buffer));
        return undef unless $got;
    }

    return $buffer;
}

while (my $line = <STDIN>) {
    chomp $line;
    my ($command, $argument) = split / /, $line, 2;

    if ($command eq 'send') {
        syswrite($socket, pack('H*', $argument)) or die "send: $!";
        print "sent\n";
    } elsif ($command eq 'read') {
        my $head = read_exactly(5);

        if (!defined $head) {
            print "closed\n";
            next;
        }

        my (undef, $length) = unpack('C N', $head);
        my $body = $length ? read_exactly($length) : '';

        if (!defined $body) {
            print "closed\n";
            next;
        }

        print "frame ", unpack('H*', $head . $body), "\n";
    } elsif ($command eq 'unparent') {
        my $parent = getppid();
        kill 'TERM', $parent;
        select(undef, undef, undef, 0.01) while getppid() == $parent;
        print "unparented $$\n";
    } elsif ($command eq 'exec') {
        my $flags = fcntl($socket, F_GETFD, 0) or die "fcntl: $!";
        fcntl($socket, F_SETFD, $flags & ~FD_CLOEXEC) or die "fcntl: $!";
        exec($^X, $0, '--fd', fileno($socket)) or die "exec: $!";
    } elsif ($command eq 'forksend') {
        my $child = fork();
        die "fork: $!" unless defined $child;

        if ($child == 0) {
            syswrite($socket, pack('H*', $argument)) or die "send: $!";
            print "childsent $$\n";
            sleep 60;
            exit 0;
        }
    } elsif ($command eq 'orphan') {
        my $parent = $$;
        my $child = fork();
        die "fork: $!" unless defined $child;
        exit 0 if $child;
        select(undef, undef, undef, 0.01) while getppid() == $parent;
        print "orphaned $$\n";
    }
}
