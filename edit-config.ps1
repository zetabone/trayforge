# TrayCommands Config Editor — graphical config.json editor
# Launch: double-click edit-config.vbs (or powershell -File edit-config.ps1)
param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ScriptDir = if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
$ConfigPath = Join-Path $ScriptDir 'config.json'

# ---------- utilities ----------

function Strip-JsComments {
    param([string]$Json)
    $sb = New-Object System.Text.StringBuilder
    $inStr = $false
    $i = 0
    $len = $Json.Length
    while ($i -lt $len) {
        $ch = $Json[$i]
        if ($inStr) {
            if ($ch -eq '\') {
                [void]$sb.Append($Json.Substring($i, [Math]::Min(2, $len - $i)))
                $i += 2
                continue
            }
            if ($ch -eq '"') { $inStr = $false }
            [void]$sb.Append($ch)
            $i++
            continue
        }
        if ($ch -eq '"') {
            $inStr = $true
            [void]$sb.Append($ch)
            $i++
            continue
        }
        if ($ch -eq '/' -and $i + 1 -lt $len) {
            $next = $Json[$i + 1]
            if ($next -eq '/') {
                while ($i -lt $len -and $Json[$i] -ne "`n") { $i++ }
                continue
            }
            if ($next -eq '*') {
                $i += 2
                while ($i + 1 -lt $len -and -not ($Json[$i] -eq '*' -and $Json[$i + 1] -eq '/')) { $i++ }
                $i += 2
                continue
            }
        }
        [void]$sb.Append($ch)
        $i++
    }
    return $sb.ToString()
}

