#!/usr/bin/env perl
use warnings;
use strict;
use open qw(:locale);

use File::Find qw(find);
use Cwd qw(getcwd);
use IO::Handle;
use Fcntl;
use Term::ANSIColor;
use IO::Select;
use Scalar::Util qw(refaddr);
use List::Util qw(all any);

our $verbose = 0;
our $noGit;
our $list;
our $inline;
our $noHeader;
our $noPager;
our $minDepth;
our $maxDepth;
our $pipe;
our $progress;
our @gitCommand;
our @exclude;
our $exitCode = 0;
our @failures;
our $quiet;
our $width;
our @include;
our $follow;

our $TTY;
open($TTY, '>', '/dev/tty') or undef $TTY;
if (defined $TTY) {
    $TTY->autoflush(1);
}

our $COLS = 0 + `tput cols`;
if (!$COLS) {
    undef $COLS;
}

main();

sub main {
    use Getopt::Long;
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
        'G|no-git'    => \$noGit,
        'l|list'      => \$list,
        'v|verbose+'  => \$verbose,
        'i|inline'    => sub { $inline = 1; $quiet = 0; },
        'p|progress'  => \$progress,
        'q|quiet'     => sub { $quiet = 1; $inline = 0; },
        'w|width=i'   => \$width,
        'no-header'   => \$noHeader,
        'no-pager'    => \$noPager,
    ) or die();

    while (scalar @ARGV) {
        my $arg = shift(@ARGV);
        last if ($arg eq '---');
        push(@gitCommand, $arg);
    }
    if (!scalar @gitCommand) {
        $list = 1;
    }

    my @findArguments = @ARGV;
    if (!scalar @findArguments) {
        @findArguments = ('.');
    }

    find({ follow_skip => $follow, wanted => \&wanted }, @findArguments);

    print $TTY ("\r\e[K") if $quiet && defined $TTY;

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
    if (-l _) {                 # if symlink
        @stat = stat($_);       # symlink target
    }
    return unless -d _;         # if symlink then symlink target
    my $filename = $_;
    # return if scalar @exclude && grep { $filename eq $_ } @exclude;
    return $File::Find::prune = 1 if $_ eq 'node_modules';

    if (scalar @exclude) {
        my $excluded = exclude_filename($File::Find::name, @exclude);
        if ($excluded) {
            return $File::Find::prune = 1;
        }
    }
    if (scalar @include) {
        my $included = include_filename($File::Find::name, @include);
        if (!$included) {
            return $File::Find::prune = 1;
        }
    }

    if (-d "$_/.git") {
        if ($list) {
            print($File::Find::name, "\n");
        } else {
            doTheFancyThing($_, $File::Find::name);
        }
        return $File::Find::prune = 1;
    }
}

use constant DEBUG_INCLUDE_EXCLUDE => 0;

sub include_filename {
    my ($filename, @pattern) = @_;
    warn("include_filename @_\n") if DEBUG_INCLUDE_EXCLUDE;
    if (!scalar @pattern) {
        warn("    no includes specified; including\n") if DEBUG_INCLUDE_EXCLUDE;
        return 1;
    }
    foreach my $pattern (@pattern) {
        if (filename_matches_pattern($filename, $pattern)) {
            warn("    filename matches $pattern; including\n") if DEBUG_INCLUDE_EXCLUDE;
            return 1;
        }
        warn("    filename does not match $pattern\n") if DEBUG_INCLUDE_EXCLUDE;
    }
    warn("    filename does not match any patterns; not including\n") if DEBUG_INCLUDE_EXCLUDE;
    return 0;
}

sub exclude_filename {
    my ($filename, @pattern) = @_;
    warn("exclude_filename @_\n") if DEBUG_INCLUDE_EXCLUDE;
    if (!scalar @pattern) {
        warn("    no excludes specified; not excluding\n") if DEBUG_INCLUDE_EXCLUDE;
        return 0;
    }
    foreach my $pattern (@pattern) {
        if (filename_matches_pattern($filename, $pattern)) {
            warn("    filename matches $pattern; excluding\n") if DEBUG_INCLUDE_EXCLUDE;
            return 1;
        }
        warn("    filename does not match $pattern\n") if DEBUG_INCLUDE_EXCLUDE;
    }
    warn("    filename does not match any patterns; not excluding\n") if DEBUG_INCLUDE_EXCLUDE;
    return 0;
}

sub filename_matches_pattern {
    my ($filename, $pattern) = @_;
    if (ref $pattern eq 'Regexp') {
        return $filename =~ $pattern;
    }
    return $filename eq $pattern;
}

use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use constant LINEBUF => 1;

