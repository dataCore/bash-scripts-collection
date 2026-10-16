<#
.SYNOPSIS
    install-log.ps1 - dataCore Fluent Bit log agent setup for Windows Server.

.DESCRIPTION
    Windows counterpart of install-log.sh. Fluent Bit itself is installed and
    updated by the package (installer, winget, UniGetUI); this script wires it
    up so that an update can never break the configuration:

    1. Detect host IP and VLAN
    2. Prompt for / accept OpenObserve credentials and verify them
    3. Write our own config to C:\ProgramData\fluent-bit\ (outside the
       install directory, which every package update rewrites)
    4. Deploy the source configs from logconfs\ (windows always, the rest
       on demand)
    5. Point the Windows service at our config via the Service Control Manager
    6. Validate (--dry-run), restart and check that the agent delivers

    The installer's C:\Program Files\fluent-bit\conf\fluent-bit.conf is NEVER
    used: each update replaces it with the vendor default. A running service
    keeps its config in memory, so an overwritten file only shows at the next
    restart - that silenced dataCoreDC04a twice and dataCoreMail02 once.

    Files owned by this script (C:\ProgramData\fluent-bit\):
      datacore.conf            main config (no secrets)
      datacore-secrets.conf    credentials, ACL SYSTEM + Administrators only
      conf.d\*.conf            inputs/outputs per source
      db\                      event log bookmarks and tail offsets
      storage\                 on-disk buffer (storage.path)
      log\fluent-bit.log       agent log (Log_File)

    Re-running is safe and idempotent: datacore.conf is regenerated from
    scratch. Configs from an older hand-made setup in the install directory
    are moved to C:\ProgramData\fluent-bit\legacy-<timestamp>\, their DB files
    are taken over so no events are shipped twice or skipped.

.PARAMETER O2Host
    OpenObserve endpoint, always the Traefik FQDN (e.g. log.geek.ch).

.PARAMETER User
    OpenObserve ingest user. Prompted when omitted.

.PARAMETER Pass
    OpenObserve ingest password. Prompted (hidden) when omitted.

.PARAMETER Org
    OpenObserve organization (default: default).

.PARAMETER Vlan
    Override the VLAN derived from the third octet of the host IP.

.PARAMETER Dc
    Include the Active Directory event logs (logconfs\dc.conf).

.PARAMETER Hmail
    Include the hMailServer logs (logconfs\hmail.conf).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install-log.ps1 -O2Host log.geek.ch -Hmail

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install-log.ps1 -O2Host log.geek.ch -Dc

.LINK
    https://github.com/dataCore/bash-scripts-collection
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$O2Host,
    [string]$User,
    [string]$Pass,
    [string]$Org = 'default',
    [string]$Vlan,
    [switch]$Dc,
    [switch]$Hmail
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --------------- Paths --------------------------------------------------------
$ServiceName = 'fluent-bit'
$FbDir       = Join-Path $env:ProgramFiles 'fluent-bit'
$FbBin       = Join-Path $FbDir 'bin\fluent-bit.exe'
$PkgConfDir  = Join-Path $FbDir 'conf'                 # installer-owned, never written
$DataDir     = Join-Path $env:ProgramData 'fluent-bit'
$DcConf      = Join-Path $DataDir 'datacore.conf'
$SecretsConf = Join-Path $DataDir 'datacore-secrets.conf'
$ConfD       = Join-Path $DataDir 'conf.d'
$DbDir       = Join-Path $DataDir 'db'
$StorageDir  = Join-Path $DataDir 'storage'
$LogDir      = Join-Path $DataDir 'log'
$AgentLog    = Join-Path $LogDir 'fluent-bit.log'
$SourceDir   = Join-Path $PSScriptRoot 'logconfs'

# Hand-made setups before 2026-10 kept their configs in the install directory
$LegacyConfs = @('datacore.conf', 'datacore.conf.vendor-bak', 'windows.conf', 'dc.conf', 'hmail.conf')

# --------------- Helpers ------------------------------------------------------
function Write-Section([string]$Text) {
    Write-Host ''
    Write-Host "> $Text" -ForegroundColor Cyan
    Write-Host ('-' * 60) -ForegroundColor Cyan
}
function Write-Ok([string]$Text)   { Write-Host "  [OK]   $Text" -ForegroundColor Green }
function Write-Info([string]$Text) { Write-Host "  [INFO] $Text" }
function Write-Warn([string]$Text) { Write-Host "  [WARN] $Text" -ForegroundColor Yellow }
function Stop-Script([string]$Text) {
    Write-Host "  [ERR]  $Text" -ForegroundColor Red
    exit 1
}

# UTF-8 without BOM: Windows PowerShell 5.1 would write UTF-16 (>) or a BOM
function Write-TextFile([string]$Path, [string]$Content) {
    [IO.File]::WriteAllText($Path, $Content, (New-Object Text.UTF8Encoding $false))
}

