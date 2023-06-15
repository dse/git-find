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
our @excludes;
our $exit_code = 0;
our @failures;
our $width;
our @includes;
our $follow;
our $quiet = 0;
our $inline = 0;

Getopt::Long::Configure('gnu_getopt', 'no_permute');
Getopt::Long::GetOptions(
    'include=s' => \@includes,
    'exclude=s' => \@excludes,
    'follow' => \$follow,
    'l|list' => \$list,
    'w|width=i' => \$width,
    'q|quiet+' => \$quiet,
    'i|inline+' => \$inline,
) or die();

@includes = map { m{^/(.*)/$} ? qr{\Q$1\E} : $_ } @includes;
@excludes = map { m{^/(.*)/$} ? qr{\Q$1\E} : $_ } @excludes;

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
    print STDERR ("The following repositories had failures:\n");
    foreach my $failure (@failures) {
        printf STDERR ("    %s\n", $failure->{name});
        my $stderr = $failure->{stderr};
        if ($stderr =~ m{\S}) {
            $stderr =~ s{\R\s*\z}{};
            $stderr .= "\n" if $stderr ne '';
            $stderr =~ s{^(?=.)}{    > }gm;
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
    return $File::Find::prune = 1 if $_ eq 'vendor' && (-e 'composer.lock' || -e 'composer.json');
    return $File::Find::prune = 1 if excludes_filename($File::Find::name, @excludes);
    return $File::Find::prune = 1 if includes_filename($File::Find::name, @includes);
    if (-d "$_/.git") {
        if ($list) {
            print($File::Find::name, "\n");
        } else {
            run_cmd($_, $File::Find::name);
        }
        return $File::Find::prune = 1;
    }
}

sub includes_filename {
    my ($filename, @pattern) = @_;
    return 1 if !scalar @pattern;
    foreach my $pattern (@pattern) {
        return 1 if filename_matches_pattern($filename, $pattern);
    }
    return 0;
}

sub excludes_filename {
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
    my $printed_header = 0;
    print_header($name, -t 1) if !$quiet && !$inline && !$printed_header++;
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
                print_header($name, -t 1) if $quiet == 1 && !$inline && !$printed_header++;
                print STDOUT prefixed($&, $name, -t 1);
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
                print_header($name, -t 1) if $quiet == 1 && !$inline && !$printed_header++;
                print STDERR prefixed($&, $name, -t 2);
            }
            $stderr .= $data;
        }
    } while ($has_stdout || $has_stderr);
    if ($buf1 ne '' || $buf2 ne '') {
        print_header($name, -t 1) if $quiet == 1 && !$inline && !$printed_header++;
        if ($buf1 ne '') {
            $buf1 .= "\n" if $buf1 !~ m{\R\z}; # make sure output ends with newline
            print STDOUT prefixed($buf1, $name, -t 1);
        }
        if ($buf2 ne '') {
            $buf2 .= "\n" if $buf2 !~ m{\R\z};
            print STDERR prefixed($buf1, $name, -t 2);
        }
    }
    my $exited_pid = waitpid($pid, 0);
    $failed = 1 if $exited_pid < 0 || $? || (0 + $!);
    if ($failed) {
        $exit_code = 1;
        push(@failures, { name => $name, stderr => $stderr });
    }
}

sub inline_prefix {
    my ($name, $is_tty) = @_;
    my $prefix = sprintf('[%s] ', $name);
    $prefix = sprintf("%-*s", $width, $prefix) if $width;
    $prefix = colored(['green'], $prefix) if $is_tty;
}

sub prefixed {
    my ($str, $name, $is_tty) = @_;
    return $str if !$inline;
    my $prefix = inline_prefix($name, $is_tty);
    $str =~ s{^(?=.)}{$prefix}gm;
    return $str;
}

sub print_header {
    my ($name, $is_tty) = @_;
    my $line = sprintf("==> %s <==", $name);
    $line = colored(['green'], $line) if $is_tty;
    print($line . "\n");
}

sub make_nonblocking {
    my ($handle) = @_;
    my $flags = fcntl($handle, F_GETFL, 0) or die("fcntl: $!");
    fcntl($handle, F_SETFL, $flags | O_NONBLOCK) or die("fcntl: $!\n");
}
