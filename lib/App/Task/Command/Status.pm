package App::Task::Command::Status;
use Moo;

use Types::Standard qw(HashRef ArrayRef);
use Term::ANSIColor;
use IO::Interactive qw( is_interactive );
use App::Task::Config;

with 'App::Task::Command';

has 'envs'               => ( is => 'ro', isa => HashRef, default => sub { {} });
has 'visited_commits'    => ( is => 'rw', isa => HashRef, default => sub { return {} } );
has 'args'               => ( is => 'rw', isa => HashRef, default => sub { return {} } );
has 'ordered_envs'       => ( is => 'lazy', isa => ArrayRef );
has 'indent'             => ( is => 'rw', default => sub { 0 } );
has 'columns'            => ( is => 'lazy' );

$| = 1;

App::Task::Config->register_command( status => 'View the status of a task branch' );

sub _build_columns {
	my $self = shift;
	return unless is_interactive();
	my ($wchar) = $ENV{COLUMNS} || 80;
	return $wchar - 2;
};

sub BUILD {
	my ($self, $args) = @_;

	$self->args->{color}       = 1 if is_interactive();

	$self->parse_options(
		'help|h'            => sub { $self->usage },
		'diff|p!'           => \$self->args->{diff},
		'diff-options=s'    => \$self->args->{diff_options},
		'log|l!'            => \$self->args->{log},
		'log-options=s'     => \$self->args->{log_options},
		'color|colour|c!'   => \$self->args->{color},
		'all-commits!'      => \$self->args->{all_commits},
		'name-only!'        => \$self->args->{name_only},
	);

	my @new_argv;

	# if there isn't any task, default to the current branch
	if (!scalar @ARGV) {
		my $current_branch = $self->content_tracker->get_current_branch;
		$self->add_task( $current_branch );
	}
	for my $arg (@ARGV) {
		if (!$self->add_task($arg)) {
			push(@new_argv, $arg);
		}
	}

	if (scalar @new_argv) {
		$self->abort("Unrecognized option: '@new_argv'");
	}
	$self->usage if !$self->task_branch;
}

sub _build_ordered_envs {
	my $self = shift;

	my $environments = App::Task::Base->environments;
	my ($current_top_level_env) = map { $environments->{$_}{branch_name} eq App::Task::Config->config->{mainline_branch} ? $_ : () } keys %$environments;
	my @ordered_envs;

	# go through each environment from prod on down to wherever the dependency chain ends
	# based on a starting point and each dependent environment
	while ($current_top_level_env && defined $environments->{$current_top_level_env}) {
		push(@ordered_envs, $current_top_level_env);
		push(@ordered_envs, "ready for $current_top_level_env") if $environments->{$current_top_level_env}{allow_ready};
		$current_top_level_env = $environments->{$current_top_level_env}{dependent_environment} || undef;
	}
	push(@ordered_envs, 'Un-merged changes');
	return \@ordered_envs;
}

sub increase_indent {
	my $self = shift;
	$self->indent($self->indent() + 4);
}

sub decrease_indent {
	my $self = shift;
	$self->indent($self->indent() - 4);
}

sub print_indented {
	my ($self, $text) = @_;
	print " " x $self->indent(), $text, "\n";
}

sub get_status {
	my ($self, $task_branch_name) = @_;

	my $mainline_branch = App::Task::Config->config->{mainline_branch};

	my $start = $self->content_tracker->get_branch_start($task_branch_name);

	$self->die_no_commits($task_branch_name) unless defined $start;

	my $definitive_branch = $task_branch_name;
	my @branch_commits    = $self->get_rev_list($start, $definitive_branch);

	# Defer to origin if the branch doesn't exist locally
	unless (@branch_commits) {
		$definitive_branch = "origin/$task_branch_name";
		@branch_commits    = $self->get_rev_list($start, $definitive_branch);
	}

	my %env_commits = $self->get_env_commits(
		start          => $start,
		branch         => $task_branch_name,
		branch_commits => \@branch_commits,
	);

	return (
		env_commits     => \%env_commits,
		branch_commits  => \@branch_commits,
	);
}

