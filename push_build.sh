#!/bin/sh

error_exit ()
{
  echo "$*" 1>&2
  exit 1
}

cp task $HOME/task

cd ..
git clone -q -b gh-pages https://${GH_TOKEN}@github.com/shutterstock/task.git gh-pages >/dev/null 2>&1 || error_exit "Error cloning gh-pages"
cd gh-pages

git config user.name "Travis Automated Build"
git config user.email "task@shutterstock.com"

BUILDDIR="build/perl-${TRAVIS_PERL_VERSION}"
mkdir -p $BUILDDIR
cp $HOME/task $BUILDDIR/task
git add $BUILDDIR/task
git commit -q -m "Travis build $TRAVIS_BUILD_NUMBER"
git push -fq origin gh-pages >/dev/null 2>&1 || error_exit "Error pushing build to github"
