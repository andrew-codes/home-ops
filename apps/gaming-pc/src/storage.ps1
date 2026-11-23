# Builds the games drive: the two spare NVMe drives striped into one Windows
# Storage Spaces drive (Simple layout, 2 columns, no redundancy - a RAID 0
# equivalent, about 4 TB). See README.md#games-drive-and-steam-library and
# docs/rebuild-runbook.md for the why and the rebuild procedure.
#
# THIS SCRIPT CAN WIPE DISKS, so it is built around refusing:
#
#   * It only ever considers physical disks that are NVMe, not the boot or system
#     disk, not USB or removable.
#   * If the pool, its virtual disk and the drive letter already exist, it changes
#     nothing. If Windows re-detected the pool after a reinstall (the disks keep
#     the pool metadata), it attaches and onlines the existing virtual disk and
#     assigns the drive letter. It never removes or recreates a pool.
#   * It creates a pool only when there are exactly two eligible NVMe drives and
#     they are empty (CanPool). Anything else - the current BIOS RAID machine, a
#     third spare drive, drives with old partitions - prints a warning with the
#     reason and the remedy and changes nothing, without failing the deploy.
#   * Drives with old partitions are wiped only with -AllowWipe, and the script
#     names every disk it would wipe when refusing.
#   * -WhatIf prints what it would do, including the disks, and touches nothing.
#
# -RequireArray turns "no array" into a failure (exit 1) for an owner who wants
# the deploy to stop when the games drive is not there.
#
# Run elevated by scripts/deploy.yml. The last line, RESULT, is what deploy.yml
# reads to decide changed or failed, so keep its shape (same as software.ps1).

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidatePattern('^[A-Za-z0-9 _.-]{1,64}$')]
    [string]$PoolName = 'GamesPool',
    [ValidatePattern('^[A-Za-z0-9 _.-]{1,64}$')]
    [string]$VirtualDiskName = 'Games',
    [ValidatePattern('^[A-Za-z]$')]
    [string]$DriveLetter = 'G',
    [ValidateSet('NTFS', 'ReFS')]
    [string]$FileSystem = 'NTFS',
    [ValidateRange(4096, 16777216)]
    [int]$Interleave = 262144,
    [ValidateRange(2, 8)]
    [int]$NumberOfColumns = 2,
    [switch]$AllowWipe,
    [switch]$RequireArray
)

$ErrorActionPreference = 'Stop'

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path $ScriptDir 'logging.ps1')

$script:Changed = 0
$script:Failures = New-Object System.Collections.Generic.List[string]
$script:Warnings = New-Object System.Collections.Generic.List[string]

function Add-StorageWarning {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Log "  WARNING $Message"
    $script:Warnings.Add($Message)
}

function Test-Apply {
    <#
    .SYNOPSIS
        False under -WhatIf, after saying what would have happened.
    #>
    param([string]$Target, [string]$Action)
    if ($WhatIfPreference) {
        Write-Log "  WHATIF: would $Action ($Target)"
        return $false
    }
    return $true
}

function Format-DiskLabel {
    param($Disk)
    $size = if ($Disk.Size) { '{0:N0} GB' -f ($Disk.Size / 1GB) } else { 'unknown size' }
    return "disk $($Disk.DeviceId) '$($Disk.FriendlyName)' serial $($Disk.SerialNumber) ($size)"
}

# ---------------------------------------------------------------------------
# What is on the machine
# ---------------------------------------------------------------------------

function Get-GamesPool {
    <#
    .SYNOPSIS
        The named pool if Windows knows it, else $null. Never creates anything.
    #>
    param([Parameter(Mandatory = $true)][string]$Name)
    return Get-StoragePool -FriendlyName $Name -ErrorAction SilentlyContinue |
        Where-Object { -not $_.IsPrimordial } |
        Select-Object -First 1
}

