# Tests for src/storage.ps1. Run with:
#   pwsh -NoProfile -File apps/gaming-pc/tests/storage.test.ps1
# Plain assertions, no Pester. Every Storage cmdlet is a fake from
# tests/helpers/storage-fakes.ps1, so no disk is ever touched.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'helpers' 'storage-fakes.ps1')

# The script writes log.txt next to itself, so it is run from a copy.
$work = Join-Path ([IO.Path]::GetTempPath()) "gaming-pc-storage-test-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $work | Out-Null
foreach ($f in 'storage.ps1', 'logging.ps1') { Copy-Item (Join-Path $PSScriptRoot '..' 'src' $f) $work }
$script:StorageScript = Join-Path $work 'storage.ps1'

$script:TestFailures = 0
function Assert-Equal {
    param($Expected, $Actual, [string]$What)
    if ("$Expected" -ne "$Actual") {
        Write-Host "FAIL $What`n  expected: $Expected`n  actual:   $Actual"
        $script:TestFailures++
    }
    else { Write-Host "ok   $What" }
}
function Assert-Match {
    param([string]$Pattern, [string]$Actual, [string]$What)
    if ($Actual -notmatch $Pattern) {
        Write-Host "FAIL $What`n  pattern: $Pattern`n  actual:  $Actual"
        $script:TestFailures++
    }
    else { Write-Host "ok   $What" }
}

# Runs the decision with the script's parameters and returns what it did.
function Invoke-Scenario {
    param($Machine, [hashtable]$Parameters = @{})
    # -WhatIf is a common parameter of the script; dot-sourced, its effect is the preference.
    $whatIf = $Parameters.ContainsKey('WhatIf')
    $Parameters.Remove('WhatIf')
    $global:FakeMachine = $Machine
    $global:FakeCalls.Clear()
    $log = & {
        . $script:StorageScript @Parameters
        $WhatIfPreference = $whatIf
        $script:Outcome = Invoke-GamesStorage
        $script:Warned = @($script:Warnings)
    } 6>&1 | ForEach-Object { "$_" }
    [pscustomobject]@{ Outcome = $script:Outcome; Warnings = $script:Warned; Log = ($log -join "`n"); Mutations = @(Get-FakeMutatingCall) }
}

function New-ExistingPool { param([bool]$ReadOnly = $false) [pscustomobject]@{ FriendlyName = 'GamesPool'; IsPrimordial = $false; IsReadOnly = $ReadOnly } }

$boot = New-FakeNvme -Number 0 -Name 'Boot 2TB' -CanPool $false -IsBoot $true -IsSystem $true -Partitions 4 -PartitionStyle GPT
$spareA = New-FakeNvme -Number 1
$spareB = New-FakeNvme -Number 2

# --- Safe no-ops -----------------------------------------------------------

# The current machine: BIOS RAID shows Windows one logical RAID drive, not the members.
$raid = New-FakeNvme -Number 0 -Name 'AMD-RAID Array' -BusType 'RAID' -CanPool $false -IsBoot $true -IsSystem $true -Partitions 4 -PartitionStyle GPT
$r = Invoke-Scenario (New-FakeMachine -Disks @($raid))
Assert-Equal 0 $r.Mutations.Count 'BIOS RAID machine: changes nothing'
Assert-Equal 1 $r.Warnings.Count 'BIOS RAID machine: one warning'
Assert-Match 'expected exactly 2 spare NVMe drives.*found 0.*NVMe mode' $r.Warnings[0] 'BIOS RAID machine: warning gives the reason and the remedy'

$r = Invoke-Scenario (New-FakeMachine -Disks @($boot, $spareA))
Assert-Equal 0 $r.Mutations.Count 'one spare drive: changes nothing'
Assert-Match 'found 1' $r.Warnings[0] 'one spare drive: warning counts it'

$spareC = New-FakeNvme -Number 3
$r = Invoke-Scenario (New-FakeMachine -Disks @($boot, $spareA, $spareB, $spareC))
Assert-Equal 0 $r.Mutations.Count 'three spare drives: changes nothing, never guesses which two'
Assert-Match 'found 3' $r.Warnings[0] 'three spare drives: warning counts them'

# --- Creating the array ----------------------------------------------------

