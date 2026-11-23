# Turns `smartctl -j` output into the Prometheus text the Hardware health
# dashboard reads. Dot-sourced by drive-health.ps1 and by tests/drive-health.test.ps1.
#
# The series are named and labelled exactly like the Proxmox host's NVMe
# collector (apps/pve/src/deploy/files/nvme-health.py): nvme_smart_* with the
# labels host, device, model and serial. That is what lets the dashboard and its
# Machine filter show this machine with no query of its own. The job label
# (gaming-pc) is added by vmagent and is what the alert rules tell the two apart
# by, see deployments/production/alerting.
#
# Only NVMe drives are reported. A SATA SSD or hard disk has no standard wear or
# spare field in smartctl's JSON (each vendor names its own attribute), so it is
# left out rather than guessed at; README.md#drive-health says so.
#
# A machine whose NVMe drives are combined into one array in the BIOS (AMD RAID)
# exposes only the array to Windows: smartctl --scan lists scsi devices and no
# nvme one, and smartctl cannot read per-drive SMART through the RAID driver. That
# is a normal state, not a failure. What Windows can read is the array's health
# (Get-PhysicalDisk), so that is reported too, as gaming_pc_array_* series, with
# the free space of the fixed volumes. See ConvertTo-ArrayMetricLines.

# Metric name -> field in nvme_smart_health_information_log of `smartctl -j`.
$script:DriveSmartFields = [ordered]@{
    nvme_smart_critical_warning                 = 'critical_warning'
    nvme_smart_percentage_used                  = 'percentage_used'
    nvme_smart_available_spare_percent          = 'available_spare'
    nvme_smart_available_spare_threshold_percent = 'available_spare_threshold'
    nvme_smart_media_errors                     = 'media_errors'
    nvme_smart_error_log_entries                = 'num_err_log_entries'
    nvme_smart_unsafe_shutdowns                 = 'unsafe_shutdowns'
    nvme_smart_power_on_hours                   = 'power_on_hours'
    nvme_smart_data_units_written               = 'data_units_written'
    nvme_smart_data_units_read                  = 'data_units_read'
    nvme_smart_warning_temperature_seconds      = 'warning_temp_time'
    nvme_smart_critical_temperature_seconds     = 'critical_comp_time'
}

function ConvertTo-PrometheusLabelValue {
    param([AllowNull()][object]$Value)
    return ([string]$Value).Replace('\', '\\').Replace('"', '\"').Replace("`n", '\n').Replace("`r", '')
}

function Format-PrometheusSample {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][double]$Value,
        [hashtable]$Labels = @{}
    )

    $pairs = foreach ($key in ($Labels.Keys | Sort-Object)) {
        if ($null -ne $Labels[$key] -and "$($Labels[$key])" -ne '') {
            '{0}="{1}"' -f $key, (ConvertTo-PrometheusLabelValue $Labels[$key])
        }
    }
    $text = if ($pairs) { '{' + ($pairs -join ',') + '}' } else { '' }
    return '{0}{1} {2}' -f $Name, $text, $Value.ToString([Globalization.CultureInfo]::InvariantCulture)
}

function Get-SmartNumber {
    # smartctl prints counters as numbers; a 128-bit counter can be an object
    # with `lo` and `hi`. Anything else is not a number.
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or $Value -is [bool]) { return $null }
    if ($Value -is [ValueType] -and $Value -isnot [string]) { return [double]$Value }
    if ($Value -is [string] -and $Value -match '^\d+$') { return [double]$Value }
    return $null
}

function Get-DriveDeviceName {
    # "/dev/nvme0" -> "nvme0", matching the pve collector's device label.
    param([Parameter(Mandatory = $true)][string]$Name)
    return $Name -replace '^/dev/', ''
}

