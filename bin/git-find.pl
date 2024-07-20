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

our $log_dir;
our $old_log_dir;
our $log_symlink;
{
    my $state_home = $ENV{XDG_STATE_HOME} // "$ENV{HOME}/.local/state";
    $log_dir = "${state_home}/git-find/log";
    $old_log_dir = "git-find-logs";
    $log_symlink = "${log_dir}/latest.log";
}

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
our @failures;
our $width;
our @includes;
our $quiet = 0;
our $inline = 0;
our $cwd;
our $plain;

Getopt::Long::Configure('gnu_getopt', 'no_permute', 'no_ignore_case');
Getopt::Long::GetOptions(
    'include=s' => \@includes,
    'exclude=s' => \@excludes,
    'l|list' => \$list,
    'w|width=i' => \$width,
    'q|quiet+' => \$quiet,
    'i|inline+' => \$inline,
    'C|cwd=s' => \$cwd,
    'p|plain' => \$plain,
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

# any --include or --exclude of the form /xxx/ becomes a regexp.
@includes = map { m{^/(.*)/$} ? qr{\Q$1\E} : $_ } @includes;
@excludes = map { m{^/(.*)/$} ? qr{\Q$1\E} : $_ } @excludes;

# @cmd will contain arguments before \;\;
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

# arguments after \;\; become starting points for find.
my @find_arguments = @ARGV;
if (defined $cwd) {
    push(@find_arguments, $cwd) if !scalar @find_arguments;
} else {
    push(@find_arguments, '.') if !scalar @find_arguments;
}

$SIG{INT} = sub {
    see_error_log();
    exit();
};
$SIG{QUIT} = sub {
    see_error_log();
    exit();
};

our $exit_code = 0;

find({ wanted => \&wanted }, @find_arguments);

exit($exit_code);

###############################################################################

sub wanted {
    my @stat = lstat($_);
    return if !scalar(@stat);
    @stat = stat($_) if -l _ && $_ eq '.'; # only follow symlink if it's a target you specified
    return unless -d _;         # if symlink then check symlink target
    my $filename = $_;
    return $File::Find::prune = 1 if $_ eq 'git-find-logs';
    return $File::Find::prune = 1 if $_ eq 'node_modules';
    return $File::Find::prune = 1 if $_ eq 'vendor' && (-e 'composer.lock' || -e 'composer.json');
    foreach my $pattern (@excludes) {
        return $File::Find::prune = 1 if ref $pattern eq 'RegExp' && $_ =~ $pattern;
        return $File::Find::prune = 1 if ref $pattern eq ''       && $_ eq $pattern;
    }
    if (scalar @includes) {
        my $matched = 0;
        foreach my $pattern (@includes) {
            do { $matched = 1; last; } if ref $pattern eq 'RegExp' && $_ =~ $pattern;
            do { $matched = 1; last; } if ref $pattern eq ''       && $_ eq $pattern;
        }
        return $File::Find::prune = 1 if !$matched;
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
                $err .= "  sysread stdout: $!\n";
            }
            if (!$bytes) {
                if (!close($stdout_read)) {
                    if ($!) {
                        $err .= "  close stdout: $!\n";
                    }
                    if ($?) {
                        my ($exit, $sig) = ($? >> 8, $? & 127);
                        $err .= "  close stdout: exited returning $exit\n" if $exit;
                        $err .= "  close stdout: killed with signal $sig\n" if $sig;
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
                $err .= "  sysread stderr: $!\n";
            }
            if (!$bytes) {
                if (!close($stderr_read)) {
                    if ($!) {
                        $err .= "  close stderr: $!\n";
                    }
                    if ($?) {
                        my ($exit, $sig) = ($? >> 8, $? & 127);
                        $err .= "  close stderr: exited returning $exit\n" if $exit;
                        $err .= "  close stderr: killed with signal $sig\n" if $sig;
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
        $err .= "  child process not found\n";
    }
    if ($?) {
        my ($exit, $sig) = ($? >> 8, $? & 127);
        $err .= "  child exited returning $exit\n" if $exit;
        $err .= "  child killed with signal $sig\n" if $sig;
    }
    if (length($err)) {
        $exit_code = 1;
        my $fh = open_error_log();
        printf $fh ("==> %s <== [%s]\n", $name, scalar(localtime($start)));
        print $fh $log;
        print $fh $err;
    }
}

sub inline_prefix {
    my ($name, $is_tty) = @_;
    if ($plain) {
        return sprintf("%-*s ", $width, $name) if $width;
        return sprintf("%s ", $name);
    }
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
    my $line;
    if ($plain) {
        $line = sprintf("%s", $name);
    } else {
        $line = sprintf("==> %s <==", $name);
        $line = colored(['green'], $line) if $is_tty;
    }
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

our $error_log_filename;
our $symlink_valid;

sub open_error_log {
    state $fh;
    return $fh if $fh;
    log_cleanup();
    my $time = time();
    ($fh, $error_log_filename) = tempfile("${time}-XXXXXXXXXXXXXXXX",
                                          DIR => $log_dir,
                                          SUFFIX => ".log");
    if (-e $log_symlink) {
        unlink($log_symlink) or warn("$log_symlink: $!");
    }
    if (!-e $log_symlink) {
        if (symlink($error_log_filename, $log_symlink)) {
            $symlink_valid = 1;
        } else {
            warn("$log_symlink: $!");
        }
    }
    return $fh;
}

sub see_error_log {
    return if !defined $error_log_filename;
    state %printed;
    return if $printed{$error_log_filename}++;
    printf STDERR ("\nSome runs failed; see %s\n", $error_log_filename);
    if ($symlink_valid) {
        printf STDERR (  "                  aka %s\n", $log_symlink);
    }
}

sub log_cleanup {
    make_path($log_dir);
    my $dh;
    opendir($dh, $old_log_dir) or do { $! = undef; return; };
    while (defined(my $filename = readdir($dh))) {
        next if $filename eq '.' || $filename eq '..';
        my $pathname = "$old_log_dir/$filename";
        my $new_pathname = "$log_dir/$filename";
        if (!lstat($pathname)) {
            next;
        }
        if (-l _ || -p _ || -S _ || -b _ || -c _) {
            unlink($pathname);
            next;
        }
        rename($pathname, $new_pathname) or warn("$pathname => $new_pathname: $!");
    }
    closedir($dh);
    rmdir($old_log_dir);
    $! = undef;
}

END {
    see_error_log();
}
