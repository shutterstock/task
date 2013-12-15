package App::Task::ContentTracker;
use Moo;

use File::Spec::Functions qw( rel2abs abs2rel );
use Cwd qw( getcwd );
use Term::ANSIColor;
use IO::Interactive qw( is_interactive );

has 'current_branch' => (
	is => 'rw',
	lazy => 1,
	builder => '_build_current_branch',
	clearer => '_clear_current_branch',
);

has 'all_branches' => (
	is => 'ro',
	lazy => 1,
	builder => '_build_all_branches',
	clearer => '_clear_all_branches',
);

no Moo;

sub get_repository_root {
	my ($abs_top_level_dir) = App::Task::Base->system_call("git rev-parse --show-toplevel");
	chomp $abs_top_level_dir;
	return $abs_top_level_dir;
}

sub create_deployment_branch {
	my ($self, $branch) = @_;

	# get the branch name for the task so we can calculate the merge-base
	my $task_branch_name = $self->get_branch_name($branch);

	# create the deployment branch
	my $deployment_branch_name = $self->get_next_deployment_branch_name($branch);

	my $mainline_branch = App::Task::Config->config->{mainline_branch};
	my ($merge_commit) = App::Task::Base->system_call("git merge-base $task_branch_name $mainline_branch", ignore_exit_status => 1);

	$self->_create_branch($deployment_branch_name, $merge_commit);

	return $deployment_branch_name;
}

sub _create_branch {
	my ($self, $branch_name, $start_ref) = @_;

	my $mainline_branch = App::Task::Config->config->{mainline_branch};
	my @branches = @{$self->all_branches};

	if (!$start_ref) {
		if (scalar grep { /^remotes\/origin\/$mainline_branch/ims } @branches) {
			$start_ref = "origin/$mainline_branch";
		} else {
			$start_ref = $mainline_branch;
		}
	}

	# get the original branch (what we're currently on)
	my $original_branch = $self->get_current_branch;
	my $current_dir = getcwd;

	if (scalar grep { /^\Q$branch_name/i } @branches) {
		# check if the branch name exists
		# and switch to it if it does
		my ($output) = App::Task::Base->system_call("git checkout $branch_name", combine => 1);
		print $output;
	} elsif (scalar grep { /^remotes\/origin\/\Q$branch_name\E$/i } @branches) {
		# if it exists on origin, then just check that out
		my ($output) = App::Task::Base->system_call("git checkout --track -b $branch_name origin/$branch_name");
		print $output;
	} else {
		# or create it if it doesn't
		App::Task::Base->system_call("git checkout --no-track -b $branch_name $start_ref");

		print "Created and switched to branch '$branch_name' from $start_ref\n";

		# set upstream only for task branches off of the mainline
		if ($start_ref eq "origin/$mainline_branch") {
			App::Task::Base->system_call("git branch --set-upstream $branch_name $start_ref");
		}
	}

	$self->_clear_all_branches;
	$self->current_branch($branch_name);

	return $branch_name;
}

sub add_files_to_new_deployment_branch {
	my ($self, $branch, $files) = @_;
	die "No branch specified to add files to" if !$branch;

	# get the original branch (what we're currently on)
	my $original_branch = $self->get_current_branch;
	my $current_dir = getcwd;

	# get the branch name for the task
	my $branch_name = $self->create_deployment_branch($branch);

	$self->_add_files_to_branch(
		source_branch => $original_branch,
		target_branch => $branch_name,
		current_dir   => $current_dir,
		files         => $files,
	);

	return $branch_name;
}

sub _add_files_to_branch {
	my ($self, %args) = @_;

	my $original_branch = $args{source_branch} or die 'no target branch';
	my $branch_name     = $args{target_branch} or die 'no target branch';
	my $current_dir     = $args{current_dir} || getcwd;
	my @files = @{$args{files} || []};

	# change into root dir
	chdir $self->get_repository_root;

	# merge each file existing on the original branch
	my $file_list = join(' ', map { "'$_'" } @files);

	# checkout the file to the branch
	App::Task::Base->system_call("git checkout $original_branch $file_list");

	# and make sure it's committed
	# and don't bother to run tests since we won't handle it correctly if they fail
	App::Task::Base->system_call("git commit -n -m \"Added files: $file_list to branch $branch_name from branch $original_branch\"", ignore_exit_status => 1);

	# switch back to the original branch
	App::Task::Base->system_call("git checkout $original_branch");

	chdir $current_dir;

	if ($original_branch ne $branch_name) {
		print "Added the following " . (scalar(@files) == 1 ? 'file' : 'files'). " from branch '$original_branch' into branch '$branch_name': $file_list\n";
	} else {
		print((scalar(@files) == 1 ? 'File is' : 'Files are') . " already in branch '$branch_name': $file_list\n");
	}
}

