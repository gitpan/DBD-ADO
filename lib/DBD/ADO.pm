{
  package DBD::ADO;

  use strict;
  use DBI();
  use Win32::OLE();
  use vars qw($VERSION $drh $err $errstr $state $errcum);

  $VERSION = '2.87';

  $drh    = undef;  # holds driver handle once initialised
  $err    =  0;     # The $DBI::err value
  $errstr = '';
  $state  = '';
  $errcum =  0;

  sub driver {
    return $drh if $drh;
    my($class, $attr) = @_;
    $drh = DBI::_new_drh( $class . '::dr', {
      Name        => 'ADO'
    , Version     => $VERSION
    , Attribution => 'DBD ADO for Win32 by Tim Bunce, Phlip, Thomas Lowery and Steffen Goeldner'
    });
    if ( $DBI::VERSION >= 1.37 ) {
      DBD::ADO::db->install_method('ado_open_schema');
    }
    return $drh;
  }

  sub errors {
    my $Conn = shift;
    my $MaxErrors = shift || 50;
    my @Err  = ();

    my $lastError = Win32::OLE->LastError;
    if ( $lastError ) {
      $DBD::ADO::errcum = $DBD::ADO::err = 0+$lastError;
      push @Err, "\n  Last error : $DBD::ADO::err\n\n$lastError";
    } else {
      $DBD::ADO::err    =  0;
      $DBD::ADO::errstr = '';
      $DBD::ADO::state  = '';
      $DBD::ADO::errcum =  0;
    }
    if ( ref $Conn ) {
      my $Errors = $Conn->Errors;
      if ( $Errors ) {
        my $Count = $Errors->Count;
        for ( my $i = 1; $i <= $Count; $i++ ) {
          if ( $i > $MaxErrors ) {
            push @Err, "\n    ... (too many errors: $Count)";
            $i = $Count;
          }
          my $err = $Errors->Item( $i - 1 );
          push @Err, '';
          push @Err, sprintf "%19s : %s", $_, $err->$_ ||'' for qw(
            Description HelpContext HelpFile NativeError Number Source SQLState);
          push @Err, '    ';
          $DBD::ADO::errcum |= $err->Number;
          $DBD::ADO::state   = $err->SQLState ||'';
        }
        $Errors->Clear;
      }
    }
    join "\n", @Err;
  }

  sub Failed {
    my $h   = shift;

    my $lastError = DBD::ADO::errors( $h->{ado_conn}, $h->{ado_max_errors} )
      or return 0;

    my ( $package, $filename, $line ) = caller;
    my $s = shift()
          . "\n"
          . "\n  Package    : $package"
          . "\n  Filename   : $filename"
          . "\n  Line       : $line"
          ;
    $DBD::ADO::err = 0 unless $DBD::ADO::errcum & 1 << 31;  # oledberr.h
    my $state = $DBD::ADO::state if length $DBD::ADO::state == 5;
    $h->set_err( $DBD::ADO::err, $s . $lastError, $state );
    return 1;
  }

}

{ package DBD::ADO::dr; # ====== DRIVER ======

  use strict;
  use DBI();
  use Win32::OLE();

  $DBD::ADO::dr::imp_data_size = 0;

	use constant DBPROPVAL_TC_ALL        => 8;
	use constant DBPROPVAL_TC_DDL_IGNORE => 4;
	use constant DBPROPVAL_TC_DDL_COMMIT => 2;
	use constant DBPROPVAL_TC_DML        => 1;
	use constant DBPROPVAL_TC_NONE       => 0;

  sub data_sources {
    my($drh, $attr) = @_;
    my @list = ();
    $drh->{ado_data_sources} ||= eval { require Local::DBD::ADO::DSN } || [];
    $drh->trace_msg("    !! $@", 7 ) if $@;
    for my $h ( @{$drh->{ado_data_sources}} ) {
      my @a = map "$_=$h->{$_}", sort keys %$h;
      push @list, 'dbi:ADO:' . join(';', @a );
    }
    return @list;
  }

	sub connect {
		my ($drh, $dsn, $user, $auth) = @_;

		local $Win32::OLE::Warn = 0;
		my $conn = Win32::OLE->new('ADODB.Connection');
		return if DBD::ADO::Failed( $drh,"Can't create 'ADODB.Connection'");

		my ($outer, $this) = DBI::_new_dbh($drh, {
			Name => $dsn,
			User => $user,
			AutoCommit => 1,
			Warn => 0,
			LongReadLen => 0,
			LongTruncOk => 0,
			ado_max_errors => 50,
		});

		# Get the default value;
		$this->{ado_commandtimeout} = $conn->{CommandTimeout};
		# Refer the connection commandtimeout to the handler.
		$conn->{CommandTimeout} = \$this->{ado_commandtimeout};

		$this->{ado_conn} = $conn;
		$drh->trace_msg( "->ADO Connection: " . ref $this->{ado_conn} .
			" Connection: " . ref $conn . "\n", 1);
		##  ODBC rule - Null is not the same as an empty password...
		$auth = '' if !defined $auth;

		my (@cdsn,$cdsn);
		# Run thru the dsn extracting connection options.
		if( $dsn =~ /;/ ) {
			for my $s (split( /;/, $dsn)) {
				if ($s =~ m/^(.*?)=(.*)$/s){
					my ($c, $v) = ($1, $2);
					# Only include the options defined.
					if( $conn->{$c} ) {
						$this->STORE($c, $v);
						$drh->trace_msg("->> Storing $c $v\n", 1);
						next;
					}
				}
				push(@cdsn, $s );
			}
		} else {
			if($dsn =~ m/^(.*?)=(.*)$/s) {
				$outer->STORE( "ConnectionString", $dsn );
			} else {
				$outer->STORE( "ConnectionString", "DSN=$dsn" );
				push(@cdsn, $dsn);
			}
		}

		$cdsn = join( ";", @cdsn );
		$drh->trace_msg("->> Open ADO connection using $cdsn\n", 1);
		$conn->Open( $cdsn, $user, $auth );
		return if DBD::ADO::Failed( $drh,"Can't connect to '$dsn'");

		# Determine if the provider supports transaction.
		my $auto = 0;
		eval {
			$auto = $conn->Properties->{qq{Transaction DDL}}->{Value};
		if ( $auto eq &DBPROPVAL_TC_ALL ) {
			$this->{ado_provider_support_auto_commit} = $auto;
			$this->{ado_provider_auto_commit_comments} =
				qq{Transactions can contain DDL and DML statements in any order.};
		} elsif ( $auto eq &DBPROPVAL_TC_DDL_COMMIT ) {
			$this->{ado_provider_support_auto_commit} = $auto;
			$this->{ado_provider_auto_commit_comments} =
				qq{Transactions can contain DML statements.  DDL statements within a transaction cause the transaction to be committed.};
		} elsif ( $auto eq &DBPROPVAL_TC_DDL_IGNORE )  {
			$this->{ado_provider_support_auto_commit} = $auto;
			$this->{ado_provider_auto_commit_comments} =
				qq{Transactions can only contain DML statements.  DDL statements within a transaction are ignored.};
		} elsif ( $auto eq &DBPROPVAL_TC_DML )  {
			$this->{ado_provider_support_auto_commit} = $auto;
			$this->{ado_provider_auto_commit_comments} =
				qq{Transactions can only contain Data Manipulation (DML) statements.  DDL statements within a trnsaction cause an error.};
		} else {
			$this->{ado_provider_support_auto_commit} = $auto;
			$this->{ado_provider_auto_commit_comments} =
				qq{Transactions are not supported.};
		}
		};
		if ($@) {
			warn "No transactions";
			$this->{ado_provider_support_auto_commit} = 0;
			$this->{ado_provider_auto_commit_comments} =
				qq{Transactions are not supported.};
			$auto = 0;
			my $lastError = DBD::ADO::errors($conn);
		}

		$drh->trace_msg( "->> Transaction support: $auto " .
			$this->{ado_provider_auto_commit_comments} . "\n",1);

    $outer->STORE('Active', 1 );
		return $outer;
	}

  sub disconnect_all { }

} # ====== DRIVER ======

# names of adSchemaProviderTypes fields
# my $ado_info = [qw{
# 	TYPE_NAME DATA_TYPE COLUMN_SIZE LITERAL_PREFIX
# 	LITERAL_SUFFIX CREATE_PARAMS IS_NULLABLE CASE_SENSITIVE
# 	SEARCHABLE UNSIGNED_ATTRIBUTE FIXED_PREC_SCALE AUTO_UNIQUE_VALUE
# 	LOCAL_TYPE_NAME MINIMUM_SCALE MAXIMUM_SCALE GUID TYPELIB
# 	VERSION IS_LONG BEST_MATCH IS_FIXEDLENGTH
# }];
# check IS_NULLABLE => NULLABLE (only difference with DBI/ISO field names)
# Information returned from the provider about the schema.  The column names
# are different then the DBI spec.
my $ado_schematables = [
	qw{ TABLE_CAT TABLE_SCHEM TABLE_NAME TABLE_TYPE REMARKS
		TABLE_GUID TABLE_PROPID DATE_CREATED DATE_MODIFIED
	} ];

my $ado_dbi_schematables = [
	qw{ TABLE_CAT TABLE_SCHEM TABLE_NAME TABLE_TYPE REMARKS }
	];

my $sch_dbi_to_ado = {
	TABLE_CAT     => 'TABLE_CATALOG',
	TABLE_SCHEM   => 'TABLE_SCHEMA',
	TABLE_NAME    => 'TABLE_NAME',
	TABLE_TYPE    => 'TABLE_TYPE',
	REMARKS       => 'DESCRIPTION',
	TABLE_GUID    => 'TABLE_GUID',
	TABLE_PROPID  => 'TABLE_PROPID',
	DATE_CREATED  => 'DATE_CREATED',
	DATE_MODIFIED => 'DATE_MODIFIED',
	};


