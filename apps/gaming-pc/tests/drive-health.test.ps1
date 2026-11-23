# Tests for src/drive-health-metrics.ps1. Run with:
#   pwsh -NoProfile -File apps/gaming-pc/tests/drive-health.test.ps1
# Plain assertions, no Pester, so the only thing it needs is PowerShell 7. The
# fixtures are the shape of `smartctl --json` 7.5 on Windows (tests/fixtures/smartctl).

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'src' 'drive-health-metrics.ps1')

$script:Failures = 0
function Assert-Equal {
    param($Expected, $Actual, [string]$What)
    if ($Expected -ne $Actual) {
        Write-Host "FAIL $What`n  expected: $Expected`n  actual:   $Actual"
        $script:Failures++
    }
    else {
        Write-Host "ok   $What"
    }
}

function Read-Fixture {
    param([string]$Name)
    Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'fixtures' 'smartctl' $Name) | ConvertFrom-Json
}

# The sample lines of a text, keyed by series name and labels.
function Get-Samples {
    param([string]$Text)
    $samples = @{}
    foreach ($line in $Text -split "`n") {
        if ($line -match '^(.+) (\S+)$') { $samples[$Matches[1]] = $Matches[2] }
    }
    return $samples
}

$healthy = '{device="nvme0",host="gaming-pc",model="Samsung SSD 990 PRO 2TB",serial="S6Z2NJ0W123456A"}'
$failing = '{device="nvme1",host="gaming-pc",model="WD_BLACK SN850X 4000GB",serial="24123M800987"}'

# A scan lists every drive; only the NVMe ones are read.
$scan = Get-NvmeScanDevices (Read-Fixture 'scan.json')
Assert-Equal '/dev/nvme0,/dev/nvme1' (($scan | ForEach-Object name) -join ',') 'the scan keeps the NVMe drives and drops the SATA one'

# One healthy drive, one failing drive, one that could not be read.
$errors = [Collections.Generic.List[string]]::new()
$text = New-DriveHealthText -HostName 'gaming-pc' -Timestamp 1795440000 -OnError { param($Message) $errors.Add($Message) } -Drives @(
    @{ Device = '/dev/nvme0'; Smart = (Read-Fixture 'nvme_healthy.json') }
    @{ Device = '/dev/nvme1'; Smart = (Read-Fixture 'nvme_failing.json') }
    @{ Device = '/dev/nvme2'; Error = 'smartctl did not answer within 30 s' }
)
$s = Get-Samples $text

# The series and labels the Hardware health dashboard reads.
Assert-Equal '3' $s['nvme_health_drives{host="gaming-pc"}'] 'counts the drives'
Assert-Equal '3' $s["nvme_smart_percentage_used$healthy"] 'wear of the healthy drive'
Assert-Equal '100' $s["nvme_smart_available_spare_percent$healthy"] 'spare of the healthy drive'
Assert-Equal '10' $s["nvme_smart_available_spare_threshold_percent$healthy"] 'spare threshold of the healthy drive'
Assert-Equal '38' $s["nvme_smart_temperature_celsius$healthy"] 'temperature of the healthy drive'
Assert-Equal '5200' $s["nvme_smart_power_on_hours$healthy"] 'power on hours of the healthy drive'
Assert-Equal '2000398934016' $s["nvme_capacity_bytes$healthy"] 'capacity of the healthy drive'
Assert-Equal '28300000' $s["nvme_smart_data_units_written$healthy"] 'data units written of the healthy drive'
Assert-Equal '0' $s["nvme_smart_media_errors$healthy"] 'no media errors on the healthy drive'
Assert-Equal '0' $s["nvme_smart_critical_warning$healthy"] 'no critical warning on the healthy drive'
Assert-Equal '1' $s['nvme_health_collect_ok{device="nvme0",host="gaming-pc"}'] 'healthy drive was read'

