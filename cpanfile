requires 'perl', '5.008001';

on 'test' => sub {
    requires 'CGI', '>= 4.46',
    requires 'Cpanel::JSON::XS', '>= 4.08';
    requires 'DBD::mysql', '>= 4.050';
    requires 'DBI', '>= 1.643';
    requires 'Try::Tiny', '>= 0.30';
    requires 'Test::More', '0.98';
};

