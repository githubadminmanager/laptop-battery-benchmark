<#
.SYNOPSIS
    Battery Benchmark for Windows laptops: runs a standard "simulated user" workload,
    logs the battery every minute, and rates the battery at the end.

.PARAMETER Brightness
    Screen brightness (1-100) used during the test. 0 = leave brightness alone. Default 65.
.PARAMETER NoWorkload
    Skip the simulated user (no apps opened). Use the laptop yourself.
.PARAMETER StopAt
    Stop automatically when the battery reaches this percentage. 0 = never (run until empty). Default 10.
.PARAMETER Minutes
    Stop automatically after this many minutes. 0 = no time limit. Default 0.
.PARAMETER OutputPath
    Folder for battery_log.txt and the CSV file. Default: your Desktop.
.PARAMETER ReportFrom
    Path to a saved battery_benchmark_*.csv. Builds the final report from it and exits; no test is run.
    Use it when the battery died (or the window closed) before the report was shown.
    Add -StopAt if you used a different value than the default 10.
    Example:  .\battery_test.ps1 -ReportFrom "$env:USERPROFILE\Desktop\battery_benchmark_20261123_0900.csv"
.PARAMETER PcAgeYears
    Age of this PC in years, used to judge the battery fairly (an old laptop is not expected to match a new one).
    Default: worked out from the BIOS date, which is only approximate (a BIOS update makes a PC look newer).
.PARAMETER KeepApps
    Do not close your open apps before the test. (The result is then less comparable.)
.PARAMETER Sites
    Websites to open as browser tabs. Default: 5 ordinary news / reference sites.
.PARAMETER Tabs
    How many browser tabs to open (1-30). 0 (default) = one tab per website in -Sites.
    Asking for more tabs than websites adds extra ordinary websites automatically.
.PARAMETER Browser
    Auto (default: Chrome, else Edge), Chrome, Edge, or None (no browser at all).
.PARAMETER NoNotepad
    Don't open or use Notepad.
.PARAMETER NoCalculator
    Don't open or use Calculator.
.PARAMETER MouseActivity
    How often the mouse wanders: Low (about every 8 s), Normal (about every 3 s, default), High (every 1-2 s).
.PARAMETER TabSwitchEvery
    Switch browser tab every N page visits (each visit is about a minute apart). 0 = never. Default 3.
.PARAMETER Customize
    Open the settings menu. It also opens by itself when you start the script with no options.
    In the menu you can change everything and save it as your default (stored in %APPDATA%).
#>
param(
    [int]$Brightness = 65,
    [switch]$NoWorkload,
    [int]$StopAt = 10,
    [int]$Minutes = 0,
    [string]$OutputPath = [Environment]::GetFolderPath('Desktop'),
    [string]$ReportFrom = "",
    [switch]$KeepApps,
    [double]$PcAgeYears = -1,
    [switch]$NoNotepad,
    [switch]$NoCalculator,
    [ValidateSet('Auto', 'Chrome', 'Edge', 'None')][string]$Browser = 'Auto',
    [ValidateRange(0, 30)][int]$Tabs = 0,
    [ValidateSet('Low', 'Normal', 'High')][string]$MouseActivity = 'Normal',
    [ValidateRange(0, 20)][int]$TabSwitchEvery = 3,
    [switch]$Customize,
    [string[]]$Sites = @(
        "https://en.wikipedia.org/wiki/Laptop",
        "https://news.ycombinator.com/",
        "https://www.bbc.com/news",
        "https://en.wikipedia.org/wiki/Lithium-ion_battery",
        "https://www.nasa.gov/"
    )
)

$ScriptVersion = "1.6.0"
$cmdLineParams = @($PSBoundParameters.Keys)     # which options were typed on the command line
$replay = $false     # becomes $true when the report is rebuilt from a CSV (-ReportFrom)

if (-not $OutputPath) { $OutputPath = $env:USERPROFILE }
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$log = Join-Path $OutputPath "battery_log.txt"
$csv = Join-Path $OutputPath ("battery_benchmark_{0}.csv" -f (Get-Date -Format "yyyyMMdd_HHmm"))

# ---------------------------------------------------------------- helpers
function Out-Both($text) {
    Write-Host $text
    Add-Content -Path $log -Value $text -Encoding UTF8
}

# True if the user pressed Q or Ctrl+C
function Test-Stop {
    while ([Console]::KeyAvailable) {
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq 'Q') { return $true }
        if ($k.Key -eq 'C' -and ($k.Modifiers -band [ConsoleModifiers]::Control)) { return $true }
    }
    return $false
}

# After a manual stop: wait 20 seconds for R (resume). Anything else, or no key, means finish.
function Read-ResumeChoice {
    try { $Host.UI.RawUI.FlushInputBuffer() } catch { }
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            return ($k.Key -eq 'R')
        }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

# Real power draw (mW) and energy left (mWh) from the battery, if the laptop reports it
function Get-Power {
    try {
        $b = Get-CimInstance -Namespace root/wmi -ClassName BatteryStatus -ErrorAction Stop | Select-Object -First 1
        return [pscustomobject]@{ Rate = [double]$b.DischargeRate; Remaining = [double]$b.RemainingCapacity }
    } catch { return $null }
}

# Battery state. Copes with laptops that have two batteries (average charge) and
# treats every "charging" state as plugged in, not just status 2.
function Get-Batt {
    $b = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
    if ($b.Count -eq 0) { return $null }
    $vals    = @($b | Where-Object { $null -ne $_.EstimatedChargeRemaining } | ForEach-Object { [int]$_.EstimatedChargeRemaining })
    $charge  = if ($vals.Count) { [int][math]::Round(($vals | Measure-Object -Average).Average) } else { $null }
    $plugged = [bool]($b | Where-Object { @(2, 6, 7, 8, 9) -contains [int]$_.BatteryStatus })
    return [pscustomobject]@{ Charge = $charge; Plugged = $plugged }
}

# Battery capacity in Wh (full-charge and design), if the laptop reports it
function Get-CapacityWh {
    $full = $null; $design = $null
    try { $full   = [double](Get-CimInstance -Namespace root/wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop | Select-Object -First 1).FullChargedCapacity / 1000 } catch { }
    try { $design = [double](Get-CimInstance -Namespace root/wmi -ClassName BatteryStaticData -ErrorAction Stop | Select-Object -First 1).DesignedCapacity / 1000 } catch { }
    return [pscustomobject]@{ Full = $full; Design = $design }
}

