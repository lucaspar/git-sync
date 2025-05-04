#!/usr/bin/env bash
set -euo pipefail
#
# Synchronizes tracking repositories.
#
# Source: https://github.com/lucaspar/git-sync
#
# Run `git-sync -h` for help
#
# This script intends to sync via git near-automatically
# in "tracking" repositories where a nice history is not
# crucial, but having one at all is.
#
# Sync mode (default)
#       Sync will likely get from you from a dull normal git repo with trivial
#       changes to an updated dull normal git repo equal to origin. No more, no
#       less. The intent is to do everything that's needed to sync automatically,
#       and resort to manual intervention as soon as something non-trivial occurs.
#       It is designed to be safe in that it will likely refuse to do anything not
#       known to be safe.
#
# Check mode
#       Check only performs the basic checks to make sure the repository is in
#       an orderly state to continue syncing, i.e. committing changes, pull etc.
#       without losing any data. When check returns 0, sync can start immediately.
#       This does not, however, indicate that syncing is at all likely to succeed.
#
# Ownership check
#
#       git-sync attempts to check that the current git user owns the remote we're
#       trying to push to. This is a safeguard to prevent accidental pushes to
#       repositories where a better crafted commit message is likely desired. If the
#       ownership check fails, you will see a message with a few suggestions on how to
#       fix it. To bypass this check at the risk of pushing automated commits to
#       repositories you don't own, you can set the GIT_SYNC_ALLOW_NONOWNER environment
#       variable.

# override for the git command, e.g. in case we're using a bare repo:
#   GIT_CMD='git --git-dir=${HOME}/.cfg/ --work-tree=${HOME}' git-sync
GIT_CMD="${GIT_CMD:-git}"
# expand variables in GIT_CMD, if present
GIT_CMD=$(eval echo "${GIT_CMD}")

# command used to auto-commit file modifications
DEFAULT_AUTOCOMMIT_CMD="${GIT_CMD} add -u; ${GIT_CMD} commit -m \"%message\";"

# command used to auto-commit all changes
ALL_AUTOCOMMIT_CMD="${GIT_CMD} add -A; ${GIT_CMD} commit -m \"%message\";"

# default commit message substituted into autocommit commands
DEFAULT_AUTOCOMMIT_MSG="changes from $(uname -n)"

# ================================
# ENVIRONMENT VARIABLES FOR CONTROL

# When set, it allows syncing even when the user is not the owner of the repository.
# Default is unset.
GIT_SYNC_ALLOW_NONOWNER="${GIT_SYNC_ALLOW_NONOWNER:-}"

# User to check for remote ownership (e.g. GitHub user).
# When not provided, a best-effort guess is made based on the configured git email.
GIT_SYNC_PROVIDER_USER="${GIT_SYNC_USER:-}"

function print_usage() {

    script_base_name=$(basename "${0}")
    echo -e "\n\t\033[0;34mSynchronizes the current branch to a git remote.\033[0m\n"
    echo -e "\tUsage:\t\033[0;32m${script_base_name} [MODE] [OPTIONS]\033[0m\n\n"

    echo -e "\tMODE:"
    echo -e "\t    sync    Synchronize the current branch to a remote backup (default)"
    echo -e "\t    check   Verify that the branch is ready to sync\n"

    echo -e "\tOPTIONS:"
    echo -e "\t    -h | --help            Show this message."
    echo -e "\t    -n | --sync-new-files  Commit new files even if branch.\$branch_name.syncNewFiles isn't set."
    echo -e "\t    -s | --sync-branch     Sync the branch even if branch.\$branch_name.sync isn't set."
    echo -e "\t    -r | --recursive       Sync submodules recursively."
    echo -e "\t    -d | --debug           Debug mode: runs script with added verbosity.\n"
    echo

}

PREFIX="gs ⟩ "

