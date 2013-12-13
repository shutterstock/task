requires 'IO::CaptureOutput'    => 0.00;
requires 'IO::Interactive'      => 0.00;
requires 'Term::ANSIColor'      => 0.00;
requires 'Getopt::Long'         => 0.00;
requires 'YAML'                 => 0.00;
requires 'Moo'                  => 0.00;
requires 'Types::Standard'      => 0.00;

on test => sub {
	requires 'Test::Most'      => 0.00;
	requires 'Test::Class'     => 0.00;
	requires 'File::Slurp'     => 0.00;
	requires 'Carp'            => 0.00;
};

on develop => sub {
	requires 'App::FatPacker'  => 0.00;
	requires 'Perl::Strip'     => 0.00;
	requires 'File::Find'      => 0.00;
	requires 'File::pushd'     => 0.00;
	requires 'Module::CoreList' => 3;
};
