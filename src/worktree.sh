#!/usr/bin/env bash
#
# worktree — helpers for a bare-repo + worktrees layout.
#
# Usage:
#   worktree clone <repo-url> [-b <main-branch>]
#
# Source this file (e.g. from ~/.bashrc) so `worktree` is available as a
# shell function:
#
#   source /path/to/worktree.sh
#
# Or run it directly:
#
#   ./worktree.sh clone <repo-url> -b main

worktree() {
    local cmd="$1"
    shift 2>/dev/null

    case "$cmd" in
        clone)
            _worktree_clone "$@"
            ;;
        switch)
            _worktree_switch "$@"
            ;;
        remove|rm)
            _worktree_remove "$@"
            ;;
        list|ls)
            _worktree_list "$@"
            ;;
        ""|-h|--help|help)
            _worktree_usage
            ;;
        *)
            echo "worktree: unknown command '$cmd'" >&2
            _worktree_usage >&2
            return 1
            ;;
    esac
}

_worktree_usage() {
    cat <<'EOF'
Usage:
  worktree clone <repo-url> [-b <main-branch>]
  worktree switch <branch-name> [--from <base>]
  worktree remove [<branch-name>] [-f|--force]   (alias: rm)
  worktree list                                  (alias: ls)

  clone    Clone <repo-url> as a bare repo into ./.git and check out
           <main-branch> (default: main) as the first worktree.
  switch   cd into the <branch-name> worktree, creating it with
           `git worktree add` first if it doesn't exist yet. A brand-new
           branch is based on the current worktree's HEAD; use --from <base>
           to base it on another branch/commit instead.
  remove   Remove the <branch-name> worktree. With no name, cd out of and
           remove the worktree you're currently in.
  list     List the existing worktrees (runs `git worktree list`).
EOF
}

_worktree_clone() {
    local repo_url=""
    local main_branch="main"

    # Parse arguments: a positional repo URL plus an optional -b/--branch flag.
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -b|--branch)
                if [ -z "$2" ]; then
                    echo "worktree clone: -b requires a branch name" >&2
                    return 1
                fi
                main_branch="$2"
                shift 2
                ;;
            -h|--help)
                _worktree_usage
                return 0
                ;;
            -*)
                echo "worktree clone: unknown option '$1'" >&2
                return 1
                ;;
            *)
                if [ -n "$repo_url" ]; then
                    echo "worktree clone: unexpected argument '$1'" >&2
                    return 1
                fi
                repo_url="$1"
                shift
                ;;
        esac
    done

    if [ -z "$repo_url" ]; then
        echo "worktree clone: missing <repo-url>" >&2
        _worktree_usage >&2
        return 1
    fi

    # Derive the repo name from the URL (strip trailing slash and .git suffix).
    local repo_name
    repo_name="${repo_url%/}"
    repo_name="${repo_name##*/}"
    repo_name="${repo_name%.git}"

    if [ -z "$repo_name" ]; then
        echo "worktree clone: could not determine repo name from '$repo_url'" >&2
        return 1
    fi

    if [ -e "$repo_name" ]; then
        echo "worktree clone: '$repo_name' already exists here; refusing to overwrite" >&2
        return 1
    fi

    # Create the repo directory and work inside it.
    mkdir -p "$repo_name" || return 1
    cd "$repo_name" || return 1

    # 1. Clone the repo into a hidden .git folder (bare).
    git clone --bare "$repo_url" .git || return 1

    # 3. Fix the fetch refspec so all remote branches are visible.
    git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*" || return 1

    # Populate the remote-tracking refs we just enabled.
    git fetch origin || return 1

    # 4. Create the first worktree for the main branch.
    git worktree add "$main_branch" || return 1

    # 5. Get the user back out of the repo
    cd ..

    echo "Done. Worktree '$main_branch' is ready at ./$repo_name/$main_branch"
}

