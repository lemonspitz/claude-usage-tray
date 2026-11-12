# Claude usage tray widget for Windows.
# Tray icon = 3 stacked bars: top 5-hour session, middle weekly (all models),
# bottom weekly Fable. Click it for details. Uses the sign-in saved by Claude Code
# (~/.claude/.credentials.json). Right-click for Refresh / Start with Windows / Exit.

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class NativeIcon {
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
}
'@
# DPI-aware so the icon is drawn at real pixel size instead of being stretched (blurry)
[void][NativeIcon]::SetProcessDPIAware()
[System.Windows.Forms.Application]::EnableVisualStyles()
$g0 = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $script:DpiScale = $g0.DpiX / 96; $g0.Dispose()
$script:IconPx = [NativeIcon]::GetSystemMetrics(49)  # SM_CXSMICON: tray icon size at current DPI
if ($script:IconPx -lt 16) { $script:IconPx = 16 }
function Px([double]$n) { [int][math]::Round($n * $script:DpiScale) }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# One instance only
$mutexNew = $false
$script:Mutex = New-Object System.Threading.Mutex($true, 'Local\ClaudeUsageTray', [ref]$mutexNew)
if (-not $mutexNew) { exit }

$CredPath  = Join-Path $env:USERPROFILE '.claude\.credentials.json'
$ClientId  = '9d1c250a-e61b-44d9-88ed-5944d1962f5e'
$UsageUrl  = 'https://api.anthropic.com/api/oauth/usage'
$TokenUrls = @('https://console.anthropic.com/v1/oauth/token', 'https://platform.claude.com/v1/oauth/token')
$SettingsPath = Join-Path $PSScriptRoot 'settings.json'
$IntervalChoices = @(@(1, '1 minute'), @(3, '3 minutes'), @(5, '5 minutes'), @(10, '10 minutes'),
                     @(15, '15 minutes'), @(30, '30 minutes'), @(60, '1 hour'))
$StyleChoices = @(@('bars', 'Bars'), @('rounded', 'Rounded bars'), @('thin', 'Thin bars'),
                  @('columns', 'Columns'), @('number', 'Number (5-hour %)'))
$ColorChoices = @(@('orange', 'Claude orange'), @('traffic', 'Traffic light (green / amber / red)'),
                  @('blue', 'Blue'), @('perbar', 'One color per bar'), @('white', 'White'), @('black', 'Black'))
$script:Settings = @{ refreshMinutes = 5; style = 'bars'; color = 'orange'; warn = $true }
try {
    $saved = Get-Content $SettingsPath -Raw -ErrorAction Stop | ConvertFrom-Json
    foreach ($name in @('refreshMinutes', 'style', 'color', 'warn')) { if ($null -ne $saved.$name) { $script:Settings[$name] = $saved.$name } }
} catch { }

function Save-Settings {
    try { [IO.File]::WriteAllText($SettingsPath, ($script:Settings | ConvertTo-Json)) } catch { }
}
$Launcher  = Join-Path $PSScriptRoot 'Start-ClaudeUsageTray.vbs'
$StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Usage Tray.lnk'

$script:State = @{ Error = 'Loading...'; Rows = @(); Bars = @($null, $null, $null); Updated = $null; Plan = $null }

# ---------- data ----------

function Read-Creds {
    if (-not (Test-Path $CredPath)) { return $null }
    try { return (Get-Content $CredPath -Raw | ConvertFrom-Json) } catch { return $null }
}

function Save-Creds($creds) {
    $json = $creds | ConvertTo-Json -Depth 10
    $tmp = "$CredPath.tmp"
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding $false))  # no BOM: Claude Code must still parse it
    Move-Item -Path $tmp -Destination $CredPath -Force
}