{ package DBD::ADO::db; # ====== DATABASE ======

  use strict;
  use DBI();
  use Win32::OLE();
  use Win32::OLE::Variant();
  use DBD::ADO::TypeInfo();
  use DBD::ADO::Const();
  use Carp();

  $DBD::ADO::db::imp_data_size = 0;

  my $ado_consts = DBD::ADO::Const->Enums;

  sub ping {
    my ( $dbh ) = @_;
    my $conn = $dbh->{ado_conn};

    defined $conn && $conn->State & $ado_consts->{ObjectStateEnum}{adStateOpen};
  }

	sub disconnect {
		my ($dbh) = @_;
		my $conn = $dbh->{ado_conn};
		local $Win32::OLE::Warn = 0;
		$dbh->trace_msg('    -- State: ' . $conn->State . "\n");
		if ( $conn->State & $ado_consts->{ObjectStateEnum}{adStateOpen} ) {
			# Change the connection attribute so Commit/Rollback
			# does not start another transaction.
			$conn->{Attributes} = 0;
			my $lastError = DBD::ADO::errors($conn);
			return $dbh->set_err( $DBD::ADO::err || -1,"Failed setting CommitRetaining: $lastError") if $lastError && $lastError !~ m/-2147168242/;
			$dbh->trace_msg('    -- Modified ADO Connection Attributes: ' . $conn->{Attributes} . "\n");

			my $auto = $dbh->{AutoCommit};
			$dbh->trace_msg("    -- AutoCommit: $auto, Provider Support: $dbh->{ado_provider_support_auto_commit}, Comments: $dbh->{ado_provider_auto_commit_comments}\n");
			$conn->RollbackTrans unless $auto and
				not $dbh->{ado_provider_support_auto_commit};
			$lastError = DBD::ADO::errors($conn);
			return $dbh->set_err( $DBD::ADO::err || -1,"Failed to execute rollback: $lastError") if $lastError && $lastError !~ m/-2147168242/;
			# Provider error about txn not started. Ignore message, clear error codes.
			DBD::ADO::errors($conn) if $lastError && $lastError =~ m/-2147168242/;

			$conn->Close;
		}
		$conn = undef;
		$dbh->{ado_conn} = undef;
		$dbh->SUPER::STORE('Active', 0 );
		return 1;
	}

	# Commit to the database.
	sub commit {
		my($dbh) = @_;

		return warn "Commit ineffective when AutoCommit is on\n"
			if $dbh->{AutoCommit} and $dbh->FETCH('Warn');
		return Carp::carp $dbh->{ado_provider_auto_commit_comments}
			unless $dbh->{ado_provider_support_auto_commit};
    if ( $dbh->FETCH('BegunWork') ) {
      $dbh->{AutoCommit} = 1;
      $dbh->SUPER::STORE('BegunWork', 0 );
      my $conn = $dbh->{ado_conn};
      $conn->{Attributes} = 0;
      return if DBD::ADO::Failed( $dbh,"Failed setting CommitRetaining");
    }
		if (exists $dbh->{ado_conn} and defined $dbh->{ado_conn} and
			$dbh->{ado_conn}->{State} == $ado_consts->{ObjectStateEnum}{adStateOpen}) {
			$dbh->{ado_conn}->CommitTrans;
			return if DBD::ADO::Failed( $dbh,"Failed to CommitTrans");
		}
    return 1;
	}

	# Rollback to the database.
	sub rollback {
		my($dbh) = @_;

		return Carp::carp "Rollback ineffective when AutoCommit is on\n"
			if $dbh->{AutoCommit} and $dbh->FETCH('Warn');
		return Carp::carp $dbh->{ado_provider_auto_commit_comments}
			unless $dbh->{ado_provider_support_auto_commit};
    if ( $dbh->FETCH('BegunWork') ) {
      $dbh->{AutoCommit} = 1;
      $dbh->SUPER::STORE('BegunWork', 0 );
      my $conn = $dbh->{ado_conn};
      $conn->{Attributes} = 0;
      return if DBD::ADO::Failed( $dbh,"Failed setting CommitRetaining");
    }
		if (exists $dbh->{ado_conn} and defined $dbh->{ado_conn} and
			$dbh->{ado_conn}->{State} & $ado_consts->{ObjectStateEnum}{adStateOpen}) {
			$dbh->{ado_conn}->RollbackTrans;
			return if DBD::ADO::Failed( $dbh,"Failed to Rollback Trans");
		}
    return 1;
	}

	# The create parm methods builds a usable type statement for constructing
	# tables.
	# XXX This method may not stay ...
	sub create_parm {
		my ($dbh, $type) = @_;

		my $field = undef;

		if ($type) {
    	$field = $type->{TYPE_NAME};
			if (defined $type->{CREATE_PARAMS}) {
			$field .= qq{(} . $type->{COLUMN_SIZE} . qq{)}
				if ($type->{CREATE_PARAMS} =~ /LENGTH/i);
			$field .= qq{(} . $type->{COLUMN_SIZE} . qq{, 0)}
				if ($type->{CREATE_PARAMS} =~ /PRECISION,SCALE/i);
			}
		}
		return $field;
	}

	sub prepare {
		my($dbh, $statement, $attribs) = @_;
		my $conn = $dbh->{ado_conn};

		my $comm = Win32::OLE->new('ADODB.Command');
		return if DBD::ADO::Failed( $dbh,"Can't create 'object ADODB.Command'");

		$comm->{ActiveConnection} = $conn;
		return if DBD::ADO::Failed( $dbh,"Unable to set ActiveConnection 'ADODB.Command'");

		$comm->{CommandText} = $statement;
		return if DBD::ADO::Failed( $dbh,"Unable to set CommandText 'ADODB.Command'");

		my $ct = $attribs->{CommandType}? $attribs->{CommandType}: "adCmdText";
		$comm->{CommandType} = $ado_consts->{CommandTypeEnum}{$ct};
		return if DBD::ADO::Failed( $dbh,"Unable to set command type 'ADODB.Command'");

		my ($outer, $sth) = $dbh->DBI::_new_sth( {
		  Statement		=> $statement
		, NAME				=> undef
		, TYPE				=> undef
		, PRECISION		=> undef
		, SCALE				=> undef
		, NULLABLE		=> undef
		, CursorName	=> undef
		, ParamValues	=> {}
		, RowsInCache	=> 0
		, ado_max_errors => $dbh->{ado_max_errors}
		, ado_type		=> undef
		});

		$outer->STORE( LongReadLen	=> 0 );
		$outer->STORE( LongTruncOk	=> 0 );

		if (exists $attribs->{RowsInCache}) {
			$outer->STORE( RowsInCache	=> $attribs->{RowsInCache} );
		} else {
			$outer->STORE( RowsInCache	=> 0 );
		}

		$sth->{ado_comm}		= $comm;
		$sth->{ado_conn}		= $conn;
		$sth->{ado_dbh}			= $dbh;
		$sth->{ado_fields}	= undef;
		$sth->{ado_refresh}	= 1;
		$sth->{ado_rownum}	= -1;
		$sth->{ado_rows}		= -1;
		$sth->{ado_rowset}	= undef;
		$sth->{ado_attribs}	= $attribs;
		$sth->{ado_usecmd}	= undef;
		$sth->{ado_users}		= undef;

		# Inherit from dbh.
		$sth->{ado_commandtimeout} =
			defined $dbh->{ado_commandtimeout} ?  $dbh->{ado_commandtimeout} :
				$conn->{CommandTimeout};

		$comm->{CommandTimeout} = $sth->{ado_commandtimeout};
		return if DBD::ADO::Failed( $dbh,"Unable to set CommandText 'ADODB.Command'");

		$sth->{ado_cursortype} =
			defined $dbh->{ado_cursortype} ?  $dbh->{ado_cursortype} : undef;

		# Set overrides for and attributes.
		foreach my $key (grep { /^ado_/ } keys %$attribs) {
			$sth->trace_msg("    -- Attribute: $key => $attribs->{$key}\n");
			if ( exists $sth->{$key} ) {
				$sth->{$key} = $attribs->{$key};
			} else {
					warn "Unknown attribute $key\n";
			}
		}

    my $Cnt;
    if ( $sth->{ado_refresh} == 1 ) {
      # Refresh() is - among other things - useful to detect syntax errors.
      # The eval block is used because Refresh() may not be supported (but
      # no such case is known).
      # Buggy drivers, e.g. FoxPro, may leave the Parameters collection
      # empty, without returning an error. Then _refresh() is defered until
      # bind_param() is called.
      eval {
        local $Win32::OLE::Warn = 0;
        $comm->Parameters->Refresh;
        $Cnt = $comm->Parameters->Count;
      };
      my $lastError = DBD::ADO::errors( $conn );
      if ( $lastError ) {
        $dbh->trace_msg("    !! Refresh error: $lastError\n", 4 );
        $sth->{ado_refresh} = 2;
      }
    }
    if ($sth->{ado_refresh} == 2 ) {
      $Cnt = DBD::ADO::st::_refresh( $outer );
    }
    if ( $Cnt ) {
      # Describe the Parameters:
      for my $p ( Win32::OLE::in( $comm->Parameters ) ) {
        my @p = map "$_ => $p->{$_}", qw(Name Type Direction Size);
        $dbh->trace_msg("    -- Parameter: @p\n", 4 );
      }
      $outer->STORE('NUM_OF_PARAMS' => $Cnt );
    }
    $comm->{Prepared} = 1;
    return if DBD::ADO::Failed( $dbh,"Unable to set prepared 'ADODB.Command'");

    return $outer;
  } # prepare
	#
	# Creates a Statement handle from a row set.
	#
	sub _rs_sth_prepare {
		my($dbh, $rs, $attribs) = @_;

		$dbh->trace_msg( "-> _rs_sth_prepare: Create statement handle from RecordSet\n" );

		my $conn = $dbh->FETCH("ado_conn");
		my $ado_fields = [ Win32::OLE::in($rs->Fields) ];

		my ($outer, $sth) = DBI::_new_sth($dbh, {
		  NAME				=> [ map { $_->Name } @$ado_fields ]
		, TYPE				=> [ map { $_->Type } @$ado_fields ]
		, PRECISION		=> [ map { $_->Precision } @$ado_fields ]
		, SCALE				=> [ map { $_->NumericScale } @$ado_fields ]
		, NULLABLE		=> [ map { $_->Attributes & $ado_consts->{FieldAttributeEnum}{adFldMayBeNull}? 1 : 0 } @$ado_fields ]
		, Statement		=> $rs->Source
		, LongReadLen	=> 0
		, LongTruncOk	=> 0
		, CursorName	=> undef
		, ParamValues	=> {}
		, RowsInCache	=> 0
		, ado_max_errors => $dbh->{ado_max_errors}
		, ado_type		=> [ map { $_->Type } @$ado_fields ]
		});

		$sth->{ado_comm}		= $conn;
		$sth->{ado_conn}		= $conn;
		$sth->{ado_dbh}			= $dbh;
		$sth->{ado_fields}	= $ado_fields;
		$sth->{ado_refresh}	= 0;
		$sth->{ado_rownum}	= 0;
		$sth->{ado_rows}		= -1;
		$sth->{ado_rowset}	= $rs;
		$sth->{ado_attribs}	= $attribs;

		$sth->STORE( NUM_OF_FIELDS	=> scalar @$ado_fields );
		$sth->STORE( Active					=> 1);

		$dbh->trace_msg( "<- _rs_sth_prepare: Create statement handle from RecordSet\n" );
		return $outer;
	} # _rs_sth_prepare

	sub get_info {
		my($dbh, $info_type) = @_;
		$info_type = int($info_type);
		require DBD::ADO::GetInfo;
		if ( exists $DBD::ADO::GetInfo::odbc2ado{$info_type} ) {
			return $dbh->{ado_conn}->Properties->{$DBD::ADO::GetInfo::odbc2ado{$info_type}}{Value};
		}
		my $v = $DBD::ADO::GetInfo::info{$info_type};
		if (ref $v eq 'CODE') {
			my $get_info_cache = $dbh->{dbd_get_info_cache} ||= {};
			return $get_info_cache->{$info_type} if exists $get_info_cache->{$info_type};
			$v = $v->($dbh);
			return $$v if ref $v eq 'SCALAR';  # don't cache!
			$get_info_cache->{$info_type} = $v;
		}
		return $v;
	}

	sub ado_schema_dbinfo_literal {
		my($dbh, $literal_name) = @_;
		my $cache = $dbh->{ado_schema_dbinfo_literal_cache};
		unless ( defined $cache ) {
			$dbh->trace_msg("-> ado_schema_dbinfo_literal: filling cache\n");
			$cache = $dbh->{ado_schema_dbinfo_literal_cache} = {};
			my $sth = $dbh->func('adSchemaDBInfoLiterals','OpenSchema');
			while ( my $row = $sth->fetch ) {
				$cache->{$row->[0]} = [ @$row ];
			}
		}
		my $row = $cache->{$literal_name};
		return $row->[1] unless wantarray;  # literal value
		return @$row;
	}

	sub table_info {
		my($dbh, $attribs) = @_;
		$attribs = {
			TABLE_CAT   => $_[1],
			TABLE_SCHEM => $_[2],
			TABLE_NAME  => $_[3],
			TABLE_TYPE  => $_[4],
		} unless ref $attribs eq 'HASH';

		$dbh->trace_msg( "-> table_info\n" );

		my @criteria = (undef); # ADO needs at least one element in the criteria array!

		my $tmpCursorLocation = $dbh->{ado_conn}->{CursorLocation};
		$dbh->{ado_conn}->{CursorLocation} = $ado_consts->{CursorLocationEnum}{adUseClient};

		my @tp;
		my $field_names = $attribs->{ADO_Columns}
			?  $ado_schematables : $ado_dbi_schematables;
		my $rs;

		#
		# If the value of $catalog is '%' and $schema and $table name are empty
		# strings, the result set contains a list of catalog names.
		#
		if ( (defined $attribs->{TABLE_CAT}   and $attribs->{TABLE_CAT}   eq '%'  )
			&& (defined $attribs->{TABLE_SCHEM} and $attribs->{TABLE_SCHEM} eq '' )
			&& (defined $attribs->{TABLE_NAME}  and $attribs->{TABLE_NAME}  eq '') ) { # Rule 19a
			# This is the easy way to determine catalog support.
			eval {
				local $Win32::OLE::Warn = 0;
				$rs = $dbh->{ado_conn}->OpenSchema($ado_consts->{SchemaEnum}{adSchemaCatalogs});
				my $lastError = DBD::ADO::errors($dbh->{ado_conn});
				$lastError = undef if $lastError =~ m/0x80020007/;
				die "Died on:\n$lastError" if $lastError;
			};
			$dbh->trace_msg( "->	Eval of adSchemaCatalogs died for $@\n" )
				if $@;
			$dbh->trace_msg( "->	Rule 19a\n" );
			if ( $rs ) {
				$dbh->trace_msg( "->	Rule 19a, record set defined\n" );
				while ( !$rs->{EOF} ) {
					push @tp, [ $rs->Fields(0)->{Value}, undef, undef, undef, undef ];
					$rs->MoveNext;
				}
			}
			else {
				# The provider does not support the adSchemaCatalogs.  Let's attempt
				# to still return a list of catalogs.
				$dbh->trace_msg( "->	Rule 19a, record set undefined\n" );
				my $csth = $dbh->table_info( { Trim_Catalog => 1 } );
				if ( $csth ) {
          my $ref = {};
          my $Undef = 0;  # for 'undef' hash keys (which mutate to '')
          while ( my $Row = $csth->fetch ) {
            defined $Row->[0] ? $ref->{$Row->[0]} = 1 : $Undef = 1;
          }
          push @tp, [ undef, undef, undef, undef, undef ] if $Undef;
          push @tp, [    $_, undef, undef, undef, undef ] for sort keys %$ref;
				}
				else {
					push @tp, [ undef, undef, undef, undef, undef ];
				}
			}
		}
		#
		# If the value of $schema is '%' and $catalog and $table are empty
		# strings, the result set contains a list of schema names.
		#
		elsif ( (defined $attribs->{TABLE_CAT} and $attribs->{TABLE_CAT}   eq '')
				 && (defined $attribs->{TABLE_SCHEM} and $attribs->{TABLE_SCHEM} eq '%')
				 && (defined $attribs->{TABLE_NAME} and $attribs->{TABLE_NAME}  eq '') ) { # Rule 19b
			eval {
				local $Win32::OLE::Warn = 0;
				$rs = $dbh->{ado_conn}->OpenSchema($ado_consts->{SchemaEnum}{adSchemaSchemata});
				my $lastError = DBD::ADO::errors($dbh->{ado_conn});
				$lastError = undef if $lastError =~ m/0x80020007/;
				die "Died on:\n$lastError" if $lastError;
			};
			$dbh->trace_msg( "->	Eval of adSchemaSchemata died for $@\n" )
				if $@;
			$dbh->trace_msg( "->	Rule 19b\n" );
			if ( $rs ) {
				$dbh->trace_msg( "->	Rule 19b, record set defined\n" );
				while ( !$rs->{EOF} ) {
					push @tp, [ $rs->Fields(0)->{Value}, $rs->Fields(1)->{Value}, undef, undef, undef ];
					$rs->MoveNext;
				}
			}
			else {
				# The provider does not support the adSchemaSchemata.  Let's attempt
				# to still return a list of schemas.
				$dbh->trace_msg( "->	Rule 19b, record set undefined\n" );
				my $csth = $dbh->table_info( { Trim_Catalog => 1 } );
				if ( $csth ) {
          my $ref = {};
          my $Undef = 0;  # for 'undef' hash keys (which mutate to '')
          while ( my $Row = $csth->fetch ) {
            defined $Row->[0] ? $ref->{$Row->[0]} = 1 : $Undef = 1;
          }
          push @tp, [ undef, undef, undef, undef, undef ] if $Undef;
          push @tp, [ undef,    $_, undef, undef, undef ] for sort keys %$ref;
				}
				else {
					push @tp, [ undef, undef, undef, undef, undef ];
				}
			}
		}
		#
		# If the value of $type is '%' and $catalog, $schema, and $table are all
		# empty strings, the result set contains a list of table types.
		#
		elsif ( (defined $attribs->{TABLE_CAT} and $attribs->{TABLE_CAT}   eq '')
				 && (defined $attribs->{TABLE_SCHEM} and $attribs->{TABLE_SCHEM} eq '')
				 && (defined $attribs->{TABLE_NAME} and $attribs->{TABLE_NAME}  eq '')
				 && (defined $attribs->{TABLE_TYPE} and $attribs->{TABLE_TYPE}  eq '%')
				 ) { # Rule 19c
			$dbh->trace_msg( "->	Rule 19c\n" );
			my @TableTypes = ('ALIAS','TABLE','SYNONYM','SYSTEM TABLE','VIEW','GLOBAL TEMPORARY','LOCAL TEMPORARY','SYSTEM VIEW'); # XXX
			for ( sort @TableTypes ) {
				push @tp, [ undef, undef, undef, $_, undef ];
			}
		}
		else {
			@criteria = (undef); # ADO needs at least one element in the criteria array!
			for (my $i=0; $i<@$ado_dbi_schematables; $i++) {
				my $field = $ado_dbi_schematables->[$i];
				if ( exists $attribs->{$field} ) {
					$criteria[$i] = $attribs->{$field};
				}
			}

			eval {
				local $Win32::OLE::Warn = 0;
				$rs = $dbh->{ado_conn}->OpenSchema($ado_consts->{SchemaEnum}{adSchemaTables}, \@criteria);
				my $lastError = DBD::ADO::errors($dbh->{ado_conn});
				$lastError = undef if $lastError =~ m/0x80020007/;
				die "Died on:\n$lastError" if $lastError;
			};
			$dbh->trace_msg( "->	Eval of adSchemaTables died for $@\n" )
				if $@;
			if ( $rs ) {
				if ( exists $attribs->{Filter} ) {
					$rs->{Filter} = $attribs->{Filter};
				}

				while ( !$rs->{EOF} ) {
					my @out = map { $rs->Fields($_)->{Value} }
						map { $sch_dbi_to_ado->{$_} } @$field_names;
					# Jan Dubois jand@activestate.com addition to handle changes
					# in Win32::OLE return of Variant types of data.
					foreach ( @out ) {
						$_ = $_->As( Win32::OLE::Variant::VT_BSTR() )
							if ( defined $_ ) && ( UNIVERSAL::isa( $_, 'Win32::OLE::Variant') );
					}
					if ( $attribs->{Trim_Catalog} ) {
						$out[0] =~ s/^(.*\\)// if defined $out[0];  # removes leading
						$out[0] =~ s/(\..*)$// if defined $out[0];  # removes file extension
					}
					push( @tp, \@out );
					$rs->MoveNext;
				}
			}
			else {
				push @tp, [ undef, undef, undef, undef, undef ];
			}
		}

		$rs->Close if $rs;
		$rs = undef;
		$dbh->{ado_conn}->{CursorLocation} = $tmpCursorLocation;

		my $statement = "adSchemaTables";
		my $sponge = DBI->connect("dbi:Sponge:","","",{ RaiseError => 1 });
		my $sth = $sponge->prepare($statement,
			{ rows=> \@tp, NAME=> $field_names });

		$dbh->trace_msg( "<- table_info\n" );
		return $sth;
	}

	sub column_info {
		my( $dbh, @Criteria ) = @_;
		my $Criteria = \@Criteria if @Criteria;
		my $QueryType = 'adSchemaColumns';
		my @Rows;
		my $conn = $dbh->{ado_conn};
		my $tmpCursorLocation = $conn->{CursorLocation};
		$conn->{CursorLocation} = $ado_consts->{CursorLocationEnum}{adUseClient};

		my $rs = $conn->OpenSchema( $ado_consts->{SchemaEnum}{$QueryType}, $Criteria );
		return if DBD::ADO::Failed( $dbh,"Error occurred with call to OpenSchema ($QueryType)");

		$rs->{Sort} = 'TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION';
		return if DBD::ADO::Failed( $dbh,"Error occurred defining sort order ");

		while ( !$rs->{EOF} ) {
			my $AdoType    = $rs->Fields('DATA_TYPE'   )->{Value};
			my $ColFlags   = $rs->Fields('COLUMN_FLAGS')->{Value};
			my $IsLong     = ( $ColFlags & $ado_consts->{FieldAttributeEnum}{adFldLong } ) ? 1 : 0;
			my $IsFixed    = ( $ColFlags & $ado_consts->{FieldAttributeEnum}{adFldFixed} ) ? 1 : 0;
			my @SqlType    = DBD::ADO::TypeInfo::ado2dbi( $AdoType, $IsFixed, $IsLong );
			my $IsNullable = $rs->Fields('IS_NULLABLE')->{Value} ? 'YES' : 'NO';
			my $ColSize    = $rs->Fields('NUMERIC_PRECISION'       )->{Value}
			              || $rs->Fields('CHARACTER_MAXIMUM_LENGTH')->{Value}
										|| 0;  # Default value to stop warnings ???
			my $TypeName;
			my $ado_tis    = DBD::ADO::db::_ado_get_type_info_for( $dbh, $AdoType, $IsFixed, $IsLong );
			$dbh->trace_msg('  *** ' . $rs->Fields('COLUMN_NAME')->{Value} . "($ColSize): $AdoType, $IsFixed, $IsLong\n", 3 );
			# find the first type which has a large enough COLUMN_SIZE:
			for my $ti ( sort { $a->{COLUMN_SIZE} <=> $b->{COLUMN_SIZE} } @$ado_tis ) {
				$dbh->trace_msg("    * => $ti->{TYPE_NAME}($ti->{COLUMN_SIZE})\n", 3 );
				if ( $ti->{COLUMN_SIZE} >= $ColSize ) {
					$TypeName = $ti->{TYPE_NAME};
					last ;
				}
			}
			# unless $TypeName: Standard SQL type name???

			my @Fields;
			$Fields[ 0] = $rs->Fields('TABLE_CATALOG'           )->{Value}; # TABLE_CAT
			$Fields[ 1] = $rs->Fields('TABLE_SCHEMA'            )->{Value}; # TABLE_SCHEM
			$Fields[ 2] = $rs->Fields('TABLE_NAME'              )->{Value}; # TABLE_NAME
			$Fields[ 3] = $rs->Fields('COLUMN_NAME'             )->{Value}; # COLUMN_NAME
			$Fields[ 4] = $SqlType[0]                                     ; # DATA_TYPE !!!
			$Fields[ 5] = $TypeName                                       ; # TYPE_NAME !!!
			$Fields[ 6] = $ColSize                                        ; # COLUMN_SIZE !!! MAX for *LONG*
			$Fields[ 7] = $rs->Fields('CHARACTER_OCTET_LENGTH'  )->{Value}; # BUFFER_LENGTH !!! MAX for *LONG*, ... (e.g. num)
			$Fields[ 8] = $rs->Fields('NUMERIC_SCALE'           )->{Value}; # DECIMAL_DIGITS ???
			$Fields[ 9] = undef                                           ; # NUM_PREC_RADIX !!!
			$Fields[10] = $rs->Fields('IS_NULLABLE'             )->{Value}; # NULLABLE !!!
			$Fields[11] = $rs->Fields('DESCRIPTION'             )->{Value}; # REMARKS
			$Fields[12] = $rs->Fields('COLUMN_DEFAULT'          )->{Value}; # COLUMN_DEF
			$Fields[13] = $SqlType[1]                                     ; # SQL_DATA_TYPE !!!
			$Fields[14] = $SqlType[2]                                     ; # SQL_DATETIME_SUB !!!
			$Fields[15] = $rs->Fields('CHARACTER_OCTET_LENGTH'  )->{Value}; # CHAR_OCTET_LENGTH !!! MAX for *LONG*
			$Fields[16] = $rs->Fields('ORDINAL_POSITION'        )->{Value}; # ORDINAL_POSITION
			$Fields[17] = $IsNullable                                     ; # IS_NULLABLE !!!

			push( @Rows, \@Fields );
			$rs->MoveNext;
		}

		$rs->Close; undef $rs;
		$conn->{CursorLocation} = $tmpCursorLocation;

		DBI->connect('dbi:Sponge:','','', { RaiseError => 1 })->prepare(
			$QueryType, { rows => \@Rows
			, NAME => [ qw( TABLE_CAT TABLE_SCHEM TABLE_NAME COLUMN_NAME DATA_TYPE TYPE_NAME COLUMN_SIZE BUFFER_LENGTH DECIMAL_DIGITS NUM_PREC_RADIX NULLABLE REMARKS COLUMN_DEF SQL_DATA_TYPE SQL_DATETIME_SUB CHAR_OCTET_LENGTH ORDINAL_POSITION IS_NULLABLE ) ]
			, TYPE => [            12,         12,        12,         12,        5,       12,          4,            4,             5,             5,       5,     12,        12,            5,               5,                4,               4,         12   ]
		});
	}

	sub primary_key_info {
		my( $dbh, @Criteria ) = @_;
		my $QueryType = 'adSchemaPrimaryKeys';
		my @Rows;
		my $conn = $dbh->{ado_conn};
		my $tmpCursorLocation = $conn->{CursorLocation};
		$conn->{CursorLocation} = $ado_consts->{CursorLocationEnum}{adUseClient};

		my $rs = $conn->OpenSchema( $ado_consts->{SchemaEnum}{$QueryType}, \@Criteria );
		return if DBD::ADO::Failed( $dbh,"Error occurred with call to OpenSchema ($QueryType)");

		$rs->{Sort} = 'TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME, ORDINAL';
		return if DBD::ADO::Failed( $dbh,"Error occurred defining sort order ");

		while ( !$rs->{EOF} ) {
			my $ado_fields = [ Win32::OLE::in($rs->Fields) ];
			my @Fields = (map { $_->{Value} } Win32::OLE::in($rs->Fields) ) [ 0,1,2,3,6,7 ];
			push( @Rows, \@Fields );
			$rs->MoveNext;
		}

		$rs->Close; undef $rs;
		$conn->{CursorLocation} = $tmpCursorLocation;

		DBI->connect('dbi:Sponge:','','', { RaiseError => 1 })->prepare(
			$QueryType, { rows => \@Rows
			, NAME => [ qw( TABLE_CAT TABLE_SCHEM TABLE_NAME COLUMN_NAME KEY_SEQ PK_NAME ) ]
			, TYPE => [            12,         12,        12,         12,      5,     12   ]
		});
	}


	sub foreign_key_info {
		my( $dbh, @Criteria ) = @_;
		my $Criteria = \@Criteria if @Criteria;
		my $QueryType = 'adSchemaForeignKeys';
		my $RefActions = {
			'CASCADE'     => 0,
			'RESTRICT'    => 1,
			'SET NULL'    => 2,
			'NO ACTION'   => 3,
			'SET DEFAULT' => 4,
		};
		my @Rows;
		my $conn = $dbh->{ado_conn};
		my $tmpCursorLocation = $conn->{CursorLocation};
		$conn->{CursorLocation} = $ado_consts->{CursorLocationEnum}{adUseClient};

		my $rs = $conn->OpenSchema( $ado_consts->{SchemaEnum}{$QueryType}, $Criteria );
		return if DBD::ADO::Failed( $dbh,"Error occurred with call to OpenSchema ($QueryType)");

		$rs->{Sort} = 'PK_TABLE_CATALOG, PK_TABLE_SCHEMA, PK_TABLE_NAME, FK_TABLE_CATALOG, FK_TABLE_SCHEMA, FK_TABLE_NAME';
		return if DBD::ADO::Failed( $dbh,"Error occurred defining sort order ");

		while ( !$rs->{EOF} ) {
			my @Fields = (map { $_->{Value} } Win32::OLE::in($rs->Fields) ) [ 0..3,6..9,12..14,16,15,17 ];
			$Fields[ 9]  = $RefActions->{$Fields[ 9]};
			$Fields[10]  = $RefActions->{$Fields[10]};
			$Fields[13] += 4 if $Fields[13];
			push( @Rows, \@Fields );
			$rs->MoveNext;
		}

		$rs->Close; undef $rs;
		$conn->{CursorLocation} = $tmpCursorLocation;

		DBI->connect('dbi:Sponge:','','', { RaiseError => 1 })->prepare(
			$QueryType, { rows => \@Rows
			, NAME => [ qw( PKTABLE_CAT PKTABLE_SCHEM PKTABLE_NAME PKCOLUMN_NAME FKTABLE_CAT FKTABLE_SCHEM FKTABLE_NAME FKCOLUMN_NAME KEY_SEQ UPDATE_RULE DELETE_RULE FK_NAME PK_NAME DEFERRABILITY ) ]
			, TYPE => [              12,           12,          12,           12,         12,           12,          12,           12,      5,          5,          5,     12,     12,            5   ]
		});
	}

		sub type_info_all {
		my ($dbh) = @_;
		my $names = {
      TYPE_NAME		=> 0,
      DATA_TYPE		=> 1,
      COLUMN_SIZE		=> 2,
      LITERAL_PREFIX	=> 3,
      LITERAL_SUFFIX	=> 4,
      CREATE_PARAMS		=> 5,
      NULLABLE		=> 6,
      CASE_SENSITIVE	=> 7,
      SEARCHABLE		=> 8,
      UNSIGNED_ATTRIBUTE	=> 9,
      FIXED_PREC_SCALE	=>10,
      AUTO_UNIQUE_VALUE	=>11,
      LOCAL_TYPE_NAME	=>12,
      MINIMUM_SCALE		=>13,
      MAXIMUM_SCALE		=>14,
    };
		# Based on the values from the current provider.
		my @myti;
		# my $sth = $dbh->func('adSchemaProviderTypes','OpenSchema');

		# If the type information is previously obtained, use it.
		unless( $dbh->{ado_all_types_supported} ) {
			&_determine_type_support or
				Carp::croak "_determine_type_support failed: ", $dbh->{errstr};
		}

		my $ops = ado_open_schema( $dbh,'adSchemaProviderTypes');
		Carp::croak "ops undefined!" unless defined $ops;

		my $ado_info		= [ @{$ops->{NAME}} ];
		$ops->finish; $ops = undef;

		my $sponge = DBI->connect("dbi:Sponge:","","",{ PrintError => 1, RaiseError => 1 });
		Carp::croak "sponge return undefined: $DBI::errstr" unless defined $sponge;

		my $sth = $sponge->prepare("adSchemaProviderTypes", {
			rows=>   [ @{$dbh->{ado_all_types_supported}} ] , NAME=> $ado_info,
		});

		while ( my $row = $sth->fetchrow_hashref ) {
			my @tyinfo;
			# Only add items from the above names list.  When
			# this list explans, the code 'should' still work.
			for my $n (keys %{$names}){
				$tyinfo[ $names->{$n} ] = $row->{$n} || '';
			}
			push( @myti, \@tyinfo );
		}

		$sth->finish; $sth = undef;
		$sponge->disconnect; $sponge = undef;

		my $ti = [ $names, @myti ];

		return $ti;
	}


	# This is a function, not a method.
	sub _determine_type_support {
		my ($dbh) = @_;
		die 'dbh undefined' unless $dbh;

		$dbh->trace_msg("    -> _determine_type_support\n");

		my $conn = $dbh->{ado_conn};
		my $Enums = DBD::ADO::Const->Enums;
		my $Dt = $Enums->{DataTypeEnum};

    # Attempt to convert data types from ODBC to ADO.
    my %local_types = (
      DBI::SQL_BINARY()        => [
        $Dt->{adBinary}
      , $Dt->{adVarBinary}
      ]
    , DBI::SQL_BIT()           => [ $Dt->{adBoolean}]
    , DBI::SQL_CHAR()          => [
        $Dt->{adChar}
      , $Dt->{adVarChar}
      , $Dt->{adWChar}
      , $Dt->{adVarWChar}
      ]
    , DBI::SQL_DATE()          => [
        $Dt->{adDBTimeStamp}
      , $Dt->{adDate}
      ]
    , DBI::SQL_DECIMAL()       => [ $Dt->{adNumeric} ]
    , DBI::SQL_DOUBLE()        => [ $Dt->{adDouble} ]
    , DBI::SQL_FLOAT()         => [ $Dt->{adSingle} ]
    , DBI::SQL_INTEGER()       => [ $Dt->{adInteger} ]
    , DBI::SQL_LONGVARBINARY() => [
        $Dt->{adLongVarBinary}
      , $Dt->{adVarBinary}
      , $Dt->{adBinary}
      ]
    , DBI::SQL_LONGVARCHAR()   => [
        $Dt->{adLongVarChar}
      , $Dt->{adVarChar}
      , $Dt->{adChar}
      , $Dt->{adLongVarWChar}
      , $Dt->{adVarWChar}
      , $Dt->{adWChar}
      ]
    , DBI::SQL_NUMERIC()       => [ $Dt->{adNumeric} ]
    , DBI::SQL_REAL()          => [ $Dt->{adSingle} ]
    , DBI::SQL_SMALLINT()      => [ $Dt->{adSmallInt} ]
    , DBI::SQL_TIMESTAMP()     => [
        $Dt->{adDBTime}
      , $Dt->{adDBTimeStamp}
      , $Dt->{adDate}
      ]
    , DBI::SQL_TINYINT()       => [ $Dt->{adUnsignedTinyInt} ]
    , DBI::SQL_VARBINARY()     => [
        $Dt->{adVarBinary}
      , $Dt->{adLongVarBinary}
      , $Dt->{adBinary}
      ]
    , DBI::SQL_VARCHAR()       => [
        $Dt->{adVarChar}
      , $Dt->{adChar}
      , $Dt->{adVarWChar}
      , $Dt->{adWChar}
      ]
    , DBI::SQL_WCHAR()         => [
        $Dt->{adWChar}
      , $Dt->{adVarWChar}
      , $Dt->{adLongVarWChar}
      ]
    , DBI::SQL_WVARCHAR()      => [
        $Dt->{adVarWChar}
      , $Dt->{adLongVarWChar}
      , $Dt->{adWChar}
      ]
    , DBI::SQL_WLONGVARCHAR()  => [
        $Dt->{adLongVarWChar}
      , $Dt->{adVarWChar}
      , $Dt->{adWChar}
      , $Dt->{adLongVarChar}
      , $Dt->{adVarChar}
      , $Dt->{adChar}
      ]
    );

    my @sql_types = (
      DBI::SQL_BINARY()
    , DBI::SQL_BIT()
    , DBI::SQL_CHAR()
    , DBI::SQL_DATE()
    , DBI::SQL_DECIMAL()
    , DBI::SQL_DOUBLE()
    , DBI::SQL_FLOAT()
    , DBI::SQL_INTEGER()
    , DBI::SQL_LONGVARBINARY()
    , DBI::SQL_LONGVARCHAR()
    , DBI::SQL_NUMERIC()
    , DBI::SQL_REAL()
    , DBI::SQL_SMALLINT()
    , DBI::SQL_TIMESTAMP()
    , DBI::SQL_TINYINT()
    , DBI::SQL_VARBINARY()
    , DBI::SQL_VARCHAR()
    , DBI::SQL_WCHAR()
    , DBI::SQL_WVARCHAR()
    , DBI::SQL_WLONGVARCHAR()
    );

		# Get the Provider Types attributes.
		my @sort_rows;
		my %ct;
		my $rs = $conn->OpenSchema( $ado_consts->{SchemaEnum}{adSchemaProviderTypes} );
		return if DBD::ADO::Failed( $dbh,"OpenSchema error");

		my $ado_fields = [ Win32::OLE::in( $rs->Fields ) ];
		my $ado_info   = [ map { $_->Name } @$ado_fields ];

		while ( !$rs->{EOF} ) {
			# Sort by row
			my $type_name = $rs->{TYPE_NAME}->{Value};
			my $def;
			push ( @sort_rows,  $def = join(' '
			, $rs->{DATA_TYPE}->Value
			, $rs->{BEST_MATCH}->Value || 0
			, $rs->{IS_LONG}->Value || 0
			, $rs->{IS_FIXEDLENGTH}->Value || 0
			, $rs->{COLUMN_SIZE}->Value
			, $rs->{TYPE_NAME}->Value
			));
			$dbh->trace_msg("    -- data type $type_name: $def\n");
			@{$ct{$type_name}} = map { $rs->{$_}->Value || '' } @$ado_info;
			$rs->MoveNext;
		}
		$rs->Close if $rs &&
			$rs->State & $ado_consts->{ObjectStateEnum}{adStateOpen};
		$rs = undef;
		for my $t ( @sql_types ) {
			# Attempt to work with LONG text fields.
			# However for a LONG field, the order by ... isn't always the best pick.
			# Loop through the rows looking for something with a IS LONG mark.
			my $alt = join('|', @{$local_types{$t}} );
			my $re;
			if    ( $t == DBI::SQL_LONGVARCHAR()   ) { $re = qr{^($alt)\s\d\s1\s0\s}  }
			elsif ( $t == DBI::SQL_LONGVARBINARY() ) { $re = qr{^($alt)\s\d\s1\s0\s}  }
			elsif ( $t == DBI::SQL_VARBINARY()     ) { $re = qr{^($alt)\s1\s\d\s0\s}  }
			elsif ( $t == DBI::SQL_VARCHAR()       ) { $re = qr{^($alt)\s[01]\s0\s0\s}}
			elsif ( $t == DBI::SQL_WVARCHAR()      ) { $re = qr{^($alt)\s[01]\s0\s0\s}}
			elsif ( $t == DBI::SQL_WLONGVARCHAR()  ) { $re = qr{^($alt)\s\d\s1\s0\s}  }
			elsif ( $t == DBI::SQL_CHAR()          ) { $re = qr{^($alt)\s\d\s0\s1\s}  }
			elsif ( $t == DBI::SQL_WCHAR()         ) { $re = qr{^($alt)\s\d\s0\s1\s}  }
			else                                     { $re = qr{^($alt)\s\d\s\d\s}    }

			for ( sort { $b cmp $a } grep { /$re/ } @sort_rows ) {
				my ($cc) = m/\d+\s+(\D\w?.*)$/;
				Carp::carp "$cc does not exist in hash\n" unless exists $ct{$cc};
				my @rec = @{$ct{$cc}};
				$dbh->trace_msg("Changing type $rec[1] -> $t : @rec\n");
				$rec[1] = $t;
				push @{$dbh->{ado_all_types_supported}}, \@rec;
			}
		}
		$dbh->trace_msg("    <- _determine_type_support\n");
		return \@{$dbh->{ado_all_types_supported}};
	}

	sub _ado_get_type_info_for {
		my ($dbh, $AdoType, $IsFixed, $IsLong ) = @_;

		unless( $dbh->{ado_type_info_hash} ) {
			my $sth = $dbh->func('adSchemaProviderTypes','OpenSchema');
			while ( my $r = $sth->fetchrow_hashref ) {
				push @{$dbh->{ado_type_info_hash}{$r->{DATA_TYPE}}{$r->{IS_FIXEDLENGTH}}{$r->{IS_LONG}}}, $r;
			}
		}
		$dbh->{ado_type_info_hash}{$AdoType}{$IsFixed}{$IsLong} || [];
	}


  sub ado_open_schema {
    my ($dbh, $var, @crit) = @_;

    unless ( exists $ado_consts->{SchemaEnum}{$var} ) {
      return $dbh->set_err( -910,"OpenSchema called with unknown parameter: $var");
    }
    my $crit = \@crit if @crit;  # XXX: o.k.?
    my $conn = $dbh->{ado_conn};
    my $rs   = $conn->OpenSchema( $ado_consts->{SchemaEnum}{$var}, $crit );
    return if DBD::ADO::Failed( $dbh,"OpenSchema error");

    return _rs_sth_prepare( $dbh, $rs );
  }

  *OpenSchema = \&ado_open_schema;


	sub FETCH {
		my ($dbh, $attrib) = @_;
		# If the attribute contains ado_, return the value.
		$dbh->trace_msg( "->Fetch: $attrib\n", 3);
		my $value;
		if ( exists $dbh->{$attrib} ) {
			return $dbh->{$attrib};
		} else {
			eval {
				$attrib =~ s/^ado_//;
				local $Win32::OLE::Warn = 0;
				$value = $dbh->{ado_conn}->{$attrib};
				my $lastError = DBD::ADO::errors($dbh->{ado_conn});
				$lastError = undef if $lastError =~ m/0x80020007/;
				die "Died on:\n$lastError" if $lastError;
			};
		}
		return $value unless $@;
		# else pass up to DBI to handle
		return $dbh->SUPER::FETCH($attrib);
		# return $dbh->DBD::_::db::FETCH($attrib);
	}

	sub STORE {
		my ($dbh, $attrib, $value) = @_;
		# Patch from Simon Oliver
		$dbh->trace_msg( "-> Store: " . ($attrib||'undef') .
			" " . ($value||'undef') . "\n", 3);
		# Handle a request to change the AutoCommit value.
		# If the service provider supports Transaction,
		# then allow AutoCommit off.
		if ($attrib eq 'Warn' ) {
			$Win32::OLE::Warn = $value;
		}
		if ($attrib eq 'AutoCommit') {
			# Return the value is auto commit is not support and
			# value is not zero.  Handles defaults.
			return $value if $value
				and not $dbh->{ado_provider_support_auto_commit};
			# Cause the application to die, user attempting to
			# change the auto commit value.
			Carp::croak
				qq{Provider does not support auto commit: },
				$dbh->{ado_provider_auto_commit_comments},
				qq{\n}
			unless $dbh->{ado_provider_support_auto_commit};
			return $dbh->{AutoCommit} = _auto_commit($dbh, $value);
		}
		# If the attribute contains ado_, return the value.
		# Determine if this is one our expected parameters.
		# If the attribute is all lower case, then it is a driver
		# defined value.  If mixed case, then it is a ADO defined value.
		if ($attrib =~ m/^ado_/ || exists $dbh->{$attrib}) {
			return $dbh->{$attrib} = $value;
		} else {
			unless( $attrib =~ /PrintError|RaiseError/) {
			eval {
				local $Win32::OLE::Warn = 0;
				$dbh->{ado_conn}->{$attrib} = $value;
				my $lastError = DBD::ADO::errors($dbh->{ado_conn});
				die $lastError if $lastError;
			};
			Carp::carp $@ if $@ and $dbh->FETCH('Warn');
			return $value unless $@;
			}
		}
		return $dbh->SUPER::STORE($attrib, $value);
		# return $dbh->DBD::_::db::STORE($attrib, $value);
	}

  sub _auto_commit {
    my ( $dbh, $value ) = @_;

    my $cv = $dbh->FETCH('AutoCommit') || 0;

    if ( !$cv && $value ) { # Current off, turn on
      my $conn = $dbh->{ado_conn};
      $conn->{Attributes} = 0;
      return if DBD::ADO::Failed( $dbh,"Failed setting CommitRetaining");
      $dbh->commit;
      return 1;
    } elsif ( $cv && !$value ) {
      my $conn = $dbh->{ado_conn};
      $conn->{Attributes} = $ado_consts->{XactAttributeEnum}{adXactCommitRetaining}
                          | $ado_consts->{XactAttributeEnum}{adXactAbortRetaining};
      return if DBD::ADO::Failed( $dbh,"Failed setting CommitRetaining");
      $conn->BeginTrans;
      return if DBD::ADO::Failed( $dbh,"Begin Transaction Failed");
      return 0;
    }
    return $cv;  # Didn't change the value.
  }

  sub DESTROY {
    my ($dbh) = @_;
    $dbh->disconnect if $dbh->FETCH('Active');
    return;
  }

} # ======= Database Handle ========

