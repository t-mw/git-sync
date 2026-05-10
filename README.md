# git-sync

Checks each repository in the parent directory for changes that need to be pushed to remotes.

## Options

```bash
./run.py --remote origin --tags
```

Use `--remote REMOTE` to check only specific remotes. The flag can be repeated, and skipped remotes are printed at the end.

Use `--tags` with `--remote` to push tags after a branch is pushed to that remote.