function log_debug() {
    if [ "${DEBUG}" == "true" ]; then
        if [ -z "${NO_COLOR:-}" ]; then
            echo -e "\t\033[1;35m${PREFIX}${repo_name} | ${1}\033[0m"
        else
            echo -e "\t${PREFIX}${repo_name} | ${1}"
        fi
    fi
}

function log_msg() {
    if [ -z "${NO_COLOR:-}" ]; then
        echo -e "\t\033[1;34m${PREFIX}${repo_name}\033[0m | ${1}"
    else
        echo -e "\t${PREFIX}${repo_name} | ${1}"
    fi
}

function log_info() {
    if [ -z "${NO_COLOR:-}" ]; then
        echo -e "\t\033[1;36m${PREFIX}${repo_name} | ${1}\033[0m"
    else
        echo -e "\t${PREFIX}${repo_name} | ${1}"
    fi
}

function log_err() {
    if [ -z "${NO_COLOR:-}" ]; then
        echo -e "\t\033[1;33m${PREFIX}${repo_name} | ${1}\033[0m" >&2
    else
        echo -e "\t${PREFIX}${repo_name} | ${1}" >&2
    fi
}

function log_success() {
    if [ -z "${NO_COLOR:-}" ]; then
        echo -e "\t\033[1;32m${PREFIX}${repo_name} | ${1}\033[0m"
    else
        echo -e "\t${PREFIX}${repo_name} | ${1}"
    fi
}

# echo the git dir
function git_dir() {
    if [ "$(${GIT_CMD} rev-parse --is-inside-work-tree "$PWD" 2>/dev/null | head -1)" == "true" ]; then
        ${GIT_CMD} rev-parse --git-dir "$PWD" 2>/dev/null | head -n 1
    fi
}

function get_repo_name() {
    local real_git_dir
    real_git_dir="$(realpath "$(git_dir)" 2>/dev/null)"
    local repo_name
    if [[ "${real_git_dir}" =~ modules/([^/]+)$ ]]; then
        # if real_git_dir ends in "modules/*", get the last part
        repo_name="${BASH_REMATCH[1]}"
    else
        # otherwise, get the parent's name
        repo_name=$(basename "$(dirname "${real_git_dir}")")
    fi
    echo "${repo_name}"
}

repo_name=$(get_repo_name)

# echos repo state
function get_repo_state() {
    local git_dir
    local repo_state
    git_dir="$(git_dir)"
    repo_state=""
    if [ -z "${git_dir}" ]; then
        repo_state="NOGIT"
    else
        if [ -f "${git_dir}/rebase-merge/interactive" ]; then
            repo_state="REBASE-i"
        elif [ -d "${git_dir}/rebase-merge" ]; then
            repo_state="REBASE-m"
        else
            if [ -d "${git_dir}/rebase-apply" ]; then
                repo_state="AM/REBASE"
            elif [ -f "${git_dir}/MERGE_HEAD" ]; then
                repo_state="MERGING"
            elif [ -f "${git_dir}/CHERRY_PICK_HEAD" ]; then
                repo_state="CHERRY-PICKING"
            elif [ -f "${git_dir}/BISECT_LOG" ]; then
                repo_state="BISECTING"
            else
                repo_state="NORMAL"
            fi
        fi
        if [ "true" = "$(${GIT_CMD} rev-parse --is-inside-git-dir 2>/dev/null)" ]; then
            if [ "true" = "$(${GIT_CMD} rev-parse --is-bare-repository 2>/dev/null)" ]; then
                repo_state="${repo_state} | BARE"
            else
                repo_state="${repo_state} | GIT_DIR"
            fi
        elif [ "true" = "$(${GIT_CMD} rev-parse --is-inside-work-tree 2>/dev/null)" ]; then
            if ! ${GIT_CMD} diff --no-ext-diff --quiet --exit-code; then
                repo_state="${repo_state} | DIRTY"
            else
                repo_state="${repo_state} | CLEAN"
            fi
        fi
    fi
    echo "${repo_state}"
}

