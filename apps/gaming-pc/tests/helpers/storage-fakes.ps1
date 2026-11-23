# Fake Storage cmdlets for tests/storage.test.ps1. Dot-source it, then set
# $global:FakeMachine with New-FakeMachine. Functions shadow the real cmdlets, so
# nothing here (or in CI, which has no Windows disks) ever touches a disk. Every
# mutating cmdlet only records the call in $global:FakeCalls.

function New-FakeNvme {
    param(
        [Parameter(Mandatory = $true)][int]$Number,
        [string]$Name = "Samsung SSD 990 PRO 2TB",
        [string]$BusType = 'NVMe',
        [bool]$CanPool = $true,
        [bool]$IsBoot = $false,
        [bool]$IsSystem = $false,
        [bool]$IsRemovable = $false,
        [string]$CannotPoolReason = '',
        [int]$Partitions = 0,
        [string]$PartitionStyle = 'RAW',
        [bool]$InPool = $false,
        [long]$Size = 2000398934016
    )
    @{
        Physical   = [pscustomobject]@{
            DeviceId = "$Number"; FriendlyName = $Name; SerialNumber = "SER$Number"; UniqueId = "uid-$Number"
            BusType = $BusType; CanPool = $CanPool; CannotPoolReason = $(if ($InPool) { 'In a Pool' } else { $CannotPoolReason }); Size = $Size
        }
        Disk       = [pscustomobject]@{
            Number = $Number; IsBoot = $IsBoot; IsSystem = $IsSystem; IsRemovable = $IsRemovable
            BusType = $BusType; PartitionStyle = $PartitionStyle
        }
        Partitions = $Partitions
        InPool     = $InPool
    }
}

function New-FakeMachine {
    param(
        [object[]]$Disks = @(),
        $Pool = $null,
        $VirtualDisk = $null,
        $VirtualDiskDisk = $null,
        [object[]]$VirtualDiskPartitions = @(),
        [object[]]$Volumes = @()
    )
    @{ Disks = $Disks; Pool = $Pool; VirtualDisk = $VirtualDisk; VirtualDiskDisk = $VirtualDiskDisk
       VirtualDiskPartitions = $VirtualDiskPartitions; Volumes = $Volumes }
}

function Get-FakeCall {
    param([string]$Name)
    @($global:FakeCalls | Where-Object { $_.Name -eq $Name })
}

$global:FakeCalls = New-Object System.Collections.Generic.List[object]
function Add-FakeCall { param($Name, $Arguments) $global:FakeCalls.Add([pscustomobject]@{ Name = $Name; Arguments = $Arguments }) }

function Get-PhysicalDisk {
    [CmdletBinding()] param($CanPool)
    $all = @($global:FakeMachine.Disks | ForEach-Object { $_.Physical })
    if ($PSBoundParameters.ContainsKey('CanPool')) { return @($all | Where-Object { $_.CanPool -eq $CanPool }) }
    $all
}
function Get-Disk {
    [CmdletBinding()] param($Number, $VirtualDisk)
    if ($VirtualDisk) { return $global:FakeMachine.VirtualDiskDisk }
    $global:FakeMachine.Disks | Where-Object { -not $_.InPool -and $_.Disk.Number -eq $Number } | ForEach-Object { $_.Disk }
}
function Get-Partition {
    [CmdletBinding()] param($DiskNumber)
    if ($global:FakeMachine.VirtualDiskDisk -and $DiskNumber -eq $global:FakeMachine.VirtualDiskDisk.Number) {
        return $global:FakeMachine.VirtualDiskPartitions
    }
    $disk = $global:FakeMachine.Disks | Where-Object { $_.Disk.Number -eq $DiskNumber }
    for ($n = 1; $n -le [int]$disk.Partitions; $n++) { [pscustomobject]@{ PartitionNumber = $n; Type = 'Basic'; Size = 1GB; DriveLetter = [char]0 } }
}
function Get-StoragePool {
    [CmdletBinding()] param($FriendlyName)
    [pscustomobject]@{ FriendlyName = 'Primordial'; IsPrimordial = $true; IsReadOnly = $false }
    if ($global:FakeMachine.Pool -and $global:FakeMachine.Pool.FriendlyName -eq $FriendlyName) { $global:FakeMachine.Pool }
}
function Get-VirtualDisk {
    [CmdletBinding()] param($FriendlyName)
    if ($global:FakeMachine.VirtualDisk -and $global:FakeMachine.VirtualDisk.FriendlyName -eq $FriendlyName) { $global:FakeMachine.VirtualDisk }
}
function Get-Volume {
    [CmdletBinding()] param($DriveLetter)
    $global:FakeMachine.Volumes | Where-Object { $_.DriveLetter -eq $DriveLetter }
}
function Get-StorageSubSystem { [CmdletBinding()] param($FriendlyName) [pscustomobject]@{ UniqueId = 'subsystem-1' } }