function Get-DiskClassification {
    <#
    .SYNOPSIS
        Sorts every physical disk into the one reason it is or is not a candidate.
    .DESCRIPTION
        Returns one object per physical disk with Disk, Class and Reason. Class is
        one of: Clean (empty NVMe, poolable), Dirty (NVMe with old partitions or a
        file system, not poolable until cleared), PoolMember, Excluded.
        Excluded covers everything the script must never touch: not NVMe, boot or
        system disk, USB or removable, or unhealthy.
    #>
    foreach ($physical in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
        $result = @{ Disk = $physical; Class = 'Excluded'; Reason = '' }

        if ("$($physical.BusType)" -ne 'NVMe') {
            $result.Reason = "bus type is $($physical.BusType), not NVMe"
        }
        elseif ("$($physical.CannotPoolReason)" -match 'Removable') {
            $result.Reason = 'removable media'
        }
        elseif ("$($physical.CannotPoolReason)" -match 'In a Pool') {
            $result.Class = 'PoolMember'
            $result.Reason = 'already in a storage pool'
        }
        else {
            # Pool members are hidden from Get-Disk, so this is only reached for
            # drives that are not in a pool.
            $disk = Get-Disk -Number ([int]$physical.DeviceId) -ErrorAction SilentlyContinue
            if (-not $disk) {
                $result.Reason = 'Windows cannot read its disk record'
            }
            elseif ($disk.IsBoot -or $disk.IsSystem) {
                $result.Reason = 'it is the boot or system disk'
            }
            elseif ($disk.BusType -eq 'USB' -or $disk.IsRemovable) {
                $result.Reason = 'it is USB or removable'
            }
            elseif ($physical.CanPool) {
                $result.Class = 'Clean'
                $result.Reason = 'empty and poolable'
            }
            elseif (@(Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue).Count -gt 0) {
                $result.Class = 'Dirty'
                $result.Reason = 'it has existing partitions'
            }
            elseif ($disk.PartitionStyle -ne 'RAW') {
                $result.Class = 'Dirty'
                $result.Reason = "it has a $($disk.PartitionStyle) partition table"
            }
            else {
                $result.Reason = "Windows reports it cannot be pooled ($($physical.CannotPoolReason))"
            }
        }

        [pscustomobject]$result
    }
}

# ---------------------------------------------------------------------------
# The existing pool: attach, online, assign the letter. Never recreate.
# ---------------------------------------------------------------------------

function Mount-ExistingGamesDrive {
    <#
    .OUTPUTS
        'Installed' when it changed anything, 'Present' when it did not.
    #>
    param(
        [Parameter(Mandatory = $true)]$Pool,
        [Parameter(Mandatory = $true)][string]$VirtualDiskName,
        [Parameter(Mandatory = $true)][string]$DriveLetter
    )

    $changed = $false
    $label = "pool '$($Pool.FriendlyName)'"

    if ($Pool.IsReadOnly) {
        # Windows opens a pool it found on foreign disks read-only.
        if (Test-Apply $label 'make writable') {
            Set-StoragePool -FriendlyName $Pool.FriendlyName -IsReadOnly $false
        }
        Write-Log "  $label : made writable"
        $changed = $true
    }

    $virtualDisk = Get-VirtualDisk -FriendlyName $VirtualDiskName -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $virtualDisk) {
        Add-StorageWarning ("$label exists but has no virtual disk named '$VirtualDiskName'. Nothing was changed. " +
            'Remedy: open Storage Spaces in Settings > System > Storage, or run Get-VirtualDisk, and set ' +
            '-VirtualDiskName to the existing name; the script will not create a disk inside a pool it did not make.')
        return 'Present'
    }

    if ("$($virtualDisk.OperationalStatus)" -match 'Detached' -or "$($virtualDisk.IsManualAttach)" -eq 'True') {
        if (Test-Apply "virtual disk '$VirtualDiskName'" 'attach') {
            Connect-VirtualDisk -FriendlyName $VirtualDiskName
        }
        Write-Log "  virtual disk '$VirtualDiskName': attached"
        $changed = $true
    }

    $disk = Get-Disk -VirtualDisk $virtualDisk -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $disk) {
        if ($WhatIfPreference) { return 'Installed' }
        throw "virtual disk '$VirtualDiskName' has no disk after attaching it"
    }

    if ($disk.IsOffline) {
        if (Test-Apply "virtual disk '$VirtualDiskName'" 'bring online') {
            Set-Disk -Number $disk.Number -IsOffline $false
        }
        Write-Log "  virtual disk '$VirtualDiskName': brought online"
        $changed = $true
    }
    if ($disk.IsReadOnly) {
        if (Test-Apply "virtual disk '$VirtualDiskName'" 'make writable') {
            Set-Disk -Number $disk.Number -IsReadOnly $false
        }
        Write-Log "  virtual disk '$VirtualDiskName': made writable"
        $changed = $true
    }

    $partition = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue |
        Where-Object { $_.Type -eq 'Basic' } | Sort-Object Size -Descending | Select-Object -First 1
    if (-not $partition) {
        Add-StorageWarning ("virtual disk '$VirtualDiskName' has no data partition, so there is nothing to give the letter ${DriveLetter}: to. " +
            'Nothing was formatted. Remedy: look at the disk in Disk Management; if it is meant to be empty, remove the virtual disk deliberately and re-run.')
        return $(if ($changed) { 'Installed' } else { 'Present' })
    }

    if ("$($partition.DriveLetter)" -ne $DriveLetter) {
        $holder = Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue
        if ($holder) {
            Add-StorageWarning ("drive letter ${DriveLetter}: is held by another volume ('$($holder.FileSystemLabel)'), so the games drive keeps " +
                "letter '$($partition.DriveLetter)'. Nothing was changed. Remedy: free ${DriveLetter}: in Disk Management and re-run, or set -DriveLetter to a free letter.")
            return $(if ($changed) { 'Installed' } else { 'Present' })
        }
        if (Test-Apply "partition $($partition.PartitionNumber) of disk $($disk.Number)" "assign drive letter $DriveLetter") {
            Set-Partition -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber -NewDriveLetter $DriveLetter
        }
        Write-Log "  games drive: assigned ${DriveLetter}:"
        $changed = $true
    }

    if (-not $changed) {
        Write-Log "  games drive ${DriveLetter}: already present ($label, virtual disk '$VirtualDiskName')"
        return 'Present'
    }
    return 'Installed'
}

