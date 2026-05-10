#!/usr/bin/env python3

import argparse
import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path


USE_COLOR = sys.stdout.isatty() and not os.environ.get("NO_COLOR")
BOLD = "\033[1m" if USE_COLOR else ""
DIM = "\033[2m" if USE_COLOR else ""
YELLOW = "\033[33m" if USE_COLOR else ""
MAGENTA = "\033[35m" if USE_COLOR else ""
CYAN = "\033[36m" if USE_COLOR else ""
RESET = "\033[0m" if USE_COLOR else ""


def ask(message):
    # Read from the controlling terminal so prompts still work if stdout is piped.
    with open("/dev/tty", "r+") as tty:
        tty.write(message)
        tty.flush()
        return tty.readline().strip()


def confirm(prompt_text, default_answer):
    if default_answer == "yes":
        choices = "[Y/n]"
    elif default_answer == "no":
        choices = "[y/N]"
    else:
        raise ValueError(f"invalid default answer: {default_answer}")

    while True:
        answer = ask(f"{prompt_text} {choices} ")
        if answer == "":
            return default_answer == "yes"
        if answer in ("Y", "y"):
            return True
        if answer in ("N", "n"):
            return False
        with open("/dev/tty", "w") as tty:
            tty.write(f"{YELLOW}Please answer y or n.{RESET}\n")


def run_git(args, cwd, *, check=True, capture=True):
    result = subprocess.run(
        ["git", *args],
        cwd=cwd,
        check=False,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )
    if check and result.returncode != 0:
        stderr = result.stderr.strip() if result.stderr else ""
        raise RuntimeError(f"git {' '.join(args)} failed in {cwd}: {stderr}")
    return result


def git_ok(args, cwd):
    return run_git(args, cwd, check=False).returncode == 0


def status_paths(repo_dir):
    # Use NUL-delimited porcelain output so filenames with spaces/newlines parse safely.
    result = subprocess.run(
        ["git", "status", "--porcelain=v1", "-z"],
        cwd=repo_dir,
        check=True,
        stdout=subprocess.PIPE,
    )
    entries = result.stdout.split(b"\0")
    paths = []
    i = 0
    while i < len(entries):
        entry = entries[i]
        i += 1
        if not entry:
            continue

        status = entry[:2].decode("ascii", errors="replace")
        path = entry[3:].decode("utf-8", errors="surrogateescape")
        if status[0] in ("R", "C"):
            # In -z porcelain output, renamed/copied entries include the original
            # path as the next NUL-delimited field. The new path is the one to stat.
            i += 1

        if "D" not in status:
            paths.append(path)

    return paths


def latest_change_date(repo_dir, paths):
    latest_timestamp = None
    for path in paths:
        try:
            timestamp = (repo_dir / path).stat().st_mtime
        except OSError:
            continue
        if latest_timestamp is None or timestamp > latest_timestamp:
            latest_timestamp = timestamp

    if latest_timestamp is None:
        return ""
    return datetime.fromtimestamp(latest_timestamp).strftime("%Y-%m-%d")


def find_git_dirs(parent_dir):
    # The tool lives inside one repo and scans its parent for sibling repos.
    for root, dirs, _files in os.walk(parent_dir, followlinks=True):
        if ".git" in dirs:
            yield Path(root) / ".git"
            # Do not descend into Git internals after finding a repository root.
            dirs.remove(".git")


def parse_args(argv):
    parser = argparse.ArgumentParser(
        prog=Path(argv[0]).name,
        description="Checks sibling repositories for commits that need to be pushed.",
    )
    parser.add_argument(
        "--remote",
        action="append",
        default=[],
        dest="selected_remotes",
        metavar="REMOTE",
        help="Only check this remote. Can be repeated.",
    )
    return parser.parse_args(argv[1:])


