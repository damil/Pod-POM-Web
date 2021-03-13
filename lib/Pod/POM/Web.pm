#======================================================================
package Pod::POM::Web; # see doc at end of file
#======================================================================
use strict;
use warnings;
use 5.008;
no warnings 'uninitialized';

use parent 'Plack::Component';              # web app based on Plack architecture
use Plack::Request;                         # Plack API for an HTTP request
use Plack::Response;                        # Plack API for an HTTP response
use Plack::Util;                            # encode_html()
use Pod::POM 0.25;                          # parsing Pod
use List::Util      qw/max/;                # maximum
use List::MoreUtils qw/uniq firstval any/;  # list utilities
use Module::CoreList;                       # asking if a module belongs to Perl core
use MIME::Types;                            # translate file extension into MIME type
use Alien::GvaScript 1.021000;              # javascript files
use Config;                                 # where are the perl script directories

use Module::Metadata 1.000033;              # get version number from module
use Encode          qw/decode encode_utf8/; # utf8 encoding
use Encode::Detect;                         # automatic encoding recognition
use Params::Validate qw/validate_with SCALAR ARRAYREF/; # check validity of parameters
use CPAN::Common::Index::Mux::Ordered;      # current CPAN version of a module


# other modules that may be required dynamically :
# Getopt::Long, PPI::HTML, ActiveState::Scineplex, Pod::POM::Web::Indexer, Plack::Runner


#----------------------------------------------------------------------
# GLOBAL VARIABLES
#---------------------------------------------------------------------

our $VERSION = '1.24';

# parameters for instantiating the module. They could also come from cmd-line options
my %params_for_new = (
  page_title  => {type => SCALAR  , optional => 1},
  script_name => {type => SCALAR  , optional => 1},
  module_dirs => {type => ARRAYREF, optional => 1},
  script_dirs => {type => ARRAYREF, optional => 1},
 );
my @params_for_getopt = (
  'page_title|title=s',
  'module_dirs|mdirs=s@{,}',
  'script_dirs|sdirs=s@{,}',
);


# directories for modules -- filter @INC (we don't want '.', nor server_root added by mod_perl)
my $server_root = eval {Apache2::ServerUtil::server_root()} || "";
our                # because accessed from Pod::POM::Web::Indexer
  @default_module_dirs = grep {!/^\./ && $_ ne $server_root} @INC;

# directories for executable perl scripts
my @default_script_dirs = grep {$_}
                          @Config{qw/sitescriptexp vendorscriptexp scriptdirexp/};

# some subdirs never contain Pod documentation
my @ignore_toc_dirs = qw/auto unicore/;


# syntax coloring (optional)
my $coloring_package
  = eval {require PPI::HTML}              ? "PPI"
  : eval {require ActiveState::Scineplex} ? "SCINEPLEX"
  : "";

# full-text indexing (optional)
my $no_indexer = eval {require Pod::POM::Web::Indexer} ? 0 : $@;

