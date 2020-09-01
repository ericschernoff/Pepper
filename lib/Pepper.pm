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
		foreach my $key ('hostname','uri','cookies','params','auth_token','uploaded_files') {
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

Pepper - Quick-start kit for creating microservices in Perl.

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
journey on to Mojo, Dancer2, AnyEvent, PDL and all the many terrific Perl libraries.  
This is a great community of builders, and there is so much to discover at 
L<https://metacpan.org> and L<https://perldoc.perl.org/>

This kit supports database connections to MySQL 5.7/8 or MariaDB 10.3+. 
There are many other great options out there, but one database driver
was chosen for the sake of simplicity.  If your heart is set on Postgres,
you may choose not to connect to MySQL/MariaDB server and instead use
L<DBD:Pg> directly.

=head1 SYNOPSIS

  To set up a new web service:

  # sudo pepper setup
  # sudo pepper set-endpoint /dogs/daisy PepperApps::Dogs::Daisy
  
  A new Perl module is created at /opt/pepper/code/PepperApps/Dogs.Daisy.pm.
  Edit that module to have it perform any actions and return any content you prefer.  
  You will be able to execute the service via http://you.hostname.ext:5000/dogs/daisy
  
  For a simple Perl script, just add this at the top.
  
  use Pepper;
  my $pepper = Pepper->new();
  
  The $pepper object will provide several conveniences for MySQL/MariaDB, JSON
  parsing, Template Toolkit, file handling and logging.  In Web/Plack mode,
  $pepper will also include the entire PSGI (CGI) environment.

=head1 INSTALLATION / GETTTING STARTED

This kit has been tested with Ubuntu 18.04 & 20.04, CentOS 8, and FeeBSD 12.

1. Install the needed packages
	Ubuntu: apt install build-essential cpanminus libmysqlclient-dev perl-doc zlib1g-dev 
	CentOS: yum install 
	FreeBSD: 
	
2. Recommended: If you do not already have a MySQL/MariaDB database available, 
	please install and configure that here.  Create a designated user and database for Pepper.
	See the Mysql / MariaDB docs for guidance on this task.
	
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

If you are new to Perl, please have L<https://perldoc.perl.org/> handy, especially
the 'Functions' menu and 'Tutorials' under the 'Manuals' menu.

=head1 ADDING / MANAGING ENDPOINTS

Adding a new endpoint is just as easy as:

	# sudo pepper set-endpoint /Some/URI PerlModuleDirectory::PerlModule
	
For example:

	# sudo pepper set-endpoint /Carrboro/WeaverStreet PepperApps::Carrboro::WeaverStreet
	
That will map any request to the /Carrboro/WeaverStreet endpoint to the endpoint_handler()
subroutine in /opt/pepper/code/PepperApps/Carrboro/WeaverStreet.pm and a very basic version
of that file will be created for you.  Simply edit and test the file to power the endpoint.

If you wish to change the endpoint to another module, just re-issue the command:

	# sudo pepper set-endpoint /Carrboro/WeaverStreet PepperApps::Carrboro::AnotherWeaverStreet

You can see your current endpoints via list-endpoints

	# sudo pepper list-endpoints
	
To deactivate an endpoint, you can set it to the default:

	# sudo pepper set-endpoint /Carrboro/WeaverStreet default

=head1 BASICS OF AN ENDPOINT HANDLER

You can have any code you require within the endpoint_handler subroutine.  You must
leave the 'my ($pepper) = @_;' right below 'sub endpoint_handler', and your
endpoint handler must return some text or data that can be sent to the browser.

If you wish to send JSON to the client, simply return a reference to the data structure
that should be converted to JSON. Otherwise, you can return HTML or text. For your convenience,
an interface to the the excellent Template-Toolkit library is a part of this kit (see below).

For example:

	my $data_to_send = {
		'colors' => ['Red','Green','Blue'],
		'favorite_city' => 'Boston',
	};

	return $data_to_send;  # client gets JSON of the above
	
	return qq{
		<html>
		<body>
			<h1>This is a bad web page</h1>
		</body>
		</html>
	}; # client gets some HTML
	
	# you can return plain text as well, i.e. generated config files

The $pepper object has lots of goodies, described in detail in the following sections.  There
is a wealth of additional libraries in L<https://metacpan.org> and you add include your 
own re-usable packages under /opt/pepper/code .  For instance, if many of your endpoints
share some data-crunching routines, you could create /opt/pepper/code/MyUtils/DataCrunch.pm
and import it as:  use MyUtils::DataCrunch;

=head1 WEB / PSGI ENVIRONMENT IN THE $pepper OBJECT

When you are building an endpoint handler for a web URI, the $pepper object will
contain the full PSGI (~CGI) environment, including the parameters sent by
the client.  This can be accessed as follows:

=head2 $pepper->{params}

This is a hash of all the parameters sent via a GET or POST request or 
via a JSON request body.  For example, if a web form includes a 'book_title'
field, the submitted value would be found in $pepper->{params}{book_title} .

For multi-value fields, such as checkboxes or multi-select menus, those values
can be found as arrays under $pepper->{params}{multi} or comma-separated lists
under $pepper->{params}.  For example, if are two values, 'Red' and 'White', 
for the 'colors' param, you could access:

=over 12

	$pepper->{params}{colors} # Would be 'Red,White'
	$pepper->{params}{multi}{colors}[0]  # would be 'Red'
	$pepper->{params}{multi}{colors}[1]  # would be 'White'

-back	

=head2 $pepper->{cookies}

This is a name/value hash of the cookies sent by the client. If there is 
a cookie named 'Oreo' with a value of 'Delicious but unhealthy', that
text value would be accessible at $pepper->{cookies}{Oreo} .

Setting cookies can be done like so:

	$pepper->set_cookie({
		'name' => 'Oreo', # could be any name
		'value' => 'Delicious but unhealthy', # any text you wish
		'days_to_live' => integer over 0, # optional, default is 10
	}); 
	
These cookies are tied to the web service's hostname.

=head2 $pepper->{uploaded_files}

If there are any uploaded files, this will contain a name/value hash,
were the name (key) is the filename and the value is the path to access
the file contents on your server.  For example, to save all the
uploaded files to a permmanet space:

	use File::Copy;

	foreach my $filename (keys %{ $pepper->{uploaded_files} }) {
		my ($clean_file_name = $filename) =~ s/[^a-z0-9\.]//gi;
		copy($pepper->{uploaded_files}{$filename}, '/some/directory/'.$clean_file_name);
	}

=head2 $pepper->{auth_token}	

If the client sends an 'Authorization' header, that value will be stored in $pepper->{auth_token} 
for a minimally-secure API, provided you have some code to validate this token.

=head2 $pepper->{hostname}	

This will contain the HTTP_HOST for the request.  If the URL being accessed is
https://pepper.weaverstreet.net/All/Hail/Ginger, the value of $pepper->{hostname}
will be 'pepper.weaverstreet.net'; for http://pepper.weaverstreet.net:5000/All/Hail/Ginger,
$pepper->{hostname} will be 'pepper.weaverstreet.net:5000'.

=head2 $pepper->{uri}	

This will contain the endpoint URI. If the URL being accessed is
https://pepper.weaverstreet.net/All/Hail/Ginger, the value of $pepper->{uri}
will be '/All/Hail/Ginger'.

=head2 Accessing the Plack Request / Response objects.

The plain request and response Plack objects will be available at $pepper->{plack_handler}->{request}
and $pepper->{plack_handler}->{response} respectively.  Please only use these if you absolutely must,
and please see L<Plack::Request> and L<Plack::Response> before working with these.

=head1 RESPONSE / LOGGING / TEMPLATE METHODS PROVIDED BY THE $pepper OBJECT

=head2 template_process

This is an easy interface to the excellent Template Toolkit.  This is great for generating
HTML or any kind of processed text files.  Create your Template Toolkit templates 
under /opt/pepper/template and please see L<Template> and L<http://www.template-toolkit.org>
The basic idea is to process a template with the values in a data structure to create the 
appropriate text output.  

	To process a template and have your endpoint handler return the results:

	return $pepper->template_process({
		'template_file' => 'some_template.tt', 
		'template_vars' => $some_data_structure,
	});

You can add subdirectories under /opt/pepper/template and refer to the files as
'subdirectory_name/template_filename.tt'.

To save the generated text as a file:

	$pepper->template_process({
		'template_file' => 'some_template.tt', 
		'template_vars' => $some_data_structure,
		'save_file' => '/some/file/path/new_filename.ext',
	});

To have the template immediate sent out, such as for a fancy error page:

	$pepper->template_process({
		'template_file' => 'some_template.tt', 
		'template_vars' => $some_data_structure,
		'send_out' => 1,
		'stop_here' => 1, # recommended, execution will continue, but generated text is what they will get.
	});
	
=head2 logger

This adds entries to the files under /opt/pepper/log and is useful to log actions or
debugging messages.  You can send a plain text string or a reference to a data structure.

	$pepper->logger('A nice log message','example-log');

	That will add a timestamped entry to a file named for example-log-YYYY-MM-DD.log. If you
	leave off the second argument, the message is appended to today's errors-YYYY-MM-DD.log.

	$pepper->logger($hash_reference,'example-log');

	This will save the output of Data::Dumper's Dumper($hash_reference) to today's
	example-log-YYYY-MM-DD.log.

=head2 send_response

This method will send data to the client.  It is usually unnecessary, as you will simply
return data structures or text.  This may be useful in two situations:

	# To bail-out in case of an error:
	$pepper->send_response('Error, everything just blew up.',1);

	# To send out a binary file:
	$pepper->send_response($file_contents,'the_filename.ext',2,'mime/type');
	$pepper->send_response($png_file_contents,'lovely_ginger.png',2,'image/png');
	
=head2 set_cookie

From a web endpoint handler, you may set a cookie like this:

	$pepper->set_cookie({
		'name' => 'Cookie_name', # could be any name
		'value' => 'Cookie_value', # any text you wish
		'days_to_live' => integer over 0, # optional, default is 10
	}); 

=head1 DATABASE METHODS PROVIDED BY THE $pepper OBJECT

=head2 change_database
=head2 comma_list_select
=head2 commit
=head2 do_sql
=head2 list_select
=head2 quick_select
=head2 sql_hash

=head1 JSON METHODS PROVIDED BY THE $pepper OBJECT

=head2 json_from_perl
=head2 json_to_perl
=head2 read_json_file
=head2 write_json_file

=head1 DATE / UTILITY METHODS PROVIDED BY THE $pepper OBJECT

=head2 filer
=head2 random_string
=head2 time_to_date

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

=head1 USING WITH APACHE / NGINIX AND SYSTEMD

=head1 REGARDING AUTHENTICATION & SECURITY

=head1 See Also

http://www.template-toolkit.org/

=head1 AUTHOR

Eric Chernoff - ericschernoff at gmail.com 