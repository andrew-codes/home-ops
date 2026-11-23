# Switches the running FanControl to one of the two profiles without opening it:
#
#   fancontrol-profile.ps1 balance      (the default)
#   fancontrol-profile.ps1 gpu-boost
#
# This is a convenience; switching in FanControl itself keeps working untouched,
# and nothing in the deploy calls this. It runs `FanControl.exe -c <profile>.json`,
# which FanControl documents as "start using the specified config, or change the
# config if the software is already running" (https://www.getfancontrol.com/docs).
# The running instance switches in place, so no restart is needed; if FanControl
# is not running it starts with that profile. It does not restart FanControl.
#
# Run it as the logged-in user, not over the deploy's SSH session: FanControl is a
# GUI app on the user's desktop and asks for elevation itself (a UAC prompt).

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('balance', 'gpu-boost')]
    [string]$ProfileName,

    # Overrides where FanControl is installed. Empty means look it up.
    [string]$InstallDir = ''
)

$ErrorActionPreference = 'Stop'

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
# Only the helpers: fancontrol.ps1 returns early when dot-sourced.
. (Join-Path $ScriptDir 'fancontrol.ps1')

function Switch-FanControlProfile {
    param(
        [Parameter(Mandatory = $true)][string]$ProfileName,
        [string]$InstallDir = ''
    )

    if (-not $script:FanControlProfiles.Contains($ProfileName)) {
        throw "unknown profile '$ProfileName'; use one of: $($script:FanControlProfiles.Keys -join ', ')"
    }
    $file = $script:FanControlProfiles[$ProfileName].File

    $dir = Get-FanControlInstallDir -Override $InstallDir
    if (-not $dir) { throw 'FanControl.exe was not found; run the gaming-pc deploy first' }
    if (-not (Test-Path (Join-Path $dir 'Configurations' $file))) {
        throw "$file is not in FanControl's Configurations folder; run the gaming-pc deploy first"
    }

    # "Start in" must hold the exe and its configs, per FanControl's docs.
    Start-Process -FilePath (Join-Path $dir 'FanControl.exe') -ArgumentList '-c', $file -WorkingDirectory $dir
    Write-Log "FanControl: asked to use $file"
}

if ($MyInvocation.InvocationName -eq '.') { return }

if ($PSCmdlet.ShouldProcess("FanControl", "switch to $ProfileName")) {
    Switch-FanControlProfile -ProfileName $ProfileName -InstallDir $InstallDir
}
