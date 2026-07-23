#!/usr/bin/env pwsh
<#
.SYNOPSIS
  One command, no manual download: fetch a harness release from the PUBLIC
  distribution repo and install it - the Windows/PowerShell sibling of web-install.sh.

.DESCRIPTION
  The `irm ... | iex` front door. Deliberately THIN: resolve a release (latest, a
  pinned version, or an interactive pick), download the version-matched bundle +
  sha256 sidecar + the matching install.ps1, then hand off to install.ps1 - which
  owns the real work (checksum verify, tar-escape guard, dependency preflight,
  copy + hook wiring, strict integrity check, and the post-install test run). This
  wrapper trusts NOTHING from a local checkout; every byte comes from the release
  assets. Compatible with Windows PowerShell 5.1 and PowerShell 7+.

.PARAMETER Target
  Target repo root to install into (positional, default: current directory).

.PARAMETER Version
  Pin a version (e.g. 5.3.0 or harness-v5.3.0). Default: the HARNESS_VERSION env
  var, else the latest release.

.PARAMETER Interactive
  List the available releases, pick one, PREVIEW its changelog, and confirm before
  installing.

.PARAMETER DryRun
  Resolve the version and print exactly what WOULD be downloaded (URLs + expected
  sha256) - install nothing.

.PARAMETER SkipTests
  Forwarded to install.ps1 (skip the post-install suite). Alias -NoTests.

.EXAMPLE
  irm https://hieubui2409.github.io/sdlc-harness-release/install.ps1 | iex

.EXAMPLE
  pwsh -File web-install.ps1 C:\src\my-repo -Interactive
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Target,

    [string]$Version = $env:HARNESS_VERSION,

    [switch]$Interactive,

    [switch]$DryRun,

    [Alias('NoTests')]
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'

$Repo = 'hieubui2409/sdlc-harness-release'
$Api  = "https://api.github.com/repos/$Repo/releases"
$Dl   = "https://github.com/$Repo/releases"

if ([string]::IsNullOrEmpty($Target)) { $Target = (Get-Location).Path }

# A fetch helper that handles both https (Invoke-WebRequest) and a file:// base
# (Copy-Item) - the file:// path lets the whole flow be exercised offline, mirroring
# curl's file:// support in web-install.sh.
function Get-Asset([string]$Url, [string]$OutFile) {
    if ($Url -like 'file://*') {
        $p = $Url -replace '^file://', ''
        Copy-Item -LiteralPath $p -Destination $OutFile -Force
    } else {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
    }
}

# 1. resolve the release tag.
if (-not [string]::IsNullOrEmpty($Version)) {
    $Tag = 'harness-v' + ($Version -replace '^harness-v', '')
}
elseif ($Interactive) {
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
    if (-not [int]::TryParse($choice, [ref]$idx) -or $idx -lt 1 -or $idx -gt $rels.Count) {
        throw "invalid selection: $choice"
    }
    $sel = $rels[$idx - 1]
    $Tag = $sel.tag_name
    Write-Host ''
    Write-Host "-------- changelog: $Tag --------"
    if ([string]::IsNullOrWhiteSpace($sel.body)) {
        Write-Host '(no release notes published for this version)'
    } else {
        Write-Host ($sel.body).Trim()
    }
    Write-Host '---------------------------------'
    $yes = Read-Host "install $Tag into $Target? [y/N]"
    if ($yes -notmatch '^(y|yes)$') { Write-Host 'aborted.'; exit 1 }
}
else {
    Write-Host 'resolving the latest harness release ...'
    $Tag = (Invoke-RestMethod -Uri "$Api/latest" -UseBasicParsing).tag_name
    if ([string]::IsNullOrEmpty($Tag)) { throw "could not resolve the latest release tag from $Api/latest" }
}

$Base   = if ($env:HARNESS_RELEASE_BASE) { $env:HARNESS_RELEASE_BASE } else { "$Dl/download/$Tag" }
$Bundle = "$Tag.tar.gz"

# 2. dry-run: print the plan and stop - the "show me first" surface.
if ($DryRun) {
    Write-Host "DRY-RUN - would install $Tag into $Target, fetching:"
    Write-Host "  bundle:    $Base/$Bundle"
    Write-Host "  checksum:  $Base/$Bundle.sha256"
    Write-Host "  installer: $Base/install.ps1"
    try {
        $sha = (Invoke-RestMethod -Uri "$Base/$Bundle.sha256" -UseBasicParsing).ToString().Trim()
        if ($sha) { Write-Host "  expected sha256: $sha" }
    } catch { }
    Write-Host 're-run without -DryRun to install.'
    exit 0
}

# 3. download the version-matched bundle + sidecar + installer to a temp dir.
$Work = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-" + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $Work -Force | Out-Null
try {
    Write-Host "downloading $Bundle from $Base ..."
    Get-Asset "$Base/$Bundle" (Join-Path $Work $Bundle)
    # The sha256 sidecar is optional to install.ps1 (missing -> skip verify), so a
    # failed sidecar fetch must not abort the whole install.
    try { Get-Asset "$Base/$Bundle.sha256" (Join-Path $Work "$Bundle.sha256") }
    catch { Write-Warning 'no sha256 sidecar published - install.ps1 will skip checksum verify' }
    Get-Asset "$Base/install.ps1" (Join-Path $Work 'install.ps1')

    # 4. hand off to the version-matched installer, using the SAME PowerShell engine
    #    (pwsh or Windows PowerShell) so 5.1 and 7+ both work.
    Write-Host "installing harness $Tag into $Target ..."
    $engine = (Get-Process -Id $PID).Path
    $ps1 = Join-Path $Work 'install.ps1'
    $argv = @('-File', $ps1, (Join-Path $Work $Bundle), $Target)
    if ($SkipTests) { $argv += '-SkipTests' }
    & $engine @argv
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
finally {
    Remove-Item -Recurse -Force -LiteralPath $Work -ErrorAction SilentlyContinue
}
