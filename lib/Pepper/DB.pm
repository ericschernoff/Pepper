package Pepper::DB;

# please see pod documentation included below
# perldoc Majestica::DB

$Pepper::VERSION = '7.0';

# load needed third-part modules
use DBI; # tim bounce, where would the world be without you? nowhere.
use Try::Tiny;

# for checking the status of the DBI reference
use Scalar::Util qw(blessed);

# time to grow up
use strict;

# create ourself and connect to the database
sub new {
	my $class = shift;

	# grab args, which will be the connect_to_database and the system config hash from the UtilityBelt
	my ($connect_to_database, $config) = @_;

	# if $connect_to_database is empty, go with the main 'information_schema' system database
	$connect_to_database ||= "information_schema";

	# cannot do a thing without the %$config - hard death
	if (ref($config) ne 'HASH' || !$$config{database_username} || !$$config{database_password}) {
		die "Cannot create DB object and continue without valid %$config hash.\n";
	}
	
	# default DB server is localhost
	$$config{database_server} ||= '127.0.0.1';
	
	# make the object
	my $self = bless {
		'config' => $config, 
		'database_server' => $database_server,
		'current_database' => $connect_to_database,
		'created' => time(),
	}, $class;

	# now connect to the database and get a real DBI object into $self->{dbh}
	$self->connect_to_database();

	return $self;
}

# special method to connect or re-connect to the database
sub connect_to_database {
	my $self = shift;
	
	# only do this if $self->{dbh} is not already a DBI object
	return if $self->{dbh} && blessed($self->{dbh}) =~ /DBI/ && 
		( ( time()-$self->{connect_time} ) < 5 || $self->{dbh}->ping );

	my ($username, $password, $credentials, $dsn, $salt_phrase);

	# make the connection - fail and log if cannot connect
	$dsn = 'DBI:mysql:database='.$self->{current_database}.';host='.$self->{database_server}.';port=3306';
	$self->{dbh} = DBI->connect($dsn, $self->{config}{database_username}, $self->{config}{database_password},{ 
		PrintError => 1, 
		RaiseError => 1, 
		AutoCommit => 0,
		mysql_enable_utf8 => 8
	}) or $self->log_errors('Cannot connect to '.$self->{database_server});

	# Set Long to 1000000 for long text...may need to adjust this
	$self->{dbh}->{LongReadLen} = 1000000;

	# let's automatically reconnect if the connection is timed out
	$self->{dbh}->{mysql_auto_reconnect} = 1;
	# note that this doesn't seem to work too well

	# let's use UTC time in DB saves
	$self->do_sql(qq{set time_zone = '+0:00'});

	# no pings for the first 5 seconds
	$self->{connect_time} = time();
	
	# $self->{dbh} is now ready to go
}

# method to make sure I am alive
sub your_birthdate {
	my $self = shift;

	# make sure we are connected to the DB
	$self->connect_to_database();

	# pull and return the info
	my ($created) = $self->quick_select('select from_unixtime('. $self->{'created'}.')');
	return $created;
}

# method to change the current working database for a connection
sub change_database {
	# required argument is the database they want to switch into
	my ($self,$database_name) = @_;

	# nothing to do if that's not specified
	return if !$database_name;

	# no funny business
	return 'Bad Name' if $database_name =~ /[^a-z0-9\_]/i;

	# put in object attribute
	$self->{current_database} = $database_name;

	# make sure we are connected to the DB
	$self->connect_to_database();

	# pretty easy
	$self->{dbh}->do(qq{use $database_name});

}


# comma_list_select: same as list_select, but returns a commafied list rather than an array
sub comma_list_select {
	# grab args
	my ($self,$sql,$bind_values) = @_;

	# rely on our brother upstairs
	my $results = $self->list_select($sql,$bind_values);

	# nothing found?  just return
	if (!$$results[0]) {
		return;
	} else { # otherwise, return our comma-separated version of this
		return join(',',@$results);
	}
}

