# Note: this file has been initially created by Make::Build::Convert 0.20_01

use Module::Build;

my $build = Module::Build->new
  (
   module_name => 'Make::Build::Convert',
   dist_author => 'Steven Schubiger <schubiger@cpan.org>',
   dist_version_from => 'lib/Make/Build/Convert.pm',
   requires => { 
                 Carp => 0,
                 Cwd => 0, 
		 Data::Dumper => 0,
		 ExtUtils::MakeMaker => 0,
		 File::Basename => 0,
		 File::HomeDir => 0,
		 File::Slurp => 0,
		 File::Spec => 0,
		 Getopt::Long => 0,
		 IO::File => 0,
               },
   build_requires => { 
                       Test::More => 0,
                       Test::Pod => 1.14,
		       Test::Pod::Coverage => 1.04,
		     },
   script_files => [ 'scripts/make2build' ],
   license => 'perl',
   create_readme => 1,
   create_makefile_pl => 'passthrough',
  );
  
$build->create_build_script;
