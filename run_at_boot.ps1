# Brave-Portable-Updater v1.1.0 - registers a Scheduled Task that runs
# Update-BravePortable.ps1 at every system startup.

# Elevation check
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Relaunching as Administrator..."
    Start-Process powershell "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$TaskName        = "BravePortableUpdate"
$TaskDescription = "Brave-Portable-Updater v1.1.0 - check for new Brave release at boot"
$ScriptDir       = Split-Path -Parent $MyInvocation.MyCommand.Definition
$TaskCommand     = Join-Path $ScriptDir "Update-BravePortable.ps1"

if (-not (Test-Path $TaskCommand)) {
    Write-Error "Update-BravePortable.ps1 not found next to run_at_boot.ps1 ($TaskCommand)"
    exit 1
}

# Warn if the script directory is writable by non-admin users (TOCTOU risk)
try {
    $acl = Get-Acl $ScriptDir
    $risky = $acl.Access | Where-Object {
        $_.IdentityReference -match '(Users|Everyone|Authenticated Users)' -and
        $_.FileSystemRights -match '(Write|Modify|FullControl)' -and
        $_.AccessControlType -eq 'Allow'
    }
    if ($risky) {
        Write-Warning "Script directory is writable by non-admin users."
        Write-Warning "A scheduled task with Highest privilege pointing here is a privilege escalation risk."
        Write-Warning "Consider moving the updater to a protected directory (e.g. C:\Tools\)."
    }
}
catch { }

$TaskTrigger  = New-ScheduledTaskTrigger -AtStartup
$TaskAction   = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$TaskCommand`" -Quiet"
$TaskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

Register-ScheduledTask -TaskName $TaskName -Description $TaskDescription `
    -Trigger $TaskTrigger -Action $TaskAction -Settings $TaskSettings `
    -RunLevel Highest -Force | Out-Null

Write-Host "Scheduled task '$TaskName' registered."
Write-Host "  Script:  $TaskCommand"
Write-Host "  Trigger: at system startup (Highest privilege, Quiet)"
Write-Host ""
Write-Host "Run now to test:    schtasks /run /tn $TaskName"
Write-Host "View status:        schtasks /query /tn $TaskName /v /fo LIST"
Write-Host "Remove later:       Unregister-ScheduledTask -TaskName $TaskName -Confirm:`$false"