# check if we only have untouched, modified or (if configured) new files
function check_initial_file_state() {
    local sync_new_files_config
    sync_new_files_config="$(${GIT_CMD} config --get --bool "branch.${branch_name}.syncNewFiles")"
    return_state=""
    if [[ "${sync_new_files_config}" == "true" || "${sync_new_files_cli}" == "true" ]]; then
        # allowing for new files...
        if [ -n "$(${GIT_CMD} status --porcelain | ${grep_exe} -E '^[^ \?][^M\?] *')" ]; then
            return_state="new-or-untracked"
        fi
    else
        # only allow for modified files
        if [ -n "$(${GIT_CMD} status --porcelain | ${grep_exe} -E '^[^ ][^M] *')" ]; then
            return_state="only-modified"
        fi
    fi
    echo "${return_state}"
}

# look for local changes
#   used to decide if autocommit should be invoked
function local_changes() {
    if ${GIT_CMD} status --porcelain | "${grep_exe}" -q -E '^(\?\?|[MARC] |[ MARC][MD])*'; then
        echo "LocalChanges"
    fi
}

# determine sync state of repository, i.e. how the remote relates to our HEAD
function get_sync_state() {
    local count
    count="$(${GIT_CMD} rev-list --count --left-right "${remote_name}/${branch_name}"...HEAD)"

    local diff_state

    case "${count}" in
    "") # no upstream
        diff_state="noUpstream"
        ;;
    $'0\t0')
        diff_state="equal"
        ;;
    $'0\t'*)
        diff_state="ahead"
        ;;
    *$'\t0')
        diff_state="behind"
        ;;
    *)
        diff_state="diverged"
        ;;
    esac

    echo "${diff_state}"
}

# exit, issue warning if not in sync
function exit_assuming_sync() {
    sync_state="$(get_sync_state)"
    if [ "equal" == "${sync_state}" ]; then
        log_success "In sync, all fine."
        exit 0
    else
        log_err "Synchronization failed (${sync_state}) | Check your repo carefully."
        log_msg "\tPossibly a transient network problem? Please try again in that case."
        exit 3
    fi
}

# basic checks before git-sync can start
function pre_checks() {

    repo_state="$(get_repo_state)"
    log_msg "Repo state: ${repo_state}"
    if [[ "${repo_state}" = "NORMAL | CLEAN" || "${repo_state}" = "NORMAL | DIRTY" ]]; then
        log_debug "Preparing. Repo in $(git_dir)"
    elif [[ "NOGIT" = "${repo_state}" ]]; then
        log_err "No git repository detected. Exiting."
        exit 128 # matches git's error code
    else
        log_err "Git repo state considered unsafe for sync. State: '$(get_repo_state)'"
        exit 2
    fi

    log_debug "Pre-checks OK"

}

# runs git status for the user
function git_status() {
    ${GIT_CMD} -c color.ui=always status --short --branch
}

