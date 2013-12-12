package App::Task::Command::Start;
use Moo;

use App::Task::Config;

with 'App::Task::Command';

App::Task::Config->register_command( start => 'Start work on a new or existing task branch' );

sub BUILD {
	my ($self, $args) = @_;

	$self->parse_options(
		'help|h'       => sub { $self->usage },
	);

	# take the last command line arg if it specifies a task
	my $arg = shift @ARGV;
	if ($arg) {
		$self->task_branch($arg);
	}

	$self->{allow_branch_switch} = 1;

	$self->usage("No feature branch name specified to start work on") if !$self->task_branch;
}

sub run {
	my ($self) = @_;

	$self->content_tracker->update_remotes;

	if (my $branch = $self->task_branch) {
		$self->create_task_branch($branch);
	}
}

sub create_task_branch {
	my ($self, $branch) = @_;

	# get the branch name for the task
	my $branch_name = $self->content_tracker->get_branch_name($branch);

	$self->content_tracker->_create_branch($branch_name);
}

sub usage {
	my ($self, $message) = @_;

	print "$message\n\n" if $message;

	print <<"END_USAGE";
Usage: task start [-h] <branch_name>

Properly starts a task branch from your mainline branch

Options:

    -h, --help     Show a brief help message and exit

Examples:

    task start feature/docs

    creates a branch feature/docs from origin/master
    or checks it out if someone else already created it
END_USAGE

	exit 1;
}

1;
