#!/bin/sh

error_exit ()
{
  echo "$*" 1>&2
  exit 1
}

# Test everything, but only build and release our master.
if [ "$TRAVIS_BRANCH" != "master" ]; then
  exit 0
fi

if [ "$TRAVIS_PULL_REQUEST" != "false" ] ; then
  exit 0
fi

# Make note of where we built it
BUILD_RESULT="$PWD/task"

# Check out the repo read-write with our token and go into the gh-pages branch
cd ..
git clone -q -b gh-pages https://${GH_TOKEN}@github.com/shutterstock/task.git gh-pages >/dev/null 2>&1 || error_exit "Error cloning gh-pages"
cd gh-pages

# Set up a user/email to commit with
git config user.name "Travis Automated Build"
git config user.email "task@shutterstock.com"

# Copy the fatpacked binary into an appropriate dir in gh-pages
BUILDDIR="build/perl-${TRAVIS_PERL_VERSION}"
mkdir -p $BUILDDIR
cp $BUILD_RESULT $BUILDDIR/task

# And commit it
git add $BUILDDIR/task
git commit -q -m "Travis build $TRAVIS_BUILD_NUMBER for ${TRAVIS_PERL_VERSION}"

# Try to mitigate race conditions a little
git pull --rebase
# Then push it back
git push -q origin gh-pages >/dev/null 2>&1 || error_exit "Error pushing build to github"
