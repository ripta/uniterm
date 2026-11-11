#!/usr/bin/perl
# A synthetic exec driver for uniterm's tests. Usage:
#
#   driver.pl MODE TYPE SCHEMA [ARGUMENTS...]
#
# TYPE and SCHEMA go into the driver's hello. MODE picks how the driver behaves or misbehaves, so
# each test names the one behavior it proves.
use strict;
use warnings;
use JSON::PP;

$| = 1;
STDERR->autoflush(1);

my ($mode, $type, $schema, @rest) = @ARGV;
my $json = JSON::PP->new->canonical->allow_nonref;
my $next_id = 1;

sub send_message { print $json->encode($_[0]), "\n"; }

sub hello {
    my ($protocol, $schema_version) = @_;
    send_message({type => "hello", protocol => $protocol + 0, applet => $type,
                  schema => $schema_version + 0});
}

sub command {
    my ($name, $arguments) = @_;
    send_message({type => "command", id => $next_id++, name => $name,
                  arguments => $arguments // {}});
}

# Reads the app's hello first, the way a real driver checks it before it sends anything.
sub read_app_hello {
    my $line = <STDIN>;
    return undef unless defined $line;
    return $json->decode($line);
}

# Answers events and logs every line from the app to stderr, until stdin ends.
sub serve {
    while (my $line = <STDIN>) {
        chomp $line;
        my $message = $json->decode($line);
        print STDERR "got $message->{type}", (defined $message->{name} ? " $message->{name}" : ""),
            (defined $message->{error} ? " $message->{error}{code}" : ""), "\n";

        if ($message->{type} eq "event" && $message->{name} eq "advance-requested") {
            command("show-slide", {index => $message->{data}{from} + 1});
        }
    }
}

if ($mode eq "script") {
    read_app_hello();
    hello(1, $schema);
    print STDERR "driver ready\n";
    command($_->{name}, $_->{arguments}) for map { $json->decode($_) } @rest;
    serve();
} elsif ($mode eq "env") {
    my ($file) = @rest;
    read_app_hello();
    hello(1, $schema);
    open(my $out, ">", $file) or die "cannot write $file: $!";
    print $out "cwd=", `/bin/pwd`;
    print $out "$_=$ENV{$_}\n" for sort keys %ENV;
    close($out);
    serve();
} elsif ($mode eq "hello-protocol") {
    read_app_hello();
    hello($rest[0], $schema);
    command("set-deck", {titles => ["skew"]});
    serve();
} elsif ($mode eq "hello-schema") {
    read_app_hello();
    hello(1, $rest[0]);
    command("set-deck", {titles => ["skew"]});
    serve();
} elsif ($mode eq "command-first") {
    command("set-deck", {titles => ["early"]});
    hello(1, $schema);
    serve();
} elsif ($mode eq "refuse") {
    my $app = read_app_hello();
    send_message({type => "error",
                  error => {code => "unsupported-version",
                            message => "this driver needs exec protocol 9, not $app->{protocol}"}});
    command("set-deck", {titles => ["refused"]});
    exit 3;
} elsif ($mode eq "malformed") {
    read_app_hello();
    hello(1, $schema);
    print "this is not json\n";
    serve();
} elsif ($mode eq "partial") {
    read_app_hello();
    hello(1, $schema);
    print '{"type":"command","id":1,"name":"set-de';
    exit 0;
} elsif ($mode eq "long-line") {
    read_app_hello();
    hello(1, $schema);
    print "x" x (2 * 1024 * 1024);
    sleep 60;
} elsif ($mode eq "flood") {
    read_app_hello();
    hello(1, $schema);
    while (1) { command("status", {}); }
} elsif ($mode eq "stall") {
    read_app_hello();
    hello(1, $schema);
    print STDERR "stalling\n";
    sleep 600;
} elsif ($mode eq "stderr-flood") {
    read_app_hello();
    hello(1, $schema);
    print STDERR "flood line $_\n" for 1 .. 100000;
    # The pause lets the app drain the bounded ingress, so the last line is not one of the dropped.
    select(undef, undef, undef, 0.5);
    print STDERR "flood done\n";
    serve();
} elsif ($mode eq "ignore-term") {
    $SIG{TERM} = "IGNORE";
    read_app_hello();
    hello(1, $schema);
    sleep 600 while 1;
} elsif ($mode eq "grandchild") {
    # A background child in the driver's group that ignores SIGTERM and holds stdout open.
    my ($file) = @rest;
    read_app_hello();
    my $child = fork();
    if ($child == 0) {
        $SIG{TERM} = "IGNORE";
        sleep 600 while 1;
        exit 0;
    }
    open(my $out, ">", $file) or die "cannot write $file: $!";
    print $out "$child\n";
    close($out);
    hello(1, $schema);
    serve();
} elsif ($mode eq "exit") {
    read_app_hello();
    hello(1, $schema);
    exit($rest[0] // 0);
} elsif ($mode eq "silent") {
    1 while <STDIN>;
} else {
    die "unknown mode $mode\n";
}