function Update-Token($creds) {
    $o = $creds.claudeAiOauth
    if (-not $o.refreshToken) { throw 'Sign-in expired. Open Claude Code to sign in again.' }
    $body = @{ grant_type = 'refresh_token'; refresh_token = $o.refreshToken; client_id = $ClientId } | ConvertTo-Json
    $r = $null
    foreach ($u in $TokenUrls) {
        try { $r = Invoke-RestMethod -Method Post -Uri $u -ContentType 'application/json' -Body $body -TimeoutSec 15; break } catch { }
    }
    if (-not $r -or -not $r.access_token) { throw 'Sign-in expired. Open Claude Code to sign in again.' }
    $o.accessToken = $r.access_token
    if ($r.refresh_token) { $o.refreshToken = $r.refresh_token }
    if ($r.expires_in) { $o.expiresAt = [DateTimeOffset]::UtcNow.AddSeconds([double]$r.expires_in).ToUnixTimeMilliseconds() }
    Save-Creds $creds
}

function Get-UsageRaw([string]$token) {
    $h = @{ Authorization = "Bearer $token"; 'anthropic-beta' = 'oauth-2025-04-20' }
    Invoke-RestMethod -Uri $UsageUrl -Headers $h -UserAgent 'claude-usage-tray/1.0' -TimeoutSec 15
}

function Format-Reset($iso) {
    if (-not $iso) { return '' }
    $t = [DateTimeOffset]::Parse($iso).LocalDateTime
    $d = $t - (Get-Date)
    if ($d.TotalMinutes -lt 1) { return 'resets now' }
    if ($d.TotalHours -lt 24) { return ('resets in {0}h {1:00}m' -f [int][math]::Floor($d.TotalHours), $d.Minutes) }
    return 'resets ' + $t.ToString('ddd h:mm tt')
}

