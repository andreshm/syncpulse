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

function New-DotBitmap {
    param([System.Drawing.Color]$Color)
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush $Color
    $g.FillEllipse($brush, 2, 2, 12, 12)
    $brush.Dispose(); $g.Dispose()
    return $bmp
}

function New-DotIconFromBitmap {
    param([System.Drawing.Bitmap]$Bmp)
    return [System.Drawing.Icon]::FromHandle($Bmp.GetHicon())
}

function New-DotIcon {
    param([System.Drawing.Color]$Color)
    $bmp = New-DotBitmap $Color
    $icon = New-DotIconFromBitmap $bmp
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

function Remove-OrphanWatchers {
    $activePids = New-Object System.Collections.Generic.HashSet[int]
    $pidFiles = Get-ChildItem -Path $StateDir -Filter '*.pid' -ErrorAction SilentlyContinue
    foreach ($f in $pidFiles) {
        $pVal = 0
        if ([int]::TryParse((Get-Content $f.FullName -Raw).Trim(), [ref]$pVal)) {
            $activePids.Add($pVal) | Out-Null
        }
    }

    $procs = Get-CimInstance Win32_Process -Filter "Name LIKE 'WinSCP%'" -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
        if ($p.CommandLine -like "*SyncPulse*") {
            if (-not $activePids.Contains($p.ProcessId) -and -not $activePids.Contains($p.ParentProcessId)) {
                try {
                    Start-Process -FilePath 'taskkill.exe' -ArgumentList @('/PID', $p.ProcessId, '/T', '/F') -NoNewWindow -Wait -ErrorAction SilentlyContinue | Out-Null
                } catch { }
            }
        }
    }
}

function Start-AllWatchers {
    Remove-OrphanWatchers
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

    $defaultIgnore = ".vscode, .git, .gitignore, .env*, *.pem, *.key, *.sql, *.sqlite, *.bak, node_modules, dist, build, *.log, *.map, vendor, _bk, __bk, _notes, deploy, .tmp*, .tmp_*, tmp_*, .sass-cache, .superpowers, .expo, web.conf*, web.config, * - Copy*, *.7z, *.zip, *.bat, *.cmd, .aiexclude, .gitmodules"
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

    $btnCompare = New-Object System.Windows.Forms.Button
    $btnCompare.Text = "Compare..."
    $btnCompare.Location = New-Object System.Drawing.Point($btnX, 130)
    $btnCompare.Size = New-Object System.Drawing.Size(105, 30)
    $btnCompare.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $btnCompare.Add_Click({
        if ($lv.SelectedItems.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Please select a site to compare.", "Selection Required", "OK", "Information")
            return
        }
        $selected = $lv.SelectedItems[0].Tag
        Show-SiteCompareDialog -Site $selected
    })

    $btnOpenJson = New-Object System.Windows.Forms.Button
    $btnOpenJson.Text = "Open sites.json"
    $btnOpenJson.Location = New-Object System.Drawing.Point($btnX, 168)
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

    $mgrForm.Controls.AddRange(@($lv, $btnAdd, $btnEdit, $btnRemove, $btnCompare, $btnOpenJson, $btnClose)) | Out-Null
    $mgrForm.ShowDialog() | Out-Null
}


