# DXL (DLSS eXtended Loader, https://github.com/LCPD15/DXL) install/update logic.
#
# Not built on github-release.ps1: that module hardcodes this repo's own
# update-gaming-pc.zip artifact and tag-prefix filtering, which doesn't
# transfer to DXL's release shape. DXL's releases publish DXL-v<version>-win64.zip
# (plus a source zip and .sha256 checksums for both) with a single
# version-named top-level folder in the zip root, confirmed by downloading and
# extracting a real release (v0.7) rather than assumed - see AGENTS.md.
#
# Idempotency compares the installed PACKAGE_MANIFEST.json's "Version" field
# (which DXL's own release already ships) against the latest release tag, the
# same version-compare-before-download shape as MoonDeck Buddy and the NVIDIA
# driver in software.ps1/run.ps1 - no separate marker file needed.

$script:DxlRepo = "LCPD15/DXL"
$script:DxlProcessName = "DXL"
$script:DxlStartTaskName = "Start-DXL"

function Get-DxlInstalledVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DxlDir
    )

    $manifestPath = Join-Path $DxlDir "PACKAGE_MANIFEST.json"
    if (-not (Test-Path $manifestPath)) {
        return $null
    }

    try {
        $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
        return $manifest.Version
    }
    catch {
        Write-Log "Failed to read installed DXL version from $manifestPath : $($_.Exception.Message)"
        return $null
    }
}

function Get-LatestDxlRelease {
    <#
    .SYNOPSIS
        Finds the latest DXL release and its Windows x64 zip asset.
    .OUTPUTS
        A hashtable with Version, Tag and ArtifactUrl, or $null on failure.
    #>
    $apiUrl = "https://api.github.com/repos/$script:DxlRepo/releases/latest"
    try {
        $release = Invoke-RestMethod -Uri $apiUrl -Headers @{ "User-Agent" = "home-ops-gaming-pc" }
    }
    catch {
        Write-Log "Failed to fetch the latest DXL release: $($_.Exception.Message)"
        return $null
    }

    # The win64 zip is the app itself; releases also carry a *-source.zip and
    # a .sha256 file per zip, which this pattern excludes.
    $asset = $release.assets | Where-Object { $_.name -match '-win64\.zip$' } | Select-Object -First 1
    if (-not $asset) {
        Write-Log "The latest DXL release ($($release.tag_name)) has no *-win64.zip asset."
        return $null
    }

    return @{
        Version     = $release.tag_name.TrimStart('v')
        Tag         = $release.tag_name
        ArtifactUrl = $asset.browser_download_url
    }
}

function Expand-DxlArchive {
    <#
    .SYNOPSIS
        Extracts a DXL release zip into $Destination, flattening the single
        version-named top-level folder the real release shape carries so the
        destination directory contains the application files directly.
    .DESCRIPTION
        Only flattens when the archive root is in fact exactly one directory;
        an archive that ever ships files at the zip root instead lands as-is
        rather than assuming the nested shape blindly.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ZipPath,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    $stagingDir = Join-Path ([System.IO.Path]::GetTempPath()) "dxl-extract-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $stagingDir | Out-Null

    try {
        Expand-Archive -Path $ZipPath -DestinationPath $stagingDir -Force

        $topLevelEntries = @(Get-ChildItem -Path $stagingDir)
        $sourceDir = if ($topLevelEntries.Count -eq 1 -and $topLevelEntries[0].PSIsContainer) {
            $topLevelEntries[0].FullName
        }
        else {
            $stagingDir
        }

        if (Test-Path $Destination) {
            Remove-Item $Destination -Recurse -Force
        }
        New-Item -ItemType Directory -Path $Destination | Out-Null

        Get-ChildItem -Path $sourceDir | ForEach-Object {
            Move-Item -Path $_.FullName -Destination $Destination
        }
    }
    finally {
        Remove-Item $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Stop-DxlProcess {
    Get-Process -Name $script:DxlProcessName -ErrorAction SilentlyContinue | Stop-Process -Force
}

function Start-DxlAfterUpdate {
    <#
    .SYNOPSIS
        Restarts DXL after an update by way of the Start-DXL scheduled task.
    .DESCRIPTION
        Update-DXL runs from run.ps1 under the nightly Update-Gaming-PC task,
        which executes as SYSTEM in session 0 - a process it starts directly
        cannot show a window or reach the logged-in user's desktop, and DXL is
        a GUI app that injects into games running in that user's session.
        Start-ScheduledTask hands the actual launch to Start-DXL, which is
        already registered (by install.ps1) to run in the interactive user's
        own session, and start-dxl.ps1 additionally no-ops instead of double-
        launching if DXL is somehow already running.
    #>
    try {
        Start-ScheduledTask -TaskName $script:DxlStartTaskName -ErrorAction Stop
    }
    catch {
        Write-Log "Could not start the '$script:DxlStartTaskName' task ($($_.Exception.Message)); install.ps1 may not have run yet."
    }
}

function Update-DXL {
    <#
    .SYNOPSIS
        Ensures the latest DXL release is installed to $DxlDir, stopping and
        restarting the running process across the update. No-ops when already
        on the latest version.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$DxlDir
    )

    Write-Log "Checking for DXL updates..."

    $latest = Get-LatestDxlRelease
    if (-not $latest) {
        throw "Could not determine the latest DXL release."
    }

    $installedVersion = Get-DxlInstalledVersion -DxlDir $DxlDir
    if ($installedVersion -eq $latest.Version) {
        Write-Log "DXL is already on the latest version ($installedVersion). No update needed."
        return
    }

    if ($installedVersion) {
        Write-Log "DXL $installedVersion installed, $($latest.Version) available; updating..."
    }
    else {
        Write-Log "DXL not installed; installing $($latest.Version)..."
    }

    $downloadDir = Join-Path $env:TEMP "dxl-download"
    New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
    $zipPath = Join-Path $downloadDir "DXL-$($latest.Tag)-win64.zip"

    try {
        Invoke-WebRequest -Uri $latest.ArtifactUrl -OutFile $zipPath -Headers @{ "User-Agent" = "home-ops-gaming-pc" }

        Write-Log "Stopping DXL if it is running..."
        Stop-DxlProcess

        Write-Log "Extracting DXL to $DxlDir..."
        Expand-DxlArchive -ZipPath $zipPath -Destination $DxlDir
    }
    finally {
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    }

    Write-Log "Restarting DXL..."
    Start-DxlAfterUpdate

    Write-Log "DXL updated to $($latest.Version)."
}
