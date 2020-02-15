package Pepper::CGIHandler;

# for encoding and decoding JSON
use Cpanel::JSON::XS;
use CGI;                             # load CGI routines
use strict;

# https://metacpan.org/pod/distribution/CGI/lib/CGI.pod#HTTP-COOKIES

sub new {

}

sub fetch_params {

} 

sub get_cookies {

}

sub set_cookies {

}

sub send_response {

}

1;
 
 
my $q = CGI->new;                    # create new CGI object
print $q->header;                    # create the HTTP header


# please see pod documentation included below
# perldoc Majestica::Core::UtilityBelt

$Majestica::Core::UtilityBelt::VERSION = '7.0';

# need some date/time toys
use Date::Format;
use DateTime;
use Date::Manip::Date;

# for show_data_structure
use Data::Dumper;

# for logging via logger() as well as the filer() method
use Path::Tiny;

# for utf8 support
use utf8;
use Encode qw( encode_utf8 );

# for encoding and decoding JSON
use Cpanel::JSON::XS;

# for converting ranges of numbers to lists of numbers
use Number::Range;

# for archiving log files
use Gzip::Faster;

# for testing recaptcha submissions
use WWW::Mechanize;

# for benchmarker routine
use Benchmark ':hireswallclock';
use Proc::ProcessTable;

# for getting the current domain name
use Net::Domain qw( hostdomain );

# for get_mime_type
use MIME::Types;

# for loading up the DB handle
use Majestica::Core::DB;

# for looking up users and the recaptcha key
use Majestica::Components::SystemAdmin::Models::SystemUsers;
use Majestica::Components::SystemAdmin::Models::CertainInformation;

# for generating HTML (error screen)
use Majestica::Core::View;

# time to grow up
use strict;

# two ways to create ourself
# for calling web majestica.psgi
sub psgi_new {
	my $class = shift;

	# majestica.psgi will send the Plack request and response objects, 
	# and the database object
	my ($request, $response, $db) = @_;

	my $self = bless {
		'all_hail' => 'ginger', 		# for proof-of-life
		'created' => time(),			# for verifying the same $belt across requests
		'start_benchmark' => Benchmark->new,	# for benchmarker() below
		'request' => $request,		# the Plack request object; will bet sent from majestica.psgi
		'response' => $response,	# the Plack response object; will net sent from majestica.psgi
		'json_coder' => Cpanel::JSON::XS->new->utf8->allow_nonref->allow_blessed,
	}, $class;
	
	# read in the system configuration
	$self->read_system_configuration();

	# connect to the database
	$self->{db} = Majestica::Core::DB->new('majestica_dispatcher', $self->{config});

	# now load up our PSGI params and environment, including our auth cookie
	$self->pack_psgi_variables();

	# now determine which application/database we are addressing
	# actually need lots of key information, so let's not be shy....
	
	# use the hostname we found in pack_psgi_variables() to ID the application
	my ($application_id) = $self->{db}->quick_select(qq{
		select id from majestica.applications where hostname=? and is_active='Yes'
	},[ $self->{hostname} ]);

	# then use our fancy info-grab utility below
	$self->get_application_info($application_id) if $application_id; 

	# go into that database
	$self->{db}->change_database( $self->{database_name} );

	# OK, if this is an open-access app, we do not need to mess with the authentication at all
	if ($self->{authentication_type} eq 'Open Access (No Auth)') {
		$self->{user_id} = 20020415;
		$self->{two_factor_code} = 1;
		return $self;
	}
	
	# otherwise, we must try to authenticate
	my $user_authenticator = Majestica::Core::UserAuthenticator->new( $self );
	$user_authenticator->web_authenticator($application_id);

	# if a user was found, load them up and pack into into %$self
	if ($self->{user_id}) {
		$self->get_user_info();
	}

	# ready to go; send out lots of goodies
	return $self;
}

# for creating via a script:
sub new {
	my $class = shift;

	# they send in the current database name, and the current user ID
	my ($database_name, $user_id) = @_;

	$database_name ||= 'majestica_dispatcher';
	$user_id ||= 1;

	my $self = bless {
		'all_hail' => 'ginger', 		# for proof-of-life
		'created' => time(),			# for verifying the same $belt across requests
		'start_benchmark' => Benchmark->new,	# for benchmarker() below
		'database_name' => $database_name,
		'user_id' => $user_id,
		'json_coder' => Cpanel::JSON::XS->new->utf8->allow_nonref->allow_blessed,
	}, $class;

	# read in the system configuration
	$self->read_system_configuration();
	
	# $self->benchmarker('blessed belt');
	
	# connect to the database
	$self->{db} = Majestica::Core::DB->new($database_name, $self->{config});
	# $self->benchmarker('belt connected to DB');

	# now determine which application/database we are addressing
	# query our 'applications' table for the application details, including trial status
	my ($application_id) = $self->{db}->quick_select(qq{
		select id from majestica.applications where database_name=? and is_active='Yes'
	}, [ $self->{database_name} ] );

	# then use our fancy info-grab utility for the rest
	$self->get_application_info($application_id) if $application_id; 

	# put hostname in place (gets fixed in plack-mode_
	$self->{hostname} = $self->{the_hostname};

	# load the user information, below
	$self->get_user_info() if $user_id;

	# ready to go
	return $self;
}

# method shared by both new's to get the current user's info and access level
sub get_user_info {
	my $self = shift;

	# use our system object
	$self->{system_users} = $self->get_model_object('SystemAdmin/SystemUsers',{
		'skip_check_table_readiness' => 1,
	});

	# load the user up
	$self->{system_users}->{load_scary_fields} = 1; # these fields are OK for this use
	$self->{system_users}->load( $self->{user_id} );

	# add them to our object
	$self->{user_info} = $self->{system_users}->{data};

	# set the time zone
	$self->{time_zone_name} = $self->{user_info}{time_zone_name};

	# CSRF for forms - web mode only
	if ($self->{request}) {
		my $csrf_tokens = $self->get_model_object('SystemDispatcher/CSRFTokens');
		$self->{csrf_token} = $csrf_tokens->get_csrf_token( $self->{user_id} );
	}

}

# method to log benchmarks for execution times and memory; useful for debugging and finding chokepoints
sub benchmarker {
	my ($self,$log_message,$log_name,$log_memory) = @_;

	# return if no log message
	return if !$log_message;

	# default log filename to 'benchmarks'
	$log_name ||= 'benchmarks';

	my ($right_now, $benchmark, $pt, %info, $memory_size, $milliseconds);

	# if we are benchmarking, we need to skip the part of logger where it archives old logs
	$self->{skip_log_archiving} = 1;

	# figure the benchmark for this checkpoint / log-message
	# will be from the creation of $self, which is practically the start of the execution
	$right_now = Benchmark->new;
	$benchmark = timediff($right_now, $self->{start_benchmark});

	# all I care about is milliseconds
	$milliseconds = sprintf("%.3f", (1000 * $benchmark->real) );

	if ($log_memory) { # logging memory is optional, because it does add time
		# figure out the current memory usage for this process - stolen from https://blog.celogeek.com/201312/394/perl-universal-way-to-get-memory-usage-of-a-process/
		$pt = Proc::ProcessTable->new;
		%info = map { $_->pid => $_ } @{$pt->table};
		$memory_size = $info{$$}->rss;
		# we care about megs
		$memory_size = sprintf("%.2f", ( $memory_size / 1048576));

		# now log out the benchmark, for saving in DESTROY
		push(@{ $self->{benchmarks}{$log_name} }, $log_message.' at '.$milliseconds. 'ms / Memory Size: '.$memory_size.' mb / Process ID: '.$$);

	# standard logging, no memory
	} else {
		# now log out the benchmark, for saving in DESTROY
		push(@{ $self->{benchmarks}{$log_name} }, $log_message.' at '.$milliseconds. 'ms / Process ID: '.$$);
	}

	# all done
}

# start routine to turn an array (reference) to flat string, separated by commas (or whatever)
sub comma_list {
	# declare vars
	my ($nice_list, $piece, $real_list);

	# grab args
	my ($self,$list,$delimiter) = @_;

	# default delimiter is a comma
	$delimiter ||= ',';

	# make it sort, no dups
	$real_list = $self->uniquify_list($list);

	# turn that list into a nice comma-separated list
	$nice_list = join($delimiter, @$real_list);

	# send it out
	return $nice_list;
}

# subroutine to convert strings from snake_case to CamelCase
sub camelize {
	# required arg is the string to convert
	my ($self,$snake_case_string) = @_;
	
	# cannot do much without that
	return if !$snake_case_string;

	my ($part, $camelCaseString);
	foreach $part (split /[^a-z0-9]/i, $snake_case_string) {
		$camelCaseString .= ucfirst($part);
	}
	
	return $camelCaseString;
}

