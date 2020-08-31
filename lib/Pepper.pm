package Pepper;

$Pepper::VERSION = '1.0';

use Pepper::DB;
use Pepper::PlackHandler;
use Pepper::Utilities;
use lib '/opt/pepper/code/';

# try to be a good person
use strict;
use warnings;

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
	eval qq{$endpoint_handler_module->import};
	
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


NEXT STEPS:
x Move 'templates' into Pepper::Templates & update Commander.pm
x pepper test db
- Documentation
- sample endpoints
- sample script

Test these:
x MySQL
- systemd service file
- Apache config

=head1 DESCRIPTION / PURPOSE

Perl is a wonderful language with an amazing ecosystem and terrific community.
This quick-start kit is meant for new users to easily experiment and learn
about Perl and for seasoned users to easily stand up simple web services.

This is not a framework.  This is a quick-start kit meant to simplify learning and 
small projects.  The hope is that you will fall in love with Perl and continue your 
journey on to Mojolicious, Dancer2, AnyEvent, PDL and all the other powerful Perl libraries.  

This kit will support database connections to MySQL 5.7 or 8, MariaDB 10.3+. 
Advice is provided for hosting via Apache 2.4+ and Nginx 1.18+.
There are lots of other great options out there, but choices were 
made for the sake of simplicity.

=head1 SYNOPSIS

  To set up a new web service:

  # sudo pepper setup
  # sudo pepper set-endpoint /dogs/daisy PepperApps::Dogs::Daisy
  
  A new Perl module is created at /opt/pepper/code/PepperApps/Dogs.Daisy.pm.
  Edit that module perform any actions / return any content you prefer.  
  You will be able to execute the service via http://you.hostname.ext:5000/dogs/daisy
  More details below.
  
  For a simple Perl script, add this at the top.
  
  use Pepper;
  my $pepper = Pepper->new();
  
  The $pepper object will provide many conveniences for your database and JSON.
  More details below.

=head1 INSTALLATION / GETTTING STARTED

This kit has been tested with Ubuntu 18.04 & 20.04, CentOS 8, and FeeBSD 12.

1. Install the needed packages
	Ubuntu: apt install build-essential cpanminus libmysqlclient-dev perl-doc zlib1g-dev 
	CentOS: yum install 
	FreeBSD: 
	
2. Recommended: If you do not already have a MySQL/MariaDB database available, 
	please install and configure one here.  Create a designated user and database for Pepper.
	See database vendor docs for details on this task.
	
3. Install Pepper:  sudo cpanm Pepper
	It may take several minutes to build and install the few dependencies.
	
4. Set up / configure Pepper:  sudo pepper setup
	This will prompt you for the configuration options. Choose carefully, but you can
	safely re-run this command if needed to make changes.  This command will create the
	directory under /opt/pepper with the needed sub-directories and templates.
	Do not provide a 'Default endpoint-handler Perl module' for now. (You can update later.)
	
5. Open up /opt/pepper/code/PepperExample.pm and read the comments to see how easy it
	is to code up web endpoints.
	
6. Start the Plack service:  sudo pepper start
	Then check out the results of PepperExample.pm here: https://127.0.0.1:5000 .
	You should receive basic JSON results.  Modify PepperExample.pm to tweak those results
	and then restart the Plack service to test your changes:  sudo pepper restart
	Any errors will be logged to /opt/pepper/log/fatals-YYYY-MM-DD.log (replacing YYYY-MM-DD).
	In a dev environment, you can auto-restart, see 'sudo pepper help'
	
7. If you would like to write command-line Perl scripts, you can skip step #6 and just
	start your script like this:
	
		use Pepper;
		my $pepper = Pepper->new();

The $pepper object will have all the methods and variables described below.

=head1 THE /opt/pepper DIRECTORY

After running 'sudo pepper setup', /opt/pepper should contain the following subdirectories:

=over 12

=item C<code>

This is where your endpoint handler modules go.  This will be added to the library path
in the Plack service, so you can place any other custom modules/packages that you create
to use in your endpoints. You may choose to store scripts in here.

=item C<config>

This will contain your main pepper.cfg file, which should only be updated via 'sudo pepper setup'.
If you do not opt to specify an option for 'url_mappings_database', the pepper_endpoints.json file
will be stored here as well.  Please store any other custom configurations.

=item C<lib>

This contains the pepper.psgi script used to run your services via Plack/Gazelle. 
Please only modify if you are 100% sure of the changes you are making.

=item C<log>

All logs generated by Pepper are kept here. This includes access and error logs, as well
as any messages you save via $pepper->logger(). The primary process ID file is also 
kept here.  Will not contain the logs created by Apache/Nginx or the database server.

=item C<template>

This is where Template Toolkit templates are kept. These can be used to create text
files of any type, including HTML to return via the web.  Be sure to not delete 
the 'system' subdirectory or any of its files.

=back

=head1 ATTRIBUTES IN THE $pepper OBJECT

=head1 METHODS PROVIDED BY THE $pepper OBJECT

=head1 USING WITH APACHE / NGINIX AND SYSTEMD

=head1 See Also

http://www.template-toolkit.org/

=head1 AUTHOR

Eric Chernoff - ericschernoff at gmail.com 