function JsonEscape {
    param([string]$s)
    $s = $s.Replace('\', '\\').Replace('"', '\"')
    $s = $s.Replace("`r`n", '\n').Replace("`r", '\n').Replace("`n", '\n').Replace("`t", '\t')
    return $s
}

function Get-CommandsOf {
    param($Item)
    if ($Item.commands) { return @($Item.commands) }
    if ($null -ne $Item.command) { return @("$($Item.command)") }
    return @()
}

function New-DefaultCommand {
    return [pscustomobject]@{
        name    = 'New Command'
        icon    = ''
        shell   = 'powershell'
        command = ''
        window  = 'hidden'
    }
}

# ---------- serialization to JSON with comments ----------

function ConvertTo-CommandJson {
    param($C, [int]$Indent)
    $pad = ' ' * $Indent
    $props = New-Object System.Collections.Generic.List[string]

    $props.Add(('"name": "' + (JsonEscape "$($C.name)") + '"'))

    if ("$($C.icon)" -ne '') {
        $props.Add(('"icon": "' + (JsonEscape "$($C.icon)") + '"'))
    }

    $sh = "$($C.shell)"
    if (-not $sh) { $sh = 'powershell' }
    $props.Add(('"shell": "' + $sh + '"'))

    $cmds = @(Get-CommandsOf $C)
    if ($cmds.Count -eq 1) {
        $props.Add(('"command": "' + (JsonEscape $cmds[0]) + '"'))
    } elseif ($cmds.Count -gt 1) {
        $inner = ($cmds | ForEach-Object { $pad + '        "' + (JsonEscape "$_") + '"' }) -join ",`r`n"
        $props.Add(('"commands": [' + "`r`n" + $inner + "`r`n" + $pad + '    ]'))
    }

    $wn = "$($C.window)"
    if (-not $wn) { $wn = 'hidden' }
    $props.Add(('"window": "' + $wn + '"'))

    if ("$($C.cwd)" -ne '') {
        $props.Add(('"cwd": "' + (JsonEscape "$($C.cwd)") + '"'))
    }
    if ($null -ne $C.keepOpen) {
        $v = 'false'
        if ($C.keepOpen) { $v = 'true' }
        $props.Add(('"keepOpen": ' + $v))
    }
    if ($C.confirm)        { $props.Add('"confirm": true') }
    if ($C.notify)         { $props.Add('"notify": true') }
    if ($C.separatorAfter) { $props.Add('"separatorAfter": true') }

    $body = ($props | ForEach-Object { $pad + '    ' + $_ }) -join ",`r`n"
    return $pad + "{`r`n" + $body + "`r`n" + $pad + '}'
}

function Get-ConfigText {
    param($Cfg)
    $icon = JsonEscape "$($Cfg.icon)"
    if (-not $icon) { $icon = 'imageres.dll,76' }
    $tip = JsonEscape "$($Cfg.tooltip)"
    if (-not $tip) { $tip = 'TrayCommands' }
    $mode = "$($Cfg.mode)"
    if ($mode -ne 'icons') { $mode = 'text' }
    $dcwd = JsonEscape "$($Cfg.defaultCwd)"

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('{')
    [void]$sb.AppendLine('    // Tray icon: "file.ico", "shell32.dll,44" or "imageres.dll,-109".')
    [void]$sb.Append('    "icon": "' + $icon + '",')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('    // Tooltip shown on hover.')
    [void]$sb.Append('    "tooltip": "' + $tip + '",')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('    // Menu style: "text" (text with icons) | "icons" (large icons).')
    [void]$sb.Append('    "mode": "' + $mode + '",')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('    // Default working directory for PowerShell/CMD windows ("%USERPROFILE%", "C:\\path").')
    [void]$sb.Append('    "defaultCwd": "' + $dcwd + '",')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('    // Commands. Fields:')
    [void]$sb.AppendLine('    //   name - label; icon - icon; shell - powershell|pwsh|cmd|auto;')
    [void]$sb.AppendLine('    //   command - single command OR commands - array of commands (single session);')
    [void]$sb.AppendLine('    //   window - hidden|normal|minimized; cwd - custom directory (otherwise defaultCwd);')
    [void]$sb.AppendLine('    //   keepOpen - keep window open; confirm - confirmation prompt;')
    [void]$sb.AppendLine('    //   notify - notification on completion; separatorAfter - separator after item.')
    [void]$sb.Append('    "commands": [')
    [void]$sb.AppendLine('')
    $texts = foreach ($c in @($Cfg.commands)) { ConvertTo-CommandJson -C $c -Indent 8 }
    [void]$sb.Append(($texts -join ",`r`n`r`n"))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('    ]')
    [void]$sb.Append('}')
    return $sb.ToString()
}

function Save-ConfigFile {
    param($Cfg)
    $text = Get-ConfigText -Cfg $Cfg
    $enc = New-Object System.Text.UTF8Encoding $true
    [IO.File]::WriteAllText($ConfigPath, $text, $enc)
}

function Load-ConfigObject {
    param([string]$Path)
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $clean = Strip-JsComments $raw
    $cfg = $clean | ConvertFrom-Json
    if (-not $cfg.commands) {
        $cfg | Add-Member NoteProperty commands @() -Force
    }
    return $cfg
}

# ---------- self-test without GUI ----------

if ($SelfTest) {
    $sample = [pscustomobject]@{
        icon       = 'imageres.dll,76'
        tooltip    = 'Test quotes " and \ backslash'
        mode       = 'text'
        defaultCwd = '%USERPROFILE%'
        commands   = @(
            [pscustomobject]@{ name = 'First'; icon = 'shell32.dll,21'; shell = 'cmd'; command = 'echo "hello \ world"'; window = 'normal' },
            [pscustomobject]@{ name = 'Second'; shell = 'powershell'; window = 'hidden'; commands = @('cd test', 'npm run dev'); keepOpen = $true; confirm = $true; separatorAfter = $true }
        )
    }
    $oldCfgPath = $ConfigPath
    $tmp = Join-Path $env:TEMP 'tray-selftest.json'
    Set-Variable -Name ConfigPath -Value $tmp
    Save-ConfigFile -Cfg $sample
    $back = Load-ConfigObject -Path $tmp
    $ok = $true
    if (@($back.commands).Count -ne 2) { $ok = $false; Write-Host 'FAIL: commands count' }
    if ($back.tooltip -ne $sample.tooltip) { $ok = $false; Write-Host 'FAIL: tooltip escape' }
    $c1 = @($back.commands)[0]
    if ($c1.command -ne 'echo "hello \ world"') { $ok = $false; Write-Host 'FAIL: quote escape' }
    $c2 = @($back.commands)[1]
    if (@($c2.commands).Count -ne 2) { $ok = $false; Write-Host 'FAIL: commands array count' }
    if (@($c2.commands)[1] -ne 'npm run dev') { $ok = $false; Write-Host 'FAIL: commands array item' }
    if ($c2.keepOpen -ne $true -or $c2.confirm -ne $true -or $c2.separatorAfter -ne $true) { $ok = $false; Write-Host 'FAIL: flags' }
    Remove-Item -LiteralPath $tmp -Force
    Set-Variable -Name ConfigPath -Value $oldCfgPath
    if ($ok) { Write-Host 'SELFTEST OK' } else { exit 1 }
    exit 0
}

# ---------- load config ----------

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    [System.Windows.Forms.MessageBox]::Show("File not found:`r`n$ConfigPath", 'TrayCommands',
        'OK', 'Error') | Out-Null
    exit 1
}
try {
    $cfg = Load-ConfigObject -Path $ConfigPath
} catch {
    [System.Windows.Forms.MessageBox]::Show("Error reading config.json:`r`n$($_.Exception.Message)",
        'TrayCommands', 'OK', 'Error') | Out-Null
    exit 1
}
$script:cmds = New-Object System.Collections.ArrayList
foreach ($c in @($cfg.commands)) { [void]$script:cmds.Add($c) }
$script:dirty = $false