# reverse of the above
sub decamelize {
	# required arg is the string to convert
	my ($self,$camelCaseString) = @_;
	
	# cannot do much without that
	return if !$camelCaseString;

	my ($part, $snake_case_string);
	foreach $part (split/(?=[A-Z])/, $camelCaseString) {
		next if !$part;
		$snake_case_string .= lc($part).'_';
	}
	$snake_case_string =~ s/\_$//;
	# that is really bad, and I should know better how to do this right by now
	
	return $snake_case_string;
}

# provide a percentage from a portion/total pair
sub calculate_percentage {
	my ($self, $portion, $total) = @_; # first number is 'base'
	
	if ($total > 0 && $portion > 0) { # calculate the growth, and leave one decimel
		return sprintf("%.2f", 100 * ($portion/$total) ).'%';
		
	} else { # not applicable
		return 'N/A';
	}
}

# subroutine to strip special chars from a string
sub clean_string {
	my ($self, $dirty_string, $remove_spaces) = @_;
	
	my $clean_string;
	($clean_string = $dirty_string) =~ s/[^0-9a-z\s]//gi;
	
	if ($remove_spaces) {
		$clean_string =~ s/\s/_/g;
	}
	
	return $clean_string;
}

# subroutine to give numbers commas, like dollars
# ripped off of the Perl Cookbook, page 85
sub commaify_number {
	my ($self,$num,$need_dollar_sign, $remove_trailing_zeros) = @_;
	# $num is kind of reqired
	$num = '0' if !length($num);
	
	# round to two decimels
	$num = sprintf("%.2f", $num) if $num =~ /\./;

	# convert 1000 to 1,000
	$num = reverse $num;
	$num =~ s/(\d\d\d)(?=\d)(?!\d*\.)/$1,/g;

	# here we go:
	my $nice_num = scalar reverse $num;

	if ($remove_trailing_zeros) {
		$nice_num =~ s/\.00$//;
	}
	
	if ($need_dollar_sign) { # money, money, money
		return '$'.$nice_num;
	} else { # plain
		return $nice_num;
	}
}

# laziness
sub commit {
	my $self = shift;
	$self->{db}->commit();
}

# start the dateFix subroutine, where we humanify database dates
sub date_fix {
	my ($self,$date) = @_; # will be in YYYY-MM-DD format
	my ($year,$month,$day,$dt);

	# no wise-guys
	return 'Sept. 4, 1976' if $date !~ /[0-9]{4}\-[0-9]{2}\-[0-9]{2}/;

	# let's cut the BS and use MySQL
	my ($nice_date) = $self->{db}->quick_select(qq{
		select date_format(?,'%b %e, %Y')
	},[$date]);

	return $nice_date;

}

# start the diff_percent subroutine, where we calculate the growth/shrink percentage between two numbers
sub diff_percent {
	# declare vars and grab args
	my ($self,$first,$second) = @_; # first number is 'base'
	my ($difference);
	
	if ($first > 0) { # calculate the growth, and leave one decimel
		$difference = 100 * (($second - $first) / $first);
		$difference = sprintf("%.1f", $difference);
	} else { # not applicable
		$difference = qq{N/A};
	}

	# send it out
	return $difference;

}

# subroutine to calculate the number of days, hours, or minutes SINCE an epoch
sub figure_age {
	# required argument is the epoch to test against
	my ($self, $past_epoch) = @_;

	my ($delta, $minutes, $hours, $days, $weeks, $dt1, $dt2, $dur, $months);

	# the argument they sent must be an integar, before the current timetamp
	if (!$past_epoch || $past_epoch =~ /\D/ || $past_epoch > time()) {
		return 'Unknown';
	}

	# get the delta and proceed accordingly
	$delta = time() - $past_epoch;

	# less than two minutes is really just now
	if ($delta < 120) {
		return 'Just now';

	# less than two hours: minutes
	} elsif ($delta < 7200) {
		$minutes = int($delta/60); # do whole numbers for this
		return $minutes.' minutes ago';

	# less than a day: hours
	} elsif ($delta < 86400) {
		$hours = sprintf("%.1f", ($delta/3600)); # one digit after decimel
		return $hours.' hours ago';

	# less than two weeks, get days
	} elsif ($delta < 1209600) {
		$days = sprintf("%.2f", ($delta/86400)); # two digits after decimel
		return $days.' days ago';

	# less than nine weeks, get weeks
	} elsif ($delta < 5443200) {
		$weeks = sprintf("%.2f", ($delta/604800)); # two digits after decimel
		return $weeks.' weeks ago';

	# otherwise, months
	} else {
		# DateTime.pm should have done this for us, but it seems to be a little buggy,
		# so we will presume 30.4 days in a month.  makes ense since months starts after 9 weeks
		$months = sprintf("%.1f", ($delta/2626560)); # one digit after decimel
		return $months.' months ago';

	}

}

# subroutine to calculate the number of days, hours, or minutes UNTIL an epoch
# i made the decision not munge figure_age to try and do both
sub figure_delay_time {
	# required argument is the epoch to test against
	my ($self, $future_epoch) = @_;

	my ($delta, $minutes, $hours, $days, $weeks, $dt1, $dt2, $dur, $months);

	# the argument they sent must be an integar, before the current timetamp
	if (!$future_epoch || $future_epoch =~ /\D/ || $future_epoch < time()) {
		return 'Unknown';
	}

	# get the delta and proceed accordingly
	$delta = $future_epoch - time();

	# less than two minutes is really just now
	if ($delta < 120) {
		return 'Right now';

	# less than two hours: minutes
	} elsif ($delta < 7200) {
		$minutes = int($delta/60); # do whole numbers for this
		return 'In '.$minutes.' minutes';

	# less than a day: hours
	} elsif ($delta < 86400) {
		$hours = sprintf("%.1f", ($delta/3600)); # one digit after decimel
		return 'In '.$hours.' hours';

	# less than two weeks, get days
	} elsif ($delta < 1209600) {
		$days = sprintf("%.2f", ($delta/86400)); # two digits after decimel
		return 'In '.$days.' days';

	# less than nine weeks, get weeks
	} elsif ($delta < 5443200) {
		$weeks = sprintf("%.2f", ($delta/604800)); # two digits after decimel
		return 'In '.$weeks.' weeks';

	# otherwise, months
	} else {
		# DateTime.pm should have done this for us, but it seems to be a little buggy,
		# so we will presume 30.4 days in a month.  makes ense since months starts after 9 weeks
		$months = sprintf("%.1f", ($delta/2626560)); # one digit after decimel
		return 'In '.$months.' months';

	}

}

# add a WWW::Mechanize object to my utility belt; useful if/when we need to make external requests
sub get_http_client {
	my $self = shift;

	# not needed if we already have one
	return if $self->{mech};

	# step one: launch Mechanize
	$self->{mech} = WWW::Mechanize->new(
		timeout => 60,
		autocheck => 0,
		cookie_jar => {},
		keep_alive => 1,
		ssl_opts => {
			verify_hostname => 0,
		},
		'agent' => 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_11_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/52.0.2743.116 Safari/537.36',
	);

}

# utility to determine the mime type of a file by extension
sub get_mime_type {
	my ($self, $filename) = @_;

	return 'application/octlet-stream' if !$filename;

	$self->{mime_typer} = MIME::Types->new if !$self->{mime_typer};
	
	my $mime_type = $self->{mime_typer}->mimeTypeOf($filename)->type;
	$mime_type ||= 'application/octlet-stream';
	
	return $mime_type;
}