# utility method to commit changes; I know DBI does it.  This is how I want to do it.
sub commit {
	my $self = shift;
	$self->do_sql('commit');
}

# decrypt_string: a method to decrypt a base64-encoded and encrypted string
sub decrypt_string {
	# the arguments are the string to encrypt and the 'salt' value
	my ($self,$encoded_and_encrypted_string,$salt_phrase) = @_;

	# first required is very much required
	return if !$encoded_and_encrypted_string;

	# if no salt is sent, use $self->{config}{salt_phrase}, failing that, default to the truth
	$salt_phrase ||= $self->{config}{salt_phrase};
	$salt_phrase ||= 'AllHailGinger'; # please set up a $salt_phrase

	# make sure we are connected to the DB
	$self->connect_to_database();
	
	# pull out the information
	my ($plain_text_string) = $self->quick_select(qq{
		select AES_DECRYPT(FROM_BASE64(?),SHA2(?,512))
	},[ $encoded_and_encrypted_string, $salt_phrase ]);

	# send it out
	return $plain_text_string;
}

# helper method to generate the SQL code to decrypt a two-way encrypted column
# used for data_loader in BaseModel
sub decrypt_string_sql {
	# required argument is the name of the DB column
	my ($self,$column_name) = @_;

	return if !$column_name;
	
	# if no salt is sent, use $self->{config}{salt_phrase}, failing that, default to the truth
	my $salt_phrase ||= $self->{config}{salt_phrase};
	$salt_phrase ||= 'AllHailGinger'; # please set up a $salt_phrase
	
	return qq{AES_DECRYPT(FROM_BASE64($column_name),SHA2('$salt_phrase',512))};
}

# do_sql: our most flexible way to execute SQL statements
sub do_sql {
	# grab args
	my ($self,$sql,$bind_values) = @_;

	# declare vars
	my ($results, $sth, $cleared_deadlocks);

	# sql statement to execute and if placeholders used, arrayref of values

	# make sure we are connected to the DB
	$self->connect_to_database();

	# i shouldn't need this, but just in case
	if (!$self->{dbh}) {
		$self->log_errors(qq{Missing DB Connection for $sql.});
	}

	# prepare the SQL
	$sth = $self->{dbh}->prepare($sql) or $self->log_errors(qq{Error preparing $sql: }.$self->{dbh}->errstr());
	
	# ready to execute, but we want to plan for some possible deadlocks, since InnoDB is still not perfect
	$cleared_deadlocks = 0;
	while ($cleared_deadlocks == 0) {
		$cleared_deadlocks = 1; # if it succeeds once, we can stop
		# attempt to execute; catch any errors and keep retrying in the event of a deadlock
		try {
			# use $@values if has placeholders
			if ($bind_values) {
				$sth->execute(@$bind_values);
			} else { # plain-jane
				$sth->execute;
			}
		}
		# catch the errors
		catch {
			if ($_ =~ /Deadlock/) { # retry after three seconds
				sleep(3);
				$cleared_deadlocks = 0;
			} else { # regular error: rollback, log error, and die
				$self->{dbh}->rollback;
				$$bind_values[0] = 'No values';
				$self->log_errors(qq{Error executing $sql (@$bind_values): }.$_);
				$cleared_deadlocks = 1;
			}
		}
	}

	# i like pretty formatting/spacing for my code, maybe too much
	$sql =~ s/^\s+//g;

	# if SELECT, grab all the results into a arrayref of arrayrefs
	if ($sql =~ /^select|^show|^desc/i) {
		# snatch it
		$results = $sth->fetchall_arrayref;
		# here's how you use this:
		# while (($one,$two) = @{shift(@$results)}) { ... }

		# clean up
		$sth->finish;

		# send out results
		return $results;

	# if it is an insert, let's stash the last-insert ID, mainly for BaseModel's save()
	} elsif ($sql =~ /^(insert|replace)/i) {
		$self->{last_insert_id} = $sth->{'mysql_insertid'};
	}

	# any finally, clean (will only still be here for insert, replace, or update statements)
	$sth->finish;
}

