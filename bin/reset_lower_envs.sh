#/bin/bash

# display commands and their arguments as they are executed
set -x

for branch_name in staging qa integration
do
	# make sure we're up to date to begin with
	git remote update --prune

	echo Removing $branch_name-ready branches from origin with now invalid commits in them

	# show and then delete '$env-ready' branches so there is no premerged content with now invalid refs for that env
	git branch -r | grep "\<$branch_name-ready" | sed 's/\s*origin\///'
	git branch -r | grep "\<$branch_name-ready" | sed 's/\s*origin\//:/' | xargs --no-run-if-empty git push origin

	# make sure we're up to date
	git remote update --prune

	origin_master=$(git rev-parse origin/master)
	echo "Resetting $branch_name back to the current state of production ($origin_master)"

	# then check out a temporary env branch and reset it to the production state
	git checkout -b temp_$branch_name origin/$branch_name
	git reset --hard origin/master
	git push origin +temp_$branch_name:$branch_name
	git remote update --prune

	# get rid of temporary env branch
	git checkout master
	git branch -d temp_$branch_name

done