# ---------------------------------------------------------------- Compare Dialog UI
function Show-SiteCompareDialog {
    param($Site)

    if (-not $Site) { return }
    $projPath = if ($Site.Path) { $Site.Path } else { $Site.localPath }
    $projName = if ($Site.Name) { $Site.Name } else { $Site.name }

    $cfg = Get-SiteConfig -ProjectPath $projPath
    if (-not $cfg) {
        [System.Windows.Forms.MessageBox]::Show("Could not load configuration for $projName.", "Configuration Error", "OK", "Error") | Out-Null
        return
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "SyncPulse - Compare with Remote: $projName"
    $form.Size = New-Object System.Drawing.Size(960, 620)
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.MinimumSize = New-Object System.Drawing.Size(760, 460)

    # Top Container holding Header banner and Options bar
    $pnlTop = New-Object System.Windows.Forms.Panel
    $pnlTop.Dock = [System.Windows.Forms.DockStyle]::Top
    $pnlTop.Height = 148
    $form.Controls.Add($pnlTop)

    # Header Panel (Top inside pnlTop)
    $pnlHeader = New-Object System.Windows.Forms.Panel
    $pnlHeader.Dock = [System.Windows.Forms.DockStyle]::Top
    $pnlHeader.Height = 56
    $pnlHeader.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)
    $pnlHeader.Padding = New-Object System.Windows.Forms.Padding(16, 8, 16, 8)
    $pnlTop.Controls.Add($pnlHeader)

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "Compare: $projName"
    $lblTitle.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    $lblTitle.Location = New-Object System.Drawing.Point(16, 6)
    $lblTitle.Size = New-Object System.Drawing.Size(600, 24)
    $pnlHeader.Controls.Add($lblTitle)

    $lblSubtitle = New-Object System.Windows.Forms.Label
    $lblSubtitle.Text = "Local: $projPath   ->   Remote: sftp://$($cfg.Username)@$($cfg.HostName):$($cfg.Port)$($cfg.RemotePath)"
    $lblSubtitle.ForeColor = [System.Drawing.Color]::FromArgb(90, 100, 110)
    $lblSubtitle.Location = New-Object System.Drawing.Point(16, 30)
    $lblSubtitle.Size = New-Object System.Drawing.Size(900, 20)
    $pnlHeader.Controls.Add($lblSubtitle)

    # Options Panel (Bottom inside pnlTop)
    $pnlOptions = New-Object System.Windows.Forms.Panel
    $pnlOptions.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $pnlOptions.Height = 92
    $pnlOptions.Padding = New-Object System.Windows.Forms.Padding(16, 6, 16, 6)
    $pnlTop.Controls.Add($pnlOptions)

    # Row 1: Exclusions toggle, Obsolete check, Compare Now button, Progress bar, Status
    $chkExclude = New-Object System.Windows.Forms.CheckBox
    $chkExclude.Text = "Exclude ignored files / folders"
    $chkExclude.Checked = $true
    $chkExclude.Location = New-Object System.Drawing.Point(16, 8)
    $chkExclude.Size = New-Object System.Drawing.Size(205, 24)
    $pnlOptions.Controls.Add($chkExclude)

    $chkDelete = New-Object System.Windows.Forms.CheckBox
    $chkDelete.Text = "Check remote obsolete (with delete)"
    $chkDelete.Checked = $false
    $chkDelete.Location = New-Object System.Drawing.Point(228, 8)
    $chkDelete.Size = New-Object System.Drawing.Size(225, 24)
    $pnlOptions.Controls.Add($chkDelete)

    $btnCompare = New-Object System.Windows.Forms.Button
    $btnCompare.Text = "Compare Now"
    $btnCompare.Location = New-Object System.Drawing.Point(460, 6)
    $btnCompare.Size = New-Object System.Drawing.Size(115, 28)
    $btnCompare.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $pnlOptions.Controls.Add($btnCompare)

    $pb = New-Object System.Windows.Forms.ProgressBar
    $pb.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $pb.Location = New-Object System.Drawing.Point(585, 10)
    $pb.Size = New-Object System.Drawing.Size(100, 20)
    $pb.Visible = $false
    $pnlOptions.Controls.Add($pb)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = "Ready. Add any extra exclusions and click 'Compare Now'."
    $lblStatus.Location = New-Object System.Drawing.Point(695, 10)
    $lblStatus.Size = New-Object System.Drawing.Size(245, 20)
    $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(70, 80, 90)
    $lblStatus.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $pnlOptions.Controls.Add($lblStatus)

    # Row 2: Extra exclusions input box, File picker, Folder picker, Save to sites.json toggle
    $lblExtra = New-Object System.Windows.Forms.Label
    $lblExtra.Text = "Extra exclusions:"
    $lblExtra.Location = New-Object System.Drawing.Point(16, 46)
    $lblExtra.Size = New-Object System.Drawing.Size(105, 22)
    $lblExtra.ForeColor = [System.Drawing.Color]::FromArgb(70, 80, 90)
    $pnlOptions.Controls.Add($lblExtra)

    $tbExtra = New-Object System.Windows.Forms.TextBox
    $tbExtra.Location = New-Object System.Drawing.Point(124, 44)
    $tbExtra.Size = New-Object System.Drawing.Size(445, 24)
    $tbExtra.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $tipExtra = New-Object System.Windows.Forms.ToolTip
    $tipExtra.SetToolTip($tbExtra, "Comma-separated patterns to exclude, e.g. *.log, temp/, cache/, secret.json")
    $pnlOptions.Controls.Add($tbExtra)

    $btnAddFile = New-Object System.Windows.Forms.Button
    $btnAddFile.Text = "+ File..."
    $btnAddFile.Location = New-Object System.Drawing.Point(578, 43)
    $btnAddFile.Size = New-Object System.Drawing.Size(75, 26)
    $btnAddFile.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $btnAddFile.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.InitialDirectory = $projPath
        $ofd.Title = "Select File to Exclude from Comparison"
        if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $fn = $ofd.FileName
            $rel = if ($fn.StartsWith($projPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                $fn.Substring($projPath.Length).TrimStart('\', '/').Replace('\', '/')
            } else {
                [System.IO.Path]::GetFileName($fn)
            }
            if ($rel) {
                if ($tbExtra.Text.Trim()) {
                    $tbExtra.Text = $tbExtra.Text.Trim().TrimEnd(',') + ", " + $rel
                } else {
                    $tbExtra.Text = $rel
                }
            }
        }
    })
    $pnlOptions.Controls.Add($btnAddFile)

    $btnAddFolder = New-Object System.Windows.Forms.Button
    $btnAddFolder.Text = "+ Folder..."
    $btnAddFolder.Location = New-Object System.Drawing.Point(658, 43)
    $btnAddFolder.Size = New-Object System.Drawing.Size(85, 26)
    $btnAddFolder.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $btnAddFolder.Add_Click({
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fbd.SelectedPath = $projPath
        $fbd.Description = "Select Folder to Exclude from Comparison"
        if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $fp = $fbd.SelectedPath
            $rel = if ($fp.StartsWith($projPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                $fp.Substring($projPath.Length).TrimStart('\', '/').Replace('\', '/') + "/"
            } else {
                [System.IO.Path]::GetFileName($fp) + "/"
            }
            if ($rel -and $rel -ne "/") {
                if ($tbExtra.Text.Trim()) {
                    $tbExtra.Text = $tbExtra.Text.Trim().TrimEnd(',') + ", " + $rel
                } else {
                    $tbExtra.Text = $rel
                }
            }
        }
    })
    $pnlOptions.Controls.Add($btnAddFolder)

    $chkSaveToSite = New-Object System.Windows.Forms.CheckBox
    $chkSaveToSite.Text = "Save extra to sites.json"
    $chkSaveToSite.Checked = $false
    $chkSaveToSite.Location = New-Object System.Drawing.Point(752, 45)
    $chkSaveToSite.Size = New-Object System.Drawing.Size(180, 22)
    $chkSaveToSite.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $pnlOptions.Controls.Add($chkSaveToSite)

    # Bottom Container holding selection helpers and action buttons
    $pnlBottomContainer = New-Object System.Windows.Forms.Panel
    $pnlBottomContainer.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $pnlBottomContainer.Height = 82
    $form.Controls.Add($pnlBottomContainer)

    # Sub-bar for selection helpers (Top of bottom container)
    $pnlSelect = New-Object System.Windows.Forms.Panel
    $pnlSelect.Dock = [System.Windows.Forms.DockStyle]::Top
    $pnlSelect.Height = 28
    $pnlSelect.Padding = New-Object System.Windows.Forms.Padding(16, 2, 16, 2)
    $pnlBottomContainer.Controls.Add($pnlSelect)

    $lblSelect = New-Object System.Windows.Forms.Label
    $lblSelect.Text = "Select:"
    $lblSelect.Location = New-Object System.Drawing.Point(16, 4)
    $lblSelect.Size = New-Object System.Drawing.Size(46, 20)
    $lblSelect.ForeColor = [System.Drawing.Color]::Gray
    $pnlSelect.Controls.Add($lblSelect)

    $lnkAll = New-Object System.Windows.Forms.LinkLabel
    $lnkAll.Text = "All"
    $lnkAll.Location = New-Object System.Drawing.Point(65, 4)
    $lnkAll.Size = New-Object System.Drawing.Size(25, 20)
    $pnlSelect.Controls.Add($lnkAll)

    $lnkNone = New-Object System.Windows.Forms.LinkLabel
    $lnkNone.Text = "None"
    $lnkNone.Location = New-Object System.Drawing.Point(95, 4)
    $lnkNone.Size = New-Object System.Drawing.Size(35, 20)
    $pnlSelect.Controls.Add($lnkNone)

    $lnkMod = New-Object System.Windows.Forms.LinkLabel
    $lnkMod.Text = "Modified Only"
    $lnkMod.Location = New-Object System.Drawing.Point(135, 4)
    $lnkMod.Size = New-Object System.Drawing.Size(85, 20)
    $pnlSelect.Controls.Add($lnkMod)

    $lnkNew = New-Object System.Windows.Forms.LinkLabel
    $lnkNew.Text = "New Only"
    $lnkNew.Location = New-Object System.Drawing.Point(225, 4)
    $lnkNew.Size = New-Object System.Drawing.Size(65, 20)
    $pnlSelect.Controls.Add($lnkNew)

    # Bottom Actions Panel (Bottom of bottom container)
    $pnlBottom = New-Object System.Windows.Forms.Panel
    $pnlBottom.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $pnlBottom.Height = 52
    $pnlBottom.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)
    $pnlBottomContainer.Controls.Add($pnlBottom)

    $lblSummary = New-Object System.Windows.Forms.Label
    $lblSummary.Text = "Differences: 0  |  Selected: 0"
    $lblSummary.Location = New-Object System.Drawing.Point(16, 16)
    $lblSummary.Size = New-Object System.Drawing.Size(260, 23)
    $lblSummary.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $pnlBottom.Controls.Add($lblSummary)

    $btnUploadSelected = New-Object System.Windows.Forms.Button
    $btnUploadSelected.Text = "Upload Selected (0)"
    $btnUploadSelected.Location = New-Object System.Drawing.Point(290, 12)
    $btnUploadSelected.Size = New-Object System.Drawing.Size(155, 30)
    $btnUploadSelected.Enabled = $false
    $pnlBottom.Controls.Add($btnUploadSelected)

    $btnUploadAll = New-Object System.Windows.Forms.Button
    $btnUploadAll.Text = "Upload All Differences"
    $btnUploadAll.Location = New-Object System.Drawing.Point(455, 12)
    $btnUploadAll.Size = New-Object System.Drawing.Size(160, 30)
    $btnUploadAll.Enabled = $false
    $pnlBottom.Controls.Add($btnUploadAll)

    $btnCopy = New-Object System.Windows.Forms.Button
    $btnCopy.Text = "Copy Report"
    $btnCopy.Location = New-Object System.Drawing.Point(625, 12)
    $btnCopy.Size = New-Object System.Drawing.Size(100, 30)
    $btnCopy.Enabled = $false
    $pnlBottom.Controls.Add($btnCopy)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(835, 12)
    $btnClose.Size = New-Object System.Drawing.Size(95, 30)
    $btnClose.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $btnClose.Add_Click({ $form.Close() })
    $pnlBottom.Controls.Add($btnClose)

    # Main ListView
    $lv = New-Object System.Windows.Forms.ListView
    $lv.Dock = [System.Windows.Forms.DockStyle]::Fill
    $lv.View = [System.Windows.Forms.View]::Details
    $lv.FullRowSelect = $true
    $lv.GridLines = $true
    $lv.CheckBoxes = $true
    $lv.HideSelection = $false
    $form.Controls.Add($lv)

    # Explicit z-ordering to ensure Fill stays cleanly between Top and Bottom containers
    $pnlTop.SendToBack()
    $pnlBottomContainer.SendToBack()
    $lv.BringToFront()

    # Columns
    $lv.Columns.Add("File / Directory", 320) | Out-Null
    $lv.Columns.Add("Status", 140) | Out-Null
    $lv.Columns.Add("Local Size", 85) | Out-Null
    $lv.Columns.Add("Remote Size", 85) | Out-Null
    $lv.Columns.Add("Local Modified", 130) | Out-Null
    $lv.Columns.Add("Remote Modified", 130) | Out-Null

    $currentDiffs = @()

    $updateSelectionCount = {
        $selCount = $lv.CheckedItems.Count
        $totCount = $lv.Items.Count
        $lblSummary.Text = "Differences: $totCount  |  Selected: $selCount"
        $btnUploadSelected.Text = "Upload Selected ($selCount)"
        $btnUploadSelected.Enabled = ($selCount -gt 0)
        $btnUploadAll.Enabled = ($totCount -gt 0)
        $btnCopy.Enabled = ($totCount -gt 0)
    }

    $lv.Add_ItemChecked({ & $updateSelectionCount })

    $lnkAll.Add_LinkClicked({
        foreach ($item in $lv.Items) { $item.Checked = $true }
        & $updateSelectionCount
    })
    $lnkNone.Add_LinkClicked({
        foreach ($item in $lv.Items) { $item.Checked = $false }
        & $updateSelectionCount
    })
    $lnkMod.Add_LinkClicked({
        foreach ($item in $lv.Items) {
            $d = $item.Tag
            $item.Checked = ($d -and $d.Action -eq 'uploadupdate')
        }
        & $updateSelectionCount
    })
    $lnkNew.Add_LinkClicked({
        foreach ($item in $lv.Items) {
            $d = $item.Tag
            $item.Checked = ($d -and $d.Action -eq 'uploadnew')
        }
        & $updateSelectionCount
    })

    $runCompare = {
        $btnCompare.Enabled = $false
        $btnUploadSelected.Enabled = $false
        $btnUploadAll.Enabled = $false
        $pb.Visible = $true
        $lblStatus.Text = "Scanning differences..."
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $form.Refresh()

        $exclude = $chkExclude.Checked
        $withDel = $chkDelete.Checked

        # Extract extra exclusion patterns
        $extraArr = @($tbExtra.Text -split '[,;\r\n]+' | ForEach-Object { $_.Trim().Replace('\\', '/') } | Where-Object { $_ })

        # Save extra exclusions permanently to sites.json if checked
        if ($chkSaveToSite.Checked -and $extraArr.Count -gt 0) {
            $cfgList = @(Get-ConfiguredSites)
            $updated = $false
            for ($i = 0; $i -lt $cfgList.Count; $i++) {
                if ($cfgList[$i].localPath -eq $projPath -or $cfgList[$i].name -eq $projName) {
                    $currentIg = [System.Collections.Generic.List[string]]::new(@($cfgList[$i].ignore))
                    foreach ($entry in $extraArr) {
                        if (-not $currentIg.Contains($entry)) {
                            $currentIg.Add($entry)
                            $updated = $true
                        }
                    }
                    $cfgList[$i].ignore = @($currentIg)
                    $cfg.Ignore = @($currentIg)
                    break
                }
            }
            if ($updated) {
                $sitesFile = Get-SitesConfigFile
                $cfgList | ConvertTo-Json -Depth 5 | Set-Content -Path $sitesFile -Encoding UTF8
            }
        }

        $res = Invoke-SiteCompare -Config $cfg -LocalPath $projPath -ExcludeIgnored:$exclude -ExtraIgnore $extraArr -WithDelete:$withDel

        $lv.Items.Clear()
        $currentDiffs = @($res.Differences)

        if (-not $res.Success) {
            $lblStatus.Text = "Error during comparison."
            [System.Windows.Forms.MessageBox]::Show("Comparison failed to complete. Check network or server connection.", "Comparison Error", "OK", "Warning") | Out-Null
        }
        elseif ($currentDiffs.Count -eq 0) {
            $lblStatus.Text = "Everything in sync!"
            $item = New-Object System.Windows.Forms.ListViewItem("(No differences - local and remote are completely in sync)")
            $item.ForeColor = [System.Drawing.Color]::ForestGreen
            $item.SubItems.Add("In Sync") | Out-Null
            $lv.Items.Add($item) | Out-Null
        }
        else {
            $lblStatus.Text = "$($currentDiffs.Count) difference(s) found."
            foreach ($d in $currentDiffs) {
                $item = New-Object System.Windows.Forms.ListViewItem($d.Relative)
                $item.Tag = $d
                $item.Checked = $true

                # Status column
                $item.SubItems.Add($d.Status) | Out-Null

                # Local Size
                $item.SubItems.Add((Format-FileSize $d.LocalSize)) | Out-Null

                # Remote Size
                $item.SubItems.Add((Format-FileSize $d.RemoteSize)) | Out-Null

                # Local Modified
                $locModStr = if ($d.LocalMod) { $d.LocalMod.ToString("yyyy-MM-dd HH:mm:ss") } else { "-" }
                $item.SubItems.Add($locModStr) | Out-Null

                # Remote Modified
                $remModStr = if ($d.RemoteMod) { $d.RemoteMod.ToString("yyyy-MM-dd HH:mm:ss") } else { "-" }
                $item.SubItems.Add($remModStr) | Out-Null

                # Color coding
                if ($d.Action -eq 'uploadnew') {
                    $item.ForeColor = [System.Drawing.Color]::FromArgb(0, 102, 204) # Blue for new
                }
                elseif ($d.Action -eq 'uploadupdate') {
                    $item.ForeColor = [System.Drawing.Color]::FromArgb(180, 90, 0) # Amber for modified
                }
                elseif ($d.Action -eq 'delete') {
                    $item.ForeColor = [System.Drawing.Color]::FromArgb(180, 0, 0) # Red for obsolete
                }

                $lv.Items.Add($item) | Out-Null
            }
        }

        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $pb.Visible = $false
        $btnCompare.Enabled = $true
        & $updateSelectionCount
    }

    $btnCompare.Add_Click({ & $runCompare })

    $btnUploadSelected.Add_Click({
        $selectedItems = foreach ($item in $lv.CheckedItems) {
            if ($item.Tag) { $item.Tag }
        }
        if (-not $selectedItems -or $selectedItems.Count -eq 0) { return }

        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Upload $($selectedItems.Count) selected item(s) to $($cfg.HostName)$($cfg.RemotePath)?",
            "Confirm Upload",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)

        if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
            $btnUploadSelected.Enabled = $false
            $btnUploadAll.Enabled = $false
            $btnCompare.Enabled = $false
            $pb.Visible = $true
            $lblStatus.Text = "Uploading selected items..."
            $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            $form.Refresh()

            $extraArr = @($tbExtra.Text -split '[,;\r\n]+' | ForEach-Object { $_.Trim().Replace('\\', '/') } | Where-Object { $_ })
            $upRes = Invoke-SiteUploadDiffs -Config $cfg -LocalPath $projPath -Items $selectedItems -ExcludeIgnored:$chkExclude.Checked -ExtraIgnore $extraArr -WithDelete:$chkDelete.Checked

            $form.Cursor = [System.Windows.Forms.Cursors]::Default
            $pb.Visible = $false
            $btnCompare.Enabled = $true

            if ($upRes.Success) {
                [System.Windows.Forms.MessageBox]::Show("Successfully uploaded selected item(s)!", "Upload Complete", "OK", "Information") | Out-Null
                & $runCompare
            } else {
                [System.Windows.Forms.MessageBox]::Show("Upload encountered errors. Check log.", "Upload Error", "OK", "Error") | Out-Null
            }
        }
    })

    $btnUploadAll.Add_Click({
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Synchronize all differences to $($cfg.HostName)$($cfg.RemotePath)?`n`n(ExcludeIgnored: $($chkExclude.Checked), Delete: $($chkDelete.Checked))",
            "Confirm Upload All",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)

        if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
            $btnUploadSelected.Enabled = $false
            $btnUploadAll.Enabled = $false
            $btnCompare.Enabled = $false
            $pb.Visible = $true
            $lblStatus.Text = "Synchronizing all differences..."
            $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            $form.Refresh()

            $extraArr = @($tbExtra.Text -split '[,;\r\n]+' | ForEach-Object { $_.Trim().Replace('\\', '/') } | Where-Object { $_ })
            $upRes = Invoke-SiteUploadDiffs -Config $cfg -LocalPath $projPath -UploadAll -ExcludeIgnored:$chkExclude.Checked -ExtraIgnore $extraArr -WithDelete:$chkDelete.Checked

            $form.Cursor = [System.Windows.Forms.Cursors]::Default
            $pb.Visible = $false
            $btnCompare.Enabled = $true

            if ($upRes.Success) {
                [System.Windows.Forms.MessageBox]::Show("Successfully synchronized all differences!", "Upload Complete", "OK", "Information") | Out-Null
                & $runCompare
            } else {
                [System.Windows.Forms.MessageBox]::Show("Synchronization encountered errors. Check log.", "Upload Error", "OK", "Error") | Out-Null
            }
        }
    })

    $btnCopy.Add_Click({
        if ($lv.Items.Count -eq 0) { return }
        $sb = New-Object System.Text.StringBuilder
        $sb.AppendLine("SyncPulse Difference Report - $projName") | Out-Null
        $sb.AppendLine("Local: $projPath") | Out-Null
        $sb.AppendLine("Remote: $($cfg.HostName)$($cfg.RemotePath)") | Out-Null
        $sb.AppendLine("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')") | Out-Null
        $sb.AppendLine("=" * 80) | Out-Null
        $sb.AppendLine(("{0,-35} {1,-20} {2,-12} {3,-12}" -f "File", "Status", "Local Size", "Remote Size")) | Out-Null
        $sb.AppendLine("-" * 80) | Out-Null
        foreach ($item in $lv.Items) {
            if ($item.Tag) {
                $d = $item.Tag
                $sb.AppendLine(("{0,-35} {1,-20} {2,-12} {3,-12}" -f $d.Relative, $d.Status, (Format-FileSize $d.LocalSize), (Format-FileSize $d.RemoteSize))) | Out-Null
            }
        }
        [System.Windows.Forms.Clipboard]::SetText($sb.ToString())
        [System.Windows.Forms.MessageBox]::Show("Report copied to clipboard!", "Report Copied", "OK", "Information") | Out-Null
    })

    # Do not compare on load. The user must click 'Compare Now' to scan.
    $form.ShowDialog() | Out-Null
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
            $parent.Image = $bmpIdle

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

            $miCompare = New-Object System.Windows.Forms.ToolStripMenuItem
            $miCompare.Text = 'Compare with remote...'
            $miCompare.Add_Click({ Show-SiteCompareDialog -Site $site }.GetNewClosure())

            $parent.DropDownItems.AddRange(@($miStart, $miStop, $miOnce, $miCompare)) | Out-Null
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
$bmpIdle = New-DotBitmap ([System.Drawing.Color]::FromArgb(120, 120, 120))       # Grey: all idle / stopped
$bmpBusy = New-DotBitmap ([System.Drawing.Color]::FromArgb(40, 180, 70))         # Green: watching
$bmpWarn = New-DotBitmap ([System.Drawing.Color]::FromArgb(235, 170, 0))         # Yellow: down / warning
$bmpSync = New-DotBitmap ([System.Drawing.Color]::FromArgb(0, 150, 240))         # Cyan: startup comparing
$bmpSyncBlink = New-DotBitmap ([System.Drawing.Color]::FromArgb(140, 225, 255))   # Bright Sky: blinking pulse

