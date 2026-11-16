# Frame statistics for the PresentMon stream, written as Prometheus text for the
# windows_exporter textfile collector. Dot-sourced by fps-exporter.ps1 and by
# tests/fps-summary.test.ps1; it does nothing on its own.
#
# PresentMon prints one CSV row per presented frame for every process that
# presents, so the per-line work is the only cost that scales with frame rate.
# Invoke-FpsSummariser therefore keeps that work to a split, a name check and a
# list append, and does every sort and format once per window.

# Processes that present frames all day but are never "the game". PresentMon is
# told to skip them (see fps-exporter.ps1) and the summariser skips them again,
# so a PresentMon that ignores --exclude still cannot name a browser as the game.
$script:FpsIgnoredApplications = @(
    'dwm.exe'
    'explorer.exe'
    'ApplicationFrameHost.exe'
    'SearchHost.exe'
    'ShellExperienceHost.exe'
    'StartMenuExperienceHost.exe'
    'TextInputHost.exe'
    'LockApp.exe'
    'chrome.exe'
    'msedge.exe'
    'firefox.exe'
    'steamwebhelper.exe'
    '1Password.exe'
)

function ConvertTo-PromLabelValue {
    <#
    .SYNOPSIS
        Escapes a string for use inside a Prometheus label value.
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    return $Value.Replace('\', '\\').Replace('"', '\"').Replace("`r", '').Replace("`n", '\n')
}

function Get-FpsPercentile {
    <#
    .SYNOPSIS
        Value at a percentile of an ascending-sorted array (nearest rank, floored).
    #>
    param(
        [Parameter(Mandatory = $true)][double[]]$Sorted,
        [Parameter(Mandatory = $true)][double]$Percent
    )

    $index = [Math]::Min($Sorted.Length - 1, [int][Math]::Floor($Percent / 100.0 * $Sorted.Length))
    return $Sorted[$index]
}

function Format-FpsWindow {
    <#
    .SYNOPSIS
        Turns one window of frame times into Prometheus text.
    .DESCRIPTION
        Picks the application that presented the most frames, provided it ran at
        or above MinFps for the window; that is "the current application".
        Returns an empty string when nothing qualifies, which is what makes the
        series disappear when no game is running instead of freezing at the
        last game's numbers.
    .PARAMETER Frames
        Dictionary of application name to the frame times (ms) it presented.
    .PARAMETER Totals
        Dictionary of application name to frames presented since the summariser
        started. Updated here, because it backs the frames_total counter.
    #>
    param(
        [Parameter(Mandatory = $true)]$Frames,
        [Parameter(Mandatory = $true)]$Totals,
        [Parameter(Mandatory = $true)][double]$ElapsedSeconds,
        [Parameter(Mandatory = $true)][double]$MinFps
    )

    if ($ElapsedSeconds -le 0) {
        return ''
    }

    $app = $null
    $best = 0
    foreach ($entry in $Frames.GetEnumerator()) {
        $count = $entry.Value.Count
        if ($count -gt $best -and ($count / $ElapsedSeconds) -ge $MinFps) {
            $app = $entry.Key
            $best = $count
        }
    }
    if ($null -eq $app) {
        return ''
    }

    $times = $Frames[$app].ToArray()
    [Array]::Sort($times)
    $sum = 0.0
    foreach ($time in $times) { $sum += $time }

    $p99 = Get-FpsPercentile -Sorted $times -Percent 99
    $max = $times[$times.Length - 1]
    $average = $times.Length / $ElapsedSeconds
    $low = if ($p99 -gt 0) { 1000.0 / $p99 } else { 0.0 }

    if ($Totals.ContainsKey($app)) { $Totals[$app] += $times.Length } else { $Totals[$app] = [long]$times.Length }

    $label = 'app="{0}"' -f (ConvertTo-PromLabelValue $app)
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $lines = @(
        '# HELP gaming_pc_fps_average Frames presented per second by the current application, averaged over the last window.'
        '# TYPE gaming_pc_fps_average gauge'
        'gaming_pc_fps_average{0} {1}' -f "{$label}", $average.ToString('0.00', $inv)
        '# HELP gaming_pc_fps_1pct_low Frames per second at the 99th percentile frame time (the 1% low) over the last window.'
        '# TYPE gaming_pc_fps_1pct_low gauge'
        'gaming_pc_fps_1pct_low{0} {1}' -f "{$label}", $low.ToString('0.00', $inv)
        '# HELP gaming_pc_frametime_p99_milliseconds 99th percentile time between presents over the last window.'
        '# TYPE gaming_pc_frametime_p99_milliseconds gauge'
        'gaming_pc_frametime_p99_milliseconds{0} {1}' -f "{$label}", $p99.ToString('0.000', $inv)
        '# HELP gaming_pc_frametime_max_milliseconds Longest time between presents over the last window.'
        '# TYPE gaming_pc_frametime_max_milliseconds gauge'
        'gaming_pc_frametime_max_milliseconds{0} {1}' -f "{$label}", $max.ToString('0.000', $inv)
        '# HELP gaming_pc_frames_total Frames presented by the application since the summariser started.'
        '# TYPE gaming_pc_frames_total counter'
        'gaming_pc_frames_total{0} {1}' -f "{$label}", $Totals[$app]
        '# HELP gaming_pc_active_app_info The application currently presenting frames. The value is always 1.'
        '# TYPE gaming_pc_active_app_info gauge'
        'gaming_pc_active_app_info{0} 1' -f "{$label}"
    )
    return ($lines -join "`n") + "`n"
}

function Write-FpsTextfile {
    <#
    .SYNOPSIS
        Replaces the textfile collector's input atomically.
    .DESCRIPTION
        Writes a sibling temporary file and renames it over the target, so the
        collector never reads a half-written file. The temporary name does not
        end in .prom, so the collector never reads it either. A rename can fail
        while the collector has the target open; it is retried briefly, and a
        failure is returned rather than thrown because the next window writes
        the file again.
    .OUTPUTS
        $true when the file was replaced, otherwise $false.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    $temporary = "$Path.tmp"
    [IO.File]::WriteAllText($temporary, $Content, [Text.UTF8Encoding]::new($false))
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            [IO.File]::Move($temporary, $Path, $true)
            return $true
        }
        catch [IO.IOException] {
            Start-Sleep -Milliseconds 100
        }
    }
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    return $false
}

