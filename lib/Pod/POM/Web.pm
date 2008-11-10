=begin BUGS

  MSIE : click on TOC entry jumps and then jumps back to TOC (timeout handler)
  Firefox: kb navigation does not scroll properly

=cut







#======================================================================
package Pod::POM::Web; # see doc at end of file
#======================================================================
use strict;
use warnings;
no warnings 'uninitialized';

use Pod::POM 0.17;              # parsing Pod
use List::Util      qw/max/;    # maximum
use List::MoreUtils qw/uniq firstval/;
use Module::CoreList;           # asking if a module belongs to Perl core
use HTTP::Daemon;               # for the builtin HTTP server
use URI;                        # parsing incoming requests
use URI::QueryParam;
use MIME::Types;                # translate file extension into MIME type
use Alien::GvaScript 1.10;      # javascript files
use Encode::Guess;              # guessing if pod source is utf8 or latin1
use Config;                     # where are the script directories


#----------------------------------------------------------------------
# globals
#----------------------------------------------------------------------

our $VERSION = '1.10';

# some subdirs never contain Pod documentation
my @ignore_toc_dirs = qw/auto unicore/; 

# filter @INC (don't want '.', nor server_root added by mod_perl)
my $server_root = eval {Apache2::ServerUtil::server_root()} || "";
our                # because accessed from Pod::POM::Web::Indexer
   @search_dirs = grep {$_ ne '.' && $_ ne $server_root} @INC;

# directories for executable perl scripts
my @config_script_dirs = qw/sitescriptexp vendorscriptexp scriptdirexp/;
my @script_dirs        = grep {$_} @Config{@config_script_dirs};

# syntax coloring (optional)
my $coloring_package 
  = eval {require PPI::HTML}              ? "PPI"
  : eval {require ActiveState::Scineplex} ? "SCINEPLEX" : "";

# fulltext indexing (optional)
my $no_indexer = eval {require Pod::POM::Web::Indexer} ? 0 : $@;

# CPAN latest version info (disabled, for future releases)
my $has_cpan = 0; # eval {require CPAN};



