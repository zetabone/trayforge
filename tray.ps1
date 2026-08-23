# TrayCommands — system tray icon with menu
# Launch: powershell -NoProfile -ExecutionPolicy Bypass -File tray.ps1
# Config test without GUI: ... -File tray.ps1 -Test
param(
    [string]$ConfigPath,
    [switch]$Test
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not $PSScriptRoot) { $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ConfigPath)   { $ConfigPath   = Join-Path $PSScriptRoot 'config.json' }

Add-Type -Namespace Native -Name Tools -MemberDefinition @"
[DllImport("shell32.dll", CharSet = CharSet.Unicode)]
public static extern int ExtractIconEx(string lpszFile, int nIconIndex, System.IntPtr[] phIconLarge, System.IntPtr[] phIconSmall, int nIcons);
[DllImport("user32.dll")]
public static extern bool SetForegroundWindow(System.IntPtr hWnd);
"@

$script:cfg = $null
$script:pwshPath = $null
$script:dummy = New-Object System.Windows.Forms.Form
$script:dummy.ShowInTaskbar = $false
$script:dummy.WindowState = 'Minimized'
$script:dummy.FormBorderStyle = 'None'
$script:panel = $null

function Remove-JsonComments {
    param([string]$Json)
    $sb = New-Object System.Text.StringBuilder
    $inString = $false
    $i = 0
    $len = $Json.Length
    while ($i -lt $len) {
        $ch = $Json[$i]
        if ($inString) {
            if ($ch -eq '\') {
                [void]$sb.Append($Json.Substring($i, [Math]::Min(2, $len - $i)))
                $i += 2
                continue
            }
            if ($ch -eq '"') { $inString = $false }
            [void]$sb.Append($ch)
            $i++
            continue
        }
        if ($ch -eq '"') { $inString = $true; [void]$sb.Append($ch); $i++; continue }
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

function Get-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Config not found: $ConfigPath"
    }
    $raw = Remove-JsonComments (Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8) | ConvertFrom-Json
    if (-not $raw.commands) { throw "config.json has no 'commands' array" }
    foreach ($c in $raw.commands) {
        if (-not $c.name)  { throw "Command item has no 'name' field" }
        if (-not $c.command -and -not $c.commands) { throw "Item '$($c.name)': has neither 'command' nor 'commands'" }
        if (-not $c.shell) { $c | Add-Member NoteProperty shell 'powershell' }
        if (-not $c.window) { $c | Add-Member NoteProperty window 'hidden' }
        if ($c.confirm -eq $null) { $c | Add-Member NoteProperty confirm $false }
    }
    if (-not $raw.mode)     { $raw | Add-Member NoteProperty mode 'text' }
    if (-not $raw.tooltip)  { $raw | Add-Member NoteProperty tooltip 'TrayCommands' }
    return $raw
}

function Get-IconFromSpec {
    param([string]$Spec, [int]$Size)
    try {
        if ([string]::IsNullOrWhiteSpace($Spec)) { return $null }
        $expanded = [Environment]::ExpandEnvironmentVariables($Spec)
        $index = 0
        if ($expanded -match '^(.*),\s*(-?\d+)\s*$') {
            $expanded = $Matches[1].Trim()
            $index = [int]$Matches[2]
        }
        if (-not [IO.Path]::IsPathRooted($expanded)) {
            $candidates = @(
                (Join-Path $PSScriptRoot $expanded),
                (Join-Path $env:SystemRoot "System32\$expanded"),
                (Join-Path $env:SystemRoot $expanded)
            )
            $found = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
            if (-not $found -and [IO.Path]::GetExtension($expanded) -ieq '.exe') {
                $onPath = where.exe $expanded 2>$null | Select-Object -First 1
                if ($onPath) { $found = $onPath }
            }
            if ($found) { $expanded = $found }
        }
        if (-not (Test-Path -LiteralPath $expanded)) { return $null }

        if ([IO.Path]::GetExtension($expanded) -ieq '.ico') {
            return New-Object System.Drawing.Icon($expanded)
        }

        $large = New-Object 'System.IntPtr[]' 1
        $small = New-Object 'System.IntPtr[]' 1
        $n = [Native.Tools]::ExtractIconEx($expanded, $index, $large, $small, 1)
        if ($n -lt 1) { return $null }
        $handle = if ($Size -ge 32) { $large[0] } else { $small[0] }
        if ($handle -eq [System.IntPtr]::Zero) { $handle = if ($large[0] -ne [System.IntPtr]::Zero) { $large[0] } else { $small[0] } }
        if ($handle -eq [System.IntPtr]::Zero) { return $null }
        try { return [System.Drawing.Icon]::FromHandle($handle) } catch { return $null }
    } catch { return $null }
}

function Get-PowerShellPath {
    if (-not $script:pwshPath) {
        $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
        $script:pwshPath = if ($pwsh) { $pwsh.Source } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    }
    return $script:pwshPath
}

