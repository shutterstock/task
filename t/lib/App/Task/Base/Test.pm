package App::Task::Base::Test;

use strict;
use warnings;

use Test::Most;
use IO::CaptureOutput qw( capture );
use base 'App::Task::TestClass';

sub stdout_like (&@) {
	my ($test, $expected, $description) = @_;
	my $stdout = stdout_from($test);
#	print $stdout;
	like $stdout, $expected, $description;
}

sub stdout_from {
	my ($test) = @_;
	my $stdout;
	capture { &$test } \$stdout;
	return $stdout;
}

sub constructor : Tests(14) {
	my ($test) = @_;
	my $class = $test->class;

	can_ok $class, 'new';
	dies_ok { $class->new } 'new dies with no arguments';
	stdout_like { dies_ok { $class->new( ) } } qr/Can't read config file: deployment\.yaml/, 'new dies with no config file';
	stdout_like { dies_ok { $class->new( config_file => 'asdf' ) } } qr/Can't read config file: asdf/, 'new dies with non-existent config file';

	my $exit_count = $test->exit_count;
	my $task = $class->new( config_file => $test->config_file_path );
	stdout_like { eval { $task->run } } qr/Usage:/, 'run dies with usage when with no command specified';
	ok $test->exit_count > $exit_count , "make sure that we exited properly";

	require App::Task::Command::Status;

	@ARGV = qw( status );
	my $base;
	lives_ok { $base = $class->new( config_file => $test->config_file_path ) } 'new lives with valid command';
	isa_ok $base, $class, 'Check the object it returns';
	is App::Task::Config->find_command('status')->{module}, 'App::Task::Command::Status', 'Check that the module name is correct';

	@ARGV = qw( foo );
	lives_ok { $base = $class->new( config_file => $test->config_file_path ) } 'new lives with invalid command';
	stdout_like { eval { $task->run } } qr/Invalid command/, 'run dies with usage when there is an invalid command specified';
	is App::Task::Config->find_command('foo'), undef, "Check that the module isn't found";
}

1;
