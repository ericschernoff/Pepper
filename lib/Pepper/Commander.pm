package Pepper::Commander;

use 5.022001;
use strict;
use warnings;

our $VERSION = "1.0.1";

# for accepting options
use IO::Prompter;

# for getting default hostname/domain name
use Net::Domain qw( hostfqdn domainname );

# for retrieving important templates from the project's github
use LWP::Simple;

# for doing everything else
use Pepper;
use Pepper::DB;

# create myself and try to grab arguments
sub new {
	my ($class) = @_;

	# set up the object with all the options data
	my $self = bless {
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
		'help' => 'help_screen',
		'setup' => 'setup_and_configure',
		'set-endpoint' => 'set_endpoint',
		'start' => 'plack_controller',
		'stop' => 'plack_controller',
		'restart' => 'plack_controller',
	};
	
	# have to be one of these
	if (!$args[0] || !$$dispatch{$args[0]}) {

		die "Usage: sudo pepper help|setup|set-endpoint|start|stop|restart\n";
		
	# can not do anything without a config file
	} elsif ($args[0] ne 'setup' && !(-e $self->{pepper}->{utils}->{config_file})) {
		die "You must run 'pepper setup' to create a config file.\n";
	
	# must run as root
	} elsif ($ENV{USER} ne 'root') {
	
		die "Usage: sudo pepper setup|set-endpoint|start|stop|restart\nThis command must be run as root.\n";
	
	# otherwise, run it
	} else {
		my $method = $$dispatch{$args[0]};
		$self->$method(@args);
	
	}
		
}

# print documentation on how to use this
sub help_screen {
	my ($self,@args) = @_;

print qq{

pepper: Utility command to configure and control the Pepper environment.

This command must be run as root or via sudo, and expects at least one
argument.

# pepper setup

This is the configuration mode.  The Pepper workspace will be created under /opt/pepper,
unless it already exists.  You will be prompted for the configuration options, and
your configuration file will be created or overwritten.

# pepper set-endpoint [URI] [PerlModule]

This creates an endpoint mapping in Pepper to tell Plack how to dispatch incoming
requests.  The first argument is a URI and the second is a target Perl module for
handing GET/POST requests to the URI.  If these two arguments are not given, you
will be prompted for the information.  

If the Perl module does not exist under /opt/pepper/code, an initial version will be created.

# pepper start [#Workers] [dev-reload]

Attempts to start the Plack service.  Provide an integer for the #Workers to spcify the 
maximum number of Plack processes to run.  The default is 10.

If you indicate a number of workers plus 'dev-reload' as the third argument, Plack 
will be started with the auto-reload option to auto-detect changes to your code.
If that is not provided, you will need to issue 'pepper restart' to make code changes
effective.  This option slows down Plack significantly, so it is only appropriate for
development environments.

# pepper restart

Restarts the Plack service and makes your code changes effective.

};

}

