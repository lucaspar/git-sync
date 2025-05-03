# Git Sync

> Adapted from [this git-sync](https://github.com/simonthum/git-sync).

+ `git-sync` synchronizes the current branch to a git remote.
+ `git-sync` automates git synchronization for repositories that prioritize tracking over maintaining a clean commit history.
+ `git-sync` is a smarter way to `git add -u; git commit -m "changes"; git push` that:
    + Detects when _not_ to continue e.g. no repo; no remote; during a merge, rebase, or cherry-pick; or when bisecting;
    + Handles submodules recursively;
    + Checks for remote ownership to avoid accidentally pushing to third-party repositories;
    + Has nice human-readable output;

+ [Git Sync](#git-sync)
    + [Additional features](#additional-features)
    + [Branch configuration](#branch-configuration)
    + [Ownership check](#ownership-check)

## Additional features

Changes from the base work include:

+ Fixed shellcheck errors and warnings;
+ Better repo state handling;
+ Refactored functions;
+ Improved output formatting and added colored logs, with `NO_COLOR` respected if set;
+ Soft remote ownership check to prevent accidentally syncing to a remote not owned by you;
+ Reduced stdout by using quiet versions of git commands;
+ Support for bare repos, useful for dotfile repos. Set `GIT_CMD` before running it e.g.:
    + `GIT_CMD='git --git-dir=${HOME}/.cfg/ --work-tree=${HOME}' git-sync`
+ Support to recursively sync submodules;
+ Debug mode to log additional messages.

```log
$ git-sync --help

 Synchronizes the current branch to a git remote.

 Usage: git-sync [MODE] [OPTIONS]


 MODE:
    sync    Synchronize the current branch to a remote backup (default)
    check   Verify that the branch is ready to sync

 OPTIONS:
    -h | --help            Show this message.
    -n | --sync-new-files  Commit new files even if branch.${branch_name}.syncNewFiles isn't set.
    -s | --sync-branch     Sync the branch even if branch.${branch_name}.sync isn't set.
    -r | --recursive       Sync submodules recursively.
    -d | --debug           Debug mode: runs script with added verbosity.
```

## Branch configuration

There are three options to use in your `${XDG_CONFIG_HOME}/git/config` or the config of
a specific repository.

+ `branch.$branch_name.syncNewFiles (bool)`

    Tells git-sync to invoke auto-commit even if new (untracked) files are present.
    Normally, you have to commit those yourself to prevent accidental additions.

+ `branch.$branch_name.syncCommitMsg (string)`

    The default commit message for this branch. When not set, it will default to
    `"changes from $(uname -n)"`.

+ `branch.$branch_name.autoCommitScript (string)`

    Command to perform an auto-commit. e.g. `"git add -u; git commit -m \"%message\";"`.
    At runtime, `%message` is replaced with the default commit message or with the value
    for `branch.$branch_name.syncCommitMsg` if set. Pushing is handled by the script.

Example:

```ini
[branch "main"]
    syncNewFiles = true
    syncCommitMsg = "Syncing changes from $(uname -n)"
    autoCommitScript = "git add -u; git commit -m \"%message\";"
```

## Ownership check

`git-sync` attempts to check that the current git user owns the remote we're trying
to push to. This is a safeguard to prevent accidental pushes to repositories where
a better crafted commit message is likely desired. If the ownership check fails,
you will see a message with a few suggestions on how to fix it.

The ownership check attempts to match the user or organization in the remote's URI with
the username of the current git user (the part before the `@` in the email address).
If they match, the user is considered the owner of the remote. GitHub and other forges
provide a no-reply email address that can be used for commits and will play nicely with
this check e.g. `<github-user>@users.noreply.github.com`.

The remote configured as the default for pushes is the one used to match with the
current user

To bypass this check at the risk of pushing automated commits to repositories you
don't own, you can set the `GIT_SYNC_ALLOW_NONOWNER=1` environment variable.
