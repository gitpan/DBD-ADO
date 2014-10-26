#!perl -I./t

$| = 1;

use strict;
use warnings;
use DBI();
use ADOTEST();

use Test::More;

if ( defined $ENV{DBI_DSN} ) {
  plan tests => 30;
} else {
  plan skip_all => 'Cannot test without DB info';
}

pass('Row count tests');

my $dbh = DBI->connect or die "Connect failed: $DBI::errstr\n";
   $dbh->{RaiseError} = 1;
   $dbh->{PrintError} = 0;
pass('Database connection created');

my $tbl = $ADOTEST::table_name;
my $cnt = 7;

ok( ADOTEST::tab_create( $dbh ),"CREATE TABLE $tbl");

is( $dbh->do("INSERT INTO $tbl( A, B ) VALUES( $_,'T$_')"), 1,"($_) Insert")
  for 1..$cnt;

my $sth = $dbh->prepare("SELECT * FROM $tbl");
is( $sth->rows, -1,'Rows (prepare) :'. $sth->rows );

for ( 1..2 ) {  # (re)execute
  $sth->execute;
# is( $sth->rows, 0,'Rows (execute) : '. $sth->rows );
  my $i = 0;
  while ( my $row = $sth->fetch ) {
    is( $sth->rows, ++$i,"($_) Rows so far: $i");
#   print "# Row $i: ", DBI::neat_list( $row ),"\n";
  }
  is( $sth->rows, $cnt,"($_) Rows total : $cnt");
}

#$sth = $dbh->prepare("SELECT count(*) FROM $tbl");

is( $dbh->do("DELETE FROM $tbl"), $cnt,"Delete: $cnt");
is( $dbh->do("DELETE FROM $tbl"),'0E0',"Delete: 0E0");

ok( $dbh->disconnect,'Disconnect');
