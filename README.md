# 🚀 SyncPulse

> **Industrial-strength, automated SFTP continuous sync engine and system tray monitor for Windows developers.**

[![Windows](https://img.shields.io/badge/Platform-Windows%2010%20%7C%2011-0078D6?logo=windows&logoColor=white)](https://microsoft.com/windows)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B%20%7C%207%2B-5391FE?logo=powershell&logoColor=white)](https://github.com/PowerShell/PowerShell)
[![WinSCP](https://img.shields.io/badge/Engine-WinSCP%206.x-blue?logo=winscp&logoColor=white)](https://winscp.net/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

**SyncPulse** bridges the gap between local development and remote web servers. It continuously monitors multiple local website directories, automatically uploading modified and newly created files to remote SFTP servers in real time using WinSCP's robust transport protocol.

Includes an **interactive Windows System Tray controller** with real-time status indicators, auto-healing background watchers, and a built-in **Site Manager GUI**.

---

## ✨ Features

- ⚡ **Real-Time Continuous Sync (`keepuptodate`)**: Detects file creation, modification, and deletion at the OS kernel level and synchronizes changes instantly to remote servers.
- 🚦 **Color-Coded Live Tray Status**:
  - 🟢 **Green**: All desired watchers are active and running normally.
  - 🟡 **Yellow**: Warning state — one or more watchers are down, reconnecting, or failed.
  - ⚪ **Grey**: Idle state — all watchers stopped.
- 🎛️ **Interactive Site Manager GUI**:
  - Add, edit, and remove monitored websites directly from the tray icon.
  - Native **Browse...** folder picker for selecting local project roots.
  - Masked password input with a live toggle.
  - Dynamic live reloading: modifying sites instantly updates tray menus and watchers without restarting the app.
- 🛡️ **Fault-Tolerant Auto-Healing**:
  - Resilient continuous watching mode (`option batch continue`) handles temporary network drops, Wi-Fi switching, and file lock contentions without dying.
  - Smart exponential backoff and consecutive failure thresholds prevent infinite restart loops.
  - Silent routine reconnections with toast notifications reserved only for persistent problems.
- 🛑 **Windows Reserved Device Protection**:
  - Built-in automatic exclusion for DOS/Windows device names (`NUL`, `CON`, `PRN`, `AUX`, `COM1-9`, `LPT1-9`).
  - Completely immune to crashes (Win32 Error 87) caused by accidental Git redirection (`> nul`) creating literal `NUL` files.
- 📡 **Active SSH Keepalive & TCP Probing**:
  - Employs SSH Dummy Protocol Requests (`keepalive@openssh.com`) and OS-level TCP probes (`PingType=2`) every 30 seconds.
  - Generates true bidirectional SSH traffic, keeping NAT router states and stateful firewalls active indefinitely.
- 🧹 **Zero-Zombie Process Management**:
  - Implements process tree termination (`taskkill /T /F`) to cleanly stop `WinSCP.com` along with its child `WinSCP.exe` worker processes.
- 🔒 **Secure Central Configuration**:
  - All locations and credentials reside in a centralized, git-ignored `sites.json`.
  - Cryptographic host fingerprint pinning support via `known-hosts.json` for strict MITM defense.

---

## 📋 Requirements

| Requirement | Details |
| :--- | :--- |
| **Operating System** | Windows 10 / Windows 11 (x64 / ARM64) |
| **PowerShell** | PowerShell 5.1 (Built into Windows) or PowerShell 7+ |
| **WinSCP** | WinSCP 5.19+ or 6.x (Console + GUI) |
| **Remote Server** | Any standard SFTP (SSH File Transfer Protocol) or SFTPGo server |

### Installing WinSCP
If WinSCP is not yet installed on your system, install it in seconds via Windows Package Manager:
```powershell
winget install --id WinSCP.WinSCP -e
```

---

## 🚀 Quick Start Guide

### 1. Installation & First-Time Setup
Clone or copy this repository to your preferred tools location (e.g. `D:\websites\_common_scripts\deploy`):
```powershell
git clone https://github.com/your-username/syncpulse.git D:\websites\_common_scripts\deploy
```

Run **`install_winscp.bat`** (or double-click it in Windows Explorer):
* Automatically checks if WinSCP is installed.
* If missing, installs WinSCP via `winget` unattended.
* Automatically launches the SyncPulse system tray monitor.

### 2. Launch the System Tray Controller
To start the tray at any time without reinstalling:
* Double-click **`Start-Tray.vbs`** (launches completely silently in the background with no flashing console windows).
* Or execute via PowerShell:
```powershell
powershell -ExecutionPolicy Bypass -File .\Deploy-Tray.ps1
```

### 3. Add Your Monitored Sites
1. Right-click the **SyncPulse** tray icon (near the Windows clock).
2. Click **`Manage sites...`** at the top of the menu.
3. Click **`Add Site...`**:
   - Enter a friendly **Site Name** (e.g. `MyProject`).
   - Click **`Browse...`** to pick your local project root folder.
   - Enter your **SFTP Host**, **Port** (default 22), **Username**, and **Password**.
   - Set the **Remote Path** (e.g. `/` or `/public_html/`).
   - Adjust the **Ignore List** if needed.
4. Click **`Save`** &rarr; The site appears in the list and is immediately ready to watch!

---

## ⚙️ Setting Up Auto-Start on Windows Login

To have SyncPulse start automatically whenever you log into Windows:

### Option A: Windows Startup Folder (Easiest)
1. Press `Win + R`, type `shell:startup`, and press **Enter**.
2. Right-click inside the folder &rarr; **New** &rarr; **Shortcut**.
3. In the location box, enter the full path to `Start-Tray.vbs`:
   ```text
   wscript.exe "D:\websites\_common_scripts\deploy\Start-Tray.vbs"
   ```
4. Name the shortcut **SyncPulse Tray** and click **Finish**.

### Option B: Windows Task Scheduler (Recommended for Power Users)
```powershell
$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument '"D:\websites\_common_scripts\deploy\Start-Tray.vbs"'
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0
Register-ScheduledTask -TaskName 'SyncPulseTray' -Action $action -Trigger $trigger -Settings $settings
```

---

## 💻 CLI Engine Usage (`Deploy-Site.ps1`)

The core deployment engine can also be executed directly from any terminal or automated CI/CD pipeline:

```powershell
# Sync a website one time and exit (fail-fast exit code)
powershell -File Deploy-Site.ps1 -Action once -Path D:\websites\myproject

# Watch in the foreground (Ctrl+C to stop)
powershell -File Deploy-Site.ps1 -Action watch -Path D:\websites\myproject

# Start a detached background watcher (PID recorded)
powershell -File Deploy-Site.ps1 -Action start -Path D:\websites\myproject

# Stop the running background watcher for a project
powershell -File Deploy-Site.ps1 -Action stop -Path D:\websites\myproject

# Display the status of all active background watchers
powershell -File Deploy-Site.ps1 -Action status
```

### Command-Line Parameters

| Parameter | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `-Action` | `string` | `'once'` | Action to execute: `once`, `watch`, `start`, `stop`, `status`, `library` |
| `-Path` | `string` | `(Get-Location)` | Local path of the project to deploy |
| `-Delete` | `switch` | `False` | Opt-in: removes remote files that no longer exist locally |
| `-NoInitialSync` | `switch` | `False` | Skips initial reconciling sync, going straight to file watching |
| `-LogRetentionDays`| `int` | `7` | Number of days to retain rotated log files (0 disables purge) |
| `-AddressFamily` | `int` | `1` | Network routing: `1` = IPv4 only (default), `2` = IPv6 only, `0` = auto |

---

## 🔧 Server-Side Optimization Guide

To achieve maximum stability and avoid dropped connections on long-lived watchers, we recommend the following server-side configurations:

### 1. OpenSSH Server (`/etc/ssh/sshd_config`)
On your Linux server, edit `/etc/ssh/sshd_config` to enable proactive keepalives and prevent idle timeouts:

```nginx
# Keep connections alive across NAT/firewalls
TCPKeepAlive yes
ClientAliveInterval 30
ClientAliveCountMax 10

# Increase maximum multiplexed sessions
MaxSessions 50
MaxStartups 20:30:100

# SFTP Subsystem
Subsystem sftp internal-sftp
```
Reload SSH after making changes:
```bash
sudo systemctl reload sshd
```

### 2. SFTPGo Configuration (`sftpgo.json`)
If you are using **SFTPGo**:
- Set `"idle_timeout": 0` in `sftpgo.json` (or set a high value like `3600`) so the SFTP server does not disconnect idle watcher clients.
- Ensure the SFTP user has standard file write/delete permissions.

### 3. Pinning Host Keys (`known-hosts.example.json`)
For high security, you can optionally pin server host key fingerprints in a local `known-hosts.json` (git-ignored).

1. Copy `known-hosts.example.json` to `known-hosts.json`.
2. Obtain your server's `ed25519` key fingerprint:
   ```bash
   ssh-keyscan -t ed25519 example.com | ssh-keygen -lf -
   ```
3. Add it to `known-hosts.json`:
   ```json
   {
     "example.com:22": "ssh-ed25519 255 PZngOMq2UfWgKXsI4Eq8jul28L3sLA90UKx/Q5I2pr8"
   }
   ```
If a host is not listed in `known-hosts.json`, SyncPulse safely falls back to `acceptnew` with a warning.

---

## 📁 Repository & Configuration Structure

```text
d:\websites\_common_scripts\deploy/
├── Deploy-Site.ps1          # Core CLI sync engine & WinSCP interface
├── Deploy-Tray.ps1          # System tray controller & WinForms UI
├── Start-Tray.vbs           # Silent background launcher
├── install_winscp.bat       # One-click WinSCP setup & launcher
├── known-hosts.example.json # Pinned SSH host key template
├── known-hosts.json         # Local host keys (git-ignored)
├── sites.example.json       # Configuration template
├── sites.json               # Local site credentials (git-ignored)
├── .gitignore               # Git ignore rules
└── README.md                # Documentation
```

### `sites.json` Format Reference
```json
[
  {
    "name": "MyProject",
    "localPath": "D:\\websites\\myproject",
    "host": "bypia.com",
    "port": 22,
    "username": "sftpuser",
    "password": "your-password",
    "remotePath": "/public_html/",
    "ignore": [
      ".vscode",
      ".git",
      ".gitignore",
      ".env",
      "node_modules",
      "dist",
      "build",
      "*.log",
      "*.map",
      "vendor"
    ]
  }
]
```

---

## 🔍 Logs & Diagnostics

All session logs, PID state files, and transfer journals are stored in:
```text
%LOCALAPPDATA%\SyncPulse
```
*(e.g. `C:\Users\<YourUser>\AppData\Local\SyncPulse`)*

* Logs rotate automatically daily (`<ProjectKey>-YYYY-MM-DD.log`).
* Logs are capped at 5 MB with 3 rotated archives per day (`/logsize=3*5M`).
* Rotated logs older than 7 days are automatically purged hourly.
* Click **`Open log folder`** directly from the system tray menu to inspect logs anytime.

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