# Build up the data structure of commits in each environment, and other data
# return (
#     prod => {
#         same_as_prev_env  => 0|1,
#         branch_tip        => 'ae4bdf32ab9247e8d2942aa75235239572fbba23',
#         branch_start_ref  => '2942aa75235239572fbba23ae4bdf32ab9247e8d',
#         abs_commits => {
#             list => [ ... ],
#             hash => { ... },
#         },
#         rel_commits => {
#             list => [ ... ],
#             hash => { ... },
#         },
#     },
#     ...
# );
sub get_env_commits {
	my ($self, %args) = @_;

	die "start not specified" if !$args{start};
	die "branch not specified" if !$args{branch};

	my $branch = $args{branch};
	my @envs = @{$self->ordered_envs};

	my @branch_rev_list = $args{branch_commits}
		? @{$args{branch_commits}}
		: $self->get_rev_list($args{start}, $branch);

	$self->die_no_commits($branch) unless (@branch_rev_list);

	my %branch_rev_hash = map { $_ => 1 } @branch_rev_list;

	my %env_commits;
	my $prev_env;
	for my $env (@envs) {
		# Get the rev-list of the remote repository
		my ($remote_branch, $repo) = $self->get_remote_branch_for_env($env, $branch);
		$remote_branch = $repo ? "$repo/$remote_branch" : $remote_branch;

		my $len = print_disappearing(msg => "Fetching rev-list for '$env'...");

		# Record the existing commits for the environment
		my %remote_rev_list = map {
			exists $branch_rev_hash{$_} ? ($_ => 1) : ()
		} $self->get_rev_list($args{start}, $remote_branch);

		print_disappearing(len => $len);

		$env_commits{$env} = {
			abs_commits => { list => [], hash => {} },
			rel_commits => { list => [], hash => {} },
		};

		# Generate a list and hash of all the commits in this environment
		for my $commit (@branch_rev_list) {
			if ($remote_rev_list{$commit}) {
				push @{$env_commits{$env}->{abs_commits}->{list}}, $commit; # add to list
				$env_commits{$env}->{abs_commits}->{hash}->{$commit} = 1;   # hashify that list
			}
		}

		# Set the branch start, start ref, and tip for convenience
		$env_commits{$env}->{branch_start_name} = $args{start};
		chomp(my ($start_ref) = App::Task::Base->system_call(
			"git show-ref $args{start}",
			ignore_exit_status => 1,
		));
		# Revert back to start if show-ref failed
		$start_ref ||= $args{start};

		$env_commits{$env}->{branch_start_ref} = (split(/\s+/, $start_ref))[0];
		$env_commits{$env}->{branch_tip} = $env_commits{$env}->{abs_commits}->{list}->[0] || '';

		# Indicate if this environment is the same as the previous
		if ($prev_env && $env_commits{$env}->{branch_tip} eq $env_commits{$prev_env}->{branch_tip}) {
			$env_commits{$env}->{same_as_prev_env} = 1;
		}

		# Generate relative list of commits
		for my $commit (@{$env_commits{$env}->{abs_commits}->{list}}) {
			# Stop if we're at the previous branch tip already
			# When there's no prev_env, relative = absolute, therefore don't break
			my $prev_branch_tip = $prev_env && $env_commits{$prev_env}->{branch_tip};
			if ($prev_env && $prev_branch_tip && $commit eq $prev_branch_tip) {
				$prev_env = $env;
				last;
			}

			push @{$env_commits{$env}->{rel_commits}->{list}}, $commit;
			$env_commits{$env}->{rel_commits}->{hash}->{$commit} = 1;
		}

		$prev_env = $env;
	}

	return %env_commits;
}