function Invoke-FpsSummariser {
    <#
    .SYNOPSIS
        Reads PresentMon CSV from a reader and writes one summary per window.
    .DESCRIPTION
        Returns when the reader reaches the end of the stream. Lines that are not
        CSV rows of the expected width (PresentMon's own messages, a header that
        repeats) are skipped. A reader that produces nothing for a while still
        gets its window flushed, because an idle desktop presents no frames and
        the file has to be emptied then too.
    .PARAMETER Reader
        PresentMon's standard output, or a StringReader in the tests.
    .PARAMETER ErrorReader
        Optional. PresentMon's standard error; lines go to OnError.
    .PARAMETER Now
        Milliseconds clock. Replaced in the tests so windows are deterministic.
    .PARAMETER OnWindow
        Called with the text of each window after it is written.
    #>
    param(
        [Parameter(Mandatory = $true)][IO.TextReader]$Reader,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [int]$WindowSeconds = 30,
        [double]$MinFps = 15,
        [IO.TextReader]$ErrorReader,
        [scriptblock]$OnError = { param($Message) },
        [scriptblock]$OnWindow = { param($Text) },
        [scriptblock]$Now = { [Environment]::TickCount64 }
    )

    $inv = [Globalization.CultureInfo]::InvariantCulture
    $ignored = [Collections.Generic.HashSet[string]]::new(
        [string[]]$script:FpsIgnoredApplications, [StringComparer]::OrdinalIgnoreCase)
    $frames = [Collections.Generic.Dictionary[string, Collections.Generic.List[double]]]::new()
    $totals = [Collections.Generic.Dictionary[string, long]]::new()
    $windowMs = $WindowSeconds * 1000

    $appIndex = -1
    $timeIndex = -1
    $width = 0
    $windowStart = & $Now
    $lineTask = $Reader.ReadLineAsync()
    $errorTask = if ($ErrorReader) { $ErrorReader.ReadLineAsync() } else { $null }

    while ($true) {
        # A short wait, so an idle stream still reaches the flush below.
        if ($lineTask.Wait(1000)) {
            $line = $lineTask.Result
            if ($null -eq $line) {
                break
            }
            $lineTask = $Reader.ReadLineAsync()

            if ($appIndex -lt 0) {
                if ($line.StartsWith('Application,', [StringComparison]::OrdinalIgnoreCase)) {
                    $columns = $line.Split(',')
                    $width = $columns.Length
                    for ($i = 0; $i -lt $columns.Length; $i++) {
                        if ($columns[$i] -ieq 'Application') { $appIndex = $i }
                        elseif ($columns[$i] -ieq 'MsBetweenPresents') { $timeIndex = $i }
                    }
                    if ($timeIndex -lt 0) {
                        throw 'PresentMon wrote no MsBetweenPresents column.'
                    }
                }
            }
            else {
                $fields = $line.Split(',')
                if ($fields.Length -eq $width) {
                    $app = $fields[$appIndex]
                    $ms = 0.0
                    if (-not $ignored.Contains($app) -and
                        [double]::TryParse($fields[$timeIndex], [Globalization.NumberStyles]::Float, $inv, [ref]$ms)) {
                        $list = $null
                        if (-not $frames.TryGetValue($app, [ref]$list)) {
                            $list = [Collections.Generic.List[double]]::new()
                            $frames[$app] = $list
                        }
                        $list.Add($ms)
                    }
                }
            }
        }

        if ($errorTask -and $errorTask.IsCompleted) {
            $message = $errorTask.Result
            if ($null -ne $message) {
                & $OnError $message
                $errorTask = $ErrorReader.ReadLineAsync()
            }
            else {
                $errorTask = $null
            }
        }

        # PowerShell variable names are case-insensitive, so this cannot be $now.
        $tick = & $Now
        if ($tick - $windowStart -ge $windowMs) {
            $text = Format-FpsWindow -Frames $frames -Totals $totals `
                -ElapsedSeconds (($tick - $windowStart) / 1000.0) -MinFps $MinFps
            [void](Write-FpsTextfile -Path $OutputPath -Content $text)
            & $OnWindow $text
            $frames.Clear()
            $windowStart = $tick
        }
    }
}
