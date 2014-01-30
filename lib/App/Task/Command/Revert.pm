package App::Task::Command::Revert;
use Moo;

use App::Task::Config;

with 'App::Task::Command';

App::Task::Config->register_command( revert => 'Remove all of a task branch changes from a given environment and all dependent envs' );

sub BUILD {
	my ($self, $args) = @_;

	$self->parse_options(
		'help|h'      => sub { $self->usage },
	);

	$self->set_environment($args->{destination_environment});

	my $branch_name = $self->env->{branch_name};
	$self->content_tracker->update_remotes;
	my ($branch_tip, $err, $exit_status) = App::Task::Base->system_call("git rev-parse 'origin/$branch_name'", ignore_exit_status => 1);
	if (!$branch_tip or $exit_status) {
		$self->usage("No branch origin/$branch_name exists. Create it to do something useful");
	}
}

sub run {
	my ($self) = @_;

	App::Task::Config->set_option('needs-update' => 1);
	$self->content_tracker->update_remotes;

	my $env_name = $self->env->{name};
	my $env_branch = $self->env->{branch_name};

	my $original_branch = $self->content_tracker->get_current_branch;
	my $task_branch = $self->content_tracker->get_branch_name($self->task_branch);
	my $branch_start = $self->content_tracker->get_branch_start($task_branch);

	my $temp_branch = "temp_revert_from_$env_name";
	App::Task::Base->system_call("git checkout -b $temp_branch remotes/origin/$env_branch");
	$self->content_tracker->_clear_current_branch;

	chomp(my @commits = `git log --merges --pretty="%H %s" $branch_start...remotes/origin/$env_branch`);
	for my $commit (@commits) {
		my ($sha, $msg) = split / /, $commit, 2;

		if ($msg =~ /Merge branch '\Q$task_branch\E(?:-deploy\d+)?'|from branch \Q$task_branch\E/) {
			my ($out, $err, $status) = App::Task::Base->system_call("git revert --no-edit -m 1 $sha", ignore_exit_status => 1);
			if ($status && $out !~ /nothing to commit/) {
				FIX: {
					print "Merge conflict: $out:$err:$status\n";
					my $response = App::Task::Base->prompt(
						s => 'open a shell to fix the merge manually',
						default => 'reset',
					);
					if ($response =~ /open a shell/) {
						print "Fix your conflict and commit\n";
						print "Exit shell to finish the deployment\n";
						system('bash');
					} else {
						App::Task::Base->system_call("git reset --merge");
						die "exiting\n";
					}
					redo FIX if $self->content_tracker->get_conflicted_files;
				}
			}
		}
	}
	# Squash it all into one commit
	App::Task::Base->system_call("git reset --soft remotes/origin/$env_branch");
	App::Task::Base->system_call("git commit -nm 'Reverted $task_branch from $env_name'");
	my ($diffstat) = App::Task::Base->system_call("git diff --stat=120,100 'remotes/origin/$env_branch' '$temp_branch'");
	print "Deploying the following changes to $env_name:\n$diffstat\n";
	print "Enter 'y' to continue, anything else to exit: ";
	chomp (my $response = <STDIN>);
	if (lc $response eq 'y') {
		App::Task::Base->system_call("git push origin $temp_branch:$env_branch");
	}
	App::Task::Base->system_call("git checkout '$original_branch'");
	App::Task::Base->system_call("git branch -D '$temp_branch'");
	$self->content_tracker->_clear_current_branch;
}

sub usage {
	my ($self, $message) = @_;
	print <<"END_USAGE";
Usage: task revert <environment> <branch_name>
END_USAGE

	print "\n$message\n" if $message;
}

1;
