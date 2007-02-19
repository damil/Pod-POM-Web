use strict;
use warnings;
use Module::Build;

my $builder = Module::Build->new(
    module_name         => 'Pod::POM::Web',
    license             => 'perl',
    dist_author         => 'Laurent Dami <laurent.dami@justice.ge.ch>',
    dist_version_from   => 'lib/Pod/POM/Web.pm',
    build_requires => {
        'Test::More' => 0,
    },
    add_to_cleanup      => [ 'Pod-POM-Web-*' ],
);

$builder->create_build_script();
