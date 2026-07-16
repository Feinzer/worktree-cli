<#
.SYNOPSIS
    worktree — helpers for a bare-repo + worktrees layout (PowerShell port).

.DESCRIPTION
    Native PowerShell counterpart to worktree.sh / worktree.zsh, for Windows
    PowerShell 5.1 and PowerShell 7+. Provides the same clone/switch/remove
    commands plus tab-completion, without needing Git Bash or WSL.

    Commands:
      worktree clone <repo-url> [-Branch <main-branch>]   (-b alias)
      worktree switch <branch-name> [-From <base>]
      worktree remove [<branch-name>] [-Force]             (-f alias; rm alias)
      worktree list                                        (ls alias)

    NOTE ON FLAGS: this is idiomatic PowerShell, so options use the PowerShell
    convention (-Branch / -b, -Force / -f) rather than the shell's --branch /
    --force. The positional commands (clone/switch/remove) are identical.

.EXAMPLE
    # Dot-source it (e.g. from your $PROFILE) so `worktree` and `wt` stick:
    . C:\path\to\worktree.ps1
    worktree clone https://github.com/acme/widgets.git -b main

.EXAMPLE
    # Or run it once, directly:
    .\worktree.ps1 clone https://github.com/acme/widgets.git

.NOTES
    On Windows you can also just use the bash version (worktree.sh) under
    Git Bash or WSL — see README.md. This .ps1 is for a native PowerShell
    experience.
#>

function Show-WorktreeUsage {
    Write-Host @'
Usage:
  worktree clone <repo-url> [-Branch <main-branch>]   (-b alias)
  worktree switch <branch-name> [-From <base>]
  worktree remove [<branch-name>] [-Force]            (-f alias; rm alias)
  worktree list                                       (ls alias)

  clone    Clone <repo-url> as a bare repo into .\.git and check out
           <main-branch> (default: the repository's default branch) as the first worktree.
  switch   Set-Location into the <branch-name> worktree, creating it with
           `git worktree add` first if it doesn't exist yet. A brand-new
           branch is based on the current worktree's HEAD; use -From <base>
           to base it on another branch/commit instead.
  remove   Remove the <branch-name> worktree. With no name, step out of and
           remove the worktree you're currently in.
  list     List the existing worktrees (runs `git worktree list`).
'@
}

# Resolve the repo root: the directory that contains the bare .git dir.
# Returns $null (and writes an error under $Context) when not in a worktree.
function Resolve-WorktreeRoot {
    param([string]$Context)

    $common = git rev-parse --git-common-dir 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($common)) {
        Write-Error "worktree ${Context}: not inside a worktree repo (no .git found)"
        return $null
    }
    # git may return a relative path (e.g. ".git"); make it absolute first.
    if (-not [System.IO.Path]::IsPathRooted($common)) {
        $common = Join-Path (Get-Location).Path $common
    }
    return (Split-Path -Parent $common)
}

# List the branch names of existing worktrees. Used by tab-completion to
# suggest arguments for `switch` and `remove`. Stays silent when not in a repo.
function Get-WorktreeNames {
    $common = git rev-parse --git-common-dir 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($common)) { return @() }
    if (-not [System.IO.Path]::IsPathRooted($common)) {
        $common = Join-Path (Get-Location).Path $common
    }
    $root = (Split-Path -Parent $common) -replace '\\', '/'

    $names = @()
    $lines = git -C $root worktree list --porcelain 2>$null
    if ($LASTEXITCODE -ne 0) { return @() }
    foreach ($line in $lines) {
        if ($line -like 'worktree *') {
            $p = ($line.Substring(9)) -replace '\\', '/'
            # Only report worktrees living under the repo root, and print them
            # relative to it so nested names (e.g. feature/foo) survive.
            if ($p.StartsWith($root + '/')) {
                $names += $p.Substring($root.Length + 1)
            }
        }
    }
    return $names
}

