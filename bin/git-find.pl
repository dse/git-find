#!/usr/bin/env perl
use warnings;
use strict;
use File::Find qw(find);
use IO::Handle;
use Fcntl;
use Term::ANSIColor;
use IO::Select;
use Scalar::Util qw(refaddr);
use List::Util qw(all any);
use Getopt::Long;
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);

our $verbose = 0;
our $list;
our $inline;
our @command;
our @exclude;
our $exitCode = 0;
our @failures;
our $quiet = 0;
our $width;
our @include;
our $follow;

our $TTY;
open($TTY, '>', '/dev/tty') or undef $TTY;
$TTY->autoflush(1) if defined $TTY;

our $COLS = 0 + `tput cols`;
undef $COLS if !$COLS;

main();

sub main {
    Getopt::Long::Configure('bundling', 'gnu_compat', 'no_ignore_case', 'no_permute');
    Getopt::Long::GetOptions(
        'include=s' => sub {
            if ($_[1] =~ m{^/(.*)/$}) {
                my $regexp = qr{\Q$1\E};
                push(@include, $regexp);
            } else {
                push(@include, $_[1]);
            }
        },
        'exclude=s' => sub {
            if ($_[1] =~ m{^/(.*)/$}) {
                my $regexp = qr{\Q$1\E};
                push(@exclude, $regexp);
            } else {
                push(@exclude, $_[1]);
            }
        },
        'follow'      => \$follow,
        'l|list'      => \$list,
        'v|verbose+'  => \$verbose,
        'i|inline'    => sub { $inline = 1; $quiet = 0; },
        'q|quiet'     => sub { $quiet += 1; $inline = 0; },
        'w|width=i'   => \$width,
    ) or die();

    while (scalar @ARGV) {
        my $arg = shift(@ARGV);
        last if $arg eq ';;';
        push(@command, $arg);
    }
    $list = 1 if !scalar @command;

    my @findArguments = @ARGV;
    push(@findArguments, '.') if !scalar @findArguments;

    find({ follow_skip => $follow, wanted => \&wanted }, @findArguments);
    print $TTY ("\r\e[K") if $quiet == 1 && defined $TTY;

    if (scalar @failures) {
        warn("The following repositories had issues:\n");
        foreach my $failure (@failures) {
            printf STDERR ("    %s\n", $failure->{name});
            my $stderr = $failure->{stderr};
            if ($stderr =~ m{\S}) {
                $stderr =~ s{\R\s*\z}{};
                $stderr .= "\n" if $stderr ne '';
                $stderr =~ s{^}{    >   }gm;
                printf STDERR $stderr;
            }
        }
    }
    exit($exitCode);
}

sub wanted {
    my @stat = lstat($_);
    return if !scalar(@stat);
    @stat = stat($_) if -l _;   # symlink target
    return unless -d _;         # if symlink then symlink target
    my $filename = $_;
    return $File::Find::prune = 1 if $_ eq 'node_modules';
    if (scalar @exclude) {
        my $excluded = exclude_filename($File::Find::name, @exclude);
        return $File::Find::prune = 1 if $excluded;
    }
    if (scalar @include) {
        my $included = include_filename($File::Find::name, @include);
        return $File::Find::prune = 1 if !$included;
    }
    if (-d "$_/.git") {
        if ($list) {
            print($File::Find::name, "\n");
        } else {
            runCmd($_, $File::Find::name);
        }
        return $File::Find::prune = 1;
    }
}

sub include_filename {
    my ($filename, @pattern) = @_;
    return 1 if !scalar @pattern;
    foreach my $pattern (@pattern) {
        return 1 if filename_matches_pattern($filename, $pattern);
    }
    return 0;
}
sub exclude_filename {
    my ($filename, @pattern) = @_;
    return 0 if !scalar @pattern;
    foreach my $pattern (@pattern) {
        return 1 if filename_matches_pattern($filename, $pattern);
    }
    return 0;
}
sub filename_matches_pattern {
    my ($filename, $pattern) = @_;
    if (ref $pattern eq 'Regexp') {
        return $filename =~ $pattern;
    }
    return $filename eq $pattern;
}

sub inlinePrefix {
    my ($prefix, $isTTY) = @_;
    $prefix = sprintf('[%s]', $prefix);
    $prefix = sprintf('%-*s', $width - 1, $prefix) if $width;
    $prefix = msg($prefix, $isTTY) . ' ';
    return $prefix;
}

