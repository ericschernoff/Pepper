package Pepper::PlackHandler;

$Pepper::PlackHandler::VERSION = '1.0';

# for utf8 support with JSON
use utf8;
use Encode qw( encode_utf8 );

# for encoding and decoding JSON
use Cpanel::JSON::XS;

# for logging via logger()
use Path::Tiny;

# need some date/time toys
use Date::Format;
use DateTime;
use Date::Manip::Date;

# for being a good person
use strict;

sub new {
	my ($class,$args) = @_;
	# %$args must have:
	#	'request' => $plack_request_object, 
	#	'response' => $plack_response_object, 

	# start the object 
	my $self = bless $args, $class;
	
	# be ready to handle JSON
	$self->{json_coder} = Cpanel::JSON::XS->new->utf8->allow_nonref->allow_blessed,
	
	# gather up the PSGI environment
	$self->pack_psgi_variables();
	
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


# routine to (re-)pack up the PSGI environment
sub pack_psgi_variables {
	my $self = shift;

	# eject from this if we do not have the plack request and response objects
	return if !$self->{request} || !$self->{response};

	my (@vars, $value, @values, $v, $request_body_type, $request_body_content, $json_params, $plack_headers);

	# stash the hostname, URI, and complete URL
	$self->{hostname} = lc($self->{request}->env->{HTTP_HOST});
	$self->{uri} = $self->{request}->path_info();

	# you might want to allow an Authorization Header
	$plack_headers = $self->{request}->headers;
	$self->{auth_token} = $plack_headers->header('Authorization');
	
	# or you might test with cookies
	$self->{cookies} = $self->{request}->cookies;

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

	# the rest of this is to accept any POST / GET vars

	# space for arrays for fields with multiple values
	$self->{params}{multi} = {};

	# create a hash of the PSGI params they've sent
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

# utility to set cookies
sub set_cookies {
	my ($self,$cookie_details) = @_;
	
	# need at least a name and value
	return if !$$cookie_details{name} || !$$cookie_details{value};

	# days to live is important; default to 10 days
	$$cookie_details{days_to_live} ||= 10;

	$self->{response}->cookies->{ $$cookie_details{name} } = {
		value => $$cookie_details{value},
		domain  =>  $self->{request}->env->{HTTP_HOST},
		path => '/',
		expires => time() + ($$cookie_details{days_to_live} * 86400)
	};	
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
			if ($self->{development_server} || $content =~ /^No application exists/) {
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
				
				$self->send_response($content);
				$self->{db}->do_sql('rollback'); # end our transaction

				# do not continue if in the inner eval{} loop
				if ($stop_here == 1) {
					die 'Execution stopped: '.$content;
				} else { # if $stop_here == 3, then we are in a 'superfatal' from majestica.psgi
					return;
				}
				
			}

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

# subroutine to log messages under the 'logs' directory
sub logger {
	# takes three args: the message itself (required), the log_type (optional, one word),
	# and an optional logs location/directory
	my ($self, $log_message, $log_type, $log_directory) = @_;

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
		$log_file = '/opt/pepper/logs/'.$log_type.'-'.$todays_date.'.log';
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
	path($file_location)->append_raw( 'append', 'ID: '.$error_id.' | '.$current_time.': '.$log_message."\n" );

	# return the code/epoch for an innocent-looking display and for fast lookup
	return $error_id;
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

# utility to generate a random string
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

	while ($length--) {
		$string .= $chars[rand @chars]
	};

	return $string;
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

1;