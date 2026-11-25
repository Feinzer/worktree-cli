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
        prune)
            _worktree_prune "$@"
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
  worktree prune [-n|--dry-run]
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
           remove the worktree you're currently in. Empty parent dirs left
           by a nested name (fix/ after fix/login) are pruned.
  prune    Remove worktrees whose directory was deleted outside wt (e.g. with
           `rm -rf`). Clears their git admin files and tidies up the empty
           parent dirs a nested name leaves behind. -n/--dry-run just lists
           what would be pruned.
  list     List the existing worktrees (runs `git worktree list`).
  shared   Manage files shared via .wt/shared/. `add` moves a path into
           .wt/shared/ and symlinks it back; `list` prints the shared paths;
           `remove` deletes a shared path from .wt/shared/ and cleans up its
           symlinks. `switch` re-creates the symlinks in every worktree
           it enters.
EOF
}

# ---------------------------------------------------------------------------
# Path-resolution helpers — the .wt/ layout is defined here, in one place.
# ---------------------------------------------------------------------------

# Repo root: the directory that contains the bare .git dir.
_worktree_root() {
    local common
    common="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1
    dirname "$common"
}

# .wt/ directory (sibling of .git, tool-owned).
_worktree_wt_dir() {
    local root
    root="$(_worktree_root)" || return 1
    printf '%s/.wt' "$root"
}

# .wt/shared/ — actual shared files/folders.
_worktree_shared_dir() {
    local root
    root="$(_worktree_root)" || return 1
    printf '%s/.wt/shared' "$root"
}

# .wt/manifest — list of shared relpaths (one per line).
_worktree_manifest() {
    local root
    root="$(_worktree_root)" || return 1
    printf '%s/.wt/manifest' "$root"
}

# .wt/config — optional key=value config (may be absent).
_worktree_config() {
    local root
    root="$(_worktree_root)" || return 1
    printf '%s/.wt/config' "$root"
}

# Read a config value: _worktree_config_get <section> <key> [default]
# Returns the value on stdout, or the default when absent/unparseable.
_worktree_config_get() {
    local section="$1" key="$2" default="${3:-}"
    local config
    config="$(_worktree_config 2>/dev/null)" || { printf '%s' "$default"; return 0; }
    [ -f "$config" ] || { printf '%s' "$default"; return 0; }

    local cur_section="" line k v
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in
            ''|'#'*) continue ;;
        esac
        case "$line" in
            '['*']')
                cur_section="${line#"["}"
                cur_section="${cur_section%"]"}"
                continue
                ;;
        esac
        case "$line" in
            *=*)
                k="${line%%=*}"
                v="${line#*=}"
                k="${k#"${k%%[![:space:]]*}"}"; k="${k%"${k##*[![:space:]]}"}"
                v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
                if [ "$cur_section" = "$section" ] && [ "$k" = "$key" ]; then
                    printf '%s' "$v"
                    return 0
                fi
                ;;
        esac
    done < "$config"
    printf '%s' "$default"
}

_worktree_clone() {
    local repo_url=""
    local main_branch=""

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

    mkdir -p "$repo_name" || return 1
    cd "$repo_name" || return 1

    git clone --bare "$repo_url" .git || return 1

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

    git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*" || return 1
    git fetch origin || return 1
    git worktree add "$main_branch" || return 1
    cd ..

    echo "Done. Worktree '$main_branch' is ready at ./$repo_name/$main_branch"
}

_worktree_switch() {
    local branch=""
    local base=""
    local have_base=false

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

    if [ "$have_base" = false ]; then
        base="$(git rev-parse HEAD 2>/dev/null)"
    fi

    local root
    root="$(git rev-parse --git-common-dir 2>/dev/null)" || {
        echo "worktree switch: not inside a worktree repo (no .git found)" >&2
        return 1
    }
    root="$(dirname "$root")"

    local target="$root/$branch"

    if [ ! -d "$target" ]; then
        if [ "$have_base" = true ]; then
            git -C "$root" worktree add -b "$branch" "$branch" "$base" || return 1
        elif git -C "$root" show-ref --verify --quiet "refs/heads/$branch" \
             || git -C "$root" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
            git -C "$root" worktree add "$branch" || return 1
        elif [ -n "$base" ]; then
            git -C "$root" worktree add -b "$branch" "$branch" "$base" || return 1
        else
            git -C "$root" worktree add "$branch" || return 1
        fi
    fi

    cd "$target" || return 1
    _worktree_link_common "$root" "$branch"
    echo "Switched to worktree '$branch' ($target)"
}