# Text from a CSV cell to a number; empty or unreadable gives $null
function ConvertTo-NumOrNull($v) {
    if ($null -eq $v -or "$v" -eq '') { return $null }
    $d = 0.0
    if ([double]::TryParse("$v", [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
    return $null
}

function Format-Hours($h) {
    if ($null -eq $h) { return "N/A" }
    $t = [timespan]::FromHours($h)
    return ("{0}h {1:00}m" -f [int][math]::Floor($t.TotalHours), $t.Minutes)
}

function Format-Change($n) {
    if ($n -gt 0) { return "-$n%" } elseif ($n -lt 0) { return "+$(-$n)%" } else { return "0%" }
}

function Get-Brightness {
    try { return (Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorBrightness -ErrorAction Stop | Select-Object -First 1).CurrentBrightness }
    catch { return $null }
}

function Set-Brightness($level) {
    try {
        $m = Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorBrightnessMethods -ErrorAction Stop | Select-Object -First 1
        Invoke-CimMethod -InputObject $m -MethodName WmiSetBrightness -Arguments @{ Timeout = [uint32]1; Brightness = [byte]$level } | Out-Null
        return $true
    } catch { return $false }
}

# How old is this PC? Uses -PcAgeYears if given, otherwise the BIOS date (approximate).
function Get-PcAge {
    if ($PcAgeYears -ge 0) { return [pscustomobject]@{ Years = $PcAgeYears; Source = "set with -PcAgeYears" } }
    try {
        $d = (Get-CimInstance Win32_BIOS -ErrorAction Stop | Select-Object -First 1).ReleaseDate
        if ($d -and $d -gt [datetime]'1995-01-01' -and $d -lt (Get-Date)) {
            return [pscustomobject]@{ Years = [math]::Round(((Get-Date) - $d).TotalDays / 365.25, 1); Source = "BIOS dated $($d.ToString('yyyy-MM-dd'))" }
        }
    } catch { }
    return [pscustomobject]@{ Years = $null; Source = "BIOS date not available" }
}

# How much battery life to expect compared with a new laptop: 100% up to 2 years old,
# then falling by 6.25 points per year (50% at 10 years), never below 40%.
function Get-AgeFactor($years) {
    if ($null -eq $years -or $years -le 2) { return 1.0 }
    return [math]::Max(0.4, 1 - 0.0625 * ($years - 2))
}

# Rate battery life. $f scales the expectations for older PCs (0.5 = half what a new laptop manages).
function Get-LifeRating($h, $f = 1.0) {
    $h = $h / $f
    if     ($h -ge 10) { return "EXCELLENT" }
    elseif ($h -ge 7)  { return "GOOD" }
    elseif ($h -ge 5)  { return "AVERAGE" }
    elseif ($h -ge 3)  { return "POOR" }
    else               { return "BAD" }
}

function Get-HealthRating($pct) {
    if     ($pct -ge 90) { return "EXCELLENT" }
    elseif ($pct -ge 80) { return "GOOD" }
    elseif ($pct -ge 60) { return "WORN" }
    else                 { return "BAD (consider replacing)" }
}

# ---------------------------------------------------------------- simulated user
$wsh          = New-Object -ComObject WScript.Shell
$browserDir   = Join-Path $env:TEMP "battery_test_browser"     # own throw-away browser profile
$browserInfo  = $null                                          # set by Start-Workload (Chrome, or Edge if no Chrome)
$startedNames = @()
$useNotepad = $false; $useCalc = $false; $useBrowser = $false
$scrolls = 0
$rng = New-Object System.Random

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Namespace Native -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
[DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);
[DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, int dwData, UIntPtr dwExtraInfo);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
'@

# Window handle of one of the apps we started (zero if not found)
function Get-AppHandle($app) {
    try {
        $procs = @()
        if ($app -eq "notepad" -and $script:useNotepad) {
            $procs = @(Get-Process -Name notepad -ErrorAction SilentlyContinue)
        } elseif ($app -eq "calc" -and $script:useCalc) {
            $procs = @(Get-Process -Name CalculatorApp, Calculator -ErrorAction SilentlyContinue)
            if (-not ($procs | Where-Object { $_.MainWindowHandle -ne 0 })) {
                # Store apps live inside ApplicationFrameHost, so find the window by its title
                $procs = @(Get-Process -Name ApplicationFrameHost -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -like 'Calculator*' })
            }
        } elseif ($app -eq "browser" -and $script:useBrowser) {
            $ids = @(Get-CimInstance Win32_Process -Filter "Name='$($script:browserInfo.Exe)'" -ErrorAction SilentlyContinue |
                     Where-Object { $_.CommandLine -like "*battery_test_browser*" } | ForEach-Object { $_.ProcessId })
            $procs = @($ids | ForEach-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
        }
        foreach ($p in $procs) { if ($p.MainWindowHandle -ne 0) { return $p.MainWindowHandle } }
    } catch { }
    return [IntPtr]::Zero
}

# Bring a window to the front. Returns $true only if it really is in front afterwards.
function Show-Window($h) {
    if ($h -eq [IntPtr]::Zero) { return $false }
    # Restore only if minimised. (Restoring a maximised window would un-maximise it.)
    if ([Native.Win]::IsIconic($h)) { [void][Native.Win]::ShowWindow($h, 9) }
    [void][Native.Win]::SetForegroundWindow($h)
    Start-Sleep -Milliseconds 500
    if ([Native.Win]::GetForegroundWindow() -ne $h) {
        # Windows sometimes refuses to change the front window; a tap of Alt lifts that block
        [Native.Win]::keybd_event([byte]0x12, [byte]0, [uint32]0, [UIntPtr]::Zero)
        [Native.Win]::keybd_event([byte]0x12, [byte]0, [uint32]2, [UIntPtr]::Zero)
        [void][Native.Win]::SetForegroundWindow($h)
        Start-Sleep -Milliseconds 500
    }
    return ([Native.Win]::GetForegroundWindow() -eq $h)
}

# A point inside a window, given as a fraction of its width/height (0.5, 0.5 = centre)
function Get-WindowPoint($h, $fx, $fy) {
    $r = New-Object Native.Win+RECT
    [void][Native.Win]::GetWindowRect($h, [ref]$r)
    return @([int]($r.Left + ($r.Right - $r.Left) * $fx), [int]($r.Top + ($r.Bottom - $r.Top) * $fy))
}

# Glide the mouse pointer to a spot, like a hand would
function Move-MouseTo($x, $y, $steps = 50) {
    $start = [System.Windows.Forms.Cursor]::Position
    for ($i = 1; $i -le $steps; $i++) {
        $nx = [int]($start.X + ($x - $start.X) * $i / $steps)
        $ny = [int]($start.Y + ($y - $start.Y) * $i / $steps)
        [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point($nx, $ny)
        Start-Sleep -Milliseconds 12
    }
    # Setting the cursor position does NOT count as user activity for Windows' idle timers.
    # A 1-pixel nudge sent as real mouse input does (and resets the screen-off / lock timer).
    [Native.Win]::mouse_event(0x0001, 1, 0, 0, [UIntPtr]::Zero)                  # MOUSEEVENTF_MOVE +1 px
    Start-Sleep -Milliseconds 30
    [Native.Win]::mouse_event(0x0001, [uint32]4294967295, 0, 0, [UIntPtr]::Zero)  # and back (-1 px)
}

# A small, random, human-like wander of the pointer (people never hold the mouse perfectly still)
function Move-MouseWander {
    $cur = [System.Windows.Forms.Cursor]::Position
    $b   = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $x = [math]::Min([math]::Max($cur.X + $script:rng.Next(-140, 141), $b.Left + 20), $b.Right - 20)
    $y = [math]::Min([math]::Max($cur.Y + $script:rng.Next(-90, 91),  $b.Top + 20),  $b.Bottom - 20)
    Move-MouseTo $x $y 20
}

function Send-Click {
    [Native.Win]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)   # left button down
    Start-Sleep -Milliseconds 60
    [Native.Win]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)   # left button up
}

# Mouse wheel: positive = scroll down, negative = scroll up (one notch = 3 lines)
function Send-Wheel($notches) {
    [Native.Win]::mouse_event(0x0800, 0, 0, (-120 * $notches), [UIntPtr]::Zero)
}

# Find the window that holds this console so we can bring it back to the front after each action
function Get-ConsoleWindowPid {
    $p = $PID
    for ($i = 0; $i -lt 6; $i++) {
        try {
            $proc = Get-Process -Id $p -ErrorAction Stop
            if ($proc.MainWindowHandle -ne 0) { return $p }
            $p = (Get-CimInstance Win32_Process -Filter "ProcessId=$p").ParentProcessId
        } catch { return $null }
    }
    return $null
}

# ---------------------------------------------------------------- settings (tabs, browser, mouse ...) and the menu
$settingsFile = Join-Path $env:APPDATA 'battery_benchmark_settings.json'
$settingNames = @('Tabs', 'Browser', 'Sites', 'NoNotepad', 'NoCalculator', 'MouseActivity', 'TabSwitchEvery', 'Brightness', 'StopAt', 'Minutes', 'KeepApps', 'PcAgeYears')
$defaultSites = @('https://en.wikipedia.org/wiki/Laptop', 'https://news.ycombinator.com/', 'https://www.bbc.com/news',
                  'https://en.wikipedia.org/wiki/Lithium-ion_battery', 'https://www.nasa.gov/')
$settingDefaults = @{ Tabs = 0; Browser = 'Auto'; Sites = $defaultSites; NoNotepad = $false; NoCalculator = $false; MouseActivity = 'Normal'
                      TabSwitchEvery = 3; Brightness = 65; StopAt = 10; Minutes = 0; KeepApps = $false; PcAgeYears = -1 }
# Extra ordinary websites, used when you ask for more tabs than websites
$extraSites = @('https://www.reuters.com/', 'https://www.npr.org/', 'https://arstechnica.com/', 'https://en.wikipedia.org/wiki/Computer',
                'https://www.nationalgeographic.com/', 'https://www.weather.gov/', 'https://www.theguardian.com/international',
                'https://en.wikipedia.org/wiki/Solar_System', 'https://www.sciencedaily.com/', 'https://en.wikipedia.org/wiki/Internet',
                'https://www.britannica.com/', 'https://www.smithsonianmag.com/', 'https://en.wikipedia.org/wiki/Moon', 'https://www.cnet.com/',
                'https://en.wikipedia.org/wiki/Bicycle', 'https://www.gutenberg.org/', 'https://en.wikipedia.org/wiki/Tokyo', 'https://www.loc.gov/',
                'https://en.wikipedia.org/wiki/Jazz', 'https://en.wikipedia.org/wiki/Ocean', 'https://en.wikipedia.org/wiki/Coffee',
                'https://en.wikipedia.org/wiki/Mount_Everest', 'https://en.wikipedia.org/wiki/Chess', 'https://en.wikipedia.org/wiki/Railway',
                'https://www.nasa.gov/missions/')

# The websites that will really be opened, one per tab
function Get-TabUrls {
    $urls = @($Sites | Where-Object { $_ })
    if ($urls.Count -eq 0) { $urls = @($defaultSites) }
    $n = if ($Tabs -gt 0) { $Tabs } else { $urls.Count }
    foreach ($e in $extraSites) {
        if ($urls.Count -ge $n) { break }
        if ($urls -notcontains $e) { $urls += $e }
    }
    $i = 0
    while ($urls.Count -lt $n) { $urls += $urls[$i]; $i++ }
    return @($urls | Select-Object -First $n)
}

# Seconds to wait before the next small mouse wander
function Get-WanderDelay {
    switch ($MouseActivity) {
        'Low'   { return $script:rng.Next(6, 11) }
        'High'  { return $script:rng.Next(1, 3) }
        default { return $script:rng.Next(2, 5) }
    }
}

# One-line description of what the simulated user will open
function Get-WorkloadSummary {
    $a = @()
    if (-not $NoNotepad)    { $a += 'Notepad' }
    if (-not $NoCalculator) { $a += 'Calculator' }
    if ($Browser -ne 'None') {
        $bn = switch ($Browser) { 'Chrome' { 'Chrome' } 'Edge' { 'Edge' } default { 'a browser (Chrome, else Edge)' } }
        $a += "$bn with $(@(Get-TabUrls).Count) tabs"
    }
    if ($a.Count -eq 0) { return 'nothing (only the mouse moves)' }
    return ($a -join ', ')
}

function Export-SavedSettings {
    $o = [ordered]@{}
    foreach ($n in $settingNames) {
        $v = Get-Variable -Name $n -Scope Script -ValueOnly
        if ($v -is [System.Management.Automation.SwitchParameter]) { $v = [bool]$v }
        if ($n -eq 'Sites') { $v = @($v | ForEach-Object { "$_" }) }     # plain strings, or ConvertTo-Json adds extra fields
        $o[$n] = $v
    }
    $o | ConvertTo-Json | Set-Content -LiteralPath $settingsFile -Encoding UTF8
}

# Apply saved settings, except for options typed on the command line
function Import-SavedSettings {
    if (-not (Test-Path -LiteralPath $settingsFile)) { return $false }
    try { $s = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json } catch { return $false }
    foreach ($n in $settingNames) {
        if ($script:cmdLineParams -contains $n) { continue }
        if ($null -eq $s.$n) { continue }
        try {
            if ($n -eq 'Sites') { Set-Variable -Name $n -Value ([string[]]@($s.$n)) -Scope Script }
            else                { Set-Variable -Name $n -Value $s.$n -Scope Script }
        } catch { }
    }
    return $true
}

function Read-IntSetting($label, $min, $max, $current) {
    $a = (Read-Host "$label ($min-$max, Enter keeps $current)").Trim()
    if ($a -eq '') { return $current }
    $v = 0
    if ([int]::TryParse($a, [ref]$v) -and $v -ge $min -and $v -le $max) { return $v }
    Write-Host "  Not a number from $min to $max - keeping $current."
    return $current
}

function Read-ChoiceSetting($label, $options, $current) {
    for ($i = 0; $i -lt $options.Count; $i++) { Write-Host ("      {0}) {1}" -f ($i + 1), $options[$i]) }
    $a = (Read-Host "$label (Enter keeps $current)").Trim()
    if ($a -eq '') { return $current }
    $idx = 0
    if ([int]::TryParse($a, [ref]$idx) -and $idx -ge 1 -and $idx -le $options.Count) { return $options[$idx - 1] }
    $hit = @($options | Where-Object { $_ -ieq $a })
    if ($hit.Count) { return $hit[0] }
    Write-Host "  Not one of the choices - keeping $current."
    return $current
}

function Show-SettingsMenu {
    $urls  = @(Get-TabUrls)
    $hosts = ($urls | ForEach-Object { try { ([uri]$_).Host -replace '^www\.', '' } catch { $_ } }) -join ', '
    if ($hosts.Length -gt 58) { $hosts = $hosts.Substring(0, 55) + '...' }
    $yn    = { param($b) if ($b) { 'yes' } else { 'no' } }
    $mouse = switch ($MouseActivity) { 'Low' { 'Low (about every 8 s)' } 'High' { 'High (every 1-2 s)' } default { 'Normal (about every 3 s)' } }
    $rows = @(
        @(' 1', 'Browser tabs',            "$($urls.Count)$(if ($Tabs -eq 0) { ' (one per website)' })"),
        @(' 2', 'Browser',                 $(if ($Browser -eq 'Auto') { 'Auto (Chrome, else Edge)' } else { $Browser })),
        @(' 3', 'Websites',                $hosts),
        @(' 4', 'Use Notepad',             (& $yn (-not $NoNotepad))),
        @(' 5', 'Use Calculator',          (& $yn (-not $NoCalculator))),
        @(' 6', 'Mouse activity',          $mouse),
        @(' 7', 'Switch tab every',        $(if ($TabSwitchEvery -gt 0) { "$TabSwitchEvery page visits" } else { 'never' })),
        @(' 8', 'Screen brightness',       $(if ($Brightness -gt 0) { "$Brightness%" } else { 'left alone' })),
        @(' 9', 'Stop at battery',         $(if ($StopAt -gt 0) { "$StopAt%" } else { 'runs until empty' })),
        @('10', 'Time limit',              $(if ($Minutes -gt 0) { "$Minutes min" } else { 'none' })),
        @('11', 'Close open apps first',   (& $yn (-not $KeepApps))),
        @('12', 'PC age (for the rating)', $(if ($PcAgeYears -ge 0) { "$PcAgeYears years" } else { 'automatic (from BIOS date)' }))
    )
    Write-Host ""
    Write-Host "------------------------- SETTINGS -------------------------"
    foreach ($r in $rows) { Write-Host ("  {0}) {1,-24} {2}" -f $r[0], $r[1], $r[2]) }
    Write-Host "-------------------------------------------------------------"
}

# Load saved settings, then (if wanted) let the user change them. Starts the test when they press Enter.
function Invoke-SettingsStep {
    $loaded = Import-SavedSettings
    $menu   = $Customize -or ($script:cmdLineParams.Count -eq 0)
    if (-not $menu) { return }
    if ($loaded) { Write-Host "Loaded your saved settings (R in the menu resets them)." }
    while ($true) {
        Show-SettingsMenu
        $c = (Read-Host "Type a number to change it, S = save these as my default, R = reset, Enter = START").Trim().ToUpper()
        if ($c -eq '') { break }
        switch ($c) {
            '1'  { $script:Tabs = Read-IntSetting 'How many browser tabs' 1 30 @(Get-TabUrls).Count }
            '2'  { $script:Browser = Read-ChoiceSetting 'Browser' @('Auto', 'Chrome', 'Edge', 'None') $Browser }
            '3'  {
                $a = (Read-Host "Website addresses separated by spaces (D = default list, Enter keeps)").Trim()
                if ($a -eq '') { }
                elseif ($a -ieq 'D') { $script:Sites = $defaultSites }
                else {
                    $new = @()
                    foreach ($w in @($a -split '[\s,;]+' | Where-Object { $_ })) {
                        if ($w -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') { $w = "https://$w" }
                        if ($w -match '^https?://[^\s/]+') { $new += $w } else { Write-Host "  Skipped (needs to be a normal web address): $w" }
                    }
                    if ($new.Count) { $script:Sites = $new; $script:Tabs = 0; Write-Host "  Using your $($new.Count) website(s). Use option 1 for more tabs." }
                }
            }
            '4'  { $script:NoNotepad    = -not [bool]$script:NoNotepad }
            '5'  { $script:NoCalculator = -not [bool]$script:NoCalculator }
            '6'  { $script:MouseActivity = Read-ChoiceSetting 'Mouse activity' @('Low', 'Normal', 'High') $MouseActivity }
            '7'  { $script:TabSwitchEvery = Read-IntSetting 'Switch tab every N page visits (0 = never)' 0 20 $TabSwitchEvery }
            '8'  { $script:Brightness = Read-IntSetting 'Screen brightness % (0 = leave alone)' 0 100 $Brightness }
            '9'  { $script:StopAt = Read-IntSetting 'Stop at battery % (0 = run until empty)' 0 95 $StopAt }
            '10' { $script:Minutes = Read-IntSetting 'Time limit in minutes (0 = none)' 0 10000 $Minutes }
            '11' { $script:KeepApps = -not [bool]$script:KeepApps }
            '12' {
                $a = (Read-Host "PC age in years, or A for automatic (Enter keeps)").Trim()
                if ($a -ieq 'A') { $script:PcAgeYears = -1 }
                elseif ($a -ne '') {
                    $d = 0.0
                    if ([double]::TryParse($a, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d) -and $d -ge 0 -and $d -le 40) { $script:PcAgeYears = $d }
                    else { Write-Host "  Not a valid age - keeping it." }
                }
            }
            'S'  { try { Export-SavedSettings; Write-Host "  Saved. These will be your defaults next time ($settingsFile)." } catch { Write-Host "  Could not save: $($_.Exception.Message)" } }
            'R'  {
                foreach ($n in $settingNames) { Set-Variable -Name $n -Value $settingDefaults[$n] -Scope Script }
                Remove-Item -LiteralPath $settingsFile -Force -ErrorAction SilentlyContinue
                Write-Host "  Back to the built-in defaults (saved settings deleted)."
            }
            default { Write-Host "  Not a choice. Type a number from 1 to 12, S, R, or just press Enter." }
        }
    }
}

# Pick the browser for the workload (Auto = Chrome if installed, otherwise Edge)
function Find-Browser {
    if ($Browser -eq 'None') { return $null }
    if ($Browser -in 'Auto', 'Chrome') {
        $chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
                    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
                    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe")
        foreach ($p in $chrome) { if ($p -and (Test-Path -LiteralPath $p)) { return [pscustomobject]@{ Label = 'Chrome'; Exe = 'chrome.exe'; Path = $p } } }
    }
    if ($Browser -in 'Auto', 'Edge') {
        $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
                  "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe")
        foreach ($p in $edge) { if ($p -and (Test-Path -LiteralPath $p)) { return [pscustomobject]@{ Label = 'Edge'; Exe = 'msedge.exe'; Path = $p } } }
    }
    return $null
}
# Apps that have an open window and would be closed (never includes this console or Windows' own shell)
function Get-CloseCandidates {
    $protect = @('explorer', 'dwm', 'winlogon', 'csrss', 'ApplicationFrameHost', 'ShellExperienceHost', 'StartMenuExperienceHost',
                 'SearchHost', 'SearchApp', 'TextInputHost', 'LockApp', 'SystemSettings', 'RuntimeBroker', 'sihost', 'taskhostw', 'ctfmon',
                 'WindowsTerminal', 'OpenConsole', 'conhost', 'powershell', 'pwsh', 'cmd', 'powershell_ise', 'Idle', 'Taskmgr')
    $keepPid = Get-ConsoleWindowPid
    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -and $_.Id -ne $PID -and $_.Id -ne $keepPid -and ($protect -notcontains $_.ProcessName) })
}

