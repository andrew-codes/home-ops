# Tests for src/fps-summary.ps1. Run with:
#   pwsh -NoProfile -File apps/gaming-pc/tests/fps-summary.test.ps1
# Plain assertions, no Pester, so the only thing it needs is PowerShell 7. It
# feeds the summariser PresentMon-shaped CSV from a StringReader with a fake
# clock, so windows are deterministic and no PresentMon or Windows is involved.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'src' 'fps-summary.ps1')

$script:Failures = 0
function Assert-Equal {
    param($Expected, $Actual, [string]$What)
    if ($Expected -ne $Actual) {
        Write-Host "FAIL $What`n  expected: $Expected`n  actual:   $Actual"
        $script:Failures++
    }
    else {
        Write-Host "ok   $What"
    }
}

function Get-Sample {
    # The value of one series from a window's Prometheus text, or $null.
    param([string]$Text, [string]$Metric)
    foreach ($line in $Text -split "`n") {
        if ($line -match "^$Metric\{app=`"((?:[^`"\\]|\\.)*)`"\} (\S+)$") {
            return @{ App = $Matches[1]; Value = $Matches[2] }
        }
    }
    return $null
}

# Runs the summariser over the given lines. Every clock read advances time by
# TickMs, and the loop reads the clock once per line, so one line is TickMs.
function Invoke-Run {
    param([string[]]$Lines, [int]$WindowSeconds = 1, [int]$TickMs = 10, [double]$MinFps = 15)

    $script:clock = 0
    $script:windows = [Collections.Generic.List[string]]::new()
    $out = Join-Path ([IO.Path]::GetTempPath()) ("fps-test-{0}.prom" -f [guid]::NewGuid())
    try {
        Invoke-FpsSummariser -Reader ([IO.StringReader]::new(($Lines -join "`n") + "`n")) `
            -OutputPath $out -WindowSeconds $WindowSeconds -MinFps $MinFps `
            -Now { $script:clock += $TickMs; $script:clock } `
            -OnWindow { param($Text) $script:windows.Add($Text) }
        $file = if (Test-Path -LiteralPath $out) { [IO.File]::ReadAllText($out) } else { '<missing>' }
        return @{ Windows = $script:windows; File = $file }
    }
    finally {
        Remove-Item -LiteralPath $out, "$out.tmp" -Force -ErrorAction SilentlyContinue
    }
}

$header = 'Application,ProcessID,SwapChainAddress,PresentRuntime,SyncInterval,PresentFlags,AllowsTearing,PresentMode,FrameType,CPUStartTime,MsBetweenPresents'
function New-Row { param($App, $Ms) "$App,1,0x1,DXGI,0,0,0,Hardware: Independent Flip,Application,0,$Ms" }

# 100 lines per 1 s window (10 ms of fake clock each). A game presents 90 of
# every 100 lines at 10 ms; dwm.exe fills the rest.
$game = 'Game.exe'
$lines = @($header)
for ($i = 0; $i -lt 300; $i++) {
    if ($i % 10 -eq 0) { $lines += New-Row 'dwm.exe' '16.667' } else { $lines += New-Row $game '10.000' }
}
# One 40 ms hitch in the second window.
$lines[150] = New-Row $game '40.000'

$result = Invoke-Run -Lines $lines
Assert-Equal 3 $result.Windows.Count 'three one-second windows over 300 lines'

$first = $result.Windows[0]
$avg = Get-Sample $first 'gaming_pc_fps_average'
Assert-Equal $game $avg.App 'the presenting game is the active app, not dwm.exe'
Assert-Equal 'Game.exe' (Get-Sample $first 'gaming_pc_active_app_info').App 'active_app_info carries the app label'
Assert-Equal '1' (Get-Sample $first 'gaming_pc_active_app_info').Value 'active_app_info is 1'
# The header line is read before the first row and costs one tick of the fake
# clock, so the first window holds 99 rows, nine of them from dwm.exe.
Assert-Equal '89.00' $avg.Value 'average FPS is frames per second of the window (first window)'
Assert-Equal '10.000' (Get-Sample $first 'gaming_pc_frametime_p99_milliseconds').Value 'p99 of identical frames'
Assert-Equal '100.00' (Get-Sample $first 'gaming_pc_fps_1pct_low').Value '1% low of identical 10 ms frames is 100 FPS'

$second = $result.Windows[1]
Assert-Equal '40.000' (Get-Sample $second 'gaming_pc_frametime_max_milliseconds').Value 'the hitch shows in the window max'
$counter = (Get-Sample $first 'gaming_pc_frames_total').Value + ' ' + (Get-Sample $second 'gaming_pc_frames_total').Value
Assert-Equal '89 179' $counter 'frames_total is cumulative across windows'

# No game: only an ignored process and a slow app below the minimum FPS.
$idle = @($header)
for ($i = 0; $i -lt 200; $i++) { $idle += New-Row 'dwm.exe' '16.667' }
for ($i = 0; $i -lt 3; $i++) { $idle += New-Row 'Slow.exe' '500' }
$result = Invoke-Run -Lines $idle
Assert-Equal 2 $result.Windows.Count 'two windows over 200+ idle lines'
Assert-Equal '' $result.Windows[0] 'a window with no game is empty text'
Assert-Equal '' $result.File 'the textfile is empty (and exists) when no game is running'

# Browsers are ignored even when they present the most frames.
$browser = @($header)
for ($i = 0; $i -lt 100; $i++) { $browser += New-Row 'chrome.exe' '16.667' }
$result = Invoke-Run -Lines $browser
Assert-Equal '' $result.Windows[0] 'chrome.exe is never the active app'

# Noise: PresentMon messages, a repeated header, short rows and unparsable times.
$noisy = @('PresentMon 2.6.0', $header)
for ($i = 0; $i -lt 98; $i++) {
    $noisy += New-Row $game '10.000'
    if ($i -eq 10) { $noisy += 'warning: something'; $noisy += $header; $noisy += 'Game.exe,1'; $noisy += (New-Row $game 'NA') }
}
$result = Invoke-Run -Lines $noisy
$sample = Get-Sample $result.Windows[0] 'gaming_pc_fps_average'
Assert-Equal $game $sample.App 'noise lines do not stop the summariser'

# Label escaping.
$escaped = @($header)
for ($i = 0; $i -lt 100; $i++) { $escaped += New-Row 'we"ird\name.exe' '10.000' }
$result = Invoke-Run -Lines $escaped
Assert-Equal 'we\"ird\\name.exe' (Get-Sample $result.Windows[0] 'gaming_pc_active_app_info').App 'quotes and backslashes are escaped in the app label'

# A stream without the frame time column is an error the exporter can restart on.
$threw = $false
try { Invoke-Run -Lines @('Application,ProcessID', 'a,1') | Out-Null } catch { $threw = $true }
Assert-Equal $true $threw 'a header with no MsBetweenPresents throws'

# The exposition format: every sample line is name{labels} value, nothing else
# but comments, and the file ends with a line feed (the textfile collector
# rejects a file that does not).
$result = Invoke-Run -Lines $lines
$text = $result.Windows[0]
$bad = @($text -split "`n" | Where-Object { $_ -ne '' -and $_ -notmatch '^(#.*|[a-z0-9_]+\{app="[^"]*"\} [0-9.]+)$' })
Assert-Equal 0 $bad.Count 'every line is a comment or a well-formed sample'
Assert-Equal $true $text.EndsWith("`n") 'the text ends with a line feed'

if ($script:Failures -gt 0) {
    Write-Host "`n$script:Failures failure(s)"
    exit 1
}
Write-Host "`nall passed"
