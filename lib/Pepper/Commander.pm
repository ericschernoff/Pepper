package Pepper::Commander;

use 5.022001;
use strict;
use warnings;

our $VERSION = "1.0.1";

# for accepting options
use IO::Prompter;

# for getting default hostname/domain name
use Net::Domain qw( hostfqdn domainname );

# for doing everything else
use Pepper;
use Pepper::DB;
use Pepper::Templates;

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

	return $self;
}

# dispatch based on $ARGV[0]
sub run {
	my ($self,@args) = @_;
	
	my $dispatch = {
		'help' => 'help_screen',
		'setup' => 'setup_and_configure',
		'config' => 'setup_and_configure',
		'set-endpoint' => 'set_endpoint',
		'list-endpoints' => 'list_endpoints',
		'test-db' => 'test_db',
		'start' => 'plack_controller',
		'stop' => 'plack_controller',
		'restart' => 'plack_controller',
	};
	
	# have to be one of these
	if (!$args[0] || !$$dispatch{$args[0]}) {

		die "Usage: sudo pepper help|setup|set-endpoint|list-endpoints|start|stop|restart\n";
		
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

# pepper test-db

This will perform a basic connection / query test on the database config you provided
via 'pepper setup'.  Highly recommended to be run after setup.

# pepper set-endpoint [URI] [PerlModule]

This creates an endpoint mapping in Pepper to tell Plack how to dispatch incoming
requests.  The first argument is a URI and the second is a target Perl module for
handing GET/POST requests to the URI.  If these two arguments are not given, you
will be prompted for the information.  

If the Perl module does not exist under /opt/pepper/code, an initial version will be created.

# pepper list-endpoints

This will output your configured endpoint mappings.

# pepper start [#Workers] [dev-reload]

Attempts to start the Plack service.  Provide an integer for the #Workers to spcify the 
maximum number of Plack processes to run.  The default is 10.

If you indicate a number of workers plus 'dev-reload' as the third argument, Plack 
will be started with the auto-reload option to auto-detect changes to your code.
If that is not provided, you will need to issue 'pepper restart' to put your code 
changes into effect.  Enabling dev-reload will slow down Plack significantly, so it 
is only appropriate for development environments.

# pepper restart

Restarts the Plack service and put your code changes into effect.

};

}

# test that the database connection works; hard to do this in module install
sub test_db {
	my $self = shift;
	
	my $utils = $self->{pepper}->{utils};
		$utils->read_system_configuration();
	
	my $db;
	eval {
		$db = Pepper::DB->new({
			'config' => $utils->{config},
			'utils' => $utils,
		});
	};
	
	if ($@) {
		print "\nCould not connect to the database.\nError Msg: $@";
		print "\nPlease confirm config and re-run 'pepper setup' as needed.\n\n";
	}
	
	# this should work on our three supported DB's
	my ($current_timestamp) = $db->quick_select('select current_timestamp');
	
	if ($current_timestamp =~ /^\d{4}\-\d{2}\-\d{2}\s/) {
		print "\nYour database connection appears to be working.\n\n";
		
	} else {
		print "\nCould not query the database.\nError Msg: $@";
		print "\nPlease confirm config and re-run 'pepper setup' as needed.\n\n";
	
	}

}

