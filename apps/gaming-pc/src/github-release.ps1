# Shared functions for downloading GitHub release artifacts

$script:GitHubRepo = "andrew-codes/home-ops"
$script:ArtifactName = "update-gaming-pc.zip"

function Get-LatestReleaseWithArtifact {
    <#
    .SYNOPSIS
        Finds the latest GitHub release that contains the specified artifact.
        Tags are formatted as update-gaming-pc-YYYYMMDD-HHMMSS-SHA so alphabetical sorting = chronological.
        Returns the first matching release since GitHub returns them sorted alphabetically (newest first).
    .OUTPUTS
        Returns a hashtable with 'tag', 'releaseUrl', and 'artifactUrl' or $null if not found.
    #>
    param(
        [int]$MaxPages = 10
    )

    $apiBase = "https://api.github.com/repos/$script:GitHubRepo/releases"
    $page = 1

    while ($page -le $MaxPages) {
        $url = "$apiBase`?page=$page&per_page=100"
        Write-Log "Fetching releases page $page..."
        try {
            $releases = Invoke-RestMethod -Uri $url -Headers @{ "User-Agent" = "PowerShell" }
        }
        catch {
            Write-Log "Failed to fetch releases from GitHub: $_"
            return $null
        }

        if ($releases.Count -eq 0) {
            break
        }

        foreach ($release in $releases) {
            # Only consider releases with our tag prefix
            if ($release.tag_name -notlike "update-gaming-pc-*") {
                continue
            }

            $artifact = $release.assets | Where-Object { $_.name -eq $script:ArtifactName }
            if ($artifact) {
                Write-Log "Found latest release: $($release.tag_name)"
                return @{
                    Tag         = $release.tag_name
                    ReleaseUrl  = $release.html_url
                    ArtifactUrl = $artifact.browser_download_url
                }
            }
        }

        $page++
    }

    Write-Log "No release found with artifact '$script:ArtifactName'"
    return $null
}

function Get-ReleaseArtifact {
    <#
    .SYNOPSIS
        Downloads the latest release artifact and extracts it to a tmp directory.
    .OUTPUTS
        Returns the path to the extracted tmp directory or $null on failure.
    #>
    param(
        [Parameter(Mandatory = $false)]
        [string]$WorkingDirectory = (Get-Location).Path
    )

    $release = Get-LatestReleaseWithArtifact
    if (-not $release) {
        return $null
    }

    Write-Log "Found release: $($release.Tag)"
    Write-Log "Release URL: $($release.ReleaseUrl)"
    Write-Log "Artifact URL: $($release.ArtifactUrl)"
    Write-Log "Downloading $script:ArtifactName..."

    $zipPath = Join-Path $WorkingDirectory $script:ArtifactName
    $tmpDir = Join-Path $WorkingDirectory "tmp"

    # Clean up existing files
    if (Test-Path $zipPath) {
        Remove-Item $zipPath -Force
    }
    if (Test-Path $tmpDir) {
        Remove-Item $tmpDir -Recurse -Force
    }

    try {
        Invoke-WebRequest -Uri $release.ArtifactUrl -OutFile $zipPath -Headers @{ "User-Agent" = "PowerShell" }
    }
    catch {
        Write-Log "Failed to download artifact: $_"
        return $null
    }

    Write-Log "Extracting to tmp directory..."
    try {
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        Expand-Archive -Path $zipPath -DestinationPath $tmpDir -Force
    }
    catch {
        Write-Log "Failed to extract artifact: $_"
        return $null
    }

    # Clean up zip file
    Remove-Item $zipPath -Force

    Write-Log "Successfully downloaded and extracted release $($release.Tag)"
    return $tmpDir
}
