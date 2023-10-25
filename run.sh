#!/bin/bash

# Get the directory containing the script
script_dir="$(dirname "$0")"

# Go to the parent directory
cd "$script_dir/.." || exit
parent_dir=$(pwd)

# Iterate over all subdirectories of the parent directory
while IFS= read -r -d '' repo
do
    # Navigate to the repository's root directory
    repo_dir=$(dirname "$repo")
    cd "$repo_dir" || exit

    # Check if the repository has a main or master branch
    if git show-ref --verify --quiet refs/heads/main; then
        branch="main"
    elif git show-ref --verify --quiet refs/heads/master; then
        branch="master"
    else
        echo "Neither main nor master branch found in $repo_dir"
        continue
    fi
    echo "Checking $repo_dir"
    
    # Iterate over all remotes
    for remote in $(git remote); do
        # Check if the branch is ahead of the remote branch
        ahead=$(git rev-list --count "$remote/$branch..$branch")
        if [ "$ahead" -ne 0 ]; then
            echo "Local branch $branch at $repo_dir is $ahead commit(s) ahead of $remote/$branch"

            # Confirm before pushing
            read -p "Push changes to $remote/$branch? [yn]" answer </dev/tty
            if [[ $answer =~ ^[Yy]$ ]]
            then
                git push "$remote" "$branch"
            fi
        fi
    done
done < <(find "$parent_dir" -type d -name '.git' -print0)
