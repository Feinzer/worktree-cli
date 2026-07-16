# AGENTS.md

`worktree` (alias `wt`) is a shell function that manages a **bare-repo + worktrees** layout: `./<repo>/.git` is a bare clone and `./<repo>/<branch>` are per-branch worktrees. The repo ships three parallel implementations of the same logic — keep them in lockstep.

## Source files (the whole project)

- `src/worktree.sh` — **bash, the reference implementation.** Treat as source of truth.
- `src/worktree.zsh` — zsh port (`ZSH_EVAL_CONTEXT`, `compdef` / `_describe` / `_arguments`).
- `src/worktree.ps1` — PowerShell 5.1 & 7+ port (native functions, `Register-ArgumentCompleter`).

No other source, no build system, no tests, no linter, no manifest.

## Critical conventions

- **Any behavior or flag change must be mirrored across all three files.** `worktree.sh` is canonical; port the change to `.zsh` and `.ps1`. Do not edit one without the others.
- **Flag style is per-shell and idiomatic — do not "normalize" it.** bash/zsh use GNU long options (`--branch`, `--from`, `--force`); PowerShell uses native single-dash params (`-Branch`, `-From`, `-Force`, with `-b`/`-f` aliases). The positional commands (`clone` / `switch` / `remove` / `list`) and their semantics stay identical.
- **Each file detects sourced-vs-executed** and registers tab-completion only when sourced (`BASH_SOURCE` / `ZSH_EVAL_CONTEXT` / `$MyInvocation.InvocationName -eq '.'`). Preserve this when refactoring the tail of each file.

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
- `remove` with no name targets the worktree you're in and steps out to the repo root first so the shell isn't left in a deleted path.
- `list` filters out the bare-repo entry.

License: GPL-3.0 (`LICENSE`).
