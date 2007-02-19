#!perl -T

use Test::More tests => 1;

BEGIN {
	use_ok( 'Pod::POM::Web' );
}

diag( "Testing Pod::POM::Web $Pod::POM::Web::VERSION, Perl $], $^X" );
