#!perl -I./t

$| = 1;

use strict;
use warnings;
use DBI();
use DBD_TEST();

use Test::More;

if ( defined $ENV{DBI_DSN} ) {
  plan tests => 9;
} else {
  plan skip_all => 'Cannot test without DB info';
}

pass('Quote identifier tests');

my $dbh = DBI->connect or die "Connect failed: $DBI::errstr\n";
   $dbh->{RaiseError} = 1;
   $dbh->{PrintError} = 0;
pass('Database connection created');

my $tbl = $DBD_TEST::table_name;

ok( DBD_TEST::tab_create( $dbh ),"CREATE TABLE $tbl");

eval { $dbh->quote_identifier };
ok( $@,"Call to quote_identifier with 0 arguments, error expected: $@");
{
  my $cst = $dbh->quote_identifier('catalog','schema','table');
  ok( $cst,"Test quote: $cst");
}
my @cst;
{
  my $sth = $dbh->table_info( undef, undef, $tbl,'TABLE');
  ok( defined $sth,"Called table_info for $tbl");

  my $row = $sth->fetch;
  @cst = @$row[0,1,2];
}
{
  my $cst = $dbh->quote_identifier( @cst );
  ok( $cst,"Test quote from table_info: $cst");

  my $sth = $dbh->prepare("SELECT * FROM $cst");
  ok( $sth,"SELECT * FROM $cst prepared");
  $sth->execute;
  while ( my $row = $sth->fetch ) {
    print '-- ', DBI::neat_list( $row ),"\n";
  }
}

ok( $dbh->disconnect,'Disconnect');