# ---------------------------------------------------------------------------
# Creating the array
# ---------------------------------------------------------------------------

function New-GamesDrive {
    <#
    .OUTPUTS
        'Installed' when the array was created, 'Present' when it deliberately
        did nothing (a warning says why).
    #>
    param(
        [Parameter(Mandatory = $true)][object[]]$Classified,
        [Parameter(Mandatory = $true)][string]$PoolName,
        [Parameter(Mandatory = $true)][string]$VirtualDiskName,
        [Parameter(Mandatory = $true)][string]$DriveLetter,
        [Parameter(Mandatory = $true)][string]$FileSystem,
        [Parameter(Mandatory = $true)][int]$Interleave,
        [Parameter(Mandatory = $true)][int]$NumberOfColumns,
        [bool]$AllowWipe
    )

    $candidates = @($Classified | Where-Object { $_.Class -in 'Clean', 'Dirty' })
    $poolMembers = @($Classified | Where-Object { $_.Class -eq 'PoolMember' })

    Write-Log '  NVMe drives seen:'
    foreach ($entry in $Classified) {
        if ("$($entry.Disk.BusType)" -eq 'NVMe') {
            Write-Log "    $(Format-DiskLabel $entry.Disk): $($entry.Class) - $($entry.Reason)"
        }
    }

    if ($poolMembers.Count -gt 0) {
        $names = ($poolMembers | ForEach-Object { Format-DiskLabel $_.Disk }) -join '; '
        Add-StorageWarning ("an NVMe drive is already in a storage pool that is not '$PoolName' ($names). Nothing was changed. " +
            "Remedy: if that pool is the games array under another name, re-run with -PoolName set to it; otherwise remove it deliberately in Settings > System > Storage > Storage Spaces.")
        return 'Present'
    }

    if ($candidates.Count -ne 2) {
        $found = if ($candidates.Count -eq 0) { 'none' } else { ($candidates | ForEach-Object { Format-DiskLabel $_.Disk }) -join '; ' }
        Add-StorageWarning ("expected exactly 2 spare NVMe drives (not the boot disk) to stripe, found $($candidates.Count) ($found). Nothing was changed. " +
            'Remedy: with BIOS RAID on, Windows sees the array as one drive and the members are hidden - switch the BIOS to NVMe mode (this erases the array), ' +
            'install Windows on one drive, and re-run. With a different number of spare drives, remove or add drives so exactly two remain. ' +
            'See apps/gaming-pc/docs/rebuild-runbook.md.')
        return 'Present'
    }

    $dirty = @($candidates | Where-Object { $_.Class -eq 'Dirty' })
    if ($dirty.Count -gt 0 -and -not $AllowWipe) {
        $names = ($dirty | ForEach-Object { "$(Format-DiskLabel $_.Disk) ($($_.Reason))" }) -join '; '
        Add-StorageWarning ("REFUSING to wipe: these drives hold old data and would be erased to build the array: $names. Nothing was changed. " +
            'Remedy: if that data is disposable, re-run the deploy with GAMING_PC_STORAGE_WIPE=true (yarn nx deploy gaming-pc); ' +
            'otherwise back it up first.')
        return 'Present'
    }

    $letterHolder = Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue
    if ($letterHolder) {
        Add-StorageWarning ("drive letter ${DriveLetter}: is already used by volume '$($letterHolder.FileSystemLabel)'. Nothing was changed. " +
            'Remedy: free the letter in Disk Management or choose another with -DriveLetter.')
        return 'Present'
    }

    $diskList = ($candidates | ForEach-Object { Format-DiskLabel $_.Disk }) -join '; '
    Write-Log "  WOULD USE: $diskList"
    if ($dirty.Count -gt 0) {
        $wipeList = ($dirty | ForEach-Object { Format-DiskLabel $_.Disk }) -join '; '
        Write-Log "  WOULD WIPE (old data, -AllowWipe given): $wipeList"
    }

    if (-not (Test-Apply $diskList "create pool '$PoolName', Simple virtual disk '$VirtualDiskName' ($NumberOfColumns columns), $FileSystem volume ${DriveLetter}:")) {
        return 'Installed'
    }

    foreach ($entry in $dirty) {
        Write-Log "  wiping $(Format-DiskLabel $entry.Disk)"
        Clear-Disk -Number ([int]$entry.Disk.DeviceId) -RemoveData -RemoveOEM -Confirm:$false
    }

    # Re-read: clearing a disk is what makes it poolable. Only these two drives
    # go into the pool, matched by the identity they were chosen under.
    $ids = @($candidates | ForEach-Object { $_.Disk.UniqueId })
    $poolable = @(Get-PhysicalDisk -CanPool $true | Where-Object { $_.UniqueId -in $ids })
    if ($poolable.Count -ne 2) {
        throw "expected both chosen drives to be poolable after preparing them, found $($poolable.Count)"
    }

    $subsystem = Get-StorageSubSystem -FriendlyName 'Windows Storage*' | Select-Object -First 1
    Write-Log "  creating pool '$PoolName'"
    New-StoragePool -FriendlyName $PoolName -StorageSubSystemUniqueId $subsystem.UniqueId -PhysicalDisks $poolable | Out-Null

    Write-Log "  creating virtual disk '$VirtualDiskName' (Simple, $NumberOfColumns columns, interleave $Interleave)"
    New-VirtualDisk -StoragePoolFriendlyName $PoolName -FriendlyName $VirtualDiskName `
        -ResiliencySettingName Simple -NumberOfColumns $NumberOfColumns -Interleave $Interleave `
        -ProvisioningType Fixed -UseMaximumSize | Out-Null

    $disk = Get-Disk -VirtualDisk (Get-VirtualDisk -FriendlyName $VirtualDiskName)
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT
    $partition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter $DriveLetter
    Format-Volume -Partition $partition -FileSystem $FileSystem -NewFileSystemLabel $VirtualDiskName -Confirm:$false | Out-Null

    Write-Log "  games drive ${DriveLetter}: created"
    return 'Installed'
}

