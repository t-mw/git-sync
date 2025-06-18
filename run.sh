#!/bin/bash

# Get the directory containing the script
script_dir="$(dirname "$0")"

# Go to the parent directory
cd "$script_dir/.." || exit
parent_dir=$(pwd)

declare -a repos_with_unstaged_changes

# Iterate over all subdirectories of the parent directory
while IFS= read -r -d '' repo
do
    # Navigate to the repository's root directory
    repo_dir=$(dirname "$repo")
    cd "$repo_dir" || exit

    echo "Checking $repo_dir"

    # `git status --porcelain` is empty if the working directory is clean
    if [ -n "$(git status --porcelain)" ]; then
        # Get the date of the most recently modified unstaged file
        latest_timestamp=$(git status --porcelain | while read -r status file; do
            # Skip deleted files
            if [[ ! "$status" =~ ^D ]]; then
                stat -c "%Y" "$file" 2>/dev/null || echo "0"
            fi
        done | sort -rn | head -1)
        
        if [ "$latest_timestamp" != "0" ] && [ -n "$latest_timestamp" ]; then
            latest_date=$(date -d "@$latest_timestamp" "+%Y-%m-%d")
        else
            latest_date=""
        fi
        
        repos_with_unstaged_changes+=("$repo_dir|$latest_date")
    fi

    # Check if the repository has a main or master branch
    if git show-ref --verify --quiet refs/heads/main; then
        branch="main"
    elif git show-ref --verify --quiet refs/heads/master; then
        branch="master"
    else
        echo "Neither main nor master branch found in $repo_dir"
        cd "$parent_dir" # Go back to the parent to continue the loop
        continue
    fi

    # Iterate over all remotes
    for remote in $(git remote); do
        # Check if the branch is ahead of the remote branch
        ahead=$(git rev-list --count "$remote/$branch..$branch" 2>/dev/null)
        if [ "$ahead" -ne 0 ]; then
            echo "Local branch $branch at $repo_dir is $ahead commit(s) ahead of $remote/$branch"

            # Confirm before pushing
            read -p "Push changes to $remote/$branch? [y/n] " answer </dev/tty
            if [[ $answer =~ ^[Yy]$ ]]
            then
                git push "$remote" "$branch"
            fi
        fi
    done

    # Go back to the parent directory to process the next repository
    cd "$parent_dir" || exit

done < <(find "$parent_dir" -type d -name '.git' -print0)


if [ ${#repos_with_unstaged_changes[@]} -gt 0 ]; then
    echo
    echo "----------------------------------------"
    echo "Repositories with unstaged changes:"
    for repo_info in "${repos_with_unstaged_changes[@]}"; do
        repo_path="${repo_info%%|*}"
        latest_date="${repo_info#*|}"
        if [ -n "$latest_date" ] && [ "$latest_date" != "$repo_path" ]; then
            printf "  - %s (latest change: %s)\n" "$repo_path" "$latest_date"
        else
            printf "  - %s (no date available)\n" "$repo_path"
        fi
    done
    echo "----------------------------------------"
fi