Assert-Equal '89' $s["nvme_smart_percentage_used$failing"] 'wear of the failing drive'
Assert-Equal '94' $s["nvme_smart_available_spare_percent$failing"] 'spare of the failing drive'
Assert-Equal '3' $s["nvme_smart_media_errors$failing"] 'media errors of the failing drive'
Assert-Equal '9' $s["nvme_smart_error_log_entries$failing"] 'error log entries of the failing drive'
Assert-Equal '120' $s["nvme_smart_warning_temperature_seconds$failing"] 'time over the warning temperature'
Assert-Equal '1' $s['nvme_health_collect_ok{device="nvme1",host="gaming-pc"}'] 'failing drive was read'

# An unreadable drive reports collect_ok 0 and no SMART series of its own.
Assert-Equal '0' $s['nvme_health_collect_ok{device="nvme2",host="gaming-pc"}'] 'unreadable drive is collect_ok 0'
Assert-Equal '0' (@($s.Keys | Where-Object { $_ -match 'nvme_smart_.*nvme2' }).Count) 'unreadable drive has no SMART series'
Assert-Equal 'nvme2: smartctl did not answer within 30 s' $errors[0] 'unreadable drive is reported to the caller'

# The heartbeat is its own series: the pve alert on nvme_health_push_timestamp_seconds
# must not be satisfied by this machine.
Assert-Equal '1795440000' $s['gaming_pc_drive_health_timestamp_seconds{host="gaming-pc"}'] 'heartbeat'
Assert-Equal '0' (@($s.Keys | Where-Object { $_ -like 'nvme_health_push_timestamp_seconds*' }).Count) 'no pve heartbeat series'
$lastLine = ($text.TrimEnd("`n") -split "`n")[-1]
Assert-Equal 'gaming_pc_drive_health_timestamp_seconds{host="gaming-pc"} 1795440000' $lastLine 'heartbeat is written last'

# A JSON body with no NVMe log (an ATA drive, or smartctl failing) is a read failure.
$errors.Clear()
$text = New-DriveHealthText -HostName 'gaming-pc' -Timestamp 1 -OnError { param($Message) $errors.Add($Message) } -Drives @(
    @{ Device = '/dev/nvme0'; Smart = ([pscustomobject]@{ device = [pscustomobject]@{ name = '/dev/nvme0' } }) }
)
Assert-Equal '0' (Get-Samples $text)['nvme_health_collect_ok{device="nvme0",host="gaming-pc"}'] 'a body without an NVMe log is collect_ok 0'

# No NVMe drive at all is not a failure.
$text = New-DriveHealthText -HostName 'gaming-pc' -Timestamp 1 -Drives @()
Assert-Equal '0' (Get-Samples $text)['nvme_health_drives{host="gaming-pc"}'] 'no drives is a count of 0'
Assert-Equal '0' (@((Get-Samples $text).Keys | Where-Object { $_ -like 'nvme_health_collect_ok*' }).Count) 'no drives, no read failures'

# The owner's machine: the three NVMe drives are one AMD RAID array, so the scan
# lists two scsi devices (the array and a USB stick) and no NVMe one. That is a
# normal state: no drives, no read failures, and the array is what is reported.
$raidScan = Get-NvmeScanDevices (Read-Fixture 'scan_amd_raid.json')
Assert-Equal '0' @($raidScan).Count 'scsi devices are not NVMe drives'
Assert-Equal '0' @(Get-NvmeScanDevices ([pscustomobject]@{ devices = $null })).Count 'a scan with no devices at all is fine'

