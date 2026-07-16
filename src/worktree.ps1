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
  worktree shared add <path>
  worktree shared list                          (alias: ls)
  worktree shared remove <relpath>              (alias: rm)

  clone    Clone <repo-url> as a bare repo into .\.git and check out
           <main-branch> (default: the repository's default branch) as the first worktree.
  switch   Set-Location into the <branch-name> worktree, creating it with
           `git worktree add` first if it doesn't exist yet. A brand-new
           branch is based on the current worktree's HEAD; use -From <base>
           to base it on another branch/commit instead.
  remove   Remove the <branch-name> worktree. With no name, step out of and
           remove the worktree you're currently in.
  list     List the existing worktrees (runs `git worktree list`).
  shared   Manage files shared via .shared\. `add` moves a path into
           .shared\ and symlinks it back; `list` prints the shared paths;
           `remove` deletes a shared path from .shared\ and cleans up its
           symlinks. `switch` re-creates the symlinks in every worktree
           it enters.
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

# Compute the relative symlink target for a link living at
#   $root/$WorktreeName/$RelPath  ->  $root/.shared/$RelPath
# Uses forward slashes so the same target works under Git Bash / WSL too.
function Get-CommonRelTarget {
    param([string]$WorktreeName, [string]$RelPath)

    $linkdir = $WorktreeName
    $sub = Split-Path -Parent $RelPath
    if ($sub -and $sub -ne '.') { $linkdir = "$linkdir/$sub" }
    # depth = number of path segments in linkdir
    $depth = ($linkdir -split '[\\/]' | Where-Object { $_ }).Count
    $ups = '../' * $depth
    return "$ups.shared/$RelPath"
}

function Show-WorktreeSharedUsage {
    Write-Host @'
Usage:
  worktree shared add <path>
  worktree shared list                          (alias: ls)
  worktree shared remove <relpath>              (alias: rm)

  add     Move <path> into the shared .shared\ directory at the repo root and
          symlink it back into the worktree it came from. <path> may be
          prefixed with a worktree name (e.g. 'master\node_modules') or given
          relative to the worktree you're currently in (e.g. 'node_modules').
          Every subsequent `worktree switch` re-creates the symlinks in the
          worktree it enters.
  list    Print the repo-relative paths currently shared in .shared\, one per
          line (the contents of .shared\.manifest).
  remove  Delete the shared <relpath> from .shared\ and remove every symlink
          pointing to it across all worktrees. Real files/folders at the path
          in any worktree are left untouched. Destructive: the .shared copy is
          deleted, not moved back.
'@
}

function Invoke-WorktreeShared {
    param([string]$Subcommand, [string]$Path)

    switch ($Subcommand) {
        'add'    { Invoke-WorktreeSharedAdd -Path $Path }
        'list'   { Invoke-WorktreeSharedList }
        'ls'     { Invoke-WorktreeSharedList }
        'remove' { Invoke-WorktreeSharedRemove -RelPath $Path }
        'rm'     { Invoke-WorktreeSharedRemove -RelPath $Path }
        ''       { Show-WorktreeSharedUsage }
        'help'   { Show-WorktreeSharedUsage }
        default {
            Write-Error "worktree shared: unknown subcommand '$Subcommand'"
            Show-WorktreeSharedUsage
        }
    }
}

function Invoke-WorktreeSharedAdd {
    param([string]$Path)

    if ([string]::IsNullOrEmpty($Path)) {
        Write-Error 'worktree shared add: missing <path>'
        return
    }
    if ($Path -like '/*' -or $Path -like '\*') {
        Write-Error "worktree shared add: absolute paths are not supported; use a path relative to the repo root (e.g. 'master/node_modules')"
        return
    }
    $Path = $Path.TrimStart('./').TrimEnd('/')

    $root = Resolve-WorktreeRoot 'shared add'
    if (-not $root) { return }

    $common = Join-Path $root '.shared'
    $manifest = Join-Path $common '.manifest'

    # Resolve which worktree the path lives in (longest-name prefix first).
    $wtname = ''
    $relpath = ''
    $names = Get-WorktreeNames | Sort-Object { $_.Length } -Descending
    foreach ($name in $names) {
        if ($Path.StartsWith($name + '/')) {
            $wtname = $name
            $relpath = $Path.Substring($name.Length + 1)
            break
        }
    }

    if ([string]::IsNullOrEmpty($wtname)) {
        $top = git rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($top)) {
            Write-Error "worktree shared add: '$Path' is not inside a worktree"
            return
        }
        $topFwd = $top -replace '\\', '/'
        $rootFwd = $root -replace '\\', '/'
        if ($topFwd.StartsWith($rootFwd + '/')) {
            $wtname = $topFwd.Substring($rootFwd.Length + 1)
        } else {
            $wtname = Split-Path -Leaf $topFwd
        }
        $relpath = $Path
    }

    $source = (Join-Path $root ($wtname + '/' + $relpath))
    if (-not (Test-Path -LiteralPath $source)) {
        Write-Error "worktree shared add: no such file or directory '$source'"
        return
    }
    $item = Get-Item -LiteralPath $source -Force
    if ($item.LinkType -eq 'SymbolicLink') {
        Write-Error "worktree shared add: '$source' is already a symlink"
        return
    }

    $dest = Join-Path $common $relpath
    if (Test-Path -LiteralPath $dest) {
        Write-Error "worktree shared add: '$relpath' is already shared (.shared/$relpath exists)"
        return
    }
    if (Test-Path -LiteralPath $manifest) {
        $existing = @(Get-Content -LiteralPath $manifest -ErrorAction SilentlyContinue)
        if ($existing -contains $relpath) {
            Write-Error "worktree shared add: '$relpath' is already in the shared manifest"
            return
        }
    }

    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force
    Move-Item -LiteralPath $source -Destination $dest

    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $source) -Force
    Add-Content -LiteralPath $manifest -Value $relpath

    $linkTarget = Get-CommonRelTarget -WorktreeName $wtname -RelPath $relpath
    $null = New-Item -ItemType SymbolicLink -Path $source -Target $linkTarget

    Write-Host "Shared '$relpath' (.shared/$relpath); symlinked into '$wtname'."
}