# ---------- command edit dialog ----------

function Show-CommandDialog {
    param($Cmd)

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Command'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.StartPosition = 'CenterParent'
    $dlg.ClientSize = New-Object System.Drawing.Size(520, 500)
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $dlg.MaximizeBox = $false

    $lblName = New-Object System.Windows.Forms.Label
    $lblName.Location = New-Object System.Drawing.Point(15, 23)
    $lblName.AutoSize = $true
    $lblName.Text = 'Name:'
    $dlg.Controls.Add($lblName)

    $tbName = New-Object System.Windows.Forms.TextBox
    $tbName.Location = New-Object System.Drawing.Point(130, 20)
    $tbName.Size = New-Object System.Drawing.Size(370, 22)
    $tbName.Text = "$($Cmd.name)"
    $dlg.Controls.Add($tbName)

    $lblIcon = New-Object System.Windows.Forms.Label
    $lblIcon.Location = New-Object System.Drawing.Point(15, 53)
    $lblIcon.AutoSize = $true
    $lblIcon.Text = 'Icon:'
    $dlg.Controls.Add($lblIcon)

    $tbIcon = New-Object System.Windows.Forms.TextBox
    $tbIcon.Location = New-Object System.Drawing.Point(130, 50)
    $tbIcon.Size = New-Object System.Drawing.Size(370, 22)
    $tbIcon.Text = "$($Cmd.icon)"
    $dlg.Controls.Add($tbIcon)

    $hintIcon = New-Object System.Windows.Forms.Label
    $hintIcon.Location = New-Object System.Drawing.Point(130, 74)
    $hintIcon.AutoSize = $true
    $hintIcon.ForeColor = [System.Drawing.Color]::Gray
    $hintIcon.Text = 'e.g.: shell32.dll,44 or my.ico (empty = PowerShell icon)'
    $dlg.Controls.Add($hintIcon)

    $lblShell = New-Object System.Windows.Forms.Label
    $lblShell.Location = New-Object System.Drawing.Point(15, 103)
    $lblShell.AutoSize = $true
    $lblShell.Text = 'Shell:'
    $dlg.Controls.Add($lblShell)

    $cbShell = New-Object System.Windows.Forms.ComboBox
    $cbShell.DropDownStyle = 'DropDownList'
    $cbShell.Location = New-Object System.Drawing.Point(130, 100)
    $cbShell.Size = New-Object System.Drawing.Size(150, 22)
    foreach ($s in @('powershell', 'pwsh', 'cmd', 'auto')) { [void]$cbShell.Items.Add($s) }
    $shCur = "$($Cmd.shell)"
    if ($shCur -notin @('powershell', 'pwsh', 'cmd', 'auto')) { $shCur = 'powershell' }
    $cbShell.SelectedIndex = $cbShell.Items.IndexOf($shCur)
    $dlg.Controls.Add($cbShell)

    $lblWindow = New-Object System.Windows.Forms.Label
    $lblWindow.Location = New-Object System.Drawing.Point(300, 103)
    $lblWindow.AutoSize = $true
    $lblWindow.Text = 'Window:'
    $dlg.Controls.Add($lblWindow)

    $cbWindow = New-Object System.Windows.Forms.ComboBox
    $cbWindow.DropDownStyle = 'DropDownList'
    $cbWindow.Location = New-Object System.Drawing.Point(350, 100)
    $cbWindow.Size = New-Object System.Drawing.Size(150, 22)
    foreach ($w in @('hidden', 'normal', 'minimized')) { [void]$cbWindow.Items.Add($w) }
    $wnCur = "$($Cmd.window)"
    if ($wnCur -notin @('hidden', 'normal', 'minimized')) { $wnCur = 'hidden' }
    $cbWindow.SelectedIndex = $cbWindow.Items.IndexOf($wnCur)
    $dlg.Controls.Add($cbWindow)

    $lblCwd = New-Object System.Windows.Forms.Label
    $lblCwd.Location = New-Object System.Drawing.Point(15, 133)
    $lblCwd.AutoSize = $true
    $lblCwd.Text = 'Folder (cwd):'
    $dlg.Controls.Add($lblCwd)

    $tbCwd = New-Object System.Windows.Forms.TextBox
    $tbCwd.Location = New-Object System.Drawing.Point(130, 130)
    $tbCwd.Size = New-Object System.Drawing.Size(370, 22)
    $tbCwd.Text = "$($Cmd.cwd)"
    $dlg.Controls.Add($tbCwd)

    $lblCmds = New-Object System.Windows.Forms.Label
    $lblCmds.Location = New-Object System.Drawing.Point(15, 163)
    $lblCmds.AutoSize = $true
    $lblCmds.Text = 'Commands:'
    $dlg.Controls.Add($lblCmds)

    $tbCmds = New-Object System.Windows.Forms.TextBox
    $tbCmds.Multiline = $true
    $tbCmds.ScrollBars = 'Vertical'
    $tbCmds.Location = New-Object System.Drawing.Point(130, 160)
    $tbCmds.Size = New-Object System.Drawing.Size(370, 150)
    $tbCmds.Text = (@(Get-CommandsOf $Cmd) -join "`r`n")
    $dlg.Controls.Add($tbCmds)

    $hintCmds = New-Object System.Windows.Forms.Label
    $hintCmds.Location = New-Object System.Drawing.Point(130, 312)
    $hintCmds.AutoSize = $true
    $hintCmds.ForeColor = [System.Drawing.Color]::Gray
    $hintCmds.Text = 'each line is a separate command (executed sequentially)'
    $dlg.Controls.Add($hintCmds)

    $chkKeep = New-Object System.Windows.Forms.CheckBox
    $chkKeep.Text = 'Keep window open'
    $chkKeep.ThreeState = $true
    $chkKeep.AutoSize = $true
    $chkKeep.Location = New-Object System.Drawing.Point(130, 338)
    if ($null -eq $Cmd.keepOpen) { $chkKeep.CheckState = 'Indeterminate' }
    elseif ($Cmd.keepOpen) { $chkKeep.CheckState = 'Checked' } else { $chkKeep.CheckState = 'Unchecked' }
    $dlg.Controls.Add($chkKeep)

    $chkConfirm = New-Object System.Windows.Forms.CheckBox
    $chkConfirm.Text = 'Ask for confirmation'
    $chkConfirm.AutoSize = $true
    $chkConfirm.Checked = [bool]$Cmd.confirm
    $chkConfirm.Location = New-Object System.Drawing.Point(130, 364)
    $dlg.Controls.Add($chkConfirm)

    $chkNotify = New-Object System.Windows.Forms.CheckBox
    $chkNotify.Text = 'Notify after execution'
    $chkNotify.AutoSize = $true
    $chkNotify.Checked = [bool]$Cmd.notify
    $chkNotify.Location = New-Object System.Drawing.Point(130, 390)
    $dlg.Controls.Add($chkNotify)

    $chkSep = New-Object System.Windows.Forms.CheckBox
    $chkSep.Text = 'Separator after item'
    $chkSep.AutoSize = $true
    $chkSep.Checked = [bool]$Cmd.separatorAfter
    $chkSep.Location = New-Object System.Drawing.Point(130, 416)
    $dlg.Controls.Add($chkSep)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = 'OK'
    $btnOk.Location = New-Object System.Drawing.Point(240, 455)
    $btnOk.Size = New-Object System.Drawing.Size(80, 28)
    $dlg.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Cancel'
    $btnCancel.Location = New-Object System.Drawing.Point(330, 455)
    $btnCancel.Size = New-Object System.Drawing.Size(80, 28)
    $dlg.Controls.Add($btnCancel)
    $dlg.CancelButton = $btnCancel
    $dlg.AcceptButton = $btnOk

    $btnOk.add_Click({
        if (-not $tbName.Text.Trim()) {
            [void][System.Windows.Forms.MessageBox]::Show('Please specify a command name.', 'TrayCommands')
            return
        }
        $lines = @($tbCmds.Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($lines.Count -eq 0) {
            [void][System.Windows.Forms.MessageBox]::Show('Enter at least one command.', 'TrayCommands')
            return
        }
        $o = [pscustomobject]@{}
        $o | Add-Member NoteProperty name $tbName.Text.Trim()
        if ($tbIcon.Text.Trim()) { $o | Add-Member NoteProperty icon $tbIcon.Text.Trim() }
        $o | Add-Member NoteProperty shell $cbShell.SelectedItem.ToString()
        if ($lines.Count -eq 1) { $o | Add-Member NoteProperty command $lines[0] }
        else { $o | Add-Member NoteProperty commands $lines }
        $o | Add-Member NoteProperty window $cbWindow.SelectedItem.ToString()
        if ($tbCwd.Text.Trim()) { $o | Add-Member NoteProperty cwd $tbCwd.Text.Trim() }
        if ($chkKeep.CheckState -eq [System.Windows.Forms.CheckState]::Checked) {
            $o | Add-Member NoteProperty keepOpen $true
        } elseif ($chkKeep.CheckState -eq [System.Windows.Forms.CheckState]::Unchecked) {
            $o | Add-Member NoteProperty keepOpen $false
        }
        if ($chkConfirm.Checked) { $o | Add-Member NoteProperty confirm $true }
        if ($chkNotify.Checked)  { $o | Add-Member NoteProperty notify $true }
        if ($chkSep.Checked)     { $o | Add-Member NoteProperty separatorAfter $true }
        $dlg.Tag = $o
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dlg.Close()
    })

    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.Tag }
    return $null
}

