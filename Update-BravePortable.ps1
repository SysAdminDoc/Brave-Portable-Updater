#Requires -Version 5.1
<#
.SYNOPSIS
    Brave-Portable-Updater v1.2.0 - updates the Brave install inside a
    Portapps brave-portable directory, leaving the system-wide install
    and user profile untouched.

.DESCRIPTION
    Targets C:\brave-portable-work by default. Reads installed version
    from app\brave.exe, queries github.com/brave/brave-browser for the
    latest release of the chosen channel, downloads the matching zip
    (auto-detects x64/ARM64), and atomically swaps the contents of app\.

    Path-scoped: only kills brave.exe / brave-portable.exe whose .Path
    is under the portable root. The full installed Brave is never touched.

.PARAMETER PortableRoot
    Root of the Portapps install (the directory containing brave-portable.exe).

.PARAMETER Channel
    stable | beta | nightly | auto (default: stable). Auto picks whichever channel has the newest release.

.PARAMETER Force
    Reinstall even if the installed version is already current.

.PARAMETER Quiet
    Suppress console output (still logs to file).

.PARAMETER GitHubToken
    Personal access token for GitHub API (raises rate limit from 60 to 5000 req/hr).

.PARAMETER Rollback
    Swap app.old back to app without downloading. Requires a previous update's app.old.

.PARAMETER BackupProfile
    Copy data\ to backup\data-<timestamp>\ before updating. Keeps 3 most recent.

.PARAMETER SuppressUpdateNag
    Opt in to a machine-wide Brave policy change that suppresses the built-in
    update prompt. This can also affect an installed Brave browser.

.EXAMPLE
    .\Update-BravePortable.ps1
    .\Update-BravePortable.ps1 -Channel beta
    .\Update-BravePortable.ps1 -PortableRoot "D:\Apps\Brave" -Force
    .\Update-BravePortable.ps1 -Rollback
    .\Update-BravePortable.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$PortableRoot = "C:\brave-portable-work",
    [ValidateSet("stable", "beta", "nightly", "auto")]
    [string]$Channel = "stable",
    [switch]$Force,
    [switch]$Quiet,
    [string]$GitHubToken,
    [switch]$Rollback,
    [switch]$BackupProfile,
    [switch]$SuppressUpdateNag
)

$ScriptVersion = "1.2.0"
$ErrorActionPreference = 'Stop'

# --- Paths ---
$appDir      = Join-Path $PortableRoot 'app'
$dataDir     = Join-Path $PortableRoot 'data'
$logDir      = Join-Path $PortableRoot 'log'
$portappJson = Join-Path $PortableRoot 'portapp.json'
$braveExe    = Join-Path $appDir       'brave.exe'
$wrapperExe  = Join-Path $PortableRoot 'brave-portable.exe'

# --- Safety: refuse to run if this doesn't look like a Portapps install ---
if (-not (Test-Path $wrapperExe)) {
    throw "brave-portable.exe not found at $wrapperExe - refusing to run (this is not a Brave Portable install)."
}
if (-not (Test-Path $dataDir)) {
    throw "data\ missing at $dataDir - refusing to run (would orphan profile)."
}

# --- Logging ---
if (-not (Test-Path $logDir)) { [void][IO.Directory]::CreateDirectory($logDir) }
$logFile = Join-Path $logDir 'update.log'

# --- Log rotation (1 MB limit, keep one backup) ---
if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 1MB) {
    $logBackup = Join-Path $logDir 'update.log.1'
    if (Test-Path $logBackup) { [IO.File]::Delete($logBackup) }
    [IO.File]::Move($logFile, $logBackup)
}

