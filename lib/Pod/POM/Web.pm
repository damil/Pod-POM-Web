package Pod::POM::Web;
use strict;
use warnings;
no warnings 'uninitialized';
use Pod::POM;
use List::Util      qw/first/;
use List::MoreUtils qw/uniq pairwise/;
use Module::CoreList;
use CGI; # rather than mod_perl API, because it will work in standalone server
use URI;
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


#----------------------------------------------------------------------
# main entry point
#----------------------------------------------------------------------

sub server {
  my $class = shift;

  use HTTP::Daemon;
  use HTTP::Status;

  my $port = $ARGV[0] || 8080;

  my $d = HTTP::Daemon->new(LocalPort => $port) || die "could not start daemon";
  print STDERR "Please contact me at: <URL:", $d->url, ">\n";
  while (my $c = $d->accept) {
    while (my $req = $c->get_request) {
      print STDERR "URL : " , $req->url, "\n";
      my $r = HTTP::Response->new;
      $class->handler($r, $req->url, $req->url->path, $req->url->query_form_hash);
      $c->send_response($r);
    }
    $c->close;
    undef($c);
  }
}


sub handler : method  {
  my ($class, $r, $url, $path, $params) = @_; 

  my $self  = $url ? # if coming from server() method above
    {r => $r, root_url => $url, path => $path, params => $params}
  : do { # coming from mod_perl
      my $cgi = CGI->new;
      {r        => $r, 
       root_url => $cgi->url(-absolute => 1),
       path     => $cgi->path_info,
       params   => $cgi->Vars
      }};

  bless $self, $class;

  eval { $self->dispatch_request(); 1}  or $self->send_html($@);
  return 0; # Apache2::Const::OK;
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
    /^_dirs$/          and return print(join "<br>", @search_dirs);

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

  my $file = $self->find_sourcefile($path) or die "No file for '$path'";
  my $text = $self->slurp_file($file);

  $params->{coloring} and eval {
    require ActiveState::Scineplex;
    $text = ActiveState::Scineplex::Annotate($text, 
                                             'perl', 
                                             outputFormat => 'html');
  };

  $params->{lines} and do {
    my $line = 1;
    $text =~ s/^/sprintf "%6d\t", $line++/egm;
  };

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
  <link href="$lib/scineplex.css" rel="stylesheet" type="text/css">
  <link href="$lib/GvaScript_doc.css" rel="stylesheet" type="text/css">
  <style> 
    PRE {border: none; background: none}
    FORM {float: right; font-size: 70%; border: 1px solid}
  </style>
</head>
<body>
$doc_link
<h1>Source of $path</h1>

<pre>File: $file</pre>

$offer_print

<pre>$text</pre>
</body>
</html>
__EOHTML__
}



sub serve_pod {
  my ($self, $path) = @_;
  $path =~ s[::][/]g;

  my $podfile = $self->find_sourcefile($path) or die "No file for '$path'";
  my $content = $self->slurp_file($podfile);

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
  my $view    = Pod::POM::View::HTML::_PerlDoc->new(
    root_url => $self->{root_url},
    path     => $path,
   );

  my $html = $view->print($pom);

  # again special handling for perlfunc : ids should be just function names
  $html =~ s/li id="(.*?)_.*?"/li id="$1"/g if $path eq 'perlfunc';

  return $self->send_html($html);
}


sub slurp_file {
  my ($self, $file) = @_;
  open my $fh, $file or die "open $file: $!";
  my $mtime = (stat $fh)[9];
  local $/ = undef;
  my $content = <$fh>;
  return wantarray ? ($content, $mtime) : $content;
}