sub get_deployed_envs {
	my ($self, $branch_name) = @_;

	# find all the remote branches that contain the current tip of the branch
	my ($remote_branches) = App::Task::Base->system_call("git branch -r --contains $branch_name");

	my %env_names = map { $_ => 1 } keys %{App::Task::Base->environments};

	my %deployed_envs;
	for my $raw_branch (split("\n", $remote_branches)) {
		my ($remote) = $raw_branch =~ / *\*? *origin\/(\w+)$/;

		# skip branches that aren't master branches
		next if !$remote;

		# skip branches that aren't env remotes
		next if !exists $env_names{$remote};

		$deployed_envs{$remote} = 1;
	}

	return \%deployed_envs;
}

sub get_current_branch {
	my ($self) = @_;
	return $self->current_branch;
}

sub _build_current_branch {
	my ($self) = @_;

	my ($branches) = App::Task::Base->system_call("git branch");
	my ($current_branch) = $branches =~ /^\* ([^\n]+)/ims;
	return $current_branch;
}

sub _build_all_branches {
	my ($self) = @_;

	my ($branches) = App::Task::Base->system_call("git branch -a");
	my @branches;
	for my $branch (split /^/, $branches) {
		chomp $branch;
		$branch =~ s/^(\*?)[ \t]*(.*)[ \t]*$/$2/;
		$self->current_branch($branch) if $1;
		push @branches, $branch;
	}

	return \@branches;
}

sub unique_branches {
	my ($self) = @_;

	my (%branches, @branches);
	for my $branch (@{$self->all_branches}) {
		my $non_origin_branch = $branch;
		$non_origin_branch =~ s/^remotes\/origin\///;
		next if exists $branches{$non_origin_branch};

		$branches{$non_origin_branch} = 1;
		push @branches, $non_origin_branch;
	}

	return \@branches;
}

sub get_branches_by_prefix {
	my ($self, $prefix) = @_;

	my @branches = @{$self->unique_branches};
	my @matches = grep { /^\Q$prefix/ } @branches;
	return @matches;
}

sub get_branch_name {
	my ($self, $branch) = @_;
	if ($branch) {
		my @existing_branches_matching = $self->get_branches_by_prefix($branch);
		if (grep { $_ eq $branch } @existing_branches_matching) {
			# if $branch *is* a branch name, assume that's what they meant, don't complain if there
			# exist other branches with names that are suffixes of it :)
			return $branch;
		}

		# Deploy branches don't count against us for ambiguity, we just want the non-deploy branches.
		@existing_branches_matching = grep { !/[\/-]deploy\d+$/ } @existing_branches_matching;
		if (@existing_branches_matching > 1) {
			die "Ambiguous branch specified $branch:\n", join("\n", map "  $_", @existing_branches_matching);
		}
		if (@existing_branches_matching) {
			return $existing_branches_matching[0];
		}
		return $branch;
	} else {
		return $self->get_current_branch;
	}
}

sub get_next_deployment_branch_name {
	my ($self, $branch) = @_;

	my @existing = $self->get_all_deployment_branches($branch);
	my $deployment_branch_count = 0;
	for my $branch_name (@existing) {
		if ($branch_name =~ /[\/-]deploy(\d+)$/i) {
			$deployment_branch_count = $1 if $1 > $deployment_branch_count;
		}
	}

	return "$branch-deploy" . ($deployment_branch_count + 1);
}

sub get_all_deployment_branches {
	my ($self, $branch) = @_;
	my @branches = @{ $self->unique_branches };
	my %deployment_branches;
	for my $branch_name (@branches) {
		if ($branch_name =~ /^($branch[\/-]deploy(\d+))/ims) {
			$deployment_branches{$2} = $1;
		}
	}
	return map { $deployment_branches{$_} } sort { $a <=> $b } keys %deployment_branches;
}

