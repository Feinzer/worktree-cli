#!/usr/bin/env zsh
#
# worktree — helpers for a bare-repo + worktrees layout (zsh port).
#
# This is the zsh-native counterpart to worktree.sh. The command logic is
# identical; only the "sourced vs. executed" detection and the tab-completion
# are written the zsh way (ZSH_EVAL_CONTEXT + compdef instead of BASH_SOURCE +
# complete/compgen).
#
# Usage:
#   worktree clone <repo-url> [-b <main-branch>]
#
# Source this file (e.g. from ~/.zshrc) so `worktree` is available as a
# shell function:
#
#   source /path/to/worktree.zsh
#
# Or run it directly:
#
#   ./worktree.zsh clone <repo-url> -b main

worktree() {
    local cmd="$1"
    [ "$#" -gt 0 ] && shift

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
        shared)
            _worktree_shared "$@"
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
  worktree shared add <path>
  worktree shared list                          (alias: ls)
  worktree shared remove <relpath>              (alias: rm)

  clone    Clone <repo-url> as a bare repo into ./.git and check out
           <main-branch> (default: the repository's default branch) as the first worktree.
  switch   cd into the <branch-name> worktree, creating it with
           `git worktree add` first if it doesn't exist yet. A brand-new
           branch is based on the current worktree's HEAD; use --from <base>
           to base it on another branch/commit instead.
  remove   Remove the <branch-name> worktree. With no name, cd out of and
           remove the worktree you're currently in.
  list     List the existing worktrees (runs `git worktree list`).
  shared   Manage files shared via .common/. `add` moves a path into
           .common/ and symlinks it back; `list` prints the shared paths;
           `remove` deletes a shared path from .common/ and cleans up its
           symlinks. `switch` re-creates the symlinks in every worktree
           it enters.
EOF
}

