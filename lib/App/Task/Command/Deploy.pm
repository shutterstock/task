package App::Task::Command::Deploy;
use Moo;

use Cwd qw( getcwd );
use Term::ANSIColor;
use App::Task::Config;
use App::Task::Hooks;

with 'App::Task::Command';

App::Task::Config->register_command( deploy => 'Deploy a task branch to a given environment (and all its dependent envs too)' );

sub highlighted_die {
	my ($message) = @_;
	# preserve last-line perl non-stack trace behavior
	$message =~ s/(\n?)\z/color('reset') . $1/e;
	die color('red') . $message;
}

sub BUILD {
	my ($self, $args) = @_;

	$self->parse_options(
		'help|h'      => sub { $self->usage },
		'noconfirm|n' => sub { App::Task::Config->set_option('noconfirm'  => 1)},
		'again'       => sub { App::Task::Config->set_option('redeploy' => 1)},
	);

	$self->set_environment($args->{destination_environment});

	my $branch_name = $self->env->{branch_name};
	$self->content_tracker->update_remotes;
	my ($branch_tip, $err, $exit_status) = App::Task::Base->system_call("git rev-parse 'origin/$branch_name'", ignore_exit_status => 1);
	if (!$branch_tip or $exit_status) {
		$self->usage("No branch origin/$branch_name exists. Create it to do something useful");
	}
	chomp $branch_tip;

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

	my $current_dir = getcwd;

	my $env_name = $self->env->{name};

	my @branches;
	TASK:
	my $task_branch = $self->task_branch;

	my $ready = App::Task::Command::Ready->new(
		destination_environment => $self->env->{name},
		content_tracker         => $self->content_tracker,
		deployment_branch       => $self->get_deployment_branch,
	);
	$ready->add_task($task_branch);

	my $branch_name = $ready->run;
	push(@branches, $branch_name);

	# find out what's changed between the local task branch and remote mainline
	my @unpushed_files;
	my @deployment_branches;
	my $target_branch_name = $self->env->{branch_name};
	$task_branch = $self->task_branch;

	my $current_branch_name = $self->content_tracker->get_branch_name($task_branch);

	# deploy the main task branch or a deployment branch if that was specified
	my $deployment_branch_name = $self->get_deployment_branch || $current_branch_name;

	my @files = $self->content_tracker->get_changed_files($task_branch, "origin/$target_branch_name", branch_name => $deployment_branch_name);
	push(@unpushed_files, @files);

	my $mainline_branch = App::Task::Config->config->{mainline_branch};

	# add all of the files that have been changed on the branch if we're redeploying
	if (App::Task::Config->get_option('redeploy')) {
		my $branch_start = $self->content_tracker->get_branch_start($deployment_branch_name);
		my ($file_list, $err, $exit_status) = App::Task::Base->system_call("git diff --name-only $branch_start...$env_name/$deployment_branch_name", ignore_exit_status => 1);
		if (!$exit_status) {
			chomp $file_list;

			my @files = map { s/^\s*|\s*$//ms; $_ } split(/\n/, $file_list);
			push(@unpushed_files, @files);
		}
	}

	push @deployment_branches, $deployment_branch_name;

	my $changed_file_count = scalar @unpushed_files;
	if ($changed_file_count) {
		print "$changed_file_count " . ($changed_file_count > 1 ? 'files' : 'file') . " to deploy to $env_name\n";
	} else {
		print "No changed files to deploy to $env_name";
		print "\n\n";
		return;
	}

	# quote our file lists just in case file names have spaces
	my $remote_files = join(' ', map { "'$_'" } @unpushed_files);

	my $original_branch = $self->content_tracker->get_current_branch;

	# once we do the merge, everything else should use exception handling to make sure
	my $temp_branch_exists = 0;
	eval {
		my %merged_branches;

		my $temp_branch_name = "temp_deploy_${env_name}";
		# checkout a copy of the remote master for copying/rsyncing
		App::Task::Base->system_call("git checkout --track -b '$temp_branch_name' origin/$target_branch_name");
		$self->content_tracker->_clear_current_branch;
		$temp_branch_exists = 1;

		for my $deployment_branch_name (@deployment_branches) {
			# ready should have already put the content here, so now we just need to merge the branch into master
			if (!$self->env->{allow_ready}) {
				$self->content_tracker->safe_merge($deployment_branch_name, $env_name, $target_branch_name, '', 'deploy');
			} else {
				$self->content_tracker->safe_merge("origin/$env_name-ready/$deployment_branch_name", $env_name, $temp_branch_name, '--ff-only', 'deploy');
			}

			$merged_branches{$deployment_branch_name} = 1;
		}

		# print diffstat of what we are deploying
		my ($diffstat) = App::Task::Base->system_call("git diff --stat=120,100 'origin/$target_branch_name'..'$temp_branch_name'");
		print "Deploying the following changes to $env_name:\n$diffstat\n";

		# this is as far as we can go before we have to start entering passwords and changing stuff
		if (!App::Task::Config->get_option('noconfirm')) {
			print "Enter 'y' to continue, anything else to exit: ";
			chomp(my $response = <STDIN>);
			if (lc $response ne 'y') {
				# make sure we're back in the original dir and branch
				$self->return_to_original_dir;

				App::Task::Base->system_call("git checkout $original_branch");
				App::Task::Base->system_call("git branch -D 'temp_deploy_$env_name'");
				$self->content_tracker->_clear_current_branch;
				die "Aborted by user";
			}
		}

		# push changes back to env repository
		App::Task::Base->system_call("git pull origin '$target_branch_name'");
		App::Task::Base->system_call("git push origin 'temp_deploy_$env_name:$target_branch_name'");
		print "Updated git $env_name branch\n";

		# make sure we are where we started, and get rid of the temp deployment branch
		# TODO: put in an END block so we can clean up after failure or ^c
		App::Task::Base->system_call("git checkout $original_branch");
		App::Task::Base->system_call("git branch -d 'temp_deploy_$env_name'");
		$self->content_tracker->_clear_current_branch;
		$temp_branch_exists = 0;

		my $current_dir = getcwd;

		# finish the pull requests
		my %deployed_branches;
		for my $branch_name (@branches) {
			$deployed_branches{$branch_name}++;
		}

		chomp( my ($deploy_sha) = App::Task::Base->system_call("git rev-parse HEAD") );

		my $hooks_ok = App::Task::Hooks->run_hooks($self, 'post_deploy', {
				TASK_DEPLOY_ENVIRONMENT => $env_name,
				TASK_DEPLOY_SHA => $deploy_sha,
		});

		die "Failed to run hooks" unless $hooks_ok;

		# when we're done with the deploy, merge down to dependent
		# environments, if we are doing that for this branch
		if ($self->env->{branch_name} eq App::Task::Config->config->{mainline_branch} and $self->env->{dependent_environment}) {

			# do one remote update right before merging back down to avoid fast-forward issues
			App::Task::Config->set_option('needs-update' => 1);
			$self->content_tracker->update_remotes;

			my $dependent_env_name = $self->env->{dependent_environment};
			$self->merge_back_to_dependent_environments($env_name, $dependent_env_name);
		}

		# go back to where we started
		chdir $current_dir or highlighted_die "Couldn't chdir to: $current_dir";
	};
	if ($@) {
		# make sure we're back in the original dir and branch
		$self->return_to_original_dir;

		App::Task::Base->system_call("git checkout $original_branch");
		App::Task::Base->system_call("git branch -D 'temp_deploy_$env_name'") if $temp_branch_exists;
		$self->content_tracker->_clear_current_branch;

		# and propagate the error
		die $@;
	} else {
		print color 'green';
		print "finished deploying to $env_name\n\n";
		print color 'reset';
	}
}

sub merge_back_to_dependent_environments {
	my ($self, $top_level_env, $dependent_env_name) = @_;
	my $top_level_env_branch = App::Task::Base->environments->{$top_level_env}{branch_name};
	my $dependent_env_branch = App::Task::Base->environments->{$dependent_env_name}{branch_name};

	# note that this should get called in an eval, so we can just die here on error

	my $temp_branch_name = "temp_merge_${top_level_env}_back_to_${dependent_env_name}";
	App::Task::Base->system_call("git checkout -b '$temp_branch_name' origin/$dependent_env_branch");
	$self->content_tracker->_clear_current_branch;

	$self->content_tracker->safe_merge("origin/$top_level_env_branch", $dependent_env_name, "origin/$dependent_env_branch", '', '');

	# push changes back to dependent env repository
	App::Task::Base->system_call("git push origin '$temp_branch_name:$dependent_env_branch'");

	# just get off of the branch so that we can delete it
	my $mainline_branch = App::Task::Config->config->{mainline_branch};
	App::Task::Base->system_call("git checkout $mainline_branch");
	App::Task::Base->system_call("git branch -D '$temp_branch_name'");
	$self->content_tracker->_clear_current_branch;

	print "Merged changes from $top_level_env back to $dependent_env_name\n";

	if (my $next_dependent_env = App::Task::Base->environments->{$dependent_env_name}{dependent_environment}) {
		$self->merge_back_to_dependent_environments($top_level_env, $next_dependent_env);
	} else {
		return;
	}
}

no Moo;

sub usage {
	my ($self, $message) = @_;

	print <<"END_USAGE";
Usage: task deploy [-hn] [--again] environment <branch_name>

Merge and deploy task branches

Options:

    -h, --help       Show a brief help message and exit
    -n, --noconfirm  Don't show a confirmation message before doing the deploy
    --again          Ignore if a branch has already been deployed to an
                     environment and re-deploy again anyway. Basically this
                     will rerun your hooks for this environment without merging
                     anything
END_USAGE

	print "\n$message\n" if $message;

	exit 1;
}

1;
