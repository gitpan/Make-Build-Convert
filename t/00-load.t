#!perl -T

use Test::More tests => 1;

BEGIN {
	use_ok('Make::Build::Convert');
}

diag("Testing Make::Build::Convert $Make::Build::Convert::VERSION, Perl $], $^X");
