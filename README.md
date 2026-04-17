# Huey Magoo's Signage Heartbeat Agent

**Audience:** Stream engineering / QA reviewers.
**Purpose:** Give Huey Magoo's IT visibility into which in-store
signage media players are online, so that outages raise Freshdesk
tickets automatically instead of being discovered by a manager walking
past a dark menu board.

---

## 1. TL;DR

| Question | Answer |
|---|---|
| What runs on the device? | A PowerShell script (~150 lines) fired by Windows Task Scheduler every 5 minutes. |
| What does it do each run? | One HTTPS POST to Huey Magoo's IT portal with `{hostname, MAC, timestamp, agentVersion}`. Nothing else. |
| Process model? | Short-lived process (≤2 seconds), runs as `NT AUTHORITY\SYSTEM` in **Windows Session 0** (no desktop interaction possible). |
| Inbound connections? | None. Agent is outbound-only. No listening ports. No service. |
| Persistent footprint? | One Scheduled Task + one directory under `C:\ProgramData\HueyMagoos\SignageHeartbeat` (script + config + ≤768 KB rolling logs). No registry keys, no firewall rules, no services, no startup items. |
| Can it interfere with full-screen sign.me playback? | No. Session 0 isolation makes it architecturally impossible for the agent to render to the display. |
| How do you remove it for RMA? | `uninstall.ps1` (elevated). Exits non-zero if anything is left behind. |

---

## 2. Business context

Huey Magoo's operates ~90 restaurant locations. Each location runs
multiple digital menu boards and digital marketing boards powered by
Windows media players managed by Stream via the sign.me CMS. When one
of these players goes offline (power, network, hardware, Windows
update, whatever), there is currently no way for Huey's IT to know
until a store manager reports it.

The existing "location health" portal already tracks the store's
primary ISP and 4G backup using outbound pings from AWS. Those pings
can't reach the media players (NAT'd behind the store router, ICMP
blocked, no inventory of per-player private IPs), so we are shipping
a small agent that pings *outward* from each device. Absence of the
heartbeat is the failure signal.

This is a standard "phone home" pattern, implemented in the minimum
code necessary.

---

## 3. What the agent does on each 5-minute tick

1. Reads `config.json` from its install directory (API URL + shared
   API key).
2. Reads the primary physical network adapter's MAC address via
   `Get-NetAdapter` (prefers the adapter carrying the default route).
3. Reads `$env:COMPUTERNAME`.
4. POSTs one JSON body to the configured URL over HTTPS (TLS 1.2
   forced):
   ```json
   {
     "hostname": "SIGNAGE-01",
     "macAddress": "AA:BB:CC:DD:EE:FF",
     "timestamp": "2026-04-17T14:23:45Z",
     "agentVersion": "1.0.0"
   }
   ```
5. Writes one line to the local log (`heartbeat.log`) recording the
   result (OK or error).
6. Exits with code 0 in all cases (including network errors, to
   avoid false-positive Task Scheduler failure notifications).

That is the entire behavior. There is no branching logic, no
updater, no remote command channel, no telemetry beyond the above.

---

## 4. What the agent does NOT do

- **Does not collect or transmit:** screen contents, playback
  history, video analytics, user input, audio, file contents, process
  lists, installed software, system configuration, sign.me state, or
  any data beyond hostname and NIC MAC.
- **Does not open any listening port.** No inbound connections ever.
- **Does not install a persistent service.** There is no
  `sc.exe create`, no `New-Service`, no auto-start registry key.
  Execution is driven exclusively by a Task Scheduler entry.
- **Does not modify firewall rules, Group Policy, Windows Updates
  settings, or any OS configuration.**
- **Does not write to HKCU / HKLM** outside what Task Scheduler
  itself writes to register its own task.
- **Does not self-update.** The script on disk is the script that
  ships. Any new version requires a new deployment action by Stream.
- **Does not execute code fetched from the network.** The POST is
  one-way; the server's response is logged as a status line and
  otherwise ignored.

---

## 5. Architecture