$r = Invoke-Scenario (New-FakeMachine -Disks @($boot, $spareA, $spareB))
Assert-Equal 'Installed' $r.Outcome 'two clean drives: creates the array'
$pool = (Get-FakeCall 'New-StoragePool')[0].Arguments
Assert-Equal '1,2' ($pool.Disks -join ',') 'two clean drives: pool holds exactly the two spares, not the boot disk'
Assert-Equal 'GamesPool' $pool.FriendlyName 'default pool name'
$vd = (Get-FakeCall 'New-VirtualDisk')[0].Arguments
Assert-Equal 'Simple' $vd.Resiliency 'virtual disk is Simple (no redundancy)'
Assert-Equal 2 $vd.Columns 'virtual disk has 2 columns'
Assert-Equal 262144 $vd.Interleave 'default interleave is 256 KB'
Assert-Equal 'G' (Get-FakeCall 'New-Partition')[0].Arguments.DriveLetter 'default drive letter is G'
Assert-Equal 'NTFS' (Get-FakeCall 'Format-Volume')[0].Arguments.FileSystem 'default file system is NTFS'
Assert-Equal 0 (Get-FakeCall 'Clear-Disk').Count 'clean drives are not cleared'

$r = Invoke-Scenario (New-FakeMachine -Disks @($boot, $spareA, $spareB)) @{ PoolName = 'Fast'; VirtualDiskName = 'Steam'; DriveLetter = 'H'; FileSystem = 'ReFS'; Interleave = 65536 }
Assert-Equal 'Fast' (Get-FakeCall 'New-StoragePool')[0].Arguments.FriendlyName 'pool name is a variable'
Assert-Equal 'Steam' (Get-FakeCall 'New-VirtualDisk')[0].Arguments.FriendlyName 'virtual disk name is a variable'
Assert-Equal 'H' (Get-FakeCall 'New-Partition')[0].Arguments.DriveLetter 'drive letter is a variable'
Assert-Equal 'ReFS' (Get-FakeCall 'Format-Volume')[0].Arguments.FileSystem 'file system is a variable'
Assert-Equal 65536 (Get-FakeCall 'New-VirtualDisk')[0].Arguments.Interleave 'interleave is a variable'

# Never a USB, SATA or removable drive, even when it is empty and poolable.
$usb = New-FakeNvme -Number 5 -Name 'USB stick' -BusType 'USB'
$sata = New-FakeNvme -Number 6 -Name 'SATA SSD' -BusType 'SATA'
$r = Invoke-Scenario (New-FakeMachine -Disks @($boot, $spareA, $spareB, $usb, $sata))
Assert-Equal '1,2' ((Get-FakeCall 'New-StoragePool')[0].Arguments.Disks -join ',') 'USB and SATA drives are never pooled'

# A boot disk that is somehow poolable is still excluded.
$bootPoolable = New-FakeNvme -Number 0 -Name 'Boot' -CanPool $true -IsBoot $true
$r = Invoke-Scenario (New-FakeMachine -Disks @($bootPoolable, $spareA))
Assert-Equal 0 $r.Mutations.Count 'a poolable boot disk is not a candidate'

# The drive letter belongs to something else.
$r = Invoke-Scenario (New-FakeMachine -Disks @($boot, $spareA, $spareB) -Volumes @([pscustomobject]@{ DriveLetter = 'G'; FileSystemLabel = 'Backup' }))
Assert-Equal 0 $r.Mutations.Count 'letter G in use: changes nothing'
Assert-Match 'already used by volume .Backup' $r.Warnings[0] 'letter G in use: warns'

# --- Old data: refuse unless opted in --------------------------------------

# Built fresh per scenario: the fake Clear-Disk makes a drive poolable.
function New-DirtyA { New-FakeNvme -Number 1 -CanPool $false -Partitions 2 -PartitionStyle GPT }
function New-DirtyB { New-FakeNvme -Number 2 -CanPool $false -Partitions 1 -PartitionStyle GPT }
$r = Invoke-Scenario (New-FakeMachine -Disks @($boot, (New-DirtyA), (New-DirtyB)))
Assert-Equal 0 $r.Mutations.Count 'old partitions without opt-in: wipes nothing'
Assert-Match 'REFUSING to wipe.*disk 1 .*disk 2 ' $r.Warnings[0] 'old partitions without opt-in: names the disks it would wipe'
Assert-Match 'GAMING_PC_STORAGE_WIPE=true' $r.Warnings[0] 'old partitions without opt-in: names the opt-in'

