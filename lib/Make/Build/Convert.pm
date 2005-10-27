package Make::Build::Convert;

use strict;
use warnings; 

use Carp ();
use Cwd ();
use Data::Dumper ();
use ExtUtils::MakeMaker ();
use File::Basename ();
use File::HomeDir ();
use File::Slurp ();
use File::Spec ();
use IO::File ();

our $VERSION = '0.20_05';

sub new {
    my ($self, %params) = (shift, @_);
    my $obj = bless { Config => { Path             => $params{Path}             || '',
                                  Makefile_PL      => $params{Makefile_PL}      || 'Makefile.PL',
	                          Build_PL         => $params{Build_PL}         || 'Build.PL',
		                  MANIFEST         => $params{MANIFEST}         || 'MANIFEST',
				  RC               => $params{RC}               || '.make2buildrc',
				  Create_RC        => $params{Create_RC}        || 0,
				  Exec_Makefile    => $params{Exec_Makefile}    || 0,
			          Verbose          => $params{Verbose}          || 0,
				  Debug            => $params{Debug}            || 0,
			          Use_Native_Order => $params{Use_Native_Order} || 0,
			          Len_Indent       => $params{Len_Indent}       || 3,
			          DD_Indent        => $params{DD_Indent}        || 2,
	               	          DD_Sortkeys      => $params{DD_Sortkeys}      || 1 }}, $self;
    $obj->{Config}{Makefile_PL} = File::Basename::basename($obj->{Config}{Makefile_PL});
    $obj->{Config}{Build_PL}    = File::Basename::basename($obj->{Config}{Build_PL});
    $obj->{Config}{MANIFEST}    = File::Basename::basename($obj->{Config}{MANIFEST});
    $obj->{Config}{RC}          = File::Spec->catfile(File::HomeDir::home(), $obj->{Config}{RC});
    if ($params{Path}) {
        $obj->{Config}{Makefile_PL} = File::Spec->catfile($params{Path}, $obj->{Config}{Makefile_PL});
        $obj->{Config}{Build_PL}    = File::Spec->catfile($params{Path}, $obj->{Config}{Build_PL});
	$obj->{Config}{MANIFEST}    = File::Spec->catfile($params{Path}, $obj->{Config}{MANIFEST});
    }
    return $obj;
}

sub convert {
    my $self = shift;
    $self->_create_rcfile if $self->{Config}{Create_RC};
    $self->_makefile_ok;
    print "Converting $self->{Config}{Makefile_PL} -> $self->{Config}{Build_PL}\n";
    $self->_get_data;
    if ($self->{Config}{Exec_Makefile}) {
        print "Executing $self->{Config}{Makefile_PL}\n";
        $self->_run_makefile;
    } else {
        $self->_parse_makefile;
    }
    $self->_convert;
    $self->_dump;
    $self->_write;
    $self->_add_to_manifest if -e $self->{Config}{MANIFEST};
}

sub _create_rcfile {
    my $self = shift;   
    my $rcfile = $self->{Config}{RC};
    if (-e $rcfile && !-z $rcfile && File::Slurp::read_file($rcfile) =~ /\w+/o) {
        die "$rcfile exists\n";
    } else {
        my $data = $self->_parse_data('create_rc');
	my $fh = IO::File->new(">$rcfile") or die "Can't open $rcfile: $!\n";
	print $fh $data;
	$fh->close;
	print "Created $rcfile\n";
	exit;
    }
}