# Restrict a file to SYSTEM and Administrators (plus an optional service account)
function Set-PrivateAcl([string]$Path, [string]$ExtraAccount) {
    $acl = New-Object Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {   # SYSTEM, Administrators
        $id = (New-Object Security.Principal.SecurityIdentifier $sid)
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule $id, 'FullControl', 'Allow'))
    }
    if ($ExtraAccount) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule $ExtraAccount, 'Read', 'Allow'))
    }
    Set-Acl -Path $Path -AclObject $acl
}

function Get-ServiceCommandLine {
    $proc = Get-CimInstance Win32_Process -Filter "Name='fluent-bit.exe'" | Select-Object -First 1
    if ($proc) { return $proc.CommandLine }
    return ''
}

# =============================================================================
# Step 0 - Preconditions
# =============================================================================
function Test-Preconditions {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Stop-Script 'Run this script as Administrator.'
    }
    if (-not (Test-Path $FbBin)) {
        Stop-Script "Fluent Bit not found at $FbBin. Install it first (https://fluentbit.io/download/), then re-run."
    }
    if (-not (Test-Path $SourceDir)) {
        Stop-Script "logconfs directory not found at $SourceDir."
    }
    $needed = @('windows.conf')
    if ($Dc)    { $needed += 'dc.conf' }
    if ($Hmail) { $needed += 'hmail.conf' }
    foreach ($f in $needed) {
        if (-not (Test-Path (Join-Path $SourceDir $f))) { Stop-Script "logconfs\$f is missing." }
    }
    $version = (& $FbBin --version 2>$null | Select-Object -First 1)
    Write-Ok "Fluent Bit found: $version"
}

# =============================================================================
# Step 1 - Detect Network
# =============================================================================
function Get-Network {
    Write-Section 'Network Detection'

    $cfg = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
           Select-Object -First 1
    if (-not $cfg) { Stop-Script 'Could not detect the primary IPv4 address (no interface with a default gateway).' }
    $script:HostIp = ($cfg.IPv4Address | Select-Object -First 1).IPAddress

    if ($Vlan) {
        $script:VlanId = $Vlan
        Write-Ok "Primary IP:    $HostIp"
        Write-Ok "VLAN (manual): $VlanId"
    } else {
        $script:VlanId = $HostIp.Split('.')[2]
        Write-Ok "Primary IP:    $HostIp"
        Write-Ok "VLAN (auto):   $VlanId"
        Write-Warn 'If the VLAN is wrong, re-run with -Vlan <id>.'
    }
    Write-Ok "Target:        https://$O2Host (org: $Org)"
}

# =============================================================================
# Step 2 - Credentials
# =============================================================================
function Get-Credentials {
    Write-Section 'OpenObserve Credentials'

    if (-not $User) { $script:User = Read-Host '  OpenObserve user' }
    if (-not $User) { Stop-Script 'User cannot be empty.' }

    if (-not $Pass) {
        $secure = Read-Host '  OpenObserve password' -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try     { $script:Pass = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    } else {
        Write-Ok 'Password: (from -Pass)'
    }
    if (-not $Pass) { Stop-Script 'Password cannot be empty.' }
    if ("$User$Pass" -match '[\r\n]') { Stop-Script 'User or password contains a line break.' }

    # Same check as install-log.sh: an empty batch against the ingest endpoint,
    # the only part of the API reachable from every network. Writes nothing,
    # bad credentials -> 401. Catches a typo before the service is restarted.
    Write-Info "Verifying credentials against https://$O2Host ..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $auth = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${User}:${Pass}"))
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Method Post `
             -Uri "https://$O2Host/api/$Org/windows_events/_json" `
             -Headers @{ Authorization = "Basic $auth" } -ContentType 'application/json' -Body '[]'
        $status = [int]$r.StatusCode
    } catch {
        $status = 0
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
    }
    if ($status -ne 200) { Stop-Script "Credential check failed (HTTP $status). Check -O2Host / user / password." }
    Write-Ok 'Credentials verified successfully'
}