# Close the apps the user has open so only the test workload runs. Asks first, asks politely
# (like clicking the X, so programs can offer to save work) and never force-kills anything.
function Close-OtherApps {
    $apps = Get-CloseCandidates
    if ($apps.Count -eq 0) { return }
    Write-Host ""
    Write-Host "These apps are open and would use battery during the test:"
    $apps | Group-Object ProcessName | ForEach-Object { Write-Host ("   - {0}" -f $_.Name) }
    Write-Host "They are asked to close politely (nothing is force-closed), so a program may ask you to save first."
    $ans = Read-Host "Press Enter to close them, or type N to leave them open"
    if ($ans -match '^\s*[nN]') { Write-Host "Leaving them open. The result will be less comparable."; return }

    $left = $apps
    foreach ($round in 1..2) {                       # second round catches extra windows of the same program
        foreach ($p in $left) { try { [void]$p.CloseMainWindow() } catch { } }
        $deadline = (Get-Date).AddSeconds(10)
        do {
            Start-Sleep -Seconds 1
            $left = @($left | Where-Object { try { $_.Refresh(); -not $_.HasExited } catch { $false } })
        } while ($left.Count -gt 0 -and (Get-Date) -lt $deadline)
        if ($left.Count -eq 0) { break }
    }
    if ($left.Count -gt 0) {
        Write-Host "Still open (maybe waiting for you to save):"
        $left | Group-Object ProcessName | ForEach-Object { Write-Host ("   - {0}" -f $_.Name) }
        [void](Read-Host "Close them yourself, then press Enter to continue")
    }
    Write-Host "Apps closed. Background and tray programs are left alone."
}

