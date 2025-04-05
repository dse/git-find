package Git::Find;
use warnings;
use strict;
use Data::Dumper qw();
use List::Util qw(any);
use Fcntl;

use base 'Exporter';
our @EXPORT = qw();
our @EXPORT_OK = qw(dumper finalize_rules indent);
our %EXPORT_TAGS = (all => \@EXPORT_OK);

sub dumper {
    local $Data::Dumper::Terse = 1;
    local $Data::Dumper::Useqq = 1;
    local $Data::Dumper::Indent = 1;
    local $Data::Dumper::Sortkeys = 1;
    return Data::Dumper::Dumper(@_);
}

sub finalize_rules {
    my @rules = @_;
    foreach my $rule (@rules) {
        my ($type, $pattern) = @$rule{qw(type pattern)};
        if ($pattern =~ /^(?<whole>=)?\/(?<regexp>.*)\/(?<flags>[i]*)$/) {
            my ($whole, $regexp, $flags) = @+{qw(whole regexp flags)};
            if (defined $whole && $whole ne '') {
                $regexp = sprintf("^%s\$", $regexp);
            }
            if (defined $flags && $flags ne '') {
                $regexp = sprintf("(?%s:%s)", $flags, $regexp);
            }
            $rule->{pattern} = qr{$regexp};
        }
    }
}

sub indent {
    my ($str, $indent) = @_;
    $str =~ s{^(?=.)}{$indent}gms;
    return $str;
}

1;