# =============================================================================
# Step 3 - Stop Service, Take Over Legacy Setup
# =============================================================================
function Move-LegacySetup {
    Write-Section 'Preparing'

    foreach ($d in @($DataDir, $ConfD, $DbDir, $StorageDir, $LogDir)) {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
    }

    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Stopped') {
        Stop-Service -Name $ServiceName -Force
        Write-Ok "Service $ServiceName stopped"
    }

    # Keep the bookmarks/offsets of the old setup so nothing is shipped twice
    # or skipped. Only taken over once - an existing DB here is newer.
    foreach ($db in Get-ChildItem -Path $FbDir -Filter 'fluent-bit-*.db' -File -ErrorAction SilentlyContinue) {
        $target = Join-Path $DbDir $db.Name
        if (-not (Test-Path $target)) {
            Copy-Item $db.FullName $target
            Write-Ok "Taken over DB: $($db.Name)"
        }
    }

    $legacy = @($LegacyConfs | ForEach-Object { Join-Path $PkgConfDir $_ } | Where-Object { Test-Path $_ })
    if ($legacy.Count -gt 0) {
        $dest = Join-Path $DataDir ("legacy-" + (Get-Date -Format 'yyyyMMddHHmmss'))
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        Set-PrivateAcl $dest $null
        foreach ($f in $legacy) {
            Move-Item $f $dest
            Write-Ok "Moved legacy config: $(Split-Path $f -Leaf)"
        }
        Write-Info "Legacy configs in $dest (SYSTEM + Administrators only - may contain the old password)"
    }
}

