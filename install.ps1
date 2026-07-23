#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Install a harness bundle into a target repo - the Windows/PowerShell sibling of install.sh.

.DESCRIPTION
  Dispatches on WHAT you give it:
    install.ps1                                   -> online: fetch the LATEST release
    install.ps1 <target>                          -> online latest, into <target>
    install.ps1 <url-to-.tar.gz> [target]         -> online: download that URL
    install.ps1 <harness-vX.Y.Z.tar.gz> [target]  -> offline: install a local bundle

  Whichever way the bundle arrives, the rest is one shot: verify sha256 -> extract
  (with a tar-escape guard) -> check deps -> install + verify (--strict) -> run the
  test suite. -SkipTests skips step 5 (~30s). Compatible with Windows PowerShell 5.1
  and PowerShell 7+.

.PARAMETER Source
  Positional: a local *.tar.gz bundle, a URL to one, or empty (fetch the latest).

.PARAMETER Target
  Target repo root to install into (positional, default: current directory).

.PARAMETER Version
  Online: pin a version (e.g. 5.3.0 or harness-v5.3.0). Default: HARNESS_VERSION env.

.PARAMETER Interactive
  Online: list releases, pick one, PREVIEW its changelog, confirm - then install.

.PARAMETER DryRun
  Online: print exactly what WOULD be downloaded (URLs + expected sha256) - install nothing.

.PARAMETER SkipTests
  Skip the post-install suite. Alias -NoTests.

.EXAMPLE
  irm https://hieubui2409.github.io/sdlc-harness-release/install.ps1 | iex

.EXAMPLE
  pwsh -File install.ps1 .\harness-v5.3.0.tar.gz C:\src\my-repo

.EXAMPLE
  pwsh -File install.ps1 C:\src\my-repo -Interactive
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Source,

    [Parameter(Position = 1)]
    [string]$Target,

    [string]$Version = $env:HARNESS_VERSION,

    [switch]$Interactive,

    [switch]$DryRun,

    [Alias('NoTests')]
    [switch]$SkipTests
)

# set -eu equivalent: throw on cmdlet errors. Native commands (python) do NOT trip
# this - every external call below checks $LASTEXITCODE explicitly.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Repo = 'hieubui2409/sdlc-harness-release'
$Api  = "https://api.github.com/repos/$Repo/releases"
$Dl   = "https://github.com/$Repo/releases"

if ([string]::IsNullOrEmpty($Target)) { $Target = (Get-Location).Path }

# A fetch helper that handles both https (Invoke-WebRequest) and a file:// base
# (Copy-Item) - the file:// path lets the flow be exercised offline.
function Get-Asset([string]$Url, [string]$OutFile) {
    if ($Url -like 'file://*') {
        Copy-Item -LiteralPath ($Url -replace '^file://', '') -Destination $OutFile -Force
    } else {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
    }
}

# --- Python invocation helper ---------------------------------------------------
# The interpreter command differs by platform: the `py -3` launcher is the most
# reliable on Windows and sidesteps the App Execution Alias stub (a 0-byte
# python.exe that opens the Microsoft Store and never runs code). Probe py -3
# first, then python, then python3, and pin the first Python >=3.9 found.
#
# Callers pass a SINGLE array so dash-prefixed args (-m, --source) land verbatim
# as python args instead of being parsed as this function's parameters.
$script:PyExe = $null
$script:PyBase = @()

function Invoke-Py {
    param([Parameter(Mandatory = $true)][string[]]$PyArgs)
    & $script:PyExe @($script:PyBase + $PyArgs)
}

