# Manages FanControl (Rem0o.FanControl, installed by software.ps1) and the
# owner's two fan profiles. See README.md#fancontrol-profiles for the why.
#
# What it does:
#   * copies the two profiles in fancontrol\ next to this script into FanControl's
#     Configurations folder. A file that already matches by SHA-256 is left alone,
#     and one that differs is backed up once (<name>.gaming-pc.bak, never
#     overwritten by a later run) before it is replaced;
#   * makes the balance profile the one FanControl loads, but ONLY when no
#     profile has been chosen yet (no CACHE file, no recorded name, or FanControl's
#     own untouched default, userConfig.json). The owner switches by hand, so once
#     they have picked anything else a re-run never touches it;
#   * installs two all-users Start menu shortcuts that run `FanControl.exe -c
#     <profile>.json`, the documented way to change the config of a running
#     FanControl. They are a convenience: the app and its tray keep working as
#     they always did, and nothing here ever switches profiles on its own.
#
# What it will not do:
#   * edit the CACHE file while FanControl is running (the app rewrites it from
#     memory on exit, which would undo the default). It warns instead;
#   * enable the pump header (Fan #7). Both profiles ship it disabled and the
#     tests pin that.
#
# Run elevated by scripts/deploy.yml after software.ps1 has installed FanControl
# and before monitoring.ps1, which needs the PawnIO driver FanControl brings.
# The last line, RESULT, is what deploy.yml reads, so keep its shape.

[CmdletBinding()]
param(
    # Overrides where FanControl is installed. Empty means look it up.
    [string]$InstallDir = '',
    # Where the profiles are copied from. Empty means .\fancontrol beside this script.
    [string]$ProfileSourceDir = '',
    # Where the Start menu shortcuts go. Empty means the all-users Programs folder.
    [string]$ShortcutDir = ''
)

$ErrorActionPreference = 'Stop'

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path $ScriptDir 'logging.ps1')

$script:Changed = 0
$script:Failures = New-Object System.Collections.Generic.List[string]
$script:Warnings = New-Object System.Collections.Generic.List[string]

# The profile key is what fancontrol-profile.ps1 takes on its command line.
$script:FanControlProfiles = [ordered]@{
    'balance'   = @{ File = 'gpc-thermal-balance.json'; Shortcut = 'FanControl - Balance.lnk' }
    'gpu-boost' = @{ File = 'gpc-thermal-gpu-boost.json'; Shortcut = 'FanControl - GPU boost.lnk' }
}
$script:DefaultProfileKey = 'balance'
# What FanControl names the profile it creates itself on first run.
$script:FanControlStockProfile = 'userConfig.json'

function Add-FanControlWarning {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Log "  WARNING $Message"
    $script:Warnings.Add($Message)
}

# ---------------------------------------------------------------------------
# Locating FanControl
# ---------------------------------------------------------------------------

