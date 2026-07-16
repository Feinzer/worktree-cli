# worktree

A shell helper (`worktree`, alias `wt`) that manages a **bare-repo + worktrees** git layout. Instead of a single checkout, each repo becomes a directory whose `.git` is a bare clone and whose subdirectories are per-branch worktrees:

```
my-project/
├── .git              # bare clone (the real repo)
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
worktree clone https://github.com/acme/widgets.git -b main
worktree switch feature/login
worktree list
worktree remove feature/login
```

`wt` is an alias that behaves exactly like `worktree`.

| Command | Description |
| --- | --- |
| `clone <repo-url> [-b <main-branch>]` | Clone `<repo-url>` as a bare repo into `./<repo>/.git` and check out `<main-branch>` (default: `main`) as the first worktree. |
| `switch <branch-name> [--from <base>]` | `cd` into the `<branch-name>` worktree, creating it with `git worktree add` if it doesn't exist yet. A brand-new branch is based on the current worktree's HEAD; use `--from <base>` to base it elsewhere. |
| `remove [<branch-name>] [-f\|--force]` (alias: `rm`) | Remove the named worktree. With no name, remove the worktree you're currently in (stepping out to the repo root first so your shell isn't left in a deleted path). |
| `list` (alias: `ls`) | List the existing worktrees (the bare-repo entry is filtered out). |

### Flag style per shell

| | bash / zsh | PowerShell |
| --- | --- | --- |
| Main branch (clone) | `-b`, `--branch` | `-Branch`, `-b` |
| Base ref (switch) | `--from` | `-From` |
| Force (remove) | `-f`, `--force` | `-Force`, `-f` |

The positional commands and their semantics are identical; only the option syntax follows each shell's convention.

## Shared config across worktrees (`.shared/`)

Files that git ignores — `.env.local`, local credentials, editor settings — don't travel between worktrees, because each worktree is its own directory and `git worktree add` never copies ignored files. That means every new branch starts without your local config.

To fix this, `switch` links a **shared directory** into each worktree. Drop anything you want every branch to see into a `.shared/` folder next to the bare `.git`:

```
my-project/
├── .git              # bare clone
├── .shared/          # <-- shared, gitignored config lives here
│   ├── .env.local
│   └── config/       # folders work too
├── main              # .env.local, config/  ->  symlinks into .shared/
└── feature/login     # same symlinks, same source of truth
```

Every time you `worktree switch <branch>`, each entry inside `.shared/` is symlinked into that worktree by name. Edit `.shared/.env.local` once and all branches see the change instantly — there's only one real file.

How it behaves:

- **Files and folders both work.** A symlink is created for each top-level entry in `.shared/`, whether it's a file or a directory.
- **Never clobbers.** If a worktree already has a file with that name, it's left untouched — the symlink is only created when nothing is there.
- **Backfills existing worktrees.** The linking runs on *every* `switch`, not just when a worktree is first created, so worktrees made before you populated `.shared/` pick up the links the next time you switch into them.
- **Nothing is committed.** The symlinks point at `.shared/`, which you keep gitignored; git never tracks them.
- **Opt-in.** No `.shared/` directory means no symlinks and no change in behavior.

Set it up once per repo:

```bash
cd my-project
mkdir .shared
mv main/.env.local .shared/.env.local   # move your real config into the shared source
worktree switch main                     # relink main to the shared copy
```

> **Windows / PowerShell:** creating symlinks requires either [Developer Mode](https://learn.microsoft.com/windows/apps/get-started/enable-your-device-for-development) enabled or running the shell elevated. Without it, the links are silently skipped.

## Notable behaviors

- **All remote branches are visible.** `clone` sets `remote.origin.fetch` to `+refs/heads/*:refs/remotes/origin/*` before fetching, so every remote branch shows up — not just the default one.
- **`switch` is DWIM-friendly.** If the branch already exists locally or on `origin`, it's checked out as a worktree. If it's brand-new, it's created off the current worktree's HEAD (the current commit is resolved *before* changing directories, so it reflects where you are, not the bare repo's default branch), or off `--from`/`-From` when given.
- **`remove` won't strand your shell.** With no name it targets the worktree you're in and steps out to the repo root before deleting.
- **`list` hides the bare repo.** The bare `.git` entry is filtered out; only real worktrees are shown.

## License

GPL-3.0. See [`LICENSE`](LICENSE).
