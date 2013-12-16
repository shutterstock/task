package App::Task::AcceptanceTests;

use strict;
use warnings;

use base qw( App::Task::TestClass );

use App::Task::Base;
use App::Task::Command::Start;
use App::Task::Command::Ready;
use App::Task::Command::Deploy;
use App::Task::Command::Status;
use App::Task::Command::Cleanup;

use Test::Most;
use IO::CaptureOutput qw( capture );
use File::Slurp qw( write_file slurp );
use Cwd qw( getcwd );

die_on_fail();

my $data_dir;
my %base_args;
my $global_todo_id = 1;

my $branch_mapping = {
	integration => 'integration',
	qa          => 'qa',
	staging     => 'staging',
	prod        => 'master',
};

# setup a Test::Output-like interface that uses IO::CaptureOutput instead
# (can't seem to use the two together since they both try to do different
# types of magic with STDOUT/STDERR)
sub stdout_is (&@) {
	my ($test, $expected, $description) = @_;
	my $stdout = stdout_from($test);
#	print $stdout;
	is $stdout, $expected, $description;
}

sub stdout_like (&@) {
	my ($test, $expected, $description) = @_;
	my $stdout = stdout_from($test);
#	print $stdout;
	like $stdout, $expected, $description;
}
sub stdout_unlike (&@) {
	my ($test, $expected, $description) = @_;
	my $stdout = stdout_from($test);
#	print $stdout;
	unlike $stdout, $expected, $description;
}

# set up a new repository for each test
sub startup : Tests( startup => 1 ) {
	my ($test) = @_;
	my $class = ref $test;

	# call parent startup first
	$test->SUPER::startup;
	$data_dir = $test->data_dir;

	$base_args{config_file} = $test->config_file_path;

	my $root_dir = "$data_dir/git_repo";
	mkdir $root_dir;
	chdir $root_dir;

	# set up the integration repository
	`git init --bare 2>&1`;

	chdir $data_dir;
	`git clone git_repo developer_repo 2>&1`;
	chmod 0777, 'developer_repo';
	chdir "$data_dir/developer_repo";
	`git config user.name "Task"`;
	`git config user.email 'task\@example.com'`;
	mkdir 'test';
	my $filename = add_file('test/travis.txt', 'test test test');
	mkdir 'hooks';
	add_file('hooks/echo.sh', 'echo Test hook - $TASK_DEPLOY_ENVIRONMENT $TASK_DEPLOY_SHA');
	add_file('hooks/echo_environment.sh', 'echo Test hook environment - $TASK_DEPLOY_ENVIRONMENT $TASK_DEPLOY_SHA');
	chmod 0755, 'hooks/echo.sh';
	chmod 0755, 'hooks/echo_environment.sh';
	`git commit -a -m 'make hooks executable'`;
	`git push origin master 2>&1`;
	`git push origin master:qa 2>&1`;
	`git push origin master:staging 2>&1`;
	`git push origin master:integration 2>&1`;
}

sub setup : Tests( setup => 1 ) {
	my ($test) = @_;

	# make sure we're in the checkout dir before every test
	chdir "$data_dir/developer_repo" or die "Couldn't chdir to $data_dir/developer_repo: $!";

	# always start on the master branch
	`git checkout master 2>&1`;
}

sub teardown : Tests( teardown => 1 ) {
	undef %App::Task::Config::options;
}

sub log_test_start {
	my ($test) = @_;

	my $sub_name = (caller(1))[3];
	diag "Running test: $sub_name";
}

sub a_verbosity : Tests(5) {
	my ($test) = @_;
	$test->log_test_start;
	set_commandline("status");
	{
		my $task = App::Task::Base->new(%base_args);
		is(App::Task::Config->get_option('verbose'), undef, "verbose is zero when not specified");
	}

	set_commandline("-v status");
	{
		my $task = App::Task::Base->new(%base_args);
		is(App::Task::Config->get_option('verbose'), 1, "verbose is 1 when specified");
		undef %App::Task::Config::options;
	}

	set_commandline("-vv status");
	{
		my $task = App::Task::Base->new(%base_args);
		is(App::Task::Config->get_option('verbose'), 2, "verbose is 2 when specified");
		undef %App::Task::Config::options;
	}

	set_commandline("-v -v status");
	{
		my $task = App::Task::Base->new(%base_args);
		is(App::Task::Config->get_option('verbose'), 2, "verbose is 2 when specified twice");
		undef %App::Task::Config::options;
	}

	set_commandline("status -v");
	{
		my $task = App::Task::Base->new(%base_args);
		eval { $task->run };
		is(App::Task::Config->get_option('verbose'), 1, "verbose is 1 when specified after the subcommand when it is run");
	}
}

