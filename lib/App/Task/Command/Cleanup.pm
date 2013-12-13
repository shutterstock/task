package App::Task::Command::Cleanup;
use Moo;

use App::Task::Config;

with 'App::Task::Command';

App::Task::Config->register_command( cleanup => 'Cleanup branches that have been deployed or abandoned' );

sub BUILD {
	my ($self, $args) = @_;

	# set some defaults
	my $deployed_to_env = 'prod';
	my $days            = 7;

	$self->parse_options(
		'help|h'   => sub { $self->usage },
		'delete|d' => sub { App::Task::Config->set_option('delete-task-branches' => 1) },
		'days=i'   => \$days,
		'deployed-to=s' => \$deployed_to_env,
	);
	# TODO: add a --production option that will make sure branch tips are the same and delete them

	# make sure the specified environment is a valid one
	die "Invalid env '$deployed_to_env'" if !defined App::Task::Base->environments->{$deployed_to_env};

	App::Task::Config->set_option('deployed-to' => $deployed_to_env);
	App::Task::Config->set_option('days-since-last-commit' => $days);

	for my $arg (@ARGV) {
		if (!$self->add_task($arg)) {
			print "Unknown option: $arg\n";
		}
	}
}

sub run {
	my ($self) = @_;

	$self->content_tracker->update_remotes;

	my ($local_branches) = App::Task::Base->system_call("git branch");
	my ($current_branch) = $local_branches =~ /^\* ([^\n]+)/ims;

	LOCAL_BRANCH:
	for my $raw_branch (split /\n/, $local_branches) {
		my ($branch_name) = $raw_branch =~ /^\*?[ \t]*\b(.*)/ims;

		# only deal with task branches
		# TODO: this should skip env branches, but doesn't right now
		next LOCAL_BRANCH if !$branch_name;

		# skip branches that weren't specified if branches were specified
		next LOCAL_BRANCH if $self->task_branch !~ /^\Q$branch_name/;

		my ($deployed_envs) = $self->content_tracker->get_deployed_envs($branch_name);
		my $target_env = App::Task::Config->get_option('deployed-to');

		# branches are removable when they are on integration (shared with other people) and on the target env
		if (defined $deployed_envs->{integration} and defined $deployed_envs->{$target_env}) {
			chomp(my ($last_commit_timestamp) = App::Task::Base->system_call("git log -1 --pretty=format:'%ct' '$target_env/$branch_name'", ignore_exit_status => 1));
			if (!$last_commit_timestamp) {
				chomp(my ($sha1) = App::Task::Base->system_call("git rev-parse $branch_name"));

				# it's possible that the branch was merged into another branch and deployed that way, so if you don't have the ref on the env, look up based on the local head
				chomp(($last_commit_timestamp) = App::Task::Base->system_call("git log -1 --pretty=format:'%ct' '$sha1'"));
			}

			my $actual_days_since_last_commit = int((time() - $last_commit_timestamp) / 86400);
			if ($actual_days_since_last_commit >= App::Task::Config->get_option('days-since-last-commit')) {
				print "Branch '$branch_name' has existed on $target_env for $actual_days_since_last_commit days and can be deleted\n";

				# delete the local branch if we're doing that
				if (App::Task::Config->get_option('delete-task-branches')) {
					system("git branch -D '$branch_name'");
				}
#			} else {
#				print "Branch '$branch_name' has only existed on $target_env for $actual_days_since_last_commit days\n";
			}
		}
	}
}

sub usage {
	my ($self, $message) = @_;

	print <<"END_USAGE";
Usage: task cleanup [-hd] <branch_name>

Show (and delete) task branches that have been deployed to production or another environment

Options:

    -h, --help                   Show a brief help message and exit
    -n, --noconfirm  Don't show a confirmation message before doing the deploy
    -d, --delete                 Delete the branches that exist on the target
                                 environment
    --deployed-to=<environment>  Sets the target environment for which task
                                 branches must have been deployed to.
                                 Defaults to what your mainline branch is set to
    --days=<number>              Make sure the task branches have existed on the
                                 target environment for at least this many days

Examples:

    task cleanup

Show local branches whose tips have existed on prod for at least 7 days

    task cleanup -d

Delete local branches whose tips have existed on prod for at least 7 days
END_USAGE

	print "\n$message\n" if $message;

	exit 1;
}

1;
