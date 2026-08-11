# Declarative software state for the gaming PC (HO-239).
#
# Everything the captain's machine must have installed - and the two things it
# must not - live in the manifests below. Re-running is a no-op: every entry
# tests for presence first and only acts when reality disagrees.
#
# Run in two phases because elevation is a property of the process, not of a
# command:
#
#   -Phase Machine  elevated. Machine-scope winget installs and removals.
#   -Phase User     unelevated, in the gaming user's own session. Microsoft
#                   Store (MSIX) packages and per-user installers, which either
#                   refuse to run elevated or would land in the wrong hive.
#
# Both phases are driven from scripts/deploy.yml. See apps/gaming-pc/README.md
# for the full list and for what is deliberately not installed by winget.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Machine', 'User')]
    [string]$Phase
)

$ErrorActionPreference = 'Stop'

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path $ScriptDir 'logging.ps1')
. (Join-Path $ScriptDir 'winget.ps1')

$script:Changed = 0
$script:Failures = New-Object System.Collections.Generic.List[string]
$script:Warnings = New-Object System.Collections.Generic.List[string]

# ---------------------------------------------------------------------------
# Manifests
# ---------------------------------------------------------------------------

# Machine-wide, installed from the community winget source. Ids verified
# against microsoft/winget-pkgs.
$MachinePackages = @(
    @{ Name = 'Steam'; Id = 'Valve.Steam' }
    @{ Name = 'Apollo'; Id = 'ClassicOldSong.Apollo' }
    @{ Name = 'Logi Options+'; Id = 'Logitech.OptionsPlus' }
    @{ Name = '1Password'; Id = 'AgileBits.1Password' }
    @{ Name = 'Tailscale'; Id = 'Tailscale.Tailscale' }
    @{ Name = 'Zed'; Id = 'ZedIndustries.Zed' }
)

# Must not be present. Discord additionally needs the leftover-hunting below:
# its Squirrel installer is per-user and leaves a working copy behind that
# winget cannot see.
$UnwantedPackages = @(
    @{ Name = 'Playnite'; Id = 'Playnite.Playnite' }
    @{ Name = 'Discord'; Id = 'Discord.Discord' }
)

# Microsoft Store apps. Optional by ticket wording ("if possible"): an MSIX
# install can require an interactive, signed-in Microsoft Store session that a
# remote deploy does not have. A failure here is reported loudly and listed in
# the summary rather than failing the deploy.
$StorePackages = @(
    @{ Name = 'Raycast'; Id = '9PFXXSHC64H3' }
    @{ Name = 'Windows HDR Calibration'; Id = '9N7F2SM5D1LR' }
    @{ Name = 'Dolby Access'; Id = '9N0866FS04W8' }
)

# ---------------------------------------------------------------------------
# Step harness
# ---------------------------------------------------------------------------

function Invoke-Step {
    <#
    .SYNOPSIS
        Runs one unit of work, recording whether it changed anything or failed.
    .DESCRIPTION
        The action returns 'Installed'/'Removed' when it changed the machine and
        'Present'/'Absent' when it did not, which is what keeps a second deploy
        honest about being a no-op.

        A required step's failure is collected rather than thrown so the rest of
        the manifest still runs; the script exits non-zero at the end. An
        optional step's failure becomes a warning.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,

        [switch]$Optional
    )

    try {
        $outcome = & $Action
        if ($outcome -in @('Installed', 'Removed')) {
            $script:Changed++
        }
    }
    catch {
        $message = "$Name : $($_.Exception.Message)"
        if ($Optional) {
            Write-Log "  WARNING $message"
            $script:Warnings.Add($message)
        }
        else {
            Write-Log "  FAILED $message"
            $script:Failures.Add($message)
        }
    }
}

# ---------------------------------------------------------------------------
# Discord leftovers
# ---------------------------------------------------------------------------