function Read-Storage {
    param([string]$Name)
    Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'fixtures' 'storage' $Name) | ConvertFrom-Json
}
$storage = Read-Storage 'amd_raid_healthy.json'
$text = New-DriveHealthText -HostName 'gaming-pc' -Timestamp 1 -Drives @() -ArrayDisks @($storage.disks) -Volumes @($storage.volumes)
$s = Get-Samples $text
$array = 'array="AMD-RAID Array 1",host="gaming-pc"'
Assert-Equal '0' $s['nvme_health_drives{host="gaming-pc"}'] 'array machine: no NVMe drives'
Assert-Equal '0' (@($s.Keys | Where-Object { $_ -like 'nvme_health_collect_ok*' }).Count) 'array machine: no read failure'
Assert-Equal '0' $s['gaming_pc_array_health_status{array="AMD-RAID Array 1",bus_type="RAID",host="gaming-pc",media_type="SSD"}'] 'a healthy array is 0'
Assert-Equal '1' $s['gaming_pc_array_operational_status_info{array="AMD-RAID Array 1",host="gaming-pc",status="OK"}'] 'operational status info'
Assert-Equal '6001175126016' $s["gaming_pc_array_size_bytes{$array}"] 'array size'
Assert-Equal '1' $s['gaming_pc_array_collect_ok{host="gaming-pc"}'] 'array was read'
Assert-Equal '0' (@($s.Keys | Where-Object { $_ -like '*USB*' }).Count) 'the USB stick is not reported'
Assert-Equal '500000000000' $s['gaming_pc_volume_free_bytes{host="gaming-pc",role="system",volume="C:"}'] 'system volume free'
Assert-Equal '4000000000000' $s['gaming_pc_volume_size_bytes{host="gaming-pc",role="data",volume="D:"}'] 'data volume size'
Assert-Equal '0' @($text -split "`n" | Where-Object { $_ -match 'serial' }).Count 'no serial number is printed'

# Health values: Warning 1, Unhealthy 2, anything else (Unknown) 3.
Assert-Equal '1' (Get-ArrayHealthValue 'Warning') 'Warning is 1'
Assert-Equal '2' (Get-ArrayHealthValue 'Unhealthy') 'Unhealthy is 2'
Assert-Equal '3' (Get-ArrayHealthValue 'Unknown') 'Unknown is 3'
Assert-Equal '3' (Get-ArrayHealthValue $null) 'no health is 3'

# Windows could not be asked: reported as collect_ok 0, no array series.
$text = New-DriveHealthText -HostName 'gaming-pc' -Timestamp 1 -Drives @() -ArrayError 'boom'
$s = Get-Samples $text
Assert-Equal '0' $s['gaming_pc_array_collect_ok{host="gaming-pc"}'] 'a failed array read is collect_ok 0'
Assert-Equal '0' (@($s.Keys | Where-Object { $_ -like 'gaming_pc_array_health*' }).Count) 'and no array series'

# A machine that reports drives only (no array parameters) writes no array series.
$s = Get-Samples (New-DriveHealthText -HostName 'gaming-pc' -Timestamp 1 -Drives @())
Assert-Equal '0' (@($s.Keys | Where-Object { $_ -like 'gaming_pc_array*' }).Count) 'no array parameters, no array series'

# Label values are escaped, and an empty one is left out.
$line = Format-PrometheusSample -Name 'm' -Value 1.5 -Labels @{ a = 'x"y\z'; b = '' }
Assert-Equal 'm{a="x\"y\\z"} 1.5' $line 'label escaping and empty labels'

# A counter that arrives as a string of digits is still a number.
Assert-Equal '12' (Get-SmartNumber '12') 'digit string counter'
Assert-Equal '' ([string](Get-SmartNumber 'n/a')) 'text is not a number'

# The whole script, against a stand-in smartctl that answers like the real one:
# the fixtures as JSON, and exit status 4 for the failing drive (smartctl's exit
# code is a bit field, and a drive with errors sets bits). Needs a shell, so it
# runs where the pull request checks run and is skipped on Windows.
if (-not $IsWindows) {
    $fixtures = Join-Path $PSScriptRoot 'fixtures' 'smartctl'
    $fake = Join-Path ([IO.Path]::GetTempPath()) ("fake-smartctl-{0}.sh" -f [guid]::NewGuid())
    try {
        Set-Content -LiteralPath $fake -Value @"
#!/bin/sh
case "`$*" in
  *--scan*) cat '$fixtures/scan.json' ;;
  *nvme0) cat '$fixtures/nvme_healthy.json' ;;
  *nvme1) cat '$fixtures/nvme_failing.json'; exit 4 ;;