function Get-NvmeScanDevices {
    # The NVMe entries of the parsed `smartctl --scan --json`, whatever else the
    # machine has (SATA drives, USB bridges).
    param([Parameter(Mandatory = $true)][object]$Scan)
    return @($Scan.devices | Where-Object { $_.type -eq 'nvme' })
}

function ConvertTo-DriveMetricLines {
    <#
    .SYNOPSIS
        The sample lines for one drive, from the parsed JSON of `smartctl -j -a`.
    .DESCRIPTION
        Throws when the JSON has no NVMe health log, which is how an unreadable
        drive reaches the caller as nvme_health_collect_ok 0.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Smart,
        [Parameter(Mandatory = $true)][string]$HostName
    )

    $log = $Smart.nvme_smart_health_information_log
    if (-not $log) {
        throw 'smartctl returned no nvme_smart_health_information_log'
    }
    $labels = @{
        host   = $HostName
        device = Get-DriveDeviceName $Smart.device.name
        model  = $Smart.model_name
        serial = $Smart.serial_number
    }

    $lines = [Collections.Generic.List[string]]::new()
    foreach ($metric in $script:DriveSmartFields.Keys) {
        $field = $script:DriveSmartFields[$metric]
        $value = Get-SmartNumber $log.$field
        if ($null -ne $value) {
            $lines.Add((Format-PrometheusSample -Name $metric -Value $value -Labels $labels))
        }
    }
    # smartctl reports the composite temperature in Celsius already.
    $temperature = Get-SmartNumber $log.temperature
    if ($null -ne $temperature) {
        $lines.Add((Format-PrometheusSample -Name 'nvme_smart_temperature_celsius' -Value $temperature -Labels $labels))
    }
    $capacity = Get-SmartNumber $Smart.user_capacity.bytes
    if ($null -ne $capacity) {
        $lines.Add((Format-PrometheusSample -Name 'nvme_capacity_bytes' -Value $capacity -Labels $labels))
    }
    return $lines
}

function Get-ArrayHealthValue {
    # Get-PhysicalDisk HealthStatus as a number: 0 Healthy, 1 Warning,
    # 2 Unhealthy, 3 Unknown (or anything else, so a new value is not silently OK).
    param([AllowNull()][object]$HealthStatus)
    switch ("$HealthStatus") {
        'Healthy' { return 0 }
        'Warning' { return 1 }
        'Unhealthy' { return 2 }
        default { return 3 }
    }
}

function Select-ArrayDisks {
    # The disks worth reporting: not a USB stick or a card. The AMD RAID array
    # shows up as one physical disk with BusType RAID.
    param([AllowNull()][AllowEmptyCollection()][object[]]$Disks)
    $excluded = 'USB', 'SD', 'MMC', 'Virtual', 'File Backed Virtual'
    return @($Disks | Where-Object { $_ -and ("$($_.BusType)" -notin $excluded) })
}

