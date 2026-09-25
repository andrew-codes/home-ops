# Starts DXL (DLSS eXtended Loader) if it is not already running, minimizing
# its window once one appears. Safe to run manually, from the Start-DXL
# scheduled task (Windows startup), or from Update-DXL after installing a new
# version - it no-ops rather than double-launching when DXL is already up.

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path $ScriptDir "logging.ps1")

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class DxlWindow {
    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
}
"@

$SW_MINIMIZE = 6
$DxlDir = Join-Path $ScriptDir "dxl"
$DxlExe = Join-Path $DxlDir "DXL.exe"

$existing = Get-Process -Name "DXL" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($existing) {
    Write-Log "DXL is already running (PID $($existing.Id)); not starting a second copy."
    exit 0
}

if (-not (Test-Path $DxlExe)) {
    Write-Log "DXL.exe not found at $DxlExe; nothing to start."
    exit 1
}

Write-Log "Starting DXL..."
$process = Start-Process -FilePath $DxlExe -WorkingDirectory $DxlDir -PassThru

# The main window is not necessarily created the instant the process starts,
# so poll briefly rather than assuming MainWindowHandle is already populated.
$deadline = (Get-Date).AddSeconds(15)
$handle = [IntPtr]::Zero
while ((Get-Date) -lt $deadline) {
    $process.Refresh()
    if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
        $handle = $process.MainWindowHandle
        break
    }
    Start-Sleep -Milliseconds 250
}

if ($handle -ne [IntPtr]::Zero) {
    [DxlWindow]::ShowWindowAsync($handle, $SW_MINIMIZE) | Out-Null
    Write-Log "DXL started (PID $($process.Id)) and minimized."
}
else {
    Write-Log "DXL started (PID $($process.Id)) but no window appeared within 15s to minimize."
}
