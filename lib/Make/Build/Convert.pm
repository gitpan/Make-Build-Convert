package Make::Build::Convert;

use strict;
use warnings; 

use Carp 'croak';
use Data::Dumper ();
use ExtUtils::MakeMaker ();
use File::Basename qw(basename dirname);
use File::Slurp 'read_file';
use File::Spec 'catdir';

our $VERSION = '0.20_01';

sub new {
    my ($self, %params) = (shift, @_);
    my $obj = bless { Config => { Makefile_PL      => $params{Makefile_PL}      || 'Makefile.PL',
	                          Build_PL         => $params{Build_PL}         || 'Build.PL',
		                  MANIFEST         => $params{MANIFEST}         || 'MANIFEST',
			          Verbose          => $params{Verbose}          || 0,
			          Use_Native_Order => $params{Use_Native_Order} || 0,
			          Len_Indent       => $params{Len_Indent}       || 3,
			          DD_Indent        => $params{DD_Indent}        || 2,
	               	          DD_Sortkeys      => $params{DD_Sortkeys}      || 1 }}, $self;
    $obj->{Config}{Makefile_PL} = basename($obj->{Config}{Makefile_PL});
    $obj->{Config}{Build_PL}    = basename($obj->{Config}{Build_PL});
    $obj->{Config}{MANIFEST}    = basename($obj->{Config}{MANIFEST});
    if ($params{Path}) {
        $obj->{Config}{Makefile_PL} = catdir($params{Path}, $obj->{Config}{Makefile_PL});
        $obj->{Config}{Build_PL}    = catdir($params{Path}, $obj->{Config}{Build_PL});
	$obj->{Config}{MANIFEST}    = catdir($params{Path}, $obj->{Config}{MANIFEST});
    }
    return $obj;
}

sub convert {
    my $self = shift;
    $self->_run_makefile;
    print "Converting $self->{Config}{Makefile_PL} -> $self->{Config}{Build_PL}\n";
    $self->_get_data;
    $self->_convert_args;
    $self->_dump;
    $self->_write;
    $self->_add_to_manifest if -e $self->{Config}{MANIFEST};
}

sub _run_makefile {
    my $self = shift;
    $self->_makefile_ok;
    no warnings 'redefine';
    *ExtUtils::MakeMaker::WriteMakefile = sub {
      %{$self->{make_args}} = @{$self->{make_args_arr}} = @_;
    };
    no warnings 'uninitialized';
    -e $self->{Config}{Makefile_PL}
      ? do $self->{Config}{Makefile_PL}
      : die 'No ', basename($self->{Config}{Makefile_PL}), ' found at ', 
        $self->{Config}{Path} !~ /^\.\//o && $self->{Config}{Path} =~ m{[quotemeta(/\)]}o 
	  ? dirname($self->{Config}{Makefile_PL}) 
	  : (sub { eval 'require Cwd'; croak $@ if $@; Cwd::cwd(); })->(), "\n";  
}