function Invoke-WorktreeClone {
    param(
        [string]$RepoUrl,
        [string]$Branch = ''
    )

    if ([string]::IsNullOrEmpty($RepoUrl)) {
        Write-Error 'worktree clone: missing <repo-url>'
        Show-WorktreeUsage
        return
    }

    # Derive the repo name from the URL (strip trailing slash and .git suffix).
    $repoName = $RepoUrl.TrimEnd('/')
    $repoName = $repoName -replace '.*[\\/]', ''   # keep the leaf after the last slash
    $repoName = $repoName -replace '\.git$', ''

    if ([string]::IsNullOrEmpty($repoName)) {
        Write-Error "worktree clone: could not determine repo name from '$RepoUrl'"
        return
    }

    if (Test-Path -LiteralPath $repoName) {
        Write-Error "worktree clone: '$repoName' already exists here; refusing to overwrite"
        return
    }

    # Create the repo directory and work inside it.
    try {
        New-Item -ItemType Directory -Path $repoName -ErrorAction Stop | Out-Null
    } catch {
        Write-Error "worktree clone: could not create '$repoName'"
        return
    }

    Push-Location -LiteralPath $repoName
    try {
        # 1. Clone the repo into a hidden .git folder (bare).
        git clone --bare $RepoUrl .git
        if ($LASTEXITCODE -ne 0) { return }

        # 1b. If no branch was given, ask the remote which branch its HEAD
        #     points to (the same mechanism `git clone` uses internally).
        if ([string]::IsNullOrEmpty($Branch)) {
            $lines = git ls-remote --symref origin HEAD 2>$null
            $symrefLine = $lines | Where-Object { $_ -like 'ref: *' } | Select-Object -First 1
            if ($symrefLine) {
                $rest   = $symrefLine.Substring(5)   # strip "ref: "
                $target = ($rest -split "`t")[0]
                if ($target -like 'refs/heads/*') {
                    $Branch = $target -replace '^refs/heads/', ''
                }
            }
            if ([string]::IsNullOrEmpty($Branch)) {
                Write-Error "worktree clone: could not determine the repository's default branch; pass -Branch <branch>"
                return
            }
        }

        # 2. Fix the fetch refspec so all remote branches are visible.
        git config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
        if ($LASTEXITCODE -ne 0) { return }

        # Populate the remote-tracking refs we just enabled.
        git fetch origin
        if ($LASTEXITCODE -ne 0) { return }

        # 3. Create the first worktree for the main branch.
        git worktree add $Branch
        if ($LASTEXITCODE -ne 0) { return }
    } finally {
        # 5. Get the user back out of the repo.
        Pop-Location
    }

    Write-Host "Done. Worktree '$Branch' is ready at .\$repoName\$Branch"
}

function Invoke-WorktreeSwitch {
    param(
        [string]$Branch,
        [string]$From
    )

    if ([string]::IsNullOrEmpty($Branch)) {
        Write-Error 'worktree switch: missing <branch-name>'
        return
    }

    $haveBase = -not [string]::IsNullOrEmpty($From)

    # Default base for a brand-new branch: the HEAD of the worktree we're
    # currently standing in. Resolve it to a concrete commit BEFORE we chdir to
    # the repo root, otherwise it would mean the bare repo's default branch
    # rather than where the user is.
    $base = $From
    if (-not $haveBase) {
        $base = git rev-parse HEAD 2>$null
        if ($LASTEXITCODE -ne 0) { $base = '' }
    }

    $root = Resolve-WorktreeRoot 'switch'
    if (-not $root) { return }

    $target = Join-Path $root $Branch

    # Create the worktree only if the folder isn't there yet.
    if (-not (Test-Path -LiteralPath $target -PathType Container)) {
        git -C $root show-ref --verify --quiet "refs/heads/$Branch" 2>$null
        $localExists = ($LASTEXITCODE -eq 0)
        git -C $root show-ref --verify --quiet "refs/remotes/origin/$Branch" 2>$null
        $remoteExists = ($LASTEXITCODE -eq 0)

        if ($haveBase) {
            # Explicit -From: always create a new branch off the given base.
            git -C $root worktree add -b $Branch $Branch $base
        } elseif ($localExists -or $remoteExists) {
            # Branch already exists locally or on origin: let git DWIM (check it
            # out / create a tracking branch). The base doesn't apply here.
            git -C $root worktree add $Branch
        } elseif (-not [string]::IsNullOrEmpty($base)) {
            # Brand-new branch, based on the current worktree's HEAD.
            git -C $root worktree add -b $Branch $Branch $base
        } else {
            # No current HEAD to base on: fall back to git's default.
            git -C $root worktree add $Branch
        }
        if ($LASTEXITCODE -ne 0) { return }
    }

    Set-Location -LiteralPath $target
    Write-Host "Switched to worktree '$Branch' ($target)"
}

