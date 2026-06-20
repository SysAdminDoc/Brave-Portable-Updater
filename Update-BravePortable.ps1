#Requires -Version 5.1
<#
.SYNOPSIS
    Brave-Portable-Updater v1.1.0 - updates the Brave install inside a
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
    stable | beta | nightly (default: stable).

.PARAMETER Force
    Reinstall even if the installed version is already current.

.PARAMETER Quiet
    Suppress console output (still logs to file).

.PARAMETER GitHubToken
    Personal access token for GitHub API (raises rate limit from 60 to 5000 req/hr).

.PARAMETER Rollback
    Swap app.old back to app without downloading. Requires a previous update's app.old.

.EXAMPLE
    .\Update-BravePortable.ps1
    .\Update-BravePortable.ps1 -Channel beta
    .\Update-BravePortable.ps1 -PortableRoot "D:\Apps\Brave" -Force
    .\Update-BravePortable.ps1 -Rollback
#>
[CmdletBinding()]
param(
    [string]$PortableRoot = "C:\brave-portable-work",
    [ValidateSet("stable", "beta", "nightly")]
    [string]$Channel = "stable",
    [switch]$Force,
    [switch]$Quiet,
    [string]$GitHubToken,
    [switch]$Rollback
)

$ScriptVersion = "1.1.0"
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
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$logFile = Join-Path $logDir 'update.log'

# --- Log rotation (1 MB limit, keep one backup) ---
if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 1MB) {
    $logBackup = Join-Path $logDir 'update.log.1'
    if (Test-Path $logBackup) { Remove-Item $logBackup -Force }
    Rename-Item -Path $logFile -NewName 'update.log.1' -Force
}

function Write-Log {
    param([string]$Msg, [ValidateSet('INFO', 'WARN', 'ERR')][string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format s), $Level, $Msg
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    if (-not $Quiet) {
        $color = switch ($Level) { 'WARN' { 'Yellow' } 'ERR' { 'Red' } default { 'White' } }
        Write-Host $line -ForegroundColor $color
    }
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
    catch { }
}

Write-Log "Update-BravePortable v$ScriptVersion starting (channel=$Channel, root=$PortableRoot)"

# --- Rollback: restore app.old without downloading ---
if ($Rollback) {
    $appOld = "$appDir.old"
    if (-not (Test-Path $appOld)) {
        Write-Log "No app.old directory found - nothing to roll back" 'ERR'
        exit 1
    }
    $rootPattern = (Resolve-Path $PortableRoot).Path.TrimEnd('\') + '\*'
    Get-Process -Name brave, brave-portable -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            if ($_.Path -like $rootPattern) {
                Write-Log "Stopping $($_.ProcessName) (PID $($_.Id)) for rollback"
                $_ | Stop-Process -Force -ErrorAction Stop
            }
        }
        catch { Write-Log "Could not stop PID $($_.Id): $($_.Exception.Message)" 'WARN' }
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
        Write-Log "Rollback failed: $($_.Exception.Message)" 'ERR'
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
        catch { Write-Log "Could not update portapp.json after rollback: $($_.Exception.Message)" 'WARN' }
    }
    Write-Log "Rolled back to $rolledVer"
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
        Write-Log "Installed Brave: $currentVersion (raw: $raw)"
    }
    catch {
        Write-Log "Could not parse installed version: $($_.Exception.Message)" 'WARN'
    }
}
else {
    Write-Log "No existing brave.exe at $braveExe - will install fresh" 'WARN'
}

# --- Channel keyword for filtering release names ---
$channelKeyword = @{
    'stable'  = 'Release'
    'beta'    = 'Beta'
    'nightly' = 'Nightly'
}[$Channel]