# One dirty drive is enough to refuse.
$r = Invoke-Scenario (New-FakeMachine -Disks @($boot, $spareA, (New-DirtyB)))
Assert-Equal 0 $r.Mutations.Count 'one old drive without opt-in: wipes nothing'
Assert-Match 'disk 2 ' $r.Warnings[0] 'one old drive without opt-in: names only that disk'
Assert-Match '^(?!.*disk 1 ).*$' $r.Warnings[0] 'one old drive without opt-in: does not name the clean one'

$r = Invoke-Scenario (New-FakeMachine -Disks @($boot, (New-DirtyA), (New-DirtyB))) @{ AllowWipe = $true }
Assert-Equal '1,2' ((Get-FakeCall 'Clear-Disk' | ForEach-Object { $_.Arguments.Number }) -join ',') 'opt-in: clears the two old drives and nothing else'
Assert-Equal 1 (Get-FakeCall 'New-StoragePool').Count 'opt-in: then creates the pool'
Assert-Match 'WOULD WIPE' $r.Log 'opt-in: logs which disks it wipes'

# --- Dry run ---------------------------------------------------------------

$r = Invoke-Scenario (New-FakeMachine -Disks @($boot, $spareA, $spareB)) @{ WhatIf = $true }
Assert-Equal 0 $r.Mutations.Count '-WhatIf: changes nothing'
Assert-Match 'WOULD USE: disk 1 .*disk 2 ' $r.Log '-WhatIf: lists the disks it would use'
$r = Invoke-Scenario (New-FakeMachine -Disks @($boot, (New-DirtyA), (New-DirtyB))) @{ WhatIf = $true; AllowWipe = $true }
Assert-Equal 0 $r.Mutations.Count '-WhatIf with -AllowWipe: wipes nothing'
Assert-Match 'WOULD WIPE.*disk 1 .*disk 2 ' $r.Log '-WhatIf with -AllowWipe: lists the disks it would wipe'

# --- The pool already exists (Windows was reinstalled) ---------------------

$member1 = New-FakeNvme -Number 1 -CanPool $false -InPool $true
$member2 = New-FakeNvme -Number 2 -CanPool $false -InPool $true
$vdisk = [pscustomobject]@{ FriendlyName = 'Games'; OperationalStatus = 'OK'; IsManualAttach = $false }
$online = [pscustomobject]@{ Number = 9; IsOffline = $false; IsReadOnly = $false }
$partitionG = [pscustomobject]@{ PartitionNumber = 1; Type = 'Basic'; Size = 4TB; DriveLetter = 'G' }

$r = Invoke-Scenario (New-FakeMachine -Disks @($boot, $member1, $member2) -Pool (New-ExistingPool) -VirtualDisk $vdisk -VirtualDiskDisk $online -VirtualDiskPartitions @($partitionG))
Assert-Equal 0 $r.Mutations.Count 'pool, virtual disk and letter all present: changes nothing'
Assert-Equal 'Present' $r.Outcome 'pool, virtual disk and letter all present: reports no change'

$detached = [pscustomobject]@{ FriendlyName = 'Games'; OperationalStatus = 'Detached'; IsManualAttach = $true }
$offline = [pscustomobject]@{ Number = 9; IsOffline = $true; IsReadOnly = $true }
$noLetter = [pscustomobject]@{ PartitionNumber = 1; Type = 'Basic'; Size = 4TB; DriveLetter = [char]0 }
$r = Invoke-Scenario (New-FakeMachine -Disks @($boot, $member1, $member2) -Pool (New-ExistingPool -ReadOnly $true) -VirtualDisk $detached -VirtualDiskDisk $offline -VirtualDiskPartitions @($noLetter))
Assert-Equal 'Installed' $r.Outcome 'reinstall: attaches and onlines the existing array'
Assert-Equal 1 (Get-FakeCall 'Set-StoragePool').Count 'reinstall: makes the pool writable'
Assert-Equal 1 (Get-FakeCall 'Connect-VirtualDisk').Count 'reinstall: attaches the virtual disk'
Assert-Equal 2 (Get-FakeCall 'Set-Disk').Count 'reinstall: onlines the disk and clears read-only'
Assert-Equal 'G' (Get-FakeCall 'Set-Partition')[0].Arguments.NewDriveLetter 'reinstall: assigns the drive letter'
foreach ($name in 'New-StoragePool', 'New-VirtualDisk', 'Clear-Disk', 'Initialize-Disk', 'New-Partition', 'Format-Volume') {
    Assert-Equal 0 (Get-FakeCall $name).Count "reinstall: never calls $name"
}