_worktree_clone() {
    local repo_url=""
    local main_branch=""

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

    # 1b. If no branch was given, ask the remote which branch its HEAD points
    #     to (the same mechanism `git clone` uses internally).
    if [ -z "$main_branch" ]; then
        local symref first_line rest target
        symref="$(git ls-remote --symref origin HEAD 2>/dev/null)"
        first_line="${symref%%$'\n'*}"
        case "$first_line" in
            "ref: "*)
                rest="${first_line#ref: }"
                target="${rest%%$'\t'*}"
                case "$target" in
                    refs/heads/*) main_branch="${target#refs/heads/}" ;;
                esac
                ;;
        esac
        if [ -z "$main_branch" ]; then
            echo "worktree clone: could not determine the repository's default branch; pass -b <branch>" >&2
            return 1
        fi
    fi

    # 2. Fix the fetch refspec so all remote branches are visible.
    git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*" || return 1

    # Populate the remote-tracking refs we just enabled.
    git fetch origin || return 1

    # 3. Create the first worktree for the main branch.
    git worktree add "$main_branch" || return 1

    # 4. Get the user back out of the repo
    cd ..

    echo "Done. Worktree '$main_branch' is ready at ./$repo_name/$main_branch"
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

    cd "$target" || return 1
    _worktree_link_common "$root" "$branch"
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

# ---------------------------------------------------------------------------
# shared — keep selected files/folders in .common/ and symlink them into every
# worktree on `switch`.
# ---------------------------------------------------------------------------

_worktree_shared() {
    local sub="$1"
    [ "$#" -gt 0 ] && shift

    case "$sub" in
        add)
            _worktree_shared_add "$@"
            ;;
        list|ls)
            _worktree_shared_list "$@"
            ;;
        remove|rm)
            _worktree_shared_remove "$@"
            ;;
        ""|-h|--help|help)
            _worktree_shared_usage
            ;;
        *)
            echo "worktree shared: unknown subcommand '$sub'" >&2
            _worktree_shared_usage >&2
            return 1
            ;;
    esac
}

_worktree_shared_usage() {
    cat <<'EOF'
Usage:
  worktree shared add <path>
  worktree shared list                          (alias: ls)
  worktree shared remove <relpath>              (alias: rm)

  add     Move <path> into the shared .common/ directory at the repo root and
          symlink it back into the worktree it came from. <path> may be
          prefixed with a worktree name (e.g. 'master/node_modules') or given
          relative to the worktree you're currently in (e.g. 'node_modules').
          Every subsequent `worktree switch` re-creates the symlinks in the
          worktree it enters.
  list    Print the repo-relative paths currently shared in .common/, one per
          line (the contents of .common/.wt-shared).
  remove  Delete the shared <relpath> from .common/ and remove every symlink
          pointing to it across all worktrees. Real files/folders at the path
          in any worktree are left untouched. Destructive: the .common copy is
          deleted, not moved back.
EOF
}

_worktree_common_target() {
    local wtname="$1" relpath="$2"
    local linkdir="$wtname"
    local sub
    sub="$(dirname "$relpath")"
    [ "$sub" != "." ] && linkdir="$linkdir/$sub"
    local slashes="${linkdir//[!\/]/}"
    local depth=$(( ${#slashes} + 1 ))
    local ups=""
    local i
    for ((i = 0; i < depth; i++)); do ups+="../"; done
    printf '%s.common/%s' "$ups" "$relpath"
}

_worktree_shared_add() {
    local target="$1"

    if [ -z "$target" ]; then
        echo "worktree shared add: missing <path>" >&2
        return 1
    fi
    if [ "${target#/}" != "$target" ]; then
        echo "worktree shared add: absolute paths are not supported; use a path relative to the repo root (e.g. 'master/node_modules')" >&2
        return 1
    fi
    target="${target#./}"
    target="${target%/}"

    local root
    root="$(git rev-parse --git-common-dir 2>/dev/null)" || {
        echo "worktree shared add: not inside a worktree repo (no .git found)" >&2
        return 1
    }
    root="$(dirname "$root")"

    local common="$root/.common"
    local manifest="$common/.wt-shared"

    local wtname="" relpath=""
    local sorted
    sorted="$(printf '%s\n' "$(_worktree_names)" | awk '{print length"\t"$0}' | sort -rn | cut -f2-)"
    local name
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        case "$target" in
            "$name"/*)
                wtname="$name"
                relpath="${target#"$name"/}"
                break
                ;;
        esac
    done <<< "$sorted"

    if [ -z "$wtname" ]; then
        local toplevel
        toplevel="$(git rev-parse --show-toplevel 2>/dev/null)" || {
            echo "worktree shared add: '$target' is not inside a worktree" >&2
            return 1
        }
        wtname="${toplevel#"$root"/}"
        relpath="$target"
    fi

    local source="$root/$wtname/$relpath"
    if [ ! -e "$source" ]; then
        echo "worktree shared add: no such file or directory '$source'" >&2
        return 1
    fi
    if [ -L "$source" ]; then
        echo "worktree shared add: '$source' is already a symlink" >&2
        return 1
    fi

    local dest="$common/$relpath"
    if [ -e "$dest" ] || [ -L "$dest" ]; then
        echo "worktree shared add: '$relpath' is already shared (.common/$relpath exists)" >&2
        return 1
    fi
    if [ -f "$manifest" ] && grep -Fxq -- "$relpath" "$manifest" 2>/dev/null; then
        echo "worktree shared add: '$relpath' is already in the shared manifest" >&2
        return 1
    fi

    mkdir -p "$(dirname "$dest")" || return 1
    mv "$source" "$dest" || return 1

    mkdir -p "$(dirname "$source")" || return 1
    printf '%s\n' "$relpath" >> "$manifest" || return 1
    ln -s "$(_worktree_common_target "$wtname" "$relpath")" "$source" || return 1

    echo "Shared '$relpath' (.common/$relpath); symlinked into '$wtname'."
}

# List the repo-relative paths currently shared in .common/.wt-shared, one per
# line. Used by `shared list` and by completion for `shared remove`. Silent
# when no manifest exists.
_worktree_shared_names() {
    local root
    root="$(git rev-parse --git-common-dir 2>/dev/null)" || return 0
    root="$(dirname "$root")"
    local manifest="$root/.common/.wt-shared"
    [ -f "$manifest" ] || return 0
    local line
    while IFS= read -r line; do
        [ -n "$line" ] && printf '%s\n' "$line"
    done < "$manifest"
}

_worktree_shared_list() {
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        _worktree_shared_usage
        return 0
    fi

    local root
    root="$(git rev-parse --git-common-dir 2>/dev/null)" || {
        echo "worktree shared list: not inside a worktree repo (no .git found)" >&2
        return 1
    }
    root="$(dirname "$root")"

    local manifest="$root/.common/.wt-shared"
    if [ ! -f "$manifest" ]; then
        echo "worktree shared list: no shared items (no .common/.wt-shared manifest)" >&2
        return 0
    fi

    local count=0 line
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        printf '%s\n' "$line"
        count=$((count + 1))
    done < "$manifest"

    if [ "$count" -eq 0 ]; then
        echo "worktree shared list: manifest is empty" >&2
    fi
}

_worktree_shared_remove() {
    local relpath="$1"

    if [ -z "$relpath" ]; then
        echo "worktree shared remove: missing <relpath>" >&2
        return 1
    fi
    if [ "${relpath#/}" != "$relpath" ]; then
        echo "worktree shared remove: absolute paths are not supported; use a repo-relative path (e.g. 'node_modules')" >&2
        return 1
    fi
    relpath="${relpath#./}"
    relpath="${relpath%/}"

    local root
    root="$(git rev-parse --git-common-dir 2>/dev/null)" || {
        echo "worktree shared remove: not inside a worktree repo (no .git found)" >&2
        return 1
    }
    root="$(dirname "$root")"

    local common="$root/.common"
    local manifest="$common/.wt-shared"
    if [ ! -f "$manifest" ]; then
        echo "worktree shared remove: no shared items (no .common/.wt-shared manifest)" >&2
        return 1
    fi
    if ! grep -Fxq -- "$relpath" "$manifest" 2>/dev/null; then
        echo "worktree shared remove: '$relpath' is not in the shared manifest" >&2
        return 1
    fi

    # 1. Delete the real file/folder from .common/.
    local target="$common/$relpath"
    if [ -e "$target" ] || [ -L "$target" ]; then
        rm -rf "$target" || return 1
    fi

    # 2. Rewrite the manifest without the removed relpath; delete the manifest
    #    if it's now empty (so `list` reports "no shared items" next time).
    local tmp
    tmp="$(mktemp)" || return 1
    grep -Fxv -- "$relpath" "$manifest" > "$tmp" 2>/dev/null
    if [ -s "$tmp" ]; then
        mv "$tmp" "$manifest" || { rm -f "$tmp"; return 1; }
    else
        rm -f "$tmp" "$manifest"
    fi

    # 3. Walk every worktree and remove symlinks at the shared path. Real
    #    files/folders are left untouched (never clobbered).
    local count=0 name link
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        link="$root/$name/$relpath"
        if [ -L "$link" ]; then
            rm -f "$link" || return 1
            count=$((count + 1))
        fi
    done < <(_worktree_names)

    echo "Removed shared '$relpath' (deleted from .common, $count symlink(s) cleaned up)."
}

_worktree_link_common() {
    local root="$1" branch="$2"
    local manifest="$root/.common/.wt-shared"
    [ -f "$manifest" ] || return 0

    local relpath link target
    local count=0 skipped=0
    while IFS= read -r relpath; do
        [ -z "$relpath" ] && continue
        link="$root/$branch/$relpath"
        if [ -L "$link" ]; then
            continue
        fi
        if [ -e "$link" ]; then
            echo "worktree switch: skipping shared '$relpath' (real file/folder exists in '$branch')" >&2
            skipped=$((skipped + 1))
            continue
        fi
        mkdir -p "$(dirname "$link")" || return 1
        target="$(_worktree_common_target "$branch" "$relpath")"
        ln -s "$target" "$link" || return 1
        count=$((count + 1))
    done < "$manifest"

    if [ "$count" -gt 0 ] || [ "$skipped" -gt 0 ]; then
        echo "Linked $count shared item(s) into '$branch'${skipped:+, skipped $skipped}."
    fi
}

# Programmable completion for the `worktree` shell function (zsh style).
_worktree_complete() {
    local -a subcmds names
    local cmd

    # First word after `worktree`: complete the subcommand.
    if (( CURRENT == 2 )); then
        subcmds=(
            'clone:Clone a repo as a bare repo + first worktree'
            'switch:cd into a worktree, creating it if needed'
            'remove:Remove a worktree'
            'rm:Alias for remove'
            'list:List the existing worktrees'
            'ls:Alias for list'
            'shared:Manage shared (.common) files'
            'help:Show usage'
        )
        _describe -t commands 'worktree command' subcmds
        return 0
    fi

    cmd="${words[2]}"
    case "$cmd" in
        clone)
            # -b/--branch takes a free-form branch name we can't predict.
            if [ "${words[CURRENT-1]}" = "-b" ] || [ "${words[CURRENT-1]}" = "--branch" ]; then
                return 0
            fi
            _arguments \
                '(-b --branch)'{-b,--branch}'[main branch to check out]:branch name:' \
                '(-h --help)'{-h,--help}'[show usage]'
            ;;
        switch)
            # After --from, complete with branch/ref names for the base.
            if [ "${words[CURRENT-1]}" = "--from" ]; then
                local branches
                branches=(${(f)"$(_worktree_branches)"})
                _describe -t branches 'base ref' branches
                return 0
            fi
            if [[ "${words[CURRENT]}" == -* ]]; then
                _arguments \
                    '--from[base branch/commit for a new branch]:base ref:' \
                    '(-h --help)'{-h,--help}'[show usage]'
            else
                names=(${(f)"$(_worktree_names)"})
                _describe -t worktrees 'worktree' names
            fi
            ;;
        remove|rm)
            if [[ "${words[CURRENT]}" == -* ]]; then
                _arguments \
                    '(-f --force)'{-f,--force}'[force removal]' \
                    '(-h --help)'{-h,--help}'[show usage]'
            else
                names=(${(f)"$(_worktree_names)"})
                _describe -t worktrees 'worktree' names
            fi
            ;;
        shared)
            if (( CURRENT == 3 )); then
                local -a sharedsubs
                sharedsubs=(
                    'add:Move a path into .common and symlink it back'
                    'list:List shared paths (alias: ls)'
                    'ls:Alias for list'
                    'remove:Delete a shared path and its symlinks (alias: rm)'
                    'rm:Alias for remove'
                    'help:Show usage'
                )
                _describe -t sharedsubs 'shared subcommand' sharedsubs
                return 0
            fi
            if (( CURRENT >= 4 )); then
                local prev="${words[CURRENT-1]}"
                if [ "$prev" = "add" ]; then
                    _files
                elif [ "$prev" = "remove" ] || [ "$prev" = "rm" ]; then
                    local -a sharednames
                    sharednames=(${(f)"$(_worktree_shared_names)"})
                    _describe -t sharednames 'shared path' sharednames
                fi
                return 0
            fi
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
# interactive shells. In zsh, ZSH_EVAL_CONTEXT ends in ":file" while a file is
# being sourced and is just "toplevel" for a script run as `zsh worktree.zsh`.
if [[ "$ZSH_EVAL_CONTEXT" == *:file* ]]; then
    # Make sure the completion system is initialised before registering.
    if ! whence compdef >/dev/null 2>&1; then
        autoload -Uz compinit && compinit
    fi
    compdef _worktree_complete worktree wt
else
    worktree "$@"
fi
