package Pod::POM::Web;
use strict;
use warnings;
no warnings 'uninitialized';

use Pod::POM;                   # for parsing Pod
use List::MoreUtils qw/uniq/;
use Module::CoreList;           # for asking if a module belongs to Perl core
use HTTP::Daemon;               # for the builtin HTTP server
use URI;                        # for parsing incoming requests
use URI::QueryParam;


#----------------------------------------------------------------------
# globals
#----------------------------------------------------------------------

our $VERSION = '0.01';

# some subdirs never contain Pod documentation
my @ignore_toc_dirs = qw/auto unicore/; 

# filter @INC (don't want '.', nor server_root added by mod_perl)
my $server_root = eval {Apache2::ServerUtil::server_root()} || "";
our @search_dirs = grep {$_ ne '.' && $_ ne $server_root} @INC;

my $coloring_package = eval {require ActiveState::Scineplex} ? "SCINEPLEX"
                     : eval {require PPI::HTML}              ? "PPI" : "";

my $has_indexer = eval {require Pod::POM::Web::Indexer};



#----------------------------------------------------------------------
# main entry point
#----------------------------------------------------------------------

sub server { # builtin HTTP server; unused if running under Apache
  my $class = shift;

  my $port = $ARGV[0] || 8080;

  my $d = HTTP::Daemon->new(LocalPort => $port) || die "could not start daemon";
  print STDERR "Please contact me at: <URL:", $d->url, ">\n";
  while (my $c = $d->accept) {
    while (my $req = $c->get_request) {
      print STDERR "URL : " , $req->url, "\n";
      my $response = HTTP::Response->new;
      $class->handler($req, $response);
      $c->send_response($response);
    }
    $c->close;
    undef($c);
  }
}


sub handler : method  {
  my ($class, $request, $response) = @_; 
  my $self = $class->new($request, $response);
  eval { $self->dispatch_request(); 1}  or $self->send_html($@);
  return 0; # Apache2::Const::OK;
}


sub new  {
  my ($class, $request, $response) = @_; 
  my $self;

  # cheat: will create an instance of the subclass if possible
  if ($has_indexer && $class eq __PACKAGE__) {
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
    /^lib\/(.*)$/      and return $self->lib_file($1);  # css, js, gif
    /^search$/         and return $self->dispatch_search;
    /^source\/(.*)$/   and return $self->serve_source($1);

    # for debugging
    /^_dirs$/          and return $self->send_html(join "<br>", @search_dirs);

    #otherwise
    return $self->serve_pod($path_info);
  }
}



sub redirect_index {
  my ($self) = @_;
  return $self->send_html("<script>location='$self->{root_url}/index'</script>");
}