function ConvertTo-ArrayMetricLines {
    <#
    .SYNOPSIS
        The sample lines for the disks and volumes Windows reports.
    .DESCRIPTION
        Disks are objects with FriendlyName, HealthStatus, OperationalStatus,
        Size, BusType and MediaType (what Get-PhysicalDisk returns); volumes have
        DriveLetter, Size, SizeRemaining and IsSystem. The serial number is not
        read: the series are labelled by the array's name only.
    #>
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$Disks,
        [AllowNull()][AllowEmptyCollection()][object[]]$Volumes,
        [Parameter(Mandatory = $true)][string]$HostName
    )

    $lines = [Collections.Generic.List[string]]::new()
    foreach ($disk in (Select-ArrayDisks $Disks)) {
        $labels = @{ host = $HostName; array = $disk.FriendlyName; bus_type = "$($disk.BusType)"; media_type = "$($disk.MediaType)" }
        $lines.Add((Format-PrometheusSample -Name 'gaming_pc_array_health_status' -Value (Get-ArrayHealthValue $disk.HealthStatus) -Labels $labels))
        foreach ($status in @($disk.OperationalStatus)) {
            $lines.Add((Format-PrometheusSample -Name 'gaming_pc_array_operational_status_info' -Value 1 -Labels @{ host = $HostName; array = $disk.FriendlyName; status = "$status" }))
        }
        $size = Get-SmartNumber $disk.Size
        if ($null -ne $size) {
            $lines.Add((Format-PrometheusSample -Name 'gaming_pc_array_size_bytes' -Value $size -Labels @{ host = $HostName; array = $disk.FriendlyName }))
        }
    }
    foreach ($volume in @($Volumes | Where-Object { $_ })) {
        $labels = @{ host = $HostName; volume = "$($volume.DriveLetter):"; role = $(if ($volume.IsSystem) { 'system' } else { 'data' }) }
        $size = Get-SmartNumber $volume.Size
        $free = Get-SmartNumber $volume.SizeRemaining
        if ($null -ne $size -and $null -ne $free) {
            $lines.Add((Format-PrometheusSample -Name 'gaming_pc_volume_size_bytes' -Value $size -Labels $labels))
            $lines.Add((Format-PrometheusSample -Name 'gaming_pc_volume_free_bytes' -Value $free -Labels $labels))
        }
    }
    return $lines
}

function New-DriveHealthText {
    <#
    .SYNOPSIS
        The whole textfile: one block per drive, the array and volumes, then the
        drive count and timestamp.
    .PARAMETER Drives
        One hashtable per drive: Device (the name from `smartctl --scan`) and
        either Smart (the parsed JSON) or Error (why it could not be read).
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Drives,
        [Parameter(Mandatory = $true)][string]$HostName,
        [Parameter(Mandatory = $true)][long]$Timestamp,
        # What Get-PhysicalDisk and Get-Volume returned, see ConvertTo-ArrayMetricLines,
        # or why they could not be read. Omit for a machine that reports drives only.
        [object[]]$ArrayDisks,
        [object[]]$Volumes,
        [string]$ArrayError,
        [scriptblock]$OnError = { param($Message) }
    )

    $lines = [Collections.Generic.List[string]]::new()
    # A machine with no NVMe drive has nothing to report, which is not a failure.
    $lines.Add((Format-PrometheusSample -Name 'nvme_health_drives' -Value $Drives.Count -Labels @{ host = $HostName }))
    foreach ($drive in $Drives) {
        $device = Get-DriveDeviceName $drive.Device
        $ok = 1
        try {
            if ($drive.Error) { throw $drive.Error }
            foreach ($line in (ConvertTo-DriveMetricLines -Smart $drive.Smart -HostName $HostName)) { $lines.Add($line) }
        }
        catch {
            & $OnError "${device}: $($_.Exception.Message)"
            $ok = 0
        }
        $lines.Add((Format-PrometheusSample -Name 'nvme_health_collect_ok' -Value $ok -Labels @{ host = $HostName; device = $device }))
    }
    if ($PSBoundParameters.ContainsKey('ArrayDisks') -or $ArrayError) {
        $arrayOk = 1
        if ($ArrayError) {
            & $OnError "array: $ArrayError"
            $arrayOk = 0
        }
        else {
            foreach ($line in (ConvertTo-ArrayMetricLines -Disks $ArrayDisks -Volumes $Volumes -HostName $HostName)) { $lines.Add($line) }
        }
        $lines.Add((Format-PrometheusSample -Name 'gaming_pc_array_collect_ok' -Value $arrayOk -Labels @{ host = $HostName }))
    }
    # Written last, so it only appears when the run got this far. It is not
    # nvme_health_push_timestamp_seconds: the pve alert that watches that
    # heartbeat must not be satisfied by this machine.
    $lines.Add((Format-PrometheusSample -Name 'gaming_pc_drive_health_timestamp_seconds' -Value $Timestamp -Labels @{ host = $HostName }))
    return ($lines -join "`n") + "`n"
}
