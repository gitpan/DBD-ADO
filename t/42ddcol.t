#!perl -I./t

$| = 1;

use strict;
use warnings;
use DBI();
use ADOTEST();

use Test::More;

if (defined $ENV{DBI_DSN}) {
  plan tests => 25;
} else {
  plan skip_all => 'Cannot test without DB info';
}

pass('Column info tests');

my $dbh = DBI->connect or die "Connect failed: $DBI::errstr\n";
pass('Database connection created');

my $tbl = $ADOTEST::table_name;

{
  ok( ADOTEST::tab_create( $dbh ),"CREATE TABLE $tbl");
}
# TODO: handle catalog and schema ($tbl may exist in more then one schema)
{
  my $sth;

  eval { $sth = $dbh->column_info };
  ok( (!$@ and defined $sth ),'column_info tested');
  $sth = undef;
}
{
  my $sth = $dbh->column_info( undef, undef, $tbl,'B');
  ok( defined $sth,'Statement handle defined');

  my $row = $sth->fetch;
  is( $row->[ 2], $tbl,"Is this table name $tbl?");
  is( uc $row->[ 3], 'B','Is this column name B?');
}
{
  my $sth = $dbh->column_info( undef, undef, $tbl );
  ok( defined $sth,'Statement handle defined');

  my @ColNames = sort keys %ADOTEST::TestFieldInfo;
  print "# Columns:\n";
  my $i = 0;
  while ( my $row = $sth->fetch )
  {
    $i++;
    {
      no warnings 'uninitialized';
      local $,  = ":"; print '# ', @$row, "\n";
    }
    $row->[ 3] = uc $row->[ 3];
    is( $row->[ 2], $tbl             ,"Is this table name $tbl?");
    is( $row->[16], $i               ,"Is this ordinal position $i?");
    is( $row->[ 3], $ColNames[$i-1]  ,"Is this column name $ColNames[$i-1]?");
    my @ti = ADOTEST::get_type_for_column( $dbh, $row->[3] );
    my $ti = shift @ti;
#   is( $row->[ 4] , $ti->{DATA_TYPE},"Is this data type $ti->{DATA_TYPE}?");
    is( $row->[ 5] , $ti->{TYPE_NAME},"Is this type name $ti->{TYPE_NAME}?");
  }
}

ok( $dbh->disconnect,'Disconnect');