# utility to grab a model object easily; call from any class under Majestica::Componnents
sub get_model_object {
	# model class will be the argument, e.g. 'SystemAdmin::Models::SystemUsers'
	# or SystemAdmin/SystemUsers or SystemUsers
	my ($self, $the_class_name, $args_hash) = @_;
	# second arg is optional and could be a hashref with these options
	#	'database_name' => 'database for new object', # overrides $self->{database_name}
	#	'skip_check_table_readiness' => 1, # set to 1 to have the model object SKIP check_table_readiness()
	# 	'user_id' => $user_id, # set to override $self->{user_id},
	# 	'load_ids' => $arrayref_of_record_ids, # optional; if provided, will call data_load() during new()
	# 	'save_args' => $hashref_of_save_args, #  optional; if provided, will call save() during new() with these args

	# can't do much without that class
	return if !$the_class_name;

	# we will make use of that args_hash - default to what's in my $self
	$args_hash ||= {};
	$$args_hash{database_name} ||= $self->{database_name};
	$$args_hash{user_id} ||= $self->{user_id};

	# only works if they loaded in $db, $database_name, user_id
	return if !$self->{db} || !$$args_hash{database_name} || !$$args_hash{user_id};

	## OK, they can pass in $the_class_name in one of three formats:
	# 1. ModelClassName --> it must be a 'neighbor' of the calling sub-class / under the same Component
	# 2. ComponentDirectory/ModelClassName --> it is under the Models subdir for ComponentDirectory
	# 3. Majestica::Components::ComponentDirectory::Models::ModelClassName --> standard Perl living

	# 1. ModelClassName --> it must be a 'neighbor' of the calling sub-class / under the same Component
	if ($the_class_name !~ /\:|\//) {
		my ($package, $filename, $line) = caller;
		my @the_class_path = split /\:\:/, $package;
		$the_class_path[-1] = $the_class_name;
		$the_class_path[-2] = 'Models'; # may have been calling from the controller
		$the_class_name = join('::',@the_class_path);

	# 2. ComponentDirectory/ModelClassName --> it is under the Models subdir for ComponentDirectory
	} elsif ($the_class_name =~ /\//) {
		my ($ComponentDirectory,$ModelClassName) = split /\//, $the_class_name;

		$the_class_name = 'Majestica::Components::'.$ComponentDirectory.'::Models::'.$ModelClassName;

	# 3. Majestica::Components::ComponentDirectory::Models::ModelClassName --> standard Perl living
	# 	--> no need to change $the_class_name ;)
	}

	# fail gracefully
	unless (eval "require $the_class_name") { # Error out if this won't import
		$self->send_response("Could not import $the_class_name: ".$@,1);

	# set it up
	} else {

		# set it up using our params
		my $new_model_object = $the_class_name->new(
			'db' => $self->{db},
			'belt' => $self,
			'database_name' => $$args_hash{database_name},
			'user_id' => $$args_hash{user_id},
			'skip_check_table_readiness' => $$args_hash{skip_check_table_readiness},
			'load_ids' => $$args_hash{load_ids},
			'save_args' => $$args_hash{save_args},
		);

		# send it out
		return $new_model_object;

	}
}

# start subroutine for generating easily-sortable keys for a hash, up to the max number provided
sub get_sort_keys {
	my $self = shift;

	# declare vars
	my ($i, $number, @sort_keys);

	# grab arg -- the greatest number of our sort keys
	$number = $_[0];
	$number ||= 1000; # don't allow empty strings to create endless loops

	for ($i = 0; $i < $number; $i++) {
		while (length($i) < length($number)) { $i = '0'.$i; }
		push(@sort_keys,$i);
	}

	# send out arrayref
	return \@sort_keys;
}

# utility for to grab and load into $self some relevant product / subscription info 
# for a given application; very useful for our constructors
# probably should have a sub-hash, but i will be inconsistent here
sub get_application_info {
	my ($self, $application_id) = @_;
	
	return if !$application_id;

	# use raw SQL for speed
	my (@application_info) = $self->{db}->quick_select(qq{
		select id, name, hostname, database_name, authentication_type, subscription_plan_id, 
		product_offering_id,trial_account, datediff(trial_end_date, curdate()), 
		date_format(trial_end_date,'%b %e'), (trial_account = 'Yes' and datediff(trial_end_date, curdate()) < -2)
		from majestica.applications where id=?
	},[ $application_id ]);	
	
	foreach my $key (
		'application_id','application_name','the_hostname','database_name','authentication_type',
		'subscription_plan_id','product_offering_id','trial_account',
		'days_left','trial_date_nice','is_expired_trial'
	) {
		$self->{$key} = shift @application_info;
	}	
	
}


# method to read/write/append to a file via Path::Tiny
sub filer {
	# required arg is the full path to the file
	# optional second arg is the operation:  read, write, or append.  default to 'read'
	# optional third arg is the content for write or append operations
	my ($self, $file_location, $operation, $content) = @_;

	# return if no good file path
	return if !$file_location;

	# default operation is 'read'
	$operation = 'read' if !$operation || $operation !~ /read|write|append|basename/;

	# return if write or append and no content
	return if $operation !~ /read|basename/ && !$content;

	# do the operations
	if ($operation eq 'read') {

		$content = path($file_location)->slurp_raw;
		return $content;

	} elsif ($operation eq 'write') {

		path($file_location)->spew_raw( $content );

	} elsif ($operation eq 'append') {

		# make sure the new content ends with a \n
		$content .= "\n" if $content !~ /\n$/;

		path($file_location)->append_raw( $content );

	} elsif ($operation eq 'basename') {

		return path($file_location)->basename;
	}

}

# routine to fix dates that come from jquery.daterangepicker
sub fix_jquery_date {
	my ($self,$date_to_fix) = @_;

	# might be OK?
	if ($date_to_fix =~ /(\d{2})\/(\d{2})\/(\d{4})/) {	
		$date_to_fix = $3.'-'.$1.'-'.$2;
	}
	
	return $date_to_fix;
	
}

# simple routine to get a DateTime object for a MySQL date/time, e.g. 2016-09-04 16:30
sub get_datetime_object {
	my ($self, $time_string, $time_zone_name) = @_;

	# default timezone is New York
	$time_zone_name = $self->{time_zone_name};
		$time_zone_name ||= 'America/New_York';

	my ($dt, $year, $month, $day, $hour, $minute, $second);

	# be willing to just accept the date and presume midnight
	if ($time_string =~ /^\d{4}-\d{2}-\d{2}$/) {
		$time_string .= ' 00:00:00';
	}

	# i will generally just send minutes; we want to support seconds too, and default to 00 seconds
	if ($time_string =~ /\s\d{2}:\d{2}$/) {
		$time_string .= ':00';
	}

	# if that timestring is not right, just get one for 'now'
	if ($time_string !~ /^\d{4}-\d{2}-\d{2}\s\d{2}:\d{2}:\d{2}$/) {

		$dt = DateTime->from_epoch(
			epoch => time(),
			time_zone	=> $time_zone_name,
		);

	#  otherwise, get a custom datetime object
	} else {

		# have to slice-and-dice it a bit to make sure DateTime is happy
		$time_string =~ s/-0/-/g;
		($year,$month,$day,$hour,$minute,$second) = split /-|\s|:/, $time_string;
		$hour =~ s/^0//;
		$minute =~ s/^0//;

		# try to set up the DateTime object, wrapping in eval in case they send an invalid time
		# (which happens if you go for 2am on a 'spring-forward' day
		eval {
			$dt = DateTime->new(
				year		=> $year,
				month		=> $month,
				day			=> $day,
				hour		=> $hour,
				minute		=> $minute,
				second		=> $second,
				time_zone	=> $time_zone_name,
			);
		};

		if ($@) { # if they called for an invalid time, just move ahead and hour and try again
			$hour++;
			$dt = DateTime->new(
				year		=> $year,
				month		=> $month,
				day			=> $day,
				hour		=> $hour,
				minute		=> $minute,
				second		=> $second,
				time_zone	=> $time_zone_name,
			);
		}

	}

	# send it out
	return $dt;
}

# this method is meant to get an epoch for the occurance of a given time,
# localized to a time zone.  So for instance, the next time it will be 11am in
# America/Chicago.  That could be later today or it could be tomorrow morning.
# this is handy for scheduling jobs that need to run after a certain time in
# a certain location (i.e. turn off all lights in Albuquerque at 9pm)
sub get_epoch_for_next_local_time {
	# required arg is the target time, in military format
	# optional arg is the time zone name
	# other optional arg tells us eitther to send the object out or
	# not to worry about making sure it's in the future; today is fine
	my ($self, $target_time, $time_zone_name, $dont_worry_about_the_future) = @_;

	my ($day, $dt, $hour, $minute, $month, $our_epoch, $today, $year);

	# fail if incorrect target time
	return '0' if !$target_time || $target_time !~ /^\d+:\d\d$/;

	# get the current date so we can build a DateTime
	$today = $self->todays_date();

	# default timezone for this is US/Eastern
	$time_zone_name ||= 'America/New_York';

	# use our central method to get the datetime object
	$dt = $self->get_datetime_object($today.' '.$target_time, $time_zone_name);

	# turn that into an epocH
	$our_epoch = $dt->epoch;

	# if they do not care about making sure it's in the future, return it
	if ($dont_worry_about_the_future) {
		return $our_epoch;
	}

	# if that already came by, we mean tomorrow.  may have to move forward more than once
	# depending on the time / offset combination
	while (time() > $our_epoch) { # already passed, so they mean tomorrow
		$our_epoch += 86400;
	}

	# send out our finished product
	return $our_epoch;

}


# two json translating subroutines using the great JSON module
# First, make perl data structures into JSON objects
sub json_from_perl {
	my ($self, $data_ref) = @_;

	# for this, we shall go UTF8
	return $self->{json_coder}->encode( $data_ref );
}

