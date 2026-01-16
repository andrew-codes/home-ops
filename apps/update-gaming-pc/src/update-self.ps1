# Self-update script for Update-Gaming-PC
# Downloads the latest release and updates the scripts

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Load shared GitHub release functions
. (Join-Path $ScriptDir "github-release.ps1")

Write-Host "Checking for updates..."

# Download latest release artifact
$tmpDir = Get-ReleaseArtifact -WorkingDirectory $ScriptDir
if (-not $tmpDir) {
    Write-Error "Failed to download release artifact"
    exit 1
}

# Copy extracted files to script directory (overwrite existing)
Write-Host "Updating files..."
Get-ChildItem -Path $tmpDir -File | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination $ScriptDir -Force
}

# Clean up tmp directory
Remove-Item $tmpDir -Recurse -Force

Write-Host "Update complete."

# Run the main script if it exists
$runScript = Join-Path $ScriptDir "run.ps1"
if (Test-Path $runScript) {
    Write-Host "Executing run.ps1..."
    & $runScript
}
