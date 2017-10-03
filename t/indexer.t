#!perl

use strict;
use warnings;

use Test::More;

BEGIN {
    eval {require Search::Indexer};
    plan skip_all => 'Search::Indexer does not seem to be installed'
      if $@;
}

plan tests => 2;

use_ok( 'Pod::POM::Web::Indexer' );

subtest "uri escape" => sub {
    plan tests => 3;
    is(uri_escape(), undef, "An escaped, undefined URI stays undefined");

    my $plain_uri = "http://example.com";
    is(uri_escape($plain_uri), $plain_uri, "Plain URI remains unchanged");

    my $unescaped_uri = "http://example.com/^;/?:\@,Az0-_.!~*'()";
    my $escaped_uri = "http://example.com/%5E;/?:\@,Az0-_.!~*'()";
    is(uri_escape($unescaped_uri), $escaped_uri, "Non-standard characters escaped in URI");
};

sub uri_escape {
    my $uri = shift;
    return Pod::POM::Web::Indexer::uri_escape($uri);
}

# TODO ... more than just a compile test
