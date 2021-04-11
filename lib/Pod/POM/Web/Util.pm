#======================================================================
package Pod::POM::Web::Util; # see doc at end of file
#======================================================================
use strict;
use warnings;
use Encode            qw/decode_utf8 FB_CROAK LEAVE_SRC/;
use Path::Tiny        qw/path/;
use Module::Metadata;
use Exporter          qw/import/;

our @EXPORT_OK = qw/slurp_native_or_utf8 parse_version extract_POM_items/;

sub slurp_native_or_utf8 {
  my ($file) = @_;

  my $content     = path($file)->slurp_raw;
  my $utf_decoded = $content =~ /(use utf8|=encoding utf-?8)/i && eval {decode_utf8($content, FB_CROAK | LEAVE_SRC)};

  return $utf_decoded || $content;
}


sub parse_version {
  my ($file_name) = @_;

  my $mm = Module::Metadata->new_from_file($file_name)
    or die "couldn't create Module::Metadata";

  return $mm->version;
}



sub extract_POM_items { # recursively grab all nodes of type 'item'
  my $node = shift;

  for ($node->type) {
    /^item/            and return ($node);
    /^(pod|head|over)/ and return map {extract_POM_items($_)} $node->content;
  }
  return ();
}


1;

__END__

=encoding ISO8859-1

=head1 NAME

Pod::POM::Web::Util - utility functions for Pod::POM::Web

=head1 DESCRIPTION

Utility functions (not methods) for L<Pod::POM::Web>.

=head1 METHODS

=head2 slurp_native_or_utf8

Read a file containing Perl source, try to guess if this is an utf8 source,
return the content as a decoded string.

=head2 parse_version

Return the module version, using L<Module::Metadata>.

=head2 extract_POM_items

Recursively walk down a POM tree and gather all "item" nodes.