# List the repo-relative paths currently shared in .shared\.manifest. Used by
# `shared list` and by tab-completion for `shared remove`. Silent when not in a
# repo or when no manifest exists.
function Get-WorktreeSharedNames {
    $common = git rev-parse --git-common-dir 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($common)) { return @() }
    if (-not [System.IO.Path]::IsPathRooted($common)) {
        $common = Join-Path (Get-Location).Path $common
    }
    $root = (Split-Path -Parent $common) -replace '\\', '/'
    $manifest = Join-Path $root '.shared/.manifest'
    if (-not (Test-Path -LiteralPath $manifest)) { return @() }
    $names = @()
    foreach ($line in @(Get-Content -LiteralPath $manifest -ErrorAction SilentlyContinue)) {
        if (-not [string]::IsNullOrEmpty($line)) { $names += $line }
    }
    return $names
}

function Invoke-WorktreeSharedList {
    $root = Resolve-WorktreeRoot 'shared list'
    if (-not $root) { return }

    $manifest = Join-Path $root '.shared\.manifest'
    if (-not (Test-Path -LiteralPath $manifest)) {
        Write-Host "worktree shared list: no shared items (no .shared\.manifest manifest)"
        return
    }

    $count = 0
    foreach ($line in @(Get-Content -LiteralPath $manifest)) {
        if ([string]::IsNullOrEmpty($line)) { continue }
        Write-Host $line
        $count++
    }
    if ($count -eq 0) {
        Write-Host "worktree shared list: manifest is empty"
    }
}

function Invoke-WorktreeSharedRemove {
    param([string]$RelPath)

    if ([string]::IsNullOrEmpty($RelPath)) {
        Write-Error 'worktree shared remove: missing <relpath>'
        return
    }
    if ($RelPath -like '/*' -or $RelPath -like '\*') {
        Write-Error "worktree shared remove: absolute paths are not supported; use a repo-relative path (e.g. 'node_modules')"
        return
    }
    $RelPath = $RelPath.TrimStart('./').TrimEnd('/')

    $root = Resolve-WorktreeRoot 'shared remove'
    if (-not $root) { return }

    $common = Join-Path $root '.shared'
    $manifest = Join-Path $common '.manifest'
    if (-not (Test-Path -LiteralPath $manifest)) {
        Write-Error "worktree shared remove: no shared items (no .shared\.manifest manifest)"
        return
    }

    $existing = @(Get-Content -LiteralPath $manifest -ErrorAction SilentlyContinue)
    if ($existing -notcontains $RelPath) {
        Write-Error "worktree shared remove: '$RelPath' is not in the shared manifest"
        return
    }

    # 1. Delete the real file/folder from .shared\.
    $target = Join-Path $common $RelPath
    if (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $target -Recurse -Force
    }

    # 2. Rewrite the manifest without the removed relpath; delete the manifest
    #    if it's now empty.
    $remaining = $existing | Where-Object { $_ -ne $RelPath -and -not [string]::IsNullOrEmpty($_) }
    if ($remaining) {
        Set-Content -LiteralPath $manifest -Value $remaining
    } else {
        Remove-Item -LiteralPath $manifest
    }

    # 3. Walk every worktree and remove symlinks at the shared path. Real
    #    files/folders are left untouched.
    $count = 0
    foreach ($name in (Get-WorktreeNames)) {
        if ([string]::IsNullOrEmpty($name)) { continue }
        $link = Join-Path $root ($name + '/' + $RelPath)
        if (Test-Path -LiteralPath $link) {
            $item = Get-Item -LiteralPath $link -Force
            if ($item.LinkType -eq 'SymbolicLink') {
                Remove-Item -LiteralPath $link -Force
                $count++
            }
        }
    }

    Write-Host "Removed shared '$RelPath' (deleted from .shared, $count symlink(s) cleaned up)."
}

