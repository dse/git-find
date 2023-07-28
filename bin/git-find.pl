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
use File::Path qw(make_path);
use File::Temp qw(tempfile);
use File::Spec::Functions qw(abs2rel);
use File::Basename qw(dirname);

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

Getopt::Long::Configure('gnu_getopt', 'no_permute', 'no_ignore_case');
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
if (scalar @cmd) {
    splice(@cmd, 1, 0, '--no-pager') if $cmd[0] eq 'git';
} else {
    $list = 1;
}

my @find_arguments = @ARGV;
push(@find_arguments, '.') if !scalar @find_arguments;

find({ follow_skip => $follow, wanted => \&wanted }, @find_arguments);

if (scalar @failures) {
    make_path("./git-find-logs");
    my ($fh, $filename) = tempfile("XXXXXXXXXXXXXXXX",
                                   DIR => "./git-find-logs",
                                   SUFFIX => ".log");
    print STDERR ("The following repositories had failures:\n");
    foreach my $failure (@failures) {
        printf STDERR ("    %s\n", $failure->{name});
        printf $fh ("==> %s <== [%s]\n", $failure->{name}, scalar(localtime($failure->{start})));
        foreach my $log (@{$failure->{logs}}) {
            my $str = $log->[0];
            my $indent = $log->[1] == 1 ? '  <OUT> ' : '  <ERR> ';
            $str =~ s{^(?=.)}{$indent}gms;
            print $fh $str;
        }
    }
    my $see_file = $filename;
    print STDERR ("See $see_file for details.\n");
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
    return $File::Find::prune = 1 if !includes_filename($File::Find::name, @includes);
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
    return any { filename_matches_pattern($filename, $_) } @pattern;
}

sub excludes_filename {
    my ($filename, @pattern) = @_;
    return 0 if !scalar @pattern;
    return any { filename_matches_pattern($filename, $_) } @pattern;
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
    my @logs;
    my @stdout;
    my @stderr;
    my $log = {
        start => time(),
        dir => $dir,
        name => $name,
        logs => \@logs,
        stdout => \@stdout,
        stderr => \@stderr,
    };
    my $printed_header = 0;
    print_header($name, -t 1) if !$quiet && !$inline && !$printed_header++;
    my ($stdout_read, $stdout_write, $stderr_read, $stderr_write);
    pipe($stdout_read, $stdout_write) or die("pipe: $!");
    pipe($stderr_read, $stderr_write) or die("pipe: $!");
    my $pid = fork() // die("fork: $!");
    if (!$pid) {
        chdir($dir) or die("chdir: $!");
        open(STDOUT, '>&', $stdout_write) or die("reopen: $!");
        open(STDERR, '>&', $stderr_write) or die("reopen: $!");
        binmode($stdout_write);  # for syswrites
        binmode($stderr_write);
        exec(@cmd) or die("exec failed: $!");
    }
    binmode($stdout_read);       # for sysreads
    binmode($stderr_read);
    close($stderr_write) or die("close: $!");
    close($stdout_write) or die("close: $!");
    my $select = IO::Select->new($stdout_read, $stderr_read);
    make_nonblocking($stdout_read);
    make_nonblocking($stderr_read);
    my $has_stdout;
    my $has_stderr;
    my $buf_stdout = '';
    my $buf_stderr = '';
    my $stdout = sub {
        my $str = join('', @_);
        push(@logs, [$str, 1]);
        push(@stdout, $str);
        print STDOUT prefixed($str, $name, -t 1);
    };
    my $stderr = sub {
        my $str = join('', @_);
        push(@logs, [$str, 2]);
        push(@stderr, $str);
        print STDERR prefixed($str, $name, -t 2);
    };
    # my $stderr = '';            # store for printing errors atexit
    my $failed;
    do {
        $! = 0;                 # clear error
        my @ready = $select->can_read();
        $has_stdout = grep { refaddr($_) == refaddr($stdout_read) } @ready;
        $has_stderr = grep { refaddr($_) == refaddr($stderr_read) } @ready;
        while ($has_stdout) {
            my $data;
            my $bytes = sysread($stdout_read, $data, 4096);
            if (!defined $bytes) {
                last if $!{EAGAIN}; # maybe more to read later
                warn("sysread stdout: $!\n");
            }
            if (!$bytes) {
                if (!close($stdout_read)) {
                    $failed = 1 if $? || (0 + $!);
                }
                $has_stdout = 0;
                $select->remove($stdout_read);
                last;
            }
            $buf_stdout .= $data;
            if ($buf_stdout =~ s{^.*\R}{}s) {
                print_header($name, -t 1) if $quiet == 1 && !$inline && !$printed_header++;
                &$stdout($&);
            }
        }
        while ($has_stderr) {
            my $data;
            my $bytes = sysread($stderr_read, $data, 4096);
            if (!defined $bytes) {
                last if $!{EAGAIN}; # maybe more to read later
                warn("sysread stderr: $!\n");
            }
            if (!$bytes) {
                if (!close($stderr_read)) {
                    $failed = 1 if $? || (0 + $!);
                }
                $has_stderr = 0;
                $select->remove($stderr_read);
                last;
            }
            $buf_stderr .= $data;
            if ($buf_stderr =~ s{^.*\R}{}s) {
                print_header($name, -t 1) if $quiet == 1 && !$inline && !$printed_header++;
                &$stderr($&);
            }
        }
    } while ($has_stdout || $has_stderr);
    if ($buf_stdout ne '' || $buf_stderr ne '') {
        print_header($name, -t 1) if $quiet == 1 && !$inline && !$printed_header++;
        if ($buf_stdout ne '') {
            $buf_stdout .= "\n" if $buf_stdout !~ m{\R\z}; # make sure output ends with newline
            &$stdout($buf_stdout);
        }
        if ($buf_stderr ne '') {
            $buf_stderr .= "\n" if $buf_stderr !~ m{\R\z};
            &$stderr($buf_stderr);
        }
    }
    my $exited_pid = waitpid($pid, 0);
    $failed = 1 if $exited_pid < 0 || $? || (0 + $!);
    $log->{end} = time();
    if ($failed) {
        $exit_code = 1;
        push(@failures, $log);
    }
}

sub inline_prefix {
    my ($name, $is_tty) = @_;
    my $prefix = sprintf('[%s] ', $name);
    $prefix = sprintf("%-*s", $width, $prefix) if $width;
    $prefix = colored(['green'], $prefix) if $is_tty;
    return $prefix;
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