{ package DBD::ADO::st; # ====== STATEMENT ======

  use strict;
  use Win32::OLE();
  use Win32::OLE::Variant();
  use DBD::ADO::TypeInfo();
  use DBD::ADO::Const();

  $DBD::ADO::st::imp_data_size = 0;

  my $ado_consts = DBD::ADO::Const->Enums;

  my $VT_I4_BYREF = Win32::OLE::Variant::VT_I4() | Win32::OLE::Variant::VT_BYREF();

	sub blob_read {
		my ($sth, $cnum, $offset, $lng, $attr) = @_;
		my $fld = @{$sth->{ado_fields}}[$cnum];
		my $str = "";
		if ($fld->Attributes & $ado_consts->{FieldAttributeEnum}{adFldLong}) {
			$str = $fld->GetChunk( $lng );
		} else {
			my $s = $fld->Value;
			$str = substr($s, $offset, $lng);
		}
		return( (defined($str) and length($str))? $str: "" );
	}

  # Determine the number of parameters, if Refresh fails.
  sub _params
  {
    my $sql = shift;
    use Text::ParseWords;
    $^W = 0;
    $sql =~ s/\n/ /;
    my $rtn = join( " ", grep { m/\?/ }
      grep { ! m/^['"].*\?/ } &quotewords('\s+', 1, $sql));
    my $cnt = ($rtn =~ tr /?//) || 0;
    return $cnt;
  }

  sub _refresh {
    my ( $sth ) = @_;
    $sth->trace_msg("    -> _refresh\n", 5 );
    my $conn = $sth->{ado_conn};
    my $comm = $sth->{ado_comm};

    my $Cnt = _params( $sth->FETCH('Statement') );

    for ( 0 .. $Cnt - 1 ) {
      my $Parameter = $comm->CreateParameter("$_",
        $ado_consts->{DataTypeEnum}{adVarChar},
        $ado_consts->{ParameterDirectionEnum}{adParamInput},
        1,
        "");
      return if DBD::ADO::Failed( $sth,"Unable to CreateParameter");

      $comm->Parameters->Append( $Parameter );
      return if DBD::ADO::Failed( $sth,"Append parameter failed ");
    }
    $sth->STORE('NUM_OF_PARAMS', $Cnt );
    $sth->trace_msg("    <- _refresh\n", 5 );
    return $Cnt;
  }

  sub bind_param {
    my ($sth, $pNum, $val, $attr) = @_;
    my $conn = $sth->{ado_conn};
    my $comm = $sth->{ado_comm};

    my $param_cnt = $sth->FETCH('NUM_OF_PARAMS') || _refresh( $sth );

    return $sth->set_err( -915,"Bind Parameter $pNum outside current range of $param_cnt.") if $pNum > $param_cnt || $pNum < 1;

    $sth->{ParamValues}{$pNum} = $val;

    my $i = $comm->Parameters->Item( $pNum - 1 );

    if ( defined $attr ) {
      if ( ref $attr ) {
        if ( exists $attr->{ado_type} ) {
          $i->{Type} = $attr->{ado_type};
        } elsif ( exists $attr->{TYPE} ) {
          $i->{Type} = $DBD::ADO::TypeInfo::dbi2ado->{$attr->{TYPE}};
        }
      } else {
        $i->{Type} = $DBD::ADO::TypeInfo::dbi2ado->{$attr};
      }
    }
    if ( defined $val ) {
      if ( $i->{Type} == $ado_consts->{DataTypeEnum}{adVarBinary} or
           $i->{Type} == $ado_consts->{DataTypeEnum}{adLongVarBinary}
      ) {
        # Deal with an image request.
        my $pic = Win32::OLE::Variant->new( Win32::OLE::Variant::VT_UI1() | Win32::OLE::Variant::VT_ARRAY(), 10 + length $val );  # $i->{Size}
        $pic->Put( $val );
        $i->{Value} = $pic;
        $sth->trace_msg("    -- Binary: $i->{Type} $i->{Size}\n");
      } else {
        $i->{Size}  = length $val;  # $val? length $val: $ado_type->[2];
        $i->{Value} = $val;         # $val if $val;
        $sth->trace_msg("    -- Type  : $i->{Type} $i->{Size}\n");
      }
    } else {
      $i->{Value} = Win32::OLE::Variant->new( Win32::OLE::Variant::VT_NULL() );
    }
    return 1;
  }

	sub execute {
		my ($sth, @bind_values) = @_;
		my $conn = $sth->{ado_conn};
		my $comm = $sth->{ado_comm};
		my $sql  = $sth->FETCH('Statement');

		# If a record set is currently defined, release the set.
		my $ors = $sth->{ado_rowset};
		if ( defined $ors ) {
			$ors->Close if $ors and
				$ors->State & $ado_consts->{ObjectStateEnum}{adStateOpen};
			$sth->{ado_rowset} = undef;
			$ors = undef;
		}

    # If the application is excepting arguments, then process them here.
    for ( 1 .. @bind_values ) {
      $sth->bind_param( $_, $bind_values[$_-1] ) or return;
    }

		my $lastError;

		my $rs;

		# Return the affected number to rows.
		my $rows = Win32::OLE::Variant->new( $VT_I4_BYREF, 0 );

		# At this point a command is ready to execute.  To allow for different
		# type of cursors, I need to create a recordset object.
		# However, a RecordSet Open does not return affected rows.  So I need to
		# determine if a recordset open is needed, or a command execute.

		# print "usecmd "    , exists $sth->{ado_usecmd}               , defined $sth->{ado_usecmd}               , "\n";
		# print "CursorType ", exists $sth->{ado_attribs}->{CursorType}, defined $sth->{ado_attribs}->{CursorType}, "\n";
		# print "cursortype ", exists $sth->{ado_cursortype}           , defined $sth->{ado_cursortype}           , "\n";
		# print "users "     , exists $sth->{ado_users}                , defined $sth->{ado_users}                , "\n";

		my $UseRecordSet = (
			not  ( exists $sth->{ado_usecmd}                and defined $sth->{ado_usecmd} )
			&& ( ( exists $sth->{ado_attribs}->{CursorType} and defined $sth->{ado_attribs}->{CursorType} )
			  || ( exists $sth->{ado_cursortype}            and defined $sth->{ado_cursortype} )
			  || ( exists $sth->{ado_users}                 and defined $sth->{ado_users} ) )
		);

		if ( $UseRecordSet ) {
			$rs = Win32::OLE->new('ADODB.RecordSet');
			return if DBD::ADO::Failed( $sth,"Can't create 'object ADODB.RecordSet'");

			# Determine the the CursorType to use.  The default is adOpenForwardOnly.
			my $cursortype = $ado_consts->{CursorTypeEnum}{adOpenForwardOnly};
			if ( exists $sth->{ado_attribs}->{CursorType} ) {
				my $type = $sth->{ado_attribs}->{CursorType};
				if ( exists $ado_consts->{CursorTypeEnum}{$type} ) {
					$sth->trace_msg("    -- Changing the cursor type to $type\n", 5 );
					$cursortype = $ado_consts->{CursorTypeEnum}{$type};
				} else {
					warn "Attempting to use an invalid CursorType: $type : using default adOpenForwardOnly";
				}
			}

			# Call to clear any previous error messages.
			$lastError = DBD::ADO::errors($conn);

			$sth->trace_msg("  -- Open record set using cursor type: $cursortype\n", 5 );
			$rs->Open( $comm, undef, $cursortype );
			return if DBD::ADO::Failed( $sth,"Can't execute statement '$sql'");
		} else {
			# Execute the statement, get a recordset in return.
			$rs = $comm->Execute( $rows );
			return if DBD::ADO::Failed( $sth,"Can't execute statement '$sql'");
		}
    $rows = $rows->Value;  # to make a DBD::Proxy client w/o Win32::OLE happy
    my $ado_fields = [];
    # some providers close the rs, e.g. after DROP TABLE
    if ( defined $rs and $rs->State ) {
		  $ado_fields = [ Win32::OLE::in($rs->Fields) ];
		  return if DBD::ADO::Failed( $sth,"Can't enumerate fields");
    }
    $sth->{ado_fields} = $ado_fields;
		my $num_of_fields = @$ado_fields;

		if ( $num_of_fields == 0 ) {  # assume non-select statement
			$sth->trace_msg("    -- no fields (non-select statement?)\n", 5 );
			# Clean up the record set that isn't used.
			if ( defined $rs and (ref $rs) =~ /Win32::OLE/) {
				$rs->Close if $rs and
					$rs->State & $ado_consts->{ObjectStateEnum}{adStateOpen};
			}
			$rs = undef;
			$sth->{ado_rows} = $rows;
			return $rows || '0E0';
		}

		# Current setting of RowsInCache?
		my $rowcache = $sth->FETCH('RowCacheSize');
		if ( defined $rowcache && $rowcache > 0 ) {
			my $currowcache = $rs->CacheSize;
			$sth->trace_msg("    -- changing the CacheSize using RowCacheSize: $rowcache\n", 5 );
			$rs->CacheSize( $rowcache ) unless $rowcache == $currowcache;
			return if DBD::ADO::Failed( $sth,"Unable to change CacheSize to RowCacheSize : $rowcache ");
			warn "Changed CacheSize\n";
		}

		$sth->STORE('Active'        , 1 );
		$sth->STORE('CursorName'    , undef );
		$sth->STORE('Statement'     , $rs->Source );
		$sth->STORE('RowsInCache'   , $rs->CacheSize );
		$sth->STORE('NUM_OF_FIELDS' , $num_of_fields ) unless $num_of_fields == $sth->FETCH('NUM_OF_FIELDS');
		$sth->STORE('NAME'          , [ map { $_->Name } @$ado_fields ] );
		$sth->STORE('TYPE'          , [ map { scalar DBD::ADO::TypeInfo::ado2dbi( $_->Type ) } @$ado_fields ] );
		$sth->STORE('PRECISION'     , [ map { $_->Precision } @$ado_fields ] );
		$sth->STORE('SCALE'         , [ map { $_->NumericScale } @$ado_fields ] );
		$sth->STORE('NULLABLE'      , [ map { $_->Attributes & $ado_consts->{FieldAttributeEnum}{adFldMayBeNull}? 1 : 0 } @$ado_fields ] );
		$sth->STORE('ado_type'      , [ map { $_->Type } @$ado_fields ] );

		# print 'May Defer', join(', ', map { $_->Attributes & $ado_consts->{FieldAttributeEnum}{adFldMayDefer} ? 1 : 0 } @$ado_fields ), "\n";
		# print 'Is Long  ', join(', ', map { $_->Attributes & $ado_consts->{FieldAttributeEnum}{adFldLong}     ? 1 : 0 } @$ado_fields ), "\n";

		$sth->{ado_rowset} = $rs;
		$sth->{ado_rownum} = 0;
		$sth->{ado_rows}   = $rows;  # $rs->RecordCount

		# We need to return a true value for a successful select
		# -1 means total row count unavailable
		return $rows || '0E0';  # seems more reliable than $rs->RecordCount
  }

	sub rows {
		my ($sth) = @_;
		return unless defined $sth;
		my $rc = $sth->{ado_rows};
		return defined $rc ? $rc : -1;
	}

  sub fetch {
    my ($sth) = @_;
    my $rs = $sth->{ado_rowset};

    return $sth->set_err( -900,'Statement handle not marked as Active.') unless $sth->FETCH('Active');
    return $sth->set_err( -905,'Recordset undefined, execute statement not called?') unless $rs;
    return if $rs->EOF;

    # required to not move from the current row until the next fetch is called.
    # blob_read reads the next record without this check.
    $rs->MoveNext if $sth->{ado_rownum} > 0;
    return if $rs->{EOF};
    return if DBD::ADO::Failed( $sth,'Fetch failed');

    my @row = map { $_->Value } Win32::OLE::in( $rs->Fields );
		# Jan Dubois jand@activestate.com addition to handle changes
		# in Win32::OLE return of Variant types of data.
		for ( @row ) {
			$_ = $_->As( Win32::OLE::Variant::VT_BSTR() )
				if UNIVERSAL::isa($_, 'Win32::OLE::Variant');
		}
    map { s/\s+$// } @row if $sth->FETCH('ChopBlanks');

    $sth->{ado_rownum}++;
    $sth->{ado_rows} = $sth->{ado_rownum};
    return $sth->_set_fbav( \@row );
  }

  *fetchrow_arrayref = \&fetch;

	sub finish {
		my ($sth) = @_;
		my $rs = $sth->{ado_rowset};
		$rs->Close () if $rs and
			$rs->State & $ado_consts->{ObjectStateEnum}{adStateOpen};
		$sth->{ado_rowset} = undef;
		return $sth->STORE(Active => 0);
	}

	sub FETCH {
    my ($sth, $attrib) = @_;
    # would normally validate and only fetch known attributes
    # else pass up to DBI to handle
		if ( exists $sth->{$attrib} ) {
			return $sth->{$attrib};
		}
    return $sth->SUPER::FETCH($attrib);
    # return $sth->DBD::_::dr::FETCH($attrib);
  }

	# Allows adjusting different parameters in the command and connect objects.

	my $change_affect = {
		ado_commandtimeout	=> 'CommandTimeout'
	};

  sub STORE {
    my ($sth, $attrib, $value) = @_;
    # would normally validate and only store known attributes
		if ( exists $sth->{$attrib} ) {
			if ( exists $change_affect->{$attrib} ) {
				# Only attempt to change the command if present.
				if (defined $sth->{ado_comm}) {
					$sth->{ado_comm}->{$change_affect->{$attrib}} = $value;
					return if DBD::ADO::Failed( $sth,"Store change $attrib: $value");
				}
			}
			return $sth->{$attrib} = $value;
		}
    # else pass up to DBI to handle
    return $sth->SUPER::STORE($attrib, $value);
    # return $sth->DBD::_::dr::STORE($attrib, $value);
  }

   sub DESTROY { # Statement handle
    my ($sth) = @_;
		$sth->trace_msg("<- destroy statement handler\n", 1 );

    # XXX: Necessary? Call finish()? Or is it called already?
    my $rs = $sth->{ado_rowset};
#   Carp::carp "Statement handle has active recordset" if defined $rs;
		$rs->Close ()
			if (defined $rs
				and UNIVERSAL::isa($rs, 'Win32::OLE')
				and ($rs->State != $ado_consts->{ObjectStateEnum}{adStateClosed}));
		$rs = undef;
		$sth->{ado_rowset} = undef;
    $sth->STORE(Active => 0);
		$sth->trace_msg("-> destroy statement handler\n", 1 );

		$sth = undef;
		return;
	} # Statement handle

}

1;

=head1 NAME

DBD::ADO - A DBI driver for Microsoft ADO (Active Data Objects)

=head1 SYNOPSIS

  use DBI();

  my $dbh = DBI->connect("dbi:ADO:$dsn", $usr, $pwd, $att ) or die $DBI::errstr;


=head1 DESCRIPTION

The DBD::ADO module supports ADO access on a Win32 machine.
DBD::ADO is written to support the standard DBI interface to
data sources.


=head1 PREREQUISITES

=over

=item DBI

=item Win32::OLE

=item ADO

It is strongly recommended that you use the latest version of ADO
(2.1 at the time this was written). You can download it from:

  http://www.microsoft.com/Data/download.htm

=back


=head1 Connection

Use the DBI connect method to establish a database connection:

  my $dbh = DBI->connect("dbi:ADO:$dsn", $usr, $pwd, $att ) or die $DBI::errstr;

where

  $dsn - is an ADO ConnectionString
  $usr - is a user name
  $pwd - is a password
  $att - is a hash reference with additional attributes

Typical connection attributes are

  RaiseError => 1
  PrintError => 0
  AutoCommit => 0

See the DBI module documentation for full details.

An ADO ConnectionString usually contains either a 'Provider' or a
'File Name' argument. If you omit these arguments, Provider defaults
to MSDASQL (Microsoft OLE DB Provider for ODBC). Therefore you can
pass an ODBC connection string (with DSN or DSN-less) as valid ADO
connection string.
If you use the OLE DB Provider for ODBC, it may be better to omit this
additional layer and use DBD::ODBC with the ODBC driver.

In addition the following attributes may be set in the connection string:

  Attributes
  CommandTimeout
  ConnectionString
  ConnectionTimeout
  CursorLocation
  DefaultDatabase
  IsolationLevel
  Mode

B<Warning:> The application is responsible for passing the correct
information when setting any of these attributes.

See the ADO documentation for more information on connection strings.

ADO ConnectionString examples:

  test
  File Name=test.udl
  Provider=Microsoft.Jet.OLEDB.4.0;Data Source=C:\data\test.mdb
  Provider=VFPOLEDB;Data Source=C:\data\test.dbc
  Provider=MSDAORA

For more examples, see e.g.:

  http://www.able-consulting.com/tech.htm


=head1 ADO-specific methods

=head2 ado_open_schema

  $sth = $dbh->ado_open_schema( $QueryType, @Criteria ) or die ...;

This method can be used to obtain database schema information from the
provider.
It returns a valid statement handle upon success.

C<$QueryType> may be any valid ADO SchemaEnum name such as

  adSchemaTables
  adSchemaIndexes
  adSchemaProviderTypes

C<@Criteria> (optional) is a list of query constraints depending on each
C<$QueryType>.

Example:

  my $sth = $dbh->ado_open_schema('adSchemaCheckConstraints','Catalog1');

B<Note:> With DBI version 1.36 and earlier, the func() method has to be used
to call private methods implemented by the driver:

  $h->func( @func_arguments, $func_name ) or die ...;

where C<$func_name> is 'ado_open_schema'.
You can use 'OpenSchema' for backward compatibility.

Example:

  my $sth = $dbh->func('adSchemaCheckConstraints','Catalog1','OpenSchema');

See ex/OpenSchema.pl for a working example.


=head1 DBI Methods

=head2 data_sources

Because ADO doesn't provide a data source repository, DBD::ADO uses it's
own. It tries to load Local::DBD::ADO::DSN and expects an array of hashes
describing the data sources. See ex/Local/DBD/ADO/DSN.pm for an example.

B<Warning:> This is experimental and may change.

B<Warning:> Check for the unlikly case that a file Local/DBD/ADO/DSN.pm
exists in your module search path which causes unwanted side effects when
loaded.

=head1 Enhanced DBI Methods

=head2 prepare

The B<prepare> methods allows attributes (see DBI):

  $sth = $dbh->prepare( $statement )          or die $dbh->errstr;
  $sth = $dbh->prepare( $statement, \%attr )  or die $dbh->errstr;

DBD::ADO's prepare() supports setting the CursorType, e.g.:

  $sth = $dbh->prepare( $statement, { CursorType => 'adOpenForwardOnly' } ) ...

Possible cursortypes are:

  adOpenForwardOnly (default)
  adOpenKeyset
  adOpenDynamic
  adOpenStatic

It may be necessary to prepare the statement using cursortype 'adOpenStatic'
when using a statement handle within a statement handle:

  while( my $table = $sth1->fetchrow_hashref ) {
    ...
    my $col = $sth2->fetchrow_hashref;
    ...
  }

Changing the CursorType is a solution to the following problem:

  Can't execute statement 'select * from authors':
  Lasterror : -2147467259
  OLE exception from "Microsoft OLE DB Provider for SQL Server":

  Cannot create new connection because in manual or distributed transaction
  mode.

  Win32::OLE(0.1403) error 0x80004005: "Unspecified error"
      in METHOD/PROPERTYGET "Open"

          Description : Cannot create new connection because in manual or distributed transaction mode.
          HelpContext : 0
          HelpFile    :
          NativeError : 0
          Number      : -2147467259
          Source      : Microsoft OLE DB Provider for SQL Server
          SQLState    :


=head2 bind_param

Normally, the datatypes of placeholders are known after the statement is
prepared. In this case, you don't need to provide any type information:

  $sth->bind_param( 1, $value );

Sometimes, you need to specify a type for the parameter, e.g.:

  $sth->bind_param( 1, $value, SQL_NUMERIC );

As a last resort, you can provide an ADO-specific type, e.g.:

  $sth->bind_param( 1, $value, { ado_type => 6 } );  # adCurrency

If no type is given (neither by the provider nor by you), the datatype
defaults to SQL_VARCHAR (adVarChar).


=head2 table_info

B<Warning:> This method is experimental and may change or disappear.

  $sth = $dbh->table_info(\%attr);

  $sth = $dbh->table_info({
    TABLE_TYPE => 'VIEW',
    ADO_Columns => 1,
    Trim_Catalog => 0,
    Filter => q{TABLE_NAME LIKE 'C%'},
  });

Returns an active statement handle that can be used to fetch
information about tables and views that exist in the database.
By default the handle contains the columns described in the DBI documentation:

  TABLE_CAT, TABLE_SCHEM, TABLE_NAME, TABLE_TYPE, REMARKS

=over

=item B<ADO_Columns>

Additional ADO-only fields will be included if the ADO_Columns attribute
is set to true:

  %attr = (ADO_Columns => 1);

=item B<Trim_Catalog>

Some ADO providers include path info in the TABLE_CAT column.
This information will be trimmed if the Trim_Catalog attribute is set to true:

  %attr = (Trim_Catalog => 1);

=item B<Criteria>

The ADO driver allows column criteria to be specified.  In this way the
record set can be restricted, for example, to only include tables of type 'VIEW':

  %attr = (TABLE_TYPE => 'VIEW')

You can add criteria for any of the following columns:

  TABLE_CAT, TABLE_SCHEM, TABLE_NAME, TABLE_TYPE

=item B<Filter>

=back

The ADO driver also allows the recordset to be filtered on a Criteria string:
a string made up of one or more individual clauses concatenated with AND or OR operators.

  %attr = (Filter => q{TABLE_TYPE LIKE 'SYSTEM%'})

The criteria string is made up of clauses in the form FieldName-Operator-Value.
This is more flexible than using column criteria in that the filter allows a number of operators:

  <, >, <=, >=, <>, =, or LIKE

The Fieldname must be one of the ADO 'TABLES Rowset' column names:

  TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE, DESCRIPTION,
  TABLE_GUID, TABLE_PROPID, DATE_CREATED, DATE_MODIFIED

Value is the value with which you will compare the field values
(for example, 'Smith', #8/24/95#, 12.345, or $50.00).
Use single quotes with strings and pound signs (#) with dates.
For numbers, you can use decimal points, dollar signs, and scientific notation.
If Operator is LIKE, Value can use wildcards.
Only the asterisk (*) and percent sign (%) wild cards are allowed,
and they must be the last character in the string. Value cannot be null.


=head2 tables

B<Warning:> This method is experimental and may change or disappear.

  @names = $dbh->tables(\%attr);

Returns a list of table and view names.
Accepts any of the attributes described in the L<table_info> method:

  @names = $dbh->tables({ TABLE_TYPE => 'VIEW' });


=head1 Error handling

An ADO provider may return a collection of more than one error. After
stringification , DBD::ADO concatenates these error messages to set the
errstr value of the handle.
However, the err value is set to the LastError known to Win32::OLE. Usually,
this is the native OLE DB error code. These codes contain the following
severity codes (see oledberr.h from the MDAC SDK):

  00 - Success
  01 - Informational
  10 - Warning
  11 - Error

The err value is set to 0 if all error codes belong to the Success or
Informational category, which doesn't trigger the normal DBI error
handling mechanisms.

The standard SQLSTATE is seldom supported by ADO providers and cannot be
relied on.

The db/st handle attribute 'ado_max_errors' limits the number of errors
extracted from the errors collection. To avoid time-consuming processing
of huge error collections, it defaults to 50.


=head1 CAVEATS

=head2 Character set

Proper Unicode support depends on all components involved in your
application: the DBMS, the ADO provider, Perl and some perl modules.

In short: Perl 5.8 and Win32::OLE 0.16 (or later) are strongly
recommended and Win32::OLE has to be prepared to use the correct
codepage:

  Win32::OLE->Option( CP => Win32::OLE::CP_UTF8 );

More detailed notes can be found at

  http://purl.net/stefan_ram/pub/perl_unicode_en

=head2 Type info

Support for type_info_all is supported, however, you're not using
a true OLE DB provider (using the MS OLE DB -> ODBC), the first
hash may not be the "best" solution for the data type.
adSchemaProviderTypes does provide for a "best match" column, however
the MS OLE DB -> ODBC provider does not support the best match.
Currently the types are sorted by DATA_TYPE BEST_MATCH IS_LONG ...


=head1 AUTHORS

Tim Bunce and Phlip. With many thanks to Jan Dubois and Jochen Wiedmann
for additions, debuggery and general help.
Special thanks to Thomas Lowery, who maintained this module 2001-2003.
Current maintainer is Steffen Goeldner.


=head1 SUPPORT

This software is supported via the dbi-users mailing list.
For more information and to keep informed about progress you can join the
mailing list by sending a message to dbi-users-help@perl.org

Please post details of any problems (or changes you needed to make) to
dbi-users@perl.org and CC them to me (sgoeldner@cpan.org).


=head1 COPYRIGHT

  Copyright (c) 1998, Tim Bunce
  Copyright (c) 1999, Tim Bunce, Phlip, Thomas Lowery
  Copyright (c) 2000, Tim Bunce, Thomas Lowery
  Copyright (c) 2001, Tim Bunce, Thomas Lowery, Steffen Goeldner
  Copyright (c) 2002, Thomas Lowery, Steffen Goeldner
  Copyright (c) 2003, Thomas Lowery, Steffen Goeldner
  Copyright (c) 2004, Steffen Goeldner

  All rights reserved.

  You may distribute under the terms of either the GNU General Public
  License or the Artistic License, as specified in the Perl README file.


=head1 SEE ALSO

=head2 Books

  ADO Reference book:  ADO 2.0 Programmer's Reference
  David Sussman and Alex Homer
  Wrox
  ISBN 1-861001-83-5

If there's anything better please let me know.

=head2 Perl modules

L<DBI>, L<DBD::ODBC>, L<Win32::OLE>

=cut