function Update-Usage {
    try {
        $token = $null; $creds = Read-Creds
        if ($creds -and $creds.claudeAiOauth) {
            $o = $creds.claudeAiOauth
            if ($o.expiresAt -and [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() -gt ([int64]$o.expiresAt - 60000)) { Update-Token $creds }
            $token = $creds.claudeAiOauth.accessToken
            $script:State.Plan = $creds.claudeAiOauth.subscriptionType
        } elseif ($env:CLAUDE_CODE_OAUTH_TOKEN) {
            $token = $env:CLAUDE_CODE_OAUTH_TOKEN
        } else {
            throw 'Not signed in. Install Claude Code, run "claude" and sign in.'
        }

        try { $u = Get-UsageRaw $token }
        catch {
            $code = 0; if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
            if ($code -eq 401 -and $creds) { Update-Token $creds; $u = Get-UsageRaw $creds.claudeAiOauth.accessToken }
            elseif ($code -eq 401) { throw 'Token rejected. Sign in to Claude Code again.' }
            else { throw ('Could not reach Claude (' + $_.Exception.Message + ')') }
        }

        # Bars: 0 = session, 1 = weekly all models, 2 = weekly Fable
        $rows = @(); $bars = @($null, $null, $null)
        foreach ($l in @($u.limits)) {
            if (-not $l -or $null -eq $l.percent) { continue }
            $slot = -1
            if ($l.kind -eq 'session') { $name = 'Session (5 hours)'; $slot = 0 }
            elseif ($l.kind -eq 'weekly_all') { $name = 'Weekly, all models'; $slot = 1 }
            else {
                $label = $null
                if ($l.scope -and $l.scope.model) { $label = $l.scope.model.display_name }
                if (-not $label) { $label = $l.kind }
                $name = 'Weekly, ' + $label
                if ($label -match 'Fable') { $slot = 2 }
            }
            $rows += , @{ Name = $name; Pct = [double]$l.percent; Reset = (Format-Reset $l.resets_at); Slot = $slot }
            if ($slot -ge 0 -and $null -eq $bars[$slot]) { $bars[$slot] = [double]$l.percent }
        }
        if ($rows.Count -eq 0) {  # older response shape
            foreach ($k in @(@('five_hour', 'Session (5 hours)', 0), @('seven_day', 'Weekly, all models', 1))) {
                $v = $u.($k[0])
                if ($v -and $null -ne $v.utilization) {
                    $rows += , @{ Name = $k[1]; Pct = [double]$v.utilization; Reset = (Format-Reset $v.resets_at); Slot = $k[2] }
                    $bars[$k[2]] = [double]$v.utilization
                }
            }
        }
        if ($rows.Count -eq 0) { throw 'No usage data returned for this account.' }
        $script:State.Rows = $rows; $script:State.Bars = $bars; $script:State.Error = $null; $script:State.Updated = Get-Date
    } catch {
        $script:State.Error = "$($_.Exception.Message)"
    }
    Update-Tray
}

# ---------- tray icon ----------

# Fill color for bar $slot (0 session, 1 weekly, 2 Fable, -1 other) at $p percent.
# $onDark: drawing on the dark popup, where black would be invisible.
function Get-BarColor([int]$slot, [double]$p, [bool]$onDark = $false) {
    $c = $script:Settings.color
    if ($script:Settings.warn -or $c -eq 'traffic') {
        if ($p -ge 90) { return [Drawing.Color]::FromArgb(220, 60, 50) }
        if ($p -ge 70) { return [Drawing.Color]::FromArgb(230, 150, 30) }
    }
    switch ($c) {
        'traffic' { return [Drawing.Color]::FromArgb(76, 175, 80) }
        'blue'    { return [Drawing.Color]::FromArgb(66, 133, 244) }
        'perbar'  {
            if ($slot -eq 1) { return [Drawing.Color]::FromArgb(66, 133, 244) }
            if ($slot -eq 2) { return [Drawing.Color]::FromArgb(156, 110, 230) }
            return [Drawing.Color]::FromArgb(217, 119, 87)
        }
        'white'   { return [Drawing.Color]::FromArgb(240, 240, 240) }
        'black'   { if ($onDark) { return [Drawing.Color]::FromArgb(200, 200, 200) }; return [Drawing.Color]::FromArgb(25, 25, 25) }
    }
    return [Drawing.Color]::FromArgb(217, 119, 87)  # Claude orange
}

function Get-TrackColor {
    switch ($script:Settings.color) {
        'white' { return [Drawing.Color]::FromArgb(80, 255, 255, 255) }
        'black' { return [Drawing.Color]::FromArgb(70, 0, 0, 0) }
    }
    return [Drawing.Color]::FromArgb(150, 128, 128, 128)
}

function New-RoundRect([float]$x, [float]$y, [float]$w, [float]$h) {
    $d = [math]::Min($w, $h)
    $p = New-Object Drawing.Drawing2D.GraphicsPath
    $p.AddArc($x, $y, $d, $d, 90, 180); $p.AddArc($x + $w - $d, $y, $d, $d, 270, 180); $p.CloseFigure()
    return $p
}

function ConvertTo-Icon([Drawing.Bitmap]$bmp) {
    $h = $bmp.GetHicon(); $icon = [Drawing.Icon]::FromHandle($h).Clone()
    [NativeIcon]::DestroyIcon($h) | Out-Null; $bmp.Dispose()
    return $icon
}

function New-NumberIcon([string]$text, [Drawing.Color]$bg) {
    $s = $script:IconPx
    $bmp = New-Object Drawing.Bitmap $s, $s
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.FillEllipse((New-Object Drawing.SolidBrush $bg), 0, 0, $s - 1, $s - 1)
    $em = 0.66; if ($text.Length -eq 2) { $em = 0.54 } elseif ($text.Length -ge 3) { $em = 0.40 }
    $font = New-Object Drawing.Font 'Segoe UI', ([float]($s * $em)), ([Drawing.FontStyle]::Bold), ([Drawing.GraphicsUnit]::Pixel)
    $fmt = New-Object Drawing.StringFormat ([Drawing.StringFormatFlags]::NoWrap); $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
    $fg = [Drawing.Brushes]::White; if ($bg.GetBrightness() -gt 0.75) { $fg = [Drawing.Brushes]::Black }
    $g.DrawString($text, $font, $fg, (New-Object Drawing.RectangleF 0, 0, $s, $s), $fmt)
    $g.Dispose(); $font.Dispose()
    return ConvertTo-Icon $bmp
}

# Three bars in the chosen style. Square styles are pixel-aligned with no
# anti-aliasing so edges stay sharp; rounded uses anti-aliasing for the curves.
function New-BarsIcon($pcts) {
    $s = $script:IconPx; $style = $script:Settings.style
    $bmp = New-Object Drawing.Bitmap $s, $s
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'None'; $g.PixelOffsetMode = 'Half'
    $track = New-Object Drawing.SolidBrush (Get-TrackColor)

    if ($style -eq 'columns') {  # 3 side-by-side columns filling upward
        $gap = [int][math]::Max(1, [math]::Round($s * 0.09))
        $cw  = [int][math]::Floor(($s - 2 * $gap) / 3)
        $left = [int][math]::Floor(($s - (3 * $cw + 2 * $gap)) / 2)
        $y0 = 1; $ch = $s - 2
        for ($i = 0; $i -lt 3; $i++) {
            $x = $left + $i * ($cw + $gap)
            $g.FillRectangle($track, $x, $y0, $cw, $ch)
            $p = $pcts[$i]
            if ($null -ne $p -and $p -gt 0) {
                $fh = [int][math]::Max(1, [math]::Round([math]::Min(100.0, $p) / 100 * $ch))
                $g.FillRectangle((New-Object Drawing.SolidBrush (Get-BarColor $i $p)), $x, ($y0 + $ch - $fh), $cw, $fh)
            }
        }
        $g.Dispose(); return ConvertTo-Icon $bmp
    }

    if ($style -eq 'thin') {
        $bh  = [int][math]::Max(2, [math]::Round($s * 0.16))
        $gap = [int][math]::Floor(($s - 3 * $bh) / 4)
        $top = [int][math]::Floor(($s - (3 * $bh + 2 * $gap)) / 2)
    } else {
        $gap = [int][math]::Max(1, [math]::Round($s * 0.09))
        $bh  = [int][math]::Floor(($s - 2 * $gap) / 3)
        $top = [int][math]::Floor(($s - (3 * $bh + 2 * $gap)) / 2)
    }
    $x0 = 1; $bw = $s - 2
    if ($style -eq 'rounded') { $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'Default' }
    for ($i = 0; $i -lt 3; $i++) {
        $y = $top + $i * ($bh + $gap)
        $p = $pcts[$i]
        $fw = 0; if ($null -ne $p -and $p -gt 0) { $fw = [int][math]::Max(1, [math]::Round([math]::Min(100.0, $p) / 100 * $bw)) }
        $fill = $null; if ($fw -gt 0) { $fill = New-Object Drawing.SolidBrush (Get-BarColor $i $p) }
        if ($style -eq 'rounded') {
            $path = New-RoundRect $x0 $y $bw $bh
            $g.FillPath($track, $path)
            if ($fill) { $g.SetClip($path); $g.FillRectangle($fill, $x0, $y, $fw, $bh); $g.ResetClip() }
            $path.Dispose()
        } else {
            $g.FillRectangle($track, $x0, $y, $bw, $bh)
            if ($fill) { $g.FillRectangle($fill, $x0, $y, $fw, $bh) }
        }
    }
    $g.Dispose()
    return ConvertTo-Icon $bmp
}

function Update-Tray {
    $old = $script:Tray.Icon
    if ($script:State.Error) {
        $script:Tray.Icon = New-NumberIcon '?' ([Drawing.Color]::FromArgb(110, 110, 110))
        $tip = 'Claude: ' + $script:State.Error
    } else {
        $b = $script:State.Bars
        if ($script:Settings.style -eq 'number') {
            $p = 0.0; if ($null -ne $b[0]) { $p = $b[0] }
            $script:Tray.Icon = New-NumberIcon ([string][int][math]::Round($p)) (Get-BarColor 0 $p)
        } else {
            $script:Tray.Icon = New-BarsIcon $b
        }
        $tip = 'Claude usage'
        $labels = @('5 hours', 'Weekly', 'Fable')
        for ($i = 0; $i -lt 3; $i++) {
            $v = '-'; if ($null -ne $b[$i]) { $v = [string][int][math]::Round($b[$i]) + '%' }
            $tip += "`n" + $labels[$i] + ': ' + $v
        }
    }
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 60) + '...' }
    $script:Tray.Text = $tip
    if ($old) { $old.Dispose() }
    if ($script:Popup.Visible) { $script:Popup.Invalidate() }
}

