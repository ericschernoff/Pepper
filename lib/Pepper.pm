package Pepper;

$Pepper::VERSION = '1.0';

use Pepper::DB;
use Pepper::CGIHandler;

use strict;

=cut

1. Cook up directory structure for /opt/pepper:  configs, logs, code
2. Create Pepper::Logger and fix up Pepper::DB->log_errors()
3. Fix Pepper::DB->new() to use configs
4. Replace Pepper::CGIHandler with Pepper::PlackHandler
	- json_coder passed back up to main Pepper object
5. Create pepper.psgi
6. pepper-setup command

=cut

# constructor instantiates DB and CGI classes
sub new {
	my ($class, $skip_db) = @_;

	# start the object 
	my $self = bless { }, $class;
	
	# unless they indicate not to connect to the database, go ahead
	# and set up the database object / connection
	unless ($skip_db) {
		$self->{db} = Pepper::DB->new();
	}

	# if we are in a CGI environment, instantiate CGI handler
	# this will gather up the parameters
	if ($ENV{PATH_INFO}) {
		$self->{cgi_handler} = Pepper::CGIHandler->new();
	}

	return $self;
	
}


# autoload module to support passing calls to our subordinate modules.
our $AUTOLOAD;
sub AUTOLOAD {
	my $self = shift;
	# figure out the method they tried to call
	my $called_method =  $AUTOLOAD =~ s/.*:://r;
	
	# database function?
	if ($self->{db}->can($called_method)) {

		return $self->{belt}->$called_method(@_);
		
	# cgi handler function?
	} elsif ($self->{cgi_handler}->can($called_method)) {
		return $self->{cgi_handler}->$called_method(@_);
	
	} else { # hard fail with an error message
		my $message = "ERROR: No '$called_method' method defined for ".$self->{config}{name}.' objects.';
		$self->{cgi_handler}->send_response( $message, 1 );

	}
	
}

# empty destroy for now
sub DESTROY {
	my $self = shift;
}

1;
