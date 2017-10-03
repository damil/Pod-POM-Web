#!perl

use strict;
use warnings;

use Test::More;

BEGIN {
    eval {require Search::Indexer};
    plan skip_all => 'Search::Indexer does not seem to be installed'
      if $@;
}

plan tests => 1;

use_ok( 'Pod::POM::Web::Indexer' );

# TODO ... more than just a compile test