function Invoke-WorktreeRemove {
    param(
        [string]$Branch,
        [switch]$Force
    )

    $root = Resolve-WorktreeRoot 'remove'
    if (-not $root) { return }

    if (-not [string]::IsNullOrEmpty($Branch)) {
        $target = Join-Path $root $Branch
    } else {
        # No branch given: target the worktree we're currently sitting in.
        $top = git rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($top)) {
            Write-Error 'worktree remove: no <branch-name> and not inside a worktree'
            return
        }
        $target = $top
        $Branch = Split-Path -Leaf $top
    }

    if (-not (Test-Path -LiteralPath $target -PathType Container)) {
        Write-Error "worktree remove: no such worktree '$Branch'"
        return
    }

    # If the current directory is inside the worktree being removed, step out
    # to the repo root first so we don't strand the shell in a deleted path.
    $cur = (Get-Location).Path -replace '\\', '/'
    $tgt = ((Resolve-Path -LiteralPath $target).Path) -replace '\\', '/'
    if ($cur -eq $tgt -or $cur.StartsWith($tgt + '/')) {
        Set-Location -LiteralPath $root
    }

    if ($Force) {
        git -C $root worktree remove --force $Branch
    } else {
        git -C $root worktree remove $Branch
    }
    if ($LASTEXITCODE -ne 0) { return }
    Write-Host "Removed worktree '$Branch' ($target)"
}

function Invoke-WorktreeList {
    $root = Resolve-WorktreeRoot 'list'
    if (-not $root) { return }

    # Drop the bare repo entry; only real worktrees are useful here.
    git -C $root worktree list | Where-Object { $_ -notmatch '\(bare\)$' }
}

function worktree {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Command,

        # Second positional: the repo URL for `clone`, or the branch name for
        # `switch` / `remove`.
        [Parameter(Position = 1)]
        [string]$Name,

        [Alias('b')]
        [string]$Branch = '',

        # Base branch/commit for a new branch created by `switch`.
        [string]$From,

        [Alias('f')]
        [switch]$Force,

        [Alias('h')]
        [switch]$Help
    )

    if ($Help -or [string]::IsNullOrEmpty($Command) -or $Command -eq 'help') {
        Show-WorktreeUsage
        return
    }

    switch ($Command) {
        'clone'  { Invoke-WorktreeClone -RepoUrl $Name -Branch $Branch }
        'switch' { Invoke-WorktreeSwitch -Branch $Name -From $From }
        'remove' { Invoke-WorktreeRemove -Branch $Name -Force:$Force }
        'rm'     { Invoke-WorktreeRemove -Branch $Name -Force:$Force }
        'list'   { Invoke-WorktreeList }
        'ls'     { Invoke-WorktreeList }
        default  {
            Write-Error "worktree: unknown command '$Command'"
            Show-WorktreeUsage
        }
    }
}

# Short alias: `wt` behaves exactly like `worktree`.
function wt {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Command,

        [Parameter(Position = 1)]
        [string]$Name,

        [Alias('b')]
        [string]$Branch = '',

        [string]$From,

        [Alias('f')]
        [switch]$Force,

        [Alias('h')]
        [switch]$Help
    )
    worktree @PSBoundParameters
}

# Complete the subcommand (first positional -> -Command).
$WorktreeCommandCompleter = {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameter)
    $cmds = @(
        @{ Name = 'clone';  Help = 'Clone a repo as a bare repo + first worktree' }
        @{ Name = 'switch'; Help = 'Set-Location into a worktree, creating it if needed' }
        @{ Name = 'remove'; Help = 'Remove a worktree' }
        @{ Name = 'rm';     Help = 'Alias for remove' }
        @{ Name = 'list';   Help = 'List the existing worktrees' }
        @{ Name = 'ls';     Help = 'Alias for list' }
        @{ Name = 'help';   Help = 'Show usage' }
    )
    $cmds |
        Where-Object { $_.Name -like "$wordToComplete*" } |
        ForEach-Object {
            [System.Management.Automation.CompletionResult]::new(
                $_.Name, $_.Name, 'ParameterValue', $_.Help)
        }
}

# Complete the branch name (second positional -> -Name) for switch/remove only.
$WorktreeNameCompleter = {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameter)
    $sub = $null
    if ($commandAst.CommandElements.Count -ge 2) {
        $sub = $commandAst.CommandElements[1].Extent.Text
    }
    if ($sub -in @('switch', 'remove', 'rm')) {
        Get-WorktreeNames |
            Where-Object { $_ -like "$wordToComplete*" } |
            ForEach-Object {
                [System.Management.Automation.CompletionResult]::new(
                    $_, $_, 'ParameterValue', $_)
            }
    }
}

# When dot-sourced (`. .\worktree.ps1`), the functions above are now available
# in the caller's session; register tab-completion for them. When run directly
# (`.\worktree.ps1 clone ...`), dispatch the script arguments instead.
if ($MyInvocation.InvocationName -eq '.') {
    Register-ArgumentCompleter -CommandName worktree, wt -ParameterName Command -ScriptBlock $WorktreeCommandCompleter
    Register-ArgumentCompleter -CommandName worktree, wt -ParameterName Name -ScriptBlock $WorktreeNameCompleter
} else {
    worktree @args
}