# ---------- main form ----------

$form = New-Object System.Windows.Forms.Form
$form.Text = 'TrayCommands Config Editor'
$form.FormBorderStyle = 'FixedDialog'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(770, 600)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.MaximizeBox = $false

$gb = New-Object System.Windows.Forms.GroupBox
$gb.Text = 'General Settings'
$gb.Location = New-Object System.Drawing.Point(10, 10)
$gb.Size = New-Object System.Drawing.Size(750, 145)
$form.Controls.Add($gb)

$lblGIcon = New-Object System.Windows.Forms.Label
$lblGIcon.Location = New-Object System.Drawing.Point(15, 25)
$lblGIcon.AutoSize = $true
$lblGIcon.Text = 'Icon:'
$gb.Controls.Add($lblGIcon)

$tbGIcon = New-Object System.Windows.Forms.TextBox
$tbGIcon.Location = New-Object System.Drawing.Point(140, 22)
$tbGIcon.Size = New-Object System.Drawing.Size(590, 22)
$tbGIcon.Text = "$($cfg.icon)"
$gb.Controls.Add($tbGIcon)

$lblGTip = New-Object System.Windows.Forms.Label
$lblGTip.Location = New-Object System.Drawing.Point(15, 53)
$lblGTip.AutoSize = $true
$lblGTip.Text = 'Tooltip:'
$gb.Controls.Add($lblGTip)