# A sequence of optional filters to apply to the source code before
# running it through Pod::POM. Source code is passed in $_[0] and 
# should be modified in place.
my @podfilters = (

  # AnnoCPAN must be first in the filter list because 
  # it uses the MD5 of the original source
  eval {require AnnoCPAN::Perldoc::Filter} 
    ? sub {$_[0] = AnnoCPAN::Perldoc::Filter->new->filter($_[0])} 
    : (),

  # Pod::POM fails to parse correctly when there is an initial blank line
  sub { $_[0] =~ s/\A\s*// },

);


our # because used by Pod::POM::View::HTML::_PerlDoc
  %escape_entity = ('&' => '&amp;',
                    '<' => '&lt;',
                    '>' => '&gt;',
                    '"' => '&quot;');


#----------------------------------------------------------------------
# main entry point
#----------------------------------------------------------------------

sub server { # builtin HTTP server; unused if running under Apache
  my ($class, $port) = @_;
  $port ||= 8080;

  my $daemon = HTTP::Daemon->new(LocalPort => $port,
                                 ReuseAddr => 1) # patch by CDOLAN
    or die "could not start daemon on port $port";
  print STDERR "Please contact me at: <URL:", $daemon->url, ">\n";

  # main server loop
  while (my $client_connection = $daemon->accept) {
    while (my $req = $client_connection->get_request) {
      print STDERR "URL : " , $req->url, "\n";
      $client_connection->force_last_request;    # patch by CDOLAN
      my $response = HTTP::Response->new;
      $class->handler($req, $response);
      $client_connection->send_response($response);
    }
    $client_connection->close;
    undef($client_connection);
  }

}


sub handler : method  {
  my ($class, $request, $response) = @_; 
  my $self = $class->new($request, $response);
  eval { $self->dispatch_request(); 1}
    or $self->send_content({content => $@, code => 500});  
  return 0; # Apache2::Const::OK;
}


sub new  {
  my ($class, $request, $response) = @_; 
  my $self;

  # cheat: will create an instance of the Indexer subclass if possible
  if (!$no_indexer && $class eq __PACKAGE__) {
    $class = "Pod::POM::Web::Indexer";
  }

  for (ref $request) {

    /^Apache/ and do { # coming from mod_perl
      my $path = $request->path_info;
      my $q    = URI->new;
      $q->query($request->args);
      my $params = $q->query_form_hash;
      (my $uri = $request->uri) =~ s/$path$//;
      $self = {response => $request, # Apache API: same object for both
               root_url => $uri,
               path     => $path,
               params   => $params,
             };
      last;
    };

    /^HTTP/ and do { # coming from HTTP::Daemon // server() method above
      $self = {response => $response,
               root_url => "",
               path     => $request->url->path,
               params   => $request->url->query_form_hash,
             };
      last;
    };

    #otherwise (coming from cgi-bin or mod_perl Registry)
    my $q = URI->new;
    $q->query($ENV{QUERY_STRING});
    my $params = $q->query_form_hash;
    $self = {response => undef, 
             root_url => $ENV{SCRIPT_NAME},
             path     => $ENV{PATH_INFO},
             params   => $params,
           };
  }

  bless $self, $class;
}




sub dispatch_request { 
  my ($self) = @_;
  my $path_info = $self->{path};

  # security check : no outside directories
  $path_info =~ m[(\.\.|//|\\|:)] and die "illegal path: $path_info";

  $path_info =~ s[^/][] or return $self->redirect_index;
  for ($path_info) {
    /^$/               and return $self->redirect_index;
    /^index$/          and return $self->index_frameset; 
    /^toc$/            and return $self->main_toc; 
    /^toc\/(.*)$/      and return $self->toc_for($1);   # Ajax calls
    /^script\/(.*)$/   and return $self->serve_script($1);
    /^search$/         and return $self->dispatch_search;
    /^source\/(.*)$/   and return $self->serve_source($1);

    # for debugging
    /^_dirs$/          and return $self->send_html(join "<br>", @search_dirs);

    # file extension : passthrough 
    /\.(\w+)$/         and return $self->serve_file($path_info, $1);

    #otherwise
    return $self->serve_pod($path_info);
  }
}



sub redirect_index {
  my ($self) = @_;
  return $self->send_html(<<__EOHTML__);
<html>
<head>
<script>location='$self->{root_url}/index'</script>
</head>
<body>
<p>
You should have been redirected to 
<a href='$self->{root_url}/index'>$self->{root_url}/index</a>.
</p>
<p>
If this did not happen, you probably don't have Javascript enabled.
Please enable it to take advantage of Pod::POM::Web DHTML features.
</p>
</body>
__EOHTML__
}


sub index_frameset {
  my ($self) = @_;
  return $self->send_html(<<__EOHTML__);
<html>
  <head><title>Perl documentation</title></head>
  <frameset cols="25%, 75%">
    <frame name="tocFrame"     src="toc" ></frame>
    <frame name="contentFrame" src="perl" ></frame>
  </frameset>
</html>
__EOHTML__
}




#----------------------------------------------------------------------
# serving a single file
#----------------------------------------------------------------------

sub serve_source {
  my ($self, $path) = @_;

  my $params = $self->{params};

  # default (if not printing): line numbers and syntax coloring are on
  $params->{print} or  $params->{lines} = $params->{coloring} = 1;

  my @files = $self->find_source($path) or die "No file for '$path'";
  my $mtime = max map {(stat $_)[9]} @files;

  my $display_text;

  foreach my $file (@files) {
    my $text = $self->slurp_file($file);
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
<a href="$self->{root_url}/$path" style="float:right">Doc</a>
__EOHTML__

  return $self->send_html(<<__EOHTML__, $mtime);
<html>
<head>
  <title>Source of $path</title>
  <link href="$self->{root_url}/Alien/GvaScript/lib/GvaScript.css" rel="stylesheet" type="text/css">
  <link href="$self->{root_url}/Pod/Pom/Web/lib/PodPomWeb.css" rel="stylesheet" type="text/css">
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
}


sub serve_file {
  my ($self, $path, $extension) = @_;

  my $fullpath = firstval {-f $_} map {"$_/$path"} @search_dirs
    or die "could not find $path";

  my $mime_type = MIME::Types->new->mimeTypeOf($extension);
  my $content = $self->slurp_file($fullpath);
  my $mtime   = (stat $fullpath)[9];
  $self->send_content({content   => $content, 
                       mtime     => $mtime, 
                       mime_type => $mime_type});
}


sub serve_pod {
  my ($self, $path) = @_;
  $path =~ s[::][/]g; # just in case, if called as /perldoc/Foo::Bar

  # if several sources, will be first *.pod, then *.pm
  my @sources = $self->find_source($path) or die "No file for '$path'";
  my $mtime   = max map {(stat $_)[9]} @sources;
  my $content = $path eq 'perltoc' ? $self->fake_perltoc 
                                   : $self->slurp_file($sources[0]);

  my $version = @sources > 1 
    ? $self->parse_version($self->slurp_file($sources[-1])) 
    : $self->parse_version($content);

  for my $filter (@podfilters) {
    $filter->($content);
  }

  # special handling for perlfunc: change initial C<..> to hyperlinks
  if ($path =~ /\bperlfunc$/) { 
    my $sub = sub {my $txt = shift; $txt =~ s[C<(.*?)>][C<L</$1>>]g; $txt};
    $content =~ s[(Perl Functions by Category)(.*?)(Alphabetical Listing)]
                 [$1 . $sub->($2) . $3]es;
  }

  my $parser = Pod::POM->new;
  my $pom = $parser->parse_text($content) or die $parser->error;
  (my $mod_name = $path) =~ s[/][::]g;
  my $view = $self->mk_view(version         => $version,
                            mtime           => $mtime,
                            path            => $path,
                            mod_name        => $mod_name,
                            syntax_coloring => $coloring_package);

  my $html = $view->print($pom);

  # again special handling for perlfunc : ids should be just function names
  if ($path =~ /\bperlfunc$/) { 
    $html =~ s/li id="(.*?)_.*?"/li id="$1"/g;
  }

  # special handling for 'perl' : hyperlinks to man pages
  if ($path =~ /\bperl$/) { 
    my $sub = sub {my $txt = shift;
                   $txt =~ s[(perl\w+)]
                            [<a href="$self->{root_url}/$1">$1</a>]g;
                   return $txt};
    $html =~ s[(<pre.*?</pre>)][$sub->($1)]egs;
  }

  return $self->send_html($html, $mtime);
}

sub fake_perltoc {
  my ($self) = @_;

  return "=head1 NAME\n\nperltoc\n\n=head1 DESCRIPTION\n\n"
       . "I<Sorry, this page cannot be displayed in HTML by Pod:POM::Web "
       . "(too many nodes and HTML ids -- will eat all your CPU). "
       . "If you really need it, please consult the source.>";
}




sub serve_script {
  my ($self, $path) = @_;

  my $fullpath;

 DIR:
  foreach my $dir (@script_dirs) {
    foreach my $ext ("", ".pl", ".bat") {
      $fullpath = "$dir/$path$ext";
      last DIR if -f $fullpath;
    }
  }

  $fullpath or die "no such script : $path";

  my $content = $self->slurp_file($fullpath);
  my $mtime   = (stat $fullpath)[9];

  for my $filter (@podfilters) {
    $filter->($content);
  }

  my $parser = Pod::POM->new;
  my $pom    = $parser->parse_text($content) or die $parser->error;
  my $view   = $self->mk_view(path            => "scripts/$path",
                              mtime           => $mtime,
                              syntax_coloring => $coloring_package);
  my $html   = $view->print($pom);

  return $self->send_html($html, $mtime);
}






sub find_source {
  my ($self, $path) = @_;

  # serving a script ?    # TODO : factorize common code with serve_script
  if ($path =~ s[^scripts/][]) {
  DIR:
    foreach my $dir (@script_dirs) {
      foreach my $ext ("", ".pl", ".bat") {
        -f "$dir/$path$ext" or next;
        return "$dir/$path$ext";
      }
    }
    return;
  }

  # otherwise, serving a module
  foreach my $prefix (@search_dirs) {
    my @found = grep  {-f} ("$prefix/$path.pod", 
                            "$prefix/$path.pm", 
                            "$prefix/pod/$path.pod",
                            "$prefix/pods/$path.pod");
    return @found if @found;
  }
  return;
}





sub pod2pom {
  my ($self, $sourcefile) = @_;
  my $content = $self->slurp_file($sourcefile);

  for my $filter (@podfilters) {
    $filter->($content);
  }

  my $parser = Pod::POM->new;
  my $pom = $parser->parse_text($content) or die $parser->error;
  return $pom;
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
  delete $entries->{$_} for @ignore_toc_dirs; 
  delete $entries->{$_} for grep {/^perl/ or !/^[[:lower:]]/} keys %$entries;

  return $self->send_html($self->htmlize_entries($entries));
}


sub toc_scripts {
  my ($self) = @_;

  my %scripts;

  # gather all scripts and group them by initial letter
  foreach my $dir (@script_dirs) {
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

  foreach my $root_dir (@search_dirs) {
    my $dirname = $prefix ? "$root_dir/$prefix" : $root_dir;
    opendir my $dh, $dirname or next;
    foreach my $name (readdir $dh) {
      next if $name =~ /^\./;
      next if $filter and $name !~ $filter;
      my $is_dir  = -d "$dirname/$name";
      my $has_pod = $name =~ s/\.(pm|pod)$//;

      # skip if this subdir is a member of @INC (not a real module namespace)
      next if $is_dir and grep {m[^\Q$dirname/$name\E]} @search_dirs;

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
  my $source  = $self->slurp_file($self->find_source("perl"));
  my $perlpom = $parser->parse_text($source) or die $parser->error;

  my ($synopsis) = grep {$_->title eq 'SYNOPSIS'} $perlpom->head1();

  my $html = "";

  # classified pages mentioned in the synopsis
  foreach my $h2 ($synopsis->head2) {
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
    my %args = (class => 'TN_leaf',
                label => $name, 
                attrs => '');
    if ($entry->{dir}) {
      $args{class} = 'TN_node TN_closed';
      $args{attrs} = qq{TN:contentURL='toc/$entry->{node}'};
    }
    if ($entry->{pod}) {
      $args{href}     = $entry->{node};
      $args{abstract} = $self->get_abstract($entry->{node});
      (my $id = $entry->{node}) =~ s[/][::]g;
      $args{attrs}   .= qq{id='$id'};
    }
    $html .= generic_node(%args);
  }
  return $html;
}

sub get_abstract {
  # override in indexer
}




sub main_toc { 
  my ($self) = @_;

  # perlfunc entries in JSON format for the DHTML autocompleter
  my @funcs = map {$_->title} grep {$_->content =~ /\S/} $self->perlfunc_items;
  s|[/\s(].*||s foreach @funcs;
  my $json_funcs = "[" . join(",", map {qq{"$_"}} uniq @funcs) . "]";
  my $js_no_indexer = $no_indexer ? 'true' : 'false';

  my $perldocs = closed_node(label       => "Perl docs",
                             label_class => "TN_label small_title",
                             attrs       =>  qq{TN:contentURL='toc/perldocs'});
  my $pragmas  = closed_node (label       => "Pragmas",
                              label_class => "TN_label small_title",
                              attrs       =>  qq{TN:contentURL='toc/pragmas'});
  my $scripts  = closed_node (label       => "Scripts",
                              label_class => "TN_label small_title",
                              attrs       =>  qq{TN:contentURL='toc/scripts'});
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
  <link href="$self->{root_url}/Alien/GvaScript/lib/GvaScript.css" 
        rel="stylesheet" type="text/css">
  <link href="$self->{root_url}/Pod/Pom/Web/lib/PodPomWeb.css" 
        rel="stylesheet" type="text/css">
  <script src="$self->{root_url}/Alien/GvaScript/lib/prototype.js"></script>
  <script src="$self->{root_url}/Alien/GvaScript/lib/GvaScript.js"></script>
  <script>
    var treeNavigator;
    var perlfuncs = $json_funcs;
    var completers = {};
    var no_indexer = $js_no_indexer;

    function submit_on_event(event) {
        \$('search_form').submit();
    }

    function resize_tree_navigator() {
      var height = document.body.clientHeight
                 - \$('toc_frame_top').scrollHeight -5;
      \$('TN_tree').style.height = height + "px";
    }

    function setup() {

      treeNavigator 
        = new GvaScript.TreeNavigator('TN_tree', {tabIndex:-1});

      completers.perlfunc = new GvaScript.AutoCompleter(
             perlfuncs, 
             {minimumChars: 1, minWidth: 100, offsetX: -20});
      completers.perlfunc.onComplete = submit_on_event;
      if (!no_indexer) {
        completers.modlist  = new GvaScript.AutoCompleter(
             "search?source=modlist&search=", 
             {minimumChars: 2, minWidth: 100, offsetX: -20, typeAhead: false});
        completers.modlist.onComplete = submit_on_event;
      }

      resize_tree_navigator();
      \$('search_form').search.focus();
    }
    window.onload = setup;
    window.onresize = resize_tree_navigator;

    function displayContent(event) {
        var label = event.controller.label(event.target);
        if (label && label.tagName == "A") {
          label.focus();
          return Event.stopNone;
        }
    }

    function selectToc(entry) {
      var node = \$(entry);
      if (!node) {
        var initial = entry.substr(0, 1);
        if (initial <= 'Z') 
           node = \$(initial + ":");
      }
      if (node && treeNavigator) treeNavigator.select(node);
    }

   function maybe_complete(input) {
     if (input._autocompleter)
        input._autocompleter.detach(input);

     switch (input.form.source.selectedIndex) {
       case 0: completers.perlfunc.autocomplete(input); break;
       case 2: if (!no_indexer)
                 completers.modlist.autocomplete(input); 
               break;
     }
   }


  </script>
  <style>
   .small_title {color: midnightblue; font-weight: bold; padding: 0 3 0 3}
   FORM     {margin:0px}
   BODY     {margin:0px; font-size: 70%}
   BODY     {margin:0px; font-size: 70%; overflow-x: hidden} 
   DIV      {margin:0px; width: 100%}
   #TN_tree {overflow-y:scroll; overflow-x: hidden}
  </style>
</head>
<body>

<div id='toc_frame_top'>
<div class="small_title" 
     style="text-align:center;border-bottom: 1px solid">
Perl Documentation
</div>
<div style="text-align:right">
<a href="Pod/POM/Web/Help" class="small_title">Help</a>
</div>

<form action="search" id="search_form" method="get">
<span class="small_title">Search in</span>
     <select name="source">
      <option>perlfunc</option>
      <option>perlfaq</option>
      <option>modules</option>
      <option>fulltext</option>
     </select><br>
<span class="small_title">&nbsp;for</span><input 
         name="search" size="15"
         autocomplete="off"
         onfocus="maybe_complete(this)">
</form>
<br>
<div class="small_title"
     style="border-bottom: 1px solid">Browse
</div>
</div>

<!-- In principle the tree navigator below would best belong in a 
     different frame, but instead it's in a div because the autocompleter
     from the form above sometines needs to overlap the tree nav. -->
<div id='TN_tree' onPing='displayContent'>
$perldocs
$pragmas
$scripts
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
  my ($self) = @_;

  my $params = $self->{params};
  my $source = $params->{source};
  my $method = {perlfunc => 'perlfunc',
                perlfaq  => 'perlfaq',
                modules  => 'serve_pod',
                fulltext => 'fulltext', 
                modlist  => 'modlist', 
                }->{$source}  or die "cannot search in '$source'";

  if ($method =~ /fulltext|modlist/ and $no_indexer) {
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
    my $funcpom = $self->pod2pom($self->find_source("perlfunc"));
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
     or return print("No documentation found for perl function '$func'");
  my $view    = $self->mk_view(path => "perlfunc/$func");

  my @li_items = map {$_->present($view)} @items;
  return $self->send_html(<<__EOHTML__);
<html>
<head>
  <link href="$self->{root_url}/Pod/Pom/Web/lib/PodPomWeb.css" rel="stylesheet" type="text/css">
</head>
<body>
<h2>Extract from <a href="$self->{root_url}/perlfunc">perlfunc</a></h2>

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
    my $faqpom = $self->pod2pom($self->find_source("perlfaq$num"));
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
  <link href="$self->{root_url}/Alien/GvaScript/lib/GvaScript.css" rel="stylesheet" type="text/css">
  <link href="$self->{root_url}/Pod/Pom/Web/lib/PodPomWeb.css" rel="stylesheet" type="text/css">
  <script src="$self->{root_url}/Alien/GvaScript/lib/prototype.js"></script>
  <script src="$self->{root_url}/Alien/GvaScript/lib/GvaScript.js"></script>
  <script>
    var treeNavigator;
    function setup() {  
      treeNavigator = new GvaScript.TreeNavigator('TN_tree');
    }
    window.onload = setup;
   </script>
</head>
<body>
<h1>Extracts from <a href="$self->{root_url}/perlfaq">perlfaq</a></h1><br>
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
    root_url        => $self->{root_url},
    %args
   );

  return $view;
}



sub send_html {
  my ($self, $html, $mtime) = @_;
  $self->send_content({content => $_[1], code => 200, mtime => $mtime});
}



sub send_content {
  my ($self, $args) = @_;
  my $encoding  = guess_encoding($args->{content}, qw/ascii utf8 latin1/);
  my $charset   = ref $encoding ? $encoding->name : "";
     $charset   =~ s/^ascii/US-ascii/; # Firefox insists on that imperialist name
  my $length    = length $args->{content};
  my $mime_type = $args->{mime_type} || "text/html";
     $mime_type .= "; charset=$charset" if $charset and $mime_type =~ /html/;
  my $modified  = gmtime $args->{mtime};
  my $code      = $args->{code} || 200;

  my $r = $self->{response};
  for (ref $r) {

    /^Apache/ and do {
      require Apache2::Response;
      $r->content_type($mime_type);
      $r->set_content_length($length);
      $r->set_last_modified($args->{mtime}) if $args->{mtime};
      $r->print($args->{content});
      return;
    };

    /^HTTP::Response/ and do {
      $r->code($code);
      $r->header(Content_type   => $mime_type,
                 Content_length => $length);
      $r->header(Last_modified  => $modified) if $args->{mtime};
      $r->add_content($args->{content});
      return;
    };

    # otherwise (cgi-bin)
    my $headers = "Content-type: $mime_type\nContent-length: $length\n";
    $headers .= "Last-modified: $modified\n" if  $args->{mtime};
    binmode(STDOUT);
    print "$headers\n$args->{content}";
    return;
  }
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
    $args{abstract} =~ s/([&<>"])/$escape_entity{$1}/g;
    $label_attrs .= qq{ title="$args{abstract}"};
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
  my ($self, $file) = @_;
  open my $fh, $file or die "open $file: $!";
  binmode($fh, ":crlf");
  local $/ = undef;
  return <$fh>;
}



# parse_version: code copied and adapted from Module::Build::ModuleInfo,
# but working on in-memory string instead of opening the file
my $VARNAME_REGEXP = qr/ # match fully-qualified VERSION name
  ([\$*])         # sigil - $ or *
  (
    (             # optional leading package name
      (?:::|\')?  # possibly starting like just :: (ala $::VERSION)
      (?:\w+(?:::|\'))*  # Foo::Bar:: ...
    )?
    VERSION
  )\b
/x;

my $VERS_REGEXP = qr/ # match a VERSION definition
  (?:
    \(\s*$VARNAME_REGEXP\s*\) # with parens
  |
    $VARNAME_REGEXP           # without parens
  )
  \s*
  =[^=~]  # = but not ==, nor =~
/x;




sub parse_version {
  # my ($self, $content) = @_ # don't copy $content for efficiency, use $_[1]
  my $result;
  my $in_pod = 0;
  while ($_[1] =~ /^.*$/mg) { # $_[1] is $content
    my $line = $&;
    chomp $line;
    next if $line =~ /^\s*#/;
    $in_pod = $line =~ /^=(?!cut)/ ? 1 : $line =~ /^=cut/ ? 0 : $in_pod;

    # Would be nice if we could also check $in_string or something too
    last if !$in_pod && $line =~ /^__(?:DATA|END)__$/;

    next unless $line =~ $VERS_REGEXP;
    my( $sigil, $var, $pkg ) = $2 ? ( $1, $2, $3 ) : ( $4, $5, $6 );
    $line =~ s/\bour\b//;
    my $eval = qq{q#  Hide from _packages_inside()
                   #; package Pod::POM::Web::_version;
                   no strict;
                   local $sigil$var;
                    \$$var=undef; do { $line }; \$$var
                 };
    no warnings;
    $result = eval($eval) || "";
  }
  return $result;
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
no warnings 'uninitialized';
use base qw/ Pod::POM::View::HTML /;
use POSIX  qw/strftime/; # date formatting


sub view_seq_link_transform_path {
    my($self, $page) = @_;
    $page =~ s[::][/]g;
    return "$self->{root_url}/$page";
}

sub view_seq_link {# override because SUPER does a nice job, but not fully
    my ($self, $link) = @_;
    my $linked        = $self->SUPER::view_seq_link($link);
    my ($u, $t) = 
      my ($url, $title) = ($linked =~ m[^<a href="(.*?)">(.*)</a>]); # reparse
    $url   =~ s[#(.*)]['#' . _title_to_id($1)]e;
    $title =~ s[^(.*?)/(.*)$][$1 ? "$2 in $1" : $2]e 
      unless ($title =~ m{^\w+://}s); # full-blown URL
    return qq{<a href="$url">$title</a>}; #  [$u] [$t] [$1] [$2]
}


sub view_over {
  my ($self, $over) = @_;
  # This is a fix for AnnoCPAN POD which routinely has
  #    =over \n =over \n ... \n =back \n =back
  # Pod::POM::HTML omits =over blocks that lack =items.  The code below 
  # detects the omission and adds it back, wrapped in an indented block.
  my $content = $self->SUPER::view_over($over);
  if ($content eq "") {
    my $overs = $over->over();
    if (@$overs) {
      $content = join '', map {$self->view_over($_)} @$overs;
      if ($content =~ /AnnoCPAN/) {
        $content = "<div class='AnnoCPAN'>$content</div>";
      }
    }

  }
  return $content;
}


sub view_item {
  my ($self, $item) = @_;

  my $title   = eval {$item->title->present($self)} || "";
     $title   = "" if $title =~ /^\s*\*\s*$/; 
  my $id      = _title_to_id($title);
  my $li      = $id ? qq{<li id="$id">} : qq{<li>};
  my $content = $item->content->present($self);
     $title   = qq{<b>$title</b>} if $title;
  return qq{$li$title\n$content</li>\n};
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

  # parse name and description
  my ($name_h1) = grep {$_->title =~ /^NAME\b/} $pom->head1();
  my $doc_title = $name_h1 ? $name_h1->content : 'Untitled';
  $doc_title =~ s/<.*?>//g; # no HTML tags
  my ($name, $description) = ($doc_title =~ /^\s*(.*?)\s+-+\s+(.*)/);
  $name ||= $doc_title;

  # version and installation date
  my $version   = $self->{version} ? "v. $self->{version}, " : ""; 
  my $installed = strftime("%x", localtime($self->{mtime}));

  # is this module in Perl core ?
  my $core_release = Module::CoreList->first_release($self->{mod_name}) || "";
  my $orig_version 
         = $Module::CoreList::version{$core_release}{$self->{mod_name}} || "";
  $orig_version &&= "v. $orig_version ";
  $core_release &&= "; ${orig_version}entered Perl core in $core_release";

  my $cpan_info = "";
  if ($has_cpan) {
    my $mod = CPAN::Shell->expand("Module", $self->{mod_name});
    if ($mod) {
      my $cpan_version = $mod->cpan_version;
      $cpan_info = "; CPAN has v. $cpan_version" if $cpan_version ne $self->{version};
    }
  }

  # compute view
  my $content = $pom->content->present($self);
  my $toc = $self->make_toc($pom, 0); 
  return <<__EOHTML__
<html>
<head>
  <title>$name</title>
  <link href="$self->{root_url}/Alien/GvaScript/lib/GvaScript.css" rel="stylesheet" type="text/css">
  <link href="$self->{root_url}/Pod/Pom/Web/lib/PodPomWeb.css" rel="stylesheet" type="text/css">
  <script src="$self->{root_url}/Alien/GvaScript/lib/prototype.js"></script>
  <script src="$self->{root_url}/Alien/GvaScript/lib/GvaScript.js"></script>
  <script>
    var treeNavigator;
    function setup() {  
      new GvaScript.TreeNavigator(
         'TN_tree', 
         {selectFirstNode: (location.hash ? false : true),
          tabIndex: 0}
      );

     var tocFrame = window.parent.frames.tocFrame;
     if (tocFrame) tocFrame.eval("selectToc('$name')");
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
   <a href="$self->{root_url}/source/$self->{path}">Source</a><br>
   <a href="http://search.cpan.org/perldoc/$self->{mod_name}"
      target="_blank">CPAN</a> |
   <a href="http://www.annocpan.org/?mode=search&field=Module&name=$self->{mod_name}"
      target="_blank">Anno</a> |
   <a href="http://www.cpanforum.com/search/?what=modulee&name=$self->{mod_name}"
      target="_blank">Forum</a> |
   <a href="http://cpan.uwinnipeg.ca/search/?mode=modulee&query=$self->{mod_name}"
      target="_blank">Kobes</a>
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
    $text =~ s/([&<>"])/$Pod::POM::Web::escape_entity{$1}/g;
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
    $text =~ s/([&<>"])/$Pod::POM::Web::escape_entity{$1}/g;
    return $text;
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

fulltext search, including names of Perl variables
(this is an optional feature -- see section L</"Optional features">).

=item *

parsing and display of version number

=item *

display if and when the displayed module entered Perl core.

=item *

parsing pod links and translating them into hypertext links

=item *

links to CPAN sites

=back



The DHTML code for navigating through documentation trees requires a
modern browser. So far it has been tested on Microsoft Internet
Explorer 6.0 and Firefox 2.0

=head1 USAGE

Usage is described in a separate document 
L<Pod::POM::Web::Help>.

=head1 INSTALLATION

=head2 Starting the Web application

Once the code is installed (most probably through
L<CPAN> or L<CPANPLUS>), you have to configure
the web server :

=head3 As a mod_perl service

The recommended way to run this application is within
a mod_perl environment. If you have Apache2 
with mod_perl 2.0, then edit your 
F<perl.conf> as follows :

  PerlModule Apache2::RequestRec
  PerlModule Apache2::RequestIO
  <Location /perldoc>
        SetHandler modperl
        PerlResponseHandler Pod::POM::Web->handler
  </Location>

Then navigate to URL L<http://localhost/perldoc>.

=head3 As a cgi-bin script 

Alternatively, you can run this application as a cgi-script
by writing a simple file in your C<cgi-bin> directory, like this :

  #!/path/to/perl
  use Pod::POM::Web;
  Pod::POM::Web->handler;

The same can be done for running under mod_perl Registry
(write the same script as above and put it in your
Apache/perl directory). However, this does not make much sense,
because if you have mod_perl Registry then you could as well
run it as a basic mod_perl handler.

=head3 As a standalone server

A third way to use this application is to start a process invoking
the builtin HTTP server :

  perl -MPod::POM::Web -e "Pod::POM::Web->server"

This is useful if you have no other HTTP server, or if
you want to run this module under the perl debugger.


=head2 Note about security

This application is intended as a power tool for Perl developers, 
not as an Internet application. It will display the documentation and source
code of any module installed under your C<@INC> path or
Apache C<lib/perl> directory, so it is probably a B<bad idea>
to put it on a public Internet server.

=head2 Optional features

=head3 Syntax coloring

Syntax coloring improves readability of code excerpts.
If your Perl distribution is from ActiveState, then 
C<Pod::POM::Web> will take advantage 
of the L<ActiveState::Scineplex> module
which is already installed on your system. Otherwise,
you need to install L<PPI::HTML>, available from CPAN.

=head3 Fulltext indexing

C<Pod::POM::Web> can index the documentation and source code
of all your installed modules, including Perl variable names, 
C<Names:::Of::Modules>, etc. To use this feature you need to 

=over

=item *

install L<Search::Indexer> from CPAN

=item *

build the index as described in L<Pod::POM::Web::Indexer> documentation.

=back



=head3 AnnoCPAN comments

The website L<http://annocpan.org/> lets people add comments to the
documentation of CPAN modules.  The AnnoCPAN database is freely
downloadable and can be easily integrated with locally installed
modules via runtime filtering.

If you want AnnoCPAN comments to show up in Pod::POM::Web, do the following:

=over

=item *

install L<AnnoCPAN::Perldoc> from CPAN;

=item *

download the database from L<http://annocpan.org/annopod.db> and save
it as F<$HOME/.annocpan.db> (see the documentation in the above module
for more details).  You may also like to try
L<AnnoCPAN::Perldoc::SyncDB> which is a crontab-friendly tool for
periodically downloading the AnnoCPAN database.

=back


=head1 AUTHORING

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

Thanks to BooK who mentioned a weakness in the API, to Chris Dolan who
supplied many useful suggestions and patches (esp. integration with
AnnoCPAN), to Rémi Pauchet who pointed out a regression bug with
Firefox CSS, and to Alexandre Jousset who fixed a bug in the 
TOC display.


=head1 RELEASE NOTES

Indexed information since version 1.04 is not compatible 
with previous versions.

So if you upgraded from a previous version and want to use 
the index, you need to rebuild it entirely, by running the 
command :

  perl -MPod::POM::Web::Indexer -e "Pod::POM::Web::Indexer->new->index(-from_scratch => 1)"


=head1 BUGS

Please report any bugs or feature requests to
C<bug-pod-pom-web at rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Pod-POM-Web>.
I will be notified, and then you'll automatically be notified of progress on
your bug as I make changes.


=head1 AUTHOR

Laurent Dami, C<< <laurent.d...@justice.ge.ch> >>


=head1 COPYRIGHT & LICENSE

Copyright 2007 Laurent Dami, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=head1 TODO

  - XUL error message for CSS
   - real tests !
  - checks and fallback solution for systems without perlfunc and perlfaq
  - factorization (esp. initial <head> in html pages)
  - use Getopts to choose colouring package, toggle CPAN, etc.
  - declare bugs 
      - SQL::Abstract, nonempty line #337
      - LWP: item without '*'
      - CPAN : C<CPAN::WAIT> in L<..> 
      - perlre : line 940, code <I ...> parsed as I<...>
      - =head1 NAME B<..> in Data::ShowTable