sub index_frameset {
  my ($self) = @_;
  return $self->send_html(<<__EOHTML__);
<html>
  <head><title>Perl documentation</title></head>
  <frameset cols="25%, 75%">
    <frame name="tocFrame"     src="toc"></frame>
    <frame name="contentFrame" src="perlintro"></frame>
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
  my $display_text;

  foreach my $file (@files) {
    my $text = $self->slurp_file($file);
    my $view = Pod::POM::View::HTML::_PerlDoc->new(
     syntax_coloring => $params->{coloring} ? $coloring_package : "",
     line_numbering  => $params->{lines},
    );
    $text = $view->view_verbatim($text);
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

  my $lib = "$self->{root_url}/lib";
  return $self->send_html(<<__EOHTML__);
<html>
<head>
  <link href="$lib/GvaScript.css" rel="stylesheet" type="text/css">
  <link href="$lib/PodPomWeb.css" rel="stylesheet" type="text/css">
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



sub serve_pod {
  my ($self, $path) = @_;
  $path =~ s[::][/]g; # just in case, if called /perldoc/Foo::Bar

  # if several sources, will be first *.pod, then *.pm
  my @sources = $self->find_source($path) or die "No file for '$path'";
  my $content = $self->slurp_file($sources[0]);

  my $version = @sources > 1 
    ? $self->parse_version($self->slurp_file($sources[-1])) 
    : $self->parse_version($content);
  $version &&= " <small>$version</small>";

  # Pod::POM fails to parse correctly when there is an initial blank line
  $content =~ s/^\s*//; 

  # special handling for perlfunc: change initial C<..> to hyperlinks
  if ($path eq 'perlfunc') { 
    sub C_to_L {my $txt = shift; $txt =~ s[C<(.*?)>][C<L</$1>>]g; $txt}
    $content =~ s[(Perl Functions by Category)(.*?)(Alphabetical Listing)]
                 [$1 . C_to_L($2) . $3]es;
  }

  my $parser = Pod::POM->new;
  my $pom = $parser->parse_text($content) or die $parser->error;
  (my $mod_name = $path) =~ s[/][::];
  my $view = Pod::POM::View::HTML::_PerlDoc->new(
    version         => $version,
    root_url        => $self->{root_url},
    path            => $path,
    mod_name        => $mod_name,
    syntax_coloring => $coloring_package,
   );

  my $html = $view->print($pom);

  # again special handling for perlfunc : ids should be just function names
  $html =~ s/li id="(.*?)_.*?"/li id="$1"/g if $path eq 'perlfunc';

  return $self->send_html($html);
}


sub find_source {
  my ($self, $path) = @_;

  foreach my $prefix (@search_dirs) {
    my @found = grep  {-f} ("$prefix/$path.pod", 
                            "$prefix/$path.pm", 
                            "$prefix/pod/$path.pod",
                            "$prefix/pods/$path.pod");
    return @found if @found;
  }
  return undef;
}

sub pod2pom {
  my ($self, $sourcefile) = @_;
  my $content = $self->slurp_file($sourcefile);
  my $parser = Pod::POM->new;
  my $pom = $parser->parse_text($content) or die $parser->error;
  return $pom;
}

#----------------------------------------------------------------------
# tables of contents
#----------------------------------------------------------------------


sub toc_for { # partial toc (called through Ajax)
  my ($self, $prefix) = @_;
  my $entries = $self->find_entries_for($prefix);

  # Pod/perl* should not appear under Pod, but at root level
  if ($prefix eq 'Pod') {
    foreach my $k (keys %$entries) {
      delete $entries->{$k} if $k =~ /^perl/;
    }
  }

  return $self->send_html($self->htmlize_entries($entries));
}



sub main_toc { # 
  my ($self) = @_;
  my $entries  = $self->find_entries_for("");    # files found at root level
  my (%pragmas, %modules);
  my $perldocs = $self->find_entries_for("pod"); # perldocs are under pod/perl*

  # classify entries in 3 sections (perldocs, pragmas, modules)
  foreach my $k (keys %$entries) { 
    my $which = $k =~ /^perl/        ? $perldocs : 
                $k =~ /^[[:lower:]]/ ? \%pragmas : \%modules;
    $which->{$k} = delete $entries->{$k};
  }
  foreach my $k (keys %$perldocs) {
    if ($k =~ /^perl/) {
      $perldocs->{$k}{node} =~ s[^[pP]od/][];
    }
    else {
      delete $perldocs->{$k};
    } 
  }
  delete $pragmas{$_} foreach @ignore_toc_dirs; 

  return $self->wrap_main_toc($self->htmlize_perldocs($perldocs),
                              $self->htmlize_entries(\%pragmas),
                              $self->htmlize_entries(\%modules));
}



sub find_entries_for {
  my ($self, $prefix) = @_;
  my %entries;
  foreach my $root_dir (@search_dirs) {
    my $dirname = $prefix ? "$root_dir/$prefix" : $root_dir;
    opendir my $dh, $dirname or next;
    foreach my $name (readdir $dh) {
      next if $name =~ /^\./;
      my $is_dir  = -d "$dirname/$name";
      my $has_pod = $name =~ s/\.(pm|pod)$//;
      if ($is_dir || $has_pod) {
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

  # Pod/perl.pom Synopsis contains a classification of perl*.pod documents

  my $parser  = Pod::POM->new;
  my $source  = $self->slurp_file($self->find_source("perl"));
  my $perlpom = $parser->parse_text($source) or die $parser->error;

  my ($synopsis) = grep {$_->title eq 'SYNOPSIS'} $perlpom->head1();

  my $html = "";
  foreach my $h2 ($synopsis->head2) {
    my $title   = $h2->title;
    my $content = $h2->verbatim;
    my @refs    = ($content =~ /^\s*(perl\S*?)\s*\t/gm);

    my $leaves = "";
    foreach my $ref (@refs) {
      my $entry = delete $perldocs->{$ref} or next;
      $leaves .= leaf(label => $ref, href  => $entry->{node});
    }
    $html .= closed_node(label   => "<b>$title</b>", 
                         content => $leaves);

  }

  $html .= closed_node(label   => '<b>Unclassified</b>', 
                       content => htmlize_entries($perldocs));

  return $html;
}




sub htmlize_entries {
  my ($self, $entries) = @_;
  my $html = "";
  foreach my $name (sort {uc($a) cmp uc($b)} keys %$entries) {
    my $entry = $entries->{$name};
    my %args = (class => 'TN_leaf',
                label => $name);
    if ($entry->{dir}) {
      $args{class} = 'TN_node TN_closed';
      $args{attrs} = qq{TN:contentURL='toc/$entry->{node}'};
    }
    $args{href} = $entry->{node} if $entry->{pod};
    $html .= generic_node(%args);
  }
  return $html;
}


sub wrap_main_toc {
  my ($self, $perldocs, $pragmas, $modules) = @_;

  $perldocs = generic_node(label       => "Perl docs",
                           label_class => "TN_label small_title",
                           content     => $perldocs);
  $pragmas  = closed_node (label       => "Pragmas",
                           label_class => "TN_label small_title",
                           content     => $pragmas);
  $modules  = closed_node (label       => "Modules",
                           label_class => "TN_label small_title",
                           content     => $modules);
  my @funcs = map {$_->title} grep {$_->content =~ /\S/} $self->perlfunc_items;
  s|[/\s(].*||s foreach @funcs;
  my $json_funcs = "[" . join(",", map {qq{"$_"}} uniq @funcs) . "]";
  my $js_has_indexer = $has_indexer ? 'true' : 'false';
  return $self->send_html(<<__EOHTML__);
<html>
<head>
  <base target="contentFrame">
  <link href="lib/GvaScript.css" rel="stylesheet" type="text/css">
  <link href="lib/PodPomWeb.css" rel="stylesheet" type="text/css">
  <script src="lib/prototype.js"></script>
  <script src="lib/GvaScript.js"></script>
  <script>
    var perlfuncs = $json_funcs;
    var treeNavigator;
    var completers = {};
    var has_indexer = $js_has_indexer;

    function setup() {
      treeNavigator 
        = new GvaScript.TreeNavigator('TN_tree', {tabIndex:0});
      completers.perlfunc = new GvaScript.AutoCompleter(
             perlfuncs, 
             {minimumChars: 1, minWidth: 100, offsetX: -20});
      if (has_indexer)
        completers.modlist  = new GvaScript.AutoCompleter(
             "search?source=modlist&search=", 
             {minimumChars: 2, minWidth: 100, offsetX: -20, typeAhead: false});

    }
    window.onload = setup;

   function maybe_complete(input) {
     if (input._autocompleter)
        input._autocompleter.detach(input);

     switch (input.form.source.selectedIndex) {
       case 0: completers.perlfunc.autocomplete(input); break;
       case 2: if (has_indexer)
                 completers.modlist.autocomplete(input); 
               break;
     }
   }

    function displayContent(event) {
        var label = event.controller.label(event.target);
        if (label && label.tagName == "A") {
          label.focus();
          return Event.stopNone;
        }
    }
  </script>
  <style>
   .small_title {color: midnightblue; font-weight: bold; padding: 0 3 0 3}
   FORM     {margin:0px}
   BODY     {margin:0px; font-size: 70%; overflow-x: hidden} 
   #TN_tree {height: 80%; 
             overflow-y:scroll; 
             overflow-x: hidden}
  </style>
</head>
<body>

<div class="small_title" 
     style="width:100%; text-align:center;border-bottom: 1px solid">
Perl Documentation
</div>
<a href="Pod/POM/Web/Help" class="small_title" style="float:right">Help</a>
<br><span class="small_title">Search in</span>
<form action="search" method="get">
     <select name="source">
      <option>perlfunc</option>
      <option>perlfaq</option>
      <option>modules</option>
      <option>fulltext</option>
     </select><span class="small_title">for</span><input 
         name="search" size="9"
         autocomplete="off"
         onfocus="maybe_complete(this)">
</form>
<br>
<div class="small_title"
     style="width:100%; border-bottom: 1px solid">Browse
</div>

<div id='TN_tree' onPing='displayContent'>
$perldocs
$pragmas
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

  if ($method =~ /fulltext|modlist/ and not $has_indexer) {
    die "please ask your system administrator to install "
      . "<b>Search::Indexer</b> in order to use this method";
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
  my $view    = Pod::POM::View::HTML::_PerlDoc->new(
    root_url => $self->{root_url},
    path     => "perlfunc/$func",
   );

  my @li_items = map {$_->present($view)} @items;
  my $lib = "$self->{root_url}/lib";
  return $self->send_html(<<__EOHTML__);
<html>
<head>
  <link href="$lib/PodPomWeb.css" rel="stylesheet" type="text/css">
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

  my $view    = Pod::POM::View::HTML::_PerlDoc->new(
    root_url => $self->{root_url},
    path     => "perlfaq/$faq_entry",
   );

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

  my $lib = "$self->{root_url}/lib";
  return $self->send_html(<<__EOHTML__);
<html>
<head>
  <link href="$lib/GvaScript.css" rel="stylesheet" type="text/css">
  <link href="$lib/PodPomWeb.css" rel="stylesheet" type="text/css">
  <script src="$lib/prototype.js"></script>
  <script src="$lib/GvaScript.js"></script>
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

sub lib_file {
  my ($self, $filename) = @_;
  (my $full_filename = __FILE__) =~ s[\.pm$][/lib/$filename];
  (my $extension = $filename) =~ s/.*\.//;
  my $mime_type = {html => 'text/html',
                   css  => 'text/css', 
                   js   => 'application/x-javascript',
                   gif  => 'image/gif'}->{$extension}
                     or die "lib_file($filename): unexpected extension";
  my ($content, $mtime) = $self->slurp_file($full_filename);
  $self->send_content({content   => $content, 
                       mtime     => $mtime, 
                       mime_type => $mime_type});
}


sub send_html {
  my ($self, $html) = @_;
  $self->send_content({content => $_[1]});
}



sub send_content {
  my ($self, $args) = @_;
  my $length    = length $args->{content};
  my $mime_type = $args->{mime_type} || "text/html";
  my $modified = gmtime $args->{mtime};

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
  my $mtime = (stat $fh)[9];
  local $/ = undef;
  my $content = <$fh>;
  return wantarray ? ($content, $mtime) : $content;
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




#----------------------------------------------------------------------
# VIEW PACKAGE for Pod::POM::View::HTML
#----------------------------------------------------------------------
package Pod::POM::View::HTML::_PerlDoc;
use strict;
use warnings;
no warnings 'uninitialized';
use base qw/ Pod::POM::View::HTML /;

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

  my ($name_h1) = grep {$_->title =~ /^NAME\b/} $pom->head1();
  my $doc_title = $name_h1 ? $name_h1->content : 'Untitled';
  $doc_title =~ s/<.*?>//g; # no HTML tags

  my ($name, $description) = ($doc_title =~ /^\s*(.*?)\s+-+\s+(.*)/);
  $name ||= $doc_title;

  my $core_release = Module::CoreList->first_release($self->{mod_name}) || "";
  my $orig_version = $Module::CoreList::version{$core_release}{$self->{mod_name}} || "";
     $orig_version &&= "version $orig_version ";

  $core_release &&= "<small>(${orig_version}entered Perl core in $core_release)</small>";

  my $content = $pom->content->present($self);
  my $toc = $self->make_toc($pom, 0);
  my $lib = "$self->{root_url}/lib";
  return <<__EOHTML__
<html>
<head>
  <link href="$lib/GvaScript.css" rel="stylesheet" type="text/css">
  <link href="$lib/PodPomWeb.css" rel="stylesheet" type="text/css">
  <script src="$lib/prototype.js"></script>
  <script src="$lib/GvaScript.js"></script>
  <script>
    var treeNavigator;
    function setup() {  
      new GvaScript.TreeNavigator(
         'TN_tree', 
         {selectFirstNode: location.hash ? false : true}
      );
    }
    window.onload = setup;
    function jumpto_href(event) {
      var label = event.controller.label(event.target);
      if (label && label.tagName == "A") {
        label.focus();
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
   <h1 class="TN_label">$name$self->{version}</h1>
    $core_release

   <span id="title_descr">$description</span>

   <span id="ref_box">
   <a href="$self->{root_url}/source/$self->{path}">Source</a><br>
   CPAN 
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
  if ($self->{line_numbering}) {
    my $line = 1;
    $text =~ s/^/sprintf "%6d\t", $line++/egm;
  }
  return qq{<pre class="$coloring">$text</pre>};
}



sub PPI_coloring {
  my ($self, $text) = @_;
  my $ppi = PPI::HTML->new();
  $text = $ppi->html(\$text);
  $text =~ s/<br>//g;
  return $text;
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

a source code view with syntax coloring
(this is an optional feature -- see section L</"Optional features">)


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

  <Location /perldoc>
        SetHandler modperl
        PerlResponseHandler Pod::POM::Web->handler
  </Location>

Then navigate to URL L<http://localhost/perldoc>.

=head3 As a cgi-bin script 

Alternatively, you can run this application as a cgi-script
by writing simple file in your C<cgi-bin> directory, like this :

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

  /path/to/perl -MPod::POM::Web -e "Pod::POM::Web->server"

This is useful if you have no other HTTP server, or if
you want to run this module under the perl debugger.

=head2 Note about static files

The application needs some static DHTML resources (style sheets,
javascript code, images). These are served dynamically by 
the module, under the L<lib> URL; but of course is it more
efficient to tell Apache to serve these files directly, by putting
an alias to the F<perl/site/lib/Pod/POM/Web/lib> directory.

=head2 Note about security

This application is intented as a power tool for Perl developers, 
not as an Internet application. It will display the documentation and source
code of any module installed under your C<@INC> path or
Apache C<lib/perl> directory, so it is probably a bad idea
to put it on a public Internet server.

=head2 Optional features

=head3 Syntax coloring

Syntax coloring improves readability of code excerpts.
If your Perl distribution is from ActiveState, then 
C<Pod::POM::Web> will take of the L<ActiveState::Scineplex> module
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



=head1 ACKNOWLEDGEMENTS

This web application was deeply inspired by :

=over

=item *

the structure of HTML Perl documentation released with 
ActivePerl (L<http://www.activeperl.com/ASPN/Perl>).


=item *

the tree navigation in Microsoft's MSDN Web site.

=item *

the standalone HTTP server implemented in L<Pod::WebServer>.

=item *

the wide possibilities of Andy Wardley's L<Pod::POM> parser.

=back


=head1 BUGS

Please report any bugs or feature requests to
C<bug-pod-pom-web at rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Pod-POM-Web>.
I will be notified, and then you'll automatically be notified of progress on
your bug as I make changes.


=head1 AUTHOR

Laurent Dami, C<< <laurent.dami at justice.ge.ch> >>


=head1 COPYRIGHT & LICENSE

Copyright 2007 Laurent Dami, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=head1 TODO


  - tests !

  - performance, expiry headers, server-side caching
  - also serve Programs (c:/perl/bin)

Bugs:

  - display in perlre (<a...)
  - declare bugs 
      - SQL::Abstract, nonempty line #337
      - LWP: item without '*'



