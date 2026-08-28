# Configures WinNUT-Client's connection to the Synology NAS's NUT server and
# its shutdown thresholds, then makes sure it is actually running.
#
# Run as its own step in scripts/deploy.yml, separate from software.ps1's
# winget install of the package - so only this task's Ansible invocation
# carries the NUT monitor credentials (no_log'd there) without hiding
# software.ps1's own install/warning output.
#
# Reads its inputs from environment variables so the credentials never appear
# on a process command line or in Ansible's own module-arg logging - see
# scripts/deploy.yml's `environment:` block for this task.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path $ScriptDir 'logging.ps1')
. (Join-Path $ScriptDir 'nut-client.ps1')

$RequiredEnvVars = @(
    'NUT_SERVER_ADDRESS', 'NUT_SERVER_PORT', 'NUT_UPS_NAME',
    'NUT_MONITOR_USERNAME', 'NUT_MONITOR_PASSWORD', 'NUT_BATTERY_CHARGE_FLOOR'
)
foreach ($name in $RequiredEnvVars) {
    if (-not (Test-Path "env:$name")) {
        throw "Required environment variable $name is not set."
    }
}

Write-Log '=== configure-nut-client.ps1 ==='

$configureOutcome = Set-WinNutClientSettings `
    -ServerAddress $env:NUT_SERVER_ADDRESS `
    -ServerPort ([int]$env:NUT_SERVER_PORT) `
    -UpsName $env:NUT_UPS_NAME `
    -MonitorUsername $env:NUT_MONITOR_USERNAME `
    -MonitorPassword $env:NUT_MONITOR_PASSWORD `
    -BatteryChargeFloor ([int]$env:NUT_BATTERY_CHARGE_FLOOR)

$installDir = Get-WinNutClientInstallDirectory
$startOutcome = Start-WinNutClientIfNotRunning -InstallDirectory $installDir

# Parsed by scripts/deploy.yml to decide changed/unchanged.
Write-Log ("RESULT configure={0} start={1}" -f $configureOutcome, $startOutcome)