$tbGTip = New-Object System.Windows.Forms.TextBox
$tbGTip.Location = New-Object System.Drawing.Point(140, 50)
$tbGTip.Size = New-Object System.Drawing.Size(590, 22)
$tbGTip.Text = "$($cfg.tooltip)"
$gb.Controls.Add($tbGTip)

$lblGMode = New-Object System.Windows.Forms.Label
$lblGMode.Location = New-Object System.Drawing.Point(15, 81)
$lblGMode.AutoSize = $true
$lblGMode.Text = 'Menu style:'
$gb.Controls.Add($lblGMode)

$cbGMode = New-Object System.Windows.Forms.ComboBox
$cbGMode.DropDownStyle = 'DropDownList'
$cbGMode.Location = New-Object System.Drawing.Point(140, 78)
$cbGMode.Size = New-Object System.Drawing.Size(120, 22)
[void]$cbGMode.Items.Add('text'); [void]$cbGMode.Items.Add('icons')
$mCur = "$($cfg.mode)"
if ($mCur -ne 'icons') { $mCur = 'text' }
$cbGMode.SelectedIndex = $cbGMode.Items.IndexOf($mCur)
$gb.Controls.Add($cbGMode)

$lblGCwd = New-Object System.Windows.Forms.Label
$lblGCwd.Location = New-Object System.Drawing.Point(15, 109)
$lblGCwd.AutoSize = $true
$lblGCwd.Text = 'Default folder:'
$gb.Controls.Add($lblGCwd)

