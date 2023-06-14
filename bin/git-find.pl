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

STDOUT->autoflush(1);
STDERR->autoflush(1);

our $list;
our @cmd;
our @exclude;
our $exit_code = 0;
our @failures;
our $width;
our @include;
our $follow;

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
    # 'i|inline'    => sub { $inline = 1; $quiet = 0; },
    # 'q|quiet'     => sub { $quiet += 1; $inline = 0; },
    'w|width=i'   => \$width,
) or die();

while (scalar @ARGV) {
    my $arg = shift(@ARGV);
    last if $arg eq ';;';
    push(@cmd, $arg);
}
$list = 1 if !scalar @cmd;

my @find_arguments = @ARGV;
push(@find_arguments, '.') if !scalar @find_arguments;

find({ follow_skip => $follow, wanted => \&wanted }, @find_arguments);

if (scalar @failures) {
    print STDERR ("The following repositories had issues:\n");
    foreach my $failure (@failures) {
        printf STDERR ("    %s\n", $failure->{name});
        my $stderr = $failure->{stderr};
        if ($stderr =~ m{\S}) {
            $stderr =~ s{\R\s*\z}{};
            $stderr .= "\n" if $stderr ne '';
            $stderr =~ s{^}{    > }gm;
            printf STDERR $stderr;
        }
    }
}
exit($exit_code);

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
            run_cmd($_, $File::Find::name);
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

sub run_cmd {
    my ($dir, $name) = @_;
    warn(colored(['green'], sprintf("==> %s <==", $name)) . "\n") if -t 2;
    my ($stdoutRead, $stdoutWrite, $stderrRead, $stderrWrite);
    pipe($stdoutRead, $stdoutWrite) or die("pipe: $!");
    pipe($stderrRead, $stderrWrite) or die("pipe: $!");
    splice(@cmd, 1, 0, '--no-pager') if $cmd[0] eq 'git';
    my $pid = fork() // die("fork: $!");
    if (!$pid) {
        chdir($dir) or die("chdir: $!");
        open(STDOUT, '>&', $stdoutWrite) or die("reopen: $!");
        open(STDERR, '>&', $stderrWrite) or die("reopen: $!");
        binmode($stdoutWrite);  # for syswrites
        binmode($stderrWrite);
        exec(@cmd) or die("exec failed: $!");
    }
    binmode($stdoutRead);       # for sysreads
    binmode($stderrRead);
    close($stderrWrite) or die("close: $!");
    close($stdoutWrite) or die("close: $!");
    my $select = IO::Select->new($stdoutRead, $stderrRead);
    make_nonblocking($stdoutRead);
    make_nonblocking($stderrRead);
    my $has_stdout;
    my $has_stderr;
    my $buf1 = '';
    my $buf2 = '';
    my $has_output = 0;          # print "==> %s <==" once
    my $stderr = '';            # store for printing errors atexit
    my $failed;
    do {
        $! = 0;                 # clear error
        my @ready = $select->can_read();
        $has_stdout = grep { refaddr($_) == refaddr($stdoutRead) } @ready;
        $has_stderr = grep { refaddr($_) == refaddr($stderrRead) } @ready;
        while ($has_stdout) {
            my $data;
            my $bytes = sysread($stdoutRead, $data, 4096);
            if (!defined $bytes) {
                last if $!{EAGAIN}; # maybe more to read later
                warn("sysread stdout: $!\n");
            }
            if (!$bytes) {
                if (!close($stdoutRead)) {
                    $failed = 1 if $? || (0 + $!);
                }
                $has_stdout = 0;
                $select->remove($stdoutRead);
                last;
            }
            $buf1 .= $data;
            if ($buf1 =~ s{^.*\R}{}s) {
                print STDOUT $&;
            }
        }
        while ($has_stderr) {
            my $data;
            my $bytes = sysread($stderrRead, $data, 4096);
            if (!defined $bytes) {
                last if $!{EAGAIN}; # maybe more to read later
                warn("sysread stderr: $!\n");
            }
            if (!$bytes) {
                if (!close($stderrRead)) {
                    $failed = 1 if $? || (0 + $!);
                }
                $has_stderr = 0;
                $select->remove($stderrRead);
                last;
            }
            $buf2 .= $data;
            if ($buf2 =~ s{^.*\R}{}s) {
                print STDERR $&;
            }
            $stderr .= $data;
        }
    } while ($has_stdout || $has_stderr);
    print STDOUT $buf1;
    print STDERR $buf2;
    my $exited_pid = waitpid($pid, 0);
    $failed = 1 if $exited_pid < 0 || $? || (0 + $!);
    if ($failed) {
        $exit_code = 1;
        push(@failures, { name => $name, stderr => $stderr });
    }
}

sub make_nonblocking {
    my ($handle) = @_;
    my $flags = fcntl($handle, F_GETFL, 0) or die("fcntl: $!");
    fcntl($handle, F_SETFL, $flags | O_NONBLOCK) or die("fcntl: $!\n");
}