```
Media player (Windows 10/11, Session 1+)
+-----------------------------------+
| sign.me full-screen playback     |  <-- runs in user session,
| (primary workload, not touched)  |      owns the display
+-----------------------------------+
Session 0 (services, isolated from desktop)
+-----------------------------------+
| Windows Task Scheduler            |
|   +- "HueyMagoos-SignageHeartbeat"|
|      Trigger: every 5 min         |
|      Principal: NT AUTHORITY\SYSTEM |
|      Action: powershell.exe -File heartbeat.ps1 |
+-----------------------------------+
          |
          | HTTPS (TLS 1.2), outbound only, port 443
          v
+-----------------------------------+
| Huey Magoo's IT portal            |
| api.hueymagoos.com                |
|  POST /location-health/signage-heartbeat |
+-----------------------------------+
```

---

## 6. Install procedure

Stream loads the agent on each media player via TeamViewer. Two
supported paths; (a) is recommended for production.

### (a) One-liner installer (recommended)

From an **elevated PowerShell** on the media player:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
iwr -useb https://github.com/Huey-Magoos-IT/signage-heartbeat-agent/releases/latest/download/install-latest.ps1 | iex
```

`install-latest.ps1` (visible in this repo) fetches the latest
release metadata, downloads the release zip **plus its SHA-256
checksum**, refuses to proceed on checksum mismatch, unpacks, and
runs `install.ps1`. If `config.json` doesn't already exist at the
install location it prompts for the API key.

### (b) Manual file copy (offline / audit)

1. Download the release zip + `.sha256` file from
   [Releases](https://github.com/Huey-Magoos-IT/signage-heartbeat-agent/releases/latest).
2. Verify the SHA-256 against the published checksum file.
3. Unpack to a temp folder.
4. Create `config.json` from `config.example.json` with the real
   `apiUrl` and `apiKey` (provided by Huey's IT out-of-band, not via
   email).
5. Open an **elevated PowerShell** in that folder.
6. Run:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install.ps1
   ```
4. Expected output:
   ```
   Huey Magoo's Signage Heartbeat Agent - Install
   [OK] Staged files to C:\ProgramData\HueyMagoos\SignageHeartbeat
   [OK] Restricted config.json ACL to SYSTEM + Administrators
   [OK] Scheduled task 'HueyMagoos-SignageHeartbeat' created
   [OK] Initial heartbeat task state: Ready
   Install complete.
   ```
5. Verify by watching `C:\ProgramData\HueyMagoos\SignageHeartbeat\heartbeat.log`
   — within ~60 seconds you should see an `OK heartbeat accepted`
   entry.

**What install.ps1 does, precisely:**
- Creates `C:\ProgramData\HueyMagoos\SignageHeartbeat\` if absent.
- Copies `heartbeat.ps1` and `config.json` into that directory.
- Restricts `config.json` ACL to SYSTEM + Administrators (the shared
  API key is a secret).
- Registers a Task Scheduler task named `HueyMagoos-SignageHeartbeat`:
  - Principal: `NT AUTHORITY\SYSTEM`, LogonType ServiceAccount
  - Trigger: repeats every 5 minutes, indefinitely
  - Action: `powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -NoProfile -NonInteractive -File <path>`
  - Settings: 2-minute execution time limit, 3 retries with 1-minute
    interval on failure, only one instance at a time
- Triggers the task once so the first heartbeat fires immediately.

---

## 7. Uninstall procedure (RMA / refurb)

Before any media player is returned to Stream for RMA or
refurbishing, run the uninstaller so nothing Huey-specific ships with
the device:

1. Open an **elevated PowerShell** anywhere (the uninstaller does not
   need the original install files).
2. If the uninstaller is not already on the device, copy
   `uninstall.ps1` to a temp folder.
3. Run:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
   ```
4. Expected output:
   ```
   [OK] Removed scheduled task
   [OK] Removed C:\ProgramData\HueyMagoos\SignageHeartbeat (script, config, and logs)
   [OK] No scheduled tasks remain
   [OK] No files remain in C:\ProgramData\HueyMagoos\SignageHeartbeat
   [OK] No registry keys, services, firewall rules, or startup items were ever created by this agent
   Device is clean. Safe to RMA / refurbish.
   ```