# return the list of files that have changed between a task branch and an env branch
sub get_changed_files {
	my ($self, $branch, $commit_id, %options) = @_;

	my $branch_name;
	if ($options{branch_name}) {
		$branch_name = $options{branch_name};
	} else {
		$branch_name = $self->get_branch_name($branch);
	}

	my ($file_list, $error, $exit_status) = App::Task::Base->system_call("git diff --name-only \$(git merge-base $branch_name $commit_id) $branch_name", ignore_exit_status => 1);
	chomp $file_list;

	my @files = map { s/^\s*|\s*$//ms; $_ } split(/\n/, $file_list);
	return @files;
}

# merge a branch and recover from it if it fails
sub safe_merge {
	my ($self, $merge_branch_name, $env_name, $target_branch, $options, $action) = @_;
	my $target_branch_name = App::Task::Base->environments->{$env_name}{branch_name};

	# merge branch into env branch, making sure the branch patch applies
#	print "git merge $options merge branch name: $merge_branch_name target_branch: $target_branch\n";

	my ($merge_output, $merge_errors, $exit_status) = App::Task::Base->system_call("git merge $options $merge_branch_name", ignore_exit_status => 1);
	if ($exit_status) {

#		# print any lines that git rerere fixed for us
#		while ($merge_output =~ /([^\n]*resolution[^\n]*)/ims) {
#			print "$1\n";
#		}

		my @bad_files = $self->get_conflicted_files;

#		# git rerere can record merge conflict resolutions and automatically commit them
#		# so if there aren't any files, rerere probably fixed it?
#		return if !scalar @bad_files;

		my $remote_task_branch_exclude = '';
		if ($action eq 're-ready') {
			print "merging local branch $merge_branch_name into $env_name/$merge_branch_name failed\n";
			$remote_task_branch_exclude = " ^$target_branch";
		} elsif ($action eq 'ready') {
			print "merging local branch $merge_branch_name into origin/$target_branch_name to create $merge_branch_name on $env_name failed\n";
		} elsif ($action eq 'deploy') {
			print "merging local branch $merge_branch_name into origin/$target_branch_name failed\n";
		} else {
			print "merging local branch $merge_branch_name into $target_branch failed\n";
		}
		print "See the entire problem through 'git diff ^origin/$target_branch_name$remote_task_branch_exclude $merge_branch_name'\n";
		print "This probably means that another task that has been pushed to $env_name conflicts with branch $merge_branch_name. 'git blame' on conflicting files and git branch -r contains <commit_id> for lines with conflicts, should give you enough information to find out which task branch is conflicting. It is recommended to add one branch to the other and make one dependent on the other to make it so you won't have to fix conflicts at every environment deploy\n\n";
		print "-----------------\n\n";

		print `git diff`;

		print "\n\nHow do you want to resolve this conflict?\n";

		my $response = App::Task::Base->prompt(
			s       => 'open a shell to fix the merge manually',
			default => 'reset',
		);

		eval {
			if ($response =~ /open a shell/i) {
				print "Fix your conflict and commit\n";
				print "Exit shell to finish the deployment\n";

				# note: this is a bash shell inside of the command
				# exiting the shell will continue the deployment normally
				system('bash');
			} else {
				die "Exiting";
			}

			my @remaining_bad_files = $self->get_conflicted_files;
			if (@remaining_bad_files) {
				die "You didn't fix: @remaining_bad_files\n";
			}
			print "conflicts resolved\n";
		};
		if ($@) {
			print "Resetting merge...\n";
			App::Task::Base->system_call("git reset --merge");
			# put us back where we started
			die color('red') . "Can't continue after a failed merge to environment: $env_name\n$@\n" . color('reset');
		}
	}
}

# get a list of files with conflicts
sub get_conflicted_files {
	my $self = shift;
	my $output = `git status -s`;
	chomp $output;
	my @files = split("\n",$output);

	my $relative_to_root = App::Task::Config->config->{repo_root};

	my @conflicted_files;
	for my $file (@files) {
		if (my ($path) = $file =~ /^ *U\w+ *(.*)/) {
			push @conflicted_files, "$relative_to_root$path";
		}
	}
	return @conflicted_files;
}

sub update_remotes {
	my ($self) = @_;

	# do our best to only call 'git remote update' once when needed,
	# since it's a pretty expensive operation and can slow everything down
	if (App::Task::Config->get_option('needs-update')) {
		my $msg = "Updating remote git repositories...";
		print $msg if is_interactive();
		App::Task::Base->system_call("git remote update --prune");
		printf("\r%s\r", ' ' x length($msg)) if is_interactive();
		App::Task::Config->set_option('needs-update' => 0);
	}
}


1;
__END__

=head1 NAME

B<App::Task::ContentTracker> - module to track branches and other content that should be grouped together

=head1 SYNOPSIS

[quick summary of what the module does]

Usage example:

=over 4

	use App::Task::ContentTracker;

	my $foo = App::Task::ContentTracker->new();
	...

=back

=head1 FUNCTIONS

=over 4

=item add_files_to_new_task

add specified files to a brand new task

=item get_branch_name

=item get_changed_files

=item get_current_branch

=item get_deployed_envs

=item get_repository_root

=item get_local_branch_start

=item safe_merge

merge safely, meaning merge and if it fails, reset the merge and die

=item get_shared_branch_name

Returns the name of the branch if it has already been deployed to a shared environment

=item add_files_to_new_deployment_branch

add new files to a new deployment branch for individual file deployment

=item create_deployment_branch

create a deployment branch for deploying individual files

=item get_next_deployment_branch_name

return the next deployment branch name. Formatted like <branch-name>-deploy<number>

=item get_all_deployment_branches

return a list of all individual file deployment branches that exist for a task

=item get_conflicted_files

get list of conflicted files

=cut

=back

=cut