# Re-create .shared/ symlinks inside a worktree after switching into it.
# Skips (with a warning) any relpath that already exists as a real file/folder.
function Invoke-WorktreeLinkCommon {
    param([string]$Root, [string]$Branch)

    $manifest = Join-Path $Root '.shared\.manifest'
    if (-not (Test-Path -LiteralPath $manifest)) { return }

    $count = 0
    $skipped = 0
    foreach ($relpath in @(Get-Content -LiteralPath $manifest)) {
        if ([string]::IsNullOrEmpty($relpath)) { continue }
        $link = Join-Path $Root ($Branch + '/' + $relpath)
        if (Test-Path -LiteralPath $link) {
            $item = Get-Item -LiteralPath $link -Force
            if ($item.LinkType -eq 'SymbolicLink') { continue }
            Write-Host "worktree switch: skipping shared '$relpath' (real file/folder exists in '$Branch')" -ForegroundColor Yellow
            $skipped++
            continue
        }
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $link) -Force
        $target = Get-CommonRelTarget -WorktreeName $Branch -RelPath $relpath
        $null = New-Item -ItemType SymbolicLink -Path $link -Target $target
        $count++
    }
    if ($count -gt 0 -or $skipped -gt 0) {
        $msg = "Linked $count shared item(s) into '$Branch'"
        if ($skipped) { $msg += ", skipped $skipped" }
        Write-Host $msg
    }
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
    Invoke-WorktreeLinkCommon -Root $root -Branch $Branch
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

        # Third positional: the <path> for `shared add`.
        [Parameter(Position = 2)]
        [string]$Path,

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
        'shared' { Invoke-WorktreeShared -Subcommand $Name -Path $Path }
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

        [Parameter(Position = 2)]
        [string]$Path,

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
        @{ Name = 'shared'; Help = 'Manage shared (.shared) files' }
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

# Complete the path (third positional -> -Path) for `shared add`.
$WorktreePathCompleter = {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameter)
    $sub = $null; $subsub = $null
    if ($commandAst.CommandElements.Count -ge 2) { $sub = $commandAst.CommandElements[1].Extent.Text }
    if ($commandAst.CommandElements.Count -ge 3) { $subsub = $commandAst.CommandElements[2].Extent.Text }
    if ($sub -eq 'shared') {
        if ($subsub -eq 'add') {
            $dir = Split-Path -Parent $wordToComplete
            $leaf = Split-Path -Leaf $wordToComplete
            if ([string]::IsNullOrEmpty($dir)) { $dir = (Get-Location).Path }
            Get-ChildItem -LiteralPath $dir -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like "$leaf*" } |
                ForEach-Object {
                    $name = $_.Name
                    if ($_.PSIsContainer) { $name += [System.IO.Path]::DirectorySeparatorChar }
                    $fullPath = Join-Path $dir $name
                    [System.Management.Automation.CompletionResult]::new($fullPath, $name, 'ParameterValue', $_.FullName)
                }
        } elseif ($subsub -in @('remove', 'rm')) {
            Get-WorktreeSharedNames |
                Where-Object { $_ -like "$wordToComplete*" } |
                ForEach-Object {
                    [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
                }
        }
    }
}

# When dot-sourced (`. .\worktree.ps1`), the functions above are now available
# in the caller's session; register tab-completion for them. When run directly
# (`.\worktree.ps1 clone ...`), dispatch the script arguments instead.
if ($MyInvocation.InvocationName -eq '.') {
    Register-ArgumentCompleter -CommandName worktree, wt -ParameterName Command -ScriptBlock $WorktreeCommandCompleter
    Register-ArgumentCompleter -CommandName worktree, wt -ParameterName Name -ScriptBlock $WorktreeNameCompleter
    Register-ArgumentCompleter -CommandName worktree, wt -ParameterName Path -ScriptBlock $WorktreePathCompleter
} else {
    worktree @args
}
