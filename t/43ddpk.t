#!perl -I./t
# vim:ts=2:sw=2:ai:aw:nu:

$| = 1;

use strict;
use warnings;
use DBI();
use ADOTEST();

use Test::More;

if (defined $ENV{DBI_DSN}) {
  plan tests => 15;
} else {
  plan skip_all => 'Cannot test without DB info';
}

my $dbh = DBI->connect or die "Connect failed: $DBI::errstr\n";
ok ( defined $dbh, 'Connection');

my $catalog = undef;  # TODO: current catalog?
my $schema  = undef;  # TODO: current schema?
my $table   = $ADOTEST::table_name;

my @types = ADOTEST::get_type_for_column( $dbh, 'A');
ok( @types > 0, 'Type info');
my $type = $types[0];

{
  local ($dbh->{Warn}, $dbh->{PrintError});
  $dbh->{PrintError} = $dbh->{Warn} = 0;
  $dbh->do("DROP TABLE $table");
}

# Oracle constraint ...
# CONSTRAINT pk_docindex PRIMARY KEY (token, doc_oid)

my $sql = <<"SQL";
CREATE TABLE $table
(
  K1 $type->{TYPE_NAME}
, K2 $type->{TYPE_NAME}
, CONSTRAINT ${table}_pk PRIMARY KEY (K1, K2)
)
SQL
print $sql;

ok( $dbh->do( $sql ), 'Create table');

{
  my $sth = $dbh->primary_key_info( $catalog, $schema, $table );
  ok( defined $sth, 'Statement handle defined');

  print "Primary key columns:\n";
  my @cols;
  while ( my $row = $sth->fetch )
  {
    no warnings 'uninitialized';
    local $,  = "\t";
    print @$row, "\n";
    push @cols, $row->[3];
  }
  is( @cols, 2, 'Primary key columns');
  for ( 1, 2 )
  {
    is( $cols[$_-1], 'K' . $_, 'Primary key column names');
  }
}
# -----------------------------------------------------------------------------
SKIP: {
  my $sth;

  # Test call to primary_key_info
  local ($dbh->{Warn}, $dbh->{PrintError});
  $dbh->{PrintError} = $dbh->{Warn} = 0;

  # Primary Key Info
  eval {
    $sth = $dbh->primary_key_info();
    die unless $sth;
  };
  ok ($@, "Call to primary_key_info with 0 arguements, error expected: $@" );
  $sth = undef;

  # Primary Key
  eval {
    $sth = $dbh->primary_key();
    die unless $sth;
  };
  ok ($@, "Call to primary_key with 0 arguements, error expected: $@" );
  $sth = undef;

  $sth = $dbh->primary_key_info(undef, undef, undef );

  my $non_supported = '-2146825037';

  skip 'primary_key_info not supported by provider', 5 if $dbh->err && $dbh->err == $non_supported;

  ok( defined $dbh->err, "Call dbh->primary_key_info() ... " );
  ok( defined $sth, "Statement handle defined for primary_key_info()" );

  $sth->dump_results if defined $sth;
  undef $sth;

  $sth = $dbh->primary_key_info(undef, undef, undef );
  ok( defined $dbh->err, "Call dbh->primary_key_info() ... " .
    ($dbh->err? $dbh->errstr : 'no error message' ));
  ok( defined $sth, "Statement handle defined for primary_key_info()" );

  my ( %catalogs, %schemas, %tables);

  my $cnt = 0;
  while( my ($catalog, $schema, $table) = $sth->fetchrow_array ) {
    $catalogs{$catalog}++ if $catalog;
    $schemas{$schema}++   if $schema;
    $tables{$table}++     if $table;
    $cnt++;
  }
  ok( $cnt > 0, "At least one table has a primary key." );
}
# -----------------------------------------------------------------------------

ok( $dbh->disconnect,'Disconnect');
