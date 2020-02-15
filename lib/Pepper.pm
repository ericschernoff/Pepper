package Pepper;

use Pepper::DB;
use Pepper::CGIHandler;

sub new {

}

# we need a default method in case our clients call the wrong thing
our $AUTOLOAD;
sub AUTOLOAD {
	my $self = shift;
	# figure out the method they tried to call
	my $called_method =  $AUTOLOAD =~ s/.*:://r;
	
	# database function?
	if ($self->{db}->can($called_method)) {

		return $self->{belt}->$called_method(@_);
		
	# cgi handler function?
	} elsif ($self->{cgi_handler}->can($called_method)) {
		return $self->{cgi_handler}->$called_method(@_);
	
	} else { # hard fail with an error message
		my $message = "ERROR: No '$called_method' method defined for ".$self->{config}{name}.' objects.';
		$self->{cgi_handler}->send_response( $message, 1 );

	}
	
}

# empty destroy for now
sub DESTROY {
	my $self = shift;
}

1;