# A sequence of optional filters to apply to the source code before
# running it through Pod::POM. Source code is passed in $_[0] and
# should be modified in place.
my @podfilters = (

  # Pod::POM fails to parse correctly when there is an initial blank line
  sub { $_[0] =~ s/\A\s*// },

);


#----------------------------------------------------------------------
# CLASS METHODS
#----------------------------------------------------------------------

# export functions to be called from command-line option -e
sub import {
  my $class = shift;
  my ($package, $filename) = caller;
  no strict 'refs';

  # export "server" -- for "perl -MPod::POM::Web -e server"
  if ($package eq 'main' and $filename eq '-e') {
    *{'main::server'} = sub { $class->server };
  }

  # export "app" --- for "plackup -MPod::POM::Web -e app"
  elsif($package eq 'Plack::Runner') {
    *{'Plack::Runner::app'} = sub {$class->app};
  }
}


# launch the app via Plack::Runner when called from perl cmd-line
sub server {
  my $class = shift;

  require Plack::Runner;
  my $runner = Plack::Runner->new;
  $runner->parse_options(@ARGV);
  $runner->run($class->app);
}


# return an app suitable to run under Plack::Runner
sub app {
  my $class = shift;

  # get options from command-line
  require Getopt::Long;
  my $parser = Getopt::Long::Parser->new(config => [qw/pass_through/]);
  $parser->getoptions(\my %options, @params_for_getopt);

  # create a Pod::POM::Web instance and make it into a Plack app
  my $obj = $class->new(%options);
  return $obj->to_app;
}


# backcompat : a class method to be used as a CGI script or as a modperl handler
sub handler : method  {
  my ($class, $r) = @_;

  if (ref $r =~ /^Apache/) {
    require Plack::Handler::Apache2;
    Plack::Handler::Apache2->call_app($r, $class->app);
  }
  else {
    require Plack::Handler::CGI;
    Plack::Handler::CGI->new->run($class->app);
  }
}


# constructor
sub new {
  my $class = shift;

  # validate input parameters
  my $self = validate_with(
    params      => \@_,
    spec        => \%params_for_new,
    allow_extra => 0,
   );

  # default values
  $self->{page_title} ||= 'Perl documentation';
  push @{$self->{module_dirs}}, @default_module_dirs;
  push @{$self->{script_dirs}}, @default_script_dirs;

  # CPAN index
  my @cpan_indices = (MetaDB       => {});
  if (0 and
        my $local_minicpan = eval {require CPAN::Mini;
                                   my %conf = CPAN::Mini->read_config;
                                   $conf{local}}) {
    unshift @cpan_indices,
      LocalPackage => { source => "$local_minicpan/modules/02packages.details.txt.gz" };
  }
  $self->{cpan_index} = CPAN::Common::Index::Mux::Ordered->assemble(@cpan_indices);

  # create instance
  bless $self, $class;
}


#----------------------------------------------------------------------
# INSTANCE METHODS
#----------------------------------------------------------------------

# simple-minded accessors
sub module_dirs {@{shift->{module_dirs}}}
sub script_dirs {@{shift->{script_dirs}}}

# request dispatcher (see L<Plack::Component>)
sub call {
  my ($self, $env) = @_;

  # plack request object
  my $req = Plack::Request->new($env);

  # at first request, register the script name
  $self->{script_name} = $req->script_name if not exists $self->{script_name};

  # dispatching will be based on path_info
  my $path_info = $req->path_info;

  # security check : no outside directories
  $path_info =~ m[(\.\.|//|\\|:)] and die "illegal path: $path_info";

  # dispatch
  $path_info =~ s[^/][] or return $self->index_frameset($req);
  for ($path_info) {
    /^$/               and return $self->index_frameset($req);
    /^index$/          and return $self->index_frameset($req);
    /^toc$/            and return $self->main_toc($req);
    /^toc\/(.*)$/      and return $self->toc_for($1);   # Ajax calls
    /^script\/(.*)$/   and return $self->serve_script($1);
    /^search$/         and return $self->dispatch_search($req);
    /^source\/(.*)$/   and return $self->serve_source($1, $req);

    # for debugging
    /^_dirs$/          and return $self->send_html(
      join "<br>", "<b>Modules</b>" => $self->module_dirs,
                   "<b>Scripts</b>" => $self->script_dirs,
      );

    # file extension : passthrough
    /\.(\w+)$/         and return $self->serve_file($path_info, $1);

    #otherwise
    return $self->serve_module($path_info);
  }
}


#----------------------------------------------------------------------
# main frameset
#----------------------------------------------------------------------

sub index_frameset{
  my ($self, $req) = @_;

  # initial page to open
  my $ini         = $req->parameters->{open};
  my $ini_content = $ini || "perl";
  my $ini_toc     = $ini ? "toc?open=$ini" : "toc";

  # HTML title
  my $title = Plack::Util::encode_html($self->{page_title});

  return $self->send_html(<<__EOHTML__);
<html>
  <head><title>$title</title></head>
  <frameset cols="25%, 75%">
    <frame name="tocFrame"     src="$self->{script_name}/$ini_toc">
    <frame name="contentFrame" src="$self->{script_name}/$ini_content">
  </frameset>
</html>
__EOHTML__
}




#----------------------------------------------------------------------
# serving a single file (POD, source code or raw content)
#----------------------------------------------------------------------

sub serve_source {
  my ($self, $path, $req) = @_;

  my $params = $req->parameters;

  # default (if not printing): line numbers and syntax coloring are on
  $params->{print} or  $params->{lines} = $params->{coloring} = 1;

  # find the source file(s)
  my @files = $path =~ s[^script/][] ? $self->find_script($path)
                                     : $self->find_module($path)
      or die "did not find source for '$path'";

  # last modification
  my $mtime = max map{(stat $_)[9]} @files;

  # build text to display
  my $display_text;
  foreach my $file (@files) {
    my $text = decode("Detect", $self->slurp_file($file, ":raw"));
    $text =~ s/\r\n/\n/g;

    my $view = $self->mk_view(
      line_numbering  => $params->{lines},
      syntax_coloring => ($params->{coloring} ? $coloring_package : "")
     );
    $text    = $view->view_verbatim($text);
    $display_text .= "<p/><h2>$file</h2><p/><pre>$text</pre>";
  }


  my $offer_print = $params->{print} ? "" : <<__EOHTML__;
<form method="get" target="_blank">
<input type="submit" name="print" value="Print"> with<br>
<input type="checkbox" name="lines" checked>line numbers<br>
<input type="checkbox" name="coloring" checked>syntax coloring
</form>
__EOHTML__

  my $script = $params->{print} ? <<__EOHTML__ : "";
<script>
window.onload = function () {window.print()};
</script>
__EOHTML__

  my $doc_link = $params->{print} ? "" : <<__EOHTML__;
<a href="$self->{script_name}/$path" style="float:right">Doc</a>
__EOHTML__

  my $html = <<__EOHTML__;
<html>
<head>
  <title>Source of $path</title>
  <link href="$self->{script_name}/Alien/GvaScript/lib/GvaScript.css" rel="stylesheet" type="text/css">
  <link href="$self->{script_name}/Pod/POM/Web/lib/PodPomWeb.css" rel="stylesheet" type="text/css">
  <style>
    PRE {border: none; background: none}
    FORM {float: right; font-size: 70%; border: 1px solid}
  </style>
</head>
<body>
$doc_link
<h1>Source of $path</h1>

$offer_print

$display_text
</body>
</html>
__EOHTML__

  $self->send_html($html, $mtime);

}


sub serve_file {
  my ($self, $path, $extension) = @_;

  my ($fullpath) = $self->find_file(module_dirs => $path);
  my $mime_type  = MIME::Types->new->mimeTypeOf($extension);
  my $content    = $self->slurp_file($fullpath, ":raw");
  my $mtime      = (stat $fullpath)[9];
  $self->send_content({
    content   => $content,
    mtime     => $mtime,
    mime_type => $mime_type,
  });
}



sub serve_module {
  my ($self, $path) = @_;
  $path =~ s[::][/]g; # just in case, if called as /perldoc/Foo::Bar

  # find file(s) corresponding to $path
  my @sources = $self->find_module($path)
    or return $self->_no_such_module($path);
  my $mtime   = max map {(stat $_)[9]} @sources;

  # module version
  my $version = firstval {$_} map {$self->parse_version($_)} grep {/\.pm$/} @sources;

  # latest CPAN version
  (my $mod_name = $path) =~ s[/][::]g;
  my $cpan_package = $self->{cpan_index}->search_packages( { package => $mod_name } );
  my $cpan_version = $cpan_package ? $cpan_package->{version} : undef;

  # POD content from the first file in list
  my $content = $self->slurp_file($sources[0], ":crlf");

  # filter contents
  $_->($content) foreach @podfilters;

  # special handling for perlfunc: change initial C<..> to hyperlinks
  if ($path =~ /\bperlfunc$/) {
    my $sub = sub {my $txt = shift; $txt =~ s[C<(.*?)>][C<L</$1>>]g; $txt};
    $content =~ s[(Perl Functions by Category)(.*?)(Alphabetical Listing)]
                 [$1 . $sub->($2) . $3]es;
  }

  # assemble information to be passed to the view
  my $parser = Pod::POM->new;
  my $pom = $parser->parse_text($content) or die $parser->error;
  my $view = $self->mk_view(version         => $version,
                            mtime           => $mtime,
                            path            => $path,
                            mod_name        => $mod_name,
                            cpan_version    => $cpan_version,
                            syntax_coloring => $coloring_package);

  # generate HTML
  my $html = $view->print($pom);

  # again special handling for perlfunc : ids should be just function names
  if ($path =~ /\bperlfunc$/) {
    $html =~ s/li id="(.*?)_.*?"/li id="$1"/g;
  }

  # special handling for 'perl' : hyperlinks to man pages
  if ($path =~ /\bperl$/) {
    my $sub = sub {my $txt = shift;
                   $txt =~ s[(perl\w+)]
                            [<a href="$self->{script_name}/$1">$1</a>]g;
                   return $txt};
    $html =~ s[(<pre.*?</pre>)][$sub->($1)]egs;
  }

  return $self->send_html($html, $mtime);
}


sub serve_script {
  my ($self, $path) = @_;

  my ($fullpath) = $self->find_script($path)
    or die "no such script : $path";

  my $content = $self->slurp_file($fullpath, ":crlf");
  my $mtime   = (stat $fullpath)[9];

  for my $filter (@podfilters) {
    $filter->($content);
  }

  my $parser = Pod::POM->new;
  my $pom    = $parser->parse_text($content) or die $parser->error;
  my $view   = $self->mk_view(path            => "script/$path",
                              mtime           => $mtime,
                              syntax_coloring => $coloring_package);
  my $html   = $view->print($pom);

  return $self->send_html($html, $mtime);
}




sub find_module { 
  my ($self, $path) = @_;
  return $self->find_file(module_dirs => "$path.pod", "$path.pm",
                                         "pod/$path.pod", "pods/$path.pod");
}

sub find_script {
  my ($self, $path) = @_;
  return $self->find_file(script_dirs => $path, "$path.pl", "path.bat");
}

sub find_file {
  my ($self, $dirs_method, @file_candidates) = @_;

  # try each dir in turn. The first successful search wins.
  foreach my $dir ($self->$dirs_method) {
    my @found = grep {-f} map {"$dir/$_"} @file_candidates;
    return @found if @found; # returns a list because there could be both a *.pm and *.pod
  }

  # empty list if nothing is found
  return;
}






sub pod2pom {
  my ($self, $sourcefile) = @_;
  my $content = $self->slurp_file($sourcefile, ":crlf");

  for my $filter (@podfilters) {
    $filter->($content);
  }

  my $parser = Pod::POM->new;
  my $pom = $parser->parse_text($content) or die $parser->error;
  return $pom;
}

sub _no_such_module {
  my ($self, $module) = @_;

  $module =~ s!/!::!g;
  $module = Plack::Util::encode_html($module);
  my $html =  <<__EOHTML__;
<html>
  <head>
    <title>$module not found</title>
  </head>
  <body>
    <h1>$module not found</h1>
    <p>
      The module <code>$module</code> could not be found on this server.
      It may not be installed locally. Please try 
      <a href='https://metacpan.org/pod/$module' target='_blank'>$module on Metacpan</a>.
    </p>
  </body>
</html>
__EOHTML__

  $self->send_html($html);
}


#----------------------------------------------------------------------
# tables of contents
#----------------------------------------------------------------------


sub toc_for { # partial toc (called through Ajax)
  my ($self, $prefix) = @_;

  # special handling for builtin paths
  for ($prefix) {
    /^perldocs$/ and return $self->toc_perldocs;
    /^pragmas$/  and return $self->toc_pragmas;
    /^scripts$/  and return $self->toc_scripts;
  }

  # otherwise, find and htmlize entries under a given prefix
  my $entries = $self->find_entries_for($prefix);
  if ($prefix eq 'Pod') {   # Pod/perl* should not appear under Pod
    delete $entries->{$_} for grep /^perl/, keys %$entries;
  }
  return $self->send_html($self->htmlize_entries($entries));
}


sub toc_perldocs {
  my ($self) = @_;

  my %perldocs;

  # perl basic docs may be found under "pod", "pods", or the root dir
  for my $subdir (qw/pod pods/, "") {
    my $entries = $self->find_entries_for($subdir);

    # just keep the perl* entries, without subdir prefix
    foreach my $key (grep /^perl/, keys %$entries) {
      $perldocs{$key} = $entries->{$key};
      $perldocs{$key}{node} =~ s[^subdir/][]i;
    }
  }

  return $self->send_html($self->htmlize_perldocs(\%perldocs));
}



sub toc_pragmas {
  my ($self) = @_;

  my $entries  = $self->find_entries_for("");    # files found at root level
  delete $entries->{$_} for @ignore_toc_dirs, qw/pod pods inc/;
  delete $entries->{$_} for grep {/^perl/ or !/^[[:lower:]]/} keys %$entries;

  return $self->send_html($self->htmlize_entries($entries));
}


sub toc_scripts {
  my ($self) = @_;

  my %scripts;

  # gather all scripts and group them by initial letter
  foreach my $dir ($self->script_dirs) {
    opendir my $dh, $dir or next;
  NAME:
    foreach my $name (readdir $dh) {
      for ("$dir/$name") {
        -x && !-d && -T or next NAME ; # try to just keep Perl executables
      }
      $name =~ s/\.(pl|bat)$//i;
      my $letter = uc substr $name, 0, 1;
      $scripts{$letter}{$name} = {node => "script/$name", pod => 1};
    }
  }

  # htmlize the structure
  my $html = "";
  foreach my $letter (sort keys %scripts) {
    my $content = $self->htmlize_entries($scripts{$letter});
    $html .= closed_node(label   => $letter,
                         content => $content);
  }

  return $self->send_html($html);
}


sub find_entries_for {
  my ($self, $prefix) = @_;

  # if $prefix is of shape A*, we want top-level modules starting
  # with that letter
  my $filter;
  if ($prefix =~ /^([A-Z])\*/) {
    $filter = qr/^$1/;
    $prefix = "";
  }

  my %entries;

  foreach my $root_dir ($self->module_dirs) {
    my $dirname = $prefix ? "$root_dir/$prefix" : $root_dir;
    opendir my $dh, $dirname or next;
    foreach my $name (readdir $dh) {
      next if $name =~ /^\./;
      next if $filter and $name !~ $filter;
      my $is_dir  = -d "$dirname/$name";
      my $has_pod = $name =~ s/\.(pm|pod)$//;

      # skip if this subdir is a member of @INC (not a real module namespace)
      next if $is_dir and grep {m[^\Q$dirname/$name\E]} $self->module_dirs;

      if ($is_dir || $has_pod) { # found a TOC entry
        $entries{$name}{node} = $prefix ? "$prefix/$name" : $name;
        $entries{$name}{dir}  = 1 if $is_dir;
        $entries{$name}{pod}  = 1 if $has_pod;
      }
    }
  }
  return \%entries;
}


sub htmlize_perldocs {
  my ($self, $perldocs) = @_;
  my $parser  = Pod::POM->new;

  # Pod/perl.pom Synopsis contains a classification of perl*.pod documents
  my ($perlpod) = $self->find_module("perl")
    or die "'perl.pod' does not seem to be installed on this system";
  my $source  = $self->slurp_file($perlpod, ":crlf");
  my $perlpom = $parser->parse_text($source) or die $parser->error;

  my $h1 =  (firstval {$_->title eq 'GETTING HELP'} $perlpom->head1)
         || (firstval {$_->title eq 'SYNOPSIS'}     $perlpom->head1);
  my $html = "";

  # classified pages mentioned in the synopsis
  foreach my $h2 ($h1->head2) {
    my $title   = $h2->title;
    my $content = $h2->verbatim;

    # "Internals and C-Language Interface" is too long
    $title =~ s/^Internals.*/Internals/;

    # gather leaf entries
    my @leaves;
    while ($content =~ /^\s*(perl\S*?)\s*\t(.+)/gm) {
      my ($ref, $descr) = ($1, $2);
      my $entry = delete $perldocs->{$ref} or next;
      push @leaves, {label => $ref,
                     href  => $entry->{node},
                     attrs => qq{id='$ref' title='$descr'}};
    }
    # sort and transform into HTML
    @leaves = map {leaf(%$_)}
              sort {$a->{label} cmp $b->{label}} @leaves;
    $html .= closed_node(label   => $title,
                         content => join("\n", @leaves));
  }

  # maybe some remaining pages
  if (keys %$perldocs) {
    $html .= closed_node(label   => 'Unclassified',
                         content => $self->htmlize_entries($perldocs));
  }

  return $html;
}




sub htmlize_entries {
  my ($self, $entries) = @_;
  my $html = "";
  foreach my $name (sort {uc($a) cmp uc($b)} keys %$entries) {
    my $entry = $entries->{$name};
    (my $id = $entry->{node}) =~ s[/][::]g;
    my %args = (class => 'TN_leaf',
                label => $name,
                attrs => qq{id='$id'});
    if ($entry->{dir}) {
      $args{class}  = 'TN_node TN_closed';
      $args{attrs} .= qq{ TN:contentURL='toc/$entry->{node}'};
    }
    if ($entry->{pod}) {
      $args{href}     = $entry->{node};
      $args{abstract} = $self->get_abstract($entry->{node});
    }
    $html .= generic_node(%args);
  }
  return $html;
}

sub get_abstract {
  # override in indexer
}




sub main_toc {
  my ($self, $req) = @_;

  # initial page to open
  my $ini        = $req->parameters->{open};
  my $select_ini = $ini ? "selectToc('$ini');" : "";

  # perlfunc entries in JSON format for the DHTML autocompleter
  my @funcs = map {$_->title} grep {$_->content =~ /\S/} $self->perlfunc_items;
  s|[/\s(].*||s foreach @funcs;
  my $json_funcs = "[" . join(",", map {qq{"$_"}} uniq @funcs) . "]";

  # perlVAR entries in JSON format for the DHTML autocompleter
  my @vars = map {$_->title} grep {!/->/} map {@$_} $self->perlvar_items;
  s|\s*X<.*||s foreach @vars;
  s|\\|\\\\|g  foreach @vars;
  s|"|\\"|g    foreach @vars;
  my $json_vars = "[" . join(",", map {qq{"$_"}} uniq @vars) . "]";

  my $js_no_indexer = $no_indexer ? 'true' : 'false';

  my @perl_sections = map {closed_node(
      label       => ucfirst($_),
      label_class => "TN_label small_title",
      attrs       =>  qq{TN:contentURL='toc/$_' id='$_'},
     )} qw/perldocs pragmas scripts/;

  my $alpha_list = "";
  for my $letter ('A' .. 'Z') {
    $alpha_list .= closed_node (
      label       => $letter,
      label_class => "TN_label",
      attrs       =>  qq{TN:contentURL='toc/$letter*' id='${letter}:'},
     );
  }
  my $modules = generic_node (label       => "Modules",
                              label_class => "TN_label small_title",
                              content     => $alpha_list);


  return $self->send_html(<<__EOHTML__);
<html>
<head>
  <base target="contentFrame">
  <link href="$self->{script_name}/Alien/GvaScript/lib/GvaScript.css"
        rel="stylesheet" type="text/css">
  <link href="$self->{script_name}/Pod/POM/Web/lib/PodPomWeb.css"
        rel="stylesheet" type="text/css">
  <script src="$self->{script_name}/Alien/GvaScript/lib/prototype.js"></script>
  <script src="$self->{script_name}/Alien/GvaScript/lib/GvaScript.js"></script>
  <script>
    var treeNavigator;
    var perlfuncs = $json_funcs;
    var perlvars  = $json_vars;
    var completers = {};
    var no_indexer = $js_no_indexer;

    function submit_on_event(event) {
        \$('search_form').submit();
    }

    function resize_tree_navigator() {
      // compute available height -- comes either from body or documentElement,
      // depending on browser and on compatibility mode !!
      var doc_el_height = document.documentElement.clientHeight;
      var avail_height
        = (Prototype.Browser.IE && doc_el_height) ? doc_el_height
                                                  : document.body.clientHeight;

      var tree_height = avail_height - \$('toc_frame_top').scrollHeight - 5;
      if (tree_height > 100)
        \$('TN_tree').style.height = tree_height + "px";
    }

    function open_nodes(first_node, rest) {

      var node = \$(first_node);
      if (!node || !treeNavigator) return;

      // shift to next node in sequence
      first_node = rest.shift();

      // build a handler for "onAfterLoadContent" (closure on first_node/rest)
      var open_or_select_next = function() {

        // delete handler that might have been placed by previous call
        delete treeNavigator.onAfterLoadContent;

        //
        if (rest.length > 0) {
          open_nodes(first_node, rest)
        }
        else {
          treeNavigator.openEnclosingNodes(\$(first_node));
          treeNavigator.select(\$(first_node));
        }
      };


      // if node is closed and currently has no content, we need to register
      // a handler, open the node so that it gets its content by Ajax,
      // and then execute the handler to open the rest after Ajax returns
      if (treeNavigator.isClosed(node)
          && !treeNavigator.content(node)) {
        treeNavigator.onAfterLoadContent = open_or_select_next;
        treeNavigator.open(node);
      }
      // otherwise just a direct call
      else {
        open_or_select_next();
      }

    }


    function selectToc(entry) {

      // build array of intermediate nodes (i.e "Foo", "Foo::Bar", etc.)
      var parts = entry.split(new RegExp("/|::"));
      var accu = '';
      var sequence = parts.map(function(e) {
         accu = accu ? (accu + "::" + e) : e;
         return accu;
        });

      // choose id of first_node by analysis of entry
      var initial = entry.substr(0, 1);
      var first_node

        // CASE module (starting with uppercase)
        = (initial <= 'Z')           ? (initial + ":")

        // CASE perl* documentation page
        : entry.search(/^perl/) > -1 ? "perldocs"

        // CASE other lowercase entries
        :                              "pragmas"
        ;

      // open each node in sequence
      open_nodes(first_node, sequence);
    }

    function setup() {

      treeNavigator
        = new GvaScript.TreeNavigator('TN_tree', {tabIndex:-1});

      completers.perlfunc = new GvaScript.AutoCompleter(
             perlfuncs,
             {minimumChars: 1,
              minWidth: 100,
              offsetX: -20,
              autoSuggestDelay: 400});
      completers.perlfunc.onComplete = submit_on_event;

      completers.perlvar = new GvaScript.AutoCompleter(
             perlvars,
             {minimumChars: 1,
              minWidth: 100,
              offsetX: -20,
              autoSuggestDelay: 400});
      completers.perlvar.onComplete = submit_on_event;

      if (!no_indexer) {
        completers.modlist  = new GvaScript.AutoCompleter(
             "search?source=modlist&search=",
             {minimumChars: 2, minWidth: 100, offsetX: -20, typeAhead: false});
        completers.modlist.onComplete = submit_on_event;
      }

      resize_tree_navigator();
      $select_ini
    }

    document.observe('dom:loaded', setup);
    window.onresize = resize_tree_navigator;
    // Note: observe('resize') doesn't work. Why ?

    function displayContent(event) {
        var label = event.controller.label(event.target);
        if (label && label.tagName == "A") {
          label.focus();
          return Event. stopNone;
        }
    }

   function maybe_complete(input) {
     if (input._autocompleter)
        input._autocompleter.detach(input);

     switch (input.form.source.selectedIndex) {
       case 0: completers.perlfunc.autocomplete(input); break;
       case 1: completers.perlvar.autocomplete(input); break;
       case 3: if (!no_indexer)
                 completers.modlist.autocomplete(input);
               break;
     }
   }


  </script>
  <style>
   .small_title {color: midnightblue; font-weight: bold; padding: 0 3 0 3}
   FORM     {margin:0px}
   BODY     {margin:0px; font-size: 70%; overflow-x: hidden}
   DIV      {margin:0px; width: 100%}
   #TN_tree {overflow-y:scroll; overflow-x: hidden}
  </style>
</head>
<body>

<div id='toc_frame_top'>
<div class="small_title"
     style="text-align:center;border-bottom: 1px solid">
$self->{page_title}
</div>
<div style="text-align:right">
<a href="Pod/POM/Web/Help" class="small_title">Help</a>
</div>

<form action="search" id="search_form" method="get">
<span class="small_title">Search in</span>
     <select name="source">
      <option>perlfunc</option>
      <option>perlvar</option>
      <option>perlfaq</option>
      <option>modules</option>
      <option>full-text</option>
     </select><br>
<span class="small_title">&nbsp;for&nbsp;</span><input
         name="search" size="15"
         autocomplete="off"
         onfocus="maybe_complete(this)">
</form>
<br>
<div class="small_title"
     style="border-bottom: 1px solid">Browse</div>
</div>

<!-- In principle the tree navigator below would best belong in a
     different frame, but instead it's in a div because the autocompleter
     from the form above sometimes needs to overlap the tree nav. -->
<div id='TN_tree' onPing='displayContent'>
@perl_sections
$modules
</div>

</body>
</html>
__EOHTML__
}

#----------------------------------------------------------------------
# searching
#----------------------------------------------------------------------

sub dispatch_search {
  my ($self, $req) = @_;

  my $params = $req->parameters;
  my $source = $params->{source};
  my $method = {perlfunc      => 'perlfunc',
                perlvar       => 'perlvar',
                perlfaq       => 'perlfaq',
                modules       => 'serve_module',
                full_text     => 'full_text',
                modlist       => 'modlist',
                }->{$source}  or die "cannot search in '$source'";

  if ($method =~ /full_text|modlist/ and $no_indexer) {
    die "<p>this method requires <b>Search::Indexer</b></p>"
      . "<p>please ask your system administrator to install it</p>"
      . "(<small>error message : $no_indexer</small>)";
  }

  return $self->$method($params->{search});
}



my @_perlfunc_items; # simple-minded cache

sub perlfunc_items {
  my ($self) = @_;

  unless (@_perlfunc_items) {
    my ($funcpod) = $self->find_module("perlfunc")
      or die "'perlfunc.pod' does not seem to be installed on this system";
    my $funcpom   = $self->pod2pom($funcpod);
    my ($description) = grep {$_->title eq 'DESCRIPTION'} $funcpom->head1;
    my ($alphalist)
      = grep {$_->title =~ /^Alphabetical Listing/i} $description->head2;
    @_perlfunc_items = $alphalist->over->[0]->item;
  };
  return @_perlfunc_items;
}


sub perlfunc {
  my ($self, $func) = @_;
  my @items = grep {$_->title =~ /^$func\b/} $self->perlfunc_items
     or return $self->send_html("No documentation found for perl "
                               ."function '<tt>$func</tt>'");

  my $view    = $self->mk_view(path => "perlfunc/$func");

  my @li_items = map {$_->present($view)} @items;
  return $self->send_html(<<__EOHTML__);
<html>
<head>
  <link href="$self->{script_name}/Pod/POM/Web/lib/PodPomWeb.css" rel="stylesheet" type="text/css">
</head>
<body>
<h2>Extract from <a href="$self->{script_name}/perlfunc">perlfunc</a></h2>

<ul>@li_items</ul>
</body>
__EOHTML__
}



sub perlvar_items {
  my ($self) = @_;

  # lazily compute at first request; then store in $self
  unless ($self->{perlvar_items}) {

    # get items defining variables
    my ($varpod) = $self->find_module("perlvar")
      or die "'perlvar.pod' does not seem to be installed on this system";
    my $varpom   = $self->pod2pom($varpod);
    my @items    = _extract_items($varpom);

    # group items having common content
    my $tmp = [];
    foreach my $item (@items) {
      push @$tmp, $item;
      if ($item->content . "") { # force stringification
        push @{$self->{perlvar_items}}, $tmp;
        $tmp = [];
      }
    }
  };

  return @{$self->{perlvar_items}};
}


sub perlvar {
  my ($self, $var) = @_;

  my @items = grep {any {$_->title =~ /^\Q$var\E(\s|$)/} @$_}
                   $self->perlvar_items
     or return $self->send_html("No documentation found for perl "
                               ."variable '<tt>$var</tt>'");
  my $view    = $self->mk_view(path => "perlvar/$var");

  my @li_items = map {$_->present($view)} map {@$_} @items;
  return $self->send_html(<<__EOHTML__);
<html>
<head>
  <link href="$self->{script_name}/Pod/POM/Web/lib/PodPomWeb.css" rel="stylesheet" type="text/css">
</head>
<body>
<h2>Extract from <a href="$self->{script_name}/perlvar">perlvar</a></h2>

<ul>@li_items</ul>
</body>
__EOHTML__
}



sub perlfaq {
  my ($self, $faq_entry) = @_;
  my $regex = qr/\b\Q$faq_entry\E\b/i;
  my $answers   = "";
  my $n_answers = 0;

  my $view = $self->mk_view(path => "perlfaq/$faq_entry");

 FAQ:
  for my $num (1..9) {
    my $faq = "perlfaq$num";
    my ($faqpod) = $self->find_module($faq)
      or die "'$faq.pod' does not seem to be installed on this system";
    my $faqpom = $self->pod2pom($faqpod);
    my @questions = map {grep {$_->title =~ $regex} $_->head2} $faqpom->head1
      or next FAQ;
    my @nodes = map {$view->print($_)} @questions;
    $answers .= generic_node(label     => "Found in perlfaq$num",
                             label_tag => "h2",
                             content   => join("", @nodes));
    $n_answers += @nodes;
  }

  return $self->send_html(<<__EOHTML__);
<html>
<head>
  <link href="$self->{script_name}/Alien/GvaScript/lib/GvaScript.css" rel="stylesheet" type="text/css">
  <link href="$self->{script_name}/Pod/POM/Web/lib/PodPomWeb.css" rel="stylesheet" type="text/css">
  <script src="$self->{script_name}/Alien/GvaScript/lib/prototype.js"></script>
  <script src="$self->{script_name}/Alien/GvaScript/lib/GvaScript.js"></script>
  <script>
    var treeNavigator;
    function setup() {
      treeNavigator = new GvaScript.TreeNavigator('TN_tree');
    }
    window.onload = setup;
   </script>
</head>
<body>
<h1>Extracts from <a href="$self->{script_name}/perlfaq">perlfaq</a></h1><br>
<em>searching for '$faq_entry' : $n_answers answers</em><br><br>
<div id='TN_tree'>
$answers
</div>
</body>
__EOHTML__

}


#----------------------------------------------------------------------
# miscellaneous
#----------------------------------------------------------------------


sub mk_view {
  my ($self, %args) = @_;

  my $view = Pod::POM::View::HTML::_PerlDoc->new(
    script_name => $self->{script_name},
    %args
   );

  return $view;
}



sub send_html {
  my ($self, $html, $mtime) = @_;

  # dirty hack for MSIE8 (TODO: send proper HTTP header instead)
  $html =~ s[<head>]
            [<head>\n<meta http-equiv="X-UA-Compatible" content="IE=edge">];

  $self->send_content({content => encode_utf8($html),
                       code    => 200,
                       mtime   => $mtime,
                       charset => 'UTF-8'});
}



sub send_content {
  my ($self, $args) = @_;

  my $charset   = $args->{charset};
  my $length    = length $args->{content};
  my $mime_type = $args->{mime_type} || "text/html";
     $mime_type .= "; charset=$charset" if $charset and $mime_type =~ /html/;
  my $modified  = gmtime $args->{mtime};
  my $code      = $args->{code} || 200;


  my $headers = {Content_type   => $mime_type,
                 Content_length => $length};
  $headers->{Last_modified} = $modified if $args->{mtime};
  my $r = Plack::Response->new($code, $headers, $args->{content});
  $r->finalize;
}




#----------------------------------------------------------------------
# generating GvaScript treeNavigator structure
#----------------------------------------------------------------------

sub generic_node {
  my %args = @_;
  $args{class}       ||= "TN_node";
  $args{attrs}       &&= " $args{attrs}";
  $args{content}     ||= "";
  $args{content}     &&= qq{<div class="TN_content">$args{content}</div>};
  my ($default_label_tag, $label_attrs)
    = $args{href} ? ("a",    qq{ href='$args{href}'})
                  : ("span", ""                     );
  $args{label_tag}   ||= $default_label_tag;
  $args{label_class} ||= "TN_label";
  if ($args{abstract}) {
    my $abstract = Plack::Util::encode_html($args{abstract});
    $label_attrs .= qq{ title="$abstract"};
  }
  return qq{<div class="$args{class}"$args{attrs}>}
       .    qq{<$args{label_tag} class="$args{label_class}"$label_attrs>}
       .         $args{label}
       .    qq{</$args{label_tag}>}
       .    $args{content}
       . qq{</div>};
}


sub closed_node {
  return generic_node(@_, class => "TN_node TN_closed");
}

sub leaf {
  return generic_node(@_, class => "TN_leaf");
}


#----------------------------------------------------------------------
# utilities
#----------------------------------------------------------------------


sub slurp_file {
  my ($self, $file, $io_layer) = @_;
  open my $fh, "<", $file or die "open $file: $!";
  binmode($fh, $io_layer) if $io_layer;
  local $/ = undef;
  return <$fh>;
}


sub parse_version {
  my ($self, $file_name) = @_;

  my $mm = Module::Metadata->new_from_file($file_name)
    or die "couldn't create Module::Metadata";

  return $mm->version;
}



sub _extract_items { # recursively grab all nodes of type 'item'
  my $node = shift;

  for ($node->type) {
    /^item/            and return ($node);
    /^(pod|head|over)/ and return map {_extract_items($_)} $node->content;
  }
  return ();
}


1;
#======================================================================
# END OF package Pod::POM::Web
#======================================================================


#======================================================================
package Pod::POM::View::HTML::_PerlDoc; # View package
#======================================================================
use strict;
use warnings;
no warnings         qw/uninitialized/;
use base            qw/Pod::POM::View::HTML/;
use POSIX           qw/strftime/;              # date formatting
use List::MoreUtils qw/firstval/;
use Plack::Util;



# SUPER::view_seq_text tries to find links automatically ... but is buggy
# for URLs that contain '$' or ' '. So we disable it, and only consider
# links explicitly marked with L<..>, handled in view_seq_link() below.
sub view_seq_text {
  my ($self, $text) = @_;

  for ($text) {
    s/&/&amp;/g;
    s/</&lt;/g;
    s/>/&gt;/g;
  }

  return $text;
}



# some adaptations to SUPER::view_seq_link
sub view_seq_link {
    my ($self, $link) = @_;

    # we handle the L<link_text|...> syntax here, because we also want
    # link_text for http URLS (not supported by SUPER::view_seq_link)
    my $link_text;
    $link =~ s/^([^|]+)\|// and $link_text = $1;

    # links to external resources will open in a blank page
    my $is_external_resource = ($link =~ m[^\w+://]);

    # call parent and reparse the result
    my $linked = $self->SUPER::view_seq_link($link);
    my ($url, $label) = ($linked =~ m[^<a href="(.*?)">(.*)</a>]);

    # fix link for 'hash' part of the url
    $url =~ s[#(.*)]['#' . _title_to_id($1)]e unless $is_external_resource;

    # if explicit link_text given by client, take that as label, unchanged
    if ($link_text) {
      $label = $link_text;
    }
    # if "$page/$section", replace by "$section in $page"
    elsif ($label !~ m{^\w+://}s) { # but only if not a full-blown URL
      $label =~ s[^(.*?)/(.*)$][$1 ? "$2 in $1" : $2]e ;
    }

    # return link (if external resource, opens in a new browser window)
    my $target = $is_external_resource ? " target='_blank'" : "";
    return qq{<a href="$url"$target>$label</a>};
}



sub view_seq_link_transform_path {
    my($self, $page) = @_;
    $page =~ s[::][/]g;
    return "$self->{script_name}/$page";
}


sub view_item {
  my ($self, $item) = @_;

  my $title = eval {$item->title->present($self)} || "";
     $title = "" if $title =~ /^\s*\*\s*$/;

  my $class = "";
  my $id    = _title_to_id($title);
  $id &&= qq{ id="$id"};

  my $content = $item->content->present($self);
  $title   = qq{<b>$title</b>} if $title;
  return qq{<li$id$class>$title\n$content</li>\n};
}



sub _title_to_id {
  my $title = shift;
  $title =~ s/<.*?>//g;          # no tags
  $title =~ s/[,(].*//;          # drop argument lists or text lists
  $title =~ s/\s*$//;            # drop final spaces
  $title =~ s/[^A-Za-z0-9_]/_/g; # replace chars unsuitable for an id
  return $title;
}


sub view_pod {
  my ($self, $pom) = @_;

  # compute view
  my $content = $pom->content->present($self)
    or return "no documentation found in <tt>$self->{path}</tt><br>\n"
            . "<a href='$self->{script_name}/source/$self->{path}'>Source</a>";

  # parse name and description
  my $name_h1   = firstval {$_->title =~ /^(NAME|TITLE)\b/} $pom->head1();
  my $doc_title = $name_h1 ? $name_h1->content->present('Pod::POM::View')
                                               # retrieve content as plain text
                           : 'Untitled';
  my ($name, $description) = ($doc_title =~ /^\s*(.*?)\s+-+\s+(.*)/);
  $name ||= $doc_title;
  $name =~ s/\n.*//s;

  # installation date
  my $installed = strftime("%x", localtime($self->{mtime}));

  # if this is a module (and not a script), get additional info
  my ($version, $core_release, $orig_version, $cpan_info, $module_refs)
    = ("") x 6;
  if (my $mod_name = $self->{mod_name}) {

    # version
    $version = $self->{version} ? "v. $self->{version}, " : "";

    # is this module in Perl core ?
    $core_release = Module::CoreList->first_release($mod_name) || "";
    $orig_version
      = $Module::CoreList::version{$core_release}{$mod_name} || "";
    $orig_version &&= "v. $orig_version ";
    $core_release &&= "; ${orig_version}entered Perl core in $core_release";

    # latest CPAN version
    my $latest_version = $self->{cpan_version} ? " (v. $self->{cpan_version})" : "";

    # hyperlinks to various internet resources
    $module_refs = qq{<br>
     <a href="https://metacpan.org/pod/$mod_name"
        target="_blank">meta::cpan$latest_version</a>
    };
  }

  my $toc = $self->make_toc($pom, 0);

  return <<__EOHTML__
<html>
<head>
  <title>$name</title>
  <link href="$self->{script_name}/Alien/GvaScript/lib/GvaScript.css" rel="stylesheet" type="text/css">
  <link href="$self->{script_name}/Pod/POM/Web/lib/PodPomWeb.css" rel="stylesheet" type="text/css">
  <script src="$self->{script_name}/Alien/GvaScript/lib/prototype.js"></script>
  <script src="$self->{script_name}/Alien/GvaScript/lib/GvaScript.js"></script>
  <script>
    var treeNavigator;
    function setup() {
      new GvaScript.TreeNavigator(
         'TN_tree',
         {selectFirstNode: (location.hash ? false : true),
          tabIndex: 0}
      );

     var tocFrame = window.parent.frames.tocFrame;
     if (tocFrame) {
       try {tocFrame.eval("selectToc('$name')")}
       catch(e) {};
      }
    }
    window.onload = setup;
    function jumpto_href(event) {
      var label = event.controller.label(event.target);
      if (label && label.tagName == "A") {
        /* label.focus(); */
        return Event.stopNone;
      }
    }
  </script>
  <style>
    #TOC .TN_content .TN_label {font-size: 80%; font-weight: bold}
    #TOC .TN_leaf    .TN_label {font-weight: normal}

    #ref_box {
      clear: right;
      float: right;
      text-align: right;
      font-size: 80%;
    }
    #title_descr {
       clear: right;
       float: right;
       font-style: italic;
       margin-top: 8px;
       margin-bottom: 8px;
       padding: 5px;
       text-align: center;
       border: 3px double #888;
    }
  </style>
</head>
<body>
<div id='TN_tree'>
  <div class="TN_node">
   <h1 class="TN_label">$name</h1>
   <small>(${version}installed $installed$core_release$cpan_info)</small>


   <span id="title_descr">$description</span>

   <span id="ref_box">
   <a href="$self->{script_name}/source/$self->{path}">Source</a>
   $module_refs
   </span>

   <div class="TN_content">
     <div class="TN_node"  onPing="jumpto_href" id="TOC">
       <h3 class="TN_label">Table of contents</h3>
       <div class="TN_content">
         $toc
       </div>
     </div>
     <hr/>
   </div>
  </div>
$content
</div>
</body>
</html>
__EOHTML__

}

# generating family of methods for view_head1, view_head2, etc.
BEGIN {
  for my $num (1..6) {
    no strict 'refs';
    *{"view_head$num"} = sub {
      my ($self, $item) = @_;
      my $title   = $item->title->present($self);
      my $id      = _title_to_id($title);
      my $content = $item->content->present($self);
      my $h_num   = $num + 1;
      return <<EOHTML
  <div class="TN_node" id="$id">
    <h$h_num class="TN_label">$title</h$h_num>
    <div class="TN_content">
      $content
    </div>
  </div>
EOHTML
    }
  }
}


sub view_seq_index {
  my ($self, $item) = @_;
  return ""; # Pod index tags have no interest for HTML
}


sub view_verbatim {
  my ($self, $text) = @_;

  my $coloring = $self->{syntax_coloring};
  if ($coloring) {
    my $method = "${coloring}_coloring";
    $text = $self->$method($text);
  }
  else {
    $text = Plack::Util::encode_html($text);
  }

  # hyperlinks to other modules
  $text =~ s{(\buse\b(?:</span>)?\ +(?:<span.*?>)?)([\w:]+)}
            {my $url = $self->view_seq_link_transform_path($2);
             qq{$1<a href="$url">$2</a>} }eg;

  if ($self->{line_numbering}) {
    my $line = 1;
    $text =~ s/^/sprintf "%6d\t", $line++/egm;
  }
  return qq{<pre class="$coloring">$text</pre>};
}



sub PPI_coloring {
  my ($self, $text) = @_;
  my $ppi = PPI::HTML->new();
  my $html = $ppi->html(\$text);

  if ($html) {
    $html =~ s/<br>//g;
    return $html;
  }
  else { # PPI failed to parse that text
    return Plack::Util::encode_html($text);
  }
}


sub SCINEPLEX_coloring {
  my ($self, $text) = @_;
  eval {
    $text = ActiveState::Scineplex::Annotate($text,
                                             'perl',
                                             outputFormat => 'html');
  };
  return $text;
}





sub make_toc {
  my ($self, $item, $level) = @_;

  my $html      = "";
  my $method    = "head" . ($level + 1);
  my $sub_items = $item->$method;

  foreach my $sub_item (@$sub_items) {
    my $title    = $sub_item->title->present($self);
    my $id       = _title_to_id($title);

    my $node_content = $self->make_toc($sub_item, $level + 1);
    my $class        = $node_content ? "TN_node" : "TN_leaf";
    $node_content  &&= qq{<div class="TN_content">$node_content</div>};

    $html .= qq{<div class="$class">}
           .    qq{<a class="TN_label" href="#$id">$title</a>}
           .    $node_content
           . qq{</div>};
  }

  return $html;
}


sub DESTROY {} # avoid AUTOLOAD


1;



__END__

=encoding ISO8859-1

=head1 NAME

Pod::POM::Web - HTML Perldoc server

=head1 DESCRIPTION

L<Pod::POM::Web> is a Web application for browsing
the documentation of Perl components installed
on your local machine. Since pages are dynamically
generated, they are always in sync with code actually
installed.

The application offers

=over

=item *

a tree view for browsing through installed modules
(with dynamic expansion of branches as they are visited)

=item *

a tree view for navigating and opening / closing sections while
visiting a documentation page

=item *

a source code view with hyperlinks between used modules
and optionally with syntax coloring
(see section L</"Optional features">)


=item *

direct access to L<perlfunc> entries (builtin Perl functions)

=item *

search through L<perlfaq> headers

=item *

full-text search, including names of Perl variables
(this is an optional feature -- see section L</"Optional features">).

=item *

parsing and display of version number

=item *

display if and when the displayed module entered Perl core.

=item *

parsing pod links and translating them into hypertext links

=item *

links to MetaCPAN

=back

The application may be hosted by an existing Web server, or otherwise
may run its own builtin Web server. Instructions for launching the application
are given in the next section.

Usage of the application is described in a separate document
L<Pod::POM::Web::Help>.

=head1 STARTING THE WEB APPLICATION



=head2 Starting from the command-line

The simplest way to use this application is to start a process invoking
the builtin HTTP server :

  perl -MPod::POM::Web -e server

This is useful if you have no other HTTP server, or if
you want to run this module under the perl debugger.
The server will listen at L<http://localhost:5000>.
A different port may be specified  :

  perl -MPod::POM::Web -e server -- -p 8888

Notice the double dash C<--> : this is used to separate options to the
C<perl> command itself from options to C<Pod::POM::Web>.

The internal implementation of C<server> is based on L<Plack::Runner>, the same
module that also supports the L<plackup> utility. All plackup options
can also be used here -- see plackup's documentation.

Another way to start the server is to call C<plackup> directly :

  plackup -MPod::POM::Web -e app -p 8888

In this case no double dash is required.


=head3 As a cgi-bin script

Alternatively, you can run this application as a cgi-script
by writing a simple file F<perldoc> in your C<cgi-bin> directory,
containing :

  #!/path/to/perl
  use Pod::POM::Web;
  use Plack::Handler::CGI;

  my $app = Pod::POM::Web->new->to_app;
  Plack::Handler::CGI->new->run($app);


For historical reasons, the module also supports a simpler invocation,
written as follows :

  #!/path/to/perl
  use Pod::POM::Web;
  Pod::POM::Web->handler;

Make this script executable,
then navigate to URL L<http://localhost/cgi-bin/perldoc>.


=head3 Other Web architectures -- PSGI

The application is built on top of the well-known L<Plack> middleware for
web applications, using the L<PSGI> protocol. Therefore it can be integrated 
easily in various Web architectures. Write a F<.psgi> file as follows :

  use Pod::POM::Web;
  Pod::POM::Web->new->to_app;

and invoke one of the Web server adapters under L<Plack::Handler>.



=head2 Opening a specific initial page

By default, the initial page displayed by the application
is F<perl>. This can be changed by supplying an C<open> argument
with the path to any documentation page: for example

  http://localhost:8080?open=Pod/POM/Web
  http://localhost:8080?open=perlfaq

=head2 Setting a specific title

If you run several instances of C<Pod::POM::Web> simultaneously, you may
want them to have distinct titles. This can be done like this:

  perl -MPod::POM::Web -e server -- --title "My Own Perl Doc"


=head1 MISCELLANEOUS

=head2 Note about security

This application is intended as a power tool for Perl developers,
not as an Internet application. It will give read access to any file
installed under your C<@INC> path or Apache C<lib/perl> directory;
so it is probably a B<bad idea>
to put it on a public Internet server.


=head2 Optional features

=head3 Syntax coloring

Syntax coloring improves readability of code excerpts.
If your Perl distribution is from ActiveState, then
C<Pod::POM::Web> will take advantage
of the L<ActiveState::Scineplex> module
which is already installed on your system. Otherwise,
you need to install L<PPI::HTML>, available from CPAN.

=head3 Full-text indexing

C<Pod::POM::Web> can index the documentation and source code
of all your installed modules, including Perl variable names,
C<Names:::Of::Modules>, etc. To use this feature you need to

=over

=item *

install L<Search::Indexer> from CPAN

=item *

build the index as described in L<Pod::POM::Web::Indexer> documentation.

=back


=head3 Indication of the latest CPAN version

When displaying a module, L<CPAN::Common::Index> is used to try to identify the
latest CPAN version of that module. By default the information comes from
C<http://cpanmetadb.plackperl.org/v1.0/>, but it requires an internet connection.
If a local installation of L<CPAN::Mini> is available, this will be used as
a primary source of information.



=head1 HINTS TO POD AUTHORING

=head2 Images

The Pod::Pom::Web server also serves non-pod files within the C<@INC>
hierarchy. This is useful for example to include images in your
documentation, by inserting chunks of HTML as follows :

  =for html
    <img src="pretty_diagram.jpg">

or

  =for html
    <object type="image/svg+xml" data="try.svg" width="640" height="480">
    </object>

Here it is assumed that auxiliary files C<pretty_diagram.jpg> or
C<try.svg> are in the same directory than the POD source; but
of course relative or absolute links can be used.



=head1 CLASS METHODS

=head2 import

When the module is C<use>d from the command-line, the C<import> method
automatically exports a C<server> function and an C<app> function to
facilitate server startup.

=head2 server

Invokes L<Plack::Runner> to launch the server.

=head2 app

Creates an instance of the module and returns a L<PSGI> app.

Options from the command-line that are not consumed by L<plackup>
are read and passed to to the L<new> method. Available options are :

=over

=item C<page_title> or C<title>

Title for this instance of the application.

=item C<module_dirs> or C<mdirs>

Additional directories to search for modules.

=item C<script_dirs> or C<sdirs>

Additional directories to search for scripts.

=back


=head2 handler

Legacy class method, used by CGI scripts or mod_perl handlers.

=head2 new

Constructor. May take the following arguments :

=over 

=item C<page_title>

for specifying the HTML title
of the application (useful if you run several concurrent instances
of Pod::POM::Web).

=item C<module_dirs>

directories for searching for modules,
in addition to the standard ones installed with your perl executable.

=item C<script_dirs>

additional directories for searching for scripts

=item C<script_name>

URL fragment to be prepended before each internal hyperlink.

=back


=head1 INSTANCE METHODS

Instance methods are not meant to be called by external clients.
Some documentation can be found in the source code.



=head1 ACKNOWLEDGEMENTS

This web application was deeply inspired by :

=over

=item *

the structure of HTML Perl documentation released with
ActivePerl (L<http://www.activeperl.com/ASPN/Perl>).


=item *

the  excellent tree navigation in Microsoft's former MSDN Library Web site
-- since they rebuilt the site, keyboard navigation has gone  !

=item *

the standalone HTTP server implemented in L<Pod::WebServer>.

=item *

the wide possibilities of Andy Wardley's L<Pod::POM> parser.

=back

Thanks
to Philippe Bruhat who mentioned a weakness in the API,
to Chris Dolan who supplied many useful suggestions and patches
(esp. integration with AnnoCPAN),
to R�mi Pauchet who pointed out a regression bug with Firefox CSS,
to Alexandre Jousset who fixed a bug in the TOC display,
to C�dric Bouvier who pointed out a IO bug in serving binary files,
to Elliot Shank who contributed the "page_title" option,
to Olivier 'dolmen' Mengu� who suggested to export "server" into C<main::>,
to Ben Bullock who added the 403 message for absent modules,
and to Paul Cochrane for several improvements in the doc and in the
repository structure.


=head1 RELEASE NOTES

Indexed information since version 1.04 is not compatible
with previous versions.

So if you upgraded from a previous version and want to use
the index, you need to rebuild it entirely, by running the
command :

  perl -MPod::POM::Web::Indexer -e "index(-from_scratch => 1)"



=head1 AUTHOR

Laurent Dami, C<< <dami AT cpan DOT org> >>


=head1 COPYRIGHT & LICENSE

Copyright 2007-2021 Laurent Dami, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=head1 TODO

  - real tests !
  - factorization (esp. initial <head> in html pages)
  - use Getopts to choose colouring package, toggle CPAN, etc.
  - declare Pod::POM bugs
      - perlre : line 1693 improper parsing of L<C<< (?>pattern) >>>
   - bug: doc files taken as pragmas (lwptut, lwpcook, pip, pler)
   - exploit doc index X<...>
   - do something with perllocal (installation history)
   - restrict to given set of paths/ modules
       - need to change toc (no perlfunc, no scripts/pragmas, etc)
       - treenav with letter entries or not ?
