package App::Task::Config;
use strict;
use warnings;

use YAML qw( LoadFile );

my (%commands, %config_data);
our %options;

sub register_command {
	my ($module, $name, $description) = @_;
	if ($module eq __PACKAGE__) {
		($module) = caller;
	}
	$commands{$name} = {
		description => $description,
		module      => $module,
	};
}

sub command_list {
	return sort keys %commands;
}

sub find_command {
	my ($package, $name) = @_;
	return $commands{$name};
}

sub get_option {
	my ($package, $option_name) = @_;
	return $options{$option_name};
}

sub set_option {
	my ($package, $option_name, $value) = @_;
	$options{$option_name} = $value;
}

sub configure {
	my ($package, $config_file) = @_;
	undef %config_data;

	my ($relative_to_root) = `git rev-parse --show-cdup 2>/dev/null`;
	if ($?) {
		return "You are not in a git repository.";
	}
	chomp $relative_to_root;

	if (!$config_file) {
		$config_file = ($relative_to_root ? "$relative_to_root/" : '') . 'deployment.yaml';
	}

	if (-e $config_file && -r $config_file) {
		my $repo_config = LoadFile $config_file or die "Couldn't load config file '$config_file'. Malformed yaml\n";

		$config_data{environments} = $repo_config->{environments};
		$config_data{mainline_branch} = $repo_config->{mainline_branch} || 'master';
		$config_data{github_url} = $repo_config->{github_url};
		$config_data{hooks} = $repo_config->{hooks};
	} else {
		return "Can't read config file: $config_file";
	}

	$config_data{repo_root} = $relative_to_root || ".";

	# validate the config file
	for my $env (keys %{$config_data{environments}}) {
		# add the environment name into the hashref so that we can know which env we're in without having to add that to the config file
		$config_data{environments}{$env}{name} = $env;
	}
	return;
}

sub config {
	return \%config_data;
}

1;