function Remove-DiscordLeftovers {
    <#
    .SYNOPSIS
        Removes a per-user Discord that winget does not track.
    .DESCRIPTION
        Discord ships a Squirrel installer into %LOCALAPPDATA%, so an install
        done by the user rather than by a package manager is invisible to both
        winget and Chocolatey while still being a fully working Discord. The
        ticket asks for Discord to be absent, not merely unmanaged.
    .OUTPUTS
        'Removed' if anything was actually deleted, otherwise 'Absent'.
    #>
    $removedSomething = $false

    $updateExe = Join-Path $env:LOCALAPPDATA 'Discord\Update.exe'
    if (Test-Path $updateExe) {
        Write-Log '  Discord: running the Squirrel uninstaller...'
        $process = Start-Process -FilePath $updateExe -ArgumentList '--uninstall' `
            -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            throw "the Squirrel uninstaller exited with code $($process.ExitCode)"
        }
        $removedSomething = $true
    }

    # A running Discord keeps its own files locked, which is the one failure
    # mode that would otherwise make this step fail on a machine where the
    # captain simply had it open.
    Get-Process -Name 'Discord*' -ErrorAction SilentlyContinue | Stop-Process -Force

    foreach ($directory in @(
            (Join-Path $env:LOCALAPPDATA 'Discord'),
            (Join-Path $env:APPDATA 'discord')
        )) {
        if (Test-Path $directory) {
            Write-Log "  Discord: removing $directory"
            Remove-Item $directory -Recurse -Force
            $removedSomething = $true
        }
    }

    if ($removedSomething) {
        Write-Log '  Discord: leftovers removed'
        return 'Removed'
    }

    Write-Log '  Discord: no per-user leftovers'
    return 'Absent'
}

# ---------------------------------------------------------------------------
# MoonDeck Buddy
# ---------------------------------------------------------------------------

function ConvertTo-ComparableVersion {
    <#
    .SYNOPSIS
        Pads a version to four parts so 1.9.2 and 1.9.2.0 compare equal.
    #>
    param([string]$Version)

    if ([string]::IsNullOrWhiteSpace($Version)) { return $null }
    $trimmed = $Version.Trim() -replace '^[vV]', ''
    $parts = @($trimmed -split '[.]' | Where-Object { $_ -match '^\d+$' })
    if ($parts.Count -eq 0) { return $null }
    while ($parts.Count -lt 4) { $parts += '0' }
    try { return [version]($parts[0..3] -join '.') } catch { return $null }
}

function Get-MoonDeckBuddyInstalledVersion {
    # PrivilegesRequired=lowest means the Inno uninstall key lands in HKCU for a
    # per-user install and HKLM if it was ever run elevated. Check both.
    $keys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\MoonDeckBuddy_is1',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\MoonDeckBuddy_is1'
    )
    foreach ($key in $keys) {
        $entry = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if ($entry -and $entry.DisplayVersion) {
            return $entry.DisplayVersion
        }
    }
    return $null
}

function Install-MoonDeckBuddy {
    <#
    .SYNOPSIS
        Installs or updates MoonDeck Buddy from its GitHub release.
    .DESCRIPTION
        Not published to winget or Chocolatey, so it is fetched the same way
        gsync-toggle already is in scripts/deploy.yml - from the same author's
        GitHub releases. Idempotency comes from comparing the installed Inno
        DisplayVersion against the latest release tag, so a second deploy
        downloads nothing.
    .OUTPUTS
        'Present' when already on the latest version, 'Installed' otherwise.
    #>
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/FrogTheFrog/moondeck-buddy/releases/latest' `
        -Headers @{ 'User-Agent' = 'home-ops-gaming-pc'; 'Accept' = 'application/vnd.github+json' }

    $asset = $release.assets | Where-Object { $_.name -match '^MoonDeckBuddy-.*-win64\.exe$' } | Select-Object -First 1
    if (-not $asset) {
        throw "the latest release ($($release.tag_name)) has no MoonDeckBuddy-*-win64.exe asset"
    }

    $latest = ConvertTo-ComparableVersion $release.tag_name
    $installedRaw = Get-MoonDeckBuddyInstalledVersion
    $installed = ConvertTo-ComparableVersion $installedRaw

    if ($installed -and $latest -and $installed -ge $latest) {
        Write-Log "  MoonDeck Buddy: already on $installedRaw (latest is $($release.tag_name))"
        return 'Present'
    }

    if ($installedRaw) {
        Write-Log "  MoonDeck Buddy: $installedRaw installed, $($release.tag_name) available; updating..."
    }
    else {
        Write-Log "  MoonDeck Buddy: not installed; installing $($release.tag_name)..."
    }

    $downloadDir = Join-Path $env:TEMP 'gaming-pc-software'
    New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
    $installer = Join-Path $downloadDir $asset.name

    try {
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $installer `
            -Headers @{ 'User-Agent' = 'home-ops-gaming-pc' }

        # Inno Setup silent switches. /SP- suppresses the "This will install..."
        # prompt that /VERYSILENT alone still shows on some builds.
        $process = Start-Process -FilePath $installer `
            -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-' `
            -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            throw "the installer exited with code $($process.ExitCode)"
        }
    }
    finally {
        Remove-Item $installer -Force -ErrorAction SilentlyContinue
    }

    Write-Log "  MoonDeck Buddy: installed $($release.tag_name)"
    return 'Installed'
}

# ---------------------------------------------------------------------------
# Phases
# ---------------------------------------------------------------------------

function Invoke-MachinePhase {
    Write-Log 'Installing machine-scope packages via winget...'
    foreach ($package in $MachinePackages) {
        Invoke-Step -Name $package.Name -Action {
            Install-WingetPackage -Id $package.Id -Name $package.Name -Scope machine
        }.GetNewClosure()
    }

    Write-Log 'Ensuring unwanted packages are absent...'
    foreach ($package in $UnwantedPackages) {
        Invoke-Step -Name $package.Name -Action {
            Uninstall-WingetPackage -Id $package.Id -Name $package.Name
        }.GetNewClosure()
    }
}

function Invoke-UserPhase {
    Write-Log 'Installing Microsoft Store apps (best effort - see README)...'
    foreach ($package in $StorePackages) {
        Invoke-Step -Name $package.Name -Optional -Action {
            Install-WingetPackage -Id $package.Id -Name $package.Name -Source msstore
        }.GetNewClosure()
    }

    Write-Log 'Installing per-user packages...'
    Invoke-Step -Name 'MoonDeck Buddy' -Action { Install-MoonDeckBuddy }

    Write-Log 'Removing per-user Discord leftovers...'
    Invoke-Step -Name 'Discord leftovers' -Action { Remove-DiscordLeftovers }
}

# ---------------------------------------------------------------------------

Write-Log "=== software.ps1 phase=$Phase ==="

switch ($Phase) {
    'Machine' { Invoke-MachinePhase }
    'User' { Invoke-UserPhase }
}

foreach ($warning in $script:Warnings) {
    Write-Log "SUMMARY warning: $warning"
}
foreach ($failure in $script:Failures) {
    Write-Log "SUMMARY failure: $failure"
}

# Parsed by scripts/deploy.yml to decide changed/failed, so keep the shape.
Write-Log ("RESULT phase={0} changed={1} warnings={2} failures={3}" -f `
        $Phase, $script:Changed, $script:Warnings.Count, $script:Failures.Count)

if ($script:Failures.Count -gt 0) {
    exit 1
}
exit 0