def main(argv):
    args = parse_args(argv)

    script_dir = Path(__file__).resolve().parent
    parent_dir = script_dir.parent

    repos_with_skipped_remotes = []
    repos_with_unstaged_changes = []

    for git_dir in find_git_dirs(parent_dir):
        repo_dir = git_dir.parent
        print(f"Checking {CYAN}{repo_dir}{RESET}")

        paths = status_paths(repo_dir)
        if paths:
            repos_with_unstaged_changes.append((repo_dir, latest_change_date(repo_dir, paths)))

        if git_ok(["show-ref", "--verify", "--quiet", "refs/heads/main"], repo_dir):
            branch = "main"
        elif git_ok(["show-ref", "--verify", "--quiet", "refs/heads/master"], repo_dir):
            branch = "master"
        else:
            print(
                f"{YELLOW}Warning:{RESET} neither {BOLD}main{RESET} nor "
                f"{BOLD}master{RESET} branch found in {CYAN}{repo_dir}{RESET}"
            )
            continue

        remotes_output = run_git(["remote"], repo_dir).stdout
        remotes = [line for line in remotes_output.splitlines() if line]

        if not remotes:
            print(f"{YELLOW}Warning:{RESET} no remotes configured in {CYAN}{repo_dir}{RESET}")

        if args.selected_remotes and remotes:
            for selected_remote in args.selected_remotes:
                if not git_ok(["remote", "get-url", selected_remote], repo_dir):
                    print(
                        f"{YELLOW}Warning:{RESET} remote {MAGENTA}{selected_remote}{RESET} "
                        f"is not configured in {CYAN}{repo_dir}{RESET}"
                    )

        for remote in remotes:
            if args.selected_remotes and remote not in args.selected_remotes:
                repos_with_skipped_remotes.append((repo_dir, remote))
                continue

            if not git_ok(["show-ref", "--verify", "--quiet", f"refs/remotes/{remote}/{branch}"], repo_dir):
                if confirm(
                    f"{YELLOW}Remote{RESET} {MAGENTA}{remote}{RESET} has no "
                    f"{BOLD}{branch}{RESET} branch. {BOLD}Push and create it?{RESET}",
                    "no",
                ):
                    run_git(["push", remote, branch], repo_dir, capture=False)
                else:
                    print(f"{DIM}Skipping push to {MAGENTA}{remote}/{branch}{RESET}")
                continue

            ahead = int(run_git(["rev-list", "--count", f"{remote}/{branch}..{branch}"], repo_dir).stdout.strip())
            if ahead != 0:
                print(
                    f"{BOLD}{branch}{RESET} at {CYAN}{repo_dir}{RESET} is "
                    f"{BOLD}{ahead}{RESET} commit(s) ahead of {MAGENTA}{remote}/{branch}{RESET}"
                )

                if confirm(f"{BOLD}Push changes to{RESET} {MAGENTA}{remote}/{branch}{RESET}?", "yes"):
                    run_git(["push", remote, branch], repo_dir, capture=False)
                else:
                    print(f"{DIM}Skipping push to {MAGENTA}{remote}/{branch}{RESET}")

    if repos_with_unstaged_changes:
        print()
        print(f"{BOLD}{YELLOW}Repositories with unstaged changes:{RESET}")
        for repo_path, latest_date in repos_with_unstaged_changes:
            if latest_date:
                print(f"  {YELLOW}-{RESET} {CYAN}{repo_path}{RESET} {DIM}(latest change: {latest_date}){RESET}")
            else:
                print(f"  {YELLOW}-{RESET} {CYAN}{repo_path}{RESET} {DIM}(no date available){RESET}")

    if repos_with_skipped_remotes:
        print()
        print(f"{BOLD}{YELLOW}Remotes skipped by --remote:{RESET}")
        for repo_path, remote in repos_with_skipped_remotes:
            print(f"  {YELLOW}-{RESET} {CYAN}{repo_path}{RESET} {DIM}->{RESET} {MAGENTA}{remote}{RESET}")

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv))
    except BrokenPipeError:
        raise SystemExit(1)
    except RuntimeError as error:
        print(f"{YELLOW}Error:{RESET} {error}", file=sys.stderr)
        raise SystemExit(1)
