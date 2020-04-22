use strict;
use Test::More 0.98;

use_ok $_ for qw(
	Pepper
);

# make sure Pepper::Utilities works

use_ok $_ for qw(
	Pepper::Utilities
);

my $pepper_utils = Pepper::Utilities->new({
	'skip_db' => 1,
	'skip_config' => 1,
});

isa_ok( $pepper_utils, 'Pepper::Utilities' );

my @util_methods = ('send_response','template_process','logger','filer','json_from_perl','json_to_perl','random_string','time_to_date');
can_ok('Pepper::Utilities', @util_methods);

# make sure /opt is there
my $opt_is_there = 0;
	$opt_is_there = 1 if (-d '/opt');
ok($opt_is_there, '/opt exists');

done_testing;

