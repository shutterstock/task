[![Build Status](https://travis-ci.org/shutterstock/task.png)](https://travis-ci.org/shutterstock/task)

# task

A git-based release management tool. Developed at Shutterstock.

## Introduction

Task enforces a consistent development workfow and facilitates processes around merging and deployment.  Feature development and bug fixes are done in the context of "task branches" which get readied and deployed up through environments.  Each task branch is cut from the mainline production branch, and then merged with long-lived environment branches as the task branch gets promoted.

## Example Workflow

```
$ task start my-new-feature-branch
$ vi myfile
$ git commit -a
$ task status       # shows changes in this task branch
$ task ready dev    # pre-merges into dev and pushes this branch to origin
$ task deploy dev   # merges into dev and pushes dev up to origin
$ task deploy qa    # merges and deploys to qa
$ task deploy prod  # deploys to production and runs any associated hooks
```

## Commands

##### task start <feature-branch-name>

Start work on a new or existing task branch

##### task status

View the status of a task branch

##### task ready <environment-name>

Pre-merge a task branch with an environment branch for later deployment

##### task deploy <environment-name>

Deploy a task branch to a given environment (and all its dependent envs too)

##### task cleanup

Clean up branches that have been deployed or abandoned

## Configuration

Put your task configuration in `deployment.yaml` at the root of your project.  Here's a sample configuration file:

```
environments:
  development:
    branch_name: dev

  qa:
    branch_name: qa
    dependent_environment: dev

  production:
    branch_name: master
    dependent_environment: qa

github_url: https://github.com/sample/project

hooks:
  - email: hooks/email_changes
```

Specify the following options:

##### environments

Specify a mapping of environments.  Each environment value is itself a map specifying the following keys:

- `branch\_name` - name of the long-lived branch associated with this environment
- `dependent\_environment` - name of any lower environment which must contain a task/feature branch before it gets merged into this environment (optional)
- `hooks` - a mapping of hook names to sequences where each value in the sequence is an executable script to be run upon deployment to this environment (optional)
- `allow\_ready` - allow pre-merging via "ready" branches for this environment (optional)

##### github\_url

GitHub url for the origin repo.  Currently only used for generating "compare" URLs to view diffs.  Optional.

##### hooks

A mapping of hook names to sequences where each value in the sequence is an executable script to be run upon deployment to any environment.  Optional.

An executing hook script can find `TASK\_REPO\_ROOT`, `TASK\_DEPLOY\_SHA`, and `TASK\_DEPLOY\_ENVIRONMENT` in its environment.

##### mainline\_branch

Branch from which new task/feature branches should be cut.  Optional, defaults to `master`.

##### repo\_root

Path to the root of the repository.  Optional, defaults to (`.`).

## Building Task

Something about like this should build a fat-packed script with dependencies inline:

```bash
$ plenv install 5.8.9
$ plenv shell 5.8.9
$ curl -L cpanmin.us > cpanm
$ chmod 755 cpanm
$ ./cpanm IPC::Cmd -f
$ plenv install-cpanm
$ rm cpanm
$ rm -rf local
$ cpanm -nq -l local --installdeps --with-develop --with-recommends --with-suggests .
$ export PERL5LIB=$PWD/local/lib/perl5
$ export PATH="$PWD/local/bin:$PATH"
$ ./build.pl
```

## Pre-built Downloads

You may want to use a pre-built fat-packed build of task for your version of Perl:

[http://code.shutterstock.com/task/build/perl-5.8/task]<br>
[http://code.shutterstock.com/task/build/perl-5.10/task]<br>
[http://code.shutterstock.com/task/build/perl-5.12/task]<br>
[http://code.shutterstock.com/task/build/perl-5.14/task]<br>
[http://code.shutterstock.com/task/build/perl-5.16/task]<br>
[http://code.shutterstock.com/task/build/perl-5.18/task]<br>


