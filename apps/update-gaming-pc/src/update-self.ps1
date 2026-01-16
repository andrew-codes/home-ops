# Self-update script for Update-Gaming-PC
# Downloads the latest release and updates the scripts

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Load shared modules
. (Join-Path $ScriptDir "logging.ps1")
. (Join-Path $ScriptDir "github-release.ps1")

Write-Log "Checking for updates..."

# Download latest release artifact
$tmpDir = Get-ReleaseArtifact -WorkingDirectory $ScriptDir
if (-not $tmpDir) {
    Write-Log "Failed to download release artifact"
    exit 1
}

# Copy extracted files to script directory (overwrite existing)
Write-Log "Updating files..."
Get-ChildItem -Path $tmpDir -File | ForEach-Object {
    Write-Log "  Copying $($_.Name)"
    Copy-Item -Path $_.FullName -Destination $ScriptDir -Force
}

# Clean up tmp directory
Remove-Item $tmpDir -Recurse -Force

Write-Log "Update complete."

# Run the main script if it exists
$runScript = Join-Path $ScriptDir "run.ps1"
if (Test-Path $runScript) {
    Write-Log "Executing run.ps1..."
    & $runScript
}
