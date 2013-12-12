#!/usr/bin/env perl

use strict;
use warnings;
use DateTime;

my $delete_after_on_prod_days = 7;
#my $abandon_after_days        = 30;
my $git = `which git` || '/usr/bin/git';
chomp $git;

# first make sure we are up to date and on master
echo_system("$git remote update --prune");
echo_system("$git checkout master");
echo_system("$git pull");

# get all the branches that have been readied for prod
#chomp(my $branches = `git branch -r | grep '\\<prod\/' | grep -v 'master'`);
#my @branches = map { s/^\s*|\s*$//; $_ } split /\n/, $branches;

# get all of the branches that have been fully merged into origin/master
chomp(my $branches = `$git branch -r --merged origin/master`);
my @branches = map { s/^\s*|\s*$//; $_ } split /\n/, $branches;
my %branch_envs;
for my $remote_branch_name (@branches) {
	# skip env branches and non-origin remotes
	next if $remote_branch_name =~ /^origin\/(?:master|prod|preprod|qa|integration)$/;
	next if $remote_branch_name =~ /->/;

	my ($env, $branch_name);
	if ($remote_branch_name =~ /^origin\/([^\/]+-ready)\/(.*)/) {
		($env, $branch_name) = ($1, $2);
	} elsif ($remote_branch_name =~ /^origin\/(.*)/) {
		($env, $branch_name) = ('integration', $1);
	}
	$branch_envs{$branch_name}{$env} = 1 if $branch_name && $env;
}

# find all of the branches where the integration version (where we stopped development)
# has been merged into origin/master
my @integration_merged_to_prod_branches = sort grep { exists $branch_envs{$_}{integration} } keys %branch_envs;
print "Found " . scalar @integration_merged_to_prod_branches . " branches on integration that have been merged into origin/master\n";

# filter out branches that are less than $delete_after_on_prod_days days old
my @removeable_branches;
for my $branch_name (@integration_merged_to_prod_branches) {
	my $days_since_last_commit = days_since_last_commit($branch_name);
	my $status = '';
	if ($days_since_last_commit > $delete_after_on_prod_days) {
		push @removeable_branches, $branch_name;
		$status = '(flagged for deletion)';
	}
	printf "%-50s %-30s %s\n", $branch_name, "$days_since_last_commit days since last commit", $status;
}
print "Found " . scalar @removeable_branches . " branches that are older than $delete_after_on_prod_days days on integration that have been merged into origin/master\n";

# next get all of the integration branches that aren't in the above list and makes sure they don't have any non-merge commits (new content) that isn't on prod
# this should cover started but not committed to branches and deployed branches where people never pulled from integration after creating non-fastforward merges of normal deploys
my (@no_new_commit_branches, %integration_branches_not_on_prod);
chomp(my $integration_branches = `$git branch -r | awk '{ print \$1 }' | grep -P '^origin/(?:todo|bug)'`);
my @integration_branches = split /\n/, $integration_branches;
for my $remote_branch_name (sort @integration_branches) {
#	# skip special branches
#	next if $remote_branch_name =~ /^integration\/(?:master|prod|preprod|qa|integration)$/;

	# skip branches that we already covered above
	my($remote, $branch_name) = $remote_branch_name =~ /([^\/]+)\/(.*)/;
	next if $branch_envs{$branch_name}{integration};

	chomp(my $new_commit_list = `$git rev-list --no-merges ^origin/master $remote_branch_name`);
	my @new_commits = split(/\n/, $new_commit_list);
	my $new_commit_count = scalar @new_commits;

	my $days_since_last_commit = days_since_last_commit($branch_name);

	if ($new_commit_count == 0) {
		my $status = '';
		if ($days_since_last_commit > $delete_after_on_prod_days) {
			push @no_new_commit_branches, $branch_name;
			push @removeable_branches, $branch_name;
			$status = '(flagged for deletion)';
		}
		printf "%-50s %-30s %-15s %s\n", $branch_name, "$days_since_last_commit days since last commit", "$new_commit_count commits", $status;
	} else {
		$integration_branches_not_on_prod{$branch_name} = {
			branch_name            => $branch_name,
			new_commit_count       => $new_commit_count,
			new_commits            => \@new_commits,
			days_since_last_commit => $days_since_last_commit,
		};
	}
}
print "Found " . scalar @no_new_commit_branches . " branches on integration don't have any new content for at least $delete_after_on_prod_days days (never committed to or missing merge superfluous commits)\n";
print "Found " . scalar(keys %integration_branches_not_on_prod) . " branches that are either active or abandoned that we won't be touching yet\n";

#my (@abandoned_branches, @active_branches, @never_deployed_abandoned_branches);
#for my $branch_name (sort keys %integration_branches_not_on_prod) {
#	my $branch_info = $integration_branches_not_on_prod{$branch_name};
#
#	# for small commit lists, check all of the commits
#	# for larger ones, check the first, last and a middle one
#	my @new_commits = @{$branch_info->{new_commits}};
#	my @commits_to_check = $branch_info->{new_commit_count} < 5 ? @new_commits : ($new_commits[0], $new_commits[int($#new_commits / 2)], $new_commits[-1]);
#	my %deployed_envs;
#	for my $commit_id (@commits_to_check) {
#		chomp(my $deployed_master_branches = `$git branch -r --contains $commit_id | grep '\\<master\\>' | grep -v 'origin'`);
#		for my $master_branch (split /\n/, $deployed_master_branches) {
#			my ($env) = $master_branch =~ /^\s*([^\/]+)\/master/;
#			$deployed_envs{$env} = 1;
#		}
#	}
#	my $deployed_envs = join(', ', sort keys %deployed_envs);
#
#	my $status;
#	if ($branch_info->{days_since_last_commit} > $abandon_after_days) {
#		push @abandoned_branches, $branch_name;
#		$status = '(abandoned)';
#		if (!scalar keys %deployed_envs) {
#			push @never_deployed_abandoned_branches, $branch_name;
#		}
#	} else {
#		$status = '(active)';
#		push @active_branches, $branch_name;
#	}
#
#	printf "%-75s %-30s %-15s %-30s %s\n", $branch_name, "$branch_info->{days_since_last_commit} days since last commit", "$branch_info->{new_commit_count} commits", $deployed_envs, $status;
#}
#
##@removeable_branches = (@removeable_branches, @never_deployed_abandoned_branches);
#print "Found " . scalar @active_branches . " active branches (w/commits in the last $abandon_after_days days)\n";
#print "Found " . scalar @abandoned_branches . " abandoned branches:\n";
#print join("\n", @abandoned_branches) . "\n";
print "Found " . scalar @removeable_branches . " total removeable branches\n";

# delete the branches
for my $branch_name (sort @removeable_branches) {
	remove_branch($branch_name);
}
echo_system("$git remote update --prune");

# delete the branch on all environments
sub remove_branch {
	my ($branch_name) = @_;

	for my $env (qw/ prod preprod qa /) {
		echo_system("$git push origin :refs/heads/$env/$branch_name");
		echo_system("$git push origin :refs/heads/$env-ready/$branch_name");
	}
	echo_system("$git push origin :refs/heads/$branch_name");
	print "branch $branch_name deleted on all environments\n";
}

sub echo_system {
	my ($cmd) = @_;
	print "$cmd\n";
	system $cmd;
}

sub days_since_last_commit {
	my ($branch_name) = @_;

	chomp(my $last_commit_timestamp = `$git log -1 --pretty=format:'%ct' 'origin/$branch_name'`);
	return DateTime->from_epoch( epoch => $last_commit_timestamp)->delta_days( DateTime->now( time_zone => 'America/New_York' ) )->in_units('days');
}