sub doTheFancyThing {
    my ($dir, $name) = @_;
    my $stderr = '';
    my $failed;
    my $failStatus;
    my $inlinePrefixStdout = $inline ? msg("[$name]", -t 1) . " " : '';
    my $inlinePrefixStderr = $inline ? msg("[$name]", -t 2) . " " : '';
    if ($width && $inline) {
        my $pad = $width - length($name) - 2;
        $pad = $pad > 0 ? ' ' x $pad : '';
        $inlinePrefixStdout .= $pad;
        $inlinePrefixStderr .= $pad;
    }
    if (!$inline) {
        if (!$quiet) {
            print(msg("==> $name <=="), "\n");
        } else {
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
    my @cmd = (($noGit ? () : ('git', '--no-pager')), @gitCommand);
    my $pid = fork() // die("fork: $!");
    if (!$pid) {
        # child
        chdir($dir) or die("chdir: $!");
        open(STDOUT, '>&', $stdoutWrite) or die("reopen: $!");
        open(STDERR, '>&', $stderrWrite) or die("reopen: $!");
        binmode($stdoutWrite);  # on account of we're doing sysreads
        binmode($stderrWrite);  # ditto
        exec(@cmd) or die("exec failed: $!");
    }
    binmode($stdoutRead);       # on account of we're doing sysreads
    binmode($stderrRead);       # ditto
    # parent
    close($stderrWrite) or die("close: $!");
    close($stdoutWrite) or die("close: $!");
    my $select = IO::Select->new($stdoutRead, $stderrRead);
    STDOUT->autoflush(1);
    STDERR->autoflush(1);

    # handles need to be non-blocking on account of select tells us which
    # fds are ready to read without blocking.
    {
        my $flags;
        $flags = fcntl($stdoutRead, F_GETFL, 0) or die("fcntl: $!");
        fcntl($stdoutRead, F_SETFL, $flags | O_NONBLOCK) or die("fcntl: $!\n");
        $flags = fcntl($stderrRead, F_GETFL, 0) or die("fcntl: $!");
        fcntl($stderrRead, F_SETFL, $flags | O_NONBLOCK) or die("fcntl: $!\n");
    }

    my $hasStdout;
    my $hasStderr;
    my $buf1 = new My::LineBuf;
    my $buf2 = new My::LineBuf;
    $buf1->{prefix} = $inlinePrefixStdout if $inline;
    $buf2->{prefix} = $inlinePrefixStderr if $inline;

    my $printed = 0;
    do {
        $! = 0;
        my @ready = $select->can_read();
        $hasStdout = grep { refaddr($_) == refaddr($stdoutRead) } @ready;
        $hasStderr = grep { refaddr($_) == refaddr($stderrRead) } @ready;
        while ($hasStdout) {
            my $data;
            my $bytes = sysread($stdoutRead, $data, 4096);
            if (!defined $bytes) {
                last if ($!{EAGAIN}); # there'll be more bytes to read i guess
                my $errid = errid();
                warn("sysread stdout: $errid $!\n");
            }
            if (!$bytes) {
                if (!close($stdoutRead)) {
                    my ($exit, $sig, $dump, $errno) = exit_status();
                    if ($exit || $sig || $dump || $errno) {
                        $failed = 1;
                    }
                }
                $hasStdout = 0;
                $select->remove($stdoutRead);
                last;
            }
            if ($quiet && !$printed++) {
                print $TTY ("\r\e[K") if defined $TTY;
                print(msg("==> $name <=="), "\n");
            }
            print STDOUT $buf1->feed($data);
        }
        while ($hasStderr) {
            my $data;
            my $bytes = sysread($stderrRead, $data, 4096);
            if (!defined $bytes) {
                last if ($!{EAGAIN}); # there'll be more bytes to read i guess
                my $errid = errid();
                warn("sysread stderr: $errid $!\n");
            }
            if (!$bytes) {
                if (!close($stderrRead)) {
                    my ($exit, $sig, $dump, $errno) = exit_status();
                    if ($exit || $sig || $dump || $errno) {
                        $failed = 1;
                    }
                }
                $hasStderr = 0;
                $select->remove($stderrRead);
                last;
            }
            if ($quiet && !$printed++) {
                print $TTY ("\r\e[K") if defined $TTY;
                print(msg("==> $name <=="), "\n");
            }
            print STDERR $buf2->feed($data);
            $stderr .= $data;
        }
    } while ($hasStdout || $hasStderr);
    print STDOUT $buf1->finish();
    print STDERR $buf2->finish();
    my $retval = waitpid($pid, 0);
    my ($exit, $sig, $dump, $errno) = exit_status();
    if ($exit || $sig || $dump || $errno) {
        $failed = 1;
    }
    if ($failed) {
        $exitCode = 1;
        push(@failures, { name => $name, stderr => $stderr });
    }
    return $retval;
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

package My::LineBuf {
    sub new {
        my ($class, %args) = @_;
        return bless({ %args, data => '' }, $class);
    }
    sub feed {
        my ($self, $data) = @_;
        $self->{data} .= $data;
        my $index = rindex($self->{data}, "\n");
        if ($index == -1) {
            return '';
        }
        if ($index == length($self->{data}) - 1) {
            my $data = $self->{data};
            $self->{data} = '';
            return $self->string($data);
        }
        $data = substr($self->{data}, 0, $index + 1);
        $self->{data} = substr($self->{data}, $index + 1);
        return $self->string($data);
    }
    sub finish {
        my ($self) = @_;
        my $data = $self->{data};
        $self->{data} = '';
        return '' if !length $data;
        $data .= "\n" if substr($data, -1) ne "\n";
        return $self->string($data);
    }
    sub string {
        my ($self, $data) = @_;
        my $prefix = $self->{prefix};
        $data =~ s{^}{$prefix}gm if defined $prefix && $prefix ne '';
        return $data;
    }
}