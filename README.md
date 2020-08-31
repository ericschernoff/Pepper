# NAME

Pepper - Quick-start bundle for creating microservices in Perl.

NEXT STEPS:
x Move 'templates' into Pepper::Templates & update Commander.pm
x pepper test db
\- Documentation
\- sample endpoints
\- sample script

Test these:
x MySQL
\- systemd service file
\- Apache config

# DESCRIPTION / PURPOSE

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

# SYNOPSIS

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

# INSTALLATION / GETTTING STARTED

This kit has been tested with Ubuntu 18.04 & 20.04, CentOS 8, and FeeBSD 12.

1\. Install the needed packages
	Ubuntu: apt install build-essential cpanminus libmysqlclient-dev perl-doc zlib1g-dev 
	CentOS: yum install 
	FreeBSD: 

2\. Recommended: If you do not already have a MySQL/MariaDB database available, 
	please install and configure one here.  Create a designated user and database for Pepper.
	See database vendor docs for details on this task.

3\. Install Pepper:  sudo cpanm Pepper
	It may take several minutes to build and install the few dependencies.

4\. Set up / configure Pepper:  sudo pepper setup
	This will prompt you for the configuration options. Choose carefully, but you can
	safely re-run this command if needed to make changes.  This command will create the
	directory under /opt/pepper with the needed sub-directories and templates.
	Do not provide a 'Default endpoint-handler Perl module' for now. (You can update later.)

5\. Open up /opt/pepper/code/PepperExample.pm and read the comments to see how easy it
	is to code up web endpoints.

6\. Start the Plack service:  sudo pepper start
	Then check out the results of PepperExample.pm here: https://127.0.0.1:5000 .
	You should receive basic JSON results.  Modify PepperExample.pm to tweak those results
	and then restart the Plack service to test your changes:  sudo pepper restart
	Any errors will be logged to /opt/pepper/log/fatals-YYYY-MM-DD.log (replacing YYYY-MM-DD).
	In a dev environment, you can auto-restart, see 'sudo pepper help'

7\. If you would like to write command-line Perl scripts, you can skip step #6 and just
	start your script like this:

                use Pepper;
                my $pepper = Pepper->new();

The $pepper object will have all the methods and variables described below.

# THE /opt/pepper DIRECTORY

After running 'sudo pepper setup', /opt/pepper should contain the following subdirectories:

- `code`

    This is where your endpoint handler modules go.  This will be added to the library path
    in the Plack service, so you can place any other custom modules/packages that you create
    to use in your endpoints. You may choose to store scripts in here.

- `config`

    This will contain your main pepper.cfg file, which should only be updated via 'sudo pepper setup'.
    If you do not opt to specify an option for 'url\_mappings\_database', the pepper\_endpoints.json file
    will be stored here as well.  Please store any other custom configurations.

- `lib`

    This contains the pepper.psgi script used to run your services via Plack/Gazelle. 
    Please only modify if you are 100% sure of the changes you are making.

- `log`

    All logs generated by Pepper are kept here. This includes access and error logs, as well
    as any messages you save via $pepper->logger(). The primary process ID file is also 
    kept here.  Will not contain the logs created by Apache/Nginx or the database server.

- `template`

    This is where Template Toolkit templates are kept. These can be used to create text
    files of any type, including HTML to return via the web.  Be sure to not delete 
    the 'system' subdirectory or any of its files.

# ATTRIBUTES IN THE $pepper OBJECT

# METHODS PROVIDED BY THE $pepper OBJECT

# USING WITH APACHE / NGINIX AND SYSTEMD

# See Also

http://www.template-toolkit.org/

# AUTHOR

Eric Chernoff - ericschernoff at gmail.com 