sub add_and_push : Tests(18) {
	my ($test) = @_;
	$test->log_test_start;

	my $todo_id = $test->add_todo;

	set_commandline("start todo/$todo_id");
	{
		my $task = App::Task::Base->new(%base_args);
		stdout_like { $task->run } qr/Created and switched to branch 'todo\/$todo_id' from origin\/master\n/ims, 'Create a new task branch';
	}

	chomp(my($upstream) = `git config branch.todo/$todo_id.merge`);
	is $upstream, "refs/heads/todo/$todo_id";

	mkdir 'test';
	chdir 'test';
	my $filename = add_file('test2.txt', 'test test test');

	set_commandline("status --no-color todo/$todo_id");
	{
		my $task = App::Task::Base->new(%base_args);
		stdout_like { $task->run } qr{Deployment status for todo/$todo_id[^:]*:\s+Un-merged changes:\s+Branch tip:\s+\w+.+?Commit range:\s+\w+\.\.\w+ \([0-9]+ commit[s]?\)\s+test/$filename\s+\|\s+[0-9]+\s+\+\s+[0-9]+ files? changed(?:, [0-9]+ insertions?\(\+\))?(?:, [0-9]+ deletions?\(\-\))?\s*}ims, 'Status shows file in dev';

		set_commandline("ready integration todo/$todo_id");
		$task = App::Task::Base->new(%base_args);
		stdout_like { $task->run } qr/1 file ready for integration\s+todo\/$todo_id\s+test\/$filename\s+ready for integration - commit id: \w+/, 'Report the todo was set as ready for integration';
	}

	chomp(my $branch_tip_commit = `git rev-parse todo/$todo_id`);

	chomp(my $contained_branches = `git branch -r --contains $branch_tip_commit`);
	like $contained_branches, qr/\*? ?\borigin\/todo\/$todo_id\b/ims, 'Make sure the content is contained in the local integration branch';

	# make sure we haven't actually deployed anything yet
	$contained_branches = `cd $data_dir/git_repo; git branch --contains $branch_tip_commit 2>&1`;
	unlike $contained_branches, qr/\*? ?\bmaster\b/ims, 'Make sure the content is not contained in the remote branch';

	my $diffs = `git diff origin/master 'test/$filename' 2>&1`;
	isnt $diffs, '', 'Make sure the file is not on integration';

	set_commandline("deploy -n integration todo/$todo_id");
	{
		my $task = App::Task::Base->new(%base_args);
		my $stdout = stdout_from(sub { $task->run });
		like $stdout, qr/No changed files to set as ready for integration/, "Already ready for integration";
		like $stdout, qr/1 file to deploy to integration/, "1 file to deploy to integration";
		like $stdout, qr/Deploying the following changes to integration:/, "Deploying something to integration";
		like $stdout, qr/test\/$filename\s+\|\s+1\s+\+.*1 files? changed, 1 insertions?\(\+\)(?:, 0 deletions?\(-\))?/ims, "Integration diffstat is good";
		like $stdout, qr/Updated git integration branch/, "Integration branch was updated";
		like $stdout, qr/\[\d+mfinished deploying to integration/ims, 'Deployed to integration finished';
	}

	$test->check_on_env("test/$filename", "$data_dir/git_repo", 'integration', "todo/$todo_id");
}

sub post_deploy_hook : Tests(12) {
	my ($test) = @_;
	$test->log_test_start;

	my $config = slurp "$test->{base_dir}/deployment_with_hooks.yaml";
	write_file "$test->{data_dir}/deployment_with_hooks.yaml", $config;

	set_commandline("start feature/run_hooks");
	{
		my $task = App::Task::Base->new(%base_args, config_file => "$test->{data_dir}/deployment_with_hooks.yaml");
		stdout_like { $task->run } qr/Created and switched to branch 'feature\/run_hooks' from origin\/master\n/ims, 'Create a new task branch';
	}

	my $filename = add_file('hook_test.txt', 'test test test');

	set_commandline("deploy -n integration feature/run_hooks");
	{
		my $task = App::Task::Base->new(%base_args, config_file => "$test->{data_dir}/deployment_with_hooks.yaml");
		my $stdout = stdout_from(sub { $task->run });
		like $stdout, qr/1 file to deploy to integration/, "1 file to deploy to integration";
		like $stdout, qr/Deploying the following changes to integration:/, "Deploying something to integration";
		like $stdout, qr/$filename\s+\|\s+1\s+\+.*1 files? changed, 1 insertions?\(\+\)(?:, 0 deletions?\(-\))?/ims, "Integration diffstat is good";
		like $stdout, qr/Updated git integration branch/, "Integration branch was updated";
		like $stdout, qr/Test hook environment - integration \w{8,}/, "Environment specific post-deploy hook was run";
		like $stdout, qr/Test hook - integration \w{8,}/, "Global post-deploy hook was run";
		like $stdout, qr/\[\d+mfinished deploying to integration/ims, 'Deployed to integration finished';
	}

	$test->check_on_env($filename, "$data_dir/git_repo", 'integration', "feature/run_hooks");
}

sub add_and_push_named_task : Tests(17) {
	my ($test) = @_;
	$test->log_test_start;

	my $todo_id = $test->add_todo;

	set_commandline("start todo/$todo_id-test-title");
	{
		my $task = App::Task::Base->new(%base_args);
		stdout_like { $task->run } qr/Created and switched to branch 'todo\/$todo_id-test-title' from origin\/master\n/ims, 'Create a new task branch';
	}

	mkdir 'test';
	chdir 'test';
	my $filename = add_file('test4.txt', "test test test");

	set_commandline("status --no-color todo/$todo_id-test-title");
	{
		my $task = App::Task::Base->new(%base_args);
		stdout_like { $task->run } qr{Deployment status for todo/$todo_id[^:]*:\s+Un-merged changes:\s+Branch tip:\s+\w+.+?Commit range:\s+\w+\.\.\w+ \([0-9]+ commit[s]?\)\s+test/$filename\s+\|\s+[0-9]+\s+\++\s+[0-9]+ files? changed(?:, [0-9]+ insertions?\(\+\))?(?:, [0-9]+ deletions?\(\-\))?\s*}ims, 'Status shows file in dev';
	}

	set_commandline("ready integration todo/$todo_id-test-title");
	{
		my $task = App::Task::Base->new(%base_args);
		stdout_like { $task->run } qr/1 file ready for integration\s+todo\/$todo_id-test-title\s+test\/$filename\s+ready for integration - commit id: \w+/, 'Report the todo was set as ready for integration';
	}

	chomp(my $branch_tip_commit = `git rev-parse todo/$todo_id-test-title`);

	chomp(my $contained_branches = `git branch -r --contains $branch_tip_commit`);
	like $contained_branches, qr/\*? ?\borigin\/todo\/$todo_id-test-title\b/ims, 'Make sure the content is contained in the local integration branch';

	# make sure we haven't actually deployed anything yet
	$contained_branches = `cd $data_dir/git_repo; git branch --contains $branch_tip_commit 2>&1`;
	unlike $contained_branches, qr/\*? ?\bmaster\b/ims, 'Make sure the content is not contained in the remote branch';

	my $diffs = `git diff origin/master 'test/$filename' 2>&1`;
	isnt $diffs, '', 'Make sure the file is not on integration';

	set_commandline("deploy integration todo/$todo_id-test-title");
	{
		my $task = App::Task::Base->new(%base_args);
		my $stdout = stdout_from(sub { answer_prompt (sub { $task->run }, 'y') });
		like $stdout, qr/No changed files to set as ready for integration/, "Already ready for integration";
		like $stdout, qr/1 file to deploy to integration/, "1 file to deploy to integration";
		like $stdout, qr/Deploying the following changes to integration:/, "Deploying something to integration";
		like $stdout, qr/test\/$filename.*1 files? changed, 1 insertions?\(\+\)(?:, 0 deletions?\(-\))?/ims, "Integration diffstat is good";
		like $stdout, qr/Updated git integration branch/, "Integration branch was updated";
		like $stdout, qr/\[\d+mfinished deploying to integration/ims, 'Deployed to integration finished';
	}

	$test->check_on_env("test/$filename", "$data_dir/git_repo", 'integration', "todo/$todo_id-test-title");
}

sub invalid_environment : Tests(10) {
	my ($test) = @_;
	$test->log_test_start;

	my $todo_id = $test->add_todo;

	`git checkout -b todo/$todo_id origin/master 2>&1`;
	my $filename = add_file('test3.txt', 'test test test');

	set_commandline("status --no-color todo/$todo_id");
	{
		my $task = App::Task::Base->new(%base_args);
		stdout_like { $task->run } qr{Deployment status for todo/$todo_id[^:]*:\s+Un-merged changes:\s+Branch tip:\s+\w+.+?Commit range:\s+\w+\.\.\w+ \([0-9]+ commit[s]?\)\s+$filename\s+\|\s+[0-9]+\s+\+\s+[0-9]+ files? changed(?:, [0-9]+ insertions?\(\+\))?(?:, [0-9]+ deletions?\(\-\))?\s*}ims, 'Status shows file in dev';
	}

	my $exit_count = $test->exit_count;
	set_commandline("ready preprod todo/$todo_id");
	{
		my $task = App::Task::Base->new(%base_args);
		stdout_like { dies_ok { $task->run } } qr/'preprod' is not a valid environment/, 'Invalid environment';
	}
	is $test->exit_count, $exit_count + 1, "did invalid env die?";

	$test->check_not_on_env("test/$filename", "$data_dir/git_repo", 'qa', "todo/$todo_id");

	# check that it's still not on qa
	$test->check_not_on_env("test/$filename", "$data_dir/git_repo", 'qa', "todo/$todo_id");

	my ($branches) = App::Task::Base->system_call("git branch");
	unlike $branches, qr/^\*? *temp_deploy_/ims,
		"Temp qa deployment branch doesn't still exist for push with no deployment location";
}

sub single_file_deployment : Tests(50) {
	my ($test) = @_;
	$test->log_test_start;

	# create a new todo
	my $todo_id = $test->add_todo;

	# this scheme doesn't seem to work for non-shortnamed branches, fyi
	set_commandline("start todo/$todo_id-test");
	{
		my $task = App::Task::Base->new(%base_args);
		stdout_like { $task->run } qr/Created and switched to branch 'todo\/$todo_id-test' from origin\/master\n/ims, 'Create a new task branch';
	}

	# add 2 files
	mkdir 'test';
	my $deploy_filename = add_file('test/single_file_test.html', "single file that needs\nto go all the way\nto production");
	my $other_filename = add_file('test/other_file.html', "code that doesn't need to go all the way\nto production");
	my $exit_count = $test->exit_count;

	set_commandline("deploy -n prod todo/$todo_id $deploy_filename");
	{
		my $task = App::Task::Base->new(%base_args);
		my $stdout = stdout_from(sub { $task->run });
		like $stdout, qr/Created and switched to branch 'todo\/$todo_id-test-deploy1' from \w+/, "Created branch";
		like $stdout, qr/Added the following file from branch 'todo\/$todo_id-test' into branch 'todo\/$todo_id-test-deploy1': '$deploy_filename'/, "Files got added";
		like $stdout, qr/Deploying the following changes to prod:\s+$deploy_filename[^\n]*\n[^\n]*1 files? changed/ims, "Deploying something to prod (with diffstat)";
		like $stdout, qr/finished deploying to prod/ims, 'Deploy to prod finished';
	}

	# 24
	$test->check_on_env($deploy_filename, "$data_dir/git_repo", 'integration', "todo/$todo_id-test-deploy1");
	$test->check_on_env($deploy_filename, "$data_dir/git_repo", 'qa', "todo/$todo_id-test-deploy1");
	$test->check_on_env($deploy_filename, "$data_dir/git_repo", 'staging', "todo/$todo_id-test-deploy1");
	$test->check_on_env($deploy_filename, "$data_dir/git_repo", 'prod', "todo/$todo_id-test-deploy1");

	# 16
	$test->check_not_on_env($other_filename, "$data_dir/git_repo", 'integration', "todo/$todo_id-test-deploy1");
	$test->check_not_on_env($other_filename, "$data_dir/git_repo", 'qa', "todo/$todo_id-test-deploy1");
	$test->check_not_on_env($other_filename, "$data_dir/git_repo", 'staging', "todo/$todo_id-test-deploy1");
	$test->check_not_on_env($other_filename, "$data_dir/git_repo", 'prod', "todo/$todo_id-test-deploy1");

	# make sure this syntax fails
	set_commandline("deploy -n prod $deploy_filename");
	{
		my $task = App::Task::Base->new(%base_args);
		throws_ok { $task->run } qr/No branch specified to add files to/ims, "We don't support deploying files without a branch";
	}

	# now make sure that a normal deploy of the whole task works
	set_commandline("deploy -n prod todo/$todo_id");
	{
		my $task = App::Task::Base->new(%base_args);
		my $stdout = stdout_from(sub { $task->run });
		like $stdout, qr/Deploying the following changes to prod:\s+$other_filename[^\n]*\n[^\n]*1 files? changed/ims, "Deploying other file to prod (with diffstat)";
		like $stdout, qr/finished deploying to prod/ims, 'Deploy to prod finished';
	}

	# 24
	$test->check_on_env($other_filename, "$data_dir/git_repo", 'integration', "todo/$todo_id-test");
	$test->check_on_env($other_filename, "$data_dir/git_repo", 'qa', "todo/$todo_id-test");
	$test->check_on_env($other_filename, "$data_dir/git_repo", 'staging', "todo/$todo_id-test");
	$test->check_on_env($other_filename, "$data_dir/git_repo", 'prod', "todo/$todo_id-test");
}

sub push_direct : Tests(19) {
	my ($test) = @_;
	$test->log_test_start;

	my $todo_id = $test->add_todo;

	`git checkout --no-track -b todo/$todo_id origin/master 2>&1`;
	mkdir 'test';
	my $filename = add_file('test/direct_test.html', "code that needs\nto go all the way\nto production");

	set_commandline("deploy -n prod todo/$todo_id");
	{
		my $task = App::Task::Base->new(%base_args);
		my $stdout = stdout_from(sub { $task->run });
		like $stdout, qr/Deploying the following changes to prod:\s+$filename[^\n]*\n[^\n]*1 files? changed/ims, "Deploying file to prod (with diffstat)";
		like $stdout, qr/finished deploying to prod/ims, 'Deploy to prod finished';
	}

	$test->check_on_env($filename, "$data_dir/git_repo", 'integration', "todo/$todo_id");
	$test->check_on_env($filename, "$data_dir/git_repo", 'qa', "todo/$todo_id");
	$test->check_on_env($filename, "$data_dir/git_repo", 'staging', "todo/$todo_id");
	$test->check_on_env($filename, "$data_dir/git_repo", 'prod', "todo/$todo_id");
}

sub push_file_with_spaces : Tests(8) {
	my ($test) = @_;
	$test->log_test_start;

	my $todo_id = $test->add_todo;
	`git checkout --no-track -b todo/$todo_id origin/master 2>&1`;
	mkdir 'test';
	chdir 'test';

	my $filename = add_file('filename with spaces.txt', "this is a filename with spaces in it\nyeah!");

	set_commandline("ready qa todo/$todo_id");
	{
		my $task = App::Task::Base->new(%base_args);

		stdout_like { lives_ok { answer_prompt( sub { $task->run }, 'y') } } qr/1 file ready for integration\s+todo\/$todo_id\s+test\/$filename\s+ready for integration - commit id: \w+.*finished deploying to integration.*1 file ready for qa\s+todo\/$todo_id\s+test\/$filename\s+ready for qa - commit id: \w+/ims, 'Report the todo was set and deployed to integration and is ready for qa';
	}

	$test->check_on_env("test/$filename", "$data_dir/git_repo", 'integration', "todo/$todo_id");
	$test->check_not_on_env("test/$filename", "$data_dir/git_repo", 'qa', "todo/$todo_id");
}

sub confirmation : Tests(4) {
	my ($test) = @_;
	$test->log_test_start;

	my $todo_id = $test->add_todo;
	`git checkout --no-track -b todo/$todo_id origin/master 2>&1`;
	mkdir 'test';
	chdir 'test';

	my $filename = add_file('test_file.txt', "this is a test");

	set_commandline("deploy integration todo/$todo_id");
	{
		my $task = App::Task::Base->new(%base_args);

		stdout_like { dies_ok { answer_prompt( sub { $task->run }, '', '3') } } qr/Enter 'y' to continue, anything else to exit:/ims, 'User was prompted to confirm deploy';
	}

	$test->check_not_on_env("test/$filename", "$data_dir/git_repo", 'integration', "todo/$todo_id");
}

#sub git_integration_merge_conflict : Tests(16) {
#	my ($test) = @_;
#	$test->log_test_start;
#
#	my $todo_id = $test->add_todo;
#	`git checkout -b todo/$todo_id origin/prod 2>&1`;
#	mkdir 'test';
#	chdir 'test';
#
#	my $filename = add_file('Errors', "this is a file that we want git to fail on");
#	my $original_md5 = `md5sum $filename`;
#
#	# push the file to integration
#	set_commandline("deploy integration 'todo/$todo_id'");
#	my $task = App::Task::Base->new(%base_args);
#	stdout_like { $task->run } qr/finished deploying to integration/ims,
#		"report successful deployment of todo/$todo_id";
#
#	chomp(my $original_branch_tip_commit = `git rev-parse todo/$todo_id 2>&1`);
#	$test->check_on_env("test/$filename", "$data_dir/git_repo", 'integration', $original_branch_tip_commit);
#
#	`git checkout master 2>&1`;
#	(my $changes = slurp $filename) =~ s/\z/\nthis is a new line/;
#	write_file $filename, $changes;
#	my $new_md5 = `md5sum $filename`;
#	isnt $original_md5, $new_md5, 'the files are different';
#
#	die `git commit -a -m "master change" 2>&1`;
#	`git pull origin master 2>&1`;
#	`git push origin master 2>&1`;

#	# make an edit to the file back on the original branch
#	`git checkout todo/$todo_id 2>&1`;
#	(my $changes = slurp $filename) =~ s/\z/\nthis is a change/;
#	write_file $filename, $changes;
#	my $new_md5 = `md5sum $filename`;
#
#	isnt $original_md5, $new_md5, 'the files are different';
#
#	`git commit -a -m 'changes'`;
#
#	set_commandline("deploy integration 'todo/$todo_id'");
#	$task = App::Task::Base->new(%base_args);
#	stdout_like { dies_ok { $task->run } } qr/Error during git update/ims,
#		'report the file was not deployed to integration';
#
#	chomp(my $new_branch_tip_commit = `git rev-parse todo/$todo_id 2>&1`);
##	$test->check_db_version($filename, '1.2', 'ready_for_integration');
#	$test->check_on_env("test/$filename", "$data_dir/git_repo", 'integration', $original_branch_tip_commit);
#	$test->check_not_on_env("test/$filename", "$data_dir/env_checkouts/qa", 'qa', $new_branch_tip_commit);
#}

sub merge_conflicts : Tests(22) {
	my ($test) = @_;
	$test->log_test_start;

	my $todo_id1 = $test->add_todo;
	`git checkout -b todo/$todo_id1 origin/master 2>&1`;

	my $todo_id2 = $test->add_todo;
	`git branch --no-track todo/$todo_id2 origin/master 2>&1`;

	mkdir 'test';
	chdir 'test';

	my $filename = add_file('Conflicts', "this is a file\nthat we want to have\nmerge conflicts on");

	# make the todo ready for qa
	set_commandline("ready qa 'todo/$todo_id1'");
	my $task = App::Task::Base->new(%base_args);
	stdout_like { answer_prompt( sub { $task->run }, 'y') } qr/finished deploying to integration.*ready for qa - commit id: \w+/ims,
		"report successful deployment of todo/$todo_id1 to integration and ready for qa";

	$test->check_on_env("test/$filename", "$data_dir/git_repo", 'integration', "todo/$todo_id1");

	# now make an incompatible change to the same file
	`git checkout todo/$todo_id2 2>&1`;
	add_file('Conflicts', "this is a file\nthat we don't really desire to have\nmerge conflicts on");

	# and make the conflicting todo ready for qa too
	set_commandline("ready qa 'todo/$todo_id2'");
	$task = App::Task::Base->new(%base_args);
	stdout_like {
		throws_ok {
			answer_prompt ( sub { $task->run }, "\n", 5 )
		} qr/Can't continue after a failed merge/, "Stopped merging"
	} qr/merging local branch todo\/$todo_id2 into origin\/integration failed\n.*-----.*diff/ims,
		"report merge conflict in deployment of todo/$todo_id2 to integration";

	my $diffs = `git diff`;
	is $diffs, '', 'make sure we reset properly to the pre-conflicted state';

	$test->check_not_on_env("test/$filename", "$data_dir/git_repo", 'integration', "todo/$todo_id2");

	# fix the merge ourselves
	`git checkout todo/$todo_id2 2>&1`;
	`git merge todo/$todo_id1`;
	add_file('Conflicts', "this is a file\nthat has fixed\nmerge conflicts");

	set_commandline("deploy -n qa 'todo/$todo_id2'");
	$task = App::Task::Base->new(%base_args);
	stdout_like { $task->run } qr/finished deploying to integration.*finished deploying to qa/ims,
		"fully deploy the fixed merge conflict for todo/$todo_id2 to qa";

	$diffs = `git diff`;
	is $diffs, '', 'make sure we reset properly to the pre-conflicted state';

	$test->check_on_env("test/$filename", "$data_dir/git_repo", 'integration', "todo/$todo_id2");

	# now push the first todo to qa
	set_commandline("deploy -n staging 'todo/$todo_id1'");
	$task = App::Task::Base->new(%base_args);
	stdout_like { $task->run } qr/finished deploying to staging/ims,
		"report successful deployment of todo/$todo_id1 to staging";

	chomp(my $branch_tip_commit = `git rev-parse 'todo/$todo_id1'`);
	my $contained_branches = `cd $data_dir/git_repo; git branch --contains $branch_tip_commit`;
	like $contained_branches, qr/\*? ?\bstaging\b/ims, "Make sure the content is contained in the remote branch env branch";
	$test->check_on_env("test/$filename", "$data_dir/git_repo", 'staging', "todo/$todo_id1");
}

sub push_through_qa_by_qa : Tests(25) {
	my ($test) = @_;
	$test->log_test_start;

	`git clone git_repo qa_workspace 2>&1`;
	chmod 0777, 'qa_workspace';

	my $todo_id = $test->add_todo;
	`git checkout -b todo/$todo_id origin/master 2>&1`;
	mkdir 'test';
	chdir 'test';

	my $filename = add_file('flarglnfn', 'foo bar asdf asdfas sadf');

	set_commandline("status --no-color todo/$todo_id");
	{
		my $task = App::Task::Base->new(%base_args);
		stdout_like { $task->run } qr{Deployment status for todo/$todo_id[^:]*:\s+Un-merged changes:\s+Branch tip:\s+\w+.+?Commit range:\s+\w+\.\.\w+ \([0-9]+ commit[s]?\)\s+test/$filename\s+\|\s+[0-9]+\s+\+\s+[0-9]+ files? changed(?:, [0-9]+ insertions?\(\+\))?(?:, [0-9]+ deletions?\(\-\))?\s*}ims, 'Status shows file in dev';
	}

	set_commandline("ready qa todo/$todo_id");
	{
		my $task = App::Task::Base->new(%base_args);
		stdout_like { answer_prompt( sub { $task->run }, 'y') } qr/1 file ready for integration.*finished deploying to integration.*1 file ready for qa\s+todo\/$todo_id\s+test\/$filename\s+ready for qa - commit id: \w+/ims,
			'report the file was deployed to integration and is ready for qa';
	}

	$test->check_on_env("test/$filename", "$data_dir/git_repo", 'integration', "todo/$todo_id");
	$test->check_not_on_env("test/$filename", "$data_dir/git_repo", 'qa', "todo/$todo_id");

	# now change to the qa user's workspace and try to push the todo
	chdir "$data_dir/qa_workspace";

	set_commandline("deploy -n qa todo/$todo_id");
	{
		my $task = App::Task::Base->new(%base_args);
		my $stdout = stdout_from(sub { $task->run });
		like $stdout, qr/Deploying the following changes to qa:\s+test\/$filename[^\n]*\n[^\n]*1 files? changed/ims, "Deploying file to qa (with diffstat)";
		like $stdout, qr/finished deploying to qa/ims, 'Deploy to qa finished';
	}

	$test->check_on_env("test/$filename", "$data_dir/git_repo", 'qa', "todo/$todo_id");

	set_commandline("status --no-color todo/$todo_id");
	{
		my $task = App::Task::Base->new(%base_args);
		stdout_like { $task->run } qr{Deployment status for todo/$todo_id[^:]*:\s+qa:\s+Branch tip:\s+\w+.+?Commit range:\s+\w+\.\.\w+ \([0-9]+ commit[s]?\)\s+test/$filename\s+\|\s+[0-9]+\s+\+\s+[0-9]+ files? changed(?:, [0-9]+ insertions?\(\+\))?(?:, [0-9]+ deletions?\(\-\))?\s*}ims,
			'Status shows file in qa';
	}

	set_commandline("deploy -n prod todo/$todo_id");
	{
		my $task = App::Task::Base->new(%base_args);
		stdout_like { lives_ok { $task->run } } qr/finished deploying to prod/ims,
			'report the file was deployed to prod';
	}

	$test->check_on_env("test/$filename", "$data_dir/git_repo", 'staging', "todo/$todo_id");
#	$test->check_db_version($filename, '1.1', 'ready_for_prod');
	$test->check_on_env("test/$filename", "$data_dir/git_repo", 'prod', "todo/$todo_id");
}

sub start_existing_branch : Tests(2) {
	my ($test) = @_;
	$test->log_test_start;

	my $todo_id = $test->add_todo;
	`git push origin master:todo/$todo_id`;
	`git fetch origin`;

	set_commandline("start todo/$todo_id");
	{
		my $task = App::Task::Base->new(%base_args);
		stdout_like { lives_ok { $task->run } } qr/Branch todo\/$todo_id set up to track remote branch/;
	}
}

sub branch_off_of_branch : Tests(2) {
	my ($test) = @_;
	$test->log_test_start;

	# create a first todo
	my $todo_id1 = $test->add_todo;
	`git checkout -b todo/$todo_id1 --no-track origin/master 2>&1`;
	mkdir 'test';
	chdir 'test';

	# add a file
	my $filename1 = add_file('file1', 'test test test');

	# create a new branch off of the first todo
	my $todo_id2 = $test->add_todo;
	`git checkout -b todo/$todo_id2 todo/$todo_id1 2>&1`;

	my $filename2 = add_file('file2', "yep\nyep\nyep");

	set_commandline("deploy -n integration todo/$todo_id2");
	{
		my $task = App::Task::Base->new(%base_args);
		stdout_like { lives_ok { answer_prompt( sub { print $task->run }, 'yes') } } qr/test\/file1.*test\/file2.*finished deploying to integration/ims,
			'Report both files were deployed to integration';
	}
}

sub prod_content_merged_into_all_envs : Tests(11) {
	my ($test) = @_;
	$test->log_test_start;

	# start by creating 2 todos
	my $todo_id2 = $test->add_todo;
	set_commandline("start todo/$todo_id2");
	{
		my $task = App::Task::Base->new(%base_args);
		stdout_like { $task->run } qr/Created and switched to branch 'todo\/$todo_id2' from origin\/master\n/ims, 'Create a new task branch';
	}

	my $todo_id1 = $test->add_todo;
	set_commandline("start todo/$todo_id1");
	{
		my $task = App::Task::Base->new(%base_args);
		stdout_like { $task->run } qr/Created and switched to branch 'todo\/$todo_id1' from origin\/master\n/ims, 'Create another new task branch';
	}

	mkdir 'test';
	chdir 'test';

	# add a file
	my $filename1 = add_file('testfile1', 'test test test');

	# deploy to prod
	set_commandline("deploy -n prod todo/$todo_id1");
	{
		my $task = App::Task::Base->new(%base_args);
		my $stdout = stdout_from(sub { $task->run });
		like $stdout, qr/Deploying the following changes to prod:\s+test\/$filename1[^\n]*\n[^\n]*1 files? changed/ims, "Deploying file to prod (with diffstat)";
		like $stdout, qr/finished deploying to prod/ims, 'Deploy to prod finished';
	}

	# then add a different file on the 2nd todo
	`git checkout todo/$todo_id2`;
	my $filename2 = add_file('testfile2', "yep\nyep\nyep");

	# deploy to prod
	set_commandline("deploy -n prod todo/$todo_id2");
	{
		my $task = App::Task::Base->new(%base_args);
		my $stdout = stdout_from(sub { $task->run });
		like $stdout, qr/Deploying the following changes to prod:\s+test\/$filename2[^\n]*\n[^\n]*1 files? changed/ims, "Deploying file to prod (with diffstat)";
		like $stdout, qr/finished deploying to prod/ims, 'Deploy to prod finished';
	}

	my $todo_id3 = $test->add_todo;
	set_commandline("start todo/$todo_id3");
	{
		my $task = App::Task::Base->new(%base_args);
		stdout_like { $task->run } qr/Created and switched to branch 'todo\/$todo_id3' from origin\/master\n/ims, 'Create a third new task branch';
	}

	my $filename3 = add_file('testfile3', "nope\nnope\nnope");

	set_commandline("deploy -n integration todo/$todo_id3");
	{
		my $task = App::Task::Base->new(%base_args);
		stdout_unlike { lives_ok { answer_prompt( sub { print $task->run }, undef, 5) } 'No prompt' } qr/There are some files that are different than we expected/ims,
			'Report the file was deployed to integration';
	}
}

sub non_fast_forward_merge : Tests(15) {
	my ($test) = @_;
	$test->log_test_start;

	return "skip non-fast forward merge tests for now because we fixed the main case where they happened";

	my $todo_id = $test->add_todo;

	chdir $data_dir;
	# create a 2nd dev checkout first
	`git clone git_repo checkout2 2>&1`;
	chmod 0777, 'checkout2';
	chdir "$data_dir/checkout2";

	set_commandline("start todo/$todo_id");
	my $task = App::Task::Base->new(%base_args);
	stdout_like { $task->run } qr/Created and switched to branch 'todo\/$todo_id' from origin\/master\n/ims, 'Create a new task branch';

	chdir 'test';
	my $filename = add_file('non_fast_forward_merge.txt', "some content");

	set_commandline("deploy -n integration todo/$todo_id");
	$task = App::Task::Base->new(%base_args);
	stdout_like { $task->run } qr/^updated repository:.*changed files:.*test\/$filename.*\n\[\d+mfinished deploying to integration/ims, 'Report the file was deployed to integration';

	$test->check_on_env("test/$filename", "$data_dir/git_repo", 'integration', "todo/$todo_id");

	# make sure we're back in the original repo
	chdir "$data_dir/developer_repo/test" or die "Couldn't chdir to $data_dir/developer_repo: $!";

	# now try to recreate the branch on the main dev repo with different content
	set_commandline("start todo/$todo_id");
	$task = App::Task::Base->new(%base_args);
	stdout_like { $task->run } qr/Created and switched to branch 'todo\/$todo_id' from origin\/master\n/ims, 'Create a new task branch';

	my $other_filename = add_file('something_different.txt', "some different content");
	set_commandline("deploy -n integration todo/$todo_id");
	$task = App::Task::Base->new(%base_args);
	stdout_like {
		throws_ok { $task->run } qr/master \(non-fast-forward\)/, 'dies with a non-fast forward error'
	} qr/1 file to deploy to integration/ims,
		'Report the file was readied for integration';

	$test->check_not_on_env("test/$other_filename", "$data_dir/git_repo", 'integration', "todo/$todo_id");

	my ($branches) = App::Task::Base->system_call("git branch");
	unlike $branches, qr/^\*? *temp_/ims,
		"Temp branch doesn't still exist for failed non-fast-forward merge";

	# pull changes to update the branches make the rest of the tests work
	`git pull integration todo/$todo_id 2>&1`;
	`git checkout master 2>&1`;
	`git pull integration master 2>&1`;
}

sub answer_prompt {
	my ($code, $answer, $alarm_seconds) = @_;
	eval {
		local $SIG{ALRM} = sub { die "alarm\n" }; # NB: \n required
		alarm($alarm_seconds || 10);

		# if there is no answer, let us just time out
		if (defined $answer) {
			# close STDIN, though I don't remember why this is necessary
			close STDIN;

			# tie STDIN using TieIn
			my $stdin = tie *STDIN, 'TieIn' or die;

			# pre-write to STDIN
			$stdin->write($answer) if defined $answer;

			# and now run the code
			$code->();

			alarm 0;
		} else {
			$code->();
			alarm 0;
		}
	};
	if ($@) {
		alarm 0;
		die "timed out: $@";
	}
}

#sub push_removed_files : Tests() {
#	my ($test) = @_;
#}

#sub revert_file : Tests() {
#	my ($test) = @_;
#}

#sub changes_in_env_checkout {
#	# make a local change
#	(my $local_changes = slurp "$data_dir/env_checkouts/integration/test/$filename") =~ s/\z/this is local change to the checkout\nand it's awesome/;
#	write_file "$data_dir/env_checkouts/integration/test/$filename", $local_changes;
#}


sub add_file {
	my ($filename, $content) = @_;

	write_file $filename => $content;

	`git add '$filename' 2>&1`;
	`git commit -m 'added/changed file $filename'`;

	return $filename;
}

sub add_todo {
	my ($test) = @_;
	return $global_todo_id++;
}

## 1 test
#sub check_not_db_version {
#	my ($test, $path, $version, $env) = @_;
#
#	my ($count) = $test->dbh->selectrow_array('select count(*) from file_versions fv join file_deployments fd on fd.file_version_id = fv.id join file_environments fe on fe.id = fd.environment_id where fv.path = ? and fv.version = ? and fe.environment = ?', undef, "test/$path", $version, $env);
#	is($count, 0, "File $path version $version is not marked as on $env in the db");
#}

# 5 tests
sub check_on_env {
	my ($test, $file_path, $repository_root, $env, $branch_name) = @_;

	chomp(my $branch_tip_commit = `git rev-parse $branch_name`);
	my $contained_branches = `cd $repository_root; git branch --contains $branch_tip_commit`;
	like $contained_branches, qr/\*? ?\b$branch_mapping->{$env}\b/ims, "Make sure the content is contained in the remote env branch";

	my ($branches) = App::Task::Base->system_call("git branch");
	my $current_branch = $branches =~ /^\* +([^\n]+)/;

	if ($current_branch ne $branch_name) {
		`git checkout '$branch_name' 2>&1`;
	}

	unlike $branches, qr/^\*? *temp_deploy_/ims,
		"No temp deployment branches still exist";

	unlike $branches, qr/^\*? *temp_${env}_merge_/ims,
		"No temp ready branches still exist for env $env";

	chomp(my $top_level_dir = `git rev-parse --show-cdup`);
	my $relative_path = "$top_level_dir$file_path";

#	my $env_branch = $env eq 'integration' ? 'master' : $env;
#	my $diffs = `git diff origin/$env_branch '$relative_path' 2>&1`;
#	is $diffs, '', "Make sure the file is on the $env_branch branch on integration";

	my $diffs = `git diff origin/$branch_mapping->{$env} '$relative_path' 2>&1`;
	is $diffs, '', "Make sure the file ended up in the $env branch on origin";

#	# make sure the file made it to the deployment location too
#	$diffs = `diff -q '$relative_path' '$data_dir/deployments/$env/$file_path' 2>&1`;
#	is $diffs, '', 'Make sure the file deployed is the same as what was checked in';

	if ($current_branch ne $branch_name) {
		`git checkout '$current_branch' 2>&1`;
	}
}

# 4 tests
sub check_not_on_env {
	my ($test, $file_path, $repository_root, $env, $branch_name) = @_;

	return "Repository '$repository_root' doesn't exist" if !-d $repository_root;

	chomp(my $branch_tip_commit = `git rev-parse $branch_name`);

	my ($current_branch) = App::Task::Base->system_call("git branch | grep '*'");
	chomp $current_branch;
	$current_branch =~ s/^\* //;

	if ($current_branch ne $branch_name) {
		`git checkout '$branch_name' 2>&1`;
	}

	chomp(my $top_level_dir = `git rev-parse --show-cdup`);
	my $relative_path = "$top_level_dir$file_path";

#	$test->check_not_db_version($path, $version, $env);
	my $contained_branches = `cd $repository_root; git branch --contains $branch_tip_commit 2>&1`;
	unlike $contained_branches, qr/\*? ?\borigin\/$branch_mapping->{$env}\b/ims, "Make sure the content is not contained in the remote branch '$env/master'";

	my $diffs = `git diff origin/$branch_mapping->{$env} '$relative_path' 2>&1`;
	isnt $diffs, '', "Make sure the file is not on the $env branch in the exact state as our repository";

#	$diffs = `diff -q '$relative_path' '$data_dir/deployments/$env/$file_path' 2>&1`;
#	like $diffs, qr/Files.*differ|No such file or directory/, 'Make sure the file in the deployment location is different than what was checked in';

#	ok !-e "$data_dir/deployments/$env/$path", 'Make sure the file exists in the deployment location';
#
#	my $diffs = `diff -q '$data_dir/deployments/$env/$path' '$data_dir/env_checkouts/$env/test/$path' 2>&1`;
#	like $diffs, qr/No such file or directory/, 'Make sure the file deployed is different than what was checked in';

	if ($current_branch ne $branch_name) {
		`git checkout '$current_branch' 2>&1`;
	}
}

sub set_commandline {
	my ($string) = @_;
	my @args;
	for my $arg (split(/((?:'[^']*?'|"[^"]*?"|\S+)?)/, $string)) {
		next if $arg !~ /\S/;
		$arg =~ s/^["']|["']$//g;
		push(@args, $arg);
	}
	@ARGV = @args;
}

# get stdout using IO::CaptureOutput
sub stdout_from {
	my ($test) = @_;
	my $stdout;
	capture { &$test } \$stdout;
	return $stdout;
}

package TieIn;

sub TIEHANDLE {
	bless( \(my $scalar), $_[0]);
}

sub write {
	my $self = shift;
	$$self .= join '', @_;
}

sub READLINE {
	my $self = shift;
	$$self =~ s/^(.*\n?)//;
	return $1;
}

sub EOF {
	my $self = shift;
	return !length $$self;
}

sub CLOSE { }

1;