$tbGCwd = New-Object System.Windows.Forms.TextBox
$tbGCwd.Location = New-Object System.Drawing.Point(140, 106)
$tbGCwd.Size = New-Object System.Drawing.Size(590, 22)
$tbGCwd.Text = "$($cfg.defaultCwd)"
$gb.Controls.Add($tbGCwd)

$lv = New-Object System.Windows.Forms.ListView
$lv.View = 'Details'
$lv.FullRowSelect = $true
$lv.HideSelection = $true
$lv.GridLines = $true
$lv.Location = New-Object System.Drawing.Point(10, 162)
$lv.Size = New-Object System.Drawing.Size(750, 330)
[void]$lv.Columns.Add('Name', 190)
[void]$lv.Columns.Add('Shell', 85)
[void]$lv.Columns.Add('Window', 85)
[void]$lv.Columns.Add('Commands', 370)
$form.Controls.Add($lv)

function Refresh-List {
    param([int]$SelectIndex = -1)
    $lv.BeginUpdate()
    $lv.Items.Clear()
    foreach ($c in $script:cmds) {
        $cl = @(Get-CommandsOf $c)
        $preview = ($cl -join ' ; ')
        if ($preview.Length -gt 70) { $preview = $preview.Substring(0, 67) + '...' }
        $it = New-Object System.Windows.Forms.ListViewItem("$($c.name)")
        [void]$it.SubItems.Add("$($c.shell)")
        [void]$it.SubItems.Add("$($c.window)")
        [void]$it.SubItems.Add($preview)
        $lv.Items.Add($it) | Out-Null
    }
    $lv.EndUpdate()
    if ($SelectIndex -ge 0 -and $SelectIndex -lt $lv.Items.Count) {
        $lv.Items[$SelectIndex].Selected = $true
    }
}

function Get-SelectedIndex {
    if ($lv.SelectedItems.Count -gt 0) { return $lv.SelectedItems[0].Index }
    return -1
}

$btnAdd = New-Object System.Windows.Forms.Button
$btnAdd.Text = 'Add'
$btnAdd.Location = New-Object System.Drawing.Point(10, 500)
$btnAdd.Size = New-Object System.Drawing.Size(90, 28)
$form.Controls.Add($btnAdd)

$btnEdit = New-Object System.Windows.Forms.Button
$btnEdit.Text = 'Edit'
$btnEdit.Location = New-Object System.Drawing.Point(105, 500)
$btnEdit.Size = New-Object System.Drawing.Size(90, 28)
$form.Controls.Add($btnEdit)

$btnDel = New-Object System.Windows.Forms.Button
$btnDel.Text = 'Delete'
$btnDel.Location = New-Object System.Drawing.Point(200, 500)
$btnDel.Size = New-Object System.Drawing.Size(90, 28)
$form.Controls.Add($btnDel)

$btnUp = New-Object System.Windows.Forms.Button
$btnUp.Text = 'Up'
$btnUp.Location = New-Object System.Drawing.Point(295, 500)
$btnUp.Size = New-Object System.Drawing.Size(60, 28)
$form.Controls.Add($btnUp)

$btnDown = New-Object System.Windows.Forms.Button
$btnDown.Text = 'Down'
$btnDown.Location = New-Object System.Drawing.Point(360, 500)
$btnDown.Size = New-Object System.Drawing.Size(60, 28)
$form.Controls.Add($btnDown)

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = 'Save'
$btnSave.Location = New-Object System.Drawing.Point(585, 558)
$btnSave.Size = New-Object System.Drawing.Size(85, 30)
$form.Controls.Add($btnSave)

$btnExit = New-Object System.Windows.Forms.Button
$btnExit.Text = 'Close'
$btnExit.Location = New-Object System.Drawing.Point(675, 558)
$btnExit.Size = New-Object System.Drawing.Size(85, 30)
$form.Controls.Add($btnExit)

$btnAdd.add_Click({
    $res = Show-CommandDialog -Cmd (New-DefaultCommand)
    if ($res) {
        [void]$script:cmds.Add($res)
        $script:dirty = $true
        Refresh-List -SelectIndex ($script:cmds.Count - 1)
    }
})

$btnEdit.add_Click({
    $i = Get-SelectedIndex
    if ($i -lt 0) { return }
    $res = Show-CommandDialog -Cmd $script:cmds[$i]
    if ($res) {
        $script:cmds[$i] = $res
        $script:dirty = $true
        Refresh-List -SelectIndex $i
    }
})

$lv.add_DoubleClick({ $btnEdit.PerformClick() })

$btnDel.add_Click({
    $i = Get-SelectedIndex
    if ($i -lt 0) { return }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Delete command `"$($script:cmds[$i].name)`"?", 'TrayCommands',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
        $script:cmds.RemoveAt($i)
        $script:dirty = $true
        Refresh-List
    }
})

$btnUp.add_Click({
    $i = Get-SelectedIndex
    if ($i -lt 1) { return }
    $tmp = $script:cmds[$i]; $script:cmds[$i] = $script:cmds[$i - 1]; $script:cmds[$i - 1] = $tmp
    $script:dirty = $true
    Refresh-List -SelectIndex ($i - 1)
})

$btnDown.add_Click({
    $i = Get-SelectedIndex
    if ($i -lt 0 -or $i -ge $script:cmds.Count - 1) { return }
    $tmp = $script:cmds[$i]; $script:cmds[$i] = $script:cmds[$i + 1]; $script:cmds[$i + 1] = $tmp
    $script:dirty = $true
    Refresh-List -SelectIndex ($i + 1)
})

$btnSave.add_Click({
    foreach ($c in $script:cmds) {
        if (-not "$($c.name)".Trim()) {
            [void][System.Windows.Forms.MessageBox]::Show('There is a command without a name.', 'TrayCommands')
            return
        }
        if (@(Get-CommandsOf $c).Count -eq 0) {
            [void][System.Windows.Forms.MessageBox]::Show("Command `"$($c.name)`" has no command lines.", 'TrayCommands')
            return
        }
    }
    $newIcon = $tbGIcon.Text.Trim()
    if ($newIcon) { $cfg | Add-Member NoteProperty icon $newIcon -Force }
    $newTip = $tbGTip.Text.Trim()
    if ($newTip) { $cfg | Add-Member NoteProperty tooltip $newTip -Force }
    $cfg | Add-Member NoteProperty mode $cbGMode.SelectedItem.ToString() -Force
    $newCwd = $tbGCwd.Text.Trim()
    if ($newCwd) { $cfg | Add-Member NoteProperty defaultCwd $newCwd -Force }
    $cfg | Add-Member NoteProperty commands @($script:cmds) -Force
    try {
        Save-ConfigFile -Cfg $cfg
        $script:dirty = $false
        [void][System.Windows.Forms.MessageBox]::Show(
            "Saved to: $ConfigPath`r`n`r`nRestart the tray app to apply changes.",
            'TrayCommands', 'OK', 'Information')
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show("Error saving:`r`n$($_.Exception.Message)",
            'TrayCommands', 'OK', 'Error')
    }
})

$btnExit.add_Click({
    if ($script:dirty) {
        $a = [System.Windows.Forms.MessageBox]::Show(
            'There are unsaved changes. Save before exiting?', 'TrayCommands',
            [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($a -eq [System.Windows.Forms.DialogResult]::Cancel) { return }
        if ($a -eq [System.Windows.Forms.DialogResult]::Yes) {
            $btnSave.PerformClick()
            if ($script:dirty) { return }
        }
    }
    $form.Close()
})

Refresh-List
[void]$form.ShowDialog()