function Invoke-TrayItem {
    param($Item)
    try {
        if ($Item.confirm) {
            $answer = [System.Windows.Forms.MessageBox]::Show(
                "Execute: $($Item.name)?", 'Confirmation',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Question)
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }

        $commands = @()
        if     ($Item.commands) { $commands = @($Item.commands) }
        elseif ($Item.command)  { $commands = @($Item.command) }

        $commands = @($commands | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($commands.Count -eq 0) { return }

        $shell  = "$($Item.shell)".ToLowerInvariant()
        $window = "$($Item.window)".ToLowerInvariant()

        if ($shell -eq 'auto') {
            $ext = [IO.Path]::GetExtension(($commands[0].Trim() -split '\s+')[0]).ToLowerInvariant()
            if ($ext -in '.bat', '.cmd')       { $shell = 'cmd' }
            elseif ($ext -in '.ps1', '.psm1')  { $shell = 'powershell' }
            else                               { $shell = 'cmd' }
        }

        if ($null -ne $Item.keepOpen) { $keepOpen = [bool]$Item.keepOpen }
        else { $keepOpen = ($window -ne 'hidden') }

        $psi = New-Object System.Diagnostics.ProcessStartInfo

        if ($shell -eq 'cmd') {
            $psi.FileName = $env:ComSpec
            $sw = if ($keepOpen) { '/k' } else { '/c' }
            $psi.Arguments = "$sw `"$($commands -join ' & ')`""
        } else {
            $joined = ($commands -join '; ') -replace '"', '\"'
            $noExit = if ($keepOpen) { ' -NoExit' } else { '' }
            $psi.FileName = Get-PowerShellPath
            $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass$noExit -Command `"$joined`""
        }

        $dir = $null
        if ($Item.cwd) { $dir = "$($Item.cwd)" }
        elseif ($script:cfg.defaultCwd) { $dir = "$($script:cfg.defaultCwd)" }
        else { $dir = $env:USERPROFILE }
        $dir = [Environment]::ExpandEnvironmentVariables($dir)
        if (-not [IO.Path]::IsPathRooted($dir)) { $dir = Join-Path $PSScriptRoot $dir }
        if (Test-Path -LiteralPath $dir -PathType Container) { $psi.WorkingDirectory = $dir }

        if ($window -eq 'hidden') {
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
        } else {
            $psi.UseShellExecute = $true
            if ($window -eq 'minimized') { $psi.WindowStyle = 'Minimized' }
        }
        [void][System.Diagnostics.Process]::Start($psi)

        if ($Item.notify) {
            $script:notify.BalloonTipTitle = 'Done'
            $script:notify.BalloonTipText = "Executed: $($Item.name)"
            $script:notify.BalloonTipIcon = 'Info'
            $script:notify.ShowBalloonTip(1500)
        }
    } catch {
        $script:notify.BalloonTipTitle = 'Error'
        $script:notify.BalloonTipText = $_.Exception.Message
        $script:notify.BalloonTipIcon = 'Error'
        $script:notify.ShowBalloonTip(4000)
    }
}

function Add-TrayMenuItem {
    param([System.Windows.Forms.ToolStripItemCollection]$Items, $CfgItem)
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem
    $mi.Text = $CfgItem.name
    $icon = Get-IconFromSpec -Spec $CfgItem.icon -Size 16
    if ($icon) {
        try {
            $mi.Image = $icon.ToBitmap()
            $mi.ImageScaling = 'None'
        } catch {}
    }
    $mi.Tag = $CfgItem
    $mi.add_Click({ Invoke-TrayItem $this.Tag })
    [void]$Items.Add($mi)
    if ($CfgItem.separatorAfter) {
        [void]$Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    }
}

function Update-Menu {
    $menu = $script:menu
    $menu.Items.Clear()
    foreach ($item in $script:cfg.commands) { Add-TrayMenuItem -Items $menu.Items -CfgItem $item }
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $modeText = if ($script:cfg.mode -eq 'icons') { 'View: Icons → Text' } else { 'View: Text → Icons' }
    $toggle = New-Object System.Windows.Forms.ToolStripMenuItem
    $toggle.Text = $modeText
    $toggle.add_Click({
        Close-Panel
        if ($script:cfg.mode -eq 'icons') { $script:cfg.mode = 'text' } else { $script:cfg.mode = 'icons' }
        Show-TrayMenu
    })
    [void]$menu.Items.Add($toggle)

    $editItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $editItem.Text = 'Config Editor...'
    $editItem.add_Click({
        if (Test-Path -LiteralPath $script:EditorPath) {
            Start-Process -FilePath 'powershell.exe' -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass',
                '-WindowStyle', 'Hidden', '-File', ('"' + $script:EditorPath + '"')
            ) | Out-Null
        } else {
            [void][System.Windows.Forms.MessageBox]::Show('edit-config.ps1 not found next to tray.ps1.', 'TrayCommands')
        }
    })
    [void]$menu.Items.Add($editItem)

    $exit = New-Object System.Windows.Forms.ToolStripMenuItem
    $exit.Text = 'Exit'
    $exit.add_Click({
        $script:notify.Visible = $false
        $script:app.ExitThread()
    })
    [void]$menu.Items.Add($exit)
}

