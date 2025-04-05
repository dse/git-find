package Git::Find;
use warnings;
use strict;
use Data::Dumper qw();
use List::Util qw(any);

use base 'Exporter';
our @EXPORT = qw();
our @EXPORT_OK = qw(dumper);
our %EXPORT_TAGS = (all => \@EXPORT_OK);

sub dumper {
    local $Data::Dumper::Terse = 1;
    local $Data::Dumper::Useqq = 1;
    local $Data::Dumper::Indent = 1;
    local $Data::Dumper::Sortkeys = 1;
    return Data::Dumper::Dumper(@_);
}

1;
