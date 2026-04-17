# Huey Magoo's - Signage Media Player Heartbeat Agent
#
# What it does:
#   Every 5 minutes (scheduled by install.ps1), this script POSTs a
#   single small JSON payload to Huey's IT portal so we know the
#   media player is online. No inbound connections, no listening
#   ports, no persistent service - just one HTTPS POST per tick.
#
# Payload:
#   { "hostname": "<computer name>",
#     "macAddress": "<primary NIC MAC>",
#     "timestamp":  "<ISO 8601 UTC>",
#     "agentVersion": "1.0.0" }
#
# Auth: Bearer token from config.json (shared fleet key)
# Store identity: the portal resolves it from the request's source IP
#   (matched against the ISP/4G IPs already catalogued per store) -
#   the device needs no store-specific config.
#
# Exit behavior: always exits 0 so Task Scheduler history stays clean.
# Errors are logged to C:\ProgramData\HueyMagoos\SignageHeartbeat\heartbeat.log

$ErrorActionPreference = "Continue"
$AgentVersion = "1.0.0"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ScriptDir "config.json"
$LogDir = "C:\ProgramData\HueyMagoos\SignageHeartbeat"
$LogPath = Join-Path $LogDir "heartbeat.log"

# Log rotation: keep 2 rolling archives (heartbeat.log.1, heartbeat.log.2)
# plus the active file. Rotate when active file exceeds 256 KB. Max
# disk footprint ~= 768 KB across all three files. At 5-min cadence
# that retains roughly 6-8 weeks of history, more than enough to
# debug any install/connectivity issue without bloating the device.
$RotateThresholdBytes = 256KB
$MaxArchives = 2

function Invoke-LogRotation {
    if (-not (Test-Path $LogPath)) { return }
    try {
        $size = (Get-Item $LogPath).Length
        if ($size -lt $RotateThresholdBytes) { return }

        # Shift archives: .(N-1) -> .N, dropping the oldest.
        for ($i = $MaxArchives; $i -ge 2; $i--) {
            $src = "$LogPath.$($i - 1)"
            $dst = "$LogPath.$i"
            if (Test-Path $src) {
                if (Test-Path $dst) { Remove-Item $dst -Force }
                Move-Item $src $dst -Force
            }
        }
        # Current -> .1
        $firstArchive = "$LogPath.1"
        if (Test-Path $firstArchive) { Remove-Item $firstArchive -Force }
        Move-Item $LogPath $firstArchive -Force
    } catch {
        # Rotation failure should never block a heartbeat; next tick
        # will retry. Best-effort write to stderr (which is already
        # swallowed in the scheduled-task context).
        Write-Error "log rotation failed: $($_.Exception.Message)"
    }
}

function Write-Log {
    param([string]$Level, [string]$Message)
    if (-not (Test-Path $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }
    $ts = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK")
    "$ts [$Level] $Message" | Out-File -FilePath $LogPath -Append -Encoding utf8
}

# Rotate at the start of each invocation (not per log line) so
# rotation overhead is exactly one stat + at most two renames per
# 5-min tick, regardless of how many lines the script writes.
Invoke-LogRotation

try {
    if (-not (Test-Path $ConfigPath)) {
        Write-Log "ERROR" "config.json not found at $ConfigPath"
        exit 0
    }
    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

    if ([string]::IsNullOrWhiteSpace($config.apiUrl)) {
        Write-Log "ERROR" "config.apiUrl is empty"
        exit 0
    }
    if ([string]::IsNullOrWhiteSpace($config.apiKey)) {
        Write-Log "ERROR" "config.apiKey is empty"
        exit 0
    }

    # Pick the primary physical NIC that is currently Up. If multiple,
    # prefer the one used for the default route.
    $adapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq "Up" }
    if (-not $adapters) {
        Write-Log "WARN" "No physical network adapters are Up"
        exit 0
    }

    $primary = $null
    try {
        $defaultRoute = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
            Sort-Object -Property RouteMetric | Select-Object -First 1
        if ($defaultRoute) {
            $primary = $adapters | Where-Object { $_.ifIndex -eq $defaultRoute.ifIndex } | Select-Object -First 1
        }
    } catch {
        # fall through to simple pick
    }
    if (-not $primary) {
        $primary = $adapters | Select-Object -First 1
    }

    $mac = $primary.MacAddress  # format: "AA-BB-CC-DD-EE-FF"
    if ([string]::IsNullOrWhiteSpace($mac)) {
        Write-Log "WARN" "Primary adapter $($primary.Name) has no MAC"
        exit 0
    }

    $payload = @{
        hostname     = $env:COMPUTERNAME
        macAddress   = $mac
        timestamp    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        agentVersion = $AgentVersion
    } | ConvertTo-Json -Compress

    $headers = @{
        "Authorization" = "Bearer $($config.apiKey)"
        "Content-Type"  = "application/json"
    }

    # Force TLS 1.2 on older Windows builds where it isn't default
    [System.Net.ServicePointManager]::SecurityProtocol = `
        [System.Net.SecurityProtocolType]::Tls12

    $response = Invoke-RestMethod `
        -Uri $config.apiUrl `
        -Method Post `
        -Headers $headers `
        -Body $payload `
        -TimeoutSec 30 `
        -ErrorAction Stop

    $locName = $response.locationName
    $okMsg = "heartbeat accepted - location=$locName mac=$mac"
    Write-Log "OK" $okMsg
    exit 0
}
catch {
    $err = $_.Exception.Message
    Write-Log "ERROR" "heartbeat failed: $err"
    # Swallow the error so Task Scheduler doesn't mark the task as
    # failed. Transient network issues are expected between ticks.
    exit 0
}