sub _makefile_ok {
    my $self = shift;
    my $makefile = read_file($self->{Config}{Makefile_PL});
    die "$self->{Config}{Makefile_PL} does not consist of WriteMakefile()\n"
      unless $makefile =~ /WriteMakefile\s*\(/o;
}

sub _get_data {
    my $self = shift;
    
    local $/ = '__END__';
    my @data = do {
        local $_ = <DATA>;    #  # description       
	split /#\s+.*\s+-\n/; #  -     
    };
    # superfluosity
    shift @data;
    chomp $data[-1]; $/ = "\n";
    chomp $data[-1]; 
    
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

sub _convert_args {
    my $self = shift;                        
    $self->_insert_args; 
    for my $arg (keys %{$self->{make_args}}) {
        unless ($self->{Data}{table}->{$arg}) {
	    $self->_do_verbose("*** $arg unknown, skipping\n");
	    next;
	}
	# hash conversion
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
	} elsif (ref $self->{make_args}{$arg} eq 'ARRAY') { # array conversion                           
	    warn "Warning: $arg - array conversion not supported\n";    
	} elsif (ref $self->{make_args}{$arg} eq '') { # scalar conversion
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
	$value = '' if $value eq 'SCALAR';
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
    my $fh = \*F_BUILD;
    my $selold = $self->_open_build_pl($fh);
    $self->_write_begin;
    $self->_write_args;
    $self->_write_end;
    $self->_close_build_pl($fh, $selold);
    print "Conversion done\n";
}

sub _open_build_pl {
    my ($self, $fh) = @_;
    open($fh, ">$self->{Config}{Build_PL}") or 
      die "Couldn't open $self->{Config}{Build_PL}: $!\n";
    return select $fh;
}

sub _write_begin {
    my $self = shift;  
    my $INDENT = substr($self->{INDENT}, 0, length($self->{INDENT})-1);
    $self->{Data}{begin} =~ s/(\$[A-Z]+)/$1/eeg;
    $self->_do_verbose(basename($self->{Config}{Build_PL}), " written:\n", 2);
    $self->_do_verbose($self->{Data}{begin}, 2);  
    print '# Note: this file has been initially created by ', __PACKAGE__, " $VERSION\n";
    print $self->{Data}{begin};
}

sub _write_args {
    my $self = shift;
    my $regex = '$arg =~ /=> \{/o';
    for my $arg (@{$self->{buildargs_dumped}}) {
        # Hash/Array output                       
        if ($arg =~ /=> [\{\[]/o) {
	    # Remove redundant parentheses
	    $arg =~ s/^\{.*?\n(.*(?{ eval $regex ? '\}' : '\]'}))\s+\}\s+$/$1/osx;
	    croak $@ if $@;
	    # One element per each line
	    my @lines;        
            push @lines, $1 while $arg =~ s/^(.*?\n)(.*)$/$2/os;         
	    # Gather whitespace up to hash key in order
	    # to recreate native Dump() indentation. 
	    my ($whitespace) = $lines[0] =~ /^(\s+)\w+/o;
	    my $shorten = length $whitespace;
            for my $line (@lines) {
	        chomp $line;
		# Remove additional whitespace
	        $line =~ s/^\s{$shorten}(.*)$/$1/o;
		# Add comma where appropriate (version numbers, parentheses)          
	        $line .= ',' if $line =~ /[\d+\}\]]$/o;
		$self->_do_verbose("$self->{INDENT}$line\n", 2);
		print "$self->{INDENT}$line\n";
            }
	} else { # Scalar output                                                 
	    chomp $arg;
	    # Remove redundant parentheses
            $arg =~ s/^\{\s+(.*?)\s+\}$/$1/os;
	    $self->_do_verbose("$self->{INDENT}$arg,\n", 2);
	    print "$self->{INDENT}$arg,\n";
	}
    }
}

sub _write_end {
    my $self = shift;
    my $INDENT = substr($self->{INDENT}, 0, length($self->{INDENT})-1);
    $self->{Data}{end} =~ s/(\$[A-Z]+)/$1/eeg;
    $self->_do_verbose($self->{Data}{end}, 2);
    print $self->{Data}{end};
}

sub _close_build_pl {
    my ($self, $fh, $selold) = @_;
    close($fh);
    select($selold); 
}

sub _add_to_manifest {
    my $self = shift;
    open(my $fh, "<$self->{Config}{MANIFEST}") or die "Could not open $self->{Config}{MANIFEST}: $!\n";
    my @manifest = <$fh>;
    close($fh);
    my $build_pl = basename($self->{Config}{Build_PL});
    unless (grep { $_ =~ /^$build_pl\s+$/ } @manifest) {
        unshift @manifest, "$build_pl\n";
        open($fh, ">$self->{Config}{MANIFEST}") or die "Could not open $self->{Config}{MANIFEST}: $!\n";
        print $fh sort "@manifest";
        close($fh);
	print "Added $self->{Config}{Build_PL} to $self->{Config}{MANIFEST}\n";
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
PM                    pm_files
INSTALLDIRS           installdirs
DESTDIR               destdir
CCFLAGS               extra_compiler_flags
SIGN                  sign
LICENSE               license
clean.FILES           @add_to_cleanup
 
# default arguments 
-
recommends	      HASH
build_requires        HASH
conflicts	      HASH
license               unknown
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
pm_files
installdirs
destdir
add_to_cleanup
extra_compiler_flags
sign
license
create_makefile_pl

# begin code 
-

use Module::Build;

my $build = Module::Build->new
$INDENT(
# end code 
-
$INDENT);
  
$build->create_build_script;

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

Optional arguments:

=over 4

=item Path

Path to a Perl distribution. Default: undef

=item Makefile_PL

Filename of the Makefile script. Default: F<Makefile.PL>

=item Build_PL

Filename of the Build script. Default: F<Build.PL>

=item MANIFEST

Filename of the MANIFEST file. Default: F<MANIFEST>

=item Verbose

Verbose mode. If set to 1, overridden defaults and skipped arguments
are printed while converting; if set to 2, output of C<Verbose = 1> and
created Build script will be printed. May be set via the make2build 
switches C<-v> (mode 1) and C<-vv> (mode 2). Default: 0

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
 PM                    pm_files
 INSTALLDIRS           installdirs
 DESTDIR               destdir
 CCFLAGS               extra_compiler_flags
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
 pm_files
 installdirs
 destdir
 add_to_cleanup
 extra_compiler_flags
 sign
 license
 create_makefile_pl

=head2 Begin code

Code that preceeds converted C<Module::Build> arguments.

 use Module::Build;

 my $b = Module::Build->new
 $INDENT(

=head2 End code

Code that follows converted C<Module::Build> arguments.

 $INDENT);

 $b->create_build_script;

=head1 INTERNALS

=head2 co-opting C<WriteMakefile()>

In order to convert arguments, a typeglob from C<WriteMakefile()> to an internal
sub will be set; subsequently Makefile.PL will be executed and the
arguments are then accessible to the internal sub.

=head2 Data::Dumper

Converted C<ExtUtils::MakeMaker> arguments will be dumped by 
C<Data::Dumper's> C<Dump()> and are then furtherly processed.

=head1 SEE ALSO

L<http://www.makemaker.org>, L<ExtUtils::MakeMaker>, L<Module::Build>, 
L<http://www.makemaker.org/wiki/index.cgi?ModuleBuildConversionGuide>

=head1 AUTHOR

Steven Schubiger C<< <schubiger@cpan.org> >>	    

=cut
