package Pepper::Commander;

use 5.022001;
use strict;
use warnings;

our $VERSION = "1.0.1";

# for accepting options
use IO::Prompter;

# for getting default hostname/domain name
use Net::Domain qw( hostfqdn domainname );

# for controlling plack
use Server::Starter qw(start_server restart_server stop_server);

# for doing everything else
use Pepper;

# create myself and try to grab arguments
sub new {
	my ($class) = @_;

	# set up the object with all the options data
	$self = bless {
		'pepper' => Pepper->new(
			'skip_db' => 1,
			'skip_config' => 1,
		),
	}, $class;

}

# dispatch based on $ARGV[0]
sub run {
	my ($self,@args) = @_;
	
	my $dispatch = {
		'setup' => 'setup_and_configure',
		'set-endpoint' => 'set_endpoint',
		'start' => 'plack_controller',
		'stop' => 'plack_controller',
		'restart' => 'plack_controller',
	};

	# have to be one of these
	if (!$args[0] || !$$dispatch{ $args[0] }) {
		die "Usage: sudo pepper setup|set-endpoint|start|stop|restart\n";
		
	# can not do anything without a config file
	} elsif ($args[0] ne 'setup' && !(-e $self->{pepper}->{utils}->{config_file})) {
		die "You must run 'pepper setup' to create a config file.\n";
	
	# must run as root
	} elsif ($ENV{USER} ne 'root') {
	
		die "Usage: sudo pepper setup|set-endpoint|start|stop|restart\n";
		die "This command must be run as root.\n";
	
	# otherwise, run it
	} else {
		my $method = $$dispatch{$args[0]};
		$self->$method(@args);
	
	}
		
}

# create directory structure, build configs, create examples
sub setup_and_configure {
	my ($self,@args) = @_;

	if (!(-d '/opt/pepper')) {
		mkdir ('/opt/pepper');
	}
	foreach $subdir ('config','log','code','template') {
		$subdir_full = '/opt/pepper/'.$subdir;
		mkdir ($subdir_full) if !(-d $subdir_full);
	}
	
	$config_options_map = [
		['system_username','System user to own and run this service (required)',$ENV{USER}],
		['development_server','Is this a development server? (Y or N)','Y'],
		['database_server', 'Hostname or IP Address for your MySQL/MariaDB server (required)'],
		['database_username', 'Username to connect to your MySQL/MariaDB server (required)'],
		['database_password', 'Password to connect to your MySQL/MariaDB server (required)'],
		['connect_to_database', 'Default connect-to database','information_schema'],
		['salt_phrase', 'Salt phrase for encryption routines (required)'],
		['url_mappings_database', 'Database to store URL/endpoint mappings.  User named above must be able to create a table.  Leave blank to use JSON config file.'],
	];

	# shared method below	
	$config = $self->prompt_user($config_options_map);
	
	my ($username,$pass,$uid,$gid) = getpwnam($$config{system_username})
		or die "Error: System user '$$config{system_username}' does not exist.\n";
	
	# calculate the endpoint storage
	if ($$config{url_mappings_database}) {
		$$config{url_mappings_table} = $$config{url_mappings_database}.'.pepper_endpoints';
	} else {
		$$config{url_mappings_file} = '/opt/pepper/config/pepper_endpoints.json';
	}
	
	# now write the file
	$self->{pepper}->{utils}->write_system_configuration($config);

	# create the default handler template
	$self->{pepper}->{utils}->filer('/opt/pepper/template/endpoint_handler.tt', 'write', $self->_handler_template());

	# the system user owns the directory tree
	system("chown -R $$config{system_username} /opt/pepper");

}

# method to add an endpoint mapping to the system
sub set_endpoint {
	my ($self,@args) = @_;
	
	# we need the configuration for this
	$self->{pepper}->{utils}->read_system_configuration();
	
	$endpoint_prompts = [
		['endpoint_uri','URI for endpoint, such as /hello/world (required)'],
		['endpoint_handler', 'Module name for endpoint, such as PepperApps::HelloWorld (required)'],
	];

	# shared method below	
	$endpoint_data = $self->prompt_user($endpoint_prompts);	
	
	# commit the change
	$self->{pepper}->{utils}->set_endpoint_mapping( $$endpoint_data{endpoint_uri}, $$endpoint_data{endpoint_handler} );
	
	# create the module, if it does not exist
	($module_file = $$endpoint_data{endpoint_handler}) =~ s/\:\:/\//g;
	$module_file = '/opt/pepper/code/'.$module_file.'.pm';
	if (!(-e $module_file)) { # start the handler
		$self->{pepper}->{utils}->template_process(
			'template_file' => '/opt/pepper/template/endpoint_handler.tt'
			'template_vars' => $endpoint_data,
			'save_file' => $module_file
		);	
		$extra_text = $module_file." was created.  Please edit to taste\n";
		
		system("chown $self->{pepper}->{utils}->{config}{system_username} $module_file");
		
	} else {
		$extra_text = $module_file." already exists and was left unchanged.\n";
	}
	
	# all done
	print "Endpoint configured for $$endpoint_data{endpoint_uri}\n".$extra_text;
	
}

# method to intercept prompts
sub prompt_user {
	my ($self,$prompts_map) = @_;
	
	foreach $prompt_set (@$prompts_map) {
		# password mode?
		$prompt_key = $$prompt_set[0];
		
		if ($$prompt_set[0] =~ /password|salt_phrase/i) {
			$$results{$prompt_key} = prompt $$prompt_set[1].$$prompt_set[2], -v, -echo=>'*', -must => { 'provide a value' => qr/./};
		} elsif ($$option_set[0] =~ /required/i) {
			$$results{$prompt_key} = prompt $$prompt_set[1].$$prompt_set[2], -v, -must => { 'provide a value' => qr/./};
		} else { 
			$$results{$prompt_key} = prompt $$prompt_set[1].$$prompt_set[2], -v;
		}		
		
		# accept defaults
		$$results{$prompt_key} ||= $$prompt_set[2];

	}

	return $results;
}

# method to start and stop plack
sub plack_controller {
	my ($self,@args) = @_;

	if ($args[0] eq 'start') {
	
	
	} elsif 

	if ($opts{restart}) {
		restart_server(%opts);
		exit 0;
	}

	if ($opts{stop}) {
		stop_server(%opts);
		exit 0;
	}


}

# text for the endpoint handler templates
sub _handler_template {
	my $self = shift;
	return qq{package [%endpoint_handler%];

# provides handler for Endpoint URI: [%endpoint_uri%]

# create the object
sub new {
	my ($class,$pepper) = @_;

	$self = bless {
		'pepper' => $pepper,
	}, $class;
	
	return $self;
}

# handle the request
sub handler {
	my $self = shift;
	my $pepper = $self->{pepper}; # convenience

	### YOUR FANTASTIC CODE GOES HERE
	# Please see perldoc pepper for methods available in $pepper
	#
	# Parameters sent via GET/POST or JSON body are available 
	# within $pepper->{params}
	#
	# When you're ready, please use $pepper->send_response($content) to 
	# return content to the client.  To send out JSON, $content should be
	# a reference to an array or hash.  HTML or Text is also great, 
	# and please see the documentation for other options.

	# Just a very basic start
	my $starter_content = {
		'current_timestamp' => $pepper->time_to_date( time(), 'to_date_human_full' ),
		'hello' => 'world',
	};
	
	$pepper->send_response($starter_content);
	
}

1;
	
};
}

1;
