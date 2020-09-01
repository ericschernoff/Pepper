# NAME

Pepper - Quick-start kit for creating microservices in Perl.

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
journey on to Mojo, Dancer2, AnyEvent, PDL and all the many terrific Perl libraries.  
This is a great community of builders, and there is so much to discover at 
[https://metacpan.org](https://metacpan.org) and [https://perldoc.perl.org/](https://perldoc.perl.org/)

This kit supports database connections to MySQL 5.7/8 or MariaDB 10.3+. 
There are many other great options out there, but one database driver
was chosen for the sake of simplicity.  If your heart is set on Postgres,
answer 'N' to the 'Connect to a MySQL/MariaDB database server?' set up prompt
and use [DBD:Pg](DBD:Pg) instead of Pepper::DB.

# SYNOPSIS

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

# INSTALLATION / GETTTING STARTED

This kit has been tested with Ubuntu 18.04 & 20.04, CentOS 8, and FeeBSD 12.

1\. Install the needed packages
	Ubuntu: apt install build-essential cpanminus libmysqlclient-dev perl-doc zlib1g-dev 
	CentOS: yum install 
	FreeBSD: 

2\. Recommended: If you do not already have a MySQL/MariaDB database available, 
	please install and configure that here.  Create a designated user and database for Pepper.
	See the Mysql / MariaDB docs for guidance on this task.

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

If you are new to Perl, please have [https://perldoc.perl.org/](https://perldoc.perl.org/) handy, especially
the 'Functions' menu and 'Tutorials' under the 'Manuals' menu.

# ADDING / MANAGING ENDPOINTS

Adding a new endpoint is just as easy as:

        # sudo pepper set-endpoint /Some/URI PerlModuleDirectory::PerlModule
        

For example:

        # sudo pepper set-endpoint /Carrboro/WeaverStreet PepperApps::Carrboro::WeaverStreet
        

That will map any request to the /Carrboro/WeaverStreet endpoint to the endpoint\_handler()
subroutine in /opt/pepper/code/PepperApps/Carrboro/WeaverStreet.pm and a very basic version
of that file will be created for you.  Simply edit and test the file to power the endpoint.

If you wish to change the endpoint to another module, just re-issue the command:

        # sudo pepper set-endpoint /Carrboro/WeaverStreet PepperApps::Carrboro::AnotherWeaverStreet

You can see your current endpoints via list-endpoints

        # sudo pepper list-endpoints
        

To deactivate an endpoint, you can set it to the default:

        # sudo pepper set-endpoint /Carrboro/WeaverStreet default

# BASICS OF AN ENDPOINT HANDLER

You can have any code you require within the endpoint\_handler subroutine.  You must
leave the 'my ($pepper) = @\_;' right below 'sub endpoint\_handler', and your
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
is also a wealth of additional libraries in [https://metacpan.org](https://metacpan.org) and you add include your 
own re-usable packages under /opt/pepper/code .  For instance, if many of your endpoints
share some data-crunching routines, you could create /opt/pepper/code/MyUtils/DataCrunch.pm
and import it as:  use MyUtils::DataCrunch; .  You can also add subroutines below
the main endpoint\_handler() subroutine.  Pepper is just plain Perl, and the only "rule"
is that endpoint\_handler() needs to return what will be sent to the client.

# WEB / PSGI ENVIRONMENT IN THE $pepper OBJECT

When you are building an endpoint handler for a web URI, the $pepper object will
contain the full PSGI (~CGI) environment, including the parameters sent by
the client.  This can be accessed as follows:

## $pepper->{params}

This is a hash of all the parameters sent via a GET or POST request or 
via a JSON request body.  For example, if a web form includes a 'book\_title'
field, the submitted value would be found in $pepper->{params}{book\_title} .

For multi-value fields, such as checkboxes or multi-select menus, those values
can be found as arrays under $pepper->{params}{multi} or comma-separated lists
under $pepper->{params}.  For example, if are two values, 'Red' and 'White', 
for the 'colors' param, you could access:

>         $pepper->{params}{colors} # Would be 'Red,White'
>         $pepper->{params}{multi}{colors}[0]  # would be 'Red'
>         $pepper->{params}{multi}{colors}[1]  # would be 'White'
>
> \-back	

## $pepper->{cookies}

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

## $pepper->{uploaded\_files}

If there are any uploaded files, this will contain a name/value hash,
were the name (key) is the filename and the value is the path to access
the file contents on your server.  For example, to save all the
uploaded files to a permmanet space:

        use File::Copy;

        foreach my $filename (keys %{ $pepper->{uploaded_files} }) {
                my ($clean_file_name = $filename) =~ s/[^a-z0-9\.]//gi;
                copy($pepper->{uploaded_files}{$filename}, '/some/directory/'.$clean_file_name);
        }

## $pepper->{auth\_token}	

If the client sends an 'Authorization' header, that value will be stored in $pepper->{auth\_token} 
for a minimally-secure API, provided you have some code to validate this token.

## $pepper->{hostname}	

This will contain the HTTP\_HOST for the request.  If the URL being accessed is
https://pepper.weaverstreet.net/All/Hail/Ginger, the value of $pepper->{hostname}
will be 'pepper.weaverstreet.net'; for http://pepper.weaverstreet.net:5000/All/Hail/Ginger,
$pepper->{hostname} will be 'pepper.weaverstreet.net:5000'.

## $pepper->{uri}	

This will contain the endpoint URI. If the URL being accessed is
https://pepper.weaverstreet.net/All/Hail/Ginger, the value of $pepper->{uri}
will be '/All/Hail/Ginger'.

## Accessing the Plack Request / Response objects.

The plain request and response Plack objects will be available at $pepper->{plack\_handler}->{request}
and $pepper->{plack\_handler}->{response} respectively.  Please only use these if you absolutely must,
and please see [Plack::Request](https://metacpan.org/pod/Plack%3A%3ARequest) and [Plack::Response](https://metacpan.org/pod/Plack%3A%3AResponse) before working with these.

# RESPONSE / LOGGING / TEMPLATE METHODS PROVIDED BY THE $pepper OBJECT

## template\_process

This is an easy interface to the excellent Template Toolkit.  This is great for generating
HTML or any kind of processed text files.  Create your Template Toolkit templates 
under /opt/pepper/template and please see [Template](https://metacpan.org/pod/Template) and [http://www.template-toolkit.org](http://www.template-toolkit.org)
The basic idea is to process a template with the values in a data structure to create the 
appropriate text output.  

To process a template and have your endpoint handler return the results:

        return $pepper->template_process({
                'template_file' => 'some_template.tt', 
                'template_vars' => $some_data_structure,
        });

You can add subdirectories under /opt/pepper/template and refer to the files as
'subdirectory\_name/template\_filename.tt'.

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
        

## logger

This adds entries to the files under /opt/pepper/log and is useful to log actions or
debugging messages.  You can send a plain text string or a reference to a data structure.

        $pepper->logger('A nice log message','example-log');

        That will add a timestamped entry to a file named for example-log-YYYY-MM-DD.log. If you
        leave off the second argument, the message is appended to today's errors-YYYY-MM-DD.log.

        $pepper->logger($hash_reference,'example-log');

        This will save the output of Data::Dumper's Dumper($hash_reference) to today's
        example-log-YYYY-MM-DD.log.

## send\_response

This method will send data to the client.  It is usually unnecessary, as you will simply
return data structures or text.  This may be useful in two situations:

        # To bail-out in case of an error:
        $pepper->send_response('Error, everything just blew up.',1);

        # To send out a binary file:
        $pepper->send_response($file_contents,'the_filename.ext',2,'mime/type');
        $pepper->send_response($png_file_contents,'lovely_ginger.png',2,'image/png');
        

## set\_cookie

From a web endpoint handler, you may set a cookie like this:

        $pepper->set_cookie({
                'name' => 'Cookie_name', # could be any name
                'value' => 'Cookie_value', # any text you wish
                'days_to_live' => integer over 0, # optional, default is 10
        }); 

# DATABASE METHODS PROVIDED BY THE $pepper OBJECT

## change\_database
=head2 comma\_list\_select
=head2 commit
=head2 do\_sql
=head2 list\_select
=head2 quick\_select
=head2 sql\_hash

# JSON METHODS PROVIDED BY THE $pepper OBJECT

## json\_from\_perl
=head2 json\_to\_perl
=head2 read\_json\_file
=head2 write\_json\_file

# DATE / UTILITY METHODS PROVIDED BY THE $pepper OBJECT

## filer

This is a basic interface for reading, writing, and appending files using the Path::Tiny library.

To load the contents of a file into a scalar (aka 'slurp'):

        $scalar_name = $pepper->filer('/path/to/file.ext');
        

To save the contents of a scalar into a file:

        $pepper->filer('/path/to/new_file.ext','write',$scalar_of_content);
        # maybe you have an array
        $pepper->filer('/path/to/new_file.ext','write', join("\n",@array_of_lines)  );

To append a file with additional content

        $pepper->filer('/path/to/new_file.ext','append',$scalar_of_content);

## random\_string

Handy method to generate a random string of numbers and uppercase letters. 

To create a 10-character random string:

        $random_string = $pepper->random_string();
        

To specify that it be 25 characters long;

        $longer_random_string = $pepper->random_string(25);

## time\_to\_date

Useful method for converting UNIX epochs or YYYY-MM-DD dates to more human-friendly dates.
This takes three arguments:

- A timestamp, preferably an epoch like 1018569600, but can be a date like 2002-04-12 or 'April 12, 2002'.
The epochs are best for functions that will include the time.
- An action / command, such as 'to\_year' or 'to\_date\_human\_time'. See below for full list.
- Optionally, an Olson DB time zone name, such as 'America/New\_York'.  The default is UTC / GMT.
You can set your own default via the PERL\_DATETIME\_DEFAULT\_TZ environmental variable or placing 
in $pepper->{utils}->{time\_zone\_name}.  Most of examples below take the default time zone, most 
likely UTC.  

To get the epoch of 00:00:00 on a particular date:

        $epoch_value = $pepper->time_to_date($date, 'to_unix_start');
        # $epoch_value is now something like 1018569600

To convert an epoch into a YYYY-MM-DD date:

        $date = $pepper->time_to_date($date, 'to_date_db');
        # $date is now something like '2002-04-12'
        

To convert a date or epoch to a more friendly format, such as April 12, 2002:

        $peppers_birthday = $pepper->time_to_date('2002-04-12', 'to_date_human');
        $peppers_birthday = $pepper->time_to_date(1018569600, 'to_date_human');
        # for either case, $peppers_birthday is now 'April 12, 2002'
        

You can always use time() to get values for the current moment:

        $todays_date_human = $pepper->time_to_date(time(), 'to_date_human');
        # $todays_date_human is now 'September 1'

'to\_date\_human' leaves off the year if the moment is within the last six months.
This can be useful for displaying a history log.

Use 'to\_date\_human\_full' to force the year to be included:

        $todays_date_human = $pepper->time_to_date(time(), 'to_date_human_full');
        # $todays_date_human is now 'September 1, 2020'
        

Use 'to\_date\_human\_abbrev' to abbreviate the month name:

        $nice_date_string = $pepper->time_to_date('2020-09-01', 'to_date_human_abbrev');
        # $nice_date_string is now 'Sept. 1, 2020'

To include the weekday with 'to\_date\_human\_abbrev' output:

        $nicer_date_string = $pepper->time_to_date('2020-09-01', 'to_date_human_dayname');
        # $nicer_date_string is now 'Friday, Apr 12, 2002'

        } elsif (!$task || $task eq "to_date_human_dayname") { # unix timestamp to human date (DayOfWeekName, Mon DD, YYYY)
        } elsif ($task eq "to_year") { # just want year
        } elsif ($task eq "to_month" || $task eq "to_month_name") { # unix timestamp to month name (Month YYYY)
        } elsif ($task eq "to_month_abbrev") { # unix timestamp to month abreviation (MonYY, i.e. Sep15)
        } elsif ($task eq "to_date_human_time") { # unix timestamp to human date with time (Mon DD, YYYY<br>HH:MM:SS XM)
        } elsif ($task eq "to_just_human_time") { # unix timestamp to humantime (HH:MM:SS XM)
        } elsif ($task eq "to_just_military_time") { # unix timestamp to military time
        } elsif ($task eq "to_datetime_iso") { # ISO-formatted timestamp, i.e. 2016-09-04T16:12:00+00:00
        } elsif ($task eq "to_month_abbrev") { # epoch to abbreviation, like 'MonYY'
        } elsif ($task eq "to_day_of_week") { # epoch to day of the week, like 'Saturday'
        } elsif ($task eq "to_day_of_week_numeric") { # 0..6 day of the week

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

# USING WITH APACHE AND SYSTEMD

# REGARDING AUTHENTICATION & SECURITY

# ABOUT THE NAME

# SEE ALSO

http://www.template-toolkit.org/

# AUTHOR

Eric Chernoff - ericschernoff at gmail.com 

# POD ERRORS

Hey! **The above document had some coding errors, which are explained below:**

- Around line 354:

    You forgot a '=back' before '=head2'