# ---------------------------------------------------------------------------

function Invoke-GamesStorage {
    <#
    .SYNOPSIS
        The whole decision: existing pool, new pool, or do nothing.
    #>
    $pool = Get-GamesPool -Name $PoolName
    if ($pool) {
        Write-Log "pool '$PoolName' already exists; attaching, never recreating"
        return Mount-ExistingGamesDrive -Pool $pool -VirtualDiskName $VirtualDiskName -DriveLetter $DriveLetter
    }

    $classified = @(Get-DiskClassification)
    return New-GamesDrive -Classified $classified -PoolName $PoolName -VirtualDiskName $VirtualDiskName `
        -DriveLetter $DriveLetter -FileSystem $FileSystem -Interleave $Interleave `
        -NumberOfColumns $NumberOfColumns -AllowWipe $AllowWipe.IsPresent
}

# Dot-sourcing (the tests do) defines the functions and runs nothing.
if ($MyInvocation.InvocationName -eq '.') { return }

Write-Log "=== storage.ps1 pool=$PoolName disk=$VirtualDiskName letter=$DriveLetter wipe=$($AllowWipe.IsPresent) require=$($RequireArray.IsPresent) whatif=$($WhatIfPreference) ==="

$arrayState = 'Missing'
try {
    $outcome = Invoke-GamesStorage
    if ($outcome -eq 'Installed' -and -not $WhatIfPreference) { $script:Changed++ }
    $arrayState = if (Test-Path "${DriveLetter}:\") { 'Ready' } else { 'Missing' }
}
catch {
    $message = "storage : $($_.Exception.Message)"
    Write-Log "  FAILED $message"
    $script:Failures.Add($message)
}

if ($arrayState -ne 'Ready' -and -not $WhatIfPreference) {
    if ($RequireArray) {
        $script:Failures.Add("the games drive ${DriveLetter}: is not present and -RequireArray is set")
    }
    elseif ($script:Failures.Count -eq 0 -and $script:Warnings.Count -eq 0) {
        Add-StorageWarning "the games drive ${DriveLetter}: is not present."
    }
}

foreach ($warning in $script:Warnings) {
    Write-Log "SUMMARY warning: $warning"
}
foreach ($failure in $script:Failures) {
    Write-Log "SUMMARY failure: $failure"
}

# Parsed by scripts/deploy.yml to decide changed/failed, so keep the shape.
Write-Log ("RESULT changed={0} warnings={1} failures={2} array={3}" -f `
        $script:Changed, $script:Warnings.Count, $script:Failures.Count, $arrayState)

if ($script:Failures.Count -gt 0) {
    exit 1
}
exit 0