# --- Query GitHub releases ---
Write-Log "Querying GitHub for latest $Channel release..."
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ghHeaders = @{ 'User-Agent' = 'Brave-Portable-Updater' }
if ($GitHubToken) { $ghHeaders['Authorization'] = "Bearer $GitHubToken" }
try {
    $ghResponse = Invoke-WebRequest `
        -Uri "https://api.github.com/repos/brave/brave-browser/releases?per_page=80" `
        -Headers $ghHeaders -UseBasicParsing -ErrorAction Stop
    $releases = $ghResponse.Content | ConvertFrom-Json
    $rlRemaining = $ghResponse.Headers['X-RateLimit-Remaining']
    if ($rlRemaining -and [int]$rlRemaining -le 10) {
        Write-Log "GitHub API rate limit low: $rlRemaining requests remaining" 'WARN'
    }
}
catch {
    $statusCode = $null
    if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }
    if ($statusCode -eq 403 -or $statusCode -eq 429) {
        Write-Log "GitHub API rate limit exceeded. Wait or use -GitHubToken for 5000 req/hr." 'ERR'
    }
    else {
        Write-Log "GitHub API request failed: $($_.Exception.Message)" 'ERR'
    }
    exit 1
}

# --- Architecture detection ---
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
$assetPattern = "^brave-v.*-win32-$arch\.zip$"
Write-Log "Target architecture: $arch"

$selectedAsset = $null
$selectedRelease = $null
$selectedVersion = $null
foreach ($r in $releases) {
    if ($r.name -notmatch $channelKeyword) { continue }
    if ($Channel -eq 'stable' -and $r.prerelease) { continue }
    $a = $r.assets | Where-Object { $_.name -match $assetPattern } | Select-Object -First 1
    if ($a) {
        $selectedAsset = $a
        $selectedRelease = $r
        $selectedVersion = [Version]($r.tag_name.TrimStart('v'))
        break
    }
}

if (-not $selectedAsset) {
    Write-Log "No $Channel release with a win32-$arch zip asset found." 'ERR'
    exit 1
}
$sizeMB = [math]::Round($selectedAsset.size / 1MB, 1)
Write-Log "Latest $Channel : $selectedVersion ($($selectedAsset.name), $sizeMB MB)"

# --- Skip if already current ---
if ($currentVersion -and -not $Force -and $currentVersion -ge $selectedVersion) {
    Write-Log "Already up-to-date ($currentVersion >= $selectedVersion). Use -Force to reinstall."
    exit 0
}

# --- Download to temp ---
$tempZip = Join-Path $env:TEMP $selectedAsset.name
if (Test-Path $tempZip) { Remove-Item $tempZip -Force }
Write-Log "Downloading to $tempZip..."
try {
    Import-Module BitsTransfer -ErrorAction Stop
    Start-BitsTransfer -Source $selectedAsset.browser_download_url -Destination $tempZip `
        -DisplayName "Brave $Channel $selectedVersion" -ErrorAction Stop
    Write-Log "Downloaded via BITS"
}
catch {
    Write-Log "BITS failed ($($_.Exception.Message)), falling back to Invoke-WebRequest" 'WARN'
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $selectedAsset.browser_download_url -OutFile $tempZip -UseBasicParsing -ErrorAction Stop
        Write-Log "Downloaded via Invoke-WebRequest"
    }
    catch {
        Write-Log "Download failed: $($_.Exception.Message)" 'ERR'
        exit 1
    }
}
Unblock-File -Path $tempZip -ErrorAction SilentlyContinue

# --- Best-effort SHA256 verification from release notes ---
if ($selectedRelease.body) {
    $hashLine = $selectedRelease.body -split "`n" |
        Where-Object { $_ -match [regex]::Escape($selectedAsset.name) -and $_ -match '[A-Fa-f0-9]{64}' } |
        Select-Object -First 1
    if ($hashLine -and $hashLine -match '([A-Fa-f0-9]{64})') {
        $expected = $matches[1].ToUpper()
        $actual = (Get-FileHash $tempZip -Algorithm SHA256).Hash.ToUpper()
        if ($expected -ne $actual) {
            Write-Log "SHA256 mismatch! expected=$expected actual=$actual" 'ERR'
            Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
            exit 1
        }
        Write-Log "SHA256 verified"
    }
    else {
        Write-Log "SHA256 not published in release notes - skipping integrity check" 'WARN'
    }
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
        Write-Log "Could not inspect/kill PID $($_.Id): $($_.Exception.Message)" 'WARN'
    }
}
if ($killed.Count) {
    Write-Log "Stopped portable processes: $($killed -join ', ')"
    Start-Sleep -Seconds 2
}