# The existing pool wins even when the member drives would otherwise look free.
$r = Invoke-Scenario (New-FakeMachine -Disks @($boot, $spareA, $spareB) -Pool (New-ExistingPool) -VirtualDisk $vdisk -VirtualDiskDisk $online -VirtualDiskPartitions @($partitionG))
Assert-Equal 0 (Get-FakeCall 'New-StoragePool').Count 'existing pool: never creates a second one'

$other = [pscustomobject]@{ DriveLetter = 'G'; FileSystemLabel = 'Other' }
$wrongLetter = [pscustomobject]@{ PartitionNumber = 1; Type = 'Basic'; Size = 4TB; DriveLetter = [char]'E' }
$r = Invoke-Scenario (New-FakeMachine -Disks @($boot, $member1, $member2) -Pool (New-ExistingPool) -VirtualDisk $vdisk -VirtualDiskDisk $online -VirtualDiskPartitions @($wrongLetter) -Volumes @($other))
Assert-Equal 0 $r.Mutations.Count 'existing pool, letter held by another volume: changes nothing'
Assert-Match 'held by another volume' $r.Warnings[0] 'existing pool, letter held by another volume: warns'

$r = Invoke-Scenario (New-FakeMachine -Disks @($boot, $member1, $member2) -Pool (New-ExistingPool))
Assert-Equal 0 $r.Mutations.Count 'existing pool without its virtual disk: creates nothing'
Assert-Match 'no virtual disk named' $r.Warnings[0] 'existing pool without its virtual disk: warns'

# A pool under another name: never merged, never recreated over.
$strangePool = [pscustomobject]@{ FriendlyName = 'Whatever'; IsPrimordial = $false; IsReadOnly = $false }
$r = Invoke-Scenario (New-FakeMachine -Disks @($boot, $member1, $member2) -Pool $strangePool)
Assert-Equal 0 $r.Mutations.Count 'drives already in another pool: changes nothing'
Assert-Match 'already in a storage pool' $r.Warnings[0] 'drives already in another pool: warns'

# --- The whole script: exit code and RESULT line ---------------------------

function Invoke-Script {
    param([string[]]$ScriptArgs = @(), $Machine)
    $fakes = Join-Path $PSScriptRoot 'helpers' 'storage-fakes.ps1'
    $setup = @(
        "`$ErrorActionPreference = 'Stop'",
        ". '$fakes'",
        "`$global:FakeMachine = New-FakeMachine -Disks @($Machine)",
        "& '$script:StorageScript' $($ScriptArgs -join ' ')",
        'exit $LASTEXITCODE'
    ) -join "`n"
    $out = & (Get-Process -Id $PID).Path -NoProfile -Command $setup 2>&1 | ForEach-Object { "$_" }
    [pscustomobject]@{ Exit = $LASTEXITCODE; Out = ($out -join "`n") }
}

$noArray = '(New-FakeNvme -Number 0 -Name Boot -CanPool $false -IsBoot $true -Partitions 3 -PartitionStyle GPT)'
$r = Invoke-Script -Machine $noArray
Assert-Equal 0 $r.Exit 'script without the drives: does not fail the deploy'
Assert-Match 'RESULT changed=0 warnings=1 failures=0 array=Missing' $r.Out 'script without the drives: RESULT line'
$r = Invoke-Script -Machine $noArray -ScriptArgs '-RequireArray'
Assert-Equal 1 $r.Exit 'script without the drives and -RequireArray: fails'
Assert-Match 'failures=1' $r.Out '-RequireArray: counted as a failure'

Remove-Item -LiteralPath $work -Recurse -Force
if ($script:TestFailures -gt 0) { Write-Host "$script:TestFailures failure(s)"; exit 1 }
Write-Host 'all passed'