function Start-Workload {
    $running = @(Get-Process | Select-Object -ExpandProperty ProcessName)

    if (-not $NoNotepad -and $running -notcontains 'notepad') {
        try { Start-Process notepad; $script:startedNames += 'notepad'; $script:useNotepad = $true } catch { }
    }
    if (-not $NoCalculator -and ($running -notcontains 'CalculatorApp') -and ($running -notcontains 'Calculator')) {
        try { Start-Process calc; $script:startedNames += 'CalculatorApp'; $script:startedNames += 'Calculator'; $script:useCalc = $true } catch { }
    }
    $script:browserInfo = Find-Browser
    if ($script:browserInfo) {
        try {
            # Own temporary profile, so we never touch your real browser windows or logins
            $bArgs = @("--user-data-dir=`"$browserDir`"", "--new-window", "--no-first-run", "--no-default-browser-check") + @(Get-TabUrls)
            Start-Process -FilePath $script:browserInfo.Path -ArgumentList $bArgs
            $script:useBrowser = $true
        } catch { }
    } else {
        if ($Browser -ne 'None') { Write-Host "The browser you asked for was not found - running without a browser." }
    }
    Start-Sleep -Seconds 15     # let the tabs load
    # Maximise the browser so every laptop renders a similar amount of screen
    $bh = Get-AppHandle "browser"
    if ($bh -ne [IntPtr]::Zero) { [void][Native.Win]::ShowWindow($bh, 3) }
}

function Stop-Workload {
    foreach ($n in $script:startedNames) {
        Get-Process -Name $n -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    if ($script:useBrowser) {
        Get-CimInstance Win32_Process -Filter "Name='$($script:browserInfo.Exe)'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like "*battery_test_browser*" } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 2
        Remove-Item $browserDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
# A point to aim the mouse at: inside the window if we have one, otherwise a spot on the main screen
function Get-TargetPoint($h, $fx, $fy) {
    if ($h -ne [IntPtr]::Zero) {
        $p = Get-WindowPoint $h $fx $fy
        if ($p[0] -gt -10000 -and $p[1] -gt -10000) { return $p }     # a minimised window reports garbage
    }
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    return @([int]($b.Left + $b.Width * $fx), [int]($b.Top + $b.Height * $fy))
}

# One small "user" action every 15 seconds, rotating between apps.
# The mouse ALWAYS moves. Clicking, typing and scrolling only happen if the app really is in front.
function Invoke-UserAction($tick) {
    switch ($tick % 4) {
        0 {   # Notepad: move mouse in, click, type
            if (-not $script:useNotepad) { Move-MouseWander; Write-Host "      [sim] (no Notepad) mouse wandered"; return }
            $h = Get-AppHandle "notepad"
            $front = Show-Window $h
            $pt = Get-TargetPoint $h 0.5 0.5
            Move-MouseTo $pt[0] $pt[1]
            if ($front) {
                Send-Click
                $wsh.SendKeys("Typing a short note while testing the battery. ")
                Write-Host "      [sim] Notepad: moved mouse, clicked, typed"
            } else { Write-Host "      [sim] Notepad: moved mouse (window not in front, so no click or typing)" }
        }
        1 {   # Browser: move mouse in, scroll the page, and change tab every third visit
            if (-not $script:useBrowser) { Move-MouseWander; Write-Host "      [sim] (no browser) mouse wandered"; return }
            $h = Get-AppHandle "browser"
            $front = Show-Window $h
            $pt = Get-TargetPoint $h 0.5 0.55
            Move-MouseTo $pt[0] $pt[1]
            if ($front) {
                $script:scrolls++
                $tabNote = ""
                if ($TabSwitchEvery -gt 0 -and $script:scrolls % $TabSwitchEvery -eq 0) { $wsh.SendKeys("^{TAB}"); Start-Sleep -Milliseconds 800; $tabNote = ", switched tab" }
                if ($script:scrolls % 10 -eq 0) { Send-Wheel -40 } else { Send-Wheel 3 }
                Write-Host "      [sim] Browser: moved mouse$tabNote, scrolled the page"
            } else { Write-Host "      [sim] Browser: moved mouse (window not in front, so no scrolling)" }
        }
        2 {   # Calculator: move mouse over it, type a sum
            if (-not $script:useCalc) { Move-MouseWander; Write-Host "      [sim] (no Calculator) mouse wandered"; return }
            $h = Get-AppHandle "calc"
            $front = Show-Window $h
            $pt = Get-TargetPoint $h 0.5 0.6
            Move-MouseTo $pt[0] $pt[1]
            if ($front) {
                $wsh.SendKeys("123*45{ENTER}")
                Start-Sleep -Milliseconds 300
                $wsh.SendKeys("{ESC}")
                Write-Host "      [sim] Calculator: moved mouse, typed a sum"
            } else { Write-Host "      [sim] Calculator: moved mouse (window not in front, so no typing)" }
        }
        3 {   # idle, like someone reading: small mouse drift, back and forth
            $cur = [System.Windows.Forms.Cursor]::Position
            $dir = if ([math]::Floor($tick / 4) % 2 -eq 0) { 1 } else { -1 }
            Move-MouseTo ($cur.X + 40 * $dir) ($cur.Y + 25 * $dir)
            Write-Host "      [sim] idle (reading): mouse drifted"
        }
    }
}

# ---------------------------------------------------------------- final report
function Show-Report {
    $endTime   = if ($replay) { $replayEnd }        else { Get-Date }
    $endCharge = if ($replay) { $replayEndCharge }  else { (Get-Batt).Charge }
    $hours     = ($endTime - $startTime).TotalHours
    $durMin    = [math]::Round($hours * 60)
    $used      = $startCharge - $endCharge
    $reachedLevel = ($StopAt -gt 0 -and $endCharge -le $StopAt)

    # ---- pace: how long each 1% took
    $vals    = @($drops | Where-Object { $null -ne $_.MinPerPct } | ForEach-Object { $_.MinPerPct })
    $n       = $vals.Count
    $paceAvg = if ($n -gt 0) { ($vals | Measure-Object -Average).Average } else { $null }
    $uneven  = $false
    if ($n -ge 8) {
        $half = [int][math]::Floor($n / 2)
        $f = ($vals[0..($half - 1)] | Measure-Object -Average).Average
        $s = ($vals[$half..($n - 1)] | Measure-Object -Average).Average
        $fT = [math]::Round($f, 1); $sT = [math]::Round($s, 1)
        if     ($s -gt 0 -and ($f / $s) -ge 1.35) { $uneven = $true; $paceLine = "UNEVEN - first half of the test took $fT min per 1%, second half $sT min. Early readings make the battery look better than it is." }
        elseif ($f -gt 0 -and ($s / $f) -ge 1.35) { $uneven = $true; $paceLine = "UNEVEN - first half of the test took $fT min per 1%, second half $sT min. Early readings make the battery look worse than it is." }
        else   { $paceLine = "steady - about $([math]::Round($paceAvg, 1)) min per 1%" }
    } else {
        $paceLine = "too few 1% steps ($n) to judge the pace yet"
    }
    $needLonger = ($uneven -or $n -lt 8)
    $recLine = ""
    if ($needLonger -and -not $reachedLevel) {
        if ($StopAt -gt 0) { $recLine = "Recommended: run until the battery reaches $StopAt% for an accurate result." }
        else               { $recLine = "Recommended: run until the battery runs out for an accurate result." }
    }

    # ---- Method 1: from the battery percentage
    if ($n -ge 3 -and $paceAvg -gt 0) {
        $pctFullH = 100 * $paceAvg / 60
        $pctLeftH = $endCharge * $paceAvg / 60
        $rate = [math]::Round(60 / $paceAvg, 1)
    } else {
        $rate     = if ($hours -gt 0) { [math]::Round($used / $hours, 1) } else { 0 }
        $pctFullH = if ($rate -gt 0) { 100 / $rate } else { $null }
        $pctLeftH = if ($rate -gt 0) { $endCharge / $rate } else { $null }
    }

    # ---- Method 2: from real power draw (more precise)
    if ($replay) {
        $endP = $null; $fullWh = $replayFullWh; $designWh = $replayDesignWh
    } else {
        $endP = Get-Power
        $cap = Get-CapacityWh; $fullWh = $cap.Full; $designWh = $cap.Design
    }
    $avgW     = if ($powerSamples.Count) { ($powerSamples | Measure-Object -Average).Average / 1000 } else { $null }
    $remWh    = if ($endP) { $endP.Remaining / 1000 } elseif ($replay) { $replayRemWh } else { $null }
    $pwrLeftH = if ($avgW -and $remWh -and $avgW -gt 0) { $remWh / $avgW } else { $null }
    $pwrFullH = if ($avgW -and $fullWh -and $avgW -gt 0) { $fullWh / $avgW } else { $null }

    # ---- pick the best estimate and decide if there is enough data to rate
    $valid = $false
    if ($null -ne $pwrFullH -and $durMin -ge 10) {
        $benchH = $pwrFullH; $leftH = $pwrLeftH; $src = "real power draw"; $valid = $true
    } elseif ($null -ne $pctFullH -and $durMin -ge 15 -and $used -ge 3) {
        $benchH = $pctFullH; $leftH = $pctLeftH; $src = "battery % pace (less precise)"; $valid = $true
    } else {
        $benchH = $null; $leftH = $null; $src = "not enough data"
    }

    $healthPct  = if ($fullWh -and $designWh -and $designWh -gt 0) { [math]::Round(100 * $fullWh / $designWh) } else { $null }
    $healthLine = if ($null -ne $healthPct) { "$healthPct% of original capacity -> $(Get-HealthRating $healthPct)" } else { "N/A (laptop doesn't report it)" }

    # ---- judge fairly for the age of the PC
    $pcAge   = Get-PcAge
    $ageF    = Get-AgeFactor $pcAge.Years
    $ageText = if ($null -eq $pcAge.Years) { "unknown ($($pcAge.Source)) - standard scale used" }
               else { "about $($pcAge.Years) yr old ($($pcAge.Source)) - expecting $([math]::Round(100 * $ageF))% of a new laptop's battery life" }
    if ($replay -and $PcAgeYears -lt 0) { $ageText += " [this PC's date; use -PcAgeYears if the CSV came from another PC]" }
    $scaled  = @(10, 7, 5, 3) | ForEach-Object { [string][math]::Round($_ * $ageF, 1) }

    if ($valid) {
        $ratingLine = "$(Get-LifeRating $benchH $ageF)  ($(Format-Hours $benchH) on a full charge)"
        if ($needLonger -and -not $reachedLevel) { $ratingLine += "  [PROVISIONAL]" }
        if ($ageF -lt 0.999) { $ratingLine += "`r`n                      (rated for this PC's age. A new laptop with this result would be: $(Get-LifeRating $benchH))" }
    } else {
        $ratingLine = "NOT ENOUGH DATA - run at least 15 minutes, on battery"
    }

    $avgCpu    = if ($readings.Count) { [math]::Round(($readings | Measure-Object Cpu -Average).Average, 1) } else { "N/A" }
    $brVals    = $readings | Where-Object { $null -ne $_.Bright }
    $avgBright = if ($brVals) { [math]::Round(($brVals | Measure-Object Bright -Average).Average, 0) } else { "N/A" }
    $topApps   = ($appCount.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 8 |
                  ForEach-Object { "$($_.Key) ($($_.Value)x)" }) -join ", "

    if (-not $topApps) { $topApps = "N/A" }
    $avgWText  = if ($null -ne $avgW)   { "$([math]::Round($avgW, 1)) W" } else { "N/A (laptop doesn't report it)" }
    $remText   = if ($null -ne $remWh)  { "$([math]::Round($remWh, 1)) Wh" } else { "N/A" }
    $fullText  = if ($null -ne $fullWh) { "$([math]::Round($fullWh, 1)) Wh" } else { "N/A" }
    $workText  = if ($replay) { "not stored in CSV" } elseif ($NoWorkload) { "none (manual use)" } else {
        $wa = @()
        if ($useNotepad) { $wa += 'Notepad' }
        if ($useCalc)    { $wa += 'Calculator' }
        if ($useBrowser) { $wa += "$($browserInfo.Label) ($(@(Get-TabUrls).Count) tabs)" }
        "simulated user: $(if ($wa.Count) { $wa -join ', ' } else { 'mouse only' }), mouse activity $MouseActivity" }
    $brightTxt = if ($brightSet) { "$Brightness% (set by test)" } elseif ($replay) { "$avgBright% (average of readings)" } else { "$avgBright% (not changed)" }
    $stopText  = switch ($stopReason) {
        "user"    { "you pressed stop" }
        "level"   { "battery reached $StopAt%" }
        "time"    { "time limit of $Minutes min reached" }
        "csv"     { "report rebuilt from a saved CSV file" }
        default   { "" }
    }

    # ---- full per-1% timing goes to the log file only
    if ($drops.Count) {
        Add-Content -Path $log -Encoding UTF8 -Value "Time each 1% took (first step is skipped, it started mid-percent):"
        foreach ($d in $drops) {
            $t = if ($null -ne $d.MinPerPct) { "$([math]::Round($d.MinPerPct, 1)) min" } else { "(start)" }
            Add-Content -Path $log -Encoding UTF8 -Value ("  {0,3}% reached at {1}  ->  {2}" -f $d.Percent, $d.At, $t)
        }
    }

    $lines = @(
        "",
        "=========== BATTERY BENCHMARK RESULT (v$ScriptVersion) ===========",
        "Laptop              : $($cs.Manufacturer) $($cs.Model)",
        "CPU                 : $cpuName",
        "Windows             : $osName",
        "PC age              : $ageText",
        "",
        "Test duration       : $durMin min ($($startTime.ToString('HH:mm')) -> $($endTime.ToString('HH:mm')))"
    )
    if ($stopText) { $lines += "Stopped because     : $stopText" }
    $lines += @(
        "Workload            : $workText",
        "Screen brightness   : $brightTxt",
        "Average CPU         : $avgCpu%",
        "Average power draw  : $avgWText",
        "Battery used        : $startCharge% -> $endCharge% (used $used%)",
        "Drain pace          : $paceLine",
        "Readings taken      : $($readings.Count)",
        "Most open apps      : $topApps",
        "",
        "----------------- RESULT -----------------",
        "Battery life rating : $ratingLine",
        "Time left from now  : $(Format-Hours $leftH)",
        "Battery health      : $healthLine",
        "Energy left / full  : $remText / $fullText",
        "Estimate based on   : $src",
        "(% method alone     : left $(Format-Hours $pctLeftH), full $(Format-Hours $pctFullH))"
    )
    if ($recLine) { $lines += $recLine }
    if ($replay) { $lines += "Note: rebuilt from 1-minute CSV readings, so the pace figures are approximate (about 1 minute either way per step)." }
    if ($pluggedReadings -gt 0) { $lines += "WARNING: charger was connected during $pluggedReadings readings - result is not valid." }
    $lines += @(
        "",
        $(if ($ageF -lt 0.999) { "Rating scale used, adjusted for PC age (full-charge life under this test, rough rule of thumb):" }
          else                 { "Rating scale (full-charge life under this test, rough rule of thumb):" }),
        "  $($scaled[0])h+ Excellent | $($scaled[1])-$($scaled[0])h Good | $($scaled[2])-$($scaled[1])h Average | $($scaled[3])-$($scaled[2])h Poor | under $($scaled[3])h Bad",
        $(if ($ageF -lt 0.999) { "  (new-laptop scale: 10h+ Excellent | 7-10h Good | 5-7h Average | 3-5h Poor | under 3h Bad)" } else { "" }),
        "Files: $log",
        "       $csv",
        "Before sharing this report: it includes your laptop model and open app names.",
        "================================================"
    )
    Out-Both ($lines -join "`r`n")
}

# ---------------------------------------------------------------- report from a saved CSV (-ReportFrom)
# Rebuilds the same variables the live test collects, then reuses Show-Report. No battery needed.
if ($ReportFrom) {
    if (-not (Test-Path -LiteralPath $ReportFrom -PathType Leaf)) { Write-Host "File not found: $ReportFrom"; exit 1 }
    $csv  = (Resolve-Path -LiteralPath $ReportFrom).Path
    $rows = @(Import-Csv -LiteralPath $csv)
    $need = @('Time', 'Minute', 'Charge')
    if ($rows.Count -lt 2 -or @($need | Where-Object { $rows[0].PSObject.Properties.Name -notcontains $_ }).Count -gt 0) {
        Write-Host "This does not look like a battery benchmark CSV with at least 2 readings (needs the columns: $($need -join ', '))."
        exit 1
    }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    try { foreach ($r in $rows) { [void][datetime]::ParseExact($r.Time, 'yyyy-MM-dd HH:mm:ss', $inv) } }
    catch { Write-Host "Could not read the Time column. Expected a format like 2026-11-23 09:15:00."; exit 1 }

    $first = $rows[0]; $last = $rows[$rows.Count - 1]
    $firstCharge = [int](ConvertTo-NumOrNull $first.Charge)
    $totalChg    = ConvertTo-NumOrNull $first.TotalChange
    $startCharge = if ($null -ne $totalChg) { $firstCharge + [int]$totalChg } else { $firstCharge }
    $startTime   = [datetime]::ParseExact($first.Time, 'yyyy-MM-dd HH:mm:ss', $inv).AddMinutes(-[double](ConvertTo-NumOrNull $first.Minute))

    $readings     = New-Object System.Collections.Generic.List[object]
    $powerSamples = New-Object System.Collections.Generic.List[double]
    $drops        = New-Object System.Collections.Generic.List[object]
    $appCount     = @{}
    $pluggedReadings = 0
    $lastCharge = $startCharge; $lastChange = $startTime; $firstDropDone = $false
    foreach ($r in $rows) {
        $t = [datetime]::ParseExact($r.Time, 'yyyy-MM-dd HH:mm:ss', $inv)
        $c = [int](ConvertTo-NumOrNull $r.Charge)
        if ($c -lt $lastCharge) {                      # same 1%-step timing as the live test
            $steps  = $lastCharge - $c
            $minPer = if ($firstDropDone) { ($t - $lastChange).TotalMinutes / $steps } else { $null }
            $drops.Add([pscustomobject]@{ Percent = $c; At = $t.ToString('HH:mm:ss'); MinPerPct = $minPer })
            $firstDropDone = $true; $lastChange = $t; $lastCharge = $c
        } elseif ($c -gt $lastCharge) { $lastCharge = $c }
        $pw = ConvertTo-NumOrNull $r.PowerW
        if ($null -ne $pw -and $pw -gt 0) { $powerSamples.Add($pw * 1000) }        # CSV is in W, the report works in mW
        $readings.Add([pscustomobject]@{ Charge = $c; Cpu = (ConvertTo-NumOrNull $r.CpuPercent); Bright = (ConvertTo-NumOrNull $r.BrightnessPercent) })
        if ("$($r.PluggedIn)" -eq 'True') { $pluggedReadings++ }
    }

    # Energy columns exist only in CSVs written by v1.2.0 or newer; take the last value present
    $lastVal = { param($col) $v = @($rows | ForEach-Object { ConvertTo-NumOrNull $_.$col } | Where-Object { $null -ne $_ }); if ($v.Count) { $v[$v.Count - 1] } else { $null } }
    $replayRemWh    = & $lastVal 'RemainingWh'
    $replayFullWh   = & $lastVal 'FullWh'
    $replayDesignWh = & $lastVal 'DesignWh'
    $replayEnd       = [datetime]::ParseExact($last.Time, 'yyyy-MM-dd HH:mm:ss', $inv)
    $replayEndCharge = [int](ConvertTo-NumOrNull $last.Charge)

    $replay     = $true
    $stopReason = "csv"
    $brightSet  = $false
    $cs         = [pscustomobject]@{ Manufacturer = "(not stored in CSV)"; Model = "" }
    $cpuName    = "N/A"; $osName = "N/A"
    $log = Join-Path (Split-Path $csv -Parent) ([IO.Path]::GetFileNameWithoutExtension($csv) + "_report.txt")
    if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log -Force }

    Show-Report
    exit 0
}

# ---------------------------------------------------------------- pre-flight
if ($Host.Name -ne 'ConsoleHost') {
    Write-Host "Run this in a normal PowerShell or Windows Terminal window (not ISE or an editor console)."
    exit 1
}
if (-not (Get-Batt)) {
    Write-Host "No battery found. This test only works on laptops and tablets that run on a battery."
    exit 1
}

Write-Host ""
Invoke-SettingsStep
Write-Host "============ BATTERY BENCHMARK v$ScriptVersion ============"
if (-not $NoWorkload) {
    if (-not $KeepApps) { Write-Host "First it asks to close your open apps (you can say no)." }
    Write-Host "Then it opens $(Get-WorkloadSummary)"
    Write-Host "and uses them like a person would (the mouse moves by itself, $($MouseActivity.ToLower()) activity)."
    Write-Host "DON'T use the laptop while it runs, or the result won't be comparable."
} else {
    Write-Host "Workload is OFF. Use the laptop however you like."
}
Write-Host "Stop any time with Ctrl+C (or Q). If you stop by accident you get"
Write-Host "20 seconds to press R and resume."
if ($StopAt -gt 0) { Write-Host "It will stop by itself when the battery reaches $StopAt%." }
else               { Write-Host "It will run until the battery is empty (the laptop will shut down)." }
if ($Minutes -gt 0) { Write-Host "Time limit: $Minutes minutes." }
Write-Host "==================================================="

while ((Get-Batt).Plugged) {
    [void](Read-Host "Charger is connected. Unplug it, then press Enter")
}

$startCharge = (Get-Batt).Charge
if ($null -eq $startCharge) {
    Write-Host "Could not read the battery level from Windows. Cannot run the test."
    exit 1
}
if ($StopAt -gt 0 -and $startCharge -le ($StopAt + 5)) {
    Write-Host "Battery is at $startCharge%, too low for a useful test. Charge it first (ideally to 100%)."
    exit 1
}

if (-not $NoWorkload -and -not $KeepApps) { Close-OtherApps }

$origBright = Get-Brightness
$brightSet  = $false
if (-not $NoWorkload -and $Brightness -gt 0) { $brightSet = Set-Brightness $Brightness }

$cs      = Get-CimInstance Win32_ComputerSystem
$cpuName = ((Get-CimInstance Win32_Processor | Select-Object -First 1).Name -replace '\s+', ' ').Trim()
$osName  = (Get-CimInstance Win32_OperatingSystem).Caption
$cap0    = Get-CapacityWh      # saved in the CSV too, so a report can be rebuilt later

$startTime    = Get-Date
$readings     = New-Object System.Collections.Generic.List[object]
$powerSamples = New-Object System.Collections.Generic.List[double]
$drops        = New-Object System.Collections.Generic.List[object]
$appCount     = @{}
$stop         = $false
$stopReason   = ""
$finished     = $false
$pluggedReadings = 0
$prevCharge   = $startCharge
$lastCharge   = $startCharge
$lastChange   = $startTime
$firstDropDone = $false
$tickNum      = 0

Out-Both "=== Battery test started $startTime at $startCharge% (script v$ScriptVersion) ==="
Out-Both "Laptop: $($cs.Manufacturer) $($cs.Model) | CPU: $cpuName | $osName"
Out-Both "Settings: brightness $Brightness% | stop at $StopAt% | time limit $Minutes min | mouse $MouseActivity | tab switch every $TabSwitchEvery | $(if ($NoWorkload) { 'no workload' } else { Get-WorkloadSummary })"

if (-not $NoWorkload) { Start-Workload }
$consolePid = Get-ConsoleWindowPid

# Keep Windows from sleeping AND keep the screen on for the whole test (in every mode),
# because a sleeping laptop or a dark screen would wreck the timing.
$awakeFlags = [uint32]2147483651     # ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED
[void][Native.Win]::SetThreadExecutionState($awakeFlags)

# Treat Ctrl+C as a normal key so a stop never kills the script before the report
[Console]::TreatControlCAsInput = $true

# ---------------------------------------------------------------- main loop: one line per minute
try {
    while (-not $finished) {
        $stop = $false
        $stopReason = ""

        while (-not $stop) {
            $cpuS = @(); $pwrS = @()

            for ($t = 0; $t -lt 4 -and -not $stop; $t++) {
                $tickStart = Get-Date
                $cpuS += (Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average
                $p = Get-Power
                if ($p -and $p.Rate -gt 0) { $pwrS += $p.Rate; $powerSamples.Add($p.Rate) }

                # watch every 1% step and time it
                $bat = Get-Batt
                $c   = $bat.Charge
                if ($null -eq $c) { $c = $lastCharge }     # a missed reading must not look like a drop
                if ($c -lt $lastCharge) {
                    $now   = Get-Date
                    $steps = $lastCharge - $c
                    $minPer = if ($firstDropDone) { ($now - $lastChange).TotalMinutes / $steps } else { $null }
                    $drops.Add([pscustomobject]@{ Percent = $c; At = $now.ToString('HH:mm:ss'); MinPerPct = $minPer })
                    if ($firstDropDone) { Out-Both ("      >> {0}% reached - that 1% took {1} min" -f $c, [math]::Round($minPer, 1)) }
                    else                { Out-Both ("      >> {0}% reached - timing of each 1% starts now" -f $c) }
                    $firstDropDone = $true
                    $lastChange    = $now
                    $lastCharge    = $c
                } elseif ($c -gt $lastCharge) {
                    $lastCharge = $c     # charging: ignore
                }

                # automatic stops
                if ($StopAt -gt 0 -and $c -le $StopAt) { $stop = $true; $stopReason = "level" }
                if ($Minutes -gt 0 -and ((Get-Date) - $startTime).TotalMinutes -ge $Minutes) { $stop = $true; $stopReason = "time" }

                if (-not $stop -and -not $NoWorkload) {
                    try { Invoke-UserAction $tickNum } catch { }
                    try { if ($consolePid) { [void]$wsh.AppActivate($consolePid) } } catch { }
                }
                $tickNum++

                # While waiting for the next 15-second step, keep the pointer wandering every 2-4 seconds
                $nextWander = (Get-Date).AddSeconds((Get-WanderDelay))
                while (-not $stop -and ((Get-Date) - $tickStart).TotalSeconds -lt 15) {
                    Start-Sleep -Milliseconds 500
                    if (Test-Stop) { $stop = $true; $stopReason = "user" }
                    if (-not $stop -and -not $NoWorkload -and (Get-Date) -ge $nextWander) {
                        try { Move-MouseWander } catch { }
                        $nextWander = (Get-Date).AddSeconds((Get-WanderDelay))
                    }
                }
            }
            if ($cpuS.Count -eq 0) { break }

            $cpuAvg  = [math]::Round(($cpuS | Measure-Object -Average).Average, 1)
            $charge  = $c
            if ($bat.Plugged) { $pluggedReadings++ }
            $bright  = Get-Brightness

            $appList = Get-Process | Where-Object { $_.MainWindowTitle } | Select-Object -ExpandProperty ProcessName -Unique
            foreach ($a in $appList) { $appCount[$a] = 1 + [int]$appCount[$a] }
            $readings.Add([pscustomobject]@{ Charge = $charge; Cpu = $cpuAvg; Bright = $bright })

            $minNow = [int][math]::Round(((Get-Date) - $startTime).TotalMinutes)
            $pwrW   = if ($pwrS.Count) { [math]::Round((($pwrS | Measure-Object -Average).Average) / 1000, 1) } else { $null }
            $pwrText = if ($null -ne $pwrW) { "$pwrW W" } else { "N/A" }

            # running estimate of time left, using the average power so far
            $leftText = "N/A"; $leftNum = $null
            $pNow = Get-Power
            if ($pNow -and $powerSamples.Count) {
                $avgSoFar = ($powerSamples | Measure-Object -Average).Average
                if ($avgSoFar -gt 0) { $leftNum = [math]::Round($pNow.Remaining / $avgSoFar, 2); $leftText = Format-Hours $leftNum }
            }

            $line = "[{0}] min {1,3} | Battery {2}% ({3} this min, {4} total) | Power {5} | CPU {6}% | Est. left {7}" -f (Get-Date -Format "HH:mm"), $minNow, $charge, (Format-Change ($prevCharge - $charge)), (Format-Change ($startCharge - $charge)), $pwrText, $cpuAvg, $leftText
            Out-Both $line

            $remWhCsv    = if ($pNow)                 { [math]::Round($pNow.Remaining / 1000, 2) } else { $null }
            $fullWhCsv   = if ($null -ne $cap0.Full)   { [math]::Round($cap0.Full, 2) }             else { $null }
            $designWhCsv = if ($null -ne $cap0.Design) { [math]::Round($cap0.Design, 2) }           else { $null }

            [pscustomobject]@{
                Time = (Get-Date -Format "yyyy-MM-dd HH:mm:ss"); Minute = $minNow; Charge = $charge
                ChangeThisMin = ($prevCharge - $charge); TotalChange = ($startCharge - $charge)
                PowerW = $pwrW; CpuPercent = $cpuAvg; BrightnessPercent = $bright
                PluggedIn = $bat.Plugged; EstLeftHours = $leftNum
                RemainingWh = $remWhCsv; FullWh = $fullWhCsv; DesignWh = $designWhCsv
            } | Export-Csv -Path $csv -Append -NoTypeInformation -Encoding UTF8

            $prevCharge = $charge
        }

        Show-Report

        if ($stopReason -eq "user") {
            try { if ($consolePid) { [void]$wsh.AppActivate($consolePid) } } catch { }
            Write-Host ""
            Write-Host "Stopped by accident?  Press R within 20 seconds to RESUME the test."
            Write-Host "Any other key (or waiting) finishes it."
            if (Read-ResumeChoice) {
                Out-Both "--- test resumed ---"
                continue
            }
        }
        $finished = $true
    }
}
finally {
    [Console]::TreatControlCAsInput = $false
    [void][Native.Win]::SetThreadExecutionState([uint32]2147483648)     # back to normal sleep rules
    if ($brightSet -and $null -ne $origBright) { [void](Set-Brightness $origBright) }
    if (-not $NoWorkload) { Stop-Workload }
}
