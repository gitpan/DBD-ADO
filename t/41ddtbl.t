#!perl -I./t
# vim:ts=2:sw=2:ai:aw:nu

$| = 1;

use strict;
use warnings;
use DBI();
use ADOTEST();

use Test::More;

if (defined $ENV{DBI_DSN}) {
  plan tests => 32;
} else {
  plan skip_all => 'Cannot test without DB info';
}

my $dbh = DBI->connect or die "Connect failed: $DBI::errstr\n";
ok ( defined $dbh, 'Connection');

{
  ok( ADOTEST::tab_create($dbh), "Create the test table $ADOTEST::table_name" );
}
{
  my @names = qw(TABLE_CAT TABLE_SCHEM TABLE_NAME TABLE_TYPE REMARKS);
  my $sth = $dbh->table_info;
  my $rows = 0;
  while ( my $row = $sth->fetch ) {
    $rows++;
  }
  my $names = $sth->{NAME};
  is( $names[$_], $names->[$_],"Column: $names[$_] $names->[$_]")
    for 0 .. $#names;

  is( $dbh->tables, $rows,"Total tables count: $rows");
}
{
  my $sth = $dbh->table_info( undef, undef, undef, 'TABLE');
  ok( defined $sth, 'Statement handle defined');

  my $row = $sth->fetch;
  is( $row->[3], 'TABLE', 'Fetched a TABLE?');
}
{
  my $sth = $dbh->table_info( undef, undef, $ADOTEST::table_name, 'TABLE');
  ok( defined $sth, 'Statement handle defined');

  my $row = $sth->fetch;
  is( $row->[2], $ADOTEST::table_name, "Is this $ADOTEST::table_name?");
  is( $row->[3], 'TABLE', "Is $ADOTEST::table_name a TABLE?");
}
{
  my $sth = $dbh->table_info( undef, undef, $ADOTEST::table_name, 'VIEW');
  ok( defined $sth, 'Statement handle defined');

  my $row = $sth->fetch;
  ok( !defined $row, "$ADOTEST::table_name isn't a VIEW!");
}
=for todo
{
  my $sth = $dbh->table_info('%');
  ok( defined $sth, 'Statement handle defined');

  print "Catalogs:\n";
  while ( my $row = $sth->fetch )
  {
    local $^W = 0;
    local $,  = "\t";
    print @$row, "\n";
  }
}
{
  my $sth = $dbh->table_info( undef, '%');
  ok( defined $sth, 'Statement handle defined');

  print "Schemata:\n";
  while ( my $row = $sth->fetch )
  {
    local $^W = 0;
    local $,  = "\t";
    print @$row, "\n";
  }
}
{
  my $sth = $dbh->table_info( undef, undef, undef, '%');
  ok( defined $sth, 'Statement handle defined');

  print "Table types:\n";
  while ( my $row = $sth->fetch )
  {
    local $^W = 0;
    local $,  = "\t";
    print @$row, "\n";
  }
}
=cut

# -----------------------------------------------------------------------------
{
my $sth;

# Table Info
 eval {
	 $sth = $dbh->table_info();
 };
ok ((!$@ and defined $sth), "table_info tested" );
$sth = undef;

# Tables
 eval {
	 $sth = $dbh->tables();
 };
ok ((!$@ and defined $sth), "tables tested" );
$sth = undef;

# Test Table Info
$sth = $dbh->table_info( undef, undef, undef );
ok( defined $sth, "table_info(undef, undef, undef) tested" );
DBI::dump_results($sth) if defined $sth;
$sth = undef;

$sth = $dbh->table_info( undef, undef, undef, "VIEW" );
ok( defined $sth, "table_info(undef, undef, undef, \"VIEW\") tested" );
DBI::dump_results($sth) if defined $sth;
$sth = undef;

# Test Table Info Rule 19a
$sth = $dbh->table_info( '%', '', '');
ok( defined $sth, "table_info('%', '', '',) tested" );
DBI::dump_results($sth) if defined $sth;
$sth = undef;

# Test Table Info Rule 19b
$sth = $dbh->table_info( '', '%', '');
ok( defined $sth, "table_info('', '%', '',) tested" );
DBI::dump_results($sth) if defined $sth;
$sth = undef;

# Test Table Info Rule 19c
$sth = $dbh->table_info( '', '', '', '%');
ok( defined $sth, "table_info('', '', '', '%',) tested" );
DBI::dump_results($sth) if defined $sth;
$sth = undef;

# Test to see if this database contains any of the defined table types.
$sth = $dbh->table_info( '', '', '', '%');
ok( defined $sth, "table_info('', '', '', '%',) tested" );
if ($sth) {
	my $ref = $sth->fetchall_hashref( 'TABLE_TYPE' );
	foreach my $type ( sort keys %$ref ) {
		my $tsth = $dbh->table_info( undef, undef, undef, $type );
		ok( defined $tsth, "table_info(undef, undef, undef, $type) tested" );
		DBI::dump_results($tsth) if defined $tsth;
		$tsth->finish;
	}
	$sth->finish;
}
$sth = undef;

}
# -----------------------------------------------------------------------------

ok( $dbh->disconnect,'Disconnect');
