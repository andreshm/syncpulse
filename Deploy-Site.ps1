<#
.SYNOPSIS
    Deploys a website to its SFTP server using WinSCP, driven by the project's
    existing .vscode\sftp.json (no second copy of credentials to maintain).

.DESCRIPTION
    One shared engine for all projects under D:\websites. Point it at a project
    folder and it reads host / username / password / remotePath / ignore straight
    out of that project's .vscode\sftp.json.

    Actions:
      once    Sync local -> remote one time, then exit.
      watch   Sync once, then stay in the foreground watching for changes (Ctrl+C to stop).
      start   Same as watch, but detached in the background. Records the PID.
      stop    Stops the background watcher for this project.
      status  Shows which projects currently have a background watcher running.

    "stop" then "start" is how you pause and resume.

.EXAMPLE
    Deploy-Site.ps1 -Action once   -Path D:\websites\wwwbypia
    Deploy-Site.ps1 -Action start  -Path D:\websites\wwwbypia
    Deploy-Site.ps1 -Action stop   -Path D:\websites\wwwbypia
    Deploy-Site.ps1 -Action status

.NOTES
    Never deletes remote files unless you explicitly pass -Delete.
#>
[CmdletBinding()]
param(
    # 'library' defines the functions and returns without doing anything, so other
    # scripts (Deploy-Tray.ps1) can dot-source this file and reuse them.
    [ValidateSet('once', 'watch', 'start', 'stop', 'status', 'library')]
    [string]$Action = 'once',

    [string]$Path = (Get-Location).Path,

    # Opt-in only. Removes remote files that no longer exist locally.
    [switch]$Delete,

    # Override WinSCP location if installed somewhere unusual.
    [string]$WinScpPath,

    # Override the pinned host key for this run.
    [string]$HostKey,

    # Delete rotated logs older than this many days. 0 disables the purge.
    [int]$LogRetentionDays = 7,

    # Go straight to watching, skipping the reconciling sync that normally runs first.
    # Makes 'watch'/'start' near-instant, at the cost of never catching up on anything
    # that changed while the watcher was off. Only affects watch/start, not once.
    [switch]$NoInitialSync,

    # 1 = IPv4 only (default), 2 = IPv6 only, 0 = auto.
    # Default is IPv4 because a host with an AAAA record but no working v6 route
    # makes WinSCP fail with "Network is unreachable" on auto.
    [ValidateSet(0, 1, 2)]
    [int]$AddressFamily = 1
)

$ErrorActionPreference = 'Stop'
$StateDir = Join-Path $env:LOCALAPPDATA 'SyncPulse'
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }

function Get-WinScp {
    param([string]$Override)
    if ($Override) {
        if (Test-Path $Override) { return $Override }
        throw "WinSCP not found at: $Override"
    }
    $candidates = @(
        "$env:ProgramFiles\WinSCP\WinSCP.com",
        "${env:ProgramFiles(x86)}\WinSCP\WinSCP.com",
        "$env:LOCALAPPDATA\Programs\WinSCP\WinSCP.com"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    $cmd = Get-Command 'WinSCP.com' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "WinSCP.com not found. Install it with:  winget install --id WinSCP.WinSCP -e"
}

function Get-ProjectKey {
    param([string]$ProjectPath)
    $full = (Resolve-Path $ProjectPath).Path
    $leaf = Split-Path $full -Leaf
    # Hash the full path so two projects with the same folder name never collide.
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($full.ToLowerInvariant())
    $hash = ($md5.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
    $safe = ($leaf -replace '[^A-Za-z0-9_.-]', '_')
    return "$safe-$($hash.Substring(0,8))"
}

function Get-LogPath {
    <#
      WinSCP expands !Y !M !D in the log path itself, so each session start writes to
      a file named for that day. Returns both the pattern to hand WinSCP and today's
      resolved name for display.
    #>
    param([string]$Key)
    [PSCustomObject]@{
        Pattern = Join-Path $StateDir "$Key-!Y-!M-!D.log"
        Today   = Join-Path $StateDir ("$Key-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
    }
}

function Get-LatestLog {
    param([string]$Key)
    $f = Get-ChildItem -Path $StateDir -Filter "$Key-*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($f) { return $f.FullName }
    return '(none yet)'
}

function Remove-OldLogs {
    <#
      Keeps the log directory bounded. Matches *.log and the .1/.2 archives WinSCP
      creates via /logsize. Files still being written are recent, so never caught.
    #>
    param([int]$Days)
    if ($Days -le 0) { return }
    $cutoff = (Get-Date).AddDays(-$Days)
    Get-ChildItem -Path $StateDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '*.log' -or $_.Name -match '\.log\.\d+$' } |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object {
            Write-Verbose "purging old log: $($_.Name)"
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        }
}

function Get-HostKey {
    <#
      Resolves the pinned fingerprint for a host from known-hosts.json next to
      this script. Deliberately NOT stored in sftp.json: the VS Code extension
      validates that file with Joi and rejects unknown keys.
    #>
    param([string]$HostName, [int]$Port)
    if ($script:HostKey) { return $script:HostKey }

    $khFile = Join-Path $PSScriptRoot 'known-hosts.json'
    if (Test-Path $khFile) {
        $kh = Get-Content -Raw -Path $khFile | ConvertFrom-Json
        $key = "${HostName}:${Port}"
        if ($kh.$key) { return $kh.$key }
    }

    $msg = ("No pinned host key for {0}:{1} in known-hosts.json - falling back to " +
        "'acceptnew', which verifies nothing. Add one with: " +
        "ssh-keyscan -t ed25519 {0} | ssh-keygen -lf -") -f $HostName, $Port
    Write-Warning $msg
    return 'acceptnew'
}

function Get-SitesConfigFile {
    return (Join-Path $PSScriptRoot 'sites.json')
}

function Get-ConfiguredSites {
    $sitesFile = Get-SitesConfigFile
    if (Test-Path $sitesFile) {
        try {
            $json = Get-Content -Raw -Path $sitesFile -Encoding UTF8 | ConvertFrom-Json
            if ($json -is [System.Array]) { return $json }
            if ($json) { return @($json) }
        }
        catch {
            Write-Warning "Failed to parse sites.json: $_"
        }
    }
    return @()
}

function Get-SiteConfig {
    param([string]$ProjectPath)

    # 1. Check sites.json first
    $configured = Get-ConfiguredSites
    if ($configured -and $configured.Count -gt 0) {
        $cleanPath = $ProjectPath.TrimEnd('\')
        if (Test-Path $ProjectPath) {
            $cleanPath = (Resolve-Path $ProjectPath).Path.TrimEnd('\')
        }
        $leaf = Split-Path $cleanPath -Leaf

        $site = $configured | Where-Object {
            $p = $_.localPath
            if ($p) {
                if ((Test-Path $p) -and ((Resolve-Path $p).Path.TrimEnd('\') -eq $cleanPath)) { return $true }
                if ($p.TrimEnd('\') -eq $cleanPath) { return $true }
            }
            if ($_.name -and ($_.name -eq $ProjectPath -or $_.name -eq $leaf)) { return $true }
            return $false
        } | Select-Object -First 1

        if ($site) {
            foreach ($required in @('host', 'username')) {
                if (-not $site.$required) { throw "sites.json entry for '$($site.name)' is missing '$required'" }
            }
            $port = 22
            if ($site.port) { $port = [int]$site.port }
            $remote = '/'
            if ($site.remotePath) { $remote = $site.remotePath }
            $remote = $remote -replace '\\', '/'
            if (-not $remote.EndsWith('/')) { $remote = "$remote/" }
            $hostKey = Get-HostKey -HostName $site.host -Port $port

            return [PSCustomObject]@{
                Name       = $site.name
                LocalPath  = $site.localPath
                HostName   = $site.host
                Port       = $port
                Username   = $site.username
                Password   = $site.password
                RemotePath = $remote
                HostKey    = $hostKey
                Ignore     = $site.ignore
            }
        }
    }

    # 2. Fallback to .vscode\sftp.json
    $cfgFile = Join-Path $ProjectPath '.vscode\sftp.json'
    if (Test-Path $cfgFile) {
        $cfg = Get-Content -Raw -Path $cfgFile | ConvertFrom-Json
        foreach ($required in @('host', 'username')) {
            if (-not $cfg.$required) { throw "sftp.json is missing '$required'" }
        }
        $port = 22
        if ($cfg.port) { $port = [int]$cfg.port }
        $remote = '/'
        if ($cfg.remotePath) { $remote = $cfg.remotePath }
        $remote = $remote -replace '\\', '/'
        if (-not $remote.EndsWith('/')) { $remote = "$remote/" }
        $hostKey = Get-HostKey -HostName $cfg.host -Port $port

        return [PSCustomObject]@{
            Name       = Split-Path (Resolve-Path $ProjectPath).Path -Leaf
            LocalPath  = (Resolve-Path $ProjectPath).Path
            HostName   = $cfg.host
            Port       = $port
            Username   = $cfg.username
            Password   = $cfg.password
            RemotePath = $remote
            HostKey    = $hostKey
            Ignore     = $cfg.ignore
        }
    }

    throw "No configuration found for '$ProjectPath' in sites.json or .vscode\sftp.json"
}

function ConvertTo-FileMask {
    <#
      Translates the gitignore-style "ignore" array from sftp.json into a WinSCP
      exclude mask. WinSCP matches a bare name against files only, and a name with
      a trailing slash against directories, so non-wildcard entries emit both forms.

      Always includes built-in exclusions for Windows reserved device names
      (NUL, CON, PRN, AUX, COM1-9, LPT1-9) so accidental Git redirection files
      (e.g., 'NUL') do not cause Win32 Error 87 / crash WinSCP.
    #>
    param($Ignore)
    $parts = New-Object System.Collections.Generic.List[string]
    $seen = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

    # Built-in default exclusions: Windows reserved device names and variations
    $defaults = @(
        'nul', 'nul/', 'nul.*', 'nul.*/',
        'con', 'con/', 'con.*', 'con.*/',
        'prn', 'prn/', 'prn.*', 'prn.*/',
        'aux', 'aux/', 'aux.*', 'aux.*/',
        'com[1-9]', 'com[1-9]/', 'com[1-9].*', 'com[1-9].*/',
        'lpt[1-9]', 'lpt[1-9]/', 'lpt[1-9].*', 'lpt[1-9].*/'
    )
    foreach ($d in $defaults) {
        if ($seen.Add($d)) {
            $parts.Add($d) | Out-Null
        }
    }

    if ($Ignore) {
        foreach ($entry in $Ignore) {
            $e = "$entry".Trim().Trim('/')
            if (-not $e) { continue }
            if ($e -match '[\*\?]') {
                if ($seen.Add($e)) { $parts.Add($e) | Out-Null }
            }
            else {
                if ($seen.Add("$e/")) { $parts.Add("$e/") | Out-Null }   # directory named $e
                if ($seen.Add($e)) { $parts.Add($e) | Out-Null }        # file named $e
            }
        }
    }
    if ($parts.Count -eq 0) { return $null }
    return '|' + ($parts -join ';')
}

function New-WinScpScript {
    param($Config, [string]$LocalPath, [string]$Mode, [string]$ScriptFile, [switch]$WithDelete)

    $mask = ConvertTo-FileMask -Ignore $Config.Ignore

    # -nopermissions: do not chmod after upload. SFTPGo returns "permission denied"
    #                 for chmod unless the user holds that permission.
    # -transfer=binary: no line-ending translation, ever.
    # -resumesupport=off: write directly instead of uploading to a .filepart file
    #                 and renaming, which Windows blocks when a handle is open.
    $opts = '-nopermissions -transfer=binary -resumesupport=off'
    if ($mask) { $opts = "$opts -filemask=""$mask""" }
    # -mirror is required: without it WinSCP skips any file that is OLDER locally.
    # The VS Code extension never preserved mtime on upload, so most remote files
    # carry a timestamp NEWER than their local source and would be silently skipped.
    # time,size means a difference in either direction triggers an upload.
    # (keepuptodate accepts neither switch, so this applies to synchronize only.)
    $syncOpts = "$opts -criteria=time,size -mirror"
    if ($WithDelete) { $syncOpts = "$syncOpts -delete" }

    $local = $LocalPath.TrimEnd('\')
    $remote = $Config.RemotePath

    $lines = New-Object System.Collections.Generic.List[string]
    if ($Mode -eq 'once') {
        # Fail-fast for one-shot deploys so errors produce a non-zero exit code
        $lines.Add('option batch abort') | Out-Null
    }
    else {
        # Continuous watching: continue on errors (e.g. temporary file lock, transient network drop)
        # and let option reconnecttime handle reconnection instead of killing the watcher
        $lines.Add('option batch continue') | Out-Null
    }
    $lines.Add('option confirm off') | Out-Null
    # Retry a dropped connection for up to 2 minutes before giving up.
    $lines.Add('option reconnecttime 120') | Out-Null

    # -rawsettings must come last; it consumes the remaining arguments.
    # PingType=2 (SSH dummy protocol request / keepalive@openssh.com) every 30s forces bidirectional
    # traffic across firewalls/NAT, keeping the session active without server-side timeouts.
    # TCPKeepalives=1 enables OS-level TCP keepalive probes.
    # RekeyTime=0 / RekeyData=0 disable SSH key re-exchange. WinSCP rekeys every 60
    # minutes by default and this server drops the connection when it happens - all
    # watchers were dying on the hour with "Software caused connection abort", which
    # 'option batch abort' makes fatal. Long-lived watcher sessions over a trusted
    # network are worth more here than periodic rekeying.
    $escPass = if ($Config.Password) { $Config.Password -replace '"', '""' } else { '' }
    $openCmd = 'open sftp://{0}@{1}:{2}/ -password="{3}" -hostkey="{4}" -timeout=30 -rawsettings AddressFamily={5} PingType=2 PingInterval=30 TCPKeepalives=1 RekeyTime=0 RekeyData=0' -f `
        $Config.Username, $Config.HostName, $Config.Port, $escPass, $Config.HostKey, $script:AddressFamily
    $lines.Add($openCmd) | Out-Null

    # A reconciling sync first, so "watch" starts from a known state. keepuptodate only
    # ever reacts to changes it observes, so without this anything that changed while
    # the watcher was off stays stale on the server indefinitely.
    if ($Mode -eq 'once' -or -not $script:NoInitialSync) {
        $lines.Add(('synchronize remote {0} "{1}" "{2}"' -f $syncOpts, $local, $remote)) | Out-Null
    }

    if ($Mode -eq 'watch') {
        $lines.Add(('keepuptodate {0} "{1}" "{2}"' -f $opts, $local, $remote)) | Out-Null
    }

    $lines.Add('exit') | Out-Null

    Set-Content -Path $ScriptFile -Value ($lines -join "`r`n") -Encoding UTF8
}

function Invoke-Deploy {
    param($Config, [string]$LocalPath, [string]$Mode, [string]$Key, [switch]$Detached, [switch]$WithDelete)

    $winscp = Get-WinScp -Override $WinScpPath
    $scriptFile = Join-Path $StateDir "$Key.txt"
    $log = Get-LogPath -Key $Key
    $logFile = $log.Today
    $pidFile = Join-Path $StateDir "$Key.pid"

    Remove-OldLogs -Days $script:LogRetentionDays

    New-WinScpScript -Config $Config -LocalPath $LocalPath -Mode $Mode `
        -ScriptFile $scriptFile -WithDelete:$WithDelete

    # /logsize=<count>*<size> caps each day's file at 5 MB and keeps 3 archives, so a
    # busy watcher cannot fill the disk between daily rollovers.
    $winscpArgs = @(
        '/ini=nul'
        "/script=""$scriptFile"""
        "/log=""$($log.Pattern)"""
        '/loglevel=0'
        '/logsize=3*5M'
    )

    if ($Detached) {
        $proc = Start-Process -FilePath $winscp -ArgumentList $winscpArgs `
            -WindowStyle Hidden -PassThru
        Set-Content -Path $pidFile -Value $proc.Id -Encoding UTF8
        Write-Host "Watching $LocalPath  ->  $($Config.HostName)$($Config.RemotePath)" -ForegroundColor Green
        Write-Host "  PID $($proc.Id)   log: $logFile" -ForegroundColor DarkGray
        Write-Host "  Stop with:  Deploy-Site.ps1 -Action stop -Path ""$LocalPath""" -ForegroundColor DarkGray
        return
    }

    try {
        & $winscp @winscpArgs
        $code = $LASTEXITCODE
    }
    finally {
        if (Test-Path $scriptFile) { Remove-Item $scriptFile -Force -ErrorAction SilentlyContinue }
    }

    if ($code -ne 0) {
        Write-Host "WinSCP exited with code $code. See log: $logFile" -ForegroundColor Red
        exit $code
    }
    Write-Host "Done. ($LocalPath -> $($Config.HostName)$($Config.RemotePath))" -ForegroundColor Green
}

function Stop-Watcher {
    param([string]$Key, [string]$LocalPath)
    $pidFile = Join-Path $StateDir "$Key.pid"
    if (-not (Test-Path $pidFile)) {
        Write-Host "No background watcher recorded for $LocalPath" -ForegroundColor Yellow
        return
    }
    $procId = (Get-Content $pidFile -Raw).Trim()
    $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if ($proc) {
        # Kill process tree (/T /F) to ensure child WinSCP.exe is also stopped
        try {
            Start-Process -FilePath 'taskkill.exe' -ArgumentList @('/PID', $procId, '/T', '/F') -NoNewWindow -Wait -ErrorAction SilentlyContinue | Out-Null
        }
        catch {
            Stop-Process -Id $procId -Force -Confirm:$false -ErrorAction SilentlyContinue
        }
        Write-Host "Stopped watcher (PID $procId) for $LocalPath" -ForegroundColor Green
    }
    else {
        Write-Host "Watcher (PID $procId) was no longer running." -ForegroundColor Yellow
    }
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    $scriptFile = Join-Path $StateDir "$Key.txt"
    if (Test-Path $scriptFile) { Remove-Item $scriptFile -Force -ErrorAction SilentlyContinue }
}

function Show-Status {
    $pidFiles = Get-ChildItem -Path $StateDir -Filter '*.pid' -ErrorAction SilentlyContinue
    if (-not $pidFiles) {
        Write-Host "No background watchers running." -ForegroundColor Yellow
        return
    }
    $rows = foreach ($f in $pidFiles) {
        $procId = (Get-Content $f.FullName -Raw).Trim()
        $running = $null -ne (Get-Process -Id $procId -ErrorAction SilentlyContinue)
        $state = 'stale'
        if ($running) { $state = 'running' }
        [PSCustomObject]@{
            Project = $f.BaseName
            PID     = $procId
            State   = $state
            Log     = Get-LatestLog -Key $f.BaseName
        }
    }
    $rows | Format-Table -AutoSize
}

# ---------------------------------------------------------------- main

if ($Action -eq 'library') { return }

Remove-OldLogs -Days $LogRetentionDays

if ($Action -eq 'status') {
    Show-Status
    return
}

if (-not (Test-Path $Path)) { throw "Project path does not exist: $Path" }
$Path = (Resolve-Path $Path).Path
$key = Get-ProjectKey -ProjectPath $Path

switch ($Action) {
    'stop' {
        Stop-Watcher -Key $key -LocalPath $Path
    }
    'once' {
        $cfg = Get-SiteConfig -ProjectPath $Path
        Invoke-Deploy -Config $cfg -LocalPath $Path -Mode 'once' -Key $key -WithDelete:$Delete
    }
    'watch' {
        $cfg = Get-SiteConfig -ProjectPath $Path
        Write-Host "Watching for changes. Press Ctrl+C to stop." -ForegroundColor Cyan
        Invoke-Deploy -Config $cfg -LocalPath $Path -Mode 'watch' -Key $key -WithDelete:$Delete
    }
    'start' {
        $existing = Join-Path $StateDir "$key.pid"
        if (Test-Path $existing) {
            $oldPid = (Get-Content $existing -Raw).Trim()
            if (Get-Process -Id $oldPid -ErrorAction SilentlyContinue) {
                Write-Host "Already watching $Path (PID $oldPid). Stop it first." -ForegroundColor Yellow
                return
            }
        }
        $cfg = Get-SiteConfig -ProjectPath $Path
        Invoke-Deploy -Config $cfg -LocalPath $Path -Mode 'watch' -Key $key -Detached -WithDelete:$Delete
    }
}