# =============================================================================
# Step 4 - Deploy Configs
# =============================================================================
function Set-Configs {
    Write-Section 'Deploying dataCore Config'

    $includes = @('windows.conf')
    if ($Dc)    { $includes += 'dc.conf' }
    if ($Hmail) { $includes += 'hmail.conf' }

    # Remove source configs that are no longer selected
    Get-ChildItem -Path $ConfD -Filter '*.conf' -File | Where-Object { $includes -notcontains $_.Name } | ForEach-Object {
        Remove-Item $_.FullName
        Write-Info "Removed conf.d\$($_.Name) (not selected)"
    }
    foreach ($f in $includes) {
        Copy-Item (Join-Path $SourceDir $f) (Join-Path $ConfD $f) -Force
        Write-Ok "Deployed: conf.d\$f"
    }

    # The service account must be able to read the secrets; LocalSystem is
    # covered by the SYSTEM entry.
    $startName = (Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue).StartName
    $extra = $null
    if ($startName -and $startName -notin @('LocalSystem', 'NT AUTHORITY\SYSTEM')) { $extra = $startName }

    if (-not (Test-Path $SecretsConf)) { Write-TextFile $SecretsConf '' }
    Set-PrivateAcl $SecretsConf $extra
    Write-TextFile $SecretsConf (@"
# OpenObserve ingest credentials for Fluent Bit
# Generated by install-log.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
# ACL: SYSTEM + Administrators only. Included by datacore.conf.
@SET o2_user=$User
@SET o2_passwd=$Pass
"@)
    Write-Ok "Credentials written to $SecretsConf (SYSTEM + Administrators only)"

    $includeLines = ($includes | ForEach-Object { "@INCLUDE $ConfD\$_" }) -join "`r`n"
    Write-TextFile $DcConf (@"
# =============================================================================
# Fluent Bit - dataCore Main Config
# Generated by install-log.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
# Host: $env:COMPUTERNAME ($HostIp)
# Target: https://$O2Host (org: $Org)
#
# Do not edit - re-run install-log.ps1 instead. The installer's
# $PkgConfDir\fluent-bit.conf is overwritten by every package update and
# deliberately not used; the service is pointed here with -c.
# Credentials come from $SecretsConf.
# =============================================================================

[SERVICE]
    Flush           5
    Daemon          Off
    Log_Level       warn
    Log_File        $AgentLog
    Parsers_File    $PkgConfDir\parsers.conf
    # Buffer chunks on disk so a log server outage does not lose records.
    # Inputs opt in via "storage.type filesystem", outputs cap their backlog
    # with "storage.total_limit_size" (oldest chunks are dropped first).
    storage.path              $StorageDir
    storage.sync              normal
    storage.max_chunks_up     128
    storage.backlog.mem_limit 16M

# =============================================================================
# Host-specific settings
# =============================================================================
@SET o2_host=$O2Host
@SET o2_org=$Org
@SET host_ip=$HostIp
@SET vlan=$VlanId
@SET fb_data=$DataDir
@INCLUDE $SecretsConf

# =============================================================================
# Load configs
# =============================================================================
$includeLines
"@)
    Write-Ok "Main config written to $DcConf"
    Write-Ok "Installer config $PkgConfDir\fluent-bit.conf left untouched"
}

# =============================================================================
# Step 5 - Service
# =============================================================================
function Set-ServicePath {
    Write-Section 'Pointing the Service at Our Config'

    & $FbBin -c $DcConf --dry-run *> $null
    if ($LASTEXITCODE -ne 0) { Stop-Script "Configuration validation failed. Check: & '$FbBin' -c '$DcConf' --dry-run" }
    Write-Ok 'Configuration validated successfully'

    $pathName = "`"$FbBin`" -c `"$DcConf`""
    $svc = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
    if (-not $svc) {
        New-Service -Name $ServiceName -BinaryPathName $pathName -DisplayName 'Fluent Bit' -StartupType Automatic | Out-Null
        Write-Ok "Service $ServiceName created"
    } elseif ($svc.PathName -ne $pathName) {
        # Through the SCM, not the registry: ImagePath edits only apply after a reboot
        $res = $svc | Invoke-CimMethod -MethodName Change -Arguments @{ PathName = $pathName }
        if ($res.ReturnValue -ne 0) { Stop-Script "Changing the service path failed (Win32_Service.Change returned $($res.ReturnValue))." }
        Write-Ok "Service path changed (was: $($svc.PathName))"
    } else {
        Write-Ok 'Service path already correct'
    }
    Set-Service -Name $ServiceName -StartupType Automatic
}

# =============================================================================
# Step 6 - Start and Verify
# =============================================================================
function Start-Agent {
    Write-Section 'Starting Fluent Bit'

    $logOffset = 0
    if (Test-Path $AgentLog) { $logOffset = (Get-Item $AgentLog).Length }

    Start-Service -Name $ServiceName
    Write-Info 'Waiting 20 s for the first flushes ...'
    Start-Sleep -Seconds 20

    if ((Get-Service -Name $ServiceName).Status -ne 'Running') {
        Stop-Script "Service $ServiceName is not running. Check $AgentLog"
    }
    Write-Ok "Service $ServiceName is running"

    $cmdLine = Get-ServiceCommandLine
    if ($cmdLine -like "*$DcConf*") {
        Write-Ok "Process runs with $DcConf"
    } else {
        Stop-Script "Process does not use $DcConf - command line: $cmdLine"
    }

    # Only what was logged since this start; at Log_Level warn a healthy agent writes nothing
    $new = ''
    if (Test-Path $AgentLog) {
        $fs = [IO.File]::Open($AgentLog, 'Open', 'Read', 'ReadWrite')
        try {
            [void]$fs.Seek($logOffset, 'Begin')
            $new = (New-Object IO.StreamReader $fs).ReadToEnd()
        } finally { $fs.Dispose() }
    }
    $lines    = @($new -split "`r?`n")
    $warnings = @($lines | Where-Object { $_ -match '\[ ?warn\]' })
    $errors   = @($lines | Where-Object { $_ -match '\[error\]' })
    if ($warnings.Count -gt 0) {
        Write-Warn "Fluent Bit logged $($warnings.Count) warning(s) since the start, last ones:"
        $warnings | Select-Object -Last 5 | ForEach-Object { Write-Host "         $_" -ForegroundColor Yellow }
    }
    if ($errors.Count -gt 0) {
        Write-Host "  [ERR]  Fluent Bit logged $($errors.Count) error(s) since the start, last ones:" -ForegroundColor Red
        $errors | Select-Object -Last 5 | ForEach-Object { Write-Host "         $_" -ForegroundColor Red }
        Stop-Script "Agent is running but not delivering cleanly - fix the cause and re-run. Log: $AgentLog"
    }
    Write-Ok 'No errors in the agent log since the start'
}

# =============================================================================
# Summary
# =============================================================================
function Write-Summary {
    Write-Section 'Summary'
    $active = @('windows')
    if ($Dc)    { $active += 'dc' }
    if ($Hmail) { $active += 'hmail' }

    Write-Host ''
    Write-Host '  Fluent Bit setup complete.' -ForegroundColor Green
    Write-Host ''
    '{0,-18} {1}' -f '  Host IP:', $HostIp
    '{0,-18} {1}' -f '  VLAN:', $VlanId
    '{0,-18} {1}' -f '  OpenObserve:', "https://$O2Host (org: $Org)"
    '{0,-18} {1}' -f '  Active configs:', ($active -join ', ')
    '{0,-18} {1}' -f '  Main config:', $DcConf
    '{0,-18} {1}' -f '  Credentials:', $SecretsConf
    '{0,-18} {1}' -f '  Agent log:', $AgentLog
    Write-Host ''
    Write-Info 'Fluent Bit can be updated freely (installer, winget, UniGetUI): the update'
    Write-Info 'only replaces files in the install directory, the service keeps using'
    Write-Info "$DcConf. Re-run this script after an update to be sure."
    Write-Host ''
    Write-Info 'Verify in OpenObserve (from an admin host with UI access):'
    Write-Host "    https://$O2Host -> Logs -> windows_events -> host = '$env:COMPUTERNAME'"
    Write-Host ''
}

# =============================================================================
# Main
# =============================================================================
Write-Host ''
Write-Host '  dataCore - Fluent Bit Log Agent Setup (Windows)' -ForegroundColor Cyan

Test-Preconditions
Get-Network
Get-Credentials
Move-LegacySetup
Set-Configs
Set-ServicePath
Start-Agent
Write-Summary
