# AGENTS.md

`worktree` (alias `wt`) is a shell function that manages a **bare-repo + worktrees** layout: `./<repo>/.git` is a bare clone and `./<repo>/<branch>` are per-branch worktrees. The repo ships three parallel implementations of the same logic — keep them in lockstep.

## Source files (the whole project)

- `src/worktree.sh` — **bash, the reference implementation.** Treat as source of truth.
- `src/worktree.zsh` — zsh port (`ZSH_EVAL_CONTEXT`, `compdef` / `_describe` / `_arguments`).
- `src/worktree.ps1` — PowerShell 5.1 & 7+ port (native functions, `Register-ArgumentCompleter`).
- `install.bash` — **installer for the bash implementation only.** Copies `src/worktree.sh` to `$HOME/.local/lib/worktree/worktree.sh`.

No other source, no build system, no tests, no linter, no manifest.

## The installer (`install.bash`)

- **Bash only, deliberately.** It installs `src/worktree.sh` and touches `~/.bashrc` and nothing else. zsh and PowerShell installers are **not written yet**; the README documents manual sourcing for those two. Do not teach `install.bash` about the other shells — when they get installers they get sibling scripts (`install.zsh`, `install.ps1`), which is why the file is named `.bash` rather than `.sh`.
- **Layout it owns:** installs to `$PREFIX/worktree.sh` where `PREFIX` defaults to `$HOME/.local/lib/worktree` (overridable by `--prefix` or `$WORKTREE_PREFIX`). Mode `755`, since `worktree.sh` also supports direct execution.
- **Flags:** `--prefix <dir>` (also `--prefix=<dir>`), `-s`/`--source`, `--dry-run`, `-h`/`--help`. Unknown flags are a hard error.
- **`-s`/`--source` appends to `~/.bashrc`**, preceded by the `RC_MARKER` comment. It is **idempotent via a `grep -qF` on the destination path** (not on the marker) — so renaming the marker is safe, but changing that check is not. Appending terminates an unterminated last line first, then adds one blank separator line, and creates the rc file if absent.
- **`--dry-run` must stay total:** every filesystem action goes through `_run` or the dry-run branch of `_append_to_rc`. A new side effect that bypasses those breaks the contract.
- **The repo root is resolved from `BASH_SOURCE` with a symlink-following loop**, not from `$PWD`, so the installer works from any cwd or via a symlink on `PATH`. Keep that if you move the file.
- **It refuses to replace a non-regular file** at the destination; a regular file is replaced silently (that's the upgrade path).
- Verify with `./install.bash --dry-run`, and end-to-end against a throwaway `HOME`/`--prefix` (`HOME=/tmp/x ./install.bash -s --prefix /tmp/x/lib`) — never against your real `~/.bashrc`.

## Critical conventions

- **Any behavior or flag change must be mirrored across all three files.** `worktree.sh` is canonical; port the change to `.zsh` and `.ps1`. Do not edit one without the others. (This rule is about `src/` — `install.bash` has no siblings to mirror yet.)
- **If you rename or move `src/worktree.sh`, update `install.bash`.** Its `SOURCE_FILE` constant hardcodes the repo-relative path, and the installed filename is what users have in their `~/.bashrc`.
- **Flag style is per-shell and idiomatic — do not "normalize" it.** bash/zsh use GNU long options (`--branch`, `--from`, `--force`); PowerShell uses native single-dash params (`-Branch`, `-From`, `-Force`, with `-b`/`-f` aliases). The positional commands (`clone` / `switch` / `remove` / `list`) and their semantics stay identical.
- **Each file detects sourced-vs-executed** and registers tab-completion only when sourced (`BASH_SOURCE` / `ZSH_EVAL_CONTEXT` / `$MyInvocation.InvocationName -eq '.'`). Preserve this when refactoring the tail of each file.
- **The `.wt/` layout.** All tool-owned data lives under `<repo>/.wt/` (sibling of the bare `.git`), outside every worktree so git never tracks it:
  - `.wt/config` — optional INI-style config (key = value). Absent ⇒ zero-config behavior.
  - `.wt/manifest` — list of shared repo-relative paths (one per line). Deleted when the last entry is removed.
  - `.wt/shared/` — the actual shared files/folders (moved here from a worktree, symlinked back).
  - `.wt/state/` — reserved for future runtime state (not created or used yet).
- **Path-resolution helpers define the layout in one place.** Each shell exposes helpers (`_worktree_root` / `_worktree_wt_dir` / `_worktree_shared_dir` / `_worktree_manifest` / `_worktree_config` in bash/zsh; `Resolve-WorktreeRoot` / `Get-WorktreeWtDir` / `Get-WorktreeSharedDir` / `Get-WorktreeManifest` / `Get-WorktreeConfig` in PowerShell). Use these instead of hardcoding `.wt/...` paths in new code.
- **`shared add <path>`** moves a file/folder from a worktree into `.wt/shared/` and symlinks it back; `switch` re-creates the symlinks in every worktree it enters. **`shared list`** (alias `ls`) prints the manifest. **`shared remove <relpath>`** (alias `rm`) **destructively** deletes the `.wt/shared/` copy and removes symlinks across all worktrees (real files are left untouched). The manifest is `.wt/manifest` (one repo-relative path per line); it is deleted when the last entry is removed. Symlinks are **relative** (`../.wt/shared/<relpath>`), so the repo dir stays portable. On `switch`, a real file/folder at a shared path is **skipped with a warning**, never clobbered.
- **Config parsing.** `_worktree_config_get <section> <key> [default]` (bash/zsh) / `Get-WorktreeConfigValue` (PowerShell) reads `.wt/config` (INI-style, tolerant of whitespace/comments/CRLF). Returns the value or the default when the file/section/key is absent. Only `shared.auto_link` is currently wired in (gates `_worktree_link_common` on `switch`); other keys are reserved.

## Verifying changes

There is no test suite. Verify manually by sourcing the affected file in its shell and exercising the commands against a throwaway clone:

```bash
source src/worktree.sh
worktree clone <repo-url> -b main
worktree switch feature/x
worktree list
worktree remove feature/x
```

Repeat the equivalent in zsh (`source src/worktree.zsh`) and PowerShell (`. .\src\worktree.ps1`) whenever you touch those files. `switch` / `remove` change the working directory, so run them from a scratch repo.

## Non-obvious behavior to preserve

- `clone` sets `remote.origin.fetch` to `+refs/heads/*:refs/remotes/origin/*` (non-default — makes all remote branches visible) before fetching and adding the first worktree.
- `switch <branch>` resolves the current HEAD to a concrete commit *before* chdir to the repo root, then: DWIMs an existing local/origin branch, else creates a new branch off that HEAD (or off `--from`/`-From <base>` if given).
- `remove` with no name targets the worktree you're in and steps out to the repo root first so the shell isn't left in a deleted path. It resolves the worktree name **relative to the repo root** (`fix/login`, not `login`) so nested worktrees work.
- `remove` prunes empty parent directories after a successful `git worktree remove` (`_worktree_prune_parents` / `Remove-WorktreeEmptyParents`). A nested name like `fix/login` leaves `<root>/fix/` behind; the helper walks up from the worktree's parent toward `<root>`, deleting each directory that is empty and stopping at the first that isn't (in bash/zsh that's just `rmdir` failing). Deep names (`a/b/c/x`) collapse all the way up. The repo root is never a candidate, and only empty dirs are ever deleted — a sibling worktree or a stray file preserves the parent.
- `list` filters out the bare-repo entry.
- `shared add` resolves the path by matching the longest worktree-name prefix first (so `feature/shared-files` wins over `feature`), then falls back to the current worktree's toplevel. Absolute paths are rejected. The source must not already be a symlink, and the relpath must not already be in `.wt/shared/` or the manifest.
- `shared remove` validates the relpath against the manifest, `rm -rf`s the `.wt/shared/<relpath>` copy, rewrites the manifest (deleting it if empty), then walks every worktree removing symlinks at that relpath. Real files/folders are never clobbered. The deletion is destructive — no move-back.
- `switch` calls `_worktree_link_common` / `Invoke-WorktreeLinkCommon` after `cd`/`Set-Location`; it is idempotent (existing symlinks are left alone) and silent when no `.wt/manifest` exists. It is gated by `shared.auto_link` from `.wt/config` (default `true`); when `false`/`0`/`no`/`off`, it is a no-op.

License: GPL-3.0 (`LICENSE`).