5. The script exits `0` on success and **exits `1` with a red FAIL
   banner** if anything is left behind. If you see FAIL, do not RMA
   the device until the residual artifact is resolved.

**What the uninstaller removes:**
- The Scheduled Task `HueyMagoos-SignageHeartbeat`.
- The directory `C:\ProgramData\HueyMagoos\SignageHeartbeat\` and all
  its contents (script, config with API key, all log files).

**What was never created, and therefore needs no cleanup:**
- No Windows services.
- No registry keys outside what Task Scheduler manages for its own
  task (removed automatically by `Unregister-ScheduledTask`).
- No firewall rules (inbound or outbound).
- No startup items, Run keys, or scheduled restart triggers.
- No files under `Program Files`, `Program Files (x86)`,
  `AppData`, or any user profile directory.
- No environment variables (machine or user scope).
- No certificates added to any store.

If Stream's refurb QA process requires a separate attestation of
removal, the uninstaller's zero exit code and OK log lines can be
captured as evidence.

---

## 8. Data sent to Huey Magoo's

**Every 5 minutes, one POST:**
- Request URL: `https://api.hueymagoos.com/location-health/signage-heartbeat`
  (TLS 1.2+)
- Request headers: `Authorization: Bearer <shared API key>`,
  `Content-Type: application/json`
- Request body: `{hostname, macAddress, timestamp, agentVersion}` as
  shown in section 3.
- Response body: `{locationName, deviceId, status, firstSeenAt}` or
  an error message. Logged locally, otherwise ignored.

**What Huey Magoo's does with the data:**
- Writes one row per device to the `magoos-location-health` DynamoDB
  table (one row per MAC). The MAC serves as the per-device
  identifier across reboots.
- Resolves which store the heartbeat came from by matching the
  request's public source IP against the store's ISP / 4G IP
  (already tracked in the same table for existing network-health
  monitoring).
- Surfaces the status on the internal location-health dashboard.
- Opens a single Freshdesk ticket per store after 15 minutes of
  missed heartbeats (aggregated — one store-wide ticket covers all
  offline players at that location). The ticket auto-closes when all
  players resume heartbeats.

**What Huey Magoo's does NOT receive:**
- No data about what is being displayed.
- No data about sign.me internals, playback state, or CMS activity.
- No screenshots, no video, no audio.
- No user activity (there is no logged-in user in Session 0 context).
- No other network, system, or hardware information beyond the MAC
  of the primary NIC.

---

## 9. Resource footprint

Measured on a baseline Windows 10 media-player-class device.

| Resource | Per tick (every 5 min) | Steady-state |
|---|---|---|
| CPU | ~300 ms of one core during PowerShell startup, ~0 ms in between | Idle |
| Memory | ~40-60 MB during the ~1-2 second run, freed on exit | 0 MB |
| Disk | ≤ ~100 bytes written to `heartbeat.log` per run | ≤ 768 KB total (3 rotating log files), bounded |
| Network | ~400 bytes up, ~200 bytes down, one HTTPS connection, closes on exit | 0 B/s |
| Persistent processes | 0 | 0 |

At worst this is a single dropped frame every 5 minutes on the
weakest device. On anything modern it is unmeasurable.

---

## 10. Security model

- **Auth:** HTTP Bearer token from a fleet-wide shared API key stored
  in `config.json`. The key has no privileges outside writing
  heartbeat rows — it cannot read any data, cannot modify any other
  resource, and cannot touch any other Huey Magoo's system.
- **Defense in depth:** The server also validates that the source IP
  of the request matches a known store's public IP (already tracked
  independently). A leaked key used from an unknown network returns
  `404` even with the correct Bearer token.
- **Blast radius if the key leaks:** An attacker on one of Huey's
  store networks with the key could falsely mark that store's
  signage as online (suppressing a legitimate alert). They cannot
  read any data, cannot see other stores, and cannot affect any
  other system.
- **Key rotation:** Huey's IT can regenerate the key at any time and
  push a new `config.json` via the same TeamViewer workflow used for
  install. No server-side code change required; the env var is
  updated and the process restarted.