# Die when there are no commits, and print an informative message about why
sub die_no_commits {
	my $self = shift;
	my ($branch) = @_;

	chomp(my ($stdout) = App::Task::Base->system_call("git branch -a"));
	my @all_branches = grep { s/^..// } split("\n", $stdout);
	my @branches = grep { m{(\w+/)*$branch} } @all_branches;
	if (@branches) {
		warn $self->print_color(['red'], "The branch: '$branch' exists on the repositories below, but has no commits."), "\n";
		$self->increase_indent;
		$self->print_indented($_) for @branches;
		$self->decrease_indent;
		die "\n";
	} else {
		die $self->print_color(['red'], "The branch: '$branch' does not exist locally, or on any remote."), "\n";
	}
}

# Print a status line that gets erased when the event is done
# usage:
# my $len = print_disappearing(msg => "updating..."); # Print the status message
# do_something()
# print_disappearing(len => $len); # Erase the message from before
sub print_disappearing {
	my (%args) = @_;

	return unless is_interactive();

	if ($args{msg}) {
		print $args{msg};
		return length $args{msg};
	} elsif ($args{len}) {
		my $spaces = (' ') x $args{len};
		print "\r$spaces\r";
	}
}

sub get_branch_range {
	my ($start, $end) = @_;
	return $end ? "$start..$end" : $start;
}

# Get the rev-list of a given range
# Returns a list of refs and a map of refs to 1
sub get_rev_list {
	my $self = shift;
	my ($start, $end) = @_;
	my $refspec = get_branch_range($start, $end);

	my @cmd_rev_list = ('git rev-list --no-merges', $refspec);
	my $cmd = join ' ', @cmd_rev_list;
	my ($stdout, $stderr, $exit_status) = App::Task::Base->system_call(
		$cmd,
		ignore_exit_status => 1,
	);
	my @rev_list = split "\n", $stdout;

	return @rev_list;
}


sub get_remote_branch_for_env {
	my ($self, $env, $task_branch_name) = @_;
	my ($target_branch_name, $remote);
	my $final_env = $env;
	if ($env =~ /^ready for (\w+)/) {
		$target_branch_name = $task_branch_name;
		$final_env = $1;
		if (!App::Task::Base->environments->{$final_env}{allow_ready}) {
			$remote = 'origin';
		} else {
			$remote = "origin/$final_env-ready";
		}
	} elsif ($env eq 'Un-merged changes') {
		$target_branch_name = $task_branch_name;
		$remote = '';
	} else {
		$target_branch_name = App::Task::Base->environments->{$final_env}{branch_name};
		$remote = "origin";
	}
	if ($target_branch_name eq App::Task::Config->config->{mainline_branch}) {
		$target_branch_name = App::Task::Base->environments->{$final_env}{branch_name};
	}
	return ($target_branch_name, $remote);
}

sub print_git_command {
	my $self = shift;
	my ($cmd) = @_;

	my ($output, $error, $exit_status) = App::Task::Base->system_call($cmd);
	my @lines = split(/\n/, $output);

	if ($cmd =~ /--stat\b/) {
		# Provide --name-only hint when files are shortened
		if (grep { $_ =~ m{ \.\.\./} } @lines) {
			push @lines, $self->print_color(['black'], " (specify --name-only to see full file names)");
		}
	}

	$self->print_indented($_) for @lines;
	print "\n";

	return [$output, $error, $exit_status];
}

sub get_indented_screen_width {
	my $self = shift;

	return unless $self->columns;
	return $self->columns - $self->indent;
}

sub make_git_stat_cmd {
	my $self = shift;
	my $w = $self->get_indented_screen_width;
	return '--stat' unless $w;
	return "--stat=$w,$w";
}

sub print_color {
	my $self = shift;
	my ($color_list, $string) = @_;
	if ($self->args->{color}) {
		return colored($color_list, $string);
	} else {
		return $string;
	}
}

sub run {
	my ($self) = @_;

	App::Task::Config->set_option('needs-update' => 1);
	$self->content_tracker->update_remotes;

	if (my $branch = $self->task_branch) {
		my $task_branch_name = $self->content_tracker->get_branch_name($branch);
		my @deployment_branches = $self->content_tracker->get_all_deployment_branches( $branch );

		for my $branch_name ($task_branch_name, @deployment_branches) {
			my %status = $self->get_status($branch_name);

			$self->print_status_info(
				branch => $branch_name,
				status => \%status,
			);
		}
	}
}

sub print_status_info {
	my $self = shift;
	my %args = @_;

	my $task_branch_name = $args{branch};

	die "branch not specified"    if !$args{branch};
	die "status not specified"    if !$args{status};

	my $git_args = $self->args->{color} ? '--color' : '';

	$self->print_indented($self->print_color(['bold'], "Deployment status for $task_branch_name:\n"));
	$self->increase_indent;

	my @envs = @{$self->ordered_envs};

	# for each environment, in order, whatever that means
	my $prev_env;
	for my $env (@envs) {
		my %env_commits = %{$args{status}->{env_commits}->{$env}};
		my $commit_key = 'rel_commits';
		my @commits = @{$env_commits{$commit_key}->{list} || []};

		if (!scalar @commits || $env_commits{same_as_prev_env}) {
			$prev_env = $env;
			next;
		}

		# Get chronologically first and last commits (reversed in the rev-list)
		my $commit_last  = $env_commits{branch_tip};
		my $commit_first;
		if ($prev_env && $commit_key eq 'rel_commits') {
			$commit_first = $args{status}{env_commits}{$prev_env}{branch_tip}
		}
		$commit_first ||= $env_commits{branch_start_ref};
		my $commit_range = "$commit_first..$commit_last";

		$self->print_env_label($env);
		$self->increase_indent;

		if ($self->args->{log}) {
			# Do --stat and --diff | -p with `git log` to display on a per-commit basis, and run fast
			my @log_args = ('--no-merges');
			push @log_args, $self->make_git_stat_cmd();
			push @log_args, '-p'                       if $self->args->{diff};
			push @log_args, '--name-only'              if $self->args->{name_only};

			$self->print_git_command(sprintf(
				"git log $git_args %s %s %s",
				defined $self->args->{log_options} ? $self->args->{log_options} : '',
				join(' ', @log_args),
				$commit_range
			));
		} else {
			# If --log wasn't specified, do --stat and --diff | -p compared to the child env branch tip
			my $l = $self->print_color(['blue'],   "Branch tip:  ");
			my $c = $self->print_color(['yellow'], $commit_last);
			$self->print_indented("$l $c");

			my $short_range = $commit_first eq $commit_last
				? substr($commit_first, 0, 7)
				: substr($commit_first, 0, 7) . '..' . substr($commit_last, 0, 7);
			$self->print_indented(sprintf("%s %s (%d commit%s)",
				$self->print_color(['blue'],   "Commit range:"),
				$self->print_color(['yellow'], "$short_range"),
				scalar @commits,
				scalar @commits == 1 ? '' : 's',
			));

			if ($self->args->{all_commits}) {
				$self->print_indented($self->print_color(['blue'],   "All commits:"));
				$self->increase_indent;
				for my $commit (@commits) {
					$self->print_indented($self->print_color(['yellow'], $commit));
				}
				$self->decrease_indent;
			}
			print "\n";

			my @diff_args;
			push @diff_args, '--name-only'              if $self->args->{name_only};
			push @diff_args, $self->make_git_stat_cmd();
			push @diff_args, sprintf('-p %s', (defined $self->args->{diff_options} ? $self->args->{diff_options} : ''))
				if $self->args->{diff};

			# Diff against the child environment's previous branch tip
			$self->print_git_command(sprintf(
				"git diff $git_args %s %s",
				join(' ', @diff_args),
				$commit_range,
			));
		}
		$self->decrease_indent;
		$prev_env = $env;
	}
	$self->decrease_indent;
}

sub print_env_label {
	my $self = shift;
	my ($env) = @_;

	my $env_label = "$env" ;
	$self->print_indented($self->print_color(['bold green'], "$env_label:"));
	if ($self->args->{log} || $self->args->{diff}) {
		$self->print_indented($self->print_color(['bold green'], '-' x ($self->get_indented_screen_width || 80)));
	}
}

sub abort {
	my ($self, $message) = @_;
	print color 'red';
	print "$message\n";
	print color 'reset';
	exit;
}


no Moo;
no Types::Standard;

sub usage {
	my ($self, $message) = @_;

	print <<"END_USAGE";
Usage: task status [-h] <branch_name>

Get info about which environments files for a task have been pushed to. Checks
the status of the current task branch if none is specified.

The most current version of the file (on HEAD) always shows up in bold.

Options:

    -h, --help               Show a brief help message and exit
    --all-commits            Print a list of commits affected for each
                             environment, rather than just the commit range. This
                             gives a complete list of commits, without the
                             verbosity of --log.
    -c, --color, --colour    Enable colored output. On by default. Off when the
                             terminal isn't interactive, but can be forced by
                             manually setting --color.
    --diff-options <options> Specifies extra options to pass to `git diff` when
                             -p or --diff are used.
    -l, --log                Print `git log` information for each environment.
                             Can be used with --stat and -p or --diff to print
                             stat and diff information for each log entry.
    --log-options <options>  Specifies extra options to pass to `git log` when
                             --log is used.
    --name-only              Print a list of files affected for each environment,
                             without the verbosity of --stat. Can also be used if
                             the files affected printed by --stat are
                             abbreviated, since --name-only will not abbreviate
                             file names.
    -p, --diff               Print `git diff` information for each environment.
                             This will show diffs for entire environments, or
                             per log entry if used with --log.
END_USAGE

	print "\n$message\n" if $message;

	exit 1;
}

1;
