#!perl -I./t

$| = 1;

use strict;
use warnings;
use DBI();
use DBD_TEST();

use Test::More;

if (defined $ENV{DBI_DSN}) {
  plan tests => 30;
} else {
  plan skip_all => 'Cannot test without DB info';
}

pass('Attribute tests');

my $dbh = DBI->connect or die "Connect failed: $DBI::errstr\n";
pass('Database connection created');

my $tbl = $DBD_TEST::table_name;

ok( DBD_TEST::tab_create( $dbh ),"CREATE TABLE $tbl");

my $sth = $dbh->prepare("SELECT A FROM $tbl");
ok( defined $sth,'Statement handle defined');

ok(!$sth->{$_},"$_: $sth->{$_}") for 'Active';
ok( $sth->$_, $_ ) for 'execute';
ok( $sth->{$_},"$_: $sth->{$_}") for 'Active';

# TODO:
#
# DBI 1.43: getting or setting an invalid attribute to no longer be
#           a fatal error but generate a warning instead.
#eval {
#  my $val = $sth->{BadAttributeHere};
#};
#ok( $@,"Statement attribute BadAttributeHere: $@");

my @attribs = qw(
NUM_OF_FIELDS
NUM_OF_PARAMS
NAME NAME_lc
NAME_uc
PRECISION
SCALE
NULLABLE
CursorName
Statement
RowsInCache
);

for my $attrib ( sort @attribs ) {
  eval {
    my $val = $sth->{$attrib};
  };
  ok(!$@,"Statement attribute: $attrib");
}

is( ref $sth->{NAME},'ARRAY','ref $sth->{NAME} is ARRAY');
is( @{$sth->{NAME}}, 1,'$sth->{NAME} has 1 element');
is( uc $sth->{NAME}[0],'A','1st element is "A"');
is( $sth->{NUM_OF_FIELDS}, 1,'$sth->{NUM_OF_FIELDS} is 1');

# TODO: RowsCacheSize

ok( $sth->$_, $_ ) for 'finish';
ok(!$sth->{$_},"$_: $sth->{$_}") for 'Active';
{
  my $sth = $dbh->prepare("SELECT A FROM $tbl");
  ok( defined $sth,'Statement handle defined');

  ok(!$sth->{$_},"$_: $sth->{$_}") for 'Active';
  ok( $sth->$_, $_ ) for 'execute';
  ok( $sth->{$_},"$_: $sth->{$_}") for 'Active';
  1 while $sth->fetch;
  ok(!$sth->{$_},"$_: $sth->{$_}") for 'Active';
}
ok( $dbh->disconnect,'Disconnect');