# ---------- popup ----------

$script:Popup = New-Object Windows.Forms.Form
$script:Popup.FormBorderStyle = 'None'; $script:Popup.ShowInTaskbar = $false; $script:Popup.TopMost = $true
$script:Popup.StartPosition = 'Manual'; $script:Popup.BackColor = [Drawing.Color]::FromArgb(32, 32, 32)
$script:Popup.Width = Px 320
$script:Popup.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic,Instance').SetValue($script:Popup, $true, $null)
$script:Popup.Add_Deactivate({ $script:Popup.Hide() })
$script:Popup.Add_Paint({
    param($s, $e)
    $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'ClearTypeGridFit'
    $title = New-Object Drawing.Font 'Segoe UI Semibold', 11
    $body  = New-Object Drawing.Font 'Segoe UI', 9
    $small = New-Object Drawing.Font 'Segoe UI', 8
    $white = [Drawing.Brushes]::White
    $grey  = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(160, 160, 160))
    $track = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(60, 60, 60))
    $w = $s.ClientSize.Width; $x = Px 16; $y = Px 14
    $hdr = 'Claude usage'; if ($script:State.Plan) { $hdr += '  |  ' + $script:State.Plan }
    $g.DrawString($hdr, $title, $white, $x, $y); $y += Px 32
    if ($script:State.Error) {
        $g.DrawString($script:State.Error, $body, $white, (New-Object Drawing.RectangleF $x, $y, ($w - 2 * $x), (Px 60))); $y += Px 64
    }
    foreach ($row in $script:State.Rows) {
        $g.DrawString($row.Name, $body, $white, $x, $y)
        $pt = [string][int][math]::Round($row.Pct) + '%'
        $sz = $g.MeasureString($pt, $body)
        $g.DrawString($pt, $body, $white, ($w - $x - $sz.Width), $y); $y += Px 22
        $bw = $w - 2 * $x
        $g.FillRectangle($track, $x, $y, $bw, (Px 6))
        $fill = [math]::Max(0.0, [math]::Min(1.0, $row.Pct / 100)) * $bw  # .0: int literals would round the result to 0 or 1
        if ($fill -gt 0) { $g.FillRectangle((New-Object Drawing.SolidBrush (Get-BarColor $row.Slot $row.Pct $true)), $x, $y, [float]$fill, (Px 6)) }
        $y += Px 10
        $g.DrawString($row.Reset, $small, $grey, $x, $y); $y += Px 26
    }
    $foot = 'Click icon to close'
    if ($script:State.Updated) { $foot = 'Updated ' + $script:State.Updated.ToString('h:mm tt') + '  |  right-click for options' }
    $g.DrawString($foot, $small, $grey, $x, $y + (Px 2)); $y += Px 26
    if ($s.Height -ne $y) { $s.Height = $y }
    $title.Dispose(); $body.Dispose(); $small.Dispose()
})

