package App::Task::Hooks;
use Moo;

use App::Task::Config;

sub default_env {
  my $config = App::Task::Config->config;

  return (
    TASK_REPO_ROOT => $config->{repo_root},
  );
}

sub find_hooks {
  my ($self, $command, $hook_name) = @_;
  my @hooks;

  my $hooks = $command->env->{hooks};

  if ($hooks && $hooks->{$hook_name}) {
    push @hooks, @{ $hooks->{$hook_name} };
  }

  my $global_hooks = App::Task::Config->config->{hooks};
  if ($global_hooks && $global_hooks->{$hook_name}) {
    push @hooks, @{ $global_hooks->{$hook_name} };
  }

  return @hooks;
}

sub run_hooks {
  my ($self, $command, $hook_name, $env) = @_;

  my @hooks = $self->find_hooks($command, $hook_name);

  {
    local %ENV = (
      %ENV,
      $self->default_env,
      %{ $env || {} },
    );
    for my $hook (@hooks) {
      my $ok = $self->run_hook($command, $hook_name, $hook);
      if (!$ok) {
        return;
      }
    }
  }
  return 1;
}

sub run_hook {
  my ($self, $command, $hook_name, $hook) = @_;

  my $root = App::Task::Config->config->{repo_root};
  my $hook_path = "$root/$hook";

  my $prelude = "Hook '$hook_path' for $hook_name";

  if (!-e $hook_path) {
    warn "$prelude doesn't exist, skipping";
    return 1;
  }

  if (!-x $hook_path) {
    warn "$prelude isn't executable, skipping";
    return 1;
  }

  my $system_ret = system($hook_path);
  if ($system_ret) {
    if ($? == -1) {
      warn "$prelude couldn't be executed: $!";
    } elsif ($? & 127) {
      warn "$prelude exited with signal ", ($? & 127);
    } else {
      warn "$prelude exited with nonzero status ", $? >> 8;
    }
    return 0;
  } else {
    return 1;
  }
}

1;
