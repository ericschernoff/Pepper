package Pepper;

$Pepper::VERSION = '1.0';

use Pepper::DB;
use Pepper::PlackHandler;
use Pepper::Utilities;
use lib '/opt/pepper/code/';

# try to be a good person
use strict;
use warnings;

=cut

NEXT STEPS:

Start writing docs
- What / Why
- Pre-req's & Set Up
- Building microservices
- Writing scripts
- Methods
- Running via SystemD & Apache
- Improve 'pepper help'

Test these:
- systemd service file
- Apache config

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
	if (!$args{skip_db} && $self->{config}{use_database} eq 'Y') {
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
	
	# execute the request endpoint handler; this is not OO for the sake of simplicity
	my $response_content = endpoint_handler( $self );

	# always commit to the database 
	if ($self->{config}{use_database} eq 'Y') {
		$self->commit();
	}
	
	# ship the content to the client
	$self->send_response($response_content);

}

# method to determine the handler for this URI / endpoint from the configuration
sub determine_endpoint_module {
	my ($self,$endpoint) = @_;
	
	# probably in plack mode
	my $endpoint_handler_module = '';
	$endpoint ||= $self->{uri};

	# did they choose to store in a database table?
	if ($self->{config}{url_mappings_table}) {
		
		($endpoint_handler_module) = $self->quick_select(qq{
			select handler_module from $self->{config}{url_mappings_table}
			where endpoint_uri = ?
		}, [ $endpoint ] );
		
	# or maybe a JSON file
	} elsif ($self->{config}{url_mappings_file}) {
	
		my $url_mappings = $self->read_json_file( $self->{config}{url_mappings_file} );
		
		$endpoint_handler_module = $$url_mappings{$endpoint};
		
	}

	# hopefully, they provided a default
	$endpoint_handler_module ||= $self->{config}{default_endpoint_module};
	
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
	} elsif ($self->{config}{use_database} eq 'Y' && $self->{db}->can($called_method)) {
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

__END__

=head1 NAME

Pepper - Quick-start bundle for creating microservices in Perl.

=head1 DESCRIPTION / PURPOSE

Perl is a wonderful language with an amazing ecosystem and terrific community.
This quick-start bundle is meant for new users to easily experiment and learn
about Perl and the LAMP stack, and for seasoned users to easily stand up 
simple RESTful services.

This is not a framework.  This is a quick-start bundle meant to create convenience
for learning and for small projects.  The fervent hope is that you will fall in love
with Perl and continue your journey onto Mojolicious, Dancer2, AnyEvent, PDL, Moose, Moo 
and all the other powerful Perl libraries.  

This is a LAMP stack bundle, Linux, Apache, MySQL/MariaDB, and Perl.  Of course, there are
many other fantastic options, but for the sake of simplicity, this quick-start bundle 
has made some definite choices.  

=head1 PREREQUISITES / INSTALLATION

Please start with a plain Ubuntu VM, version 18.04 or higher.  Please log in as root
and install the required packages with this command:

apt install apt install build-essential apache2 cpanminus

Start writing docs
- What / Why
- Pre-req's & Set Up
- Building microservices
- Writing scripts
- Methods
- Running via SystemD & Apache
- Improve 'pepper help'


=head1 SYNOPSIS

  use Pepper;

  my $pepper = Pepper->new();

=head1 AUTHOR

Eric Chernoff - ericschernoff at gmail.com 