$probe = 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)'
foreach ($cand in @(
        @{ exe = 'py';      base = @('-3') },
        @{ exe = 'python';  base = @() },
        @{ exe = 'python3'; base = @() })) {
    if (-not (Get-Command $cand.exe -ErrorAction SilentlyContinue)) { continue }
    try {
        & $cand.exe @($cand.base + @('-c', $probe)) 2>$null
    } catch { continue }
    if ($LASTEXITCODE -eq 0) {
        $script:PyExe = $cand.exe
        $script:PyBase = $cand.base
        break
    }
}
if (-not $script:PyExe) {
    Write-Error @'
no Python >=3.9 found (looked for: py -3, python, python3). The harness runs on
Python - its hooks execute as Python scripts, so the target machine needs it too.
Install Python 3, then re-run:
    Windows: https://www.python.org/downloads/  (tick "Add python.exe to PATH")
             or:  winget install Python.Python.3
'@
    exit 1
}
# install.py wires THIS interpreter into the hook commands.
$env:HARNESS_PY = $script:PyExe

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-install-" + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $Work -Force | Out-Null
try {
    # ── Resolve the bundle: local *.tar.gz (offline) vs URL/empty (online) ──────
    $Bundle = ''
    if (-not [string]::IsNullOrEmpty($Source) -and $Source -notmatch '^(https?|file)://' -and $Source -like '*.tar.gz') {
        # offline: a local bundle path
        if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { Write-Error "bundle not found: $Source"; exit 2 }
        $Bundle = (Resolve-Path -LiteralPath $Source).Path
        if ($DryRun) { Write-Host "DRY-RUN - would install the local bundle $Bundle into $Target."; exit 0 }
    } else {
        # online: resolve a URL and download it
        if (-not [string]::IsNullOrEmpty($Source) -and $Source -match '^(https?|file)://') {
            if ($Source -notlike '*.tar.gz') { Write-Error 'the URL must point at a harness-vX.Y.Z.tar.gz bundle'; exit 2 }
            $bundleUrl = $Source
            $bundleName = Split-Path -Path $Source -Leaf
            $tag = $bundleName -replace '\.tar\.gz$', ''
        } else {
            if (-not [string]::IsNullOrEmpty($Version)) {
                $tag = 'harness-v' + ($Version -replace '^harness-v', '')
            } elseif ($Interactive) {
                Write-Host 'fetching the release list ...'
                $rels = Invoke-RestMethod -Uri "$Api?per_page=30" -UseBasicParsing
                if (-not $rels) { throw 'no releases found' }
                for ($i = 0; $i -lt $rels.Count; $i++) {
                    $r = $rels[$i]
                    $date = if ($r.published_at) { ([string]$r.published_at).Substring(0, 10) } else { '' }
                    '{0,2}) {1,-16} {2}  {3}' -f ($i + 1), $r.tag_name, $date, $r.name | Write-Host
                }
                $choice = Read-Host 'pick a release [1]'
                if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '1' }
                $idx = 0
                if (-not [int]::TryParse($choice, [ref]$idx) -or $idx -lt 1 -or $idx -gt $rels.Count) { throw "invalid selection: $choice" }
                $sel = $rels[$idx - 1]
                $tag = $sel.tag_name
                Write-Host ''
                Write-Host "-------- changelog: $tag --------"
                if ([string]::IsNullOrWhiteSpace($sel.body)) { Write-Host '(no release notes published for this version)' }
                else { Write-Host ($sel.body).Trim() }
                Write-Host '---------------------------------'
                $yes = Read-Host "install $tag into $Target? [y/N]"
                if ($yes -notmatch '^(y|yes)$') { Write-Host 'aborted.'; exit 1 }
            } else {
                Write-Host 'resolving the latest harness release ...'
                $tag = (Invoke-RestMethod -Uri "$Api/latest" -UseBasicParsing).tag_name
                if ([string]::IsNullOrEmpty($tag)) { throw "could not resolve the latest release tag from $Api/latest" }
            }
            $base = if ($env:HARNESS_RELEASE_BASE) { $env:HARNESS_RELEASE_BASE } else { "$Dl/download/$tag" }
            $bundleName = "$tag.tar.gz"
            $bundleUrl = "$base/$bundleName"
        }
        $shaUrl = "$bundleUrl.sha256"

        if ($DryRun) {
            Write-Host "DRY-RUN - would install $tag into $Target, fetching:"
            Write-Host "  bundle:   $bundleUrl"
            Write-Host "  checksum: $shaUrl"
            try {
                $sha = (Invoke-RestMethod -Uri $shaUrl -UseBasicParsing).ToString().Trim()
                if ($sha) { Write-Host "  expected sha256: $sha" }
            } catch { }
            Write-Host 're-run without -DryRun to install.'
            exit 0
        }

        Write-Host "downloading $bundleName ..."
        Get-Asset $bundleUrl (Join-Path $Work $bundleName)
        try { Get-Asset $shaUrl (Join-Path $Work "$bundleName.sha256") }
        catch { Write-Warning 'no sha256 sidecar - checksum verify will be skipped' }
        $Bundle = Join-Path $Work $bundleName
    }

    # 1. verify the bundle before trusting its contents -----------------------------
    $sidecar = "$Bundle.sha256"
    if (Test-Path -LiteralPath $sidecar -PathType Leaf) {
        Write-Host "verifying $sidecar ..."
        # sha256sum sidecar format: "<hex>  <filename>" - take the first token.
        $expected = ((Get-Content -LiteralPath $sidecar -TotalCount 1) -split '\s+')[0].ToLowerInvariant()
        $actual = (Get-FileHash -LiteralPath $Bundle -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($expected -ne $actual) {
            Write-Error "checksum mismatch for $Bundle`n  expected: $expected`n  actual:   $actual"
            exit 1
        }
        Write-Host '  checksum OK'
    }

    # 2. extract to the temp tree (the installer reads from here) --------------------
    # 2a. validate members cannot escape the extract dir, THEN extract - both via
    #     Python tarfile. Expand-Archive only handles .zip, so leaning on tarfile
    #     keeps this portable and drops any dependency on tar.exe. The checksum step
    #     above is skipped when no sidecar exists, so a MITM'd bundle is the threat:
    #     reject any absolute path, '..' traversal, or out-of-tree link member
    #     before writing anything. Written to a temp .py (ASCII) and run as a file
    #     to avoid PS-version stdin-encoding quirks.
    $guard = @'
import os, sys, tarfile
bundle, dest = sys.argv[1], sys.argv[2]
with tarfile.open(bundle, "r:gz") as tf:
    for m in tf.getmembers():
        name = m.name
        if os.path.isabs(name) or name.startswith("/"):
            sys.exit("refusing tarball: absolute member path %r" % name)
        norm = os.path.normpath(name)
        if norm == ".." or norm.startswith(".." + os.sep):
            sys.exit("refusing tarball: path-traversal member %r" % name)
        if m.issym() or m.islnk():
            tgt = m.linkname
            joined = os.path.normpath(os.path.join(os.path.dirname(name), tgt))
            if os.path.isabs(tgt) or joined.startswith(".."):
                sys.exit("refusing tarball: unsafe link %r -> %r" % (name, tgt))
    try:
        tf.extractall(dest, filter="data")  # py3.12+: explicit safe filter (we already validated)
    except TypeError:
        tf.extractall(dest)                 # py<3.9.17: no filter arg; manual guard above stands
'@
    $guardPy = Join-Path $Work '_extract_guard.py'
    Set-Content -LiteralPath $guardPy -Value $guard -Encoding ascii
    Invoke-Py @($guardPy, $Bundle, $Work)
    if ($LASTEXITCODE -ne 0) { Write-Error 'bundle validation/extract failed'; exit 1 }
    Remove-Item -LiteralPath $guardPy -Force -ErrorAction SilentlyContinue

    # 3. dependencies first - the installer and the harness both need them ----------
    Write-Host 'checking dependencies ...'
    Invoke-Py @((Join-Path $Work 'harness\scripts\preflight_deps.py'))
    if ($LASTEXITCODE -ne 0) { Write-Error 'dependency preflight failed'; exit $LASTEXITCODE }

    # 3b. snapshot the EXISTING install's manifest BEFORE the copy overwrites it, so
    #     cleanup (step 4b) can tell version-dropped files from user-added ones.
    #     Absent on a first install -> $OldManifest stays empty -> cleanup is a no-op.
    $OldManifest = ''
    $targetManifest = Join-Path $Target 'harness\manifest.json'
    if (Test-Path -LiteralPath $targetManifest -PathType Leaf) {
        $OldManifest = Join-Path $Work 'old-manifest.json'
        Copy-Item -LiteralPath $targetManifest -Destination $OldManifest -Force
    }

    # 4. install + verify (--strict fails this script on drift) ---------------------
    Write-Host "installing harness into $Target ..."
    $installPy = Join-Path $Work 'harness\install\install.py'
    $installArgs = @($installPy, '--source', $Work, '--target', $Target, '--strict')
    if ($env:REVIEWERS) { $installArgs += @('--reviewers', $env:REVIEWERS) }
    Invoke-Py $installArgs
    if ($LASTEXITCODE -ne 0) { Write-Error 'install/verify failed'; exit $LASTEXITCODE }

    # 4b. clean up files the previous version left behind (safe layer only). This must
    #     NEVER fail the install - the harness is already copied + verified - so the
    #     call is guarded: a cleanup error just defers to the manual door.
    if ($OldManifest) {
        # persist the snapshot durably so a later hs:cleanup can reach the deferred
        # (modified) layer - harness/state/ is preserved across installs.
        $stateDir = Join-Path $Target 'harness\state'
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        try { Copy-Item -LiteralPath $OldManifest -Destination (Join-Path $stateDir 'cleanup-prev-manifest.json') -Force } catch {}
        Write-Host 'cleaning up files dropped by the previous version ...'
        Invoke-Py @((Join-Path $Work 'harness\scripts\cleanup_orphans.py'), '--target', $Target, '--old-manifest', $OldManifest, '--apply')
        if ($LASTEXITCODE -ne 0) { Write-Host "  cleanup deferred - run hs:cleanup in $Target to review" }
    }

    # 5. run the suite against the installed copy (default; -SkipTests to skip) ------
    if ($SkipTests) {
        Write-Host 'skipping the harness test suite (-SkipTests).'
    } else {
        Write-Host "running the harness test suite in $Target (use -SkipTests to skip) ..."
        Push-Location $Target
        try {
            Invoke-Py @('-m', 'pytest', 'harness/tests/', '-q')
            if ($LASTEXITCODE -ne 0) { Write-Error 'harness test suite failed'; exit $LASTEXITCODE }
        } finally {
            Pop-Location
        }
    }
} finally {
    # trap 'rm -rf "$WORK"' EXIT - fires on success, error, or Ctrl-C.
    if (Test-Path -LiteralPath $Work) {
        Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($script:PyBase.Count -gt 0) {
    $pyDisplay = "$($script:PyExe) $($script:PyBase -join ' ')"
} else {
    $pyDisplay = $script:PyExe
}
Write-Host 'done.'
Write-Host '  - enable the hs plugin: run /reload-plugins in Claude Code (or restart it)'
Write-Host "  - re-verify any time: $pyDisplay `"$Target\harness\scripts\verify_install.py`" --strict"
if ($SkipTests) {
    Write-Host "  - run the suite later: cd `"$Target`"; $pyDisplay -m pytest harness/tests/ -q"
}