# create directory structure, build configs, create examples
sub setup_and_configure {
	my ($self,@args) = @_;

	my ($config_options_map, $config, $subdir_full, $subdir, $map_set, $key);

	if (!(-d '/opt/pepper')) {
		mkdir ('/opt/pepper');
	}
	foreach $subdir ('code','config','lib','log','template') {
		$subdir_full = '/opt/pepper/'.$subdir;
		mkdir ($subdir_full) if !(-d $subdir_full);
	}
	
	# sanity
	my $utils = $self->{pepper}->{utils};
	
	$config_options_map = [
		['system_username','System user to own and run this service (required)',$ENV{USER}],
		['development_server','Is this a development server? (Y or N)','Y'],
		['use_database','Connect to a database server? (Y or N)','Y'],
		['database_server', 'Hostname or IP Address for your MySQL/MariaDB/Postgres server (required)'],
		['database_type', qq{Database server type; 'postgres' or 'mysql' (required)},'mysql'],
		['database_username', 'Username to connect to your MySQL/MariaDB/Postgres server (required)'],
		['database_password', 'Password to connect to your MySQL/MariaDB/Postgres server (required)'],
		['connect_to_database', 'Default connect-to database','information_schema'],
		['url_mappings_database', 'Database to store URL/endpoint mappings.  User above must be able to create.  Leave blank to use JSON config file.'],
		['default_endpoint_module', 'Default endpoint-handler Perl module (required)'],
	];
	
	# does a configuration already exist?
	if (-e $utils->{config_file}) {
		$utils->read_system_configuration();
		foreach $map_set (@$config_options_map) {
			$key = $$map_set[0];
			$$map_set[2] = $utils->{config}{$key} if $utils->{config}{$key}; 
		}
	}	
	
	# shared method below	
	$config = $self->prompt_user($config_options_map);

	# make the 'database_type' all lowercase 
	$$config{database_type} = lc($$config{database_type});
	
	my ($username,$pass,$uid,$gid) = getpwnam($$config{system_username})
		or die "Error: System user '$$config{system_username}' does not exist.\n";
	
	# calculate the endpoint storage
	if ($$config{url_mappings_database}) {
		$$config{url_mappings_table} = $$config{url_mappings_database}.'.pepper_endpoints';
	} else {
		$$config{url_mappings_file} = '/opt/pepper/config/pepper_endpoints.json';
	}
	
	# now write the file
	$utils->write_system_configuration($config);

	# install some needed templates
	my $template_files = {
		'endpoint_handler.tt' => 'endpoint_handler',
		'pepper.psgi' => 'psgi_script',
		'pepper_apache.conf' => 'systemd_config',
		'pepper.service' => 'apache_config',
	};
	my $pepper_templates = Pepper::Templates->new();

	foreach my $t_file (keys %$template_files) {
		my $dest_dir = 'template'; # everything by the PSGI script goes in 'template'
			$dest_dir = 'lib' if $t_file eq 'pepper.psgi';
		my $dest_file = '/opt/pepper/'.$dest_dir.'/'.$t_file;
		
		# grab it from github
		my $template_method = $$template_files{$t_file};
		my $contents = $pepper_templates->$template_method();
		
		# set the username for the SystemD service
		$contents =~ s/User=root/User=$$config{system_username}/;
		
		# now save it out
		$contents = $utils->filer($dest_file,'write',$contents);
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
		$utils->template_process({
			'template_file' => 'endpoint_handler.tt',
			'template_vars' => $endpoint_data,
			'save_file' => $module_file
		});	
		$extra_text = "\n".$module_file." was created.  Please edit to taste\n";
		
		system("chown $utils->{config}{system_username} $module_file");
		
	} else {
		$extra_text = "\n".$module_file." already exists and was left unchanged.\n";
	}
	
	# all done
	print "\nEndpoint configured for $$endpoint_data{endpoint_uri}\n".$extra_text;
	
}

# method to list all of the existing endpoints
sub list_endpoints {
	my ($self) = @_;

	my $utils = $self->{pepper}->{utils}; # sanity
	
	# we need the configuration for this
	$utils->read_system_configuration();
	
	my $url_mappings = {};

	# create a DB object if saving to a table
	if ($utils->{config}{url_mappings_table}) {
		$utils->{db} = Pepper::DB->new({
			'config' => $utils->{config},
			'utils' => $utils,
		});
		
		my $url_mappings_array = $utils->{db}->do_sql(qq{
			select endpoint_uri,handler_module from $utils->{config}{url_mappings_table} 
		});
		foreach my $map (@$url_mappings_array) {
			$$url_mappings{$$map[0]} = $$map[1];
		}
		
	# or maybe a JSON file
	} elsif ($utils->{config}{url_mappings_file}) {
	
		$url_mappings = $utils->read_json_file( $utils->{config}{url_mappings_file} );
		
	}	

	# get a sorted list of URLs	
	my @urls = sort keys %$url_mappings;

	# no urls? 
	if (!$urls[0]) {
		print "\nNo endpoints are configured.  Please use 'pepper set-endpoint'.\n\n";
		return;
	}
	
	# otherwise, print them out
	print "\nCurrent URL-to-code mappings:\n";
	foreach my $url (@urls) {
		print "\n$url --> $$url_mappings{$url}\n";
	}
	print "\n";

	return;
}

