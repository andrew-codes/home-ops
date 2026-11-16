# Runs PresentMon for as long as the machine is up and keeps a Prometheus
# textfile current with the frame rate of whatever game is running.
#
# Started at boot by the Gaming-PC-FPS scheduled task (monitoring.ps1) as
# SYSTEM, which is what gives it an ETW trace session without elevation prompts.
# Starting at boot rather than per game matters: an anti-cheat can refuse a new
# ETW trace session once it is running (PresentMon issue 573, EA AntiCheat), but
# a session that already exists keeps working.
#
# PresentMon only traces ETW present events. It does not inject into or hook any
# game. The work in this script is parsing one CSV line per presented frame, see
# fps-summary.ps1.
param(
    [Parameter(Mandatory = $true)]
    [string]$PresentMonPath,

    # The windows_exporter textfile directory; windows_exporter reads *.prom here.
    [Parameter(Mandatory = $true)]
    [string]$TextfileDirectory,

    [int]$WindowSeconds = 30,

    # An application below this frame rate over a window is not "the game".
    [double]$MinFps = 15
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'fps-summary.ps1')

$outputPath = Join-Path $TextfileDirectory 'gaming-pc-fps.prom'
$logPath = Join-Path $TextfileDirectory '..\fps-exporter.log'

function Write-FpsLog {
    param([string]$Message)

    # Kept small: a PresentMon that fails in a loop would otherwise fill the disk.
    if ((Test-Path -LiteralPath $logPath) -and (Get-Item -LiteralPath $logPath).Length -gt 1MB) {
        Move-Item -LiteralPath $logPath -Destination "$logPath.old" -Force
    }
    Add-Content -LiteralPath $logPath -Value ('{0:u} {1}' -f (Get-Date), $Message)
}

# Frame time is the cheapest thing PresentMon can report, so everything else is
# switched off: display tracking, GPU duration tracking and input tracking each
# add ETW providers and per-frame work this script never reads.
$presentMonArguments = @(
    '--output_stdout'
    '--no_console_stats'
    '--no_track_input'
    '--no_track_gpu'
    '--no_track_display'
    # A trace session left by a killed PresentMon would otherwise block this one.
    '--stop_existing_session'
    '--session_name'
    'GamingPcFps'
)
foreach ($application in $script:FpsIgnoredApplications) {
    $presentMonArguments += @('--exclude', $application)
}

# Neither the trace nor this parser should ever compete with a game for a core.
(Get-Process -Id $PID).PriorityClass = 'BelowNormal'

$delaySeconds = 5
while ($true) {
    # No game while PresentMon is down, so the series must not say otherwise.
    [void](Write-FpsTextfile -Path $outputPath -Content '')

    $startInfo = [Diagnostics.ProcessStartInfo]::new($PresentMonPath)
    foreach ($argument in $presentMonArguments) { $startInfo.ArgumentList.Add($argument) }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8

    $startedAt = Get-Date
    $process = [Diagnostics.Process]::Start($startInfo)
    try {
        $process.PriorityClass = 'BelowNormal'
        Write-FpsLog "PresentMon started (pid $($process.Id))"
        Invoke-FpsSummariser -Reader $process.StandardOutput -ErrorReader $process.StandardError `
            -OutputPath $outputPath -WindowSeconds $WindowSeconds -MinFps $MinFps `
            -OnError { param($Message) Write-FpsLog "PresentMon: $Message" }
        Write-FpsLog 'PresentMon closed its output'
    }
    catch {
        Write-FpsLog "Summariser failed: $($_.Exception.Message)"
    }
    finally {
        if (-not $process.HasExited) {
            $process.Kill($true)
        }
        $process.WaitForExit()
        Write-FpsLog "PresentMon exited with code $($process.ExitCode)"
        $process.Dispose()
    }

    # Back off when PresentMon dies straight away (a missing driver feature, a
    # blocked trace session), reset once a run lasted a minute.
    if (((Get-Date) - $startedAt).TotalSeconds -gt 60) { $delaySeconds = 5 }
    else { $delaySeconds = [Math]::Min($delaySeconds * 2, 300) }
    Start-Sleep -Seconds $delaySeconds
}