sub find_sourcefile {
  my ($self, $path) = @_;

  foreach my $prefix (@search_dirs) {
    my $filename = first {-f}("$prefix/$path.pod", 
                              "$prefix/$path.pm", 
                              "$prefix/Pod/$path.pod");
    return $filename if $filename;
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
  my $source  = $self->slurp_file($self->find_sourcefile("perl"));
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
  return $self->send_html(<<__EOHTML__);
<html>
<head>
  <base target="contentFrame">
  <link href="lib/GvaScript.css" rel="stylesheet" type="text/css">
  <link href="lib/GvaScript_doc.css" rel="stylesheet" type="text/css">
  <script src="lib/prototype.js"></script>
  <script src="lib/GvaScript.js"></script>
  <script>
    var perlfuncs = $json_funcs;
    var treeNavigator, perlfuncsAutoCompleter;
    function setup() {
      treeNavigator 
        = new GvaScript.TreeNavigator('TN_tree', {tabIndex:0});
      perlfuncsAutoCompleter 
        = new GvaScript.AutoCompleter(perlfuncs, {minimumChars: 1, 
                                                  minWidth    : 100,
                                                  offsetX     : -20});
    }
    window.onload = setup;

   function maybe_complete(input) {
     if (input.form.source.selectedIndex == 0) // perlfunc
        perlfuncsAutoCompleter.autocomplete(input);
     else 
        perlfuncsAutoCompleter.detach(input);
     return true;
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
     <select name="source"
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

  my $params = $self->params;
  my $source = $params->{source};
  my $method = {perlfunc => 'perlfunc',
                perlfaq  => 'perlfaq',
                modules  => 'serve_pod',
                fulltext => 'fulltext', # see Pod::POM::Web::Indexer
                }->{$source}  or die "cannot search in '$source'";
  return $self->$method($params->{search});
}



my @_perlfunc_items; # simple-minded cache

sub perlfunc_items {
  my ($self) = @_;

  unless (@_perlfunc_items) {
    my $funcpom = $self->pod2pom($self->find_sourcefile("perlfunc"));
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
  <link href="$lib/GvaScript_doc.css" rel="stylesheet" type="text/css">
  <link href="$lib/scineplex.css" rel="stylesheet" type="text/css">
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
 FAQ: 
  for my $num (1..9) {
    my $faqpom = $self->pod2pom($self->find_sourcefile("perlfaq$num"));
    my @questions = map {grep {$_->title =~ $regex} $_->head2} $faqpom->head1
      or next FAQ;
    my @nodes = map {Pod::POM::View::HTML::_PerlDoc->print($_)} @questions;
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
  <link href="$lib/GvaScript_doc.css" rel="stylesheet" type="text/css">
  <link href="$lib/scineplex.css" rel="stylesheet" type="text/css">
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
  my $modified = gmtime $mtime;
  my $length   = length $content;

  my $r = $self->{r};
  for (ref $r) {
    /^Apache/ and do {
      $r->content_type($mime_type);
      $r->set_last_modified($mtime);
      $r->set_content_length($length);
      $r->print($content);
      return;
    };
    /^HTTP/ and do {
      $r->header(Content_type   => $mime_type,
                 Content_length => $length,
                 Last_modified  => $modified);
      $r->add_content($content);
      return;
    }
  }
  # otherwise
  print <<__EOTHML__;
Content-type: $mime_type
Content-length: $length
Last-modified: $modified

$content
__EOTHML__
}


sub send_html {
  my ($self, $html) = @_;
  my $r = $self->{r};
  for (ref $r) {
    /^Apache/ and do {
      $r->content_type('text/html');
      $r->print($html);
      return;
    };
    /^HTTP/ and do {
      $r->header(Content_type => 'text/html');
      $r->add_content($html);
      return;
    }
  }
  # otherwise
  print "Content-type: text/html\n\n$html";
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




1;

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

  my $core_release = Module::CoreList->first_release($name) || "";
  $core_release &&= "<small>(in Perl core since version $core_release)</small>";

  my $content = $pom->content->present($self);
  my $toc = $self->make_toc($pom, 0);
  my $lib = "$self->{root_url}/lib";
  return <<__EOHTML__
<html>
<head>
  <link href="$lib/GvaScript.css" rel="stylesheet" type="text/css">
  <link href="$lib/scineplex.css" rel="stylesheet" type="text/css">
  <link href="$lib/GvaScript_doc.css" rel="stylesheet" type="text/css">
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
    #title_descr {
       font-style: italic; 
       float: right; 
       width: 40%;
       margin-top: 8px;
       padding: 5px;
       text-align: center;
       border: 3px double #888;
    }
  </style>
</head>
<body>
<a href="$self->{root_url}/source/$self->{path}"
   style="float:right">Source</a>
<div id='TN_tree'>
  <div class="TN_node">
   <h1 class="TN_label">$name</h1>
   <span id="title_descr">$description</span>
   $core_release
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

# installing same method for view_head1, view_head2, etc.
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

  eval {
    require ActiveState::Scineplex;
    $text = ActiveState::Scineplex::Annotate($text, 
                                             'perl', 
                                             outputFormat => 'html');
    return "<pre>$text</pre>";
  }
    or return $self->SUPER::view_verbatim($text);
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

1;



__END__

=head1 NAME

Pod::POM::Web - Perldoc server

=head1 VERSION

Version 0.01


=head1 SYNOPSIS





=head1 AUTHOR

Laurent Dami, C<< <laurent.dami at justice.ge.ch> >>

=head1 BUGS

Please report any bugs or feature requests to
C<bug-pod-pom-web at rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Pod-POM-Web>.
I will be notified, and then you'll automatically be notified of progress on
your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Pod::POM::Web

You can also look for information at:

=over 4

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Pod-POM-Web>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Pod-POM-Web>

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Pod-POM-Web>

=item * Search CPAN

L<http://search.cpan.org/dist/Pod-POM-Web>

=back

=head1 ACKNOWLEDGEMENTS

This web application was inspired by :

=over

=item *

the structure of HTML documentation released with ActivePerl 
from ActiveState.

=item *

the tree navigation in Microsoft's MSDN Web site.

=item *

the standalone HTTP server implemented in L<Pod::WebServer>.


=back

Andy Wardley's L<Pod::POM> parser was extremely helpful.







=head1 COPYRIGHT & LICENSE

Copyright 2007 Laurent Dami, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=head1 TODO

  - standalone server
  - autocompleter broken
  - serve_source should display both *.pod AND *.pm
  - remove modperl API, deal directly with request
   - autocompleter on modules + fulltext
  - tests !
  - modperl / Perl::Registry / standalone server
  - caching !
  - Programs (c:/perl/bin)
  - GvaScript AC : RETURN should do default if no dropdown list
  - GvaScript explain trick with <a class="TN_label">
  - fix MSIE fetching many times the plus.gif (headers ??)
  - Unix : beware Pod/pod; dependencies (perldoc package!)
  - URL for pre-fetching a given page; URL to rebuild frameset (cf. MSDN)

Bugs:

  - display in perlre (<a...)
  - declare bugs 
      - Pod::pom on initial blank line (cf. perldoc/perlpodspec)
      - perl.pod : missing parts in summary
      - SQL::Abstract, nonempty line #337
      - perlfunc.pod line #516/531 should be L</open>
      - LWP: item without '*'

