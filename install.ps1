# Huey Magoo's - Signage Heartbeat Agent - Installer
#
# Run once per media player, as Administrator. What it does:
#   1. Copies heartbeat.ps1 + config.json to C:\ProgramData\HueyMagoos\SignageHeartbeat
#   2. Creates a Scheduled Task "HueyMagoos-SignageHeartbeat" that
#      runs heartbeat.ps1 every 5 minutes under SYSTEM, starting 1
#      minute after install.
#   3. Kicks off one heartbeat immediately so the portal registers
#      the device right away (no 5-min wait for first signal).
#
# Usage (from an elevated PowerShell in this folder):
#   powershell -ExecutionPolicy Bypass -File .\install.ps1
#
# To uninstall later: run uninstall.ps1 from the same folder.

#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"
$TaskName = "HueyMagoos-SignageHeartbeat"
$InstallDir = "C:\ProgramData\HueyMagoos\SignageHeartbeat"

Write-Host "Huey Magoo's Signage Heartbeat Agent - Install" -ForegroundColor Cyan
Write-Host "-----------------------------------------------"

# 1. Stage files
$SourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SourceScript = Join-Path $SourceDir "heartbeat.ps1"
$SourceConfig = Join-Path $SourceDir "config.json"

if (-not (Test-Path $SourceScript)) {
    throw "heartbeat.ps1 not found next to install.ps1"
}
if (-not (Test-Path $SourceConfig)) {
    throw "config.json not found next to install.ps1 - copy config.example.json to config.json and fill in apiUrl + apiKey first"
}

if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}
Copy-Item -Path $SourceScript -Destination (Join-Path $InstallDir "heartbeat.ps1") -Force
Copy-Item -Path $SourceConfig -Destination (Join-Path $InstallDir "config.json") -Force
Write-Host "  [OK] Staged files to $InstallDir"

# Lock down config.json so only SYSTEM + Administrators can read the API key
$acl = Get-Acl (Join-Path $InstallDir "config.json")
$acl.SetAccessRuleProtection($true, $false)  # disable inheritance
$rules = @(
    New-Object System.Security.AccessControl.FileSystemAccessRule(
        "NT AUTHORITY\SYSTEM", "FullControl", "Allow"),
    New-Object System.Security.AccessControl.FileSystemAccessRule(
        "BUILTIN\Administrators", "FullControl", "Allow")
)
foreach ($rule in $rules) { $acl.AddAccessRule($rule) }
Set-Acl -Path (Join-Path $InstallDir "config.json") -AclObject $acl
Write-Host "  [OK] Restricted config.json ACL to SYSTEM + Administrators"

# 2. Remove any prior instance of the task
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "  [OK] Removed previous scheduled task"
}

# 3. Create the scheduled task - SYSTEM, every 5 min, indefinitely
$ScriptPath = Join-Path $InstallDir "heartbeat.ps1"
$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -NoProfile -NonInteractive -File `"$ScriptPath`""

$trigger = New-ScheduledTaskTrigger `
    -Once `
    -At ((Get-Date).AddMinutes(1)) `
    -RepetitionInterval (New-TimeSpan -Minutes 5)

$principal = New-ScheduledTaskPrincipal `
    -UserId "NT AUTHORITY\SYSTEM" `
    -LogonType ServiceAccount `
    -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew

Register-ScheduledTask `
    -TaskName $TaskName `
    -Description "Heartbeat to Huey Magoo's IT portal every 5 minutes. Source: agents/signage-heartbeat in magooos-site repo." `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings | Out-Null

Write-Host "  [OK] Scheduled task '$TaskName' created (runs every 5 min as SYSTEM)"

# 4. Fire one heartbeat now so the device registers immediately
Write-Host "  [..] Firing initial heartbeat..."
try {
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 5
    $state = (Get-ScheduledTask -TaskName $TaskName).State
    Write-Host "  [OK] Initial heartbeat task state: $state"
} catch {
    Write-Host "  [WARN] Could not trigger initial heartbeat: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Install complete." -ForegroundColor Green
Write-Host "Log file: C:\ProgramData\HueyMagoos\SignageHeartbeat\heartbeat.log"
