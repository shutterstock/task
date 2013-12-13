task
====

Here's how I could get this to build:

    plenv install 5.8.9
    plenv shell 5.8.9
    curl -L cpanmin.us > cpanm
    chmod 755 cpanm
    ./cpanm IPC::Cmd -f
    plenv install-cpanm
    rm cpanm
    rm -rf local
    cpanm -nq -l local --installdeps --with-develop --with-recommends --with-suggests .
    export PERL5LIB=$PWD/local/lib/perl5
    export PATH="$PWD/local/bin:$PATH"
    ./build.pl

[![Build Status](https://travis-ci.org/shutterstock/task.png)](https://travis-ci.org/shutterstock/task)

