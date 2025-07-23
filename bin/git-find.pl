#!/usr/bin/env perl
use warnings;
use strict;
use File::Find qw(find);
use IO::Handle;
use Fcntl;
use Term::ANSIColor;
use IO::Select;
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
use Git::Find qw(dumper finalize_rules indent);
use Git::Find::Run qw(run_cmd see_error_log);

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
our $indent = 0;

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
    'indent=i' => \$indent,
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
    indent       => $indent,
};

# any --include or --exclude of the form /xxx/ becomes a regexp.
finalize_rules(@rules);

our $exit_code = 0;

find({
    wanted => \&wanted,
    preprocess => sub { return sort @_; },
}, @find_arguments);

exit($exit_code);

###############################################################################

sub wanted {
    local $Git::Find::Run::inline = $options->{inline};
    local $Git::Find::Run::quiet = $options->{quiet};
    local @Git::Find::Run::cmd = @cmd;
    local $Git::Find::Run::plain = $options->{plain};
    local $Git::Find::Run::width = $options->{width};
    local $Git::Find::Run::indent = $options->{indent};

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

END {
    see_error_log();
}