function Show-Popup {
    if ($script:Popup.Visible) { $script:Popup.Hide(); return }
    $script:Popup.Height = Px 220
    $wa = [Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea
    $c = [Windows.Forms.Cursor]::Position
    $px = [math]::Min([math]::Max($c.X - $script:Popup.Width / 2, $wa.Left + 8), $wa.Right - $script:Popup.Width - 8)
    $script:Popup.Show()
    $script:Popup.Refresh()  # first paint sets the real height
    $py = [math]::Min([math]::Max($c.Y - $script:Popup.Height - 12, $wa.Top + 8), $wa.Bottom - $script:Popup.Height - 8)
    $script:Popup.Location = New-Object Drawing.Point ([int]$px), ([int]$py)
    $script:Popup.Activate()
}

# ---------- menu ----------

$menu = New-Object Windows.Forms.ContextMenuStrip
$miRefresh = $menu.Items.Add('Refresh now')
$miRefresh.Add_Click({ Update-Usage })
# Submenu of radio-style choices for one setting. The parent's Tag holds the
# setting name; each child's Tag holds its value.
function New-ChoiceMenu([string]$title, [string]$setting, $choices) {
    $parent = New-Object Windows.Forms.ToolStripMenuItem $title
    $parent.Tag = $setting
    foreach ($c in $choices) {
        $it = New-Object Windows.Forms.ToolStripMenuItem $c[1]
        $it.Tag = $c[0]; $it.Checked = ($script:Settings[$setting] -eq $c[0])
        $it.Add_Click({
            param($sender)
            $p = $sender.OwnerItem
            $script:Settings[$p.Tag] = $sender.Tag
            foreach ($x in $p.DropDownItems) { if ($null -ne $x.Tag) { $x.Checked = ($x.Tag -eq $sender.Tag) } }
            Save-Settings; Apply-Settings
        })
        [void]$parent.DropDownItems.Add($it)
    }
    return $parent
}

function Apply-Settings {
    $ms = [int]$script:Settings.refreshMinutes * 60000
    if ($script:Timer.Interval -ne $ms) { $script:Timer.Interval = $ms }  # restarts the countdown
    Update-Tray
}

if (-not ($IntervalChoices | Where-Object { $_[0] -eq $script:Settings.refreshMinutes })) { $script:Settings.refreshMinutes = 5 }
[void]$menu.Items.Add((New-ChoiceMenu 'Refresh every' 'refreshMinutes' $IntervalChoices))
[void]$menu.Items.Add((New-ChoiceMenu 'Style' 'style' $StyleChoices))
$miColor = New-ChoiceMenu 'Color' 'color' $ColorChoices
[void]$miColor.DropDownItems.Add('-')
$miWarn = New-Object Windows.Forms.ToolStripMenuItem 'Turn amber / red at 70% / 90%'
$miWarn.Checked = [bool]$script:Settings.warn
$miWarn.Add_Click({
    $script:Settings.warn = -not [bool]$script:Settings.warn
    $miWarn.Checked = $script:Settings.warn
    Save-Settings; Update-Tray
})
[void]$miColor.DropDownItems.Add($miWarn)
[void]$menu.Items.Add($miColor)
$miWeb = $menu.Items.Add('Open usage on claude.ai')
$miWeb.Add_Click({ Start-Process 'https://claude.ai/settings/usage' })
$miStart = New-Object Windows.Forms.ToolStripMenuItem 'Start with Windows'
$miStart.Checked = Test-Path $StartupLnk
$miStart.Add_Click({
    if (Test-Path $StartupLnk) { Remove-Item $StartupLnk -Force }
    else {
        $sh = New-Object -ComObject WScript.Shell
        $l = $sh.CreateShortcut($StartupLnk)
        $l.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
        $l.Arguments = '"' + $Launcher + '"'; $l.WorkingDirectory = $PSScriptRoot; $l.Save()
    }
    $miStart.Checked = Test-Path $StartupLnk
})
[void]$menu.Items.Add($miStart)
[void]$menu.Items.Add('-')
$miExit = $menu.Items.Add('Exit')
$miExit.Add_Click({ $script:Timer.Stop(); $script:Tray.Visible = $false; [Windows.Forms.Application]::Exit() })

# ---------- start ----------

$script:Tray = New-Object Windows.Forms.NotifyIcon
$script:Tray.ContextMenuStrip = $menu
$script:Tray.Add_MouseClick({ param($s, $e) if ($e.Button -eq 'Left') { Show-Popup } })
$script:Tray.Visible = $true

$script:Timer = New-Object Windows.Forms.Timer
$script:Timer.Interval = [int]$script:Settings.refreshMinutes * 60000
$script:Timer.Add_Tick({ Update-Usage })
$script:Timer.Start()

Update-Usage
[Windows.Forms.Application]::Run()
$script:Tray.Dispose()
