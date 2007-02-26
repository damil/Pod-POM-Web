#!perl

use Test::More tests => 11;
use HTTP::Request;
use HTTP::Response;

BEGIN {
	use_ok( 'Pod::POM::Web' );
}

diag( "Testing Pod::POM::Web $Pod::POM::Web::VERSION, Perl $], $^X" );


response_like("", qr/location=/, "redirect1");
response_like("/", qr/location=/, "redirect2");

response_like("/index", qr/frameset/, "index");

response_like("/toc", qr/Modules/, "toc");
response_like("/toc/HTTP", qr/Request.*?Response/, "toc/HTTP");

response_like("/lib/GvaScript.css", qr/AC_dropdown/, "lib");

response_like("/search?source=perlfunc&search=shift", qr/array/, "perlfunc");
response_like("/search?source=perlfaq&search=array",  qr/array/, "perlfaq");

response_like("/source/HTTP/Request",  qr/HTTP::Request/, "source");

my $regex = qr/HTTP::Request\s*<small>\s*$HTTP::Request::VERSION/;
response_like("/HTTP/Request",  $regex, "serve_pod");


sub response_like {
  my ($url, $like, $msg) = @_;
   my $response = get_response($url);
  like($response->content, $like, $msg);
}


sub get_response {
  my ($url) = @_;
  my $request  = HTTP::Request->new(GET => $url);
  my $response = HTTP::Response->new;
  Pod::POM::Web->handler($request, $response);
  return $response;
}