# method to intercept prompts
sub prompt_user {
	my ($self,$prompts_map) = @_;
	
	my ($prompt_key, $prompt_set, $results, $the_prompt);
	
	$$results{use_database} = 'Y'; # default for below
	
	foreach $prompt_set (@$prompts_map) {
		$prompt_key = $$prompt_set[0];

		# if they want to skip database configuration, we will clear/skip the database values
		if ($prompt_key =~ /database/ && $$results{use_database} eq 'N') {
			$$results{$prompt_key} = '';
			next;
		}
	
		# password mode?
	
		$the_prompt = $$prompt_set[1];
		if ($$prompt_set[2]) {
			if ($$prompt_set[0] =~ /password/i) {
				$the_prompt .= ' [Default: Stored value]';
			} else {
				$the_prompt .= ' [Default: '.$$prompt_set[2].']';
			}
		}
		$the_prompt .= ' : ';
		
		if ($$prompt_set[0] =~ /password/i && !$$prompt_set[2]) {
			$$results{$prompt_key} = prompt $the_prompt, -echo=>'*', -stdio, -v, -must => { 'provide a value' => qr/\S/};

		} elsif ($$prompt_set[0] =~ /password/i) {
			$$results{$prompt_key} = prompt $the_prompt, -echo=>'*', -stdio, -v;

		} elsif ($$prompt_set[1] =~ /required/i && !$$prompt_set[2]) {
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
	
	my $dev_reload = '';
		$dev_reload = '-R /opt/pepper/code' if $args[2];
		
	if ($args[0] eq 'start') {

		my $max_workers = $args[1] || 10;

		system(qq{/usr/local/bin/start_server --enable-auto-restart --auto-restart-interval=300 --port=5000 --dir=/opt/pepper/lib --log-file="| /usr/bin/rotatelogs /opt/pepper/log/pepper.log 86400" --daemonize --pid-file=$pid_file -- plackup -s Gazelle --max-workers=$max_workers -E deployment $dev_reload pepper.psgi});
	
	} elsif ($args[0] eq 'stop') {
		
		system(qq{kill -TERM `cat $pid_file`});

	} elsif ($args[0] eq 'restart') {

		system(qq{kill -HUP `cat $pid_file`});
		
	}

}

1;

=head1 NAME

Pepper::Commander 

=head1 DESCRIPTION / PURPOSE

This package provides all the functionality for the 'pepper' command script, which
allows you to configure and start/stop the Pepper Plack service.  The 'pepper' 
command must be run as root or via sudo, and expects at least one argument.

=head2 sudo pepper setup

This is the configuration mode.  The Pepper workspace will be created under /opt/pepper,
unless it already exists.  You will be prompted for the configuration options, and
your configuration file will be created or overwritten.

=head2 sudo pepper test-db

This will perform a basic connection / query test on the database config you provided
via 'pepper setup'.  

=head2 sudo pepper set-endpoint [URI] [PerlModule]

This creates an endpoint mapping in Pepper to tell Plack how to dispatch incoming
requests.  The first argument is a URI and the second is a target Perl module for
handing GET/POST requests to the URI.  If these two arguments are not given, you
will be prompted for the information.  

If the Perl module does not exist under /opt/pepper/code, an initial version will be created.

=head2 sudo pepper list-endpoints

This will output your configured endpoint mappings.

=head2 sudo pepper start [#Workers] [dev-reload]

Attempts to start the Plack service.  Provide an integer for the #Workers to spcify the 
maximum number of Plack processes to run.  The default is 10.

If you indicate a number of workers plus 'dev-reload' as the third argument, Plack 
will be started with the auto-reload option to auto-detect changes to your code.
If that is not provided, you will need to issue 'pepper restart' to put your code 
changes into effect.  Enabling dev-reload will slow down Plack significantly, so it 
is only appropriate for development environments.

=head2 sudo pepper restart

Restarts the Plack service and put your code changes into effect.