function Close-Panel {
    if ($script:panel) {
        try { $script:panel.Close() } catch {}
        $script:panel = $null
    }
}

function Show-IconPanel {
    param([System.Drawing.Point]$At)
    Close-Panel

    $items = @($script:cfg.commands | Where-Object { $_.command -or $_.commands })
    if ($items.Count -eq 0) { return }

    $btn = 48; $gap = 4; $pad = 8
    $perRow = [Math]::Min($items.Count, 6)
    $rows = [Math]::Ceiling($items.Count / $perRow)
    $w = $perRow * ($btn + $gap) + $pad * 2 + $gap
    $h = $rows * ($btn + $gap) + $pad * 2 + $gap

    $form = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = 'None'
    $form.ShowInTaskbar = $false
    $form.TopMost = $true
    $form.StartPosition = 'Manual'
    $form.BackColor = [System.Drawing.Color]::White
    $form.Size = New-Object System.Drawing.Size($w, $h)
    $form.KeyPreview = $true

    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $x = [Math]::Max($wa.Left, $At.X - $w)
    $y = [Math]::Min($At.Y, $wa.Bottom - $h)
    $form.Location = New-Object System.Drawing.Point([int]$x, [int]$y)

    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Dock = 'Fill'
    $flow.Padding = New-Object System.Windows.Forms.Padding($pad)
    $flow.BackColor = [System.Drawing.Color]::White
    $form.Controls.Add($flow)

    $tip = New-Object System.Windows.Forms.ToolTip
    foreach ($item in $items) {
        $b = New-Object System.Windows.Forms.Button
        $b.Size = New-Object System.Drawing.Size($btn, $btn)
        $b.FlatStyle = 'Flat'
        $b.FlatAppearance.BorderSize = 0
        $b.BackColor = [System.Drawing.Color]::White
        $b.TabStop = $false
        $icon = Get-IconFromSpec -Spec $item.icon -Size 32
        if ($icon) {
            try {
                $bmp = New-Object System.Drawing.Bitmap 32, 32
                $g = [System.Drawing.Graphics]::FromImage($bmp)
                $g.InterpolationMode = 'HighQualityBicubic'
                $g.DrawImage($icon.ToBitmap(), 0, 0, 32, 32)
                $g.Dispose()
                $b.Image = $bmp
            } catch {}
        }
        $tip.SetToolTip($b, $item.name)
        $b.Tag = $item
        $b.add_Click({ Close-Panel; Invoke-TrayItem $this.Tag })
        [void]$flow.Controls.Add($b)
    }

    $form.add_Deactivate({ Close-Panel })
    $form.add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Escape') { Close-Panel } })

    $script:panel = $form
    $form.Show()
    [void]$form.Activate()
}

function Show-TrayMenu {
    [void][Native.Tools]::SetForegroundWindow($script:dummy.Handle)
    if ($script:cfg.mode -eq 'icons') {
        Show-IconPanel -At ([System.Windows.Forms.Cursor]::Position)
    } else {
        Update-Menu
        $script:menu.Show([System.Windows.Forms.Cursor]::Position)
    }
}

if ($Test) {
    $cfg = Get-Config
    Write-Host "Config OK: $($cfg.commands.Count) commands, mode '$($cfg.mode)'"
    foreach ($item in $cfg.commands) {
        $i16 = Get-IconFromSpec -Spec $item.icon -Size 16
        $i32 = Get-IconFromSpec -Spec $item.icon -Size 32
        Write-Host (" - {0} [{1}] icon16={2} icon32={3}" -f `
            $item.name, $item.shell, [bool]$i16, [bool]$i32)
    }
    exit 0
}

try {
    $script:cfg = Get-Config
} catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'TrayCommands',
        'OK', 'Error') | Out-Null
    exit 1
}
$script:EditorPath = Join-Path $PSScriptRoot 'edit-config.ps1'

$script:app = New-Object System.Windows.Forms.ApplicationContext

$script:menu = New-Object System.Windows.Forms.ContextMenuStrip
$script:menu.add_Opening({ Update-Menu })

$trayIcon = Get-IconFromSpec -Spec $script:cfg.icon -Size 16
if (-not $trayIcon) {
    $trayIcon = Get-IconFromSpec -Spec "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Size 16
}
if (-not $trayIcon) { $trayIcon = [System.Drawing.SystemIcons]::Application }

$script:notify = New-Object System.Windows.Forms.NotifyIcon
$script:notify.Icon = $trayIcon
$script:notify.Text = $script:cfg.tooltip
$script:notify.ContextMenuStrip = $script:menu
$script:notify.Visible = $true

$script:notify.add_MouseUp({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-TrayMenu }
})

$script:notify.add_BalloonTipClicked({ Show-TrayMenu })

Update-Menu
$script:notify.BalloonTipTitle = 'TrayCommands'
$script:notify.BalloonTipText = "Running. Commands: $($script:cfg.commands.Count). Click icon for menu."
$script:notify.ShowBalloonTip(2500)

[void][System.Windows.Forms.Application]::Run($script:app)
Close-Panel