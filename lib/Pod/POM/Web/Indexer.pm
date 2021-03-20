#======================================================================
package Pod::POM::Web::Indexer;
#======================================================================

=begin TODO

  - use Getopt::Long -- @ARGV
  - 

=end TODO

=cut


use strict;
use warnings;
use 5.008;

use Pod::POM;
use List::Util       qw/min max/;
use Search::Indexer 0.75;
use BerkeleyDB;
use Path::Tiny       qw/path/;
use Params::Validate qw/validate_with SCALAR ARRAYREF/;


our $VERSION = 1.23;

#----------------------------------------------------------------------
# Initializations
#----------------------------------------------------------------------



my $id_regex = qr/(?![0-9])       # don't start with a digit
                  \w\w+           # start with 2 or more word chars ..
                  (?:::\w+)*      # .. and  possibly ::some::more::components
                 /x;

my $wregex   = qr/(?:                  # either a Perl variable:
                    (?:\$\#?|\@|\%)    #   initial sigil
                    (?:                #     followed by
                       $id_regex       #       an id
                       |               #     or
                       \^\w            #       builtin var with '^' prefix
                       |               #     or
                       (?:[\#\$](?!\w))#       just '$$' or '$#'
                       |               #     or
                       [^{\w\s\$]      #       builtin vars with 1 special char
                     )
                     |                 # or
                     $id_regex         # a plain word or module name
                 )/x;



#----------------------------------------------------------------------
# CONSTRUCTOR
#----------------------------------------------------------------------

sub new {
  my $class = shift;

  # attributes received from the client
  my $self = validate_with(
    params      => \@_,
    spec        => {index_dir    => {type => SCALAR},
                    module_dirs  => {type => ARRAYREF},
                  },
    allow_extra => 0,
   );

  # attempt to tie to the docs database
  my $bdb_file = "$self->{index_dir}/docs.bdb";
  tie %{$self->{docs}}, 'BerkeleyDB::Hash', -Filename => $bdb_file, -Flags => DB_RDONLY;

  return bless $self, $class;
}





#----------------------------------------------------------------------
# RETRIEVING
#----------------------------------------------------------------------

sub has_index {
  my ($self) = @_;
  return scalar keys %{$self->{docs}};
}



sub search {
  my ($self, $search_string) = @_;

  # force Some::Module::Name into "Some::Module::Name" to prevent
  # interpretation of ':' as a field name by Query::Parser
  $search_string =~ s/(^|\s)([\w]+(?:::\w+)+)(\s|$)/$1"$2"$3/g;

  my $indexer = Search::Indexer->new(dir       => $self->{index_dir},
                                     wregex    => $wregex,
                                     preMatch  => '[[',
                                     postMatch => ']]');
  my $result  = $indexer->search($search_string, 'implicit_plus');

  return $result;
}


sub excerpts {
  my ($self, $buf, $regex) = @_;

  my $indexer = Search::Indexer->new(dir       => $self->{index_dir},
                                     wregex    => $wregex,
                                     preMatch  => '[[',
                                     postMatch => ']]');

  return $indexer->excerpts($buf, $regex);
}



sub modules_matching_prefix {
  my ($self, $search_string) = @_;

  length($search_string) >= 2 or die "module_list: arg too short";
  $search_string =~ s[::][/]g;
  my $regex = qr/^\d+\t(\Q$search_string\E[^\t]*)/i;

  my @modules;
  foreach my $val (values %{$self->{docs}}) {
    if ($val =~ $regex) {
      (my $module = $1) =~ s[/][::]g;
      push @modules, $module;
    }
  }

  return @modules;
}





sub get_module_description {
  my ($self, $path) = @_;
  if (!$self->{_path_to_descr}) {
    $self->{_path_to_descr} = {
      map {(split /\t/, $_)[1,2]} values %{$self->{docs}}
     };
  }
  my $description = $self->{_path_to_descr}->{$path} or return;
  $description =~ s/^.*?-\s*//;
  return $description;
}


#----------------------------------------------------------------------
# INDEXING
#----------------------------------------------------------------------





sub import { # export the "index" function if called from command-line
  my $class = shift;
  my ($package, $filename) = caller;

  no strict 'refs';
  *{'main::index'} = sub {$class->index(@_)}
    if $package eq 'main' and $filename eq '-e';
}

sub index {
  my ($self, %options) = @_;


  my $session = Pod::POM::Web::Indexer::IndexingSession->new(%options);
  $session->start;
}

#======================================================================
package # hide from PAUSE
  Pod::POM::Web::Indexer::IndexingSession;
#======================================================================
use strict;
use warnings;
use Params::Validate qw/validate_with SCALAR BOOLEAN ARRAYREF/;
use Time::HiRes      qw/time/;
use Path::Tiny       qw/path/;
use List::Util       qw/max/;
use BerkeleyDB       qw/DB_CREATE/;
use List::MoreUtils  qw/part/;

my @stopwords = (
  'a' .. 'z', '_', '0' .. '9',
  qw/__data__ __end__ $class $self
     above after all also always an and any are as at
     be because been before being both but by
     can cannot could
     die do don done
     defined do does doesn
     each else elsif eq
     for from
     ge gt
     has have how
     if in into is isn it item its
     keys
     last le lt
     many may me method might must my
     ne new next no nor not
     of on only or other our
     package perl pl pm pod push
     qq qr qw
     ref return
     see set shift should since so some something sub such
     text than that the their them then these they this those to tr
     undef unless until up us use used uses using
     values
     was we what when which while will with would
     you your/
);


my $ignore_dirs = qr[
      auto | unicore | DateTime/TimeZone | DateTime/Locale    ]x;

my $ignore_headings = qr[
      SYNOPSIS | DESCRIPTION | METHODS   | FUNCTIONS |
      BUGS     | AUTHOR      | SEE\ ALSO | COPYRIGHT | LICENSE ]x;

sub new {
  my $class = shift;

  # attributes passed to the constructor
  my $self = validate_with(
    params      => \@_,
    spec        => {index_dir    => {type => SCALAR},
                    module_dirs  => {type => ARRAYREF},
                    from_scratch => {type => BOOLEAN, optional => 1},
                    positions    => {type => BOOLEAN, optional => 1},
                    max_size     => {type => SCALAR,  default  => 300 << 10}, # 300K
                  },
    allow_extra => 0,
   );

  # with option -from_scratch, throw away old index
  if ($self->{from_scratch}) {
    unlink $_ foreach glob("$self->{index_dir}/*.bdb");
  }


  # initialization of other attributes
  $self->{seen_path}      = {},
  $self->{max_doc_id}     = 0;
  $self->{previous_index} = {};
  $self->{search_indexer}
    = Search::Indexer->new(dir       => $self->{index_dir},
                           writeMode => 1,
                           positions => $self->{positions},
                           wregex    => $wregex,
                           stopwords => \@stopwords);


  # create or reuse the documents database
  my $bdb_file = "$self->{index_dir}/docs.bdb";
  tie %{$self->{docs}}, 'BerkeleyDB::Hash', -Filename => $bdb_file, -Flags => DB_CREATE
    or die "open $bdb_file : $^E $BerkeleyDB::Error";

  # in case of incremental indexing : build in-memory reverse index of
  # info already contained in %{$self->{docs}}
  while (my ($id, $doc_descr) = each %{$self->{docs}}) {
    $self->{max_doc_id} = max($id, $self->{max_doc_id});
    my ($mtime, $path, $description) = split /\t/, $doc_descr;
    $self->{previous_index}{$path}
      = {id => $id, mtime => $mtime, description => $description};
  }

  bless $self, $class;
}




sub start {
  my ($self) = @_;

  # turn on autoflush on STDOUT so that messages can be piped to the web app
  use IO::Handle;
  my $previous_autoflush_value = STDOUT->autoflush(1);

  # main indexing loop
  my $t0 = time;
  print "FULLTEXT INDEX IN PROGRESS .. wait for message 'DONE' at the end of this page\n\n";
  $self->index_dir($_) foreach @{$self->{module_dirs}};
  my $t1 = time;
  printf "\n=============\nDONE. Total indexing time : %0.3f s.\n", $t1-$t0;

  # back to previous autoflush status
  STDOUT->autoflush(0) if !$previous_autoflush_value;
}


sub index_dir {
  my ($self, $rootdir, $path) = @_;
  return if $path && $path =~ /$ignore_dirs/;

  my $dir = $rootdir;
  if ($path) {
    $dir .= "/$path";
    return print "SKIP DIR $dir (already in \@INC)\n"
      if grep {m[^\Q$dir\E]} @{$self->{module_dirs}};
  }

  chdir $dir or return print "SKIP DIR $dir (chdir $dir: $!)\n";

  print "DIR $dir\n";
  opendir my $dh, "." or die $^E;
  my ($dirs, $files) = part { -d $_ ? 0 : 1} grep {!/^\./} readdir $dh;
  $dirs ||= [], $files ||= [];
  closedir $dh;

  my %extensions;
  foreach my $file (sort @$files) {
    next unless $file =~ s/\.(pm|pod)$//;
    $extensions{$file}{$1} = 1;
  }

  foreach my $base (keys %extensions) {
    $self->index_file($path, $base, $extensions{$base});
  }

  my @subpaths = map {$path ? "$path/$_" : $_} @$dirs;
  $self->index_dir($rootdir, $_) foreach @subpaths;
}


sub index_file {
  my ($self, $path, $file, $has_ext) = @_;

  my $fullpath = $path ? "$path/$file" : $file;
  return print "SKIP $fullpath (shadowing)\n"
    if $self->{seen_path}{$fullpath};

  $self->{seen_path}{$fullpath} = 1;
  my $max_mtime = 0;
  my ($size, $mtime, @filenames);
 EXT:
  foreach my $ext (qw/pm pod/) {
    next EXT unless $has_ext->{$ext};
    my $filename = "$file.$ext";
    ($size, $mtime) = (stat $filename)[7, 9] or die "stat $filename: $!";
    $size < $self->{max_size} or
      print "$filename too big ($size bytes), skipped " and next EXT;
    $mtime = max($max_mtime, $mtime);
    push @filenames, $filename;
  }


  my $prev_mtime = $self->{previous_index}{$fullpath}{mtime};
  return print "SKIP $fullpath (index up to date)\n" if $prev_mtime && $mtime <= $prev_mtime;

  if (@filenames) {
    my $old_doc_id = $self->{previous_index}{$fullpath}{id};
    my $doc_id     = $old_doc_id || ++$self->{max_doc_id};

    print "INDEXING $fullpath (id $doc_id) ... ";

    my $t0 = time;
    my $buf = join "\n", map {path($_)->slurp} @filenames;
    my ($description) = ($buf =~ /^=head1\s*NAME\s*(.*)$/m);
    $description ||= '';
    $description =~ s/\t/ /g;
    $buf =~ s/^=head1\s+($ignore_headings).*$//m; # remove full line of those
    $buf =~ s/^=(head\d|item)//mg; # just remove command of =head* or =item
    $buf =~ s/^=\w.*//mg;          # remove full line of all other commands

    if ($old_doc_id) {
      # Here we should remove the old document from the index. But
      # we no longer have the document source! So we cheat with the current
      # doc buffer, hoping that most words are similar. This step sounds
      # ridiculous but is necessary to avoid having the same
      # doc listed twice in inverted lists.
      $self->{search_indexer}->remove($old_doc_id, $buf);
    }

    $self->{search_indexer}->add($doc_id, $buf);
    my $interval = time - $t0;
    printf "%0.3f s.", $interval;

    $self->{docs}{$doc_id} = "$mtime\t$fullpath\t$description";
  }

  print "\n";
}


1;

__END__

=head1 NAME

Pod::POM::Web::Indexer - full-text search for Pod::POM::Web

=head1 SYNOPSIS

  perl -MPod::POM::Web::Indexer -e index

=head1 DESCRIPTION

Adds full-text search capabilities to the
L<Pod::POM::Web|Pod::POM::Web> application.
This requires L<Search::Indexer|Search::Indexer> to be installed.

Queries may include plain terms, "exact phrases",
'+' or '-' prefixes, Boolean operators and parentheses.
See L<Search::QueryParser|Search::QueryParser> for details.


=head1 METHODS

=head2 index

    Pod::POM::Web::Indexer->new->index(%options)

Walks through directories in C<@INC> and indexes
all C<*.pm> and C<*.pod> files, skipping shadowed files
(files for which a similar loading path was already
found in previous C<@INC> directories), and skipping
files that are too big.

Default indexing is incremental : files whose modification
time has not changed since the last indexing operation will
not be indexed again.

Options can be

=over

=item -max_size

Size limit (in bytes) above which files will not be indexed.
The default value is 300K.
Files of size above this limit are usually not worth
indexing because they only contain big configuration tables
(like for example C<Module::CoreList> or C<Unicode::Charname>).

=item -from_scratch

If true, the previous index is deleted, so all files will be freshly
indexed. If false (the default), indexation is incremental, i.e. files
whose modification time has not changed will not be re-indexed.

=item -positions

If true, the indexer will also store word positions in documents, so
that it can later answer to "exact phrase" queries.

So if C<-positions> are on, a search for C<"more than one way"> will
only return documents which contain that exact sequence of contiguous
words; whereas if C<-positions> are off, the query is equivalent to
C<more AND than AND one AND way>, i.e. it returns all documents which
contain these words anywhere and in any order.

The option is off by default, because it requires much more disk
space, and does not seem to be very relevant for searching
Perl documentation.

=back

The C<index> function is exported into the C<main::> namespace if perl
is called with the C<-e> flag, so that you can write

  perl -MPod::POM::Web::Indexer -e index


=head1 PERFORMANCES

On my machine, indexing a module takes an average of 0.2 seconds,
except for some long and complex sources (this is why sources
above 300K are ignored by default, see options above).
Here are the worst figures (in seconds) :

  Date/Manip            39.655
  DBI                   30.73
  Pod/perlfunc          29.502
  Module/CoreList       27.287
  CGI                   16.922
  Config                13.445
  CPAN                  12.598
  Pod/perlapi           10.906
  CGI/FormBuilder        8.592
  Win32/TieRegistry      7.338
  Spreadsheet/WriteExcel 7.132
  Pod/perldiag           5.771
  Parse/RecDescent       5.405
  Bit/Vector             4.768

The index will be stored in an F<index> subdirectory
under the module installation directory.
The total index size should be around 10MB if C<-positions> are off,
and between 30MB and 50MB if C<-positions> are on, depending on
how many modules are installed.


=head1 TODO

 - highlights in shown documents
 - paging

=cut

