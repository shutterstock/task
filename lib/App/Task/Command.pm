package App::Task::Command;
use Moo::Role;
use Types::Standard qw(ArrayRef HashRef InstanceOf);

use Cwd qw( getcwd );
use Getopt::Long;
Getopt::Long::Configure( qw( no_ignore_case bundling pass_through permute ));

has 'environment'   => ( is => 'ro', isa => HashRef, reader => 'get_environment' );
has 'content_tracker' => ( is => 'ro', required => 1, isa => InstanceOf['App::Task::ContentTracker'], reader => 'content_tracker' );

has 'task_branch' => ( is => 'rw' );
has 'original_dir' => ( is => 'ro', default => sub { getcwd() }, reader => 'get_original_dir' );
has 'allow_branch_switch' => ( is => 'rw', default => sub { 0 } );
has 'deployment_branch' => ( is => 'rw', reader => 'get_deployment_branch', writer => 'set_deployment_branch' );

requires 'run';
requires 'usage';

around 'run' => sub {
	my ($next, $self, %options) = @_;

	my $original_branch = $self->content_tracker->get_current_branch;
	$self->content_tracker->update_remotes;

	# eval the run and make sure we end up in the same place we started
	my @returned_values;
	eval {
		@returned_values = $next->($self);
	};
	my $error;
	if ($@) {
		$error = $@;
	}

	$self->return_to_original_dir;
	my $current_branch = $self->content_tracker->get_current_branch;
	if ($current_branch ne $original_branch and !$self->allow_branch_switch) {
		App::Task::Base->system_call("git checkout '$original_branch'");
	}

	die $error if $error;

	return (@returned_values);
};

sub return_to_original_dir {
	my ($self) = @_;

	my $current_dir  = getcwd;
	my $original_dir = $self->get_original_dir;
	if ($original_dir ne $current_dir) {
		chdir $self->get_original_dir
			or die "Couldn't change back to $original_dir from $current_dir";
	}
}

sub set_environment {
	my ($self, $env) = @_;

	if ($env) {
		$self->{environment} = App::Task::Base->environments->{$env} or die "Invalid destination environment: $env";
	} else {

		my $destination_env = shift @ARGV;
		$self->usage("error: No environment specified") if !defined $destination_env;

		$self->{environment} = App::Task::Base->environments->{$destination_env};
		if (!defined $self->{environment}) {
			$self->usage("error: '$destination_env' is not a valid environment\nvalid environments are: " . join(', ', sort keys %{App::Task::Base->environments}));
		}
	}
}

sub env {
	my ($self) = @_;
	return $self->{environment};
}

sub add_task {
	my ($self, $branch_name) = @_;
	if (my ($valid_branch) = sort $self->content_tracker->get_branches_by_prefix($branch_name)) {
		$self->task_branch($valid_branch);
		return 1;
	}
	return 0;
}

sub resolve_file {
	my ($self, $path) = @_;

	my $relative_to_root = `git rev-parse --show-cdup`;
	chomp $relative_to_root;

	# if the relative path isn't in git, assume it is a canonical path
	# note that the file could be deleted, so we still have to check
	if (-e $path) {
		if ($relative_to_root) {
			return abs2rel(abs_path(rel2abs $path), $self->content_tracker->get_repository_root);
		} else {
			return $path;
		}
	}

	return $path if -e "$relative_to_root$path";

	die "Couldn't find file: $path";
}

sub parse_options {
	my ($self, %options) = @_;

	$options{'verbose|v+'} = \($App::Task::Config::options{verbose});

	# use Getopt::Long to get the command line options
	GetOptions(%options) or $self->usage;
};

no Moo::Role;
no Types::Standard;

1;