sub _makefile_ok {
    my $self = shift;
    my $makefile;
    if (-e $self->{Config}{Makefile_PL}) {
        $makefile = File::Slurp::read_file($self->{Config}{Makefile_PL});
    } else {
        die 'No ', File::Basename::basename($self->{Config}{Makefile_PL}), ' found at ', 
          $self->{Config}{Path} !~ /^\.\//o && $self->{Config}{Path} =~ m{[quotemeta([/\])]}o 
	    ? File::Basename::dirname($self->{Config}{Makefile_PL}) 
	    : Cwd::cwd(), "\n";
    }
    die "$self->{Config}{Makefile_PL} does not consist of WriteMakefile()\n"
      unless $makefile =~ /WriteMakefile\s*\(/os;
    die "Indirect arguments to WriteMakefile() via hash are not supported\n" 
      if $makefile =~ /WriteMakefile\(\s*%\w+.*\s*\)/os && !$self->{Config}{Exec_Makefile};
}

sub _run_makefile {
    my $self = shift;
    no warnings 'redefine';
    *ExtUtils::MakeMaker::WriteMakefile = sub {
      %{$self->{make_args}} = @{$self->{make_args_arr}} = @_;
    };
    do $self->{Config}{Makefile_PL};
}

sub _get_data {
    my $self = shift;
    my @data = $self->_parse_data;
    
    $self->{Data}{table}           = { split /\s+/, shift @data };
    $self->{Data}{default_args}    = { split /\s+/, shift @data };
    $self->{Data}{sort_order}      = [ split /\s+/, shift @data ];
   ($self->{Data}{begin}, 
    $self->{Data}{end})            =                      @data;

    # allow for embedded values such as clean => { FILES => '' }
    foreach my $arg (keys %{$self->{Data}{table}}) {
        if (index($arg, '.') > 0) {
	    my @path = split /\./, $arg;
	    my $value = $self->{Data}{table}->{$arg};
	    my $current = $self->{Data}{table};
	    while (@path) {
	        my $key = shift @path;
		$current->{$key} ||= @path ? {} : $value;
		$current = $current->{$key};
	    }
	}
    }
}

sub _parse_data {
    my $self = shift;
    my $create_rc = 1 if (shift || 'undef') eq 'create_rc';
    my ($data, @data_parsed);
    my $rcfile = $self->{Config}{RC};
    if (-e $rcfile && !-z $rcfile && File::Slurp::read_file($rcfile) =~ /\w+/o) {
	$data = File::Slurp::read_file($rcfile);
    } else {
        local $/ = '__END__';
	$data = <DATA>;
	chomp($data);
    }
    unless ($create_rc) {
        @data_parsed = do {               #  # description       
	    split /#\s+.*\s+-\n/, $data; #  -     
        };
    }
    unless ($create_rc) {
        # superfluosity
        shift @data_parsed;
        chomp($data_parsed[-1]);
	for my $line (split /\n/, $data_parsed[0]) {
	    next unless $line;
	    if ($line =~ /^#/o) {
	        my ($arg) = split /\s+/, $line;
	        $self->{disabled}{substr($arg,1)} = 1;
	    }
	}
        @data_parsed = map { s/^#.*?\n(.*)$/$1/gos; $_ } @data_parsed;
    }
    return $create_rc ? $data : @data_parsed;
}

sub _parse_makefile {
    my $self = shift;
    my (@histargs, %makeargs);
    my $makefile = File::Slurp::read_file($self->{Config}{Makefile_PL});
    $makefile =~ s/(.*)WriteMakefile\(\s*?(.*?)\);(.*)/$2/os;
    my $makecode_begin = $1;
    my $makecode_end   = $3;
    $makecode_begin =~ s/\s*([#\w]+.*;)\s*/$1/os;
    $makecode_end   =~ s/\s*([#\w]+.*;)\s*/$1/os;
    $self->{make_code}{begin} = $makecode_begin unless (($makecode_begin =~ tr/;/;/) == 1);
    $self->{make_code}{end}   = $makecode_end;
    $self->_debug("Entering parse\n");
    while ($makefile) {
        if ($makefile =~ s/^\s*['"]?(\w+)['"]?\s+=>\s+(?![\[\{])['"]?([-\$\w]?.*?)['"]?(?:,\n|,(\s+#\s+\w+.*?)\n)//os) {
	    my ($arg, $value, $comment) = ($1,$2,$3);
	    $comment ||= '';
            $makeargs{$arg} = $value;
	    push @histargs, $arg;
            if (defined($comment) && defined($self->{Data}{table}{$arg})) {
                $self->{make_comments}{$self->{Data}{table}{$arg}} = $comment;
	    }
	    $self->_debug("Found scalar:\narg: $arg\nvalue: $value\ncomment: $comment\nmake args:\n$makefile\n\n");
	} elsif ($makefile =~ s/^\s*['"]?(\w+)['"]?\s+=>\s+\[\s*(.*?)\s*\](?:,\n|,(\s+#\s+\w+.*?)\n)//os) {
	    my ($arg, $values, $comment) = ($1,$2,$3);
	    $comment ||= '';
	    $values =~ tr/[',]//d;
	    $makeargs{$arg} = [ split /\s+/, $values ];
	    push @histargs, $arg;
	    if (defined($comment) && defined($self->{Data}{table}{$arg})) {
                $self->{make_comments}{$self->{Data}{table}{$arg}} = $comment;
	    }
	    $self->_debug("Found array:\narg: $arg\nvalues: $values\ncomment: $comment\nmake args:\n$makefile\n\n");
	} elsif ($makefile =~ s/^\s*['"]?(\w+)['"]?\s+=>\s+\{\s*(.*?)\s*\}(?:,\n|,(\s+#\s+\w+.*?)\n)//os) {
	    my ($arg, $values, $comment) = ($1,$2,$3);
	    $comment ||= '';
	    my @values = split /,\ /, $values;
	    local $/ = ','; 
	    chomp(@values);
	    my @values_new;
	    for my $value (@values) {
	        my @values = split /\s+=>\s+/, $value;
		push @values_new, @values;
	    }
	    @values = map { tr/'//d; $_ } @values_new;
	    $makeargs{$arg} = { @values };
	    push @histargs, $arg;
            if (defined($comment) && defined($self->{Data}{table}{$arg})) {
                $self->{make_comments}{$self->{Data}{table}{$arg}} = $comment;
	    }
	    $self->_debug("Found hash:\narg: $arg\nvalues: $values\ncomment: $comment\nmake args:\n$makefile\n\n");
	} else {
	    my $makecode;
	    if ($makefile =~ s/^\s+(.*?\:\s+\(.*\)\s*),\n//os) {
		$makecode = $1;
	    } elsif ($makefile =~ s/^\s*([$@%]\w+)\s*//os) {
                $makecode = $1;
            } elsif ($makefile =~ s/^\s*(#.*?)\n//os) {
	        $makecode = $1;
	    } else {
                $makefile =~ s/^\s+(.*?)[,]\s*//os;
                $makecode = $1;
            }
	    SUBST: for my $make (keys %{$self->{Data}{table}}) {
		if ($makecode =~ /\b$make\b/s) {
		    $makecode =~ s/$make/$self->{Data}{table}{$make}/o;
		    last SUBST;
		}
            }
	    pop @histargs until $self->{Data}{table}{$histargs[-1]};
	    push @{$self->{make_code}{$self->{Data}{table}{$histargs[-1]}}}, $makecode;
	    $self->_debug("Found code:\ncode: $makecode\nmake args:\n$makefile\n\n");
	}
    }
    $self->_debug("Leaving parse\n");
    %{$self->{make_args}} = %makeargs;
}

sub _convert {
    my $self = shift;                        
    $self->_insert_args; 
    for my $arg (keys %{$self->{make_args}}) {
        if ($self->{disabled}{$arg}) {
	    $self->_do_verbose("*** $arg disabled, skipping\n");
	    next;
	}
        unless ($self->{Data}{table}->{$arg}) {
	    $self->_do_verbose("*** $arg unknown, skipping\n");
	    next;
	}     
        if (ref $self->{make_args}{$arg} eq 'HASH') {                                
	    if (ref $self->{Data}{table}->{$arg} eq 'HASH') {
		# embedded structure
		my @iterators = ();
		my $current = $self->{Data}{table}->{$arg};
		my $value = $self->{make_args}{$arg};
		push @iterators, _iterator($current, $value, keys %$current);
		while (@iterators) {
		    my $iterator = shift @iterators;
		    while (($current, $value) = $iterator->()) {
			if (ref $current eq 'HASH') {
			    push @iterators, _iterator($current, $value, keys %$current);
			} else {
			    if (substr($current, 0, 1) eq '@') {
				my $attr = substr($current, 1);
			        if (ref $value eq 'ARRAY') {
				    push @{$self->{build_args}}, { $attr => $value };
				} else {
				    push @{$self->{build_args}}, { $attr => [ split ' ', $value ] };
				}
			    } else {
			        push @{$self->{build_args}}, { $current => $value };
			    }
			}
		    }
		}
	    } else {
		# flat structure
		my %tmphash;
		%{$tmphash{$self->{Data}{table}->{$arg}}} = 
		  map { $_ => $self->{make_args}{$arg}{$_} } keys %{$self->{make_args}{$arg}};  
		push @{$self->{build_args}}, \%tmphash;
	    }
	} elsif (ref $self->{make_args}{$arg} eq 'ARRAY') {                         
	    push @{$self->{build_args}}, { $self->{Data}{table}->{$arg} => $self->{make_args}{$arg} };
	} elsif (ref $self->{make_args}{$arg} eq '') {
	    push @{$self->{build_args}}, { $self->{Data}{table}->{$arg} => $self->{make_args}{$arg} };
	} else { # unknown type
	    warn "Warning: $arg - unknown type of argument\n";
	}
    }
    $self->_sort_args if @{$self->{Data}{sort_order}};
}

sub _insert_args {
    my ($self, $make) = @_;
    my @insert_args;
    my %build = map { $self->{Data}{table}{$_} => $_ } keys %{$self->{Data}{table}};
    while (my ($arg, $value) = each %{$self->{Data}{default_args}}) {
        no warnings 'uninitialized';
        if (exists $self->{make_args}{$build{$arg}}) {
	    $self->_do_verbose("*** Overriding default \'$arg => $value\'\n");
	    next;
	}
        $value = {} if $value eq 'HASH';
	$value = [] if $value eq 'ARRAY';
	$value = '' if $value eq 'SCALAR' && $value !~ /\d+/o;
	push @insert_args, { $arg => $value };
    }
    @{$self->{build_args}} = @insert_args;
}

sub _iterator {
    my ($build, $make) = (shift, shift);
    my @queue = @_;
    return sub {
        my $key = shift @queue || return;
	return $build->{$key}, $make->{$key};
    }
}

sub _sort_args {
    my $self = shift;
    my %native_sortorder;
    if ($self->{Config}{Use_Native_Order}) {
	no warnings 'uninitialized';
        for (my ($i,$s) = 0; $s < @{$self->{make_args_arr}}; $s++) {
	    next unless $s % 2 == 0;
	    $native_sortorder{$self->{Data}{table}{$self->{make_args_arr}[$s]}} = $i
	      if exists $self->{Data}{table}{$self->{make_args_arr}[$s]};
	    $i++;
	}
    } 
    my %sortorder;
    {
        my %have_args = map { keys %$_ => 1 } @{$self->{build_args}};
	# Filter sort items, that we didn't receive as args,
	# and map the rest to according array indexes.
	my $i = 0;
	if ($self->{Config}{Use_Native_Order}) {
	    my %slot;
	    for my $arg (grep $have_args{$_}, @{$self->{Data}{sort_order}}) {
	        if ($native_sortorder{$arg}) {
	            $sortorder{$arg} = $native_sortorder{$arg};
		    $slot{$native_sortorder{$arg}} = 1;
	        } else {
	            $i++ while $slot{$i};
		    $sortorder{$arg} = $i++;
	        }      
            }
	    my @args = sort { $sortorder{$a} <=> $sortorder{$b} } keys %sortorder;
            $i = 0; %sortorder = map { $_ => $i++ } @args;
	} else {
	    %sortorder = map { 
	      $_ => $i++ 
            } grep $have_args{$_}, @{$self->{Data}{sort_order}};
	}
    }
    my ($is_sorted, @unsorted);
    do {
        $is_sorted = 1;
          SORT: for (my $i = 0; $i < @{$self->{build_args}}; $i++) {   
              my ($arg) = keys %{$self->{build_args}[$i]};
	      unless (exists $sortorder{$arg}) {
	          push @unsorted, splice(@{$self->{build_args}}, $i, 1);
	          next;
	      }
              if ($i != $sortorder{$arg}) {
                  $is_sorted = 0;
                  # Move element $i to pos $sortorder{$arg}
		  # and the element at $sortorder{$arg} to
		  # the end. 
	          push @{$self->{build_args}}, 
		    splice(@{$self->{build_args}}, $sortorder{$arg}, 1,    
		      splice(@{$self->{build_args}}, $i, 1));
                  last SORT;    
	      }
          }
    } until ($is_sorted);
    push @{$self->{build_args}}, @unsorted;  
}

sub _dump {
    my $self = shift;
    $Data::Dumper::Indent    = $self->{Config}{DD_Indent} || 2;
    $Data::Dumper::Quotekeys = 0;
    $Data::Dumper::Sortkeys  = $self->{Config}{DD_Sortkeys};
    $Data::Dumper::Terse     = 1;
    my $d = Data::Dumper->new(\@{$self->{build_args}});
    $self->{buildargs_dumped} = [ $d->Dump ];
}

sub _write { 
    my $self = shift;
    $self->{INDENT} = ' ' x $self->{Config}{Len_Indent};
    no warnings 'once';
    my $fh = IO::File->new(">$self->{Config}{Build_PL}") 
      or die "Can't open $self->{Config}{Build_PL}: $!\n";
    my $selold = select($fh);
    $self->_compose_header;
    $self->_write_begin;
    $self->_write_args;
    $self->_write_end;
    $fh->close;
    select($selold);
    print "Conversion done\n";
}

sub _compose_header {
    my $self = shift;
    my ($insert_comments, $insert_statements);
    my $note = '# Note: this file has been initially created by '.__PACKAGE__." $VERSION";
    if (defined($self->{make_code}{begin})) {
        $self->_do_verbose("Removing ExtUtils::MakeMaker as dependency\n");
        $self->{make_code}{begin} =~ s/[ ]*(?:require|use)\s+ExtUtils::MakeMaker\s*;//os;
        $insert_comments ||= '';
        while ($self->{make_code}{begin} =~ s/^(#[!]?.*?\n)//os) {
            $insert_comments .= $1;
        }
	chomp($insert_comments);
        $insert_statements ||= '';
        while ($self->{make_code}{begin} =~ /(?:require|use)\s+.*?;/os) {
            $self->{make_code}{begin} =~ s/^\n?(.*?;)//os;
	    $insert_statements .= "$1\n";
        }
	chomp($insert_statements);
	1 while $self->{make_code}{begin} =~ s/^\n//os;
	chomp($self->{make_code}{begin}) while $self->{make_code}{begin} =~ /\n$/os;
    }
    $self->{Data}{begin} = $insert_comments || $insert_statements
      ? ($insert_comments  =~ /\w/o ? "$insert_comments\n" : '') . "$note\n" . 
        ($insert_statements =~ /\w/o ? "\n$insert_statements\n" : '') .
        $self->{Data}{begin}
      : "$note\n" . $self->{Data}{begin};
}

sub _write_begin {
    my $self = shift;  
    my $INDENT = substr($self->{INDENT}, 0, length($self->{INDENT}) - 1);
    $self->_subst_makecode('begin');
    $self->{Data}{begin} =~ s/(\$INDENT)/$1/eego;
    $self->_do_verbose(File::Basename::basename($self->{Config}{Build_PL}), " written:\n", 2);
    $self->_do_verbose($self->{Data}{begin}, 2);
    print $self->{Data}{begin};
}

sub _write_args {
    my $self = shift;
    my $arg;
    my $regex = '$chunk =~ /=> \{/o';
    for my $chunk (@{$self->{buildargs_dumped}}) {
        # Hash/Array output                       
        if ($chunk =~ /=> [\{\[]/o) {
	    # Remove redundant parentheses
	    $chunk =~ s/^\{.*?\n(.*(?{eval $regex ? '\}' : '\]'}))\s+\}\s+$/$1/os;
	    Carp::croak $@ if $@;
	    # One element per each line
	    my @lines;        
            push @lines, $1 while $chunk =~ s/^(.*?\n)(.*)$/$2/os;         
	    # Gather whitespace up to hash key in order
	    # to recreate native Dump() indentation.
	    my ($whitespace) = $lines[0] =~ /^(\s+)(\w+)/o;
	    $arg = $2;
	    my $shorten = length($whitespace);
            for (my $i = 0; $i < @lines; $i++) {
	        my $line = $lines[$i];
	        chomp($line);
		# Remove additional whitespace
	        $line =~ s/^\s{$shorten}(.*)$/$1/o;
		# Add comma where appropriate (version numbers, parentheses)          
	        $line .= ',' if $line =~ /[\d+\}\]]$/o;
		$line =~ s/'(\d|\$\w+)'/$1/go;
		my $output = "$self->{INDENT}$line";
		$output .= ($i == $#lines && defined($self->{make_comments}{$arg}))
		  ? "$self->{make_comments}{$arg}\n" : "\n"; 
		$self->_do_verbose($output, 2);
		print $output;
            }
	} else { # Scalar output                                                 
	    chomp($chunk);
	    # Remove redundant parentheses
            $chunk =~ s/^\{\s+(.*?)\s+\}$/$1/os;
	    $chunk =~ s/'(\d|\$\w+)'/$1/gos;
	    ($arg) = $chunk =~ /^\s*(\w+)/os;
	    my $output = "$self->{INDENT}$chunk,";
	    $output .= $self->{make_comments}{$arg} if defined($self->{make_comments}{$arg});
	    $self->_do_verbose("$output\n", 2);
	    print "$output\n";
	}
	no warnings 'uninitialized';
	if ($self->{make_code}{$arg}) {
	    for my $line (@{$self->{make_code}{$arg}}) {
	        $line .= ',' unless $line =~ /^#/o;
    	        $self->_do_verbose("$self->{INDENT}$line\n", 2);
	        print "$self->{INDENT}$line\n";
	    }
	}
    }
}

sub _write_end {
    my $self = shift;
    my $INDENT = substr($self->{INDENT}, 0, length($self->{INDENT}) - 1);
    $self->_subst_makecode('end');
    $self->{Data}{end} =~ s/(\$INDENT)/$1/eego;
    $self->_do_verbose($self->{Data}{end}, 2);
    print $self->{Data}{end};
}

sub _subst_makecode {
    my ($self, $section) = @_;
    $self->{make_code}{$section} ||= '';
    $self->{make_code}{$section} =~ /\w/
      ? $self->{Data}{$section} =~ s/\$MAKECODE/$self->{make_code}{$section}/
      : $self->{Data}{$section} =~ s/\n\$MAKECODE\n//o;
}    

sub _add_to_manifest {
    my $self = shift;
    my $fh = IO::File->new("<$self->{Config}{MANIFEST}") 
      or die "Can't open $self->{Config}{MANIFEST}: $!\n";
    my @manifest = <$fh>;
    $fh->close;
    my $build_pl = File::Basename::basename($self->{Config}{Build_PL});
    unless (grep { $_ =~ /^$build_pl\s+$/o } @manifest) {
        unshift @manifest, "$build_pl\n";
        $fh = IO::File->new(">$self->{Config}{MANIFEST}") 
	  or die "Can't open $self->{Config}{MANIFEST}: $!\n";
        print $fh sort @manifest;
        $fh->close;
	print "Added to $self->{Config}{MANIFEST}: $self->{Config}{Build_PL}\n";
    }
}

sub _do_verbose {
    my $self = shift;
    my $level = $_[-1] =~ /^\d$/o ? pop : 1; 
    if (($self->{Config}{Verbose} && $level == 1) 
      || ($self->{Config}{Verbose} == 2 && $level == 2)) {
        print STDOUT @_;
    }
}

sub _debug {
    my $self = shift;
    warn @_ if $self->{Config}{Debug};
}

1;
__DATA__
 
# argument conversion 
-
NAME                  module_name
DISTNAME              dist_name
ABSTRACT              dist_abstract
AUTHOR                dist_author
VERSION               dist_version
VERSION_FROM          dist_version_from
PREREQ_PM             requires
PL_FILES              PL_files
PM                    pm_files
MAN1PODS              pod_files
XS                    xs_files
INC                   include_dirs
INSTALLDIRS           installdirs
DESTDIR               destdir
CCFLAGS               extra_compiler_flags
EXTRA_META            meta_add
SIGN                  sign
LICENSE               license
clean.FILES           @add_to_cleanup
 
# default arguments 
-
recommends	      HASH
build_requires        HASH
conflicts	      HASH
license               unknown
create_readme         1
create_makefile_pl    passthrough
 
# sorting order 
-
module_name
dist_name
dist_abstract
dist_author
dist_version
dist_version_from
requires
recommends
build_requires
conflicts
PL_files
pm_files
pod_files
xs_files
include_dirs
installdirs
destdir
add_to_cleanup
extra_compiler_flags
meta_add
sign
license
create_readme
create_makefile_pl

# begin code 
-
use Module::Build;

$MAKECODE

my $build = Module::Build->new
$INDENT(
# end code 
-
$INDENT);
  
$build->create_build_script;

$MAKECODE

__END__

=head1 NAME

Make::Build::Convert - Makefile.PL to Build.PL converter

=head1 SYNOPSIS

 require Make::Build::Convert; 

 my %params = ( Path => '/path/to/perl/distribution',
                Verbose => 2,
		Use_Native_Order => 1,
                Len_Indent => 4 );

 my $make = Make::Build::Convert->new(%params);                            
 $make->convert;

=head1 DESCRIPTION

C<ExtUtils::MakeMaker> has been a de-facto standard for the common distribution of Perl
modules; C<Module::Build> is expected to supersede C<ExtUtils::MakeMaker> in some time
(part of the Perl core as of 5.10?)

The transition takes place slowly, as the converting process manually achieved 
is yet an uncommon practice. The Make::Build::Convert F<Makefile.PL> parser is 
intended to ease the transition process.

=head1 CONSTRUCTOR

=head2 new

Possible arguments:

=over 4

=item Path

Path to a Perl distribution. Default: undef

=item Makefile_PL

Filename of the Makefile script. Default: F<Makefile.PL>

=item Build_PL

Filename of the Build script. Default: F<Build.PL>

=item MANIFEST

Filename of the MANIFEST file. Default: F<MANIFEST>

=item RC

Filename of the RC file. Default: F<.make2buildrc>

=item Create_RC

Create a RC file in the homedir of the current user.
Default: 0

=item Exec_Makefile

Execute the Makefile.PL via do 'Makefile.PL'.
Default: 0

=item Verbose

Verbose mode. If set to 1, overridden defaults and skipped arguments
are printed while converting; if set to 2, output of C<Verbose = 1> and
created Build script will be printed. May be set via the make2build 
switches C<-v> (mode 1) and C<-vv> (mode 2). Default: 0

=item Debug

Rudimentary debug facility for examining the parsing process.
Default: 0

=item Use_Native_Order

Native sorting order. If set to 1, the native sorting order of
the Makefile arguments will be tried to preserve; it's equal to
using the make2build switch C<-n>. Default: 0

=item Len_Indent

Indentation (character width). May be set via the make2build
switch C<-l>. Default: 3

=item DD_Indent

C<Data::Dumper> indendation mode. Mode 0 will be disregarded in favor
of 2. Default: 2

=item DD_Sortkeys

C<Data::Dumper> sort keys. Default: 1

=back

=head1 METHODS

=head2 convert

Parses the F<Makefile.PL>'s C<ExtUtils::MakeMaker> arguments and converts them
to C<Module::Build> equivalents; subsequently the according F<Build.PL>
is created. Takes no arguments.

=head1 DATA SECTION

=head2 Argument conversion

C<ExtUtils::MakeMaker> arguments followed by their C<Module::Build> equivalents. 
Converted data structures preserve their native structure,
that is, C<HASH> -> C<HASH>, etc.

 NAME                  module_name
 DISTNAME              dist_name
 ABSTRACT              dist_abstract
 AUTHOR                dist_author
 VERSION               dist_version
 VERSION_FROM          dist_version_from
 PREREQ_PM             requires
 PL_FILES              PL_files
 PM                    pm_files
 MAN1PODS              pod_files
 XS                    xs_files
 INC                   include_dirs
 INSTALLDIRS           installdirs
 DESTDIR               destdir
 CCFLAGS               extra_compiler_flags
 EXTRA_META            meta_add
 SIGN                  sign
 LICENSE               license
 clean.FILES           @add_to_cleanup

=head2 Default arguments

C<Module::Build> default arguments may be specified as key/value pairs. 
Arguments attached to multidimensional structures are unsupported.

 recommends	       HASH
 build_requires        HASH
 conflicts	       HASH
 license               unknown
 create_readme         1
 create_makefile_pl    passthrough

Value may be either a string or of type C<SCALAR, ARRAY, HASH>.

=head2 Sorting order

C<Module::Build> arguments are sorted as enlisted herein. Additional arguments, 
that don't occur herein, are lower prioritized and will be inserted in 
unsorted order after preceedingly sorted arguments.

 module_name
 dist_name
 dist_abstract
 dist_author
 dist_version
 dist_version_from
 requires
 recommends
 build_requires
 conflicts
 PL_files
 pm_files
 pod_files
 xs_files
 include_dirs
 installdirs
 destdir
 add_to_cleanup
 extra_compiler_flags
 meta_add
 sign
 license
 create_readme
 create_makefile_pl

=head2 Begin code

Code that preceeds converted C<Module::Build> arguments.

 use Module::Build;

 $MAKECODE

 my $b = Module::Build->new
 $INDENT(

=head2 End code

Code that follows converted C<Module::Build> arguments.

 $INDENT);

 $b->create_build_script;

 $MAKECODE

=head1 INTERNALS

=head2 co-opting C<WriteMakefile()>

This behavior is no longer the default way to receive WriteMakefile()'s
arguments; the Makefile.PL is now statically parsed unless one forces
manually the co-opting of WriteMakefile().

In order to convert arguments, a typeglob from C<WriteMakefile()> to an 
internal sub will be set; subsequently Makefile.PL will be executed and the
arguments are then accessible to the internal sub.

=head2 Data::Dumper

Converted C<ExtUtils::MakeMaker> arguments will be dumped by 
C<Data::Dumper's> C<Dump()> and are then furtherly processed.

=head1 SEE ALSO

L<http://www.makemaker.org>, L<ExtUtils::MakeMaker>, L<Module::Build>, 
L<http://www.makemaker.org/wiki/index.cgi?ModuleBuildConversionGuide>

=head1 AUTHOR

Steven Schubiger, schubiger@cpan.org

=head1 LICENSE

This program is free software; you may redistribute it and/or 
modify it under the same terms as Perl itself.

See L<http://www.perl.com/perl/misc/Artistic.html>	    

=cut
