# Reads the SMART health of this machine's NVMe drives with smartctl, and the
# health of its disk array and the free space of its volumes from Windows, and
# writes them as a Prometheus textfile for windows_exporter, which vmagent scrapes as the
# gaming-pc job. The series are the same ones the Proxmox host reports, so the
# Hardware health dashboard shows this machine under its Machine filter.
#
# Run every 5 minutes by the Gaming-PC-DriveHealth scheduled task (monitoring.ps1)
# as SYSTEM. One run reads one small log page per drive, at BelowNormal priority.
# See drive-health-metrics.ps1 for the series and README.md#drive-health.
#
# The NVMe drives are combined into one array in the BIOS (AMD RAID), so smartctl
# finds no NVMe device and the array health is what gets reported. Finding no
# NVMe device is normal, not a failure.
#
#   pwsh -File drive-health.ps1 -Print      write the metrics to the console (a dry run)
param(
    # The windows_exporter textfile directory; windows_exporter reads *.prom here.
    [string]$TextfileDirectory,

    [string]$SmartctlPath = (Join-Path $env:ProgramFiles 'smartmontools\bin\smartctl.exe'),

    # The machine label the dashboard's Machine filter shows.
    [string]$HostName = 'gaming-pc',

    [int]$CommandTimeoutSeconds = 30,

    # Reads the physical disks and volumes from this JSON file ({"disks":[],
    # "volumes":[]}) instead of Windows. For tests, where Get-PhysicalDisk does not exist.
    [string]$StorageJsonPath,

    [switch]$Print
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'drive-health-metrics.ps1')

function Invoke-Smartctl {
    # Returns the parsed JSON, whatever smartctl's exit code: it is a bit field
    # that also flags a drive that is merely worn or has logged errors, and those
    # are exactly what this script is here to report.
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $startInfo = [Diagnostics.ProcessStartInfo]::new($SmartctlPath)
    foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add($argument) }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($startInfo)
    try {
        # Read both streams before waiting, or a full pipe stalls smartctl.
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($CommandTimeoutSeconds * 1000)) {
            $process.Kill($true)
            throw "smartctl did not answer within $CommandTimeoutSeconds s"
        }
        $text = $stdout.GetAwaiter().GetResult()
        if (-not $text.Trim()) {
            throw "smartctl printed nothing (exit code $($process.ExitCode)): $($stderr.GetAwaiter().GetResult().Trim())"
        }
        return $text | ConvertFrom-Json
    }
    finally {
        $process.Dispose()
    }
}

# The same priority the FPS exporter runs at: never compete with a game for a core.
(Get-Process -Id $PID).PriorityClass = 'BelowNormal'

$drives = [Collections.Generic.List[hashtable]]::new()
$devices = @()  # NVMe only, see drive-health-metrics.ps1
try {
    $devices = Get-NvmeScanDevices (Invoke-Smartctl -Arguments '--scan', '--json')
}
catch {
    # Reported as a drive that cannot be read, not thrown: the textfile is
    # replaced on every run, and a file left from the last good run would keep
    # reporting old values as if they were current.
    $drives.Add(@{ Device = '/dev/scan'; Error = $_.Exception.Message })
}
foreach ($device in $devices) {
    try {
        $drives.Add(@{ Device = $device.name; Smart = (Invoke-Smartctl -Arguments '--json', '--all', '--device', $device.type, $device.name) })
    }
    catch {
        $drives.Add(@{ Device = $device.name; Error = $_.Exception.Message })
    }
}

function Get-StorageReport {
    # The disks and fixed volumes Windows reports. The RAID array is one
    # physical disk here; Select-ArrayDisks drops USB sticks.
    if ($StorageJsonPath) {
        $report = Get-Content -LiteralPath $StorageJsonPath -Raw | ConvertFrom-Json
        return @{ Disks = @($report.disks); Volumes = @($report.volumes) }
    }
    $disks = Get-PhysicalDisk | Select-Object FriendlyName, HealthStatus, OperationalStatus, Size, BusType, MediaType
    $systemLetter = ($env:SystemDrive -replace ':', '')
    $volumes = Get-Volume | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter } |
        Select-Object DriveLetter, Size, SizeRemaining, @{ Name = 'IsSystem'; Expression = { "$($_.DriveLetter)" -eq $systemLetter } }
    return @{ Disks = @($disks); Volumes = @($volumes) }
}

# Never thrown, for the same reason as the scan above: the file is replaced on every run.
$storage = @{ Disks = @(); Volumes = @() }
$arrayError = $null
try { $storage = Get-StorageReport }
catch { $arrayError = $_.Exception.Message }

$text = New-DriveHealthText -Drives $drives -HostName $HostName -Timestamp ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) `
    -ArrayDisks $storage.Disks -Volumes $storage.Volumes -ArrayError $arrayError `
    -OnError { param($Message) [Console]::Error.WriteLine($Message) }

if ($Print) {
    Write-Output $text
    exit 0
}
if (-not $TextfileDirectory) {
    throw 'Pass -TextfileDirectory, or -Print for a dry run.'
}

# Atomic: the collector must never read a half-written file, and a temporary
# name that does not end in .prom is never read at all.
$path = Join-Path $TextfileDirectory 'gaming-pc-drive-health.prom'
[IO.File]::WriteAllText("$path.tmp", $text, [Text.UTF8Encoding]::new($false))
[IO.File]::Move("$path.tmp", $path, $true)
