requires 'perl', '>= 5.022001';

on 'test' => sub {
    requires 'CGI', '>= 4.46',
    requires 'Cpanel::JSON::XS', '>= 4.08';
    requires 'DBI', '>= 1.643';
    requires 'DBD::mysql', '>= 4.050';

	requires 'Date::Format', '>= 2.24';
	requires 'Date::Manip::Date', '>= 6.72';
	requires 'DateTime', '>= 1.50';
	requires 'Encode', '>= 2.88';
	
	requires 'Template', '>= 3.007';

	requires 'Path::Tiny', '>= 0.108';
	requires 'Scalar::Util', '>= 1.50';
    requires 'Test::More', '0.98';
    requires 'Try::Tiny', '>= 0.30';

	requires 'Plack', '>= 1.0047';
	requires 'Server::Starter', '>= 0.33';
	requires 'Plack::Middleware::DBIx::DisconnectAll', '>= 0.02';
	requires 'Plack::Middleware::ReverseProxy', '>= 0.15';
	requires 'Plack::Middleware::Timeout','0.09';
	requires 'Starlet', '>= 0.31';
	requires 'Net::Server::SS::PreFork', '>= 0.05';
	requires 'Starman', '>= 0.4014';
	requires 'Plack::Handler::Gazelle', '>= 0.48';
	requires 'File::RotateLogs', '>= 0.08';
};