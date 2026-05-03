#!/bin/bash

script_dir="$(dirname "$0")"
cd "$script_dir/.." || exit
parent_dir=$(pwd)

bold=""
dim=""
yellow=""
magenta=""
cyan=""
reset=""

# Only emit ANSI colors for interactive terminal output. This keeps redirected logs
# clean and respects the standard NO_COLOR opt-out convention.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    bold=$(tput bold 2>/dev/null || true)
    dim=$(tput dim 2>/dev/null || true)
    yellow=$(tput setaf 3 2>/dev/null || true)
    magenta=$(tput setaf 5 2>/dev/null || true)
    cyan=$(tput setaf 6 2>/dev/null || true)
    reset=$(tput sgr0 2>/dev/null || true)
fi

say() {
    printf "%b\n" "$*"
}

ask() {
    printf "%b" "$*" >/dev/tty
}

latest_change_date() {
    local latest_timestamp

    # Parse `git status --porcelain` output and use the newest modified, non-deleted
    # file as a useful hint for how stale the unstaged work might be.
    latest_timestamp=$(printf "%s\n" "$1" | while read -r status file; do
        if [[ ! "$status" =~ ^D ]]; then
            if [[ "$OSTYPE" == "darwin"* ]]; then
                stat -f "%m" "$file" 2>/dev/null || echo "0"
            else
                stat -c "%Y" "$file" 2>/dev/null || echo "0"
            fi
        fi
    done | sort -rn | head -1)

    if [ -z "$latest_timestamp" ] || [ "$latest_timestamp" = "0" ]; then
        return
    fi

    if [[ "$OSTYPE" == "darwin"* ]]; then
        date -r "$latest_timestamp" "+%Y-%m-%d"
    else
        date -d "@$latest_timestamp" "+%Y-%m-%d"
    fi
}

declare -a repos_with_unstaged_changes

while IFS= read -r -d '' repo; do
    repo_dir=$(dirname "$repo")
    cd "$repo_dir" || exit

    say "Checking ${cyan}$repo_dir${reset}"

    status=$(git status --porcelain)
    if [ -n "$status" ]; then
        repos_with_unstaged_changes+=("$repo_dir|$(latest_change_date "$status")")
    fi

    if git show-ref --verify --quiet refs/heads/main; then
        branch="main"
    elif git show-ref --verify --quiet refs/heads/master; then
        branch="master"
    else
        say "${yellow}Warning:${reset} neither ${bold}main${reset} nor ${bold}master${reset} branch found in ${cyan}$repo_dir${reset}"
        cd "$parent_dir" || exit
        continue
    fi

    for remote in $(git remote); do
        if ! git show-ref --verify --quiet "refs/remotes/$remote/$branch"; then
            ask "${yellow}Remote${reset} ${magenta}$remote${reset} has no ${bold}$branch${reset} branch. ${bold}Push and create it?${reset} [y/N] "
            read -r answer </dev/tty
            if [[ $answer =~ ^[Yy]$ ]]; then
                git push "$remote" "$branch"
            else
                say "${dim}Skipping push to ${magenta}$remote/$branch${reset}"
            fi
            continue
        fi

        ahead=$(git rev-list --count "$remote/$branch..$branch")
        if [ "$ahead" -ne 0 ]; then
            say "${bold}$branch${reset} at ${cyan}$repo_dir${reset} is ${bold}$ahead${reset} commit(s) ahead of ${magenta}$remote/$branch${reset}"

            ask "${bold}Push changes to${reset} ${magenta}$remote/$branch${reset}? [Y/n] "
            read -r answer </dev/tty
            if [[ $answer =~ ^[Nn]$ ]]; then
                say "${dim}Skipping push to ${magenta}$remote/$branch${reset}"
            else
                git push "$remote" "$branch"
            fi
        fi
    done

    cd "$parent_dir" || exit
# The script lives in a git-sync directory, so scan its parent for sibling repos.
done < <(find -L "$parent_dir" -type d -name '.git' -print0)

if [ ${#repos_with_unstaged_changes[@]} -gt 0 ]; then
    echo
    say "${yellow}----------------------------------------${reset}"
    say "${bold}${yellow}Repositories with unstaged changes:${reset}"
    for repo_info in "${repos_with_unstaged_changes[@]}"; do
        repo_path="${repo_info%%|*}"
        latest_date="${repo_info#*|}"
        if [ -n "$latest_date" ]; then
            printf "  ${yellow}-${reset} ${cyan}%s${reset} ${dim}(latest change: %s)${reset}\n" "$repo_path" "$latest_date"
        else
            printf "  ${yellow}-${reset} ${cyan}%s${reset} ${dim}(no date available)${reset}\n" "$repo_path"
        fi
    done
    say "${yellow}----------------------------------------${reset}"
fi
