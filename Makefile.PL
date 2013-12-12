use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
	NAME                => 'App::Task',
	AUTHOR              => q{Travis Beck <travis@shutterstock.com>},
	ABSTRACT            => 'Git-based task release management tool',
	VERSION_FROM        => 'lib/App/Task/Base.pm',
	($ExtUtils::MakeMaker::VERSION >= 6.3002
		? ('LICENSE'=> 'Proprietary')
		: ()),
	PL_FILES            => {},
	PREREQ_PM => {
		'IO::CaptureOutput'    => 0.00,
		'IO::Interactive'      => 0.00,
		'Term::ANSIColor'      => 0.00,
		'Getopt::Long'         => 0.00,
		'YAML'                 => 0.00,
		'Moo'                  => 0.00,
		'Types::Standard'      => 0.00,
	},
	"TEST_REQUIRES" => {
		"Test::Most"           => 0
		'Test::Class'          => 0.00,
		'File::Slurp'          => 0.00,
		'Carp'                 => 0.00,
	},
	dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
	clean               => { FILES => 'App-Task-*' },
);
