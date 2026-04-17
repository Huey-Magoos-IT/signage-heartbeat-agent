# Huey Magoo's Signage Heartbeat Agent - Install Latest Release
#
# One-liner installer that downloads the latest signed release zip
# from this public repo, verifies its SHA-256, unpacks it, and
# invokes install.ps1. Designed to be run via TeamViewer on each
# media player with a single command:
#
#   Set-ExecutionPolicy -Scope Process Bypass -Force; `
#     iwr -useb https://github.com/Huey-Magoos-IT/signage-heartbeat-agent/releases/latest/download/install-latest.ps1 | iex
#
# Before running this, Stream must place a valid config.json at
# C:\ProgramData\HueyMagoos\SignageHeartbeat\config.json (copy of
# config.example.json with real apiUrl + apiKey). If not present
# yet, the script will prompt for the API key and write the file.
#
# Requires: elevated PowerShell (Administrator).
#
# Exit codes:
#   0 = install succeeded
#   1 = download / verification / install failed

#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"
$RepoOwner = "Huey-Magoos-IT"
$RepoName = "signage-heartbeat-agent"
$StagingDir = Join-Path $env:TEMP "huey-signage-install"

# Force TLS 1.2 on older Windows builds where it isn't default
[System.Net.ServicePointManager]::SecurityProtocol = `
    [System.Net.SecurityProtocolType]::Tls12

Write-Host "Huey Magoo's Signage Heartbeat - One-Liner Installer" -ForegroundColor Cyan
Write-Host "-----------------------------------------------------"

# 1. Fetch latest release metadata from GitHub
Write-Host "  [..] Fetching latest release info..."
$api = "https://api.github.com/repos/$RepoOwner/$RepoName/releases/latest"
$release = Invoke-RestMethod -Uri $api -Headers @{ "User-Agent" = "huey-signage-installer" }
$version = $release.tag_name -replace "^v", ""
Write-Host "  [OK] Latest release: v$version"

$zipAsset = $release.assets | Where-Object { $_.name -like "huey-signage-agent-*.zip" } | Select-Object -First 1
$sumAsset = $release.assets | Where-Object { $_.name -like "huey-signage-agent-*.sha256" } | Select-Object -First 1

if (-not $zipAsset) { throw "No zip asset found in latest release" }
if (-not $sumAsset) { throw "No SHA-256 asset found in latest release" }

# 2. Stage clean working directory
if (Test-Path $StagingDir) { Remove-Item $StagingDir -Recurse -Force }
New-Item -ItemType Directory -Path $StagingDir -Force | Out-Null

# 3. Download zip + checksum
$zipPath = Join-Path $StagingDir $zipAsset.name
$sumPath = Join-Path $StagingDir $sumAsset.name
Write-Host "  [..] Downloading $($zipAsset.name)..."
Invoke-WebRequest -Uri $zipAsset.browser_download_url -OutFile $zipPath
Invoke-WebRequest -Uri $sumAsset.browser_download_url -OutFile $sumPath
Write-Host "  [OK] Downloaded zip + checksum"

# 4. Verify SHA-256
$expected = (Get-Content $sumPath -Raw).Trim().Split()[0].ToLower()
$actual = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLower()
if ($expected -ne $actual) {
    Write-Host "  [FAIL] SHA-256 mismatch!" -ForegroundColor Red
    Write-Host "    expected: $expected" -ForegroundColor Red
    Write-Host "    actual:   $actual" -ForegroundColor Red
    throw "Checksum verification failed - refusing to run"
}
Write-Host "  [OK] SHA-256 verified: $actual"

# 5. Unpack
$unpackDir = Join-Path $StagingDir "unpacked"
Expand-Archive -Path $zipPath -DestinationPath $unpackDir -Force
Write-Host "  [OK] Unpacked"

# 6. Ensure config.json exists in unpack dir - copy from install dir
# if already present (re-install), otherwise prompt.
$existingConfig = "C:\ProgramData\HueyMagoos\SignageHeartbeat\config.json"
$targetConfig = Join-Path $unpackDir "config.json"

if (Test-Path $existingConfig) {
    Copy-Item $existingConfig $targetConfig -Force
    Write-Host "  [OK] Reusing existing config.json"
} else {
    $apiKey = Read-Host -AsSecureString "SIGNAGE_AGENT_API_KEY (provided by Huey IT out-of-band)"
    $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($apiKey))
    $apiUrl = Read-Host "API URL [https://api.hueymagoos.com/location-health/signage-heartbeat]"
    if ([string]::IsNullOrWhiteSpace($apiUrl)) {
        $apiUrl = "https://api.hueymagoos.com/location-health/signage-heartbeat"
    }
    $config = @{ apiUrl = $apiUrl; apiKey = $plain } | ConvertTo-Json
    Set-Content -Path $targetConfig -Value $config -Encoding utf8
    Write-Host "  [OK] Wrote fresh config.json"
}

# 7. Run installer
Write-Host "  [..] Running install.ps1..."
$installScript = Join-Path $unpackDir "install.ps1"
& powershell.exe -ExecutionPolicy Bypass -NoProfile -File $installScript

# 8. Cleanup staging
Remove-Item $StagingDir -Recurse -Force
Write-Host ""
Write-Host "Install-latest complete (v$version)." -ForegroundColor Green