# Symlink every entry from the repo-level shared dir into a new worktree.
# Drop any file or folder into <root>/.shared (which lives next to the bare
# .git) and it shows up — as a symlink — in every worktree. This keeps
# gitignored config such as .env.local as a single source of truth shared
# across all branches. Works for both files and directories, and never
# clobbers something the worktree already has.
_worktree_link_shared() {
    local root="$1" target="$2"
    local abs_root shared
    abs_root="$(cd "$root" 2>/dev/null && pwd)" || return 0
    shared="$abs_root/.shared"
    [ -d "$shared" ] || return 0

    # Subshell so nullglob/dotglob don't leak into the user's shell. dotglob
    # includes dotfiles; nullglob makes the loop empty when .shared has none.
    (
        shopt -s nullglob dotglob
        local item name
        for item in "$shared"/*; do
            name="$(basename "$item")"
            [ -e "$target/$name" ] && continue
            ln -s "$item" "$target/$name"
        done
    )
}

_worktree_switch() {
    local branch=""
    local base=""
    local have_base=false

    # Parse arguments: a positional branch name plus an optional --from <base>.
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --from)
                if [ -z "$2" ]; then
                    echo "worktree switch: --from requires a <base> ref" >&2
                    return 1
                fi
                base="$2"
                have_base=true
                shift 2
                ;;
            -h|--help)
                _worktree_usage
                return 0
                ;;
            -*)
                echo "worktree switch: unknown option '$1'" >&2
                return 1
                ;;
            *)
                if [ -n "$branch" ]; then
                    echo "worktree switch: unexpected argument '$1'" >&2
                    return 1
                fi
                branch="$1"
                shift
                ;;
        esac
    done

    if [ -z "$branch" ]; then
        echo "worktree switch: missing <branch-name>" >&2
        return 1
    fi

    # Default base for a brand-new branch: the HEAD of the worktree we're
    # currently standing in. Resolve it to a concrete commit *before* we chdir
    # to the repo root, otherwise HEAD would mean the bare repo's default branch
    # rather than where the user is.
    if [ "$have_base" = false ]; then
        base="$(git rev-parse HEAD 2>/dev/null)"
    fi

    # Resolve the repo root: the directory that contains the bare .git dir.
    local root
    root="$(git rev-parse --git-common-dir 2>/dev/null)" || {
        echo "worktree switch: not inside a worktree repo (no .git found)" >&2
        return 1
    }
    root="$(dirname "$root")"

    local target="$root/$branch"

    # Create the worktree only if the folder isn't there yet.
    if [ ! -d "$target" ]; then
        if [ "$have_base" = true ]; then
            # Explicit --from: always create a new branch off the given base.
            git -C "$root" worktree add -b "$branch" "$branch" "$base" || return 1
        elif git -C "$root" show-ref --verify --quiet "refs/heads/$branch" \
             || git -C "$root" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
            # Branch already exists locally or on origin: let git DWIM (check it
            # out / create a tracking branch). The base doesn't apply here.
            git -C "$root" worktree add "$branch" || return 1
        elif [ -n "$base" ]; then
            # Brand-new branch, based on the current worktree's HEAD.
            git -C "$root" worktree add -b "$branch" "$branch" "$base" || return 1
        else
            # No current HEAD to base on: fall back to git's default.
            git -C "$root" worktree add "$branch" || return 1
        fi
    fi

    # Link shared config (.env.local, etc.) into the worktree. Runs every
    # switch so worktrees created before this feature get backfilled too;
    # it's idempotent and skips anything already present.
    _worktree_link_shared "$root" "$target"

    cd "$target" || return 1
    echo "Switched to worktree '$branch' ($target)"
}

_worktree_remove() {
    local branch=""
    local force=false

    # Parse arguments: an optional branch name plus an optional -f/--force flag.
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -f|--force)
                force=true
                shift
                ;;
            -h|--help)
                _worktree_usage
                return 0
                ;;
            -*)
                echo "worktree remove: unknown option '$1'" >&2
                return 1
                ;;
            *)
                if [ -n "$branch" ]; then
                    echo "worktree remove: unexpected argument '$1'" >&2
                    return 1
                fi
                branch="$1"
                shift
                ;;
        esac
    done

    # Resolve the repo root: the directory that contains the bare .git dir.
    local root
    root="$(git rev-parse --git-common-dir 2>/dev/null)" || {
        echo "worktree remove: not inside a worktree repo (no .git found)" >&2
        return 1
    }
    root="$(dirname "$root")"

    local target
    if [ -n "$branch" ]; then
        target="$root/$branch"
    else
        # No branch given: target the worktree we're currently sitting in.
        target="$(git rev-parse --show-toplevel 2>/dev/null)" || {
            echo "worktree remove: no <branch-name> and not inside a worktree" >&2
            return 1
        }
        branch="$(basename "$target")"
    fi

    if [ ! -d "$target" ]; then
        echo "worktree remove: no such worktree '$branch'" >&2
        return 1
    fi

    # If the current directory is inside the worktree being removed, step out
    # to the repo root first so we don't strand the shell in a deleted path.
    case "$PWD/" in
        "$target"/*)
            cd "$root" || return 1
            ;;
    esac

    if [ "$force" = true ]; then
        git -C "$root" worktree remove --force "$branch" || return 1
    else
        git -C "$root" worktree remove "$branch" || return 1
    fi
    echo "Removed worktree '$branch' ($target)"
}

_worktree_list() {
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        _worktree_usage
        return 0
    fi

    # Resolve the repo root: the directory that contains the bare .git dir.
    local root
    root="$(git rev-parse --git-common-dir 2>/dev/null)" || {
        echo "worktree list: not inside a worktree repo (no .git found)" >&2
        return 1
    }
    root="$(dirname "$root")"

    # Drop the bare repo entry; only real worktrees are useful here.
    git -C "$root" worktree list "$@" | grep -v '(bare)$'
}

# List the branch names of existing worktrees, one per line. Used by the
# completion function to suggest arguments for `switch` and `remove`.
_worktree_names() {
    local root line path
    root="$(git rev-parse --git-common-dir 2>/dev/null)" || return 0
    root="$(dirname "$root")"

    while IFS= read -r line; do
        case "$line" in
            "worktree "*)
                path="${line#worktree }"
                # Only report worktrees living under the repo root, and print
                # them relative to it so nested names (e.g. feature/foo) survive.
                case "$path" in
                    "$root"/*) printf '%s\n' "${path#"$root"/}" ;;
                esac
                ;;
        esac
    done < <(git -C "$root" worktree list --porcelain 2>/dev/null)
}

# List local and origin branch names, for completing `switch --from <base>`.
_worktree_branches() {
    local root
    root="$(git rev-parse --git-common-dir 2>/dev/null)" || return 0
    root="$(dirname "$root")"
    git -C "$root" for-each-ref --format='%(refname:short)' \
        refs/heads refs/remotes/origin 2>/dev/null
}

# Programmable completion for the `worktree` shell function.
_worktree_complete() {
    local cur prev cmd
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    cmd="${COMP_WORDS[1]}"

    # First word after `worktree`: complete the subcommand.
    if [ "$COMP_CWORD" -eq 1 ]; then
        COMPREPLY=( $(compgen -W "clone switch remove rm list ls help" -- "$cur") )
        return 0
    fi

    case "$cmd" in
        clone)
            # -b/--branch takes a free-form branch name we can't predict.
            if [ "$prev" = "-b" ] || [ "$prev" = "--branch" ]; then
                COMPREPLY=()
                return 0
            fi
            case "$cur" in
                -*) COMPREPLY=( $(compgen -W "-b --branch -h --help" -- "$cur") ) ;;
            esac
            ;;
        switch)
            # After --from, complete with branch/ref names for the base.
            if [ "$prev" = "--from" ]; then
                COMPREPLY=( $(compgen -W "$(_worktree_branches)" -- "$cur") )
                return 0
            fi
            case "$cur" in
                -*) COMPREPLY=( $(compgen -W "--from -h --help" -- "$cur") ) ;;
                *)  COMPREPLY=( $(compgen -W "$(_worktree_names)" -- "$cur") ) ;;
            esac
            ;;
        remove|rm)
            case "$cur" in
                -*) COMPREPLY=( $(compgen -W "-f --force -h --help" -- "$cur") ) ;;
                *)  COMPREPLY=( $(compgen -W "$(_worktree_names)" -- "$cur") ) ;;
            esac
            ;;
    esac
    return 0
}

# Short alias: `wt` behaves exactly like `worktree`.
wt() {
    worktree "$@"
}

# If executed directly (not sourced), dispatch to the function. When sourced,
# register the completion so `worktree <TAB>` (and `wt <TAB>`) work in
# interactive shells.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    worktree "$@"
else
    complete -F _worktree_complete worktree
    complete -F _worktree_complete wt
fi

