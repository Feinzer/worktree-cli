#!/usr/bin/env bash
#
# install.sh — install the bash implementation of `worktree` (alias `wt`).
#
# Copies src/worktree.sh to $HOME/.local/lib/worktree/worktree.sh, replacing
# any previous copy. With -s/--source it also appends the `source` line to
# ~/.bashrc; otherwise it just prints the line for you to add.
#
# Usage:
#   ./install.sh [--prefix <dir>] [-s|--source] [--dry-run] [-h|--help]
#
# Environment:
#   WORKTREE_PREFIX   same as --prefix (default: $HOME/.local/lib/worktree)

set -euo pipefail

readonly SHELL_NAME="bash"
readonly SOURCE_FILE="src/worktree.sh"
readonly RC_FILE="$HOME/.bashrc"
readonly RC_MARKER="# worktree (wt) — added by install.sh"

PREFIX="${WORKTREE_PREFIX:-$HOME/.local/lib/worktree}"
DRY_RUN=0
APPEND_SOURCE=0

_usage() {
    cat <<'EOF'
install.sh — install the bash implementation of `worktree` (alias `wt`).

Usage:
  ./install.sh [options]

Options:
  --prefix <dir>   Install directory (default: $HOME/.local/lib/worktree)
  -s, --source     Append the `source <prefix>/worktree.sh` line to ~/.bashrc
                   (skipped if it is already sourced there)
  --dry-run        Print what would happen without touching the filesystem
  -h, --help       Show this help

The installed file replaces any existing copy at <prefix>/worktree.sh.
Without -s/--source, the line to add to ~/.bashrc is printed instead.
EOF
}

_die() {
    printf 'install.sh: %s\n' "$1" >&2
    exit 1
}

_run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '  [dry-run] %s\n' "$*"
        return 0
    fi
    "$@"
}

# Append the marker + source line to the rc file, creating it if needed. A
# newline is added first when the file does not end in one, so the line can
# never be glued onto existing content.
_append_to_rc() {
    local line="$1"

    if [ "$DRY_RUN" -eq 1 ]; then
        printf '  [dry-run] append to %s:\n' "$RC_FILE"
        printf '  [dry-run]     %s\n' "$RC_MARKER" "$line"
        return 0
    fi

    {
        if [ -s "$RC_FILE" ]; then
            if [ -n "$(tail -c 1 "$RC_FILE")" ]; then
                printf '\n'
            fi
            printf '\n'
        fi
        printf '%s\n%s\n' "$RC_MARKER" "$line"
    } >>"$RC_FILE"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)
            [ $# -ge 2 ] || _die "--prefix requires a directory"
            PREFIX="$2"
            shift 2
            ;;
        --prefix=*)
            PREFIX="${1#--prefix=}"
            [ -n "$PREFIX" ] || _die "--prefix requires a directory"
            shift
            ;;
        -s|--source)
            APPEND_SOURCE=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            _usage
            exit 0
            ;;
        *)
            _die "unknown option: $1"
            ;;
    esac
done

# Resolve the repo root from this script's location so it can be run from
# anywhere (./install.sh, bash /path/to/install.sh, a symlink on PATH).
script_path="${BASH_SOURCE[0]}"
while [ -L "$script_path" ]; do
    link_target="$(readlink "$script_path")"
    case "$link_target" in
        /*) script_path="$link_target" ;;
        *)  script_path="$(dirname "$script_path")/$link_target" ;;
    esac
done
repo_root="$(cd "$(dirname "$script_path")" && pwd)"

src="$repo_root/$SOURCE_FILE"
dest="$PREFIX/worktree.sh"

[ -f "$src" ] || _die "cannot find $SOURCE_FILE (looked in $repo_root)"

if [ -e "$dest" ] && [ ! -f "$dest" ]; then
    _die "$dest exists and is not a regular file — refusing to replace it"
fi

if [ -f "$dest" ]; then
    printf 'Replacing existing install at %s\n' "$dest"
else
    printf 'Installing to %s\n' "$dest"
fi

_run install -d -m 755 "$PREFIX"
_run install -m 755 "$src" "$dest"

source_line="source \"$dest\""

printf '\nInstalled %s implementation.\n' "$SHELL_NAME"

if [ -f "$RC_FILE" ] && grep -qF "$dest" "$RC_FILE"; then
    printf 'Already sourced from %s — restart your shell to pick up the new version.\n' "$RC_FILE"
elif [ "$APPEND_SOURCE" -eq 1 ]; then
    _append_to_rc "$source_line"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '\nWould append the line above to %s.\n' "$RC_FILE"
    else
        printf '\nAdded to %s:\n\n' "$RC_FILE"
        printf '  %s\n\n' "$source_line"
        printf 'Reload with:  source %s\n' "$RC_FILE"
    fi
else
    printf '\nAdd this line to %s to load `worktree`, `wt` and tab-completion:\n\n' "$RC_FILE"
    printf '  %s\n\n' "$source_line"
    printf 'Then reload with:  source %s\n' "$RC_FILE"
    printf '(or re-run with -s/--source to append it automatically)\n'
fi