# create directory structure, build configs, create examples
sub setup_and_configure {
	my ($self,@args) = @_;

	my ($config_options_map, $config, $subdir_full, $subdir);

	if (!(-d '/opt/pepper')) {
		mkdir ('/opt/pepper');
	}
	foreach $subdir ('code','config','lib','log','template') {
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
		['default_endpoint_module', 'Default endpoint-handler Perl module (required)'],
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
	my $code = getstore('', '/opt/pepper/template/endpoint_handler.tt');
	if ($code != 200) {
		die "Error: Could not retrieve template file from GitHub\n";
	}

	# fetch the PSGI script
	my $code = getstore('', '/opt/pepper/lib/pepper.psgi');
	if ($code != 200) {
		die "Error: Could not retrieve PSGI script from GitHub\n";
	}

	# set the default endpoint
	$self->set_endpoint('default','default',$$config{default_endpoint_module});

	# the system user owns the directory tree
	system("chown -R $$config{system_username} /opt/pepper");
	
	print "\nConfiguration complete and workspace ready under /opt/pepper\n";

}

# method to add an endpoint mapping to the system
sub set_endpoint {
	my ($self,@args) = @_;
	
	my ($endpoint_data, $endpoint_prompts, $extra_text, $module_file);
	
	my $utils = $self->{pepper}->{utils}; # sanity
	
	# we need the configuration for this
	$utils->read_system_configuration();

	# create a DB object if saving to a table
	if ($utils->{config}{url_mappings_table}) {
		$utils->{db} = Pepper::DB->new({
			'config' => $utils->{config},
			'utils' => $utils,
		});
	}
	
	$endpoint_prompts = [
		['endpoint_uri','URI for endpoint, such as /hello/world (required)'],
		['endpoint_handler', 'Module name for endpoint, such as PepperApps::HelloWorld (required)'],
	];

	# if they passed in two args, we can use those for the endpoints
	if ($args[1] && $args[2]) {
		
		$endpoint_data = {
			'endpoint_uri' => $args[1],
			'endpoint_handler' => $args[2],
		};
	
	# otherwise, prompt them for the information
	} else {
		# shared method below	
		$endpoint_data = $self->prompt_user($endpoint_prompts);	
	}
	
	# commit the change
	$utils->set_endpoint_mapping( $$endpoint_data{endpoint_uri}, $$endpoint_data{endpoint_handler} );
	
	# create the module, if it does not exist
	my (@module_path, $directory_path, $part);
	(@module_path) = split /\:\:/, $$endpoint_data{endpoint_handler};
	if ($module_path[1]) {
		$directory_path = '/opt/pepper/code';
		foreach $part (@module_path) {
			if ($part ne $module_path[-1]) {
				$directory_path .= '/'.$part;
				if (!(-d $directory_path)) {
					mkdir($directory_path);
				}
			}
		}
	}
	
	($module_file = $$endpoint_data{endpoint_handler}) =~ s/\:\:/\//g;
	$module_file = '/opt/pepper/code/'.$module_file.'.pm';
	if (!(-e $module_file)) { # start the handler
		$utils->template_process(
			'template_file' => 'endpoint_handler.tt',
			'template_vars' => $endpoint_data,
			'save_file' => $module_file
		);	
		$extra_text = "\n".$module_file." was created.  Please edit to taste\n";
		
		system("chown $utils->{config}{system_username} $module_file");
		
	} else {
		$extra_text = "\n".$module_file." already exists and was left unchanged.\n";
	}
	
	# all done
	print "\nEndpoint configured for $$endpoint_data{endpoint_uri}\n".$extra_text;
	
}

# method to intercept prompts
sub prompt_user {
	my ($self,$prompts_map) = @_;
	
	my ($prompt_key, $prompt_set, $results, $the_prompt);
	
	foreach $prompt_set (@$prompts_map) {
		# password mode?
		$prompt_key = $$prompt_set[0];
		
		$the_prompt = $$prompt_set[1];
		if ($$prompt_set[2]) {
			$the_prompt .= ' [Default: '.$$prompt_set[2].']';
		}
		$the_prompt .= ' : ';
		
		if ($$prompt_set[0] =~ /password|salt_phrase/i) {
			$$results{$prompt_key} = prompt $the_prompt, -echo=>'*', -stdio, -v, -must => { 'provide a value' => qr/\S/};
		} elsif ($$prompt_set[1] =~ /required/i) {
			$$results{$prompt_key} = prompt $the_prompt, -stdio, -v, -must => { 'provide a value' => qr/\S/};
		} else { 
			$$results{$prompt_key} = prompt $the_prompt, -stdio, -v;
		}		
		
		# accept defaults
		$$results{$prompt_key} ||= $$prompt_set[2];

	}

	return $results;
}

# method to start and stop plack
sub plack_controller {
	my ($self,@args) = @_;

	my $pid_file = '/opt/pepper/log/pepper.pid';

	if ($args[1] eq 'start') {

		my $max_workers = $args[2] || 10;

		system(qq{/usr/local/bin/start_server --enable-auto-restart --auto-restart-interval=300 --port=127.0.0.1:5000 --dir=/opt/pepper/lib --log-file="| /usr/bin/rotatelogs /opt/pepper/log/pepper.log 86400" --daemonize --pid-file=$pid_file -- /usr/local/bin/plackup -s Gazelle --max-workers=$max_workers -E deployment pepper.psgi});
	
	} elsif ($args[1] eq 'stop') {
		
		my $pepper_pid = $self->{utils}->filer($pid_file);
		my $done = kill 'TERM', $pepper_pid;

	} elsif ($args[1] eq 'restart') {

		my $pepper_pid = $self->{utils}->filer($pid_file);
		my $done = kill 'HUP', $pepper_pid;
		
	}

}

1;