$iconIdle = New-DotIconFromBitmap $bmpIdle
$iconBusy = New-DotIconFromBitmap $bmpBusy
$iconWarn = New-DotIconFromBitmap $bmpWarn
$iconSync = New-DotIconFromBitmap $bmpSync
$iconSyncBlink = New-DotIconFromBitmap $bmpSyncBlink

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
$script:blinkToggle = $false
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
        $script:blinkToggle = -not $script:blinkToggle

        if (((Get-Date) - $script:lastPurge).TotalHours -ge 1) {
            Remove-OldLogs -Days $LogRetentionDays
            $script:lastPurge = Get-Date
        }
        $running = @()
        $comparing = @()
        $down = @()

        foreach ($s in $script:sites) {
            $isOn = Test-Watching -Key $s.Key

            if ($isOn) {
                # Running normally: reset failure count so only consecutive failures count
                $s.Fails = 0
                $isComp = Test-SiteStartupComparing -Key $s.Key
                if ($isComp) {
                    $comparing += $s.Name
                    if ($s.Item) {
                        $s.Item.Image = if ($script:blinkToggle) { $bmpSync } else { $bmpSyncBlink }
                        $s.Item.Text = "$($s.Name)  (Comparing...)"
                        $s.Item.Checked = $true
                    }
                }
                else {
                    $running += $s.Name
                    if ($s.Item) {
                        $s.Item.Image = $bmpBusy
                        $s.Item.Text = $s.Name
                        $s.Item.Checked = $true
                    }
                }
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
                        if (Test-SiteStartupComparing -Key $s.Key) {
                            $comparing += $s.Name
                            if ($s.Item) {
                                $s.Item.Image = if ($script:blinkToggle) { $bmpSync } else { $bmpSyncBlink }
                                $s.Item.Text = "$($s.Name)  (Comparing...)"
                                $s.Item.Checked = $true
                            }
                        }
                        else {
                            $running += $s.Name
                            if ($s.Item) {
                                $s.Item.Image = $bmpBusy
                                $s.Item.Text = $s.Name
                                $s.Item.Checked = $true
                            }
                        }
                    }
                    else {
                        $down += $s.Name
                        if ($s.Item) {
                            $s.Item.Image = $bmpWarn
                            $s.Item.Text = "$($s.Name)  (Restarting $($s.Fails)/5...)"
                            $s.Item.Checked = $false
                        }
                    }
                }
                elseif ($s.Fails -ge 5) {
                    # Notify once when threshold reached, then cool down for 60s and retry cleanly
                    if ($s.Fails -eq 5) {
                        $notify.ShowBalloonTip(8000, 'SyncPulse',
                            "$($s.Name): connection issues. Will retry in 1 minute - check log.",
                            [System.Windows.Forms.ToolTipIcon]::Warning)
                    }
                    $s.Fails++
                    if ($s.Fails -ge 65) {
                        # Cool-down finished: clean any orphan processes and attempt fresh start
                        Remove-OrphanWatchers
                        $s.Fails = 1
                    }
                    $down += $s.Name
                    if ($s.Item) {
                        $s.Item.Image = $bmpWarn
                        $s.Item.Text = "$($s.Name)  (Down - retrying)"
                        $s.Item.Checked = $false
                    }
                }
                else {
                    $down += $s.Name
                    if ($s.Item) {
                        $s.Item.Image = $bmpWarn
                        $s.Item.Text = "$($s.Name)  (Down)"
                        $s.Item.Checked = $false
                    }
                }
            }
            elseif ($s.Fails -gt 5) {
                # Project gave up after repeated failures and was not restarted yet
                $down += $s.Name
                if ($s.Item) {
                    $s.Item.Image = $bmpWarn
                    $s.Item.Text = "$($s.Name)  (Down)"
                    $s.Item.Checked = $false
                }
            }
            else {
                if ($s.Item) {
                    $s.Item.Image = $bmpIdle
                    $s.Item.Text = $s.Name
                    $s.Item.Checked = $false
                }
            }
        }

        # Status determination:
        # Cyan (blinking): 1 or more watchers are performing startup comparison
        # Yellow: 1 or more desired watchers are down/failed
        # Green: all desired watchers are active and running (>0)
        # Grey: all watchers are idle/stopped (0 desired, 0 running)
        $totalCount = if ($script:sites) { $script:sites.Count } else { 0 }
        if ($comparing.Count -gt 0) {
            $notify.Icon = if ($script:blinkToggle) { $iconSync } else { $iconSyncBlink }
            $text = "SyncPulse - startup comparing ($($comparing.Count)/$totalCount): " + ($comparing -join ', ')
        }
        elseif ($down.Count -gt 0) {
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
    $iconSync.Dispose()
    $iconSyncBlink.Dispose()
    $bmpIdle.Dispose()
    $bmpBusy.Dispose()
    $bmpWarn.Dispose()
    $bmpSync.Dispose()
    $bmpSyncBlink.Dispose()
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
