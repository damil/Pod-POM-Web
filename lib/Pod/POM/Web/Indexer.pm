package Pod::POM::Web::Indexer;

use strict;
use warnings;
no warnings 'uninitialized';

use Pod::POM;
use List::Util      qw/max/;
use List::MoreUtils qw/part/;
use Time::HiRes     qw/time/;
use Search::Indexer 0.72;
use BerkeleyDB;

use base 'Pod::POM::Web';


my $ignore_dirs = qr[
      auto | unicore | DateTime/TimeZone | DateTime/Locale    ]x;

my $ignore_headings = qr[
      SYNOPSIS | DESCRIPTION | METHODS   | FUNCTIONS |
      BUGS     | AUTHOR      | SEE\ ALSO | COPYRIGHT | LICENSE ]x;

(my $index_dir = __FILE__) =~ s[Indexer\.pm$][index];

my %seen_path;

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


my @stopwords = (
  'a' .. 'z', '_', '0' .. '9',

  qw/__data__ __end__ $class $self
     above after all also always an and any are as at
     be because been before being both but by
     can cannot could
     die do don done
     defined do does doesn
     else elsif
     each
     eq
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

my $stopwords_regex = join "|", map quotemeta, @stopwords;
   $stopwords_regex = qr/^(?:$stopwords_regex)$/;


#----------------------------------------------------------------------
# RETRIEVING
#----------------------------------------------------------------------


sub fulltext {
  my ($self, $search_string) = @_;

  my $indexer = eval {
    new Search::Indexer(dir       => $index_dir,
                        wregex    => $wregex,
                        preMatch  => '[[',
                        postMatch => ']]');
  } or die <<__EOHTML__;
No fulltext index found. 
Please ask your system administrator to run the 
command 

<pre>
  perl [-I some/special/dirs] -MPod::POM::Web::Indexer -e "Pod::POM::Web::Indexer->new->index_all"
</pre>

Indexing may take about half an hour and and will use about
30-50 MB on your hard disk.
__EOHTML__

  # force Some::Module::Name into "Some::Module::Name" to prevent 
  # interpretation of ':' as a field name by Query::Parser
  $search_string =~ s/(^|\s)([\w]+(?:::\w+)+)(\s|$)/$1"$2"$3/g;

  my $result = $indexer->search($search_string);

  my $lib = "$self->{root_url}/lib";
  my $html = <<__EOHTML__;
<html>
<head>
  <link href="$lib/GvaScript.css" rel="stylesheet" type="text/css">
  <link href="$lib/PodPomWeb.css" rel="stylesheet" type="text/css">
  <style>
    .src {font-size:70%; float: right}
    .sep {font-size:110%; font-weight: bolder; color: magenta;
          padding-left: 8px; padding-right: 8px}
    .hl  {background-color: lightpink}
  </style>
</head>
<body>
<h1>Search results</h1>
__EOHTML__

  my $truncated = "";

  if (!$result) {
    $self->print("no results");
  }
  else {
    my $killedWords = join ", ", @{$result->{killedWords}};
    $killedWords &&= " (ignoring words : $killedWords)";
    my $regex = $result->{regex};

    my $scores = $result->{scores};

    my @doc_ids = sort {$scores->{$b} <=> $scores->{$a}} keys %$scores;
    my $n_docs = @doc_ids;

    $html .= "<p>searched for '$search_string'$killedWords,"
          .  " $n_docs results found</p>";

    tie %{$self->{_docs}}, 'BerkeleyDB::Hash', 
      -Filename => "$index_dir/docs.bdb", 
      -Flags    => DB_RDONLY
          or die "open $index_dir/docs.bdb : $^E $BerkeleyDB::Error";

    $truncated = <<__EOHTML__ if splice @doc_ids, 50;
<b>Too many results, please try a more specific search</b>
__EOHTML__

    foreach my $id (@doc_ids) {
      my ($mtime, $path) = split "\t", $self->{_docs}{$id}, 2;
      my $score     = $scores->{$id};
      my @filenames = $self->find_source($path);
      my $buf = join "\n", map {$self->slurp_file($_)} @filenames;
      my ($description) = ($buf =~ /^=head1\s*NAME\s*(.*)$/m);

      my $excerpts = $indexer->excerpts($buf, $regex);
      foreach (@$excerpts) {
        s/&/&amp;/g,  s/</&lt;/g, s/>/&gt;/g;          # replace entities
        s/\[\[/<span class='hl'>/g, s/\]\]/<\/span>/g; # highlight
      }
      $excerpts = join "<span class='sep'>/</span>", @$excerpts;
      $html .= <<__EOHTML__;
<p>
<a href="$self->{root_url}/source/$path" class="src">source</a>
<a href="$self->{root_url}/$path">$path</a>
(<small>$score</small>) <em>$description</em>
<br>
<small>$excerpts</small>
</p>
__EOHTML__
    }
  }

  $html .= "$truncated</body></html>\n";
  return $self->send_html($html);
}

sub modlist { # called by Ajax
  my ($self, $search_string) = @_;

  tie my %docs, 'BerkeleyDB::Hash', 
    -Filename => "$index_dir/docs.bdb", 
      -Flags    => DB_RDONLY
        or die "open $index_dir/docs.bdb : $^E $BerkeleyDB::Error";

  length($search_string) >= 2 or die "module_list: arg too short";
  my $regex = qr/^\d+\t\Q$search_string\E/i;
  my @names = grep {/$regex/} values  %docs;
  s[^\d+\t][], s[/][::]g foreach @names;
  my $json_names = "[" . join(",", map {qq{"$_"}} sort @names) . "]";
  return $self->send_content({content   => $json_names,
                              mime_type => 'application/x-json'});
}


#----------------------------------------------------------------------
# INDEXING
#----------------------------------------------------------------------


sub index_all {
  my ($self) = @_;

  -d $index_dir or mkdir $index_dir or die "mkdir $index_dir: $!";

  # create temp dir for the new index
  my $new_index_dir = "$index_dir/_new_index";
  -d $new_index_dir or mkdir $new_index_dir or die "mkdir $new_index_dir: $!";
  foreach my $file (glob("$new_index_dir/*.bdb")) {
    print STDERR "UNLINK $file\n" and unlink $file or die $!;
  }

  # do the work 
  $self->{_last_doc_id} = 0;

  tie %{$self->{_docs}}, 'BerkeleyDB::Hash', 
      -Filename => "$new_index_dir/docs.bdb", 
      -Flags    => DB_CREATE
	or die "open $new_index_dir/docs.bdb : $^E $BerkeleyDB::Error";


  $self->{_indexer} = new Search::Indexer(dir       => $new_index_dir,
                                          writeMode => 1,
                                          wregex    => $wregex,
                                          stopwords => \@stopwords);
  $self->index_dir($_) foreach @Pod::POM::Web::search_dirs; # TODO : method call
  undef $self->{_indexer};

  # move created index to production dir (might not work if files are
  # currently opened through modperl !)
    chdir $new_index_dir or die "chdir $new_index_dir: $!";
  foreach my $file (glob("*.bdb")) {
    rename $file, "$index_dir/$file" or die "rename $file $index_dir/$file: $!";
  }
}



sub index_dir {
  my ($self, $rootdir, $path) = @_;
  return if $path =~ /$ignore_dirs/;

  my $dir = $path ? "$rootdir/$path" : $rootdir;
  print STDERR "DIR $dir\n";
  chdir $dir or return print STDERR "SKIP DIR (chdir $dir: $!)\n";
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
  return print STDERR "SKIP $fullpath (shadowing)\n"
    if $seen_path{$fullpath};
  $seen_path{$fullpath} 
    = my $doc_id = ++$self->{_last_doc_id};

  print STDERR "$doc_id INDEXING $fullpath ... ";
  my $t0 = time;

  my $buf = ""; # will contain .pm file, or .pod, or both concatenated
  my $max_mtime = 0;
  foreach my $ext (qw/pm pod/) { 
    next unless $has_ext->{$ext};
    my ($text, $mtime) = $self->slurp_file("$file.$ext");
    $mtime = max($max_mtime, $mtime);
    $buf .= $text . "\n";
  }

  $buf =~ s/^=head1\s+($ignore_headings).*$//m; # remove full line of those
  $buf =~ s/^=(head\d|item)//mg; # just remove command of =head* or =item
  $buf =~ s/^=\w.*//mg;          # remove full line of all other commands 

  $self->{_indexer}->add($doc_id, $buf);

  my $interval = time - $t0;
  printf STDERR "%0.3f s.\n", $interval;

  $self->{_docs}{$doc_id} = "$max_mtime\t$fullpath";
}






1;

__END__

=head1 NAME

Pod::POM::Web::Indexer - fulltext search for Pod::POM::Web

=head1 SYNOPSIS

  perl [-I some/special/dirs] -MPod::POM::Web::Indexer \
       -e "Pod::POM::Web::Indexer->new->index_all"

=head1 DESCRIPTION

Adds fulltext search capabilities to the Pod::POM::Web application.

=head2 Performances

On my machine, indexing a module takes an average of 0.2 seconds, 
except for some long and complex sources. Here are the worst figures
(in seconds) :

  Perl/Tidy            291.969
  Unicode/CharName     184.442
  Pod/perltoc           40.071
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

The total index size should be between 30MB and 50MB, depending on
how many modules are installed.


=head1 TODO

 - incremental indexing
 - add option in Search::Indexer to ignore word positions index; not very
   relevant here, and would save a lot of disk space
 - searching some::module does not work
 - highlights in shown documents
 - paging


=cut