# determine the current branch (thanks to stackoverflow)
function set_branch_name() {
    branch_name=$(${GIT_CMD} symbolic-ref -q HEAD)
    branch_name=${branch_name##refs/heads/}

    if [ -z "${branch_name}" ]; then
        log_msg "Syncing is only possible on a branch."
        git_status
        exit 2
    fi
}

function set_remote_name() {
    # while at it, determine the remote to operate on
    remote_name=$(${GIT_CMD} config --get "branch.${branch_name}.pushRemote" || true)
    if [ -z "${remote_name}" ]; then
        remote_name=$(${GIT_CMD} config --get "remote.pushDefault" || true)
    fi
    if [ -z "${remote_name}" ]; then
        remote_name=$(${GIT_CMD} config --get "branch.${branch_name}.remote" || true)
    fi

    if [ -z "${remote_name}" ] || [[ "${remote_name}" == "." ]]; then
        log_err "The current branch does not have a configured remote.\n"
        log_msg "Create a remote first, e.g."
        log_info "    git remote add origin <url>"
        log_msg "and set it as the upstream for this branch, e.g."
        log_info "    git branch --set-upstream-to=origin/${branch_name}"
        log_msg "Then, try again."
        exit 2
    fi
}

# check if current branch is configured for sync
function make_sure_current_branch_is_syncable() {
    if [[ "$(${GIT_CMD} config --get --bool "branch.${branch_name}.sync")" != "true" && "${sync_branch_cli}" != "true" ]]; then
        log_err "Branch '${branch_name}' is not configured for synchronization."
        log_msg "Please use\n\n"
        log_info "    git config --bool branch.${branch_name}.sync true"
        log_msg "    to enlist branch '${branch_name}' for synchronization."
        log_msg "Branch '${branch_name}' has to have a same-named remote branch"
        log_msg "    for git-sync to work.\n"
        exit 1
    fi
}

# this prevents syncing if we don't own the remote
function make_sure_remote_owner_is_git_user() {
    # remote owner might be a github user or organization, for example
    remote_owner=$(${GIT_CMD} remote get-url "${remote_name}" | cut -d: -f2 | cut -d/ -f1)
    if [ -z "${GIT_SYNC_PROVIDER_USER}" ]; then
        git_email=$(${GIT_CMD} config user.email)
        git_user=$(echo "${git_email}" | cut -d@ -f1)
    else
        git_user="${GIT_SYNC_PROVIDER_USER}"
    fi
    if [ "${remote_owner}" != "${git_user}" ]; then
        log_err "Remote ownership check failed:"
        log_msg "    ⟩ Inferred owner or remote '${remote_name}': '${remote_owner}'"
        log_msg "    ⟩ Inferred git user: '${git_user}'"
        log_msg "    If this is not correct, set the GIT_SYNC_PROVIDER_USER env var, or change"
        log_msg "    your git email to e.g.: <github_user>@users.noreply.github.com\n"
        log_msg "    The git-sync script doesn't apply special logic for providers, so it expects all"
        log_msg "    repos to have the same owner regardless of the provider (github, gitlab, etc)."
        log_msg "    If this is undesired, set the GIT_SYNC_ALLOW_NONOWNER env var to skip this check.\n"
        log_err "Remote owner (${remote_owner}) is not the same as git user (${git_user})."
        log_msg "    Because of this, we're preventing an automated push to a remote we don't"
        log_msg "    own, as you probably want to craft a commit message instead."
        log_msg "    You can override this behavior by setting GIT_SYNC_ALLOW_NONOWNER.\n\n"
        exit 1
    fi
    log_debug "Remote ownership verified: '${git_user}' matches '${remote_owner}'."
}

# check for intentionally unhandled file states
function run_file_state_check() {
    initial_file_state="$(check_initial_file_state)"
    if [ -n "${initial_file_state}" ]; then
        log_msg "There are changed files you should probably handle manually: ${initial_file_state}."
        git_status
        exit 1
    fi
}

# if in check mode, this is all we need to know
function exit_if_in_check_mode() {
    if [ "${mode}" == "check" ]; then
        log_success "Check OK; sync may start."
        exit 0
    fi
}

# indents the stdin with spaces
function indent() {
    _INDENT_WIDTH=4
    if [ -n "${1}" ]; then
        _INDENT_WIDTH=${1}
    fi
    repeated_spaces=$(printf "%${_INDENT_WIDTH}s")
    sed "s/^/${repeated_spaces}/"
}

# recursively sync submodules
function sync_submodules_recursively() {
    log_debug "Syncing submodules"
    submodules=$($GIT_CMD submodule | xargs -L1 | cut -f2 -d' ')
    THIS_SCRIPT="$(realpath "${0}")"
    OPTIONS=
    if [[ ${DEBUG} == "true" ]]; then
        OPTIONS+=" --debug"
    fi
    if [[ ${sync_new_files_cli} == "true" ]]; then
        OPTIONS+=" --sync-new-files"
    fi
    if [[ ${sync_branch_cli} == "true" ]]; then
        OPTIONS+=" --sync-branch"
    fi
    if [[ ${sync_submodules} == "true" ]]; then
        OPTIONS+=" --recursive"
    fi
    OLD_GIT_CMD="${GIT_CMD}"
    GIT_CMD="git"
    log_msg "Syncing submodules"
    for submodule in ${submodules}; do
        pushd "${submodule}" &>/dev/null || {
            log_err "Failed to pushd into submodule ${submodule}"
            continue
        }
        "${THIS_SCRIPT}" "${OPTIONS}" | indent 4 &
        popd &>/dev/null || {
            log_err "Failed to popd from submodule ${submodule}"
            continue
        }
    done
    wait
    GIT_CMD="${OLD_GIT_CMD}"
}

# check if we have to commit local changes, if yes, do so
function commit_on_local_changes() {
    if [ -z "$(local_changes)" ]; then
        log_msg "No local changes to commit."
    else
        autocommit_cmd=""
        config_autocommit_cmd="$(${GIT_CMD} config --get "branch.${branch_name}.autoCommitScript")" || true

        # discern the three ways to auto-commit
        if [ -n "${config_autocommit_cmd}" ]; then
            log_debug "Using autocommit command from config."
            autocommit_cmd="${config_autocommit_cmd}"
        elif [[ "$(${GIT_CMD} config --get --bool "branch.${branch_name}.syncNewFiles")" == "true" || "${sync_new_files_cli}" == "true" ]]; then
            log_debug "Using all autocommit command."
            autocommit_cmd=${ALL_AUTOCOMMIT_CMD}
        else
            log_debug "No autocommit command found; using default."
            autocommit_cmd=${DEFAULT_AUTOCOMMIT_CMD}
        fi

        commit_msg="$(${GIT_CMD} config --get "branch.${branch_name}.syncCommitMsg" || true)"
        if [ -z "${commit_msg}" ]; then
            log_debug "No custom commit message found; using default."
            commit_msg=${DEFAULT_AUTOCOMMIT_MSG}
        fi
        if [ -z "${commit_msg}" ]; then
            commit_msg=${DEFAULT_AUTOCOMMIT_MSG}
        fi
        autocommit_cmd=${autocommit_cmd//%message/${commit_msg}}

        if [[ ${sync_submodules} == "true" ]]; then
            log_debug "Syncing submodules recursively."
            sync_submodules_recursively
        fi

        log_msg "Syncing with '${remote_name}/${branch_name}'"
        log_debug "Committing local changes using:"
        log_debug "\t ${autocommit_cmd//;/\\n\\t\\t\\t}"
        eval "${autocommit_cmd}" 1>/dev/null || {
            log_err "Auto-commit failed."
            log_msg "Commands:\n\t\t\t ${autocommit_cmd//;/\\n\\t\\t\\t}"
            log_msg "If this repo has submodules that you are trying to sync, you can run git-sync recursively with:"
            log_msg "\tgit-sync -r\n"
            git_status
            exit 1
        }

        # after autocommit, we should be clean
        repo_state="$(get_repo_state)"
        if [[ "${repo_state}" != "NORMAL | CLEAN" ]]; then
            log_err "Auto-commit left uncommitted changes"
            log_msg "Please add or remove them as desired and retry."
            log_msg "If this is a submodule, you can run git-sync recursively with:"
            log_msg "\n\n\tgit-sync -r\n\n"
            git_status
            exit 1
        else
            log_debug "Auto-commit done."
        fi
    fi
}

# fetches from remote
function fetch_remote() {
    # TODO make fetching/pushing optional
    log_debug "Fetching from ${remote_name}/${branch_name}"
    ${GIT_CMD} fetch --quiet "${remote_name}" "${branch_name}"
    local status
    status=$?
    if [ "${status}" != 0 ]; then
        log_err "'git fetch ${remote_name}' returned non-zero. Likely a network problem; exiting."
        exit 3
    fi
}

# takes different actions depending on the repo sync state observed
function sync_multiplexer() {
    local sync_state
    local status
    sync_state="$(get_sync_state)"
    log_debug "Sync state: ${sync_state}"
    case "${sync_state}" in
    "noUpstream")
        # Who knows
        log_msg "Strange state; may Torvalds be with you, otherwise you're on your own."
        exit 2
        ;;
    "equal")
        # All good
        exit_assuming_sync
        ;;
    "ahead")
        # Just push
        log_debug "Pushing changes..."
        log_debug "Running:     git push ${remote_name} ${branch_name}:${branch_name}"
        ${GIT_CMD} push --quiet "${remote_name}" "${branch_name}:${branch_name}"
        status=$?
        if [ "${status}" == 0 ]; then
            exit_assuming_sync
        else
            log_msg "'git push' returned non-zero. Likely a connection failure."
            exit 3
        fi
        ;;
    "behind")
        # Just fast-forward
        log_msg "We are behind, fast-forwarding..."
        log_debug "Running:     git merge --ff --ff-only ${remote_name}/${branch_name}"
        ${GIT_CMD} merge --quiet --ff --ff-only "${remote_name}/${branch_name}"
        status=$?
        if [ "${status}" == 0 ]; then
            exit_assuming_sync
        else
            log_msg "'git merge --ff --ff-only' returned non-zero (${status}). Exiting."
            exit 2
        fi
        ;;
    "diverged")
        # Rebase then push
        log_msg "We have diverged. Trying to rebase..."
        log_debug "Running:     git rebase ${remote_name}/${branch_name}"
        ${GIT_CMD} rebase --quiet "${remote_name}/${branch_name}"
        status=$?
        sync_state="$(get_sync_state)"
        repo_state="$(get_repo_state)"
        if [[ "${status}" == 0 && "${repo_state}" == "NORMAL | CLEAN" && "ahead" == "${sync_state}" ]]; then
            log_msg "Rebasing went fine, pushing..."
            ${GIT_CMD} push --quiet "${remote_name}" "${branch_name}:${branch_name}"
            exit_assuming_sync
        else
            log_err "Rebasing failed, likely there are conflicting changes. Resolve them and finish the rebase before repeating git-sync."
            log_msg "Repo state: ${repo_state} - Sync state: ${sync_state}"
            exit 1
        fi
        ;;
    esac
}