function Write-UpdaterLog {
    param([string]$Msg, [ValidateSet('INFO', 'WARN', 'ERR')][string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format s), $Level, $Msg
    $utf8NoBom = New-Object Text.UTF8Encoding $false
    [IO.File]::AppendAllText($logFile, $line + [Environment]::NewLine, $utf8NoBom)
    if (-not $Quiet) {
        Write-Information $line -InformationAction Continue
    }
}

function Get-ReleaseAssetSha256 {
    param(
        [Parameter(Mandatory = $true)]
        $Asset,
        [AllowNull()]
        [string]$ReleaseBody
    )

    $digest = [string]$Asset.digest
    if (-not [string]::IsNullOrWhiteSpace($digest)) {
        if ($digest -notmatch '^sha256:([A-Fa-f0-9]{64})$') {
            throw "GitHub returned an unsupported or malformed asset digest: $digest"
        }
        return $matches[1].ToUpperInvariant()
    }

    if (-not [string]::IsNullOrWhiteSpace($ReleaseBody)) {
        $hashLine = $ReleaseBody -split "`n" |
            Where-Object { $_ -match [regex]::Escape([string]$Asset.name) -and $_ -match '[A-Fa-f0-9]{64}' } |
            Select-Object -First 1
        if ($hashLine -and $hashLine -match '([A-Fa-f0-9]{64})') {
            return $matches[1].ToUpperInvariant()
        }
    }

    return $null
}

function Assert-BravePublisherSignature {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    if ($signature.Status -ne 'Valid') {
        throw "Authenticode status is $($signature.Status): $($signature.StatusMessage)"
    }
    if (-not $signature.SignerCertificate) {
        throw 'Authenticode reported a valid signature without a signer certificate.'
    }

    $subject = [string]$signature.SignerCertificate.Subject
    $braveName = '"?Brave Software, Inc\."?'
    if ($subject -notmatch "(?:^|,\s*)CN=$braveName(?:,|$)" -or
        $subject -notmatch "(?:^|,\s*)O=$braveName(?:,|$)") {
        throw "Valid Authenticode signature belongs to an unexpected publisher: $subject"
    }

    $knownThumbprints = @(
        '8903F2BD47465A4F0F080AA7CEEC31A31B74DE42',
        'F8AC5F11DE7E26383B7A389FC19A2613835799D7'
    )
    [pscustomobject]@{
        Subject = $subject
        Thumbprint = [string]$signature.SignerCertificate.Thumbprint
        KnownCertificate = ([string]$signature.SignerCertificate.Thumbprint -in $knownThumbprints)
    }
}

function Select-BraveReleaseAsset {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Releases,
        [Parameter(Mandatory = $true)]
        [ValidateSet('stable', 'beta', 'nightly', 'auto')]
        [string]$RequestedChannel,
        [Parameter(Mandatory = $true)]
        [ValidateSet('x64', 'arm64')]
        [string]$Architecture
    )

    $keywords = @{
        stable = 'Release'
        beta = 'Beta'
        nightly = 'Nightly'
    }
    $channels = if ($RequestedChannel -eq 'auto') {
        @('stable', 'beta', 'nightly')
    }
    else {
        @($RequestedChannel)
    }
    $assetPattern = "^brave-v.*-win32-$Architecture\.zip$"
    $best = $null

    foreach ($release in $Releases) {
        foreach ($candidateChannel in $channels) {
            if ($release.name -notmatch $keywords[$candidateChannel]) { continue }
            if ($candidateChannel -eq 'stable' -and $release.prerelease) { continue }
            $asset = $release.assets | Where-Object { $_.name -match $assetPattern } | Select-Object -First 1
            if (-not $asset) { continue }

            $version = [Version]($release.tag_name.TrimStart('v'))
            $candidate = [pscustomobject]@{
                Channel = $candidateChannel
                Release = $release
                Asset = $asset
                Version = $version
            }
            if ($RequestedChannel -ne 'auto') {
                return $candidate
            }
            if (-not $best -or $version -gt $best.Version) {
                $best = $candidate
            }
        }
    }

    return $best
}

