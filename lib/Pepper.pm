package Pepper;

$Pepper::VERSION = '1.0';

use Pepper::DB;
use Pepper::PlackHandler;
use Pepper::Utilities;

use strict;

=cut

Our problems:
1. How are we going to store / retrieve the URL mappings?
	- config->url_mappings_table
	- config->url_mappings_file
	- need a reader and writer for both
	
2. Cook up directory structure for /opt/pepper:  config, log, code
3. pepper-setup command
4. pepper-set-endpoint command
5. pepper start / pepper stop / pepper restart --> second arg: prod, dev, dev-reload

=cut

# constructor instantiates DB and CGI classes
sub new {
	my ($class,$args) = @_;
	# %$args can have:
	#	'skip_db' => 1 if we don't want a DB handle
	#	'request' => $plack_request_object, # if coming from pepper.psgi
	#	'response' => $plack_response_object, # if coming from pepper.psgi

	# start the object 
	my $self = bless {
		'utils' => Pepper::Utilities->new( $$args{request}, $$args{response} ),
	}, $class;
	# pass in request, response so that Utilities->send_response() works
	
	# bring in the configuration file from Utilities->read_system_configuration()
	$self->{config} = $self->{utils}->{config};
	
	# unless they indicate not to connect to the database, go ahead
	# and set up the database object / connection
	unless ($$args{skip_db}) {
		$self->{db} = Pepper::DB->new({
			'config' => $self->{config},
			'utils' => $self->{utils},
		});
		
		# let the Utilities have this db object for use in send_response()
		$self->{utils}->{db} = $self->{db};
		# yes, i did some really gross stuff for send_response()
	}

	# if we are in a Plack environment, instantiate PlackHandler
	# this will gather up the parameters
	if ($$args{request}) {
		$self->{plack_handler} = Pepper::PlackHandler->new({
			'request' => $$args{request},
			'response' => $$args{response},
			'utils' => $self->{utils},
		});
		
		# and read all the plack attributes into $self
		foreach my $key ('hostname','uri','cookies','params','auth_token') {
			$self->{$key} = $self->{plack_handler}{$key};
		}
		
	}

	# ready to go
	return $self;
	
}

sub execute_handler {
	my $self = shift;
	
	# resolve the uri to a module under /opt/pepper/code
	
	# import that module
	unless (eval "require $the_class_name") { # Error out if this won't import
		$self->{utils}->send_response("Could not import $the_class_name: ".$@,1);
	}	
	
	# create the object
	$the_handler = $the_class_name->new($self);
	
	# execute the request handler
	$response_content = $the_handler->handler();
	
	# ship the content
	$self->{utils}->send_response($response_content);
	
}


# autoload module to support passing calls to our subordinate modules.
our $AUTOLOAD;
sub AUTOLOAD {
	my $self = shift;
	# figure out the method they tried to call
	my $called_method =  $AUTOLOAD =~ s/.*:://r;
	
	# utilities function?
	if ($self->{utils}->can($called_method)) {

		return $self->{utils}->$called_method(@_);

	# database function?
	} elsif ($self->{db}->can($called_method)) {
		return $self->{db}->$called_method(@_);

		
	# plack handler function?
	} elsif ($self->{plack_handler}->can($called_method)) {
		return $self->{plack_handler}->$called_method(@_);
	
	} else { # hard fail with an error message
		my $message = "ERROR: No '$called_method' method defined for ".$self->{config}{name}.' objects.';
		$self->{utils}->send_response( $message, 1 );

	}
	
}

# empty destroy for now
sub DESTROY {
	my $self = shift;
}

1;