esac
"@
        & chmod +x $fake
        $pwsh = (Get-Process -Id $PID).Path
        $out = & $pwsh -NoProfile -File (Join-Path $PSScriptRoot '..' 'src' 'drive-health.ps1') -SmartctlPath $fake -StorageJsonPath (Join-Path $PSScriptRoot 'fixtures' 'storage' 'amd_raid_healthy.json') -Print
        $s = Get-Samples ($out -join "`n")
        Assert-Equal '2' $s['nvme_health_drives{host="gaming-pc"}'] 'end to end: two NVMe drives, the SATA one is skipped'
        Assert-Equal '3' $s["nvme_smart_percentage_used$healthy"] 'end to end: wear of the healthy drive'
        Assert-Equal '89' $s["nvme_smart_percentage_used$failing"] 'end to end: a non-zero smartctl exit code still reports the drive'
        Assert-Equal '1' $s['nvme_health_collect_ok{device="nvme1",host="gaming-pc"}'] 'end to end: the failing drive was read'

        # smartctl itself failing: one unreadable "drive", no stale series.
        Set-Content -LiteralPath $fake -Value "#!/bin/sh`nexit 1"
        $out = & $pwsh -NoProfile -File (Join-Path $PSScriptRoot '..' 'src' 'drive-health.ps1') -SmartctlPath $fake -Print 2>$null
        $s = Get-Samples ($out -join "`n")
        Assert-Equal '0' $s['nvme_health_collect_ok{device="scan",host="gaming-pc"}'] 'end to end: a smartctl that prints nothing is collect_ok 0'
        Assert-Equal '0' (@($s.Keys | Where-Object { $_ -like 'nvme_smart_*' }).Count) 'end to end: and no SMART series'

        # The AMD RAID machine: a scan of two scsi devices, and the array read
        # from a storage fixture (Get-PhysicalDisk does not exist here).
        Set-Content -LiteralPath $fake -Value @"
#!/bin/sh
case "`$*" in
  *--scan*) cat '$fixtures/scan_amd_raid.json' ;;
  *) exit 2 ;;
esac
"@
        foreach ($case in @(@('amd_raid_healthy.json', '0'), @('amd_raid_degraded.json', '1'))) {
            $out = & $pwsh -NoProfile -File (Join-Path $PSScriptRoot '..' 'src' 'drive-health.ps1') -SmartctlPath $fake -StorageJsonPath (Join-Path $PSScriptRoot 'fixtures' 'storage' $case[0]) -Print
            $s = Get-Samples ($out -join "`n")
            Assert-Equal '0' $s['nvme_health_drives{host="gaming-pc"}'] "end to end ($($case[0])): scsi devices are not drives"
            Assert-Equal '0' (@($s.Keys | Where-Object { $_ -like 'nvme_health_collect_ok*' }).Count) "end to end ($($case[0])): and not a failure"
            Assert-Equal $case[1] $s['gaming_pc_array_health_status{array="AMD-RAID Array 1",bus_type="RAID",host="gaming-pc",media_type="SSD"}'] "end to end ($($case[0])): array health"
            Assert-Equal '1' $s['gaming_pc_array_collect_ok{host="gaming-pc"}'] "end to end ($($case[0])): array was read"
        }
    }
    finally {
        Remove-Item -LiteralPath $fake -Force -ErrorAction SilentlyContinue
    }
}

if ($script:Failures -gt 0) {
    Write-Host "$script:Failures failed"
    exit 1
}
Write-Host 'all passed'