# --- Atomic swap: extract to app.new, rename app -> app.old, app.new -> app ---
$appNew = "$appDir.new"
$appOld = "$appDir.old"

if (Test-Path $appNew) { Remove-Item $appNew -Recurse -Force }
if (Test-Path $appOld) { Remove-Item $appOld -Recurse -Force }

Write-Log "Extracting to $appNew..."
try {
    Expand-Archive -Path $tempZip -DestinationPath $appNew -Force
}
catch {
    Write-Log "Extract failed: $($_.Exception.Message)" 'ERR'
    Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
    exit 1
}

# Flatten if the zip contained a single top-level dir
$topLevel = Get-ChildItem $appNew
if ($topLevel.Count -eq 1 -and $topLevel[0].PSIsContainer) {
    Write-Log "Flattening single top-level dir: $($topLevel[0].Name)"
    $inner = $topLevel[0].FullName
    Get-ChildItem $inner -Force | Move-Item -Destination $appNew -Force
    Remove-Item $inner -Force
}

if (-not (Test-Path (Join-Path $appNew 'brave.exe'))) {
    Write-Log "Extracted bundle is missing brave.exe - aborting swap" 'ERR'
    Remove-Item $appNew -Recurse -Force
    Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
    exit 1
}

# --- Authenticode signature verification on extracted brave.exe ---
$newBraveExe = Join-Path $appNew 'brave.exe'
try {
    $sig = Get-AuthenticodeSignature -FilePath $newBraveExe -ErrorAction Stop
    if ($sig.Status -eq 'Valid') {
        $thumbprint = $sig.SignerCertificate.Thumbprint
        $knownThumbs = @(
            '8903F2BD47465A4F0F080AA7CEEC31A31B74DE42',
            'F8AC5F11DE7E26383B7A389FC19A2613835799D7'
        )
        if ($thumbprint -in $knownThumbs) {
            Write-Log "Authenticode verified (Brave Software, Inc.)"
        }
        else {
            Write-Log "Authenticode valid but unknown certificate thumbprint: $thumbprint (possible cert rotation)" 'WARN'
        }
    }
    else {
        Write-Log "Authenticode verification FAILED on brave.exe: $($sig.StatusMessage)" 'ERR'
        Remove-Item $appNew -Recurse -Force
        Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
        exit 1
    }
}
catch {
    Write-Log "Could not check Authenticode signature: $($_.Exception.Message)" 'WARN'
}

Write-Log "Swapping app directories..."
if (Test-Path $appDir) {
    try {
        Rename-Item -Path $appDir -NewName 'app.old' -Force -ErrorAction Stop
    }
    catch {
        Write-Log "Could not rename existing app\ (still locked?): $($_.Exception.Message)" 'ERR'
        Remove-Item $appNew -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
        exit 1
    }
}
try {
    Rename-Item -Path $appNew -NewName 'app' -Force -ErrorAction Stop
}
catch {
    Write-Log "Could not promote app.new - restoring app.old: $($_.Exception.Message)" 'ERR'
    if (Test-Path $appOld) { Rename-Item -Path $appOld -NewName 'app' -Force -ErrorAction SilentlyContinue }
    Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
    exit 1
}
if (Test-Path $appOld) {
    Write-Log "Previous version retained at app.old (use -Rollback to restore)"
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
        Write-Log "Updated portapp.json -> version=$selectedVersion"
    }
    catch {
        Write-Log "Could not update portapp.json: $($_.Exception.Message)" 'WARN'
    }
}

# --- Cleanup + verify ---
Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
$installedNow = (Get-Item $braveExe).VersionInfo.ProductVersion
Write-Log "Done. Brave $Channel updated: $currentVersion -> $installedNow"
Send-Toast 'Brave Portable Updater' "Updated: $currentVersion -> $installedNow"
exit 0
