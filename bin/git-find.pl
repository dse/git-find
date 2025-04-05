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
use Data::Dumper qw(Dumper);

use lib dirname(__FILE__) . "/../lib";
use Git::Find qw(dumper finalize_rules indent make_nonblocking);
use Git::Find::Run qw(run_cmd);

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
our @failures;
our $width;
our $quiet = 0;
our $inline = 0;
our $cwd;
our $plain;

our @rules;
our $has_includes;

Getopt::Long::Configure('gnu_getopt', 'no_permute', 'no_ignore_case');
Getopt::Long::GetOptions(
    'include=s' => sub {
        push(@rules, { type => 'include', pattern => $_[1] });
        $has_includes = 1;
    },
    'exclude=s' => sub {
        push(@rules, { type => 'exclude', pattern => $_[1] });
    },
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
finalize_rules(@rules);

# @Cmd will contain arguments before \;\;
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

my $options = {
    list         => $list,
    cmd          => \@cmd,
    width        => $width,
    quiet        => $quiet,
    inline       => $inline,
    cwd          => $cwd,
    plain        => $plain,
    rules        => \@rules,
    has_includes => $has_includes,
};

our $exit_code = 0;

find({ wanted => \&wanted }, @find_arguments);

exit($exit_code);

###############################################################################

sub wanted {
    local $Git::Find::Run::inline = $options->{inline};
    local $Git::Find::Run::quiet = $options->{quiet};
    local @Git::Find::Run::cmd = @cmd;

    my @stat = lstat($_);
    return if !scalar(@stat);
    @stat = stat($_) if -l _ && $_ eq '.'; # only follow symlink if it's a target you specified
    return unless -d _;         # if symlink then check symlink target
    my $filename = $_;
    return $File::Find::prune = 1 if $_ eq 'git-find-logs';
    return $File::Find::prune = 1 if $_ eq 'node_modules';
    return $File::Find::prune = 1 if $_ eq 'vendor' && (-e 'composer.lock' || -e 'composer.json');
    my $match = $has_includes ? 0 : 1;
    foreach my $rule (@rules) {
        my $pattern = $rule->{pattern};
        my $type = $rule->{type};
        my $this_match = 0;
        if (ref $pattern eq 'Regexp' && $_ =~ $pattern) {
            $this_match = 1;
        } elsif (ref $pattern eq '' && $_ eq $pattern) {
            $this_match = 1;
        }
        next if !$this_match;
        $match = ($type eq 'include') ? 1 : 0;
    }
    if (!$match) {
        return $File::Find::prune = 1;
    }
    if (-d "$_/.git") {
        if ($list) {
            print($File::Find::name, "\n");
        } else {
            run_cmd($_, $File::Find::name);
            if ($?) {
                $exit_code = 1;
            }
        }
        return $File::Find::prune = 1;
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