# encrypt_string: a method to encrypt plain text and return a base64 version of that encrypted value
sub encrypt_string {
	# the arguments are the string to encrypt and the 'salt' value
	my ($self,$plain_text_string,$salt_phrase) = @_;

	# return blank if no plain text
	return if !$plain_text_string;

	# if no salt is sent, use $self->{config}{salt_phrase}, failing that, default to the truth
	$salt_phrase ||= $self->{config}{salt_phrase};
	$salt_phrase ||= 'AllHailGinger'; # please set up a $salt_phrase

	# make sure we are connected to the DB
	$self->connect_to_database();

	# encode the string
	my ($encoded_and_encrypted_string) = $self->quick_select(qq{
		select TO_BASE64( AES_ENCRYPT(?,SHA2(?,512)) )
	},[ $plain_text_string, $salt_phrase ]);


	# ship it out
	return $encoded_and_encrypted_string;
}

# methods to pack/unpack base64
sub to_base64 {
	my ($self, $regular_string) = @_;
	
	my ( $base64_string ) = $self->quick_select(
		'select TO_BASE64(?)', [ $regular_string ]
	);	
	
	return $base64_string;
}
sub from_base64 {
	my ($self, $base64_string) = @_;
	
	my ( $regular_string ) = $self->quick_select(
		'select FROM_BASE64(?)', [ $base64_string ]
	);	
	
	return $regular_string;
}

# grab_column_list: get a comma list of column names for a table
sub grab_column_list {
	# grab args
	my ($self,$database,$table) = @_;
	# database name, table name, and optional 1 indicating to leave off the 'concat(code,'_',server_id),parent' bit

	my ($cols) = $self->quick_select(qq{
		select group_concat(column_name) from information_schema.columns
		where table_schema=? and table_name=? and column_key !='PRI'
	},[$database, $table]);

	# send it out
	return $cols;
}

# list_select: easily execute sql SELECTs that will return a simple array; returns an arrayref
sub list_select {

	# grab args
	my ($self,$sql,$bind_values) = @_;
	# sql statement to execute and if placeholders used, arrayref of values

	# declare vars
	my ($sth, @data, @sendBack);

	# make sure we are connected to the DB
	$self->connect_to_database();

	# we should never have this error condition, but just in case
	if (!$self->{dbh}) {
		$self->log_errors(qq{Missing DB Connection for $sql.});
	}

	if (not $self->{belt}->{all_hail}) { # set it up
		$self->{belt} = Majestica::Core::UtilityBelt->new();
	}
	
	# prep & execute the sql
	$sth = $self->{dbh}->prepare($sql);
	# use $@values if has placeholders
	if ($bind_values) {
		$sth->execute(@$bind_values) or $self->log_errors(qq{Error executing $sql: }.$self->{dbh}->errstr);

	} else { # place-jane
		$sth->execute or $self->log_errors(qq{Error executing $sql: }.$self->{dbh}->errstr);
	}
	
	# grab the data & toss it into an array
	while ((@data)=$sth->fetchrow_array) {
		push(@sendBack,$data[0]); # take left most one, so it's 100%, for-sure one-dimensional (no funny business)
	}

	# send back the arrayref
	return \@sendBack;
}

# subroutine to use the utility_belt's logging and return functions to capture errors and return a proper message
# doing this route because often this class won't have the utility belt because it is called before the belt is set up
sub log_errors {
	my ($self,$error_message) = @_;

	# default message in cause of blank
	$error_message ||= 'Database error.';

	# do we have utility belt?  if built within pack_luggage(), we will
	if (not $self->{belt}->{all_hail}) { # set it up
		$self->{belt} = Majestica::Core::UtilityBelt->new();
	}

	# log and then send the message
    $self->{belt}->logger($error_message,'database_errors');
    $self->{belt}->send_response($error_message,1);

}

