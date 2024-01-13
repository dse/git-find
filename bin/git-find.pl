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
use Config;
use feature qw(state);

my %sig_name;
my %sig_num;
{
    my @sig_name = split(' ', $Config{sig_name});
    my @sig_num = split(' ', $Config{sig_num});
    for (my $i = 0; $i < scalar @sig_name && $i < scalar @sig_num; $i += 1) {
        $sig_name{$sig_num[$i]} = $sig_name[$i];
        $sig_num{$sig_name[$i]} = $sig_num[$i];
    }
}

STDOUT->autoflush(1);
STDERR->autoflush(1);

our $list;
our @cmd;
our @excludes;
our $exit_code = 0;
our @failures;
our $width;
our @includes;
our $quiet = 0;
our $inline = 0;
our $cwd;

Getopt::Long::Configure('gnu_getopt', 'no_permute', 'no_ignore_case');
Getopt::Long::GetOptions(
    'include=s' => \@includes,
    'exclude=s' => \@excludes,
    'l|list' => \$list,
    'w|width=i' => \$width,
    'q|quiet+' => \$quiet,
    'i|inline+' => \$inline,
    'C|cwd=s' => \$cwd,
    'help' => sub { usage(); exit(0); },
) or die();

sub usage { print_usage(<<"END"); }
to run a git (or other) command in all repositories:
    git find [--include=<glob> ...] [--exclude=<glob> ...]
             [--quiet]
             [--inline] [-w, --width=<cols>]
             [git] <cmd> [<arg> ...]
to list repositories:
    git find [<options> ...] ***-l|--list***
to specify directory trees:
    git find [<options> ...] [git] <cmd> [<arg> ...] ***\\\;\\\; <dir> ...***
END

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
if (defined $cwd) {
    push(@find_arguments, $cwd) if !scalar @find_arguments;
} else {
    push(@find_arguments, '.') if !scalar @find_arguments;
}

our $error_log_filename;
sub open_error_log {
    state $fh;
    if ($fh) {
        return $fh;
    }
    make_path("./git-find-logs");
    ($fh, $error_log_filename) = tempfile("XXXXXXXXXXXXXXXX",
                                          DIR => "./git-find-logs",
                                          SUFFIX => ".log");
    return $fh;
}
sub see_error_log {
    if (defined $error_log_filename) {
        printf STDERR ("\nSome runs failed; see %s\n", $error_log_filename);
    }
}

END {
    see_error_log();
}

$SIG{INT} = sub {
    exit();
};

find({ wanted => \&wanted }, @find_arguments);

exit($exit_code);

###############################################################################

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

    my $log = '';
    my $err = '';
    my $start = time();

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
        print STDOUT prefixed($str, $name, -t 1);
        $log .= indent($str, '      > ');
    };
    my $stderr = sub {
        my $str = join('', @_);
        print STDERR prefixed($str, $name, -t 2);
        $log .= indent($str, '  !!! > ');
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
                $err .= "sysread stdout: $!\n";
            }
            if (!$bytes) {
                if (!close($stdout_read)) {
                    if ($!) {
                        $err .= "close stdout: $!\n";
                    }
                    if ($?) {
                        my ($exit, $sig) = ($? >> 8, $? & 127);
                        $err .= "close stdout: exited returning $exit\n" if $exit;
                        $err .= "close stdout: killed with signal $sig\n" if $sig;
                    }
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
                $err .= "sysread stderr: $!\n";
            }
            if (!$bytes) {
                if (!close($stderr_read)) {
                    if ($!) {
                        $err .= "close stderr: $!\n";
                    }
                    if ($?) {
                        my ($exit, $sig) = ($? >> 8, $? & 127);
                        $err .= "close stderr: exited returning $exit\n" if $exit;
                        $err .= "close stderr: killed with signal $sig\n" if $sig;
                    }
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
    if ($exited_pid == -1) {
        $err .= "child process not found\n";
    }
    if ($?) {
        my ($exit, $sig) = ($? >> 8, $? & 127);
        $err .= "child exited returning $exit\n" if $exit;
        $err .= "child killed with signal $sig\n" if $sig;
    }
    if (length($err)) {
        $exit_code = 1;
        my $fh = open_error_log;
        printf $fh ("==> %s <== [%s]\n", $name, scalar(localtime($start)));
        print $fh $log;
        print $fh $err;
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

sub indent {
    my ($str, $indent) = @_;
    $str =~ s{^(?=.)}{$indent}gms;
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

sub print_usage {
    my ($usage) = @_;
    my $TWO_STARS = qr{(?<!\*)\*\*(?!\*)};
    my $THREE_STARS = qr{(?<!\*)\*\*\*(?!\*)};
    $usage =~ s{^to .*$}
               {green($&)}ge;
    $usage =~ s{<(\S+)>}
               {!-t 1 ? $& : green(italic($1))}ge;
    $usage =~ s{${TWO_STARS}(.*?)${TWO_STARS}}
               {bold($1)}ge;
    $usage =~ s{${THREE_STARS}(.*?)${THREE_STARS}}
               {bold(blue_bg($1))}ge;
    print($usage);
}

sub vt {
    return join("", @_) if !-t 1;
    return "\e[#{" . join("", @_) . "\e[#}";
}
sub bold {
    return join("", @_) if !-t 1;
    return vt("\e[1m" . join("", @_) . "\e[22m");
}
sub italic {
    return join("", @_) if !-t 1;
    return vt("\e[3m" . join("", @_) . "\e[23m");
}
sub green {
    return join("", @_) if !-t 1;
    return vt("\e[32m" . join("", @_) . "\e[39m");
}
sub blue_bg {
    return join("", @_) if !-t 1;
    return vt("\e[44m" . join("", @_) . "\e[49m");
}
