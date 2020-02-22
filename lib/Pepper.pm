package Pepper;

$Pepper::VERSION = '1.0';

use Pepper::DB;
use Pepper::PlackHandler;
use Pepper::Utilities;
use lib '/opt/pepper/code/';

use strict;

=cut

NEXT STEPS:

- Define list of pre-req packages & install those (incl. Mysql)

- Create 'pepper' script:
	- setup --> create directory structure, build configs, create examples
	- set-endpoint --> add/update an endpoint (including a default)
	- start / stop / restart for Plack service (second arg: prod, dev, dev-reload)
		- need a bash script for this
	- provide a systemd service file
	- provide an Apache config

- Get it to actually install

- See that it actually runs

- Start writing docs
	- What / Why
	- Pre-req's & Set Up
	- Running via SystemD & Apache
	- Building microservices
	- Methods

=cut

# constructor instantiates DB and CGI classes
sub new {
	my ($class,%args) = @_;
	# %args can have:
	#	'skip_db' => 1 if we don't want a DB handle
	#	'skip_config' => 1, # only for 'pepper' command in setup mode
	#	'request' => $plack_request_object, # if coming from pepper.psgi
	#	'response' => $plack_response_object, # if coming from pepper.psgi

	# start the object 
	my $self = bless {
		'utils' => Pepper::Utilities->new( \%args ),
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
	if ($args{request}) {
		$self->{plack_handler} = Pepper::PlackHandler->new({
			'request' => $args{request},
			'response' => $args{response},
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

# here is where we import and execute the custom code for this endpoint
sub execute_handler {
	my ($self,$endpoint) = @_;
	# the endpoint will likely be the plack request URI, but accepting
	# via an arg allows for script mode
	
	# resolve the endpoint / uri to a module under /opt/pepper/code
	my $endpoint_handler_module = $self->determine_endpoint_module($endpoint);
	
	# import that module
	unless (eval "require $endpoint_handler_module") { # Error out if this won't import
		$self->send_response("Could not import $endpoint_handler_module: ".$@,1);
	}	
	
	# create the object
	my $the_handler = $endpoint_handler_module->new($self);
	
	# execute the request handler
	my $response_content = $the_handler->handler();
	
	# ship the content
	$self->send_response($response_content);
	
}

# method to determine the handler for this URI / endpoint from the configuration
sub determine_endpoint_module {
	my ($self,$endpoint) = @_;
	
	# probably in plack mode
	my $endpoint ||= $self->{uri};

	# hopefully, they provided a default
	my $endpoint_handler_module = $self->{config}{default_endpoint_module};
	
	# did they choose to store in a database table?
	if ($self->{config}{url_mappings_table}) {
		
		($endpoint_handler_module) = $self->quick_select(qq{
			select handler_module from $self->{config}{url_mappings_table}
			where endpoint_uri = ?
		}, [ $endpoint ] );
		
	# or maybe a JSON file
	} elsif ($self->{config}{url_mappings_file}) {
	
		$url_mappings = $self->read_json_file( $self->{config}{url_mappings_file} );
		
		$endpoint_handler_module = $$url_mappings{$endpoint};
		
	}
	
	# if a module was found, send it back
	if ($endpoint_handler_module) {
		return $endpoint_handler_module;
		
	# otherwise, we have an error
	} else {
		$self->send_response('Error: No handler defined for this endpoint.',1);
	}
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