# quick_select: easily execute sql SELECTs that will return one row; returns live array
sub quick_select {
	# grab args
	my ($self,$sql,$bind_values) = @_;
	# sql statement to execute and if placeholders used, arrayref of values

	# declare vars
	my (@data, $sth);

	# make sure we are connected to the DB
	$self->connect_to_database();

	# we should never have this error condition, but just in case
	if (!$self->{dbh}) {
		$self->log_errors(qq{Missing DB Connection for $sql.});
	}

	# prep & execute the sql
	$sth = $self->{dbh}->prepare($sql);

	# use $@values if has placeholders
	if ($$bind_values[0]) {
		$sth->execute(@$bind_values) or die $sth->errstr; # or $self->log_errors(qq{Error executing $sql (@$bind_values): }.$self->{dbh}->errstr);
	} else { # plain-jane
		$sth->execute or die $sth->errstr; # or $self->log_errors(qq{Error executing $sql: }.$self->{dbh}->errstr);
	}

	# grab the data
	(@data) = $sth->fetchrow_array;

	# return a real, live array, not a memory reference for once...just easier this way,
	# since much of the time, you are just sending a single piece of data
	return (@data);
}

# sql_hash: take an sql command and return a hash of results; my absolute personal favorite
sub sql_hash {
	# grab args: the sql_statement text string (required), then an arrayref for bind-variables (highly-recommended)
	# and then an arrayref of alternative sub-key names for your second-level hashes
	my ($self, $sql, $bind_values, $names) = @_;
	# the command to run and optional: list of names to key the data by...if blank, i'll use @cols from the sql

	# declare vars
	my ($c, $cnum, $columns, $key, $kill, $num, $rest, $sth, %our_hash, @cols, @data, @keys);

	if (!$$names[0]) { # determine the column names and make them an array
		($columns,$rest) = split /\sfrom\s/i, $sql;
		$columns =~ s/count\(\*\)\ as\ //; # allow for 'count(*) as NAME' columns
		$columns =~ s/select|[^0-9a-z\_\,]//gi; # take out "SELECT" and spaces
		$columns =~ s/\,\_\,/_/; # account for a lot of this: concat(code,'_',server_id)

		(@$names) = split /\,/, $columns;
		$kill = shift (@$names); # kill the first one, as that one will be our key
	}

	# make sure we are connected to the DB
	$self->connect_to_database();

	# this is easy: run the command, and build a hash keyed by the first column, with the column names as sub-keys
	# note that this works best if there are at least two columns listed
	$num = 0;
	if (!$self->{dbh}) {
		$self->log_errors(qq{Missing DB Connection for $sql.});
	}
	
	# prep & execute the sql
	$sth = $self->{dbh}->prepare($sql);

	# placeholders?
	if ($$bind_values[0]) {
		$sth->execute(@$bind_values) or $self->log_errors(qq{Error executing $sql: }.$self->{dbh}->errstr);
	} else {
		$sth->execute or $self->log_errors(qq{Error executing $sql: }.$self->{dbh}->errstr);
	}

	# this does not seem any faster, oddly:
	# my ($results_arrays, $result_array);
	#$results_arrays = $self->{dbh}->selectall_arrayref($sql, {}, @$bind_values) 
	#	or $self->log_errors(qq{Error executing $sql: }.$self->{dbh}->errstr);

	# foreach $result_array (@$results_arrays) {
	while(($key,@data)=$sth->fetchrow_array) {
		# $key = shift @$result_array;
		$cnum = 0;
		foreach $c (@$names) {
			$our_hash{$key}{$c} = $data[$cnum]; # shift @$result_array; # 
			$cnum++;
		}
		$keys[$num] = $key;
		$num++;
	}

	# return a reference to the hash along with the ordered set of keys
	return (\%our_hash, \@keys);
}

# empty destroy for now
sub DESTROY {
	my $self = shift;
	
	# have to do this since we have autocommit off
	$self->do_sql('rollback');
}

# all done
1;

__END__