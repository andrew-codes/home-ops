# Install script to create/update the Update-Gaming-PC scheduled task
# Automatically elevates to administrator if needed

$TaskName = "Update-Gaming-PC"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ScriptPath = Join-Path $ScriptDir "update-self.ps1"

# Load shared modules
. (Join-Path $ScriptDir "logging.ps1")
. (Join-Path $ScriptDir "github-release.ps1")

# Check if running as administrator, elevate if not
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Log "Elevating to administrator..."
    $scriptFullPath = $MyInvocation.MyCommand.Definition
    Start-Process pwsh.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptFullPath`""
    exit 0
}

# Download latest release artifact
Write-Log "Fetching latest release from GitHub..."
$tmpDir = Get-ReleaseArtifact -WorkingDirectory $ScriptDir
if (-not $tmpDir) {
    Write-Log "Failed to download release artifact"
    exit 1
}

# Check if the target script exists in the extracted files
$extractedScript = Join-Path $tmpDir "update-self.ps1"
if (-not (Test-Path $extractedScript)) {
    Write-Log "Cannot find update-self.ps1 in downloaded release"
    exit 1
}

# Copy extracted files to script directory (overwrite existing)
Write-Log "Installing files..."
Get-ChildItem -Path $tmpDir -File | ForEach-Object {
    Write-Log "  Copying $($_.Name)"
    Copy-Item -Path $_.FullName -Destination $ScriptDir -Force
}

# Clean up tmp directory
Remove-Item $tmpDir -Recurse -Force

# Remove existing task if it exists
$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existingTask) {
    Write-Log "Removing existing task '$TaskName'..."
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

# Create the action - run pwsh with the script, working directory set to script location
$Action = New-ScheduledTaskAction `
    -Execute "pwsh.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`"" `
    -WorkingDirectory $ScriptDir

# Create the trigger - daily at midnight, wake to run
$Trigger = New-ScheduledTaskTrigger -Daily -At "00:00"

# Create settings - wake to run, run whether user is logged on or not
$Settings = New-ScheduledTaskSettingsSet `
    -WakeToRun `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RunOnlyIfNetworkAvailable

# Create the principal - run with highest privileges
$Principal = New-ScheduledTaskPrincipal `
    -UserId "SYSTEM" `
    -LogonType ServiceAccount `
    -RunLevel Highest

# Register the scheduled task
$Task = New-ScheduledTask -Action $Action -Trigger $Trigger -Settings $Settings -Principal $Principal

Register-ScheduledTask -TaskName $TaskName -InputObject $Task | Out-Null

# Verify the task was created
$createdTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($createdTask) {
    Write-Log "Successfully created scheduled task '$TaskName'"
    Write-Log "  Schedule: Daily at midnight"
    Write-Log "  Wake to run: Enabled"
    Write-Log "  Script: $ScriptPath"
    Write-Log "  Working Directory: $ScriptDir"
}
else {
    Write-Log "Failed to create scheduled task"
    exit 1
}