function Send-Toast {
    param([string]$Title, [string]$Body)
    if (-not $Quiet) { return }
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        $template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(
            [Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $nodes = $template.GetElementsByTagName('text')
        $nodes.Item(0).AppendChild($template.CreateTextNode($Title)) | Out-Null
        $nodes.Item(1).AppendChild($template.CreateTextNode($Body)) | Out-Null
        $toast = [Windows.UI.Notifications.ToastNotification]::new($template)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Brave Portable Updater').Show($toast)
    }
    catch { Write-UpdaterLog "Toast notification failed: $($_.Exception.Message)" 'WARN' }
}

Write-UpdaterLog "Update-BravePortable v$ScriptVersion starting (channel=$Channel, root=$PortableRoot)"

# --- Rollback: restore app.old without downloading ---
if ($Rollback) {
    $appOld = "$appDir.old"
    if (-not (Test-Path $appOld)) {
        Write-UpdaterLog "No app.old directory found - nothing to roll back" 'ERR'
        exit 1
    }
    $rollbackBraveExe = Join-Path $appOld 'brave.exe'
    try {
        $rollbackPublisher = Assert-BravePublisherSignature -Path $rollbackBraveExe
        Write-UpdaterLog "Rollback bundle verified for Brave Software, Inc. ($($rollbackPublisher.Thumbprint))"
    }
    catch {
        Write-UpdaterLog "Rollback bundle signature verification failed: $($_.Exception.Message)" 'ERR'
        exit 1
    }
    if (-not $PSCmdlet.ShouldProcess($PortableRoot, 'Restore app.old as the active Brave bundle')) {
        exit 0
    }
    $rootPattern = (Resolve-Path $PortableRoot).Path.TrimEnd('\') + '\*'
    Get-Process -Name brave, brave-portable -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            if ($_.Path -like $rootPattern) {
                Write-UpdaterLog "Stopping $($_.ProcessName) (PID $($_.Id)) for rollback"
                $_ | Stop-Process -Force -ErrorAction Stop
            }
        }
        catch { Write-UpdaterLog "Could not stop PID $($_.Id): $($_.Exception.Message)" 'WARN' }
    }
    Start-Sleep -Seconds 2
    $appBad = "$appDir.rollback-tmp"
    if (Test-Path $appBad) { Remove-Item $appBad -Recurse -Force }
    try {
        if (Test-Path $appDir) { Rename-Item -Path $appDir -NewName 'app.rollback-tmp' -Force -ErrorAction Stop }
        Rename-Item -Path $appOld -NewName 'app' -Force -ErrorAction Stop
        if (Test-Path $appBad) { Remove-Item $appBad -Recurse -Force -ErrorAction SilentlyContinue }
    }
    catch {
        Write-UpdaterLog "Rollback failed: $($_.Exception.Message)" 'ERR'
        if ((Test-Path $appBad) -and -not (Test-Path $appDir)) {
            Rename-Item -Path $appBad -NewName 'app' -Force -ErrorAction SilentlyContinue
        }
        exit 1
    }
    $rolledVer = (Get-Item $braveExe).VersionInfo.ProductVersion
    if (Test-Path $portappJson) {
        try {
            $raw = $rolledVer.Split('.')
            $braveVer = if ($raw.Length -eq 4) { $raw[1..3] -join '.' } else { $rolledVer }
            $json = Get-Content $portappJson -Raw | ConvertFrom-Json
            $json.version = $braveVer
            $json.date = (Get-Date -Format 'yyyy/MM/dd HH:mm:ss')
            $jsonText = $json | ConvertTo-Json -Depth 10
            $utf8NoBom = New-Object System.Text.UTF8Encoding $false
            [IO.File]::WriteAllText($portappJson, $jsonText, $utf8NoBom)
        }
        catch { Write-UpdaterLog "Could not update portapp.json after rollback: $($_.Exception.Message)" 'WARN' }
    }
    Write-UpdaterLog "Rolled back to $rolledVer"
    Send-Toast 'Brave Portable Updater' "Rolled back to $rolledVer"
    exit 0
}

# --- Detect installed version (strip Chromium-major prefix if present) ---
$currentVersion = $null
if (Test-Path $braveExe) {
    try {
        $raw = (Get-Item $braveExe).VersionInfo.ProductVersion
        $parts = $raw.Split('.')
        if ($parts.Length -eq 4) {
            # Chromium-major.brave-major.brave-minor.brave-patch -> drop first segment
            $currentVersion = [Version]($parts[1..3] -join '.')
        }
        else {
            $currentVersion = [Version]$raw
        }
        Write-UpdaterLog "Installed Brave: $currentVersion (raw: $raw)"
    }
    catch {
        Write-UpdaterLog "Could not parse installed version: $($_.Exception.Message)" 'WARN'
    }
}
else {
    Write-UpdaterLog "No existing brave.exe at $braveExe - will install fresh" 'WARN'
}

