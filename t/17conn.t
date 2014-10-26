#!perl -I./t

$| = 1;

use strict;
use warnings;
use DBI();
use ADOTEST();

use Test::More;

if (defined $ENV{DBI_DSN}) {
  plan tests => 18;
} else {
  plan skip_all => 'Cannot test without DB info';
}

pass('Simple prepare/execute/finish tests');

my $dbh = DBI->connect or die "Connect failed: $DBI::errstr\n";
pass('Database connection created');

my $tbl = $ADOTEST::table_name;

{
  local ($dbh->{PrintError}, $dbh->{RaiseError}, $dbh->{Warn});
  $dbh->{PrintError} = 0; $dbh->{RaiseError} = 0; $dbh->{Warn} = 0;
  $dbh->do("DROP TABLE $tbl");
}

ok( $dbh->disconnect,'Disconnect');

$dbh = DBI->connect or die "Connect failed: $DBI::errstr\n";
pass('Database connection created');
{
  local $dbh->{PrintError} = 0;
  local $dbh->{RaiseError} = 1;
  ok( !eval{ $dbh->do("DROP TABLE $tbl") },"DROP TABLE $tbl");
  print $@, "\n";
}
ok( $dbh->do("CREATE TABLE $tbl( chr char( 1 ) )"),"CREATE TABLE $tbl");

my $sth;
ok( $sth = $dbh->prepare("SELECT * FROM $tbl"),"SELECT * FROM $tbl");
ok( $sth->execute,'Execute');
ok( $sth->finish,'Finish');
ok( $sth = $dbh->prepare("SELECT * FROM $tbl"),"SELECT * FROM $tbl");
ok( $sth->finish,'Finish');
ok( $sth = $dbh->prepare("SELECT * FROM $tbl"),"SELECT * FROM $tbl");
ok( !( $sth = undef ),'Set sth to undefined');
ok( $sth = $dbh->prepare("SELECT * FROM $tbl"),"SELECT * FROM $tbl");
ok( $sth->execute,'Execute');
ok( !( $sth = undef ),'Set sth to undefined');
ok( $dbh->do("DROP TABLE $tbl"),"DROP TABLE $tbl");

ok( $dbh->disconnect,'Disconnect');
