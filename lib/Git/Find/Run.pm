package Git::Find::Run;
use warnings;
use strict;
use feature qw(state);

use Fcntl;
use Term::ANSIColor;
use Scalar::Util qw(refaddr);
use File::Path qw(make_path);
use File::Temp qw(tempfile);

use base 'Exporter';
our @EXPORT = qw(run_cmd see_error_log);
our %EXPORT_TAGS = qw();

our $inline;
our $quiet;
our @cmd;
our $plain;
our $log_dir;
our $old_log_dir;
our $log_symlink;

BEGIN {
    my $state_home = $ENV{XDG_STATE_HOME} // "$ENV{HOME}/.local/state";
    $log_dir = "${state_home}/git-find/log";
    $old_log_dir = "git-find-logs";
    $log_symlink = "${log_dir}/latest.log";
}

sub run_cmd {
    my ($dir, $name) = @_;
    my @saved_autoflush = set_autoflush();

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
        my $fh = open_error_log();
        printf $fh ("==> %s <== [%s]\n", $name, scalar(localtime($start)));
        print $fh $log;
        print $fh $err;
    }

    restore_autoflush(@saved_autoflush);
}

sub set_autoflush {
    my $stdout_autoflush;
    my $stderr_autoflush;
    my $select = select(STDOUT);
    $stdout_autoflush = $|;
    $| = 1;
    select(STDERR);
    $stderr_autoflush = $|;
    $| = 1;
    select($select);
    return ($stdout_autoflush, $stderr_autoflush) if wantarray;
    return [$stdout_autoflush, $stderr_autoflush];
}

sub restore_autoflush {
    my ($stdout_autoflush, $stderr_autoflush) = @_;
    my $select = select(STDOUT);
    $| = $stdout_autoflush;
    select(STDERR);
    $| = $stderr_autoflush;
    select($select);
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

1;