sub runCmd {
    my ($dir, $name) = @_;
    my $inlinePrefix1;
    my $inlinePrefix2;
    if (!$inline) {
        $inlinePrefix1 = inlinePrefix($name, -t 1);
        $inlinePrefix2 = inlinePrefix($name, -t 2);
        if (!$quiet) {
            print(msg("==> $name <=="), "\n");
        } elsif ($quiet == 1) {
            my $msg = "$name ...";
            if (length($msg) > ($COLS - 1)) {
                $msg = '... ' . substr($name, -($COLS - 5));
            }
            print $TTY ("\r" . colored(["green"], $msg), "\e[K") if defined $TTY;
        }
    }
    my ($stdoutRead, $stdoutWrite, $stderrRead, $stderrWrite);
    pipe($stdoutRead, $stdoutWrite) or die("pipe: $!");
    pipe($stderrRead, $stderrWrite) or die("pipe: $!");
    if ($command[0] eq 'git') {
        splice(@command, 1, 0, '--no-pager');
    }
    my $pid = fork() // die("fork: $!");
    if (!$pid) {
        chdir($dir) or die("chdir: $!");
        open(STDOUT, '>&', $stdoutWrite) or die("reopen: $!");
        open(STDERR, '>&', $stderrWrite) or die("reopen: $!");
        binmode($stdoutWrite);  # for syswrites
        binmode($stderrWrite);
        exec(@command) or die("exec failed: $!");
    }
    binmode($stdoutRead);       # for sysreads
    binmode($stderrRead);
    close($stderrWrite) or die("close: $!");
    close($stdoutWrite) or die("close: $!");
    my $select = IO::Select->new($stdoutRead, $stderrRead);
    STDOUT->autoflush(1);
    STDERR->autoflush(1);
    make_nonblocking($stdoutRead);
    make_nonblocking($stderrRead);
    my $hasStdout;
    my $hasStderr;
    my $buf1 = '';
    my $buf2 = '';
    my $hasOutput = 0;          # print "==> %s <==" once
    my $stderr = '';            # store for printing errors atexit
    my $failed;
    do {
        $! = 0;                 # clear error
        %! = ();
        my @ready = $select->can_read();
        $hasStdout = grep { refaddr($_) == refaddr($stdoutRead) } @ready;
        $hasStderr = grep { refaddr($_) == refaddr($stderrRead) } @ready;
        while ($hasStdout) {
            my $data;
            my $bytes = sysread($stdoutRead, $data, 4096);
            if (!defined $bytes) {
                last if $!{EAGAIN}; # maybe more to read later
                warn(sprintf('sysread stdout: %s %s\n', errid(), $!));
            }
            if (!$bytes) {
                if (!close($stdoutRead)) {
                    $failed = 1 if $? || (0 + $!);
                }
                $hasStdout = 0;
                $select->remove($stdoutRead);
                last;
            }
            if ($quiet == 1 && !$hasOutput++) {
                print $TTY ("\r\e[K") if defined $TTY;
                print(msg("==> $name <=="), "\n");
            }
            $buf1 .= $data;
            if ($buf1 =~ s{^.*\R}{}s) {
                print STDOUT $&;
            }
        }
        while ($hasStderr) {
            my $data;
            my $bytes = sysread($stderrRead, $data, 4096);
            if (!defined $bytes) {
                last if $!{EAGAIN}; # maybe more to read later
                warn(sprintf('sysread stderr: %s %s\n', errid(), $!));
            }
            if (!$bytes) {
                if (!close($stderrRead)) {
                    $failed = 1 if $? || (0 + $!);
                }
                $hasStderr = 0;
                $select->remove($stderrRead);
                last;
            }
            if ($quiet == 1 && !$hasOutput++) {
                print $TTY ("\r\e[K") if defined $TTY;
                print(msg("==> $name <=="), "\n");
            }
            $buf2 .= $data;
            if ($buf2 =~ s{^.*\R}{}s) {
                print STDERR $&;
            }
            $stderr .= $data;
        }
    } while ($hasStdout || $hasStderr);
    print STDOUT $buf1;
    print STDERR $buf2;
    my $exited_pid = waitpid($pid, 0);
    $failed = 1 if $exited_pid < 0 || $? || (0 + $!);
    if ($failed) {
        $exitCode = 1;
        push(@failures, { name => $name, stderr => $stderr });
    }
}

sub msg {
    my ($msg, $tty) = @_;
    $tty //= -t 1;
    return colored(['green'], $msg);
    return $msg;
}

sub errid {
    my ($errid) = grep { $!{$_} } keys %!;
    return $errid;
}

sub exit_status {
    my $exit = $? >> 8;
    my $sig  = $? & 127;
    my $dump = $? & 128;
    my $errno = 0 + $!;
    my $errid = (grep { $!{$_} } keys %!)[0];
    my $errmsg = "$!";
    return ($exit, $sig, $dump, $errno, $errid, $errmsg);
}

sub make_nonblocking {
    my ($handle) = @_;
    my $flags = fcntl($handle, F_GETFL, 0) or die("fcntl: $!");
    fcntl($handle, F_SETFL, $flags | O_NONBLOCK) or die("fcntl: $!\n");
}
