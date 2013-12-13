package App::Task::Base;
use Moo;

use IO::CaptureOutput qw( capture_exec capture_exec_combined );
use IO::Interactive qw( is_interactive );
use Getopt::Long;
use Term::ANSIColor;
use App::Task::ContentTracker;
use App::Task::Config;

Getopt::Long::Configure( qw( no_ignore_case bundling pass_through require_order ));

our $VERSION = '4.00';

my $instance;

# this is a singleton class
sub instance {
	return $instance if $instance;
	die __PACKAGE__ . ' instance has not been built yet';
}

sub BUILD {
	my ($self, $args) = @_;
	$instance = $self;

	if (my $message = App::Task::Config->configure($args->{config_file})) {
		if (grep { /--help|-h/ } @ARGV) {
			# if the user is asking for help for a subcommand, give it to them
			$self->run;
		} else {
			usage($message);
		}
	}

	# use Getopt::Long to get the command line options
	GetOptions(
		'help|h'     => sub { usage() },
		'verbose|v+' => \($App::Task::Config::options{verbose}),
	) or usage();
}

sub run {
	my ($self) = @_;

	my $content_tracker = App::Task::ContentTracker->new;

	my $command_name = shift @ARGV;
	usage() if !$command_name;

	my $command = App::Task::Config->find_command($command_name);
	if (!$command) {
		usage("Invalid command: $command_name");
	}

	my $command_instance = $command->{module}->new(
		content_tracker => $content_tracker,
	);
	$command_instance->run;
}

sub prompt {
	my ($self, %options) = @_;
	$self = instance() if !ref $self;

	print 'Enter ' . join(', ', map { "'$_' to $options{$_}" } grep { !/default/ } keys %options) . ', anything else to exit: ';
	chomp(my $response = <STDIN>);
	if (defined $options{lc $response}) {
		return $options{lc $response};
	} elsif (defined $options{default}) {
		return $options{default};
	} else {
		print "Exiting...\n";
		exit;
	}
}

# perform system calls, returning both stdout and stderr
sub system_call {
	my ($self, $command, %options) = @_;
	$self = ref $self ? $self : instance();

	# handle arrayrefs or scalars for $command
	$command = [ $command ] if !ref $command;

	my $command_text = join(' ', @$command);
	if (App::Task::Config->get_option('verbose') && App::Task::Config->get_option('verbose') >= 1 || $options{verbose}) {
		printf("\r%s\r", ' ' x 80) if is_interactive();
		print "* $command_text\n"
	}

	# run the command
	my ($stdout, $stderr);
	if ($options{combine}) {
		($stdout) = capture_exec_combined(@$command);
	} else {
		($stdout, $stderr) = capture_exec(@$command);
	}

	my $exit_status = $? & 127 ? $? & 127 : $? >> 8;

	my $output = '';
	if ($stdout) {
		# replace each line (except the first with some asterisks
		chomp(my $stdout_copy = $stdout);
		$stdout_copy =~ s/(?!\A)^/** /gims;
		$output .= "** stdout: '$stdout_copy'\n";
	}
	if ($stderr) {
		chomp(my $stderr_copy = $stderr);
		$stderr_copy =~ s/(?!\A)^/** /gims;
		$output .= "** stderr: '$stderr_copy'\n";
	}

	if (!defined $options{ignore_exit_status} and $exit_status) {
		$self->highlighted_die("Command failed: $command_text\n$output\n");
	}
	if (App::Task::Config->get_option('verbose') && App::Task::Config->get_option('verbose') >= 2) {
		print $output;
	}

	return ($stdout, $stderr, $exit_status);
}

sub highlighted_die {
	my ($self, $message) = @_;
	# preserve last-line perl non-stack trace behavior
	$message =~ s/(\n?)\z/color('reset') . $1/e;
	die color('red') . $message;
}

sub environments {
	my ($class) = @_;
	return App::Task::Config->config->{environments};
}

sub usage {
	my ($message) = @_;

	print <<"END_USAGE";
Usage: task <subcommand>

task is a release management tool for git designed to aid multi-user
development in tiny chunks (task branches). It supports
multiple environments and can build de facto releases (defined by whatever is
on a given branch) or versioned releases

Available subcommands are:
END_USAGE

	for my $command_name (App::Task::Config->command_list) {
		printf "    %-12s %s\n", $command_name, App::Task::Config->find_command($command_name)->{description};
	}

	print "\nUse 'task <subcommand> --help' for more information\n";

	print "\n$message\n\n" if $message;

	exit 1;
}

no Moo;

1;