# Second, make JSON objects into Perl structures
sub json_to_perl {
	my ($self, $json_text) = @_;

	# first, let's try via UTF-8 decoding
	my $json_text_ut8 = encode_utf8( $json_text );
	my $perl_hashref = {};
	eval {
		$perl_hashref = $self->{json_coder}->decode( $json_text_ut8 );
	};

	return $perl_hashref;
}
# see notes below for more details

# subroutine to log messages under the 'logs' directory
sub logger {
	# takes three args: the message itself (required), the log_type (optional, one word),
	# and an optional logs location/directory
	my ($self, $log_message,$log_type,$log_directory) = @_;

	# return if no message sent; no point
	return if !$log_message;

	# default is 'errors' log type
	$log_type ||= 'errors';

	# no spaces or special chars in that $log_type
	$log_type =~ s/[^a-z0-9\_]//gi;

	my ($error_id, $todays_date, $current_time, $log_file, $now);

	# how about a nice error ID
	$error_id = $self->random_string(15);

	# what is today's date and current time
	$now = time(); # this is the unix epoch / also a quick-find id of the error
	$todays_date = $self->time_to_date($now,'to_date_db','utc');

	$current_time = $self->time_to_date($now,'to_datetime_iso','utc');
		$current_time =~ s/\s//g; # no spaces

	# target log file - did they provide a target log_directory?
	if ($log_directory && -d $log_directory) { # yes
		$log_file = $log_directory.'/'.$log_type.'-'.$todays_date.'.log';
	} else { # nope, take default
		$log_file = '/opt/majestica/log/'.$log_type.'-'.$todays_date.'.log';
	}

	# sometimes time() adds a \n
	$log_message =~ s/\n//;

	# if they sent a hash or array, it's a developer doing testing.  use Dumper() to output it
	if (ref($log_message) eq 'HASH' || ref($log_message) eq 'ARRAY') {
		$log_message = Dumper($log_message);
	}

	# if we have the plack object (created via pack_luggage()), append to the $log_message
	if ($self->{request}) {
		$log_message .= ' | https://'.$self->{request}->env->{HTTP_HOST}.$self->{request}->request_uri();
	}

	# append to our log file via Path::Tiny
	$self->filer($log_file, 'append', 'ID: '.$error_id.' | '.$current_time.': '.$log_message);

	# if running in script mode (outside of plack), archive any logs older than a week
	my ($archive_directory, $log_directory_match, @log_files, $log_file, $file_age, $archive_file, $gzipped_log);
	if (!$self->{request} && !$self->{skip_log_archiving}) {
		# where they are and where they go
		$archive_directory = '/opt/majestica/log/archive';
		$log_directory_match = '/opt/majestica/log';
		# make the archive directory if it does not exist
		mkdir $archive_directory if !(-d $archive_directory);
		# find the current/active logs
		@log_files = <$log_directory_match/*.lo*>; # get the starlet logs in there too
		foreach $log_file (@log_files) {
			# only affect logs older than a week
			$file_age = time() - (stat($log_file))[10];
			next if $file_age < 608400;
			# figure the new name under 'archive'
			($archive_file = $log_file) =~ s/\/log\//\/log\/archive\//;
			$archive_file .= '.gz';
			# gzip the file without using system commands
			eval {
				$gzipped_log = gzip_file ($log_file);
				$self->filer($archive_file, 'write', $gzipped_log);
				# delete the old files
				unlink($log_file);
			}; # sometimes, you get a little bit of a race
		}
	}

	# return the code/epoch for an innocent-looking display and for fast lookup
	return $error_id;
}

# method to get a list of month names, based on number of months back and forward
sub month_name_list {
	my ($self, $months_back, $months_forward) = @_;

	my ($dt, $total_interval, $n, $months_list, @query_list);

	# reasonable defaults
	$months_back ||= 24;
	$months_forward ||= 12;

	# make sure they are integers
	$months_back = int($months_back);
	$months_forward = int($months_forward);

	# what's our total interval
	$total_interval = $months_back + $months_forward;

	# we are going to be real slobs about this and do it in one query
	# this has to beat OT5!!!
	while ($n < $total_interval) {
		push( @query_list,qq{ date_format( date_sub(curdate(), interval $months_back month), '%M %Y') });
		# advance
		$n++;
		$months_back--;
	}

	(@$months_list) = $self->{db}->quick_select('select '.join(', ',@query_list) );

	return $months_list;

}


# subroutine to deliver html & json out to the client;
# if the argument is a string, send as either HTML or text; if a ARRAY or HASH reference, send
# as a json object
sub send_response {
	my ($self, $content, $stop_here, $content_type, $content_filename) = @_;

	# if not in Plack/PSGI land, we will skip working with $self->{response}

	# $content needs to be one of a text/html string, an ARRAYREF or a HASHREF
	my $ref_type = ref($content);

	my ($access_message, $error_id, $access_error, $die_text, $display_error_message, $html_generator, $error_html);
	
	if ($stop_here == 1 || $stop_here == 3) { # if $stop_here is a 1 or 3, we are stopping due to an error condition
		# if it is plain text, we should most likely log the error message sent to us
		# and just present the error ID
		# exception is if you're a developer running a script; in that case,
		# set the 'development_server' in your system configuration
		
		# note access errors for display below
		$access_error = 1 if $content =~ /^Access\:/;

		if (length($content)) { 
			$error_id = $self->logger($content,'fatals'); # 'these errors go into the 'fatals' log

			# unless we are on the dev server or it's the no-app message, present the error ID instead
			if ($self->{config}{development_server} || $content =~ /^No application exists/) {
				$display_error_message = $content;
				# need period at the end
				$display_error_message .= '.' if $display_error_message !~ /(\.|\?|\!)$/;
			} else { # hide the error
				$content = 'Execution failed; error ID: '.$error_id."\n";
				$ref_type = ''; # make sure it gets treated as plain text;
			}

			# if we are in API mode, let's send back JSON
			if ($self->{auth_token}) {
				$ref_type = "HASH" ;
				$content = {
					'status' => 'Error',
					'error_id' => $error_id,
					'display_error_message' => $display_error_message,
				};
				# developers see the actual message
				$$content{display_error_message} = $display_error_message if $display_error_message;
				# make sure to send good HTTP codes to the API client
				$self->{response}->status(500);

			# if we are in Web UI mode, pipe it out to the user as HTML;
			} elsif ($self->{request}) {
				
				$html_generator = Majestica::Core::View->new($self, $self->{db});
				
				($access_message = $content) =~ s/^Access\:\s//;
				
				# is this an access-related error?
				if ($access_error) { # yes
					$error_html = $html_generator->access_denied_screen({
						'access_error' => $access_error,
						'access_message' => $access_message,
					});
				} else { # nope, regular error
					$error_html = $html_generator->error_screen({
						'error_id' => $error_id,
						'access_error' => $access_error,
						'display_error_message' => $display_error_message,
						'controller_method_name' => 'Error Message',
					});
				}
				
				$self->send_response($error_html);
				$self->{db}->do_sql('rollback'); # end our transaction
				# do not continue if in the inner eval{} loop
				if ($stop_here == 1) {
					die 'Execution stopped: '.$content;
				} else { # if $stop_here == 3, then we are in a 'superfatal' from majestica.psgi
					return;
				}
			}

		# otherwise, send the text with 'Execution failed' to try and pop the error modal.
		# this works nicely in 'dev' mode
		} elsif ($self->{config}{development_server} && $content !~ /sha2/ && length($content)) {
			$content = 'Error: '.$content."\n";
		}
	}

	# if they sent a valid content type, no need to change it
	if ($content_type =~ /\//) {
		# nothing to do here
	} elsif ($ref_type eq "HASH" || $ref_type eq "ARRAY") { # make it into json
		$content_type = 'application/json';
		$content = $self->json_from_perl($content);

	} elsif ($content =~ /^\/\/ This is Javascript./) { # it is 99% likely to be Javascript
		$content_type = 'text/javascript';

	} elsif ($content =~ /^\/\* This is CSS./) { # it is 99% likely to be CSS
		$content_type = 'text/css';

	} elsif ($content =~ /<\S+>/) { # it is 99% likely to be HTML
		$content_type = 'text/html';

	} elsif (!$ref_type && length($content)) { # it is plain text
		$content_type = 'text/plain';

	} else { # anything else? something of a mistake, panic a little
		$content_type = 'text/plain';
		$content = 'ERROR: The resulting content was not deliverable.';

	}

	# if in Plack, pack the response for delivery
	if ($self->{response}) {
		$self->{response}->content_type($content_type);
		# is this an error?  Change from 200 to 500, if not done so already
		if ($content =~ /^(ERROR|Execution failed)/ && $self->{response}->status() eq '200') {
			$self->{response}->status(500);
		}
		if ($content_filename && $content_type !~ /^image/) {
			$self->{response}->header('Content-Disposition' => 'attachment; filename="'.$content_filename.'"');
		}
		$self->{response}->body($content);
	} else { # print to stdout
		print $content;
	}

	if ($stop_here == 1) { # if they want us to stop here, do so; we should be in an eval{} loop to catch this
		$die_text = "Execution stopped.";
		$die_text .= '; Error ID: '.$error_id if $error_id;
		$self->{db}->do_sql('rollback') if $self->{db}; # end our transaction
		die $die_text;
	}

}

# routine to (re-)pack up the PSGI environment
sub pack_psgi_variables {
	my $self = shift;

	# eject from this if we do not have the plack request and response objects
	return if !$self->{request} || !$self->{response};

	my (@vars, $value, @values, $v, $request_body_type, $request_body_content, $json_params, $plack_headers);

	# stash the hostname, URI, and complete URL
	$self->{hostname} = lc($self->{request}->env->{HTTP_HOST});
	$self->{uri} = $self->{request}->path_info();

	# see if there is an Authentication header or cookie
	$plack_headers = $self->{request}->headers;
	$self->{auth_token} = $plack_headers->header('Authentication');
	$self->{auth_cookie} = $self->{request}->cookies->{ 'Majestica_Ticket' };

	# notice how, in a non-PSGI world, you could just pass these as arguments

	# now on to user parameters

	# accept JSON data structures
	$request_body_type = $self->{request}->content_type;
	$request_body_content = $self->{request}->content;
	if ($request_body_content && $request_body_type eq 'application/json') {
		$json_params = $self->json_to_perl($request_body_content);
		if (ref($json_params) eq 'HASH') {
			$self->{params} = $json_params;
		}
	}

	# also take any POST / GET vars
	# the rest of this if for that

	# space for arrays for fields with multiple values
	$self->{params}{multi} = {};

	# create a hash of the CGI params they've sent
	@vars = $self->{request}->parameters->keys;
	foreach $v (@vars) {
		# ony do it once! --> those multi values will get you
		next if $self->{params}{$v};

		# plack uses the hash::multivalue module, so multiple values can be sent via one param
		@values = $self->{request}->parameters->get_all($v);
		if (scalar(@values) > 1 && $v ne 'client_connection_id') { # must be a multi-select or similiar: two ways to access
			# note that we left off 'client_connection_id' as we only want one of those, in case they got too excited in JS-land
			foreach $value (@values) { # via array, and I am paranoid to just reference, as we are resuing @values
				push(@{$self->{params}{multi}{$v}}, $value);
			}
			$self->{params}{$v} = join(',', @values);  # or comma-delimited list
			$self->{params}{$v} =~ s/^,//; # no leading commas
		} elsif (length($values[0])) { # single value, make a simple key->value hash
			$self->{params}{$v} = $values[0];
		}
	}
	
	# maybe they sent the auth_token as a PSGI param?
	$self->{auth_token} ||= $self->{params}{auth_token};
	
}

# for validating CSRF tokens
sub validate_csrf_token {
	my $self = shift;
	
	if ($self->{params}{CSRFToken} ne $self->{csrf_token} && !$self->{auth_token}) {
		return 0;		
	} else {
		return 1;
	}

}

# utility to retrieve certain information
sub get_certain_info {
	# required arg is the name of the info we need to retrieve
	my ($self, $info_bit_name) = @_;
	return if !$info_bit_name;

	# get the certain_info object, if we don't already have one
	if (!$self->{certain_info}) {
		$self->{certain_info} = $self->get_model_object('SystemAdmin/CertainInformation');
	}

	# get and return that info
	return $self->{certain_info}->get_by_name($info_bit_name);

}

# subroutine to prepare a comma-separated list of X number of question marks
# useful when readying an INSERT or UPDATE with placeholders
sub q_mark_list {
	my ($self, $num) = @_;

	my ($count,$q_marks);

	$num ||= 1; # at least one

	# easy enough ;)
	$count = 1;
	while ($count <= $num) {
		$q_marks .= '?,';
		$count++;
	}

	# delete last ,
	chop($q_marks);

	return $q_marks;

}

# subroutine for generating a random string
# stolen from http://stackoverflow.com/questions/10336660/in-perl-how-can-i-generate-random-strings-consisting-of-eight-hex-digits
sub random_string {
	my ($self, $length, $numbers_only) = @_;

	# default that to 10
	$length ||= 10;

	my (@chars,$string);

	if ($numbers_only) { # what they want...
		@chars = ('0'..'9');
	} else { # both
		@chars = ('0'..'9', 'A'..'F');
	}

	while($length--){
		$string .= $chars[rand @chars]
	};

	return $string;
}

# method to convert a comma-list of numbers and ranges to a proper list of numbers
sub range_list {
	my ($self, $list_of_numbers) = @_;

	# no bad chars
	$list_of_numbers =~ s/[^0-9\-\,]//g;

	# return if that leaves nothing
	return qq{Bad string sent.  Send something like '1,2,3,5-8,10'} if $list_of_numbers !~ /\d/;

	# Number::Range likes 1..10 instead of 1-10
	$list_of_numbers =~ s/-/../g;

	# new favorite perl module ;)
	my $range = Number::Range->new($list_of_numbers);
	my @numbers = $range->range;

	# send out our comma-separated list
	return $self->comma_list(\@numbers);

}

# method to bring in the system config created using a script derived from
# ***** /opt/majestica/lib/Majestica/Scripts/Utilities/configuration.pl 
# loads up $self->{config}
# Must be called via new() / psgi_new
sub read_system_configuration {
	my $self = shift;
	
	my ($the_file, $obfuscated_json, $config_json);
	
	# where the config lives
	$the_file = '/opt/majestica/configs/majestica.cfg';
	
	# kick out if that file does not exist yet
	if (!(-e $the_file)) {
		$self->send_response('ERROR: Can not find system configuration file.',1);
	}

	# try to read it in
	eval {
		$obfuscated_json = $self->filer('/opt/majestica/configs/majestica.cfg');
		$config_json = pack "h*", $obfuscated_json;
		$self->{config} = $self->json_to_perl($config_json);
	};
	
	# error out if there was any failure
	if ($@ || ref($self->{config}) ne 'HASH') {
		$self->send_response('ERROR: Could not read in system configuration file: '.$@,1);
	}

}

# subroutine to check to see if a value is included in a delimited list
sub really_in_list {
	# grab args
	my ($self, $string,$list,$delimiter) = @_;
	# the string to check for, the delimiter of the string, and the delimited list to check in

	# declare vars
	my ($end, $middle, $start);

	# default $delimiter to a comma
	$delimiter ||= ',';

	# different versions for different modes
	# prep for any weird chars in the vars they sent
	$start = quotemeta($string.$delimiter);
	$middle = quotemeta($delimiter.$string.$delimiter);
	$end = quotemeta($delimiter.$string);

	if ($list eq $string || $list =~ /$middle|^$start|$end\Z/) {
		return (1);
	} else {
		return (0);
	}
}

# method to verify recaptcha fields in form submissions
# returns a 1 for success / 0 for fail
sub recaptcha_verify {
	my $self = shift;

	# step zero.0: if we previously passed this test, return that earlier success
	# rather than bother google
	return $self->{recaptcha_already_passed} if $self->{recaptcha_already_passed};

	# step zero.1:  If we find that recaptcha is offline, we will touch this file:
	if (-e "/opt/majestica/configs/recaptcha_is_offline") {
		$self->{recaptcha_already_passed} = 1;
		return 1;
	}

	# step zero.5: make sure they checked the box
	my $recaptcha_val = $self->{params}{'g-recaptcha-response'};
	if (!$recaptcha_val) {
		return 0;
	}

	# load up the recaptcha secret from our internal keychain
	my $certain_info = Majestica::Components::SystemAdmin::Models::CertainInformation->new(
		'db' => $self->{db},
		'belt' => $self,
		'database_name' => 'majestica',
		'user_id' => 'X',
	);
	$certain_info->load(3);
	my $recaptcha_secret = $certain_info->{data}{the_information};

	# get the WWW::Mechanize client
	$self->get_http_client();

	# step two: send the request
	my $res = $self->{mech}->post( 'https://www.google.com/recaptcha/api/siteverify', [
		'secret' => $recaptcha_secret,
		'remoteip' => $self->{request}->address,
		'response' => $recaptcha_val,
	]);

	# decode results
	my $content = $self->{mech}->content();

	if ($content =~ /success\"\: true/) { # person!
		# cache this result for the next run-through, in case this gets called twice 
		# happens when you create a new user
		$self->{recaptcha_already_passed} = 1;
	
		return 1;
	} else { # damn robot
		return 0;
	}

}

# method to initiate a 302 redirect in Plack-world
sub redirect_the_client {
	# optional args are the send-them-to-URL and a flag to tell us not to send a commit() to the DB
	my ($self, $send_to_url, $skip_commit) = @_;

	# default to whatever is current
	$send_to_url ||= $self->{uri};
	
	# cannot be '/SignOut'
	$send_to_url = '/' if $send_to_url eq '/SignOut';

	# commit changes unless they said no
	$self->{db}->commit() unless $skip_commit;
	
	# send the temporary-redirect header
	$self->{response}->redirect($send_to_url, 302);

	# kick out to main.psgi; we are done
	die "Redirected";

}

# method to 'sanitize' results data structures before sending them out to API users
sub sanitize_api_results {
	my ($self, $results_data) = @_;
	
	# first off, clear out the 'configs' and 'params' from the response
	delete($$results_data{config});
	delete($$results_data{response}{params});
	delete($$results_data{response}{config});
	delete($$results_data{response}{ui_notices});
	
	my ($key, $record);
	
	# now clean up the params
	foreach $key (keys %{$$results_data{params}}) {
		# delete any empties
		if (!$$results_data{params}{$key} || (ref($$results_data{params}{$key}) eq 'ARRAY' && !$$results_data{params}{$key}[0])) {
			delete ($$results_data{params}{$key});
		}
		
		# clear any empty hashes
		if (ref($$results_data{params}{$key}) eq 'HASH' && ! keys %{ $$results_data{params}{$key} }) {
			delete ($$results_data{params}{$key});
		}
		
		# clear any passwords / two_factor_code / window_id / html
		if ($key =~ /require_password_change|two_factor_code|window_id|html|full_access_level|is_locked|api_explorer_mode|CSRFToken/) {
			delete ($$results_data{params}{$key});
		} elsif ($key =~ /password/i) {
			$$results_data{params}{$key} = 'CENSORED';
		}	
	}

	# if we have records in the response, clear any '_html' keys
	if (ref($$results_data{response}{records_keys}) eq 'ARRAY') {
		foreach $record (@{ $$results_data{response}{records_keys} }) {
			foreach $key (keys %{ $$results_data{response}{records}{$record} }) {
				next if $key !~ /inline|html/;
				delete ($$results_data{response}{records}{$record}{$key});
			}
		}
	}
	
	# are the saved search options empty?
	foreach $key ('saved_search_options','shared_search_options') {
		if ($$results_data{response}{$key} && !$$results_data{response}{$key}[0]) {
			delete($$results_data{response}{$key});
		}
	}


	# send it back
	return $results_data;
	
}

# handy routine for debugging: show the contents of a hashref (anything really)
sub show_data_structure {
	my ($self, $data) = @_;

	# this is really just an alias for Data::Dumper with some 'pre' thrown in
	return "<pre>\n".Dumper($data)."\n</pre>";
}

# start subroutine to turn an array into a cool sql IN list, i.e 'a','b','c'
# use comma_list for lists of integers
sub sql_list {
	my ($self, $list) = @_;

	# declare vars
	my ($real_list, $piece, $nice_list, @my_list);

	# or it could be a scalar of comma-delimited items
	if (!ref($list)) {
		@my_list = split /\,/, $list;
		shift @my_list if $my_list[0] !~ /[0-9a-z]/i; # shift off first if blank
		$list = \@my_list;
	}

	# make it sort, no dups
	$real_list = $self->uniquify_list($list);

	# turn that list into a nice sql-list
	$nice_list = qq{'}.join(qq{','}, @$real_list).qq{'};

	# send it out
	return $nice_list;
}

# easy routine to get the name of the current month
sub this_month_name {
	my $self = shift;
	
	my ($this_month) = $self->{db}->quick_select(qq{
		select date_format(curdate(), '%M %Y')
	});
	
	return $this_month;
}

# start the timeToDate subroutine, where we convert between UNIX timestamps and human-friendly dates
sub time_to_date {
	# declare vars & grab args
	my ($self, $timestamp, $task, $time_zone_name) = @_;
	my ($day, $dt, $diff, $month, $templ, $year);

	# luggage::pack_luggage() tries to set the 'time_zone_name' attribute
	# try to use that if no $time_zone_name arg was sent
	$time_zone_name ||= $self->{time_zone_name};

	# if they sent a 'utc', force it to be Etc/GMT -- this is for the logger
	$time_zone_name = 'Etc/GMT' if $time_zone_name eq 'utc';

	# default timezone to Eastern if no timezone sent or set
	$time_zone_name ||= 'America/New_York';

	# fix up timestamp as necessary
	if (!$timestamp) { # empty timestamp --> default to current timestamp
		$timestamp = time();
	} elsif ($timestamp =~ /\,/) { # human date...make it YYYY-MM-DD
		($month,$day,$year) = split /\s/, $timestamp; # get its pieces
		# turn the month into a proper number
		if ($month =~ /Jan/) { $month = "1";
		} elsif ($month =~ /Feb/) { $month = "2";
		} elsif ($month =~ /Mar/) { $month = "3";
		} elsif ($month =~ /Apr/) { $month = "4";
		} elsif ($month =~ /May/) { $month = "5";
		} elsif ($month =~ /Jun/) { $month = "6";
		} elsif ($month =~ /Jul/) { $month = "7";
		} elsif ($month =~ /Aug/) { $month = "8";
		} elsif ($month =~ /Sep/) { $month = "9";
		} elsif ($month =~ /Oct/) { $month = "10";
		} elsif ($month =~ /Nov/) { $month = "11";
		} elsif ($month =~ /Dec/) { $month = "12"; }
		# remove the comma from the date and make sure it has two digits
		$day =~ s/\,//;

		# we'll convert the epoch below via DateTime, one more check...
		$day = '0'.$day if $day < 10;
		$timestamp = $year.'-'.$month.'-'.$day;

	}
	# if they passed a YYYY-MM-DD date, also we will get a DateTime object

	# need that epoch if a date string was set / parsed
	if ($month || $timestamp =~ /-/) {
		$dt = $self->get_datetime_object($timestamp.' 00:00',$time_zone_name);
		$timestamp = $dt->epoch;
		$time_zone_name = 'Etc/GMT'; # don't offset dates, only timestamps
	}

	# default task is the epoch for the first second of the day
	$task ||= 'to_unix_start';

	# proceed based on $task
	if ($task eq "to_unix_start") { # date to unix timestamp -- start of the day
		return $timestamp; # already done above
	} elsif ($task eq "to_unix_end") { # date to unix timestamp -- end of the day
		return ($timestamp + 86399); # most done above
	} elsif ($task eq "to_date_db") { # unix timestamp to db-date (YYYY-MM-DD)
		$templ = '%Y-%m-%d';
	} elsif (!$task || $task eq "to_date_human") { # unix timestamp to human date (Mon DD, YYYY)
		($diff) = ($timestamp - time())/15552000; # drop the year if within the last six months
		if ($diff > -1 && $diff < 1) {
			$templ = '%B %e';
		} else {
			$templ = '%B %e, %Y';
		}
	} elsif (!$task || $task eq "to_date_human_full") { # force YYYY in above
		$templ = '%B %e, %Y';
	} elsif (!$task || $task eq "to_date_human_abbrev") { # force YYYY in above
		$templ = '%b %e, %Y';
	} elsif (!$task || $task eq "to_date_human_dayname") { # unix timestamp to human date (DayOfWeekName, Mon DD, YYYY)
		($diff) = ($timestamp - time())/15552000; # drop the year if within the last six months
		if ($diff > -1 && $diff < 1) {
			$templ = '%A, %b %e';
		} else {
			$templ = '%A, %b %e, %Y';
		}
	} elsif ($task eq "to_year") { # just want year
		$templ = '%Y';
	} elsif ($task eq "to_month" || $task eq "to_month_name") { # unix timestamp to month name (Month YYYY)
		$templ = '%B %Y';
	} elsif ($task eq "to_month_abbrev") { # unix timestamp to month abreviation (MonYY, i.e. Sep15)
		$templ = '%b%y';
	} elsif ($task eq "to_date_human_time") { # unix timestamp to human date with time (Mon DD, YYYY<br>HH:MM:SS XM)
		($diff) = ($timestamp - time())/31536000;
		if ($diff >= -1 && $diff <= 1) {
			$templ = '%b %e at %l:%M%P';
		} else {
			$templ = '%b %e, %Y at %l:%M%P';
		}
	} elsif ($task eq "to_just_human_time") { # unix timestamp to humantime (HH:MM:SS XM)
		$templ = '%l:%M%P';
	} elsif ($task eq "to_just_military_time") { # unix timestamp to military time
		$templ = '%R';
	} elsif ($task eq "to_datetime_iso") { # ISO-formatted timestamp, i.e. 2016-09-04T16:12:00+00:00
		$templ = '%Y-%m-%dT%X%z';
	} elsif ($task eq "to_month_abbrev") { # epoch to abbreviation, like 'MonYY'
		$templ = '%b%y';
	} elsif ($task eq "to_day_of_week") { # epoch to day of the week, like 'Saturday'
		$templ = '%A';
	} elsif ($task eq "to_day_of_week_numeric") { # 0..6 day of the week
		$templ = '%w';
	}

	# if they sent a time zone, offset the timestamp epoch appropriately
	if ($time_zone_name ne 'Etc/GMT') {
		# have we cached this?
		if (!$self->{tz_offsets}{$time_zone_name}) {
			$dt = DateTime->from_epoch(
				epoch		=> $timestamp,
				time_zone	=> $time_zone_name,
			);
			$self->{tz_offsets}{$time_zone_name} = $dt->offset;
		}

		# apply the offset
		$timestamp += $self->{tz_offsets}{$time_zone_name};
	}

	# now run the conversion
	$timestamp = time2str($templ, $timestamp,'GMT');
	$timestamp =~ s/  / /g; # remove double spaces;
	$timestamp =~ s/GMT //;
	return $timestamp;
}

# very easy method to get today's date in DB format from time_to_date
sub todays_date {
	my $self = shift;

	return $self->time_to_date(time(),'to_date_db');
}

# start subroutine to uniquify a list
sub uniquify_list {
	my ($self, $list) = @_;

	# declare vars
	my (%seen, @u_list);

	# back out if not an array
	return [] if ref($list) ne 'ARRAY';

	# stolen from perl cookbook, page 124
	%seen = ();
	@u_list = grep { ! $seen{$_} ++ } @$list;

	# send back reference
	return \@u_list;
}

# save out our benchmarks
sub write_benchmarks {
	my $self = shift;

	foreach my $log_name (keys %{ $self->{benchmarks} }) {
		$self->logger($self->{benchmarks}{$log_name}, $log_name);
	}

	# only once...
	$self->{benchmarks} = {};

}

# when this object goes out of scope, log any benchmarks to our files
# (have to call it from PSGI mode manually)
sub DESTROY {
	my $self = shift;

	$self->write_benchmarks();
};

###### START UNDOCUMENTED FEATURES ######

# quick method to pack some text into Hex and save to a file
# useful in very limited situations
sub stash_some_text {
	my ($self, $text_to_stash,$file_location) = @_;

	# return if no text or $file_location
	if (!$text_to_stash || !$file_location) {
		$self->send_response('Error: both args required for stash_text()',1);
	}

	# garble it up
	my $obfuscated = unpack "h*", $text_to_stash;
	# get this out like:
	# 	$obfuscated = path($file_location)->slurp_raw
	#	$obfuscated = $belt->filer($file_location);
	# 	my $stashed_text = pack "h*", $obfuscated;
	# 	print $stashed_text."\n";
	# This is 0.0000001% of what pack() can do, please see: http://perldoc.perl.org/functions/pack.html

	# stash it out
	$self->filer($file_location, 'write', $obfuscated);

	return 1;
}

1;

__END__

=head1 Majestica::Core::UtilityBelt

A set of very handy routines, which combine to be a very critical component of this system.  Just
about everything else depends on this package.

If you are calling from a PSGI script, like majestica.psgi

	$belt = Majestica::Core::UtilityBelt->psgi_new($db $request, $response);

For initiating vita scripts:

	$belt = Majestica::Core::UtilityBelt->new($db, $database_name, $user_id);

Those 'db', 'database_name', and 'user_id' attributes / arguments are needed if you want to use
get_model_object().

Here are the included methods, in alphabetical order:

=head2 benchmarker()

For troubleshooting choke-points / speed issues.  Will log out messages showing the number of seconds, out
to five decimel places, to get to the chosen spot in your code execution.  First arg is the message indicating
the place in your code, and the second is the base name for your log file.

Second arg is optional, and will default to 'benchmarks'.

Third arg is also optional, if filled, the current memory footprint will also be logged. This adds some time
and will make subsequent benchmarks inaccurate, so only turn on if you are watching memory and not speed.

For most usefulness, you will call this twice, like so:

	$belt->benchmarker('Started my process');

	...some code here...

	$belt->benchmarker('Finished my process');

When you are done, be sure to call:

	$belt->write_benchmarks();

To save those to the 'benchmarks' log.

=head2 comma_list()

Takes a reference to an array plus an optional delimiter, runs the arrayref through our 'uniquify_list'
method to take out duplicates, then turns it into a simple string of the values, separated by the delimiter,
which defaults to a comma.  Seems like I could have explained that more simply.

Example:

	$comma_separated_string = $belt->comma_list(['eric','ginger','pepper','eric']);

	$comma_separated_string now equals 'eric,ginger,pepper'.

	Example Two;

	$comma_separated_string = $belt->comma_list(['eric','ginger','pepper','eric'],'==');

	$comma_separated_string now equals 'eric==ginger==pepper'.

=head2 commaify_number()

Turns 1976 to 1,976 or 36000000 to 36,000,000.

Example:

	$pretty_number = $belt->commaify_number(25000);

	$pretty_number is now '25,000'.

=head2 diff_percent()

Calculates the amount of growth (or shrinkage) from one number to the next.

Example:

	$diff = $belt->diff_percent(10,12);

	$diff is now 20.  No percent sign included.

=head2 figure_age()

Returns a somewhat-friendly string showing how long ago this UNIX epoch was current.
Set it an epoch from before now.

If your epoch was less than a minute ago, you will receive back 'Just now', and
otherwise, you will get a string like so:

	'40 minutes ago'
	'2.1 days ago'
	'3.6 weeks ago'
	'10 months ago'

Example:

	$phrase = $belt->figure_age( time() - 3600 );

	$phrase is now '60 minutes ago'.

=head2 figure_delay_time();

Does the opposite of figure_age().  It display a somewhat-friendly string showing
how far into the future this UNIX epoch will occur.  Send it an epoch value for
after now.

If your epoch is less than a minute from now, you will receive back 'Right now', and
otherwise, you will get a string like so:

	'In 20 minutes'
	'In 3.5 days'
	'In 7.2 weeks'
	'In 11 months'

Example:

	$phrase = $belt->figure_delay_time( time() + 3600 );

	$phrase is now 'In 60 minutes'.

=head2 filer()

Method to efficiently handle reading, writing and appending to files via Path::Tiny.

To read a file into a scalar:

	$file_contents = $belt->filer($file_location, 'read');

		or simply:

	$file_contents = $belt->filer($file_location);

To write out a complete file

	$belt->filer($file_location, 'write', $complete_content);

To append content to a file.

	$belt->filer($file_location, 'append', $append_content);

	A carriage return (\n) will be added to $append_content, if it does not already end with \n.

For all of these, $file_location is a complete path in the filesystem.

=head2 get_datetime_object()

Creates a DateTime object from a MySQL date/time, e.g. 2016-09-04 16:30.  DateTime is
integral to all the time-calculation functions in this package/system, and this method
is the central location to set up a DateTime object.

First arg is the MySQL date/time string, and the optional second arg is the tzdata
time zone name (https://en.wikipedia.org/wiki/Tz_database). The default time zone is
Etc/GMT, which is UTC+0.

More information on the excellent DateTime library is available at
http://search.cpan.org/~drolsky/DateTime-1.43/lib/DateTime.pm

You can use the returned object for anything DateTime can do, but please use the other
time-related methods here whenever possible, as they bring in the user's
$self->{luggage}{time_zone_name} as much as possible -- and that is snatched from the
browser and cached for other modes.

Example:

	$datetime_object = $belt->get_datetime_object('2018-09-04 16:20:00','America/New_York');

	# get a DateTime object for my 42nd birthday on the East Coast.

=head2 get_epoch_for_next_local_time()

Method to get an epoch for the occurrence of a given time, localized to a time zone name.
Really meant to find the epoch of the 'next' incidence of that time -- so if you say '11am,'
that could meant tomorrow morning.  If you pass the 'stick_to_day' third argument, it will
stick with the 'today' epoch for that time.

This is handy for scheduling jobs that need to run after a certain time in
a certain location (i.e. turn off all lights in Albuquerque at 9pm)

Requires one argument:  a military-style time value, i.e. 14:30 for 2:30pm.

Optional second arg is the tzdata time zone name, i.e. America/New_York or Europe/Brussels
The default here would be UTC+0.

Optional third arg tells us to not to make sure it's in the future.

Usage:

	$epoch = $belt->get_epoch_for_next_local_time('15:00','America/Los_Angeles');

	$epoch is now the epoch for the next time it will be 3pm on the West Coast.

=head2 get_http_client()

Creates a fairly standard WWW::Mechanize object and stashes it under $belt->{mech}.
If an object already exists, does nothing.  Useful if/when we need to make external requests.

=head2 get_model_object()

Convenient way to create a new Model object.  Required argument is the type of Model
to create.  One of three formats:

	1. ModelClassName --> it must be a 'neighbor' of the calling sub-class / under the same Component
	2. ComponentDirectory/ModelClassName --> it is under the Models subdir for ComponentDirectory
	3. Majestica::Components::ComponentDirectory::Models::ModelClassName --> standard Perl living

NOTE: This only works if you set object attributes for 'db', 'database_name', and 'user_id'
into the $belt object!

Examples:

	# works from anywhere, and my favorite:
	$system_users = $belt->get_model_object('SystemAdmin/SystemUsers');

	# works from anywhere, but least fun:
	$system_users = $belt->get_model_object('Majestica::Components::SystemAdmin::Models::SystemUsers');

=head2 get_sort_keys()

One of my favorites. Sends back a reference to an array of numbers which can be used to
key a hash so that it can be reliably sorted by those keys.  Prepends '0's so that all number
keys are the same length and easily sortable.

Example:

	$arrayref = $belt->get_sort_keys(10);

	$arrayref is now ['00','01','02','03','04','05','06','07','08','09']

=head2 json_from_perl() / json_to_perl()

For creating JSON from Perl or receiving JSON data into Perl.

The first method takes a reference to an array or a hash/data-structure and returns a JSON sting
in UTF-8.  The second method takes a JSON string, converts it into a perl data structure, and
returns a reference to that structure.

Examples:

	$json_string = $belt->json_from_perl($perl_hashref);

	$perl_hashref = $belt->json_to_perl($json_string);

This uses use Cpanel::JSON::XS.

=head2 logger()

Appends log messages on to files under /opt/majestica/logs. These files are named fram today's
YYYY-MM-DD date plus the log type.  Marks the message with the UNIX epoch for easy grep'ing.
Returns that epoch value to the calling routine.  Works well with send_response() when you do not
want to show an actual error message to the user.

Example of usage, if you ran this at 3:20am on March 11, 2016:

	$epoch = $belt->logger('Reached 4th Birthday.','lorelei');

	The following line would get added to /opt/majestica/logs/lorelei-2016-03-11.log:

		ID: 1457684400 | 2016-09-04T16:12:00+00:00: Reached 4th Birthday.

If $log_type is left blank, it will default to 'errors'.

Bonus: If you send a hashref or arrayref, it will be logged-out via Data::Dumper(), but please
just use that for testing your apps, not in real-world logging.

You can send a third argument, a target logs directory if you want to send this log somewhere
other than /opt/majestica/logs.  This new directory must exist in the system.

=head2 month_name_list()

Method to get a list of month names given a range of months before/ahead of now.

Let's say today is September 4, 2017, and you do this:

	$month_list = $belt->month_name_list(6,2);

Now, $month_list will be:

	$month_list = [
		'March 2017','April 2017','May 2017','June 2017','July 2017','August 2017',
		'September 2017','October 2017','November 2017'
	];

The months will change depending on your current date at time of execute.  It does try to
account for the user's time zone, when executed via the Web UI.

If you pass nothing, the defaults are 24 months back, and 12 months forward.

This is used for tool::html_sender::build_filter_menu_options() when building options for
'Month Chooser' menus, but maybe it has other applications, so included here.

=head2 pack_psgi_variables()

Reads in the PSGI environmental params into a hash at $self->{params}.  All the user-provided
parameters, sent in via a JSON body or POST/GET params. Automatically called via new() if
the Plack request object is provided

=head2 send_response()

This is our one and only method to deliver content to the client.

Anyhow, the argument sent to send_response() should be one of: a reference to an array, a reference to
a hash, or a scalar of content, usually a string of plain text or a string of HTML.  That content
could also be the binary content of a file, but usually it's some type of text. If it's an arrayref
or hashref, send_response() uses json_from_perl() to send it as a JSON string to the browser.  Otherwise,
the right content header will be sent and the string will be printed out to the client.

When you send out a Javascript file, you will make the very first line '// This is Javascript.'
with no leading space.  That saves me from writing a probably-buggy regexp to test
for JavaScript, especially since your JS code probably contains HTML fragments.

Outputting to the client relies on the 'response' Plack handler being added to the $belt
object by pack_luggage().  If the 'response' handler is not present, send_response() will just
print to stdout.

The '$stop_here' variable is optional, and will tell this subroutine that we want to
end execution after outputting the content.  If it's set to a 1 and the $content is plain text,
send_response will attempt to send the message to logger(), saving it to the fatals logs.

If you just want to stop without an error into the 'fatals' log, set $stop_here to 2 (or anything
but 1).

The third argument, $content_type, is optional, and allows you to specify the mime / content-type
of the content being served.  Make sure it's valid!

The fourth argument, $content_filename, is also optional and must be used with $content_type.  This
is to specify that we are sending a file for downloading; please see send_file() in tool::center_stage.pm

Examples:

	$belt->send_response($hashref,2);
	# sends out a JSON version of the data structure in hashref, and then end execution.

	$belt->send_response('An insightful error message.',1);
	# logs out 'An insightful error message.' to the 'fatals' log under $OTLOG.

	$belt->send_response($file_contents,2,'application/octet-stream','filename.bin');
	# sends the 'filename.bin' file to the browser.

=head2 q_mark_list()

Generates X-number of ? marks, separated by commas.  This is useful for preparing INSERT
and UPDATE SQL with placeholders.

Example:

	$q_marks = $belt->q_mark_list(3);

	$q_marks is now '?,?,?'

=head2 random_string()

Generates a random alphanumeric string, $length chars long (defaults to 10)

Example:

	$rand_string = $belt->random_string(5);

	$rand_string will now be a crazy five-character alphanumeric string.

=head2 recaptcha_verify()

DOCUMENTATION NEEDED!!

=head2 really_in_list()

Checks to see if a string is PROPERLY in a delimited list; that is, 'jdo' should not return
success in 'jblow,jdoe,jsmith' but should return true for 'jblow,jdo,jsmith'.

Returns a 1 or a 0.  Default $delimiter is a comma, so you can often leave it off.

Examples:

	if ($belt->really_in_list('d','a,b,c')) {
		...this code won't happen...
	}

	if ($belt->really_in_list('b','a|b|c','|')) {
		...this code will happen...
	}


=head2 show_data_structure()

Debugging rountine to run a structure through Data::Dumper and display the results.

Example:

	print $belt->show_data_structure($hashref);

=head2 range_list()

Takes a comma-separated list of numbers and ranges and converts to a plain comma-separated
list of numbers.  Honestly, this may not be the most popular kid in school, but neither was I.

Example:

	$number_list = $belt->('1-10,12,18,20-22');

	$number_list is now going to be:  1,2,3,4,5,6,7,8,9,10,12,18,20,21,22

=head2 sql_list()

Accepts an array reference (or a scalar of a comma-delimited string) and formats it for
doing IN queries with mysql, i.e. 'a','b','c' -- doesn't give you the ()'s.
Really for strings; if you have integers, you can rely on comma_list().

Example:

	$in_list = $belt->sql_list(['pepper','ginger']);

	$in_list is now qq{'pepper','ginger'}

Best not to use this at all; use q_mark_list and pass the array as bind variables.

=head2 time_to_date()

Takes a Unix epoch, YYYY-MM-DD date or even a 'June 27, 1998' date and formats it based on
the task given in second arg.  The tasks 'to_unix_start' and 'to_unix_end' give epoch values
for the start/end time of the date; all the others change to a readable format.

Optional third arg is the tzdata time zone name, e.g. America/New_York. You can also pass 'utc'
 to force the time zone to be 'Etc/GMT', which is good since it will default to what is
loaded in $self->{luggage}{time_zone_name} by the Web authentication.

Addtional options are: 'to_date_human', 'to_date_db', 'to_month', 'to_date_human_time',
'to_date_human_dayname', 'to_datetime_iso','to_month_abbrev', 'to_just_human_time',
'to_just_military_time', and 'to_day_of_week'

Examples:

	$month_name = $belt->time_to_date(933480000,'to_month');

	$momth_name is now 'August 1999'

	$human_date = $belt->time_to_date('2012-03-11','to_date_human');

	$human_date is now 'March 11, 2012'

The 'to_datetime_iso' option generates strings line 2016-09-04T16:12:00+00:00.

=head2 todays_date()

Returns the current date in MySQL format:  YYYY-MM-DD

Example:

	$today = $belt->todays_date();

=head2 uniquify_list()

Send in an array reference, which could include duplicate values. Returns an array reference with
unique values.

Example:

	$new_list = $belt->uniquify(['a','d','a']);

	$new_list is now ['a','d'];
