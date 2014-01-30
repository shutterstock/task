package App::Task::Command::Ready;
use Moo;

use Term::ANSIColor;
use App::Task::Config;

with 'App::Task::Command';

App::Task::Config->register_command( ready => 'Pre-merge a task branch with an environment branch for later deployment' );

sub BUILD {
	my ($self, $args) = @_;

	$self->parse_options(
		'help|h'                => sub { $self->usage },
	);

	# get the env from the command line
	$self->set_environment($args->{destination_environment});

	if (scalar @ARGV and !$self->task_branch) {

		my @files;
		while (my $arg = pop @ARGV) {
			if ($arg =~ /-deploy\d+$/ && $self->add_task($arg)) {
				$self->set_deployment_branch($arg);
			} elsif (!$self->add_task($arg)) {
				# create a list of deployable files and only deploy those if specified
				my $file = $self->resolve_file($arg);
				push @files, $file;
			}
		}

		if (@files) {
			# if explicit files were specified, create a sub-branch to deploy just those
			my $deployment_branch = $self->content_tracker->add_files_to_new_deployment_branch($self->task_branch, \@files);
			$self->set_deployment_branch($deployment_branch);
		}
	}

}

sub run {
	my ($self) = @_;

	# if we were called directly by App::Task::Base, then this means the command was called directly and we should send notifications
	# otherwise, we're operating as part of another command, so we shouldn't send out notifications about this specific operation
	# this makse some major assumtions about the way that 'around' is implemnted in Moose. We shouldn't rely on this in the long run
	my $is_final_command = (caller(4))[0] =~ /^App::Task::Base$/ ? 1 : 0;

	my (@changed_files, @ready_tasks, $diff_stat);

	my $env_name = $self->env->{name};
	my ($remotes) = App::Task::Base->system_call("git remote");
	my %remotes = map { $_ => 1 } split(/\n/, $remotes);
	if (!exists $remotes{'origin'}) {
		die color('red') . "You don't have a remote set up. Please re-clone the repository" . color('reset');
	}

	my $original_branch = $self->content_tracker->get_current_branch;
	my $merge_commit_id;

	my $repository_root = $self->content_tracker->get_repository_root;
	my $task_branch = $self->task_branch;

	my $branch_name = $self->content_tracker->get_branch_name($task_branch);

	# ready the main task branch or a deployment branch if that was specified
	my $deployment_branch_name = $self->get_deployment_branch || $branch_name;

	my $deployed_envs = $self->content_tracker->get_deployed_envs($deployment_branch_name);

	# deploy to the dependent env first if there is one
	my $dependent_env = $self->env->{dependent_environment};
	if (defined $dependent_env and !exists $deployed_envs->{$dependent_env}) {
		my $dependent_deploy = App::Task::Command::Deploy->new(
			destination_environment => $self->env->{dependent_environment},
			content_tracker         => $self->content_tracker,
			deployment_branch       => $self->get_deployment_branch,
		);
		$dependent_deploy->add_task($task_branch);
		$dependent_deploy->run;
	}

	# make sure we are where we started
	App::Task::Base->system_call("git checkout $original_branch");
	$self->content_tracker->_clear_current_branch;

	my $remote_task_branch_name = '';
	my $allow_ready = $self->env->{allow_ready};
	if (!$allow_ready) {
		($remote_task_branch_name) = map { /^\s*(origin\/$deployment_branch_name)$/ims ? $1 : ()} `git branch -r`;
	} else {
		($remote_task_branch_name) = map { /^\s*(origin\/$env_name-ready\/$deployment_branch_name)$/ims ? $1 : ()} `git branch -r`;
	}

	# create a temporary local branch to make sure your changes will apply
	my $temp_branch_name = "temp_${env_name}_merge_$deployment_branch_name";
	eval {
		my $diff_branch = $temp_branch_name;
		my $env_branch_name = App::Task::Base->environments->{$env_name}{branch_name};

		if ($remote_task_branch_name) {
			# make a local copy of the remote task branch if it exists
			App::Task::Base->system_call("git checkout -b $temp_branch_name $remote_task_branch_name");
			$self->content_tracker->_clear_current_branch;
		} elsif ($allow_ready) {
			# branch off the remote env branch if there isn't a remote task branch and we are
			# pre-merging so that people deploying to higher envs won't have merge conflicts
			App::Task::Base->system_call("git checkout -b $temp_branch_name origin/$env_branch_name");
			$self->content_tracker->_clear_current_branch;
		} else {
			# if we aren't pre-merging, then just use the branch we're pushing
			App::Task::Base->system_call("git checkout -b $temp_branch_name $deployment_branch_name");
			$self->content_tracker->_clear_current_branch;
			$diff_branch = "origin/$env_branch_name";
		}

		# get the list of files that will be changed for each task
		@changed_files = $self->content_tracker->get_changed_files($task_branch, $diff_branch, branch_name => $deployment_branch_name);

		if ($is_final_command) {
			($diff_stat) = App::Task::Base->system_call("git diff -p --stat --color '$diff_branch'...'$deployment_branch_name'", ignore_exit_status => 1);
		}

		# merge branch into env branch, making sure the branch patch applies
		# (it dies if it doesn't)
		$self->content_tracker->safe_merge($deployment_branch_name, $env_name, $temp_branch_name, '--no-ff --log', $remote_task_branch_name ? 're-ready' : 'ready');

		# merge the remote env branch into the temp branch to make sure that it applies
		if ($allow_ready) {
			$self->content_tracker->safe_merge("origin/$env_branch_name", $env_name, $temp_branch_name, '--no-ff --log', $remote_task_branch_name ? 're-ready' : 'ready');
		}

		# get the commit id for the tip of the merged branch
		chomp(($merge_commit_id) = App::Task::Base->system_call("git rev-parse '$temp_branch_name'"));

		push(@ready_tasks, $task_branch);

		# push your local version of the task branch to destination env remote
		if (!$allow_ready) {
			App::Task::Base->system_call("git push origin 'HEAD:$deployment_branch_name'");
		} else {
			App::Task::Base->system_call("git push origin 'HEAD:$env_name-ready/$deployment_branch_name'");
		}
		App::Task::Base->system_call("git checkout $original_branch");
		App::Task::Base->system_call("git branch -D $temp_branch_name");
		$self->content_tracker->_clear_current_branch;
	};
	if ($@) {
		# make sure we clean up, even if we fail
		App::Task::Base->system_call("git checkout $original_branch");
		App::Task::Base->system_call("git branch -D $temp_branch_name", ignore_exit_status => 1);
		$self->content_tracker->_clear_current_branch;

		# re-throw merge conflicts
		App::Task::Base->instance->highlighted_die($@);
	}

	my $changed_file_count = scalar @changed_files;
	if ($changed_file_count) {
		print "\n$changed_file_count " . ($changed_file_count > 1 ? 'files' : 'file') . " ready for $env_name\n";
	} else {
		print "\nNo changed files to set as ready for $env_name\n";
		return;
	}

	# list the files to be deployed
	print join('', map { "\t$deployment_branch_name\t$_\n" } @changed_files);
	print "\n";

	print "ready for $env_name - commit id: $merge_commit_id\n";
	my $github_url = App::Task::Config->config->{github_url};
	my $env_branch_name = App::Task::Base->environments->{$env_name}{branch_name};
	if ($github_url) {
		print "View the full diff here: $github_url/compare/$env_branch_name...$merge_commit_id\n";
	}

	return $deployment_branch_name;
}

sub usage {
	my ($self, $message) = @_;

	print <<"END_USAGE";
Usage: task ready [-hn] environment <branch_name>

Pre-merge task branches and set them as ready for deployment without actually deploying them

Options:

    -h, --help     Show a brief help message and exit
END_USAGE

	print "\n$message\n" if $message;

	exit 1;
}

1;