# Prune the empty parent dirs a nested worktree leaves behind.
# `fix/nested-branches` lives in `<root>/fix/`, so once it is gone `fix/` may be
# an empty leftover. Walk up from the worktree's parent toward <root>, rmdir'ing
# while empty; rmdir fails on the first non-empty dir, which stops the walk.
# <root> itself is never a candidate (the loop ends before it).
_worktree_prune_parents() {
    local root="$1" branch="$2"
    local dir="${branch%/}"

    case "$dir" in
        */*) dir="${dir%/*}" ;;
        *) return 0 ;;   # flat name — no parent dir of ours to prune
    esac

    while [ -n "$dir" ] && [ "$dir" != "." ] && [ "$dir" != "/" ]; do
        rmdir "$root/$dir" 2>/dev/null || return 0
        echo "Removed empty parent directory '$dir' ($root/$dir)"
        case "$dir" in
            */*) dir="${dir%/*}" ;;
            *) dir="" ;;
        esac
    done
}

_worktree_remove() {
    local branch=""
    local force=false

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
        target="$(git rev-parse --show-toplevel 2>/dev/null)" || {
            echo "worktree remove: no <branch-name> and not inside a worktree" >&2
            return 1
        }
        # Nested worktrees need the full <root>-relative name ('fix/x', not 'x').
        local root_abs
        root_abs="$(cd "$root" 2>/dev/null && pwd)" || root_abs="$root"
        case "$target" in
            "$root_abs"/*) branch="${target#"$root_abs"/}" ;;
            *) branch="$(basename "$target")" ;;
        esac
    fi

    if [ ! -d "$target" ]; then
        echo "worktree remove: no such worktree '$branch'" >&2
        return 1
    fi

    local was_inside=false
    case "$PWD/" in
        "$target"/*)
            cd "$root" || return 1
            was_inside=true
            ;;
    esac

    if [ "$force" = true ]; then
        git -C "$root" worktree remove --force "$branch"
    else
        git -C "$root" worktree remove "$branch"
    fi || {
        [ "$was_inside" = true ] && cd "$target" 2>/dev/null
        return 1
    }
    echo "Removed worktree '$branch' ($target)"
    _worktree_prune_parents "$root" "$branch"
}

# Strip the repo-root prefix from a worktree path, yielding its <root>-relative
# name. git reports paths in the bare repo's own convention, which can differ
# from a locally resolved path when symlinks are in play (e.g. a container
# bind-mount), so try that first, then the resolved root, then the basename.
_worktree_relname() {
    local path="$1" git_root="$2" root_abs="$3" root="$4"
    if [ -n "$git_root" ] && [ "${path#"$git_root"/}" != "$path" ]; then
        printf '%s' "${path#"$git_root"/}"
    elif [ -n "$root_abs" ] && [ "${path#"$root_abs"/}" != "$path" ]; then
        printf '%s' "${path#"$root_abs"/}"
    elif [ "${path#"$root"/}" != "$path" ]; then
        printf '%s' "${path#"$root"/}"
    else
        basename "$path"
    fi
}

# Prune worktrees whose directory was removed outside wt (e.g. `rm -rf`).
# git flags these as "prunable" in `worktree list --porcelain`; `git worktree
# prune` clears their admin files. We gather the prunable entries first (path +
# reason, one "<path>\t<reason>" per array slot) so we can report them and tidy
# up the empty parent dirs a nested name leaves behind, exactly like `remove`.
_worktree_prune() {
    local dry_run=false

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -n|--dry-run)
                dry_run=true
                shift
                ;;
            -h|--help)
                _worktree_usage
                return 0
                ;;
            -*)
                echo "worktree prune: unknown option '$1'" >&2
                return 1
                ;;
            *)
                echo "worktree prune: unexpected argument '$1'" >&2
                return 1
                ;;
        esac
    done

    local root
    root="$(git rev-parse --git-common-dir 2>/dev/null)" || {
        echo "worktree prune: not inside a worktree repo (no .git found)" >&2
        return 1
    }
    root="$(dirname "$root")"

    local root_abs
    root_abs="$(cd "$root" 2>/dev/null && pwd)" || root_abs="$root"

    # git records worktree paths in the bare repo's own path convention, which
    # the `bare` entry reports too. Capture it and strip that prefix, so paths
    # match even when our resolved root differs by a symlink.
    local prunable=()
    local git_root="" line cur=""
    while IFS= read -r line; do
        case "$line" in
            "worktree "*) cur="${line#worktree }" ;;
            bare)         git_root="$cur" ;;
            "prunable "*) prunable+=( "$cur"$'\t'"${line#prunable }" ) ;;
            "")           cur="" ;;
        esac
    done < <(git -C "$root" worktree list --porcelain 2>/dev/null)

    if [ "${#prunable[@]}" -eq 0 ]; then
        echo "worktree prune: nothing to prune"
        return 0
    fi

    local entry path reason name
    if [ "$dry_run" = true ]; then
        for entry in "${prunable[@]}"; do
            path="${entry%%$'\t'*}"
            reason="${entry#*$'\t'}"
            name="$(_worktree_relname "$path" "$git_root" "$root_abs" "$root")"
            echo "Would prune worktree '$name' ($reason)"
        done
        return 0
    fi

    git -C "$root" worktree prune || return 1

    for entry in "${prunable[@]}"; do
        path="${entry%%$'\t'*}"
        reason="${entry#*$'\t'}"
        name="$(_worktree_relname "$path" "$git_root" "$root_abs" "$root")"
        echo "Pruned worktree '$name' ($reason)"
        _worktree_prune_parents "$root" "$name"
    done
}

_worktree_list() {
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        _worktree_usage
        return 0
    fi

    local root
    root="$(git rev-parse --git-common-dir 2>/dev/null)" || {
        echo "worktree list: not inside a worktree repo (no .git found)" >&2
        return 1
    }
    root="$(dirname "$root")"

    git -C "$root" worktree list "$@" | grep -v '(bare)$'
}

_worktree_names() {
    local root line path
    root="$(git rev-parse --git-common-dir 2>/dev/null)" || return 0
    root="$(dirname "$root")"

    while IFS= read -r line; do
        case "$line" in
            "worktree "*)
                path="${line#worktree }"
                case "$path" in
                    "$root"/*) printf '%s\n' "${path#"$root"/}" ;;
                esac
                ;;
        esac
    done < <(git -C "$root" worktree list --porcelain 2>/dev/null)
}

_worktree_branches() {
    local root
    root="$(git rev-parse --git-common-dir 2>/dev/null)" || return 0
    root="$(dirname "$root")"
    git -C "$root" for-each-ref --format='%(refname:short)' \
        refs/heads refs/remotes/origin 2>/dev/null
}

# ---------------------------------------------------------------------------
# shared — keep selected files/folders in .wt/shared/ and symlink them into
# every worktree on `switch`.
# ---------------------------------------------------------------------------

_worktree_shared() {
    local sub="$1"
    shift 2>/dev/null

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

  add     Move <path> into the shared .wt/shared/ directory at the repo root
          and symlink it back into the worktree it came from. <path> may be
          prefixed with a worktree name (e.g. 'master/node_modules') or given
          relative to the worktree you're currently in (e.g. 'node_modules').
          Every subsequent `worktree switch` re-creates the symlinks in the
          worktree it enters.
  list    Print the repo-relative paths currently shared in .wt/shared/, one per
          line (the contents of .wt/manifest).
  remove  Delete the shared <relpath> from .wt/shared/ and remove every symlink
          pointing to it across all worktrees. Real files/folders at the path
          in any worktree are left untouched. Destructive: the .wt/shared copy
          is deleted, not moved back.
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
    printf '%s.wt/shared/%s' "$ups" "$relpath"
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

    local shared_dir="$root/.wt/shared"
    local manifest="$root/.wt/manifest"

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

    local dest="$shared_dir/$relpath"
    if [ -e "$dest" ] || [ -L "$dest" ]; then
        echo "worktree shared add: '$relpath' is already shared (.wt/shared/$relpath exists)" >&2
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

    echo "Shared '$relpath' (.wt/shared/$relpath); symlinked into '$wtname'."
}

_worktree_shared_names() {
    local manifest
    manifest="$(_worktree_manifest 2>/dev/null)" || return 0
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

    local manifest
    manifest="$(_worktree_manifest 2>/dev/null)" || {
        echo "worktree shared list: not inside a worktree repo (no .git found)" >&2
        return 1
    }

    if [ ! -f "$manifest" ]; then
        echo "worktree shared list: no shared items (no .wt/manifest manifest)" >&2
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

    local shared_dir="$root/.wt/shared"
    local manifest="$root/.wt/manifest"
    if [ ! -f "$manifest" ]; then
        echo "worktree shared remove: no shared items (no .wt/manifest manifest)" >&2
        return 1
    fi
    if ! grep -Fxq -- "$relpath" "$manifest" 2>/dev/null; then
        echo "worktree shared remove: '$relpath' is not in the shared manifest" >&2
        return 1
    fi

    local target="$shared_dir/$relpath"
    if [ -e "$target" ] || [ -L "$target" ]; then
        rm -rf "$target" || return 1
    fi

    local tmp
    tmp="$(mktemp)" || return 1
    grep -Fxv -- "$relpath" "$manifest" > "$tmp" 2>/dev/null
    if [ -s "$tmp" ]; then
        mv "$tmp" "$manifest" || { rm -f "$tmp"; return 1; }
    else
        rm -f "$tmp" "$manifest"
    fi

    local count=0 name link
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        link="$root/$name/$relpath"
        if [ -L "$link" ]; then
            rm -f "$link" || return 1
            count=$((count + 1))
        fi
    done < <(_worktree_names)

    echo "Removed shared '$relpath' (deleted from .wt/shared, $count symlink(s) cleaned up)."
}

_worktree_link_common() {
    local root="$1" branch="$2"
    local manifest="$root/.wt/manifest"
    [ -f "$manifest" ] || return 0

    local auto_link
    auto_link="$(_worktree_config_get shared auto_link true)"
    case "$auto_link" in
        false|0|no|off) return 0 ;;
    esac

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

_worktree_complete() {
    local cur prev cmd
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    cmd="${COMP_WORDS[1]}"

    if [ "$COMP_CWORD" -eq 1 ]; then
        COMPREPLY=( $(compgen -W "clone switch remove rm prune list ls shared help" -- "$cur") )
        return 0
    fi

    case "$cmd" in
        clone)
            if [ "$prev" = "-b" ] || [ "$prev" = "--branch" ]; then
                COMPREPLY=()
                return 0
            fi
            case "$cur" in
                -*) COMPREPLY=( $(compgen -W "-b --branch -h --help" -- "$cur") ) ;;
            esac
            ;;
        switch)
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
        prune)
            case "$cur" in
                -*) COMPREPLY=( $(compgen -W "-n --dry-run -h --help" -- "$cur") ) ;;
            esac
            ;;
        shared)
            if [ "$COMP_CWORD" -eq 2 ]; then
                COMPREPLY=( $(compgen -W "add list ls remove rm help" -- "$cur") )
                return 0
            fi
            if [ "$prev" = "add" ]; then
                compopt -o filenames
                COMPREPLY=( $(compgen -f -d -- "$cur") )
                return 0
            fi
            if [ "$prev" = "remove" ] || [ "$prev" = "rm" ]; then
                COMPREPLY=( $(compgen -W "$(_worktree_shared_names)" -- "$cur") )
                return 0
            fi
            ;;
    esac
    return 0
}

wt() {
    worktree "$@"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    worktree "$@"
else
    complete -F _worktree_complete worktree
    complete -F _worktree_complete wt
fi
