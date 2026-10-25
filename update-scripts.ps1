<#
.SYNOPSIS
    update-scripts.ps1 - updates this collection on Windows.

.DESCRIPTION
    Windows counterpart of update-scripts.sh, without git: Windows Server has
    no git, and the collection only needs to be read here, never committed.

    1. Ask GitHub for the commit at the tip of main
    2. Stop if this copy is already at that commit (unless -Force)
    3. Download the ZIP of exactly that commit and unpack it to a temp dir
    4. Remove the "downloaded from the internet" mark (Zone.Identifier), so
       the scripts also run under the RemoteSigned execution policy
    5. Mirror it into the directory of this script (robocopy /MIR) and write
       the commit to .commit

    Same semantics as on Linux: the directory is a copy of main, local changes
    are discarded and files that are gone from the repository are removed.
    Unlike update-scripts.sh there is no signature check (no git to run
    verify-commit); the download comes over HTTPS from GitHub.

    The directory must hold nothing but the collection. A directory with
    other files and no .commit is refused, so a wrong location is never
    wiped by the mirror.

.PARAMETER Force
    Download and mirror even if the copy is already at the newest commit,
    e.g. to restore a file changed by hand.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File C:\Scripts\bash-scripts-collection\update-scripts.ps1

.EXAMPLE
    # First installation: fetch this script alone, it fetches the rest
    New-Item -ItemType Directory -Force C:\Scripts\bash-scripts-collection | Out-Null
    Invoke-WebRequest -UseBasicParsing https://raw.githubusercontent.com/dataCore/bash-scripts-collection/main/update-scripts.ps1 -OutFile C:\Scripts\bash-scripts-collection\update-scripts.ps1
    powershell -ExecutionPolicy Bypass -File C:\Scripts\bash-scripts-collection\update-scripts.ps1

.LINK
    https://github.com/dataCore/bash-scripts-collection
#>

[CmdletBinding()]
param(
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Repo       = 'dataCore/bash-scripts-collection'
$Branch     = 'main'
$TargetDir  = $PSScriptRoot
$CommitFile = Join-Path $TargetDir '.commit'

# --------------- Helpers ------------------------------------------------------
function Write-Ok([string]$Text)   { Write-Host "  [OK]   $Text" -ForegroundColor Green }
function Write-Info([string]$Text) { Write-Host "  [INFO] $Text" }
function Write-Warn([string]$Text) { Write-Host "  [WARN] $Text" -ForegroundColor Yellow }
function Stop-Script([string]$Text) {
    Write-Host "  [ERR]  $Text" -ForegroundColor Red
    exit 1
}

# Add TLS 1.2 to what .NET offers (PowerShell 5.1 may default to TLS 1.0),
# without taking TLS 1.3 away where the OS supports it
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# --------------- Guard: never mirror over a foreign directory -----------------
# On the first run the directory holds only this script; later .commit marks
# it as ours. Anything else means a wrong location, and /MIR would delete it.
if (-not (Test-Path -LiteralPath $CommitFile)) {
    $foreign = @(Get-ChildItem -LiteralPath $TargetDir -Force | Where-Object { $_.Name -ne 'update-scripts.ps1' })
    if ($foreign.Count -gt 0) {
        Stop-Script "$TargetDir holds other files and no .commit. Put update-scripts.ps1 into an empty directory of its own (e.g. C:\Scripts\bash-scripts-collection)."
    }
}

# --------------- Newest commit ------------------------------------------------
try {
    $tip = Invoke-RestMethod -UseBasicParsing -TimeoutSec 60 -Uri "https://api.github.com/repos/$Repo/commits/$Branch" `
           -Headers @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'datacore-update-scripts' }
} catch {
    Stop-Script "Could not query github.com for $Repo@$Branch ($($_.Exception.Message)). Collection left unchanged."
}
$sha     = [string]$tip.sha
$subject = ([string]$tip.commit.message -split "`n")[0]
if ($sha -notmatch '^[0-9a-f]{40}$') { Stop-Script "Unexpected answer from github.com (no commit id). Collection left unchanged." }
$short = $sha.Substring(0, 7)

$current = ''
if (Test-Path -LiteralPath $CommitFile) { $current = (Get-Content -LiteralPath $CommitFile -Raw).Trim() }
if ($current -eq $sha -and -not $Force) {
    Write-Ok "Collection is already at $Branch ($short $subject)."
    exit 0
}

# --------------- Download, unpack, mirror -------------------------------------
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("datacore-scripts-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $zip = Join-Path $tmp 'collection.zip'
    try {
        # The archive of the commit id, not of the branch: what lands on disk
        # is exactly the commit reported below, even if main moves meanwhile
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 120 -Uri "https://github.com/$Repo/archive/$sha.zip" -OutFile $zip
    } catch {
        Stop-Script "Download of $short failed ($($_.Exception.Message)). Collection left unchanged."
    }

    $unpacked = Join-Path $tmp 'unpacked'
    Expand-Archive -LiteralPath $zip -DestinationPath $unpacked
    # GitHub wraps everything in one folder <repo>-<sha>
    $source = @(Get-ChildItem -LiteralPath $unpacked -Directory)
    if ($source.Count -ne 1 -or -not (Test-Path (Join-Path $source[0].FullName 'update-scripts.ps1'))) {
        Stop-Script "Unexpected archive layout. Collection left unchanged."
    }
    $source = $source[0].FullName
    Get-ChildItem -LiteralPath $source -Recurse -File | Unblock-File

    if ($current) {
        Write-Info "Updating $TargetDir from $($current.Substring(0, [Math]::Min(7, $current.Length))) to $short (local changes are discarded)"
    } else {
        Write-Info "Installing $short into $TargetDir"
    }

    # /MIR: copy new and changed files, delete what the repository no longer
    # has. .commit is excluded, it is written afterwards. robocopy exit codes
    # below 8 mean success (bit flags for copied/extra/mismatched files).
    $out  = & robocopy.exe $source $TargetDir /MIR /XF .commit /R:2 /W:2 /NFL /NDL /NJH /NJS /NP 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    if ($code -ge 8) {
        Stop-Script "robocopy failed (exit $code): $(($out | Where-Object { $_.Trim() }) -join ' ') - the collection may be incomplete, re-run update-scripts.ps1."
    }

    # Plain ASCII, no BOM, no newline: the same bytes git would show
    [IO.File]::WriteAllText($CommitFile, $sha, (New-Object Text.ASCIIEncoding))
    Write-Ok "Collection is at $Branch ($short $subject)."
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