# --- Release discovery ---
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
Write-UpdaterLog "Target architecture: $arch"
Write-UpdaterLog "Querying GitHub for latest $Channel release..."
$ghHeaders = @{ 'User-Agent' = 'Brave-Portable-Updater' }
if ($GitHubToken) { $ghHeaders['Authorization'] = "Bearer $GitHubToken" }
try {
    $ghResponse = Invoke-WebRequest `
        -Uri "https://api.github.com/repos/brave/brave-browser/releases?per_page=80" `
        -Headers $ghHeaders -UseBasicParsing -ErrorAction Stop
    $releases = $ghResponse.Content | ConvertFrom-Json
    $rlRemaining = $ghResponse.Headers['X-RateLimit-Remaining']
    if ($rlRemaining -and [int]$rlRemaining -le 10) {
        Write-UpdaterLog "GitHub API rate limit low: $rlRemaining requests remaining" 'WARN'
    }
}
catch {
    $statusCode = $null
    if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }
    if ($statusCode -eq 403 -or $statusCode -eq 429) {
        Write-UpdaterLog "GitHub API rate limit exceeded. Wait or use -GitHubToken for 5000 req/hr." 'ERR'
    }
    else {
        Write-UpdaterLog "GitHub API request failed: $($_.Exception.Message)" 'ERR'
    }
    exit 1
}

$requestedChannel = $Channel
$selection = Select-BraveReleaseAsset -Releases $releases -RequestedChannel $requestedChannel -Architecture $arch
if (-not $selection) {
    Write-UpdaterLog "No $Channel release with a win32-$arch zip asset found." 'ERR'
    exit 1
}
$Channel = $selection.Channel
$selectedAsset = $selection.Asset
$selectedRelease = $selection.Release
$selectedVersion = $selection.Version
if ($requestedChannel -eq 'auto') {
    Write-UpdaterLog "Auto-selected channel: $Channel ($selectedVersion)"
}
$sizeMB = [math]::Round($selectedAsset.size / 1MB, 1)
Write-UpdaterLog "Latest $Channel : $selectedVersion ($($selectedAsset.name), $sizeMB MB)"

# --- Skip if already current ---
if ($currentVersion -and -not $Force -and $currentVersion -ge $selectedVersion) {
    Write-UpdaterLog "Already up-to-date ($currentVersion >= $selectedVersion). Use -Force to reinstall."
    exit 0
}

# --- Metered connection check ---
if (-not $Force) {
    try {
        [void][Windows.Networking.Connectivity.NetworkInformation, Windows, ContentType = WindowsRuntime]
        $connectionProfile = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
        if ($connectionProfile) {
            $cost = $connectionProfile.GetConnectionCost()
            if ($cost.ApproachingDataLimit -or $cost.OverDataLimit -or $cost.Roaming -or
                ($cost.NetworkCostType -ne [Windows.Networking.Connectivity.NetworkCostType]::Unrestricted -and
                 $cost.NetworkCostType -ne [Windows.Networking.Connectivity.NetworkCostType]::Unknown)) {
                Write-UpdaterLog "Metered connection detected ($($cost.NetworkCostType)) - skipping $sizeMB MB download. Use -Force to override." 'WARN'
                exit 0
            }
        }
    }
    catch { Write-UpdaterLog "Metered connection check unavailable: $($_.Exception.Message)" 'WARN' }
}

# --- WhatIf gate ---
if (-not $PSCmdlet.ShouldProcess("Brave $Channel $currentVersion -> $selectedVersion ($sizeMB MB)", 'Download and install')) {
    exit 0
}