- **Transport:** TLS 1.2 is forced via
  `[System.Net.ServicePointManager]::SecurityProtocol` for older
  Windows builds.
- **ACL:** `install.ps1` sets NTFS ACL on `config.json` to SYSTEM +
  BUILTIN\Administrators only, protecting the API key from
  unprivileged users on the device.

---

## 11. Display / UX safety

The agent runs under **`NT AUTHORITY\SYSTEM`** with
`LogonType ServiceAccount` in the Scheduled Task principal. On
Windows Vista and later, SYSTEM processes run in **Session 0**,
which is architecturally isolated from any interactive desktop
session (Sessions 1+). A Session 0 process cannot attach to,
draw on, or interact with a logged-in user's desktop. This is
enforced by the Windows kernel's session-isolation mechanism, not
by agent configuration.

In addition, the PowerShell invocation explicitly passes
`-WindowStyle Hidden -NoProfile -NonInteractive` as belt-and-suspenders,
but those flags are redundant given Session 0 isolation.

The sign.me full-screen playback runs in the logged-in user's
interactive session (Session 1+). There is no mechanism by which the
heartbeat agent can draw to that session's screen, inject input,
change focus, or otherwise interfere with playback.

---

## 12. Logging

Logs are written to
`C:\ProgramData\HueyMagoos\SignageHeartbeat\heartbeat.log`. One line
per heartbeat attempt:

```
2026-04-17T14:23:45-04:00 [OK] heartbeat accepted - location=Oviedo, FL mac=AA:BB:CC:DD:EE:FF
2026-04-17T14:28:45-04:00 [ERROR] heartbeat failed: Unable to connect to the remote server
```

**Rotation:** When `heartbeat.log` exceeds 256 KB it is rotated to
`heartbeat.log.1`, which in turn shifts to `heartbeat.log.2`. Files
older than that are deleted. Total disk footprint is bounded at
~768 KB across the three files, regardless of uptime. This is
sufficient to retain roughly 6-8 weeks of heartbeat history for
debugging.

The log file contains **no secrets** — the API key is never written
to the log, only to `config.json` (which has restricted ACL as
described above).

---

## 13. Failure modes

| Scenario | Agent behavior |
|---|---|
| Network outage (no internet) | Logs `[ERROR]`, exits 0. Next tick retries in 5 min. No alerting on the device. |
| API key wrong (401) | Logs `[ERROR]`, exits 0. Server-side will not record the heartbeat. |
| Source IP not known to server (404) | Logs `[ERROR]`, exits 0. Happens if the store's public IP changed — Huey's IT needs to update their inventory. |
| Server 5xx | Logs `[ERROR]`, exits 0. Next tick retries. |
| `config.json` missing | Logs `[ERROR]`, exits 0. Re-run installer to recreate. |
| `config.json` unreadable | Logs `[ERROR]`, exits 0. |
| Log directory unwritable | Script still runs, but logs silently dropped. |
| Scheduled Task fails to start | Task Scheduler's own 3-retry policy kicks in (1-minute interval). |
| Power loss during a run | Next scheduled tick (up to 5 min later) fires normally. No state to corrupt. |

In all failure modes, the agent has zero effect on anything else
running on the device.

---

## 14. Version history

| Version | Date | Change |
|---|---|---|
| 1.0.0 | 2026-04-17 | Initial release. |

The version string is compiled into `heartbeat.ps1` as
`$AgentVersion` and reported with every heartbeat, so Huey Magoo's
IT can confirm which version is deployed where.

---

## 15. Source, build, and contact

- **Source code:** The agent lives under `agents/signage-heartbeat/`
  in the `Huey-Magoos-IT/magooos-site` GitHub repository. The
  commit hash of the version shipped to Stream can be provided on
  request. There is no build step — the three `.ps1` files and the
  `config.json` are the deployment artifact.
- **Signing:** Current release is unsigned. If Stream's QA requires
  Authenticode signing, Huey's IT can arrange that and re-ship.
- **Contact:** Jon Hance, Huey Magoo's IT — `jhance@hueymagoos.com`.
  For urgent issues, the Huey Magoo's IT support line is
  `727-425-3062`.
