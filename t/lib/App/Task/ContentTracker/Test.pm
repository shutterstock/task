package App::Task::ContentTracker::Test;

use strict;
use warnings;

use base qw( App::Task::TestClass );

use Test::Most;

sub startup : Test(startup => 1) {
	my ($test) = @_;

	# make sure the parent class startup is run first
	$test->SUPER::startup;
}

sub create : Tests(1) {
	my ($test) = @_;

	my $instance = $test->class->new();
	ok $instance->isa('App::Task::ContentTracker'), "Module is a App::Task::ContentTracker";
}

1;