function Set-StoragePool { [CmdletBinding()] param($FriendlyName, $IsReadOnly) Add-FakeCall 'Set-StoragePool' @{ FriendlyName = $FriendlyName; IsReadOnly = $IsReadOnly } }
function Connect-VirtualDisk { [CmdletBinding()] param($FriendlyName) Add-FakeCall 'Connect-VirtualDisk' @{ FriendlyName = $FriendlyName } }
function Set-Disk { [CmdletBinding()] param($Number, $IsOffline, $IsReadOnly) Add-FakeCall 'Set-Disk' @{ Number = $Number; IsOffline = $IsOffline; IsReadOnly = $IsReadOnly } }
function Set-Partition { [CmdletBinding()] param($DiskNumber, $PartitionNumber, $NewDriveLetter) Add-FakeCall 'Set-Partition' @{ DiskNumber = $DiskNumber; NewDriveLetter = $NewDriveLetter } }
function Clear-Disk {
    [CmdletBinding()] param($Number, [switch]$RemoveData, [switch]$RemoveOEM, $Confirm)
    Add-FakeCall 'Clear-Disk' @{ Number = $Number; RemoveData = $RemoveData.IsPresent }
    foreach ($d in $global:FakeMachine.Disks) { if ($d.Disk.Number -eq $Number) { $d.Physical.CanPool = $true } }
}
function New-StoragePool {
    [CmdletBinding()] param($FriendlyName, $StorageSubSystemUniqueId, $PhysicalDisks)
    Add-FakeCall 'New-StoragePool' @{ FriendlyName = $FriendlyName; Disks = @($PhysicalDisks | ForEach-Object { $_.DeviceId }) }
    $global:FakeMachine.Pool = [pscustomobject]@{ FriendlyName = $FriendlyName; IsPrimordial = $false; IsReadOnly = $false }
}
function New-VirtualDisk {
    [CmdletBinding()] param($StoragePoolFriendlyName, $FriendlyName, $ResiliencySettingName, $NumberOfColumns, $Interleave, $ProvisioningType, [switch]$UseMaximumSize)
    Add-FakeCall 'New-VirtualDisk' @{ Pool = $StoragePoolFriendlyName; FriendlyName = $FriendlyName; Resiliency = $ResiliencySettingName; Columns = $NumberOfColumns; Interleave = $Interleave }
    $global:FakeMachine.VirtualDisk = [pscustomobject]@{ FriendlyName = $FriendlyName; OperationalStatus = 'OK'; IsManualAttach = $false }
    $global:FakeMachine.VirtualDiskDisk = [pscustomobject]@{ Number = 9; IsOffline = $false; IsReadOnly = $false }
}
function Initialize-Disk { [CmdletBinding()] param($Number, $PartitionStyle) Add-FakeCall 'Initialize-Disk' @{ Number = $Number; PartitionStyle = $PartitionStyle } }
function New-Partition { [CmdletBinding()] param($DiskNumber, [switch]$UseMaximumSize, $DriveLetter) Add-FakeCall 'New-Partition' @{ DiskNumber = $DiskNumber; DriveLetter = $DriveLetter }; [pscustomobject]@{ PartitionNumber = 1 } }
function Format-Volume { [CmdletBinding()] param($Partition, $FileSystem, $NewFileSystemLabel, $Confirm) Add-FakeCall 'Format-Volume' @{ FileSystem = $FileSystem; Label = $NewFileSystemLabel } }

# Calls that change a disk. A safe no-op scenario must record none of them.
$global:FakeMutatingCalls = 'Set-StoragePool', 'Connect-VirtualDisk', 'Set-Disk', 'Set-Partition', 'Clear-Disk', 'New-StoragePool', 'New-VirtualDisk', 'Initialize-Disk', 'New-Partition', 'Format-Volume'
function Get-FakeMutatingCall { @($global:FakeCalls | Where-Object { $_.Name -in $global:FakeMutatingCalls }) }