function Get-FanControlInstallDir {
    <#
    .SYNOPSIS
        The folder holding FanControl.exe, or $null when it is not installed.
    .DESCRIPTION
        FanControl keeps its Configurations folder next to the exe. The Inno
        installer registers an uninstall entry with InstallLocation, so that is
        asked first; Program Files (x86) and Program Files are the fallbacks.
    #>
    param([string]$Override = '')

    if ($Override) {
        if (Test-Path (Join-Path $Override 'FanControl.exe')) { return $Override }
        return $null
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($root in @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
        )) {
        foreach ($entry in @(Get-ChildItem -Path $root -ErrorAction SilentlyContinue)) {
            $props = Get-ItemProperty -Path $entry.PSPath -ErrorAction SilentlyContinue
            if ($props -and $props.DisplayName -match '^Fan ?Control' -and $props.InstallLocation) {
                $candidates.Add(([string]$props.InstallLocation).TrimEnd('\'))
            }
        }
    }
    foreach ($base in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        if ($base) { $candidates.Add((Join-Path $base 'FanControl')) }
    }

    foreach ($dir in $candidates) {
        if (Test-Path (Join-Path $dir 'FanControl.exe')) { return $dir }
    }
    return $null
}

function Test-FanControlRunning {
    return $null -ne (Get-Process -Name 'FanControl' -ErrorAction SilentlyContinue)
}

# ---------------------------------------------------------------------------
# Profiles
# ---------------------------------------------------------------------------

function Copy-FanControlProfile {
    <#
    .SYNOPSIS
        Copies one profile into place unless the destination already matches.
    .OUTPUTS
        'Present' when the hashes match (nothing touched), 'Installed' when the
        file was written. A different existing file is backed up once first.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (-not (Test-Path $Source)) { throw "profile source $Source is missing" }

    if (Test-Path $Destination) {
        $same = (Get-FileHash -Path $Source -Algorithm SHA256).Hash -eq
        (Get-FileHash -Path $Destination -Algorithm SHA256).Hash
        if ($same) {
            Write-Log "  $(Split-Path $Destination -Leaf): already matches"
            return 'Present'
        }

        # The first backup is the original; a later, third version must not
        # replace it, so an existing backup is kept as it is.
        $backup = "$Destination.gaming-pc.bak"
        if (-not (Test-Path $backup)) {
            Copy-Item -Path $Destination -Destination $backup
            Write-Log "  $(Split-Path $Destination -Leaf): differs, backed up to $backup"
        }
        else {
            Write-Log "  $(Split-Path $Destination -Leaf): differs, keeping the existing backup $backup"
        }
    }
    else {
        New-Item -ItemType Directory -Path (Split-Path $Destination -Parent) -Force | Out-Null
    }

    Copy-Item -Path $Source -Destination $Destination -Force
    Write-Log "  $(Split-Path $Destination -Leaf): written"
    return 'Installed'
}

# ---------------------------------------------------------------------------
# Default profile
# ---------------------------------------------------------------------------

function Get-DefaultProfileDecision {
    <#
    .SYNOPSIS
        Whether the default profile should be recorded, and why.
    .DESCRIPTION
        FanControl records the profile it loads in Configurations\CACHE under
        CurrentConfigFileName (FanControl.Releases issue 3865). The decision is
        'Set' only when nothing has been chosen: no CACHE, no recorded name, or
        the stock userConfig.json the app creates itself. Any other recorded
        name is the owner's choice and is 'Keep'. A CACHE that is not JSON is
        'Unreadable': the format is not documented, so it is never rewritten.
    .OUTPUTS
        'Set', 'Keep' or 'Unreadable'.
    #>
    param([Parameter(Mandatory = $true)][string]$CachePath)

    if (-not (Test-Path $CachePath)) { return 'Set' }

    try { $cache = Get-Content -Path $CachePath -Raw | ConvertFrom-Json -ErrorAction Stop }
    catch { return 'Unreadable' }
    if ($null -eq $cache -or $cache -isnot [pscustomobject]) { return 'Unreadable' }

    $current = $cache.PSObject.Properties['CurrentConfigFileName']
    if (-not $current -or [string]::IsNullOrWhiteSpace([string]$current.Value)) { return 'Set' }
    if ([string]$current.Value -eq $script:FanControlStockProfile) { return 'Set' }
    return 'Keep'
}

function Set-DefaultProfile {
    <#
    .OUTPUTS
        'Installed' when the default was recorded, 'Present' when left alone.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ConfigDir,
        [Parameter(Mandatory = $true)][string]$ProfileFile
    )

    $cachePath = Join-Path $ConfigDir 'CACHE'
    $decision = Get-DefaultProfileDecision -CachePath $cachePath

    if ($decision -eq 'Keep') {
        Write-Log '  default profile: a profile is already chosen, left as it is'
        return 'Present'
    }
    if ($decision -eq 'Unreadable') {
        Add-FanControlWarning "$cachePath is not JSON, so the default profile was not set. Pick $ProfileFile in FanControl once."
        return 'Present'
    }
    if (Test-FanControlRunning) {
        Add-FanControlWarning 'FanControl is running and rewrites CACHE on exit, so the default profile was not set. Exit it from the tray and re-run, or pick the profile in the app once.'
        return 'Present'
    }

    $cache = if (Test-Path $cachePath) { Get-Content -Path $cachePath -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
    $cache | Add-Member -NotePropertyName 'CurrentConfigFileName' -NotePropertyValue $ProfileFile -Force
    $json = $cache | ConvertTo-Json -Depth 10

    $temp = "$cachePath.gaming-pc.tmp"
    [IO.File]::WriteAllText($temp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -Path $temp -Destination $cachePath -Force
    Write-Log "  default profile: set to $ProfileFile"
    return 'Installed'
}

# ---------------------------------------------------------------------------
# Shortcuts
# ---------------------------------------------------------------------------

function Get-ShortcutState {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    $link = (New-Object -ComObject WScript.Shell).CreateShortcut($Path)
    return @{ Target = $link.TargetPath; Arguments = $link.Arguments; WorkingDirectory = $link.WorkingDirectory }
}

function Write-Shortcut {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )
    $link = (New-Object -ComObject WScript.Shell).CreateShortcut($Path)
    $link.TargetPath = $Target
    $link.Arguments = $Arguments
    # FanControl's docs require "Start in" to be the folder holding the exe and
    # its configs for a shortcut that uses -c.
    $link.WorkingDirectory = $WorkingDirectory
    $link.IconLocation = "$Target,0"
    $link.Save()
}

function Install-ProfileShortcut {
    <#
    .OUTPUTS
        'Present' when the shortcut already matches, 'Installed' otherwise.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$InstallDir,
        [Parameter(Mandatory = $true)][string]$ProfileFile
    )

    $target = Join-Path $InstallDir 'FanControl.exe'
    $arguments = "-c $ProfileFile"
    $state = Get-ShortcutState -Path $Path
    if ($state -and $state.Target -eq $target -and $state.Arguments -eq $arguments -and
        $state.WorkingDirectory -eq $InstallDir) {
        Write-Log "  $(Split-Path $Path -Leaf): already correct"
        return 'Present'
    }

    New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
    Write-Shortcut -Path $Path -Target $target -Arguments $arguments -WorkingDirectory $InstallDir
    Write-Log "  $(Split-Path $Path -Leaf): written"
    return 'Installed'
}

# ---------------------------------------------------------------------------

function Invoke-FanControlStep {
    param([string]$Name, [scriptblock]$Action)
    try {
        if ((& $Action) -eq 'Installed') { $script:Changed++ }
    }
    catch {
        Write-Log "  FAILED $Name : $($_.Exception.Message)"
        $script:Failures.Add("$Name : $($_.Exception.Message)")
    }
}

# Dot-sourced by fancontrol-profile.ps1 and the tests for the functions only.
if ($MyInvocation.InvocationName -eq '.') { return }

Write-Log '=== fancontrol.ps1 ==='

$installDir = Get-FanControlInstallDir -Override $InstallDir
if (-not $installDir) {
    $script:Failures.Add('FanControl.exe was not found; software.ps1 installs Rem0o.FanControl before this step')
    Write-Log "  FAILED $($script:Failures[0])"
}
else {
    $configDir = Join-Path $installDir 'Configurations'
    $sourceDir = if ($ProfileSourceDir) { $ProfileSourceDir } else { Join-Path $ScriptDir 'fancontrol' }
    $shortcutRoot = if ($ShortcutDir) { $ShortcutDir } else { Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs' }

    Write-Log "FanControl found in $installDir"
    foreach ($key in $script:FanControlProfiles.Keys) {
        $file = $script:FanControlProfiles[$key].File
        Invoke-FanControlStep -Name "profile $key" -Action {
            Copy-FanControlProfile -Source (Join-Path $sourceDir $file) -Destination (Join-Path $configDir $file)
        }.GetNewClosure()
    }

    $defaultFile = $script:FanControlProfiles[$script:DefaultProfileKey].File
    Invoke-FanControlStep -Name 'default profile' -Action {
        Set-DefaultProfile -ConfigDir $configDir -ProfileFile $defaultFile
    }.GetNewClosure()

    foreach ($key in $script:FanControlProfiles.Keys) {
        $entry = $script:FanControlProfiles[$key]
        Invoke-FanControlStep -Name "shortcut $key" -Action {
            Install-ProfileShortcut -Path (Join-Path $shortcutRoot $entry.Shortcut) -InstallDir $installDir -ProfileFile $entry.File
        }.GetNewClosure()
    }
}

foreach ($warning in $script:Warnings) { Write-Log "SUMMARY warning: $warning" }
foreach ($failure in $script:Failures) { Write-Log "SUMMARY failure: $failure" }

Write-Log ("RESULT changed={0} warnings={1} failures={2}" -f `
        $script:Changed, $script:Warnings.Count, $script:Failures.Count)

if ($script:Failures.Count -gt 0) { exit 1 }
exit 0