function core_sync() {

    set_branch_name
    set_remote_name
    make_sure_current_branch_is_syncable
    if [ -z "${GIT_SYNC_ALLOW_NONOWNER}" ]; then
        make_sure_remote_owner_is_git_user
    fi

    log_debug "In mode '${mode}'"

    # TODO: improve this function
    # run_file_state_check
    exit_if_in_check_mode

    commit_on_local_changes

    fetch_remote
    sync_multiplexer

}

function main() {

    pre_checks || exit 1
    core_sync "$@"

}

# remember these are global
DEBUG=
branch_name=
grep_exe=$(which grep)
mode=sync
remote_name=
sync_branch_cli="false"
sync_new_files_cli="false"
sync_submodules="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
    -h | --help)
        print_usage
        exit 0
        ;;
    -n | --sync-new-files)
        sync_new_files_cli="true"
        ;;
    -s | --sync-branch)
        sync_branch_cli="true"
        ;;
    -r | --recursive)
        sync_submodules="true"
        ;;
    -d | --debug)
        DEBUG="true"
        ;;
    sync)
        mode="sync"
        ;;
    check)
        mode="check"
        ;;
    --*)
        log_err "Invalid option: $1"
        print_usage
        exit 1
        ;;
    -*)
        log_err "Invalid option: $1"
        print_usage
        exit 1
        ;;
    *)
        break
        ;;
    esac
    shift
done
shift $((OPTIND - 1))

main "$@" |& indent 4
