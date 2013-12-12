package App::Task::TestClass;

use Test::Most;
use base qw( Test::Class Class::Data::Inheritable );

use File::Spec::Functions qw( rel2abs );
use File::Basename qw( dirname );
use File::Slurp qw( slurp write_file );
use Carp qw( confess );

my $exit_count = 0;

BEGIN {
	# add a 'class' method that is inheritable
	__PACKAGE__->mk_classdata('class');

	# override 'exit' to just die
	*CORE::GLOBAL::exit = sub { $exit_count++; confess "Exit called: $exit_count" };
}

my $data_dir;
my $config_file_name = 'deployment.yaml';

# make sure the class loaded ok
sub startup : Tests( startup => 1 ) {
	my ($test) = @_;
	my $class = ref $test;
	$class =~ s/::Test$//;

	# get the directory for the running executable
	my $base_dir = dirname rel2abs $0;
	$test->{base_dir} = $base_dir;
	my $username = getpwuid($>);
	$data_dir = "/tmp/test-app-task-$username";
	$test->{data_dir} = $data_dir;

	# clear out the data_dir
	`rm -rf $data_dir` if -e "$data_dir";
	mkdir $data_dir or die "Couldn't create dir $data_dir: $!";

	# copy the deployment config into the data dir and make sure it has the right base directory
	my $config = slurp "$base_dir/$config_file_name";
	write_file $test->config_file_path, $config;

	# for this actual base class, this skips everything else
	return ok 1, "$class loaded" if $class eq __PACKAGE__;
	use_ok $class or die;

	# set up the class method so it returns the name of the class being tested
	$test->class($class);
}

# globally override a function
sub override_function {
	my ($class, $fully_qualified_name, $new_function) = @_;

	no strict 'refs';
	no warnings;
	*$fully_qualified_name = $new_function;
}

sub shutdown : Test( shutdown ) {
	my ($test) = @_;
	`rm -rf $data_dir` if -e $data_dir;
}

sub config_file_path { return "$data_dir/$config_file_name" }
sub data_dir { return $data_dir }

sub exit_count { return $exit_count }

1;
