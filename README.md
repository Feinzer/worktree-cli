# worktree

A shell helper (`worktree`, alias `wt`) that manages a **bare-repo + worktrees** git layout. Instead of a single checkout, each repo becomes a directory whose `.git` is a bare clone and whose subdirectories are per-branch worktrees:

```
my-project/
├── .git              # bare clone (the real repo)
├── .shared           # shared files, symlinked into every worktree
├── main              # worktree on main
├── feature/login     # worktree on feature/login
└── hotfix/bug-42     # worktree on hotfix/bug-42
```

Switching branches no longer thrashes your working tree — each branch lives in its own directory you can `cd` into.

## Requirements

- `git`
- One of: **bash**, **zsh**, or **PowerShell 5.1 / 7+** (pick the shell you use)

## Install

Clone this repository somewhere permanent, then source the file for your shell from your profile so `worktree`, `wt`, and tab-completion load in every session.

**bash** — add to `~/.bashrc`:
```bash
source /path/to/worktree/src/worktree.sh
```

**zsh** — add to `~/.zshrc`:
```zsh
source /path/to/worktree/src/worktree.zsh
```

**PowerShell** — add to your `$PROFILE`:
```powershell
. C:\path\to\worktree\src\worktree.ps1
```

On Windows you can also just use the bash version under Git Bash or WSL.

## Usage

The four commands work the same across all three shells; only the flag style differs (see table below).

```bash
worktree clone https://github.com/acme/widgets.git
worktree switch feature/login
worktree list
worktree remove feature/login
```

(The default branch is auto-detected from the remote so the `-b main` flag is only needed when you want to override it.)

`wt` is an alias that behaves exactly like `worktree`.

| Command | Description |
| --- | --- |
| `clone <repo-url> [-b <main-branch>]` | Clone `<repo-url>` as a bare repo into `./<repo>/.git` and check out `<main-branch>` (default: the repository's default branch, auto-detected from the remote) as the first worktree. |
| `switch <branch-name> [--from <base>]` | `cd` into the `<branch-name>` worktree, creating it with `git worktree add` if it doesn't exist yet. A brand-new branch is based on the current worktree's HEAD; use `--from <base>` to base it elsewhere. After entering, any shared `.common` items are symlinked in. |
| `remove [<branch-name>] [-f\|--force]` (alias: `rm`) | Remove the named worktree. With no name, remove the worktree you're currently in (stepping out to the repo root first so your shell isn't left in a deleted path). |
| `list` (alias: `ls`) | List the existing worktrees (the bare-repo entry is filtered out). |
| `shared add <path>` | Move `<path>` into the shared `.shared/` directory at the repo root and symlink it back into the worktree it came from. `<path>` may be prefixed with a worktree name (`master/node_modules`) or given relative to the worktree you're in (`node_modules`). Every later `switch` re-creates the symlinks in the worktree it enters. |
| `shared list` (alias: `ls`) | Print the repo-relative paths currently shared in `.shared/`, one per line (the contents of `.shared/.manifest`). |
| `shared remove <relpath>` (alias: `rm`) | Delete the shared `<relpath>` from `.shared/` and remove every symlink pointing to it across all worktrees. Real files/folders at the path in any worktree are left untouched. **Destructive** — the `.shared` copy is deleted, not moved back. |

### Flag style per shell

| | bash / zsh | PowerShell |
| --- | --- | --- |
| Main branch (clone) | `-b`, `--branch` | `-Branch`, `-b` |
| Base ref (switch) | `--from` | `-From` |
| Force (remove) | `-f`, `--force` | `-Force`, `-f` |

The positional commands and their semantics are identical; only the option syntax follows each shell's convention.

## Notable behaviors

- **All remote branches are visible.** `clone` sets `remote.origin.fetch` to `+refs/heads/*:refs/remotes/origin/*` before fetching, so every remote branch shows up — not just the default one.
- **`switch` is DWIM-friendly.** If the branch already exists locally or on `origin`, it's checked out as a worktree. If it's brand-new, it's created off the current worktree's HEAD (the current commit is resolved *before* changing directories, so it reflects where you are, not the bare repo's default branch), or off `--from`/`-From` when given.
- **`remove` won't strand your shell.** With no name it targets the worktree you're in and steps out to the repo root before deleting.
- **`list` hides the bare repo.** The bare `.git` entry is filtered out; only real worktrees are shown.

## Shared files

Some files and folders don't belong to a single branch — build output
(`node_modules/`, `dist/`), editor caches, large local data — and you'd rather
not copy or re-create them in every worktree. `worktree shared add` moves them
into a single `.shared/` directory at the repo root and symlinks them into the
worktree they came from. Every subsequent `worktree switch` re-creates the
symlinks in the worktree it enters.

```bash
worktree shared add node_modules          # from inside a worktree
worktree shared add master/node_modules    # from anywhere, by worktree name
worktree shared list                       # print all shared paths
worktree shared remove node_modules        # delete from .shared, clean up symlinks
worktree switch feature/login             # feature/login/node_modules is symlinked
```

`.shared/` lives next to the bare `.git`, outside any worktree, so git never
tracks it. The list of shared paths is kept in `.shared/.manifest` (one
repo-relative path per line). If a real file or folder already exists at a
shared path when you `switch` into a worktree, it is left untouched and a
warning is printed.

## License

GPL-3.0. See [`LICENSE`](LICENSE).