# --- Download to temp ---
$tempZip = Join-Path $env:TEMP $selectedAsset.name
if (Test-Path $tempZip) { Remove-Item $tempZip -Force }
Write-UpdaterLog "Downloading to $tempZip..."
try {
    Import-Module BitsTransfer -ErrorAction Stop
    Start-BitsTransfer -Source $selectedAsset.browser_download_url -Destination $tempZip `
        -DisplayName "Brave $Channel $selectedVersion" -ErrorAction Stop
    Write-UpdaterLog "Downloaded via BITS"
}
catch {
    Write-UpdaterLog "BITS failed ($($_.Exception.Message)), falling back to Invoke-WebRequest" 'WARN'
    try {
        if ($Quiet) { $ProgressPreference = 'SilentlyContinue' }
        Invoke-WebRequest -Uri $selectedAsset.browser_download_url -OutFile $tempZip -UseBasicParsing -ErrorAction Stop
        Write-UpdaterLog "Downloaded via Invoke-WebRequest"
    }
    catch {
        Write-UpdaterLog "Download failed: $($_.Exception.Message)" 'ERR'
        exit 1
    }
}
Unblock-File -Path $tempZip -ErrorAction SilentlyContinue

# --- SHA256 verification from GitHub asset metadata or release notes ---
try {
    $expected = Get-ReleaseAssetSha256 -Asset $selectedAsset -ReleaseBody $selectedRelease.body
}
catch {
    Write-UpdaterLog "Could not establish the expected SHA256: $($_.Exception.Message)" 'ERR'
    Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
    exit 1
}
if ($expected) {
    $actual = (Get-FileHash $tempZip -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($expected -ne $actual) {
        Write-UpdaterLog "SHA256 mismatch! expected=$expected actual=$actual" 'ERR'
        Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
        exit 1
    }
    Write-UpdaterLog "SHA256 verified"
}
else {
    Write-UpdaterLog "GitHub did not publish a SHA256 digest for this asset" 'WARN'
}

# --- Path-scoped process kill (NEVER touches the full install) ---
$rootPattern = (Resolve-Path $PortableRoot).Path.TrimEnd('\') + '\*'
$killed = [System.Collections.Generic.List[string]]::new()
Get-Process -Name brave, brave-portable -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        if ($_.Path -like $rootPattern) {
            $killed.Add("$($_.ProcessName) (PID $($_.Id))")
            $_ | Stop-Process -Force -ErrorAction Stop
        }
    }
    catch {
        Write-UpdaterLog "Could not inspect/kill PID $($_.Id): $($_.Exception.Message)" 'WARN'
    }
}
if ($killed.Count) {
    Write-UpdaterLog "Stopped portable processes: $($killed -join ', ')"
    Start-Sleep -Seconds 2
}

# --- Atomic swap: extract to app.new, rename app -> app.old, app.new -> app ---
$appNew = "$appDir.new"
$appOld = "$appDir.old"

if (Test-Path $appNew) { Remove-Item $appNew -Recurse -Force }
Write-UpdaterLog "Extracting to $appNew..."
try {
    Expand-Archive -Path $tempZip -DestinationPath $appNew -Force
}
catch {
    Write-UpdaterLog "Extract failed: $($_.Exception.Message)" 'ERR'
    Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
    exit 1
}

# Flatten if the zip contained a single top-level dir
$topLevel = Get-ChildItem $appNew
if ($topLevel.Count -eq 1 -and $topLevel[0].PSIsContainer) {
    Write-UpdaterLog "Flattening single top-level dir: $($topLevel[0].Name)"
    $inner = $topLevel[0].FullName
    Get-ChildItem $inner -Force | Move-Item -Destination $appNew -Force
    Remove-Item $inner -Force
}

if (-not (Test-Path (Join-Path $appNew 'brave.exe'))) {
    Write-UpdaterLog "Extracted bundle is missing brave.exe - aborting swap" 'ERR'
    Remove-Item $appNew -Recurse -Force
    Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
    exit 1
}

# --- Authenticode signature verification on extracted brave.exe ---
$newBraveExe = Join-Path $appNew 'brave.exe'
try {
    $publisher = Assert-BravePublisherSignature -Path $newBraveExe
    if ($publisher.KnownCertificate) {
        Write-UpdaterLog "Authenticode verified (Brave Software, Inc.)"
    }
    else {
        Write-UpdaterLog "Authenticode verified for Brave Software, Inc. with a rotated certificate: $($publisher.Thumbprint)" 'WARN'
    }
}
catch {
    Write-UpdaterLog "Authenticode verification failed: $($_.Exception.Message)" 'ERR'
    Remove-Item $appNew -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
    exit 1
}

# --- Profile backup (optional) ---
if ($BackupProfile) {
    $backupDir = Join-Path $PortableRoot 'backup'
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupDest = Join-Path $backupDir "data-$stamp"
    Write-UpdaterLog "Backing up data\ to $backupDest..."
    try {
        if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir | Out-Null }
        Copy-Item -Path $dataDir -Destination $backupDest -Recurse -Force -ErrorAction Stop
        Write-UpdaterLog "Profile backup complete"
        $existing = Get-ChildItem $backupDir -Directory | Where-Object { $_.Name -match '^data-' } |
            Sort-Object Name -Descending | Select-Object -Skip 3
        foreach ($old in $existing) {
            Remove-Item $old.FullName -Recurse -Force -ErrorAction SilentlyContinue
            Write-UpdaterLog "Pruned old backup: $($old.Name)"
        }
    }
    catch {
        Write-UpdaterLog "Profile backup failed: $($_.Exception.Message)" 'ERR'
        Remove-Item $appNew -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
        exit 1
    }
}

Write-UpdaterLog "Swapping app directories..."
if (Test-Path $appOld) {
    try {
        Remove-Item $appOld -Recurse -Force -ErrorAction Stop
    }
    catch {
        Write-UpdaterLog "Could not replace the previous rollback bundle: $($_.Exception.Message)" 'ERR'
        Remove-Item $appNew -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
        exit 1
    }
}
if (Test-Path $appDir) {
    try {
        Rename-Item -Path $appDir -NewName 'app.old' -Force -ErrorAction Stop
    }
    catch {
        Write-UpdaterLog "Could not rename existing app\ (still locked?): $($_.Exception.Message)" 'ERR'
        Remove-Item $appNew -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
        exit 1
    }
}
try {
    Rename-Item -Path $appNew -NewName 'app' -Force -ErrorAction Stop
}
catch {
    Write-UpdaterLog "Could not promote app.new - restoring app.old: $($_.Exception.Message)" 'ERR'
    if (Test-Path $appOld) { Rename-Item -Path $appOld -NewName 'app' -Force -ErrorAction SilentlyContinue }
    Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
    exit 1
}
if (Test-Path $appOld) {
    Write-UpdaterLog "Previous version retained at app.old (use -Rollback to restore)"
}

# --- Update portapp.json so the wrapper UI shows the right version ---
# CRITICAL: Portapps' Go wrapper uses encoding/json, which REJECTS UTF-8 BOM.
# PS 5.1's Set-Content -Encoding UTF8 writes BOM. Use .NET's UTF8Encoding($false)
# to emit BOM-less UTF-8, otherwise brave-portable.exe fails to launch with
# "cannot unmarshal portapps.json: invalid character ..."
if (Test-Path $portappJson) {
    try {
        $json = Get-Content $portappJson -Raw | ConvertFrom-Json
        $json.version = $selectedVersion.ToString()
        $json.date = (Get-Date -Format 'yyyy/MM/dd HH:mm:ss')
        $jsonText = $json | ConvertTo-Json -Depth 10
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [IO.File]::WriteAllText($portappJson, $jsonText, $utf8NoBom)
        Write-UpdaterLog "Updated portapp.json -> version=$selectedVersion"
    }
    catch {
        Write-UpdaterLog "Could not update portapp.json: $($_.Exception.Message)" 'WARN'
    }
}

# --- Optional machine-wide Brave policy change ---
if ($SuppressUpdateNag) {
    try {
        $regPath = 'HKLM:\SOFTWARE\WOW6432Node\BraveSoftware\UpdateDev'
        if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
        Set-ItemProperty -Path $regPath -Name 'LastCheckPeriodSec' -Value 0 -Type DWord -Force -ErrorAction Stop
        Write-UpdaterLog "Suppressed the Brave update prompt with the requested machine-wide registry policy"
    }
    catch {
        Write-UpdaterLog "Could not apply the requested update-prompt policy: $($_.Exception.Message)" 'WARN'
    }
}

# --- Cleanup + verify ---
Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
$installedNow = (Get-Item $braveExe).VersionInfo.ProductVersion
Write-UpdaterLog "Done. Brave $Channel updated: $currentVersion -> $installedNow"
Send-Toast 'Brave Portable Updater' "Updated: $currentVersion -> $installedNow"
exit 0
