<#
.SYNOPSIS
    System tray controller for Deploy-Site.ps1.

.DESCRIPTION
    Puts one icon in the notification area with a right-click menu listing every
    monitored site configured in sites.json (or discovered under -Root). Each project
    can be started watching, stopped, or deployed once. Includes a Site Manager
    dialog to Add, Edit, and Remove monitored locations directly from the tray.

    The icon is:
      - Green: All desired watchers are active and running.
      - Yellow: One or more watchers are down or failed.
      - Grey: All watchers are idle / stopped.

    This is only a controller. All the real work stays in Deploy-Site.ps1, which
    remains usable on its own from a terminal.

.NOTES
    Stopping a watcher kills WinSCP immediately. If a transfer happens to be in
    flight, the file being written is left truncated on the server. There is no
    in-flight detection here by design.

    Exiting stops every watcher first, so nothing is left uploading headlessly.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File Deploy-Tray.ps1
    powershell -ExecutionPolicy Bypass -File Deploy-Tray.ps1 -Root D:\websites
#>
[CmdletBinding()]
param(
    # Folder whose immediate subfolders are scanned if sites.json does not exist
    [string]$Root = 'D:\websites',

    # Explicit project list; overrides discovery
    [string[]]$Projects,

    # By default every discovered project starts watching as soon as the tray loads.
    # Pass this to load idle instead and start projects by hand from the menu.
    [switch]$NoAutoStart
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- single instance
$createdNew = $false
# Local\ not Global\ - creating a Global object needs SeCreateGlobalPrivilege, which
# an unelevated process does not have. The tray only ever runs in the user session.
$mutex = New-Object System.Threading.Mutex($true, 'Local\SyncPulseTray', [ref]$createdNew)
if (-not $createdNew) {
    # Exit silently. A MessageBox here is invisible when launched hidden (wscript or
    # -WindowStyle Hidden) and the process then sits alive forever waiting for a click
    # nobody can give it, accumulating a zombie per launch attempt.
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$engine = Join-Path $PSScriptRoot 'Deploy-Site.ps1'
if (-not (Test-Path $engine)) { throw "Deploy-Site.ps1 not found next to this script." }

# Pull in Get-ProjectKey / Remove-OldLogs / Get-ConfiguredSites / $StateDir etc.
. $engine -Action library

# The tray can stay up for weeks. Purge on start, then hourly from the timer, or
# long-lived watchers would never trigger the engine's own housekeeping.
Remove-OldLogs -Days $LogRetentionDays
$lastPurge = Get-Date

# ---------------------------------------------------------------- helpers
function Test-Watching {
    param([string]$Key)
    $pidFile = Join-Path $StateDir "$Key.pid"
    if (-not (Test-Path $pidFile)) { return $false }
    $procId = (Get-Content $pidFile -Raw).Trim()
    return $null -ne (Get-Process -Id $procId -ErrorAction SilentlyContinue)
}

function New-DotIcon {
    param([System.Drawing.Color]$Color)
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush $Color
    $g.FillEllipse($brush, 2, 2, 12, 12)
    $brush.Dispose(); $g.Dispose()
    # Built once at startup and reused - creating icons per timer tick leaks GDI handles.
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    return $icon
}

function Invoke-Engine {
    param([string]$EngineAction, [string]$ProjectPath)
    # start/stop return immediately (they use Start-Process internally), so calling
    # them in-process will not block the message loop.
    & $engine -Action $EngineAction -Path $ProjectPath | Out-Null
}

function Start-DeployOnce {
    param([string]$ProjectPath)
    # 'once' blocks until the sync finishes, so it must NOT run on the UI thread.
    # A visible window is deliberate: you want to see what a one-shot deploy did.
    Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', "`"$engine`"",
        '-Action', 'once', '-Path', "`"$ProjectPath`""
    )
}

function Start-AllWatchers {
    foreach ($s in $script:sites) {
        $s.Desired = $true
        $s.Fails = 0
        if (-not (Test-Watching -Key $s.Key)) {
            Invoke-Engine -EngineAction 'start' -ProjectPath $s.Path
        }
    }
}

function Stop-AllWatchers {
    foreach ($s in $script:sites) {
        $s.Desired = $false
        $s.Fails = 0
        if (Test-Watching -Key $s.Key) { Invoke-Engine -EngineAction 'stop' -ProjectPath $s.Path }
    }
}

# ---------------------------------------------------------------- Site Manager UI
function Show-SiteEditorDialog {
    param($Site = $null)

    $isEdit = $null -ne $Site
    $form = New-Object System.Windows.Forms.Form
    $form.Text = if ($isEdit) { "Edit Site: $($Site.name)" } else { "Add New Monitored Site" }
    $form.Size = New-Object System.Drawing.Size(560, 490)
    $form.StartPosition = 'CenterParent'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $curY = 18
    $labelWidth = 110
    $inputWidth = 380

    # Row: Site Name
    $lblName = New-Object System.Windows.Forms.Label
    $lblName.Text = "Site Name:"
    $lblName.Location = New-Object System.Drawing.Point(20, $curY)
    $lblName.Size = New-Object System.Drawing.Size($labelWidth, 23)
    $form.Controls.Add($lblName) | Out-Null

    $tbName = New-Object System.Windows.Forms.TextBox
    $tbName.Text = if ($Site -and $Site.name) { "$($Site.name)" } else { "" }
    $tbName.Location = New-Object System.Drawing.Point(140, $curY)
    $tbName.Size = New-Object System.Drawing.Size($inputWidth, 23)
    $form.Controls.Add($tbName) | Out-Null
    $curY += 34

    # Row: Local Path + Browse
    $lblPath = New-Object System.Windows.Forms.Label
    $lblPath.Text = "Local Path:"
    $lblPath.Location = New-Object System.Drawing.Point(20, $curY)
    $lblPath.Size = New-Object System.Drawing.Size($labelWidth, 23)
    $form.Controls.Add($lblPath) | Out-Null

    $tbPath = New-Object System.Windows.Forms.TextBox
    $tbPath.Text = if ($Site -and $Site.localPath) { "$($Site.localPath)" } else { "" }
    $tbPath.Location = New-Object System.Drawing.Point(140, $curY)
    $tbPath.Size = New-Object System.Drawing.Size(295, 23)
    $form.Controls.Add($tbPath) | Out-Null

    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = "Browse..."
    $btnBrowse.Location = New-Object System.Drawing.Point(440, [int]($curY - 1))
    $btnBrowse.Size = New-Object System.Drawing.Size(80, 25)
    $btnBrowse.Add_Click({
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fbd.Description = "Select the local website root folder"
        if ($tbPath.Text -and (Test-Path $tbPath.Text)) { $fbd.SelectedPath = $tbPath.Text }
        if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $tbPath.Text = $fbd.SelectedPath
            if (-not $tbName.Text) { $tbName.Text = Split-Path $fbd.SelectedPath -Leaf }
        }
    })
    $form.Controls.Add($btnBrowse) | Out-Null
    $curY += 34

    # Row: SFTP Host
    $lblHost = New-Object System.Windows.Forms.Label
    $lblHost.Text = "SFTP Host:"
    $lblHost.Location = New-Object System.Drawing.Point(20, $curY)
    $lblHost.Size = New-Object System.Drawing.Size($labelWidth, 23)
    $form.Controls.Add($lblHost) | Out-Null

    $tbHost = New-Object System.Windows.Forms.TextBox
    $tbHost.Text = if ($Site -and $Site.host) { "$($Site.host)" } else { "" }
    $tbHost.Location = New-Object System.Drawing.Point(140, $curY)
    $tbHost.Size = New-Object System.Drawing.Size($inputWidth, 23)
    $form.Controls.Add($tbHost) | Out-Null
    $curY += 34

    # Row: SFTP Port
    $lblPort = New-Object System.Windows.Forms.Label
    $lblPort.Text = "SFTP Port:"
    $lblPort.Location = New-Object System.Drawing.Point(20, $curY)
    $lblPort.Size = New-Object System.Drawing.Size($labelWidth, 23)
    $form.Controls.Add($lblPort) | Out-Null

    $tbPort = New-Object System.Windows.Forms.TextBox
    $tbPort.Text = if ($Site -and $Site.port) { "$($Site.port)" } else { "22" }
    $tbPort.Location = New-Object System.Drawing.Point(140, $curY)
    $tbPort.Size = New-Object System.Drawing.Size($inputWidth, 23)
    $form.Controls.Add($tbPort) | Out-Null
    $curY += 34

    # Row: Username
    $lblUser = New-Object System.Windows.Forms.Label
    $lblUser.Text = "Username:"
    $lblUser.Location = New-Object System.Drawing.Point(20, $curY)
    $lblUser.Size = New-Object System.Drawing.Size($labelWidth, 23)
    $form.Controls.Add($lblUser) | Out-Null

    $tbUser = New-Object System.Windows.Forms.TextBox
    $tbUser.Text = if ($Site -and $Site.username) { "$($Site.username)" } else { "" }
    $tbUser.Location = New-Object System.Drawing.Point(140, $curY)
    $tbUser.Size = New-Object System.Drawing.Size($inputWidth, 23)
    $form.Controls.Add($tbUser) | Out-Null
    $curY += 34

    # Row: Password
    $lblPass = New-Object System.Windows.Forms.Label
    $lblPass.Text = "Password:"
    $lblPass.Location = New-Object System.Drawing.Point(20, $curY)
    $lblPass.Size = New-Object System.Drawing.Size($labelWidth, 23)
    $form.Controls.Add($lblPass) | Out-Null

    $tbPass = New-Object System.Windows.Forms.TextBox
    $tbPass.Text = if ($Site -and $Site.password) { "$($Site.password)" } else { "" }
    $tbPass.Location = New-Object System.Drawing.Point(140, $curY)
    $tbPass.Size = New-Object System.Drawing.Size($inputWidth, 23)
    $tbPass.UseSystemPasswordChar = $true
    $form.Controls.Add($tbPass) | Out-Null
    $curY += 28

    # Row: Show Password checkbox
    $cbShowPass = New-Object System.Windows.Forms.CheckBox
    $cbShowPass.Text = "Show password"
    $cbShowPass.Location = New-Object System.Drawing.Point(140, $curY)
    $cbShowPass.Size = New-Object System.Drawing.Size(140, 20)
    $cbShowPass.Add_CheckedChanged({ $tbPass.UseSystemPasswordChar = -not $cbShowPass.Checked })
    $form.Controls.Add($cbShowPass) | Out-Null
    $curY += 26

    # Row: Remote Path
    $lblRemote = New-Object System.Windows.Forms.Label
    $lblRemote.Text = "Remote Path:"
    $lblRemote.Location = New-Object System.Drawing.Point(20, $curY)
    $lblRemote.Size = New-Object System.Drawing.Size($labelWidth, 23)
    $form.Controls.Add($lblRemote) | Out-Null

    $tbRemote = New-Object System.Windows.Forms.TextBox
    $tbRemote.Text = if ($Site -and $Site.remotePath) { "$($Site.remotePath)" } else { "/" }
    $tbRemote.Location = New-Object System.Drawing.Point(140, $curY)
    $tbRemote.Size = New-Object System.Drawing.Size($inputWidth, 23)
    $form.Controls.Add($tbRemote) | Out-Null
    $curY += 34

    # Row: Ignore List
    $lblIgnore = New-Object System.Windows.Forms.Label
    $lblIgnore.Text = "Ignore List:"
    $lblIgnore.Location = New-Object System.Drawing.Point(20, $curY)
    $lblIgnore.Size = New-Object System.Drawing.Size($labelWidth, 23)
    $form.Controls.Add($lblIgnore) | Out-Null

    $defaultIgnore = ".vscode, .git, .gitignore, .env*, *.pem, *.key, *.sql, *.sqlite, *.bak, node_modules, dist, build, *.log, *.map, vendor, _bk, _notes, deploy, .tmp*, .sass-cache, .superpowers, .expo"
    $currentIgnore = if ($Site -and $Site.ignore) { ($Site.ignore -join ", ") } else { $defaultIgnore }
    $tbIgnore = New-Object System.Windows.Forms.TextBox
    $tbIgnore.Text = $currentIgnore
    $tbIgnore.Location = New-Object System.Drawing.Point(140, $curY)
    $tbIgnore.Size = New-Object System.Drawing.Size($inputWidth, 23)
    $form.Controls.Add($tbIgnore) | Out-Null
    $curY += 40

    # Buttons
    $btnOK = New-Object System.Windows.Forms.Button
    $btnOK.Text = "Save"
    $btnOK.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $btnOK.Location = New-Object System.Drawing.Point(340, $curY)
    $btnOK.Size = New-Object System.Drawing.Size(85, 28)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $btnCancel.Location = New-Object System.Drawing.Point(435, $curY)
    $btnCancel.Size = New-Object System.Drawing.Size(85, 28)

    $form.AcceptButton = $btnOK
    $form.CancelButton = $btnCancel
    $form.Controls.Add($btnOK) | Out-Null
    $form.Controls.Add($btnCancel) | Out-Null

    $res = $form.ShowDialog()
    if ($res -eq [System.Windows.Forms.DialogResult]::OK) {
        if (-not $tbName.Text.Trim()) {
            [System.Windows.Forms.MessageBox]::Show("Site Name is required.", "Validation Error", "OK", "Warning") | Out-Null
            return $null
        }
        if (-not $tbPath.Text.Trim()) {
            [System.Windows.Forms.MessageBox]::Show("Local Path is required.", "Validation Error", "OK", "Warning") | Out-Null
            return $null
        }
        if (-not $tbHost.Text.Trim()) {
            [System.Windows.Forms.MessageBox]::Show("SFTP Host is required.", "Validation Error", "OK", "Warning") | Out-Null
            return $null
        }
        if (-not $tbUser.Text.Trim()) {
            [System.Windows.Forms.MessageBox]::Show("Username is required.", "Validation Error", "OK", "Warning") | Out-Null
            return $null
        }

        $ignoreArr = $tbIgnore.Text -split '[,;\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique
        $portVal = 22
        [int]::TryParse($tbPort.Text.Trim(), [ref]$portVal) | Out-Null

        return [PSCustomObject]@{
            name       = $tbName.Text.Trim()
            localPath  = $tbPath.Text.Trim()
            host       = $tbHost.Text.Trim()
            port       = $portVal
            username   = $tbUser.Text.Trim()
            password   = $tbPass.Text
            remotePath = if ($tbRemote.Text.Trim()) { $tbRemote.Text.Trim() } else { "/" }
            ignore     = @($ignoreArr)
        }
    }
    return $null
}

function Show-SiteManagerDialog {
    $mgrForm = New-Object System.Windows.Forms.Form
    $mgrForm.Text = "SyncPulse - Site Manager"
    $mgrForm.Size = New-Object System.Drawing.Size(780, 460)
    $mgrForm.StartPosition = 'CenterScreen'
    $mgrForm.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $lv = New-Object System.Windows.Forms.ListView
    $lv.Location = New-Object System.Drawing.Point(16, 16)
    $lv.Size = New-Object System.Drawing.Size(610, 380)
    $lv.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $lv.View = [System.Windows.Forms.View]::Details
    $lv.FullRowSelect = $true
    $lv.GridLines = $true
    $lv.MultiSelect = $false

    $lv.Columns.Add("Name", 130) | Out-Null
    $lv.Columns.Add("Local Path", 210) | Out-Null
    $lv.Columns.Add("Host", 110) | Out-Null
    $lv.Columns.Add("User", 75) | Out-Null
    $lv.Columns.Add("Remote Path", 80) | Out-Null

    function Reload-List {
        $lv.Items.Clear()
        $cfgList = Get-ConfiguredSites
        foreach ($c in $cfgList) {
            $item = New-Object System.Windows.Forms.ListViewItem($c.name)
            $item.SubItems.Add($c.localPath) | Out-Null
            $item.SubItems.Add($c.host) | Out-Null
            $item.SubItems.Add($c.username) | Out-Null
            $item.SubItems.Add($c.remotePath) | Out-Null
            $item.Tag = $c
            $lv.Items.Add($item) | Out-Null
        }
    }
    Reload-List

    $btnX = 640
    $btnAdd = New-Object System.Windows.Forms.Button
    $btnAdd.Text = "Add Site..."
    $btnAdd.Location = New-Object System.Drawing.Point($btnX, 16)
    $btnAdd.Size = New-Object System.Drawing.Size(105, 30)
    $btnAdd.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $btnAdd.Add_Click({
        $newSite = Show-SiteEditorDialog
        if ($newSite) {
            $list = [System.Collections.Generic.List[object]]@(Get-ConfiguredSites)
            $list.Add($newSite)
            $sitesFile = Get-SitesConfigFile
            $list | ConvertTo-Json -Depth 5 | Set-Content -Path $sitesFile -Encoding UTF8
            Reload-List
            Update-SiteListAndMenu
        }
    })

    $btnEdit = New-Object System.Windows.Forms.Button
    $btnEdit.Text = "Edit..."
    $btnEdit.Location = New-Object System.Drawing.Point($btnX, 54)
    $btnEdit.Size = New-Object System.Drawing.Size(105, 30)
    $btnEdit.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $btnEdit.Add_Click({
        if ($lv.SelectedItems.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Please select a site to edit.", "Selection Required", "OK", "Information")
            return
        }
        $selected = $lv.SelectedItems[0].Tag
        $updated = Show-SiteEditorDialog -Site $selected
        if ($updated) {
            $list = @(Get-ConfiguredSites)
            for ($i = 0; $i -lt $list.Count; $i++) {
                if ($list[$i].localPath -eq $selected.localPath -or $list[$i].name -eq $selected.name) {
                    $list[$i] = $updated
                    break
                }
            }
            $sitesFile = Get-SitesConfigFile
            $list | ConvertTo-Json -Depth 5 | Set-Content -Path $sitesFile -Encoding UTF8

            # If watcher was active, restart it so new ignore masks and settings take effect immediately
            $oldKey = Get-ProjectKey -ProjectPath $selected.localPath
            if (Test-Watching -Key $oldKey) {
                Invoke-Engine -EngineAction 'stop' -ProjectPath $selected.localPath
                Invoke-Engine -EngineAction 'start' -ProjectPath $updated.localPath
            }

            Reload-List
            Update-SiteListAndMenu
        }
    })

    $btnRemove = New-Object System.Windows.Forms.Button
    $btnRemove.Text = "Remove"
    $btnRemove.Location = New-Object System.Drawing.Point($btnX, 92)
    $btnRemove.Size = New-Object System.Drawing.Size(105, 30)
    $btnRemove.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $btnRemove.Add_Click({
        if ($lv.SelectedItems.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Please select a site to remove.", "Selection Required", "OK", "Information")
            return
        }
        $selected = $lv.SelectedItems[0].Tag
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Are you sure you want to remove '$($selected.name)' from monitored sites?",
            "Confirm Removal",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
            # Stop watcher if running
            Invoke-Engine -EngineAction 'stop' -ProjectPath $selected.localPath
            $list = [System.Collections.Generic.List[object]]@(Get-ConfiguredSites)
            $toRemove = $list | Where-Object { $_.localPath -eq $selected.localPath -or $_.name -eq $selected.name }
            foreach ($r in $toRemove) { $list.Remove($r) | Out-Null }
            $sitesFile = Get-SitesConfigFile
            $list | ConvertTo-Json -Depth 5 | Set-Content -Path $sitesFile -Encoding UTF8
            Reload-List
            Update-SiteListAndMenu
        }
    })

    $btnOpenJson = New-Object System.Windows.Forms.Button
    $btnOpenJson.Text = "Open sites.json"
    $btnOpenJson.Location = New-Object System.Drawing.Point($btnX, 140)
    $btnOpenJson.Size = New-Object System.Drawing.Size(105, 30)
    $btnOpenJson.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $btnOpenJson.Add_Click({
        $f = Get-SitesConfigFile
        if (Test-Path $f) { Start-Process $f }
    })

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point($btnX, 366)
    $btnClose.Size = New-Object System.Drawing.Size(105, 30)
    $btnClose.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $btnClose.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $btnClose.Add_Click({ $mgrForm.Close() })
    $mgrForm.CancelButton = $btnClose

    $mgrForm.Controls.AddRange(@($lv, $btnAdd, $btnEdit, $btnRemove, $btnOpenJson, $btnClose)) | Out-Null
    $mgrForm.ShowDialog() | Out-Null
}

# ---------------------------------------------------------------- project synchronization
function Sync-SitesObjects {
    $configured = Get-ConfiguredSites
    if ((-not $configured -or $configured.Count -eq 0) -and -not $Projects) {
        $discovered = Get-ChildItem -Path $Root -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName '.vscode\sftp.json') }
        if ($discovered) {
            $converted = foreach ($d in $discovered) {
                try {
                    $cfg = Get-Content -Raw -Path (Join-Path $d.FullName '.vscode\sftp.json') | ConvertFrom-Json
                    [PSCustomObject]@{
                        name       = $d.Name
                        localPath  = $d.FullName
                        host       = $cfg.host
                        port       = if ($cfg.port) { [int]$cfg.port } else { 22 }
                        username   = $cfg.username
                        password   = $cfg.password
                        remotePath = if ($cfg.remotePath) { $cfg.remotePath } else { '/' }
                        ignore     = if ($cfg.ignore) { $cfg.ignore } else { @() }
                    }
                }
                catch { }
            }
            if ($converted) {
                $sitesFile = Get-SitesConfigFile
                $converted | ConvertTo-Json -Depth 5 | Set-Content -Path $sitesFile -Encoding UTF8
                $configured = $converted
            }
        }
    }

    if ($Projects) {
        $configured = foreach ($p in $Projects) {
            [PSCustomObject]@{
                name      = Split-Path $p -Leaf
                localPath = $p
            }
        }
    }

    $oldSites = @{}
    if ($script:sites) {
        foreach ($s in $script:sites) {
            $oldSites[$s.Path] = $s
        }
    }

    $newSites = foreach ($c in $configured) {
        $p = $c.localPath
        $name = if ($c.name) { $c.name } else { Split-Path $p -Leaf }
        $key = Get-ProjectKey -ProjectPath $p
        $desired = $false
        $fails = 0

        if ($oldSites.ContainsKey($p)) {
            $desired = $oldSites[$p].Desired
            $fails = $oldSites[$p].Fails
        }
        else {
            # Adopt watchers that survived a previous tray
            $pidFile = Join-Path $StateDir "$key.pid"
            if (Test-Path $pidFile) {
                $existing = (Get-Content $pidFile -Raw).Trim()
                if (Get-Process -Id $existing -ErrorAction SilentlyContinue) { $desired = $true }
            }
        }

        [PSCustomObject]@{
            Path    = $p
            Name    = $name
            Key     = $key
            Item    = $null
            Desired = $desired
            Fails   = $fails
        }
    }

    $script:sites = @($newSites)
}

function Build-TrayMenu {
    $menu.Items.Clear()

    # Manage Sites item at top
    $miManage = New-Object System.Windows.Forms.ToolStripMenuItem
    $miManage.Text = 'Manage sites...'
    $miManage.Font = New-Object System.Drawing.Font($menu.Font, [System.Drawing.FontStyle]::Bold)
    $miManage.Add_Click({ Show-SiteManagerDialog })
    $menu.Items.Add($miManage) | Out-Null

    $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    if (-not $script:sites -or $script:sites.Count -eq 0) {
        $miEmpty = New-Object System.Windows.Forms.ToolStripMenuItem
        $miEmpty.Text = '(No sites configured - click Manage sites)'
        $miEmpty.Enabled = $false
        $menu.Items.Add($miEmpty) | Out-Null
    }
    else {
        foreach ($site in $script:sites) {
            $parent = New-Object System.Windows.Forms.ToolStripMenuItem
            $parent.Text = $site.Name

            $miStart = New-Object System.Windows.Forms.ToolStripMenuItem
            $miStart.Text = 'Start watching'
            $miStart.Add_Click({
                    $site.Desired = $true
                    $site.Fails = 0
                    Invoke-Engine -EngineAction 'start' -ProjectPath $site.Path
                }.GetNewClosure())

            $miStop = New-Object System.Windows.Forms.ToolStripMenuItem
            $miStop.Text = 'Stop watching'
            $miStop.Add_Click({
                    $site.Desired = $false
                    $site.Fails = 0
                    Invoke-Engine -EngineAction 'stop' -ProjectPath $site.Path
                }.GetNewClosure())

            $miOnce = New-Object System.Windows.Forms.ToolStripMenuItem
            $miOnce.Text = 'Deploy once...'
            $miOnce.Add_Click({ Start-DeployOnce -ProjectPath $site.Path }.GetNewClosure())

            $parent.DropDownItems.AddRange(@($miStart, $miStop, $miOnce)) | Out-Null
            $menu.Items.Add($parent) | Out-Null
            $site.Item = $parent
        }

        $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

        $miStartAll = New-Object System.Windows.Forms.ToolStripMenuItem
        $miStartAll.Text = 'Start all watchers'
        $miStartAll.Add_Click({ Start-AllWatchers })
        $menu.Items.Add($miStartAll) | Out-Null

        $miStopAll = New-Object System.Windows.Forms.ToolStripMenuItem
        $miStopAll.Text = 'Stop all watchers'
        $miStopAll.Add_Click({ Stop-AllWatchers })
        $menu.Items.Add($miStopAll) | Out-Null
    }

    $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    $miLogs = New-Object System.Windows.Forms.ToolStripMenuItem
    $miLogs.Text = 'Open log folder'
    $miLogs.Add_Click({ Start-Process explorer.exe $StateDir })
    $menu.Items.Add($miLogs) | Out-Null

    $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    $miExit = New-Object System.Windows.Forms.ToolStripMenuItem
    $miExit.Text = 'Stop everything and exit'
    $miExit.Add_Click({
            Stop-AllWatchers
            $appContext.ExitThread()
        })
    $menu.Items.Add($miExit) | Out-Null
}

function Update-SiteListAndMenu {
    Sync-SitesObjects
    Build-TrayMenu
}

# ---------------------------------------------------------------- tray UI
$iconIdle = New-DotIcon -Color ([System.Drawing.Color]::FromArgb(120, 120, 120))  # Grey: all idle
$iconBusy = New-DotIcon -Color ([System.Drawing.Color]::FromArgb(40, 180, 70))    # Green: all desired watching
$iconWarn = New-DotIcon -Color ([System.Drawing.Color]::FromArgb(235, 170, 0))    # Yellow: 1+ watchers down / failed

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = $iconIdle
$notify.Text = 'SyncPulse - idle'
$notify.Visible = $true
$notify.ContextMenuStrip = $menu

$appContext = New-Object System.Windows.Forms.ApplicationContext

# Initialize sites list and menu
Update-SiteListAndMenu

# ---------------------------------------------------------------- state polling
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 4000
$timer.Add_Tick({
        if (((Get-Date) - $script:lastPurge).TotalHours -ge 1) {
            Remove-OldLogs -Days $LogRetentionDays
            $script:lastPurge = Get-Date
        }
        $running = @()
        $down = @()

        foreach ($s in $script:sites) {
            $isOn = Test-Watching -Key $s.Key

            if ($isOn) {
                # Running normally: reset failure count so only consecutive failures count
                $s.Fails = 0
                $running += $s.Name
            }
            elseif ($s.Desired) {
                # A watcher is desired but not running: attempt auto-restart
                if ($s.Fails -lt 5) {
                    $s.Fails++
                    Invoke-Engine -EngineAction 'start' -ProjectPath $s.Path
                    # Only notify on persistent consecutive restart failures (attempt 3+) to prevent toast spam during routine reconnections
                    if ($s.Fails -ge 3) {
                        $notify.ShowBalloonTip(5000, 'SyncPulse',
                            "$($s.Name): watcher stopped unexpectedly - restarted (attempt $($s.Fails)).",
                            [System.Windows.Forms.ToolTipIcon]::Warning)
                    }
                    $isOn = Test-Watching -Key $s.Key
                    if ($isOn) {
                        $running += $s.Name
                    }
                    else {
                        $down += $s.Name
                    }
                }
                elseif ($s.Fails -eq 5) {
                    $s.Fails++
                    $s.Desired = $false
                    $notify.ShowBalloonTip(10000, 'SyncPulse',
                        "$($s.Name): watcher keeps dying. Giving up - check the log.",
                        [System.Windows.Forms.ToolTipIcon]::Error)
                    $down += $s.Name
                }
                else {
                    $down += $s.Name
                }
            }
            elseif ($s.Fails -gt 5) {
                # Project gave up after repeated failures and was not restarted yet
                $down += $s.Name
            }

            if ($s.Item) { $s.Item.Checked = $isOn }
        }

        # Status determination:
        # Yellow: 1 or more desired watchers are down/failed
        # Green: all desired watchers are active and running (>0)
        # Grey: all watchers are idle/stopped (0 desired, 0 running)
        $totalCount = if ($script:sites) { $script:sites.Count } else { 0 }
        if ($down.Count -gt 0) {
            $notify.Icon = $iconWarn
            $text = "SyncPulse - DOWN: " + ($down -join ', ') + " ($($running.Count)/$totalCount up)"
        }
        elseif ($running.Count -gt 0) {
            $notify.Icon = $iconBusy
            $text = "SyncPulse - watching ($($running.Count)/$totalCount): " + ($running -join ', ')
        }
        else {
            $notify.Icon = $iconIdle
            $text = 'SyncPulse - idle (all stopped)'
        }

        # NotifyIcon.Text throws above 63 characters.
        if ($text.Length -gt 63) { $text = $text.Substring(0, 60) + '...' }
        $notify.Text = $text
    })
$timer.Start()

# ---------------------------------------------------------------- run
# Start everything before entering the message loop. Projects already watching
# (adopted from a previous tray) are skipped rather than restarted.
if (-not $NoAutoStart) {
    Start-AllWatchers
    if ($script:sites.Count -gt 0) {
        $notify.ShowBalloonTip(4000, 'SyncPulse',
            "Watching $($script:sites.Count) project(s). Each runs a reconciling sync first.",
            [System.Windows.Forms.ToolTipIcon]::Info)
    }
}

try {
    [System.Windows.Forms.Application]::Run($appContext)
}
finally {
    # Without this the icon lingers in the tray until you mouse over it.
    $timer.Stop()
    $notify.Visible = $false
    $notify.Dispose()
    $iconIdle.Dispose()
    $iconBusy.Dispose()
    $iconWarn.Dispose()
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
