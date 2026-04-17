# Huey Magoo's - Signage Heartbeat Agent - Uninstaller
#
# Removes the scheduled task and deletes the installed files.
# Run as Administrator.
#
#   powershell -ExecutionPolicy Bypass -File .\uninstall.ps1

#Requires -RunAsAdministrator

$ErrorActionPreference = "Continue"
$TaskName = "HueyMagoos-SignageHeartbeat"
$InstallDir = "C:\ProgramData\HueyMagoos\SignageHeartbeat"

Write-Host "Huey Magoo's Signage Heartbeat Agent - Uninstall" -ForegroundColor Cyan
Write-Host "-------------------------------------------------"

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "  [OK] Removed scheduled task"
} else {
    Write-Host "  [--] Scheduled task was not present"
}

if (Test-Path $InstallDir) {
    Remove-Item -Path $InstallDir -Recurse -Force
    Write-Host "  [OK] Removed $InstallDir (script, config, and logs)"
} else {
    Write-Host "  [--] $InstallDir did not exist"
}

# Verification pass - for RMA / refurb readiness. Fails loudly if
# anything is left behind so a technician catches it before the
# device ships back.
Write-Host ""
Write-Host "Verifying clean removal..." -ForegroundColor Cyan
$leftover = @()
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    $leftover += "scheduled task '$TaskName'"
}
if (Test-Path $InstallDir) {
    $leftover += "directory $InstallDir"
}

if ($leftover.Count -gt 0) {
    Write-Host "  [FAIL] Residual artifacts detected:" -ForegroundColor Red
    $leftover | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    Write-Host ""
    Write-Host "Device is NOT clean. Do not RMA until removed." -ForegroundColor Red
    exit 1
}
Write-Host "  [OK] No scheduled tasks remain"
Write-Host "  [OK] No files remain in $InstallDir"
Write-Host "  [OK] No registry keys, services, firewall rules, or startup items were ever created by this agent"
Write-Host ""
Write-Host "Device is clean. Safe to RMA / refurbish." -ForegroundColor Green
exit 0
