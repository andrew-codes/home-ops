# Tests for src/fancontrol.ps1 and src/fancontrol-profile.ps1. Run with:
#   pwsh -NoProfile -File apps/gaming-pc/tests/fancontrol.test.ps1
# Plain assertions, no Pester. Everything runs against throwaway folders standing
# in for FanControl's install directory. The shortcut COM calls, the process
# check and Start-Process are replaced by fakes, so there is no FanControl, no
# registry write and no Start menu change, here or in CI.

$ErrorActionPreference = 'Stop'

$work = Join-Path ([IO.Path]::GetTempPath()) "gaming-pc-fancontrol-test-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $work | Out-Null
$src = Join-Path $PSScriptRoot '..' 'src'
foreach ($f in 'fancontrol.ps1', 'fancontrol-profile.ps1', 'logging.ps1') { Copy-Item (Join-Path $src $f) $work }
. (Join-Path $work 'fancontrol.ps1')
. (Join-Path $work 'fancontrol-profile.ps1') -ProfileName balance

$script:TestFailures = 0
function Assert-Equal {
    param($Expected, $Actual, [string]$What)
    if ("$Expected" -ne "$Actual") {
        Write-Host "FAIL $What`n  expected: $Expected`n  actual:   $Actual"
        $script:TestFailures++
    }
    else { Write-Host "ok   $What" }
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern, [string]$What)
    try { & $Action; Write-Host "FAIL $What (did not throw)"; $script:TestFailures++ }
    catch {
        if ($_.Exception.Message -match $Pattern) { Write-Host "ok   $What" }
        else { Write-Host "FAIL $What`n  message: $($_.Exception.Message)"; $script:TestFailures++ }
    }
}

# --- Fakes -----------------------------------------------------------------
$script:Running = $false
function Test-FanControlRunning { return $script:Running }
$script:Shortcuts = @{}
function Get-ShortcutState { param($Path) if ($script:Shortcuts.ContainsKey($Path)) { $script:Shortcuts[$Path] } else { $null } }
function Write-Shortcut {
    param($Path, $Target, $Arguments, $WorkingDirectory)
    $script:Shortcuts[$Path] = @{ Target = $Target; Arguments = $Arguments; WorkingDirectory = $WorkingDirectory }
}
$script:Started = New-Object System.Collections.Generic.List[object]
function Start-Process { param($FilePath, $ArgumentList, $WorkingDirectory) $script:Started.Add(@{ File = $FilePath; Args = @($ArgumentList); Dir = $WorkingDirectory }) }

function New-FakeInstall {
    $dir = Join-Path $work "install-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path (Join-Path $dir 'Configurations') -Force | Out-Null
    Set-Content -Path (Join-Path $dir 'FanControl.exe') -Value 'fake'
    $dir
}

$profileSource = Join-Path $src 'fancontrol'
$balance = $script:FanControlProfiles['balance'].File
$boost = $script:FanControlProfiles['gpu-boost'].File

# --- The shipped profiles --------------------------------------------------
foreach ($file in $balance, $boost) {
    $json = Get-Content -Path (Join-Path $profileSource $file) -Raw | ConvertFrom-Json
    Assert-Equal '286' $json.__VERSION__ "$file parses as a FanControl 286 file"

    $pump = @($json.FanControl.Controls | Where-Object { $_.Identifier -eq '/lpc/nct6799d/control/6' })
    Assert-Equal 1 $pump.Count "$file has the pump control (Fan #7)"
    Assert-Equal 'False' $pump[0].Enable "$file keeps the pump control disabled"
    Assert-Equal 'False' $pump[0].ForceApply "$file does not force the pump control"
}
function Get-GpuFans {
    param($file)
    @((Get-Content -Path (Join-Path $profileSource $file) -Raw | ConvertFrom-Json).FanControl.Controls |
            Where-Object { $_.NickName -like 'GPU fan*' })
}
$fans = Get-GpuFans $balance
Assert-Equal 2 $fans.Count 'balance has two GPU fan controls'
Assert-Equal 0 @($fans | Where-Object { $_.Enable }).Count 'balance leaves both GPU fans to NVIDIA'
$fans = Get-GpuFans $boost
Assert-Equal 2 $fans.Count 'gpu-boost has two GPU fan controls'
Assert-Equal 2 @($fans | Where-Object { $_.Enable -and $_.ForceApply }).Count 'gpu-boost drives both GPU fans'

# --- Idempotent copy and backup -------------------------------------------
$dir = New-FakeInstall
$dest = Join-Path $dir 'Configurations' $balance
$source = Join-Path $profileSource $balance
Assert-Equal 'Installed' (Copy-FanControlProfile -Source $source -Destination $dest) 'first copy writes the profile'
Assert-Equal 'Present' (Copy-FanControlProfile -Source $source -Destination $dest) 'second copy changes nothing'
Assert-Equal $false (Test-Path "$dest.gaming-pc.bak") 'no backup when nothing differed'

Set-Content -Path $dest -Value 'owner edit 1'
Assert-Equal 'Installed' (Copy-FanControlProfile -Source $source -Destination $dest) 'a different file is replaced'
Assert-Equal 'owner edit 1' ((Get-Content "$dest.gaming-pc.bak" -Raw).Trim()) 'the different file was backed up first'
Set-Content -Path $dest -Value 'owner edit 2'
Copy-FanControlProfile -Source $source -Destination $dest | Out-Null
Assert-Equal 'owner edit 1' ((Get-Content "$dest.gaming-pc.bak" -Raw).Trim()) 'a later difference keeps the first backup'
Assert-Equal (Get-FileHash $source).Hash (Get-FileHash $dest).Hash 'the destination matches the repo file again'

# --- Default profile -------------------------------------------------------
function New-CacheDir { param($Content) $d = New-FakeInstall; $c = Join-Path $d 'Configurations'; if ($null -ne $Content) { Set-Content -Path (Join-Path $c 'CACHE') -Value $Content }; $c }
function Read-Current { param($ConfigDir) (Get-Content (Join-Path $ConfigDir 'CACHE') -Raw | ConvertFrom-Json).CurrentConfigFileName }

$c = New-CacheDir $null
Assert-Equal 'Installed' (Set-DefaultProfile -ConfigDir $c -ProfileFile $balance) 'no CACHE: balance becomes the default'
Assert-Equal $balance (Read-Current $c) 'the new CACHE names balance'
Assert-Equal 'Present' (Set-DefaultProfile -ConfigDir $c -ProfileFile $balance) 'second run changes nothing'

$c = New-CacheDir '{"CurrentConfigFileName":"userConfig.json","StartMinimized":true}'
Assert-Equal 'Installed' (Set-DefaultProfile -ConfigDir $c -ProfileFile $balance) "FanControl's stock userConfig.json counts as not chosen"
Assert-Equal $balance (Read-Current $c) 'the stock name is replaced by balance'
Assert-Equal 'True' ((Get-Content (Join-Path $c 'CACHE') -Raw | ConvertFrom-Json).StartMinimized) 'other CACHE settings are kept'

$c = New-CacheDir '{"StartMinimized":true}'
Assert-Equal 'Installed' (Set-DefaultProfile -ConfigDir $c -ProfileFile $balance) 'CACHE without a recorded profile gets the default'

$c = New-CacheDir "{`"CurrentConfigFileName`":`"$boost`"}"
Assert-Equal 'Present' (Set-DefaultProfile -ConfigDir $c -ProfileFile $balance) 'a profile the owner switched to is never changed'
Assert-Equal $boost (Read-Current $c) 'gpu-boost survives a re-run'

$c = New-CacheDir '{"CurrentConfigFileName":"my-own.json"}'
Assert-Equal 'Present' (Set-DefaultProfile -ConfigDir $c -ProfileFile $balance) 'any other chosen profile is left alone'

$c = New-CacheDir 'not json at all'
$before = $script:Warnings.Count
Assert-Equal 'Present' (Set-DefaultProfile -ConfigDir $c -ProfileFile $balance) 'an unreadable CACHE is not rewritten'
Assert-Equal 'not json at all' ((Get-Content (Join-Path $c 'CACHE') -Raw).Trim()) 'the unreadable CACHE is byte-for-byte kept'
Assert-Equal ($before + 1) $script:Warnings.Count 'an unreadable CACHE is a warning'

$c = New-CacheDir $null
$script:Running = $true
Assert-Equal 'Present' (Set-DefaultProfile -ConfigDir $c -ProfileFile $balance) 'a running FanControl is not edited under'
Assert-Equal $false (Test-Path (Join-Path $c 'CACHE')) 'no CACHE written while it runs'
$script:Running = $false

# --- Shortcuts --------------------------------------------------------------
$dir = New-FakeInstall
$lnk = Join-Path $work 'menu' $script:FanControlProfiles['gpu-boost'].Shortcut
Assert-Equal 'Installed' (Install-ProfileShortcut -Path $lnk -InstallDir $dir -ProfileFile $boost) 'a missing shortcut is created'
Assert-Equal "-c $boost" $script:Shortcuts[$lnk].Arguments 'the shortcut passes -c <profile>'
Assert-Equal $dir $script:Shortcuts[$lnk].WorkingDirectory 'the shortcut starts in the FanControl folder'
Assert-Equal 'Present' (Install-ProfileShortcut -Path $lnk -InstallDir $dir -ProfileFile $boost) 'a correct shortcut is left alone'
Assert-Equal 'Installed' (Install-ProfileShortcut -Path $lnk -InstallDir $dir -ProfileFile $balance) 'a wrong shortcut is rewritten'

# --- Locating FanControl ----------------------------------------------------
$dir = New-FakeInstall
Assert-Equal $dir (Get-FanControlInstallDir -Override $dir) 'an override with FanControl.exe is used'
Assert-Equal '' (Get-FanControlInstallDir -Override (Join-Path $work 'nothing')) 'an override without FanControl.exe finds nothing'

# --- The switch script -------------------------------------------------------
$dir = New-FakeInstall
foreach ($f in $balance, $boost) { Copy-Item (Join-Path $profileSource $f) (Join-Path $dir 'Configurations') }
Switch-FanControlProfile -ProfileName 'gpu-boost' -InstallDir $dir
Assert-Equal 1 $script:Started.Count 'switching launches FanControl once'
Assert-Equal (Join-Path $dir 'FanControl.exe') $script:Started[0].File 'it runs FanControl.exe'
Assert-Equal "-c $boost" ($script:Started[0].Args -join ' ') 'it passes -c and the profile file'
Assert-Equal $dir $script:Started[0].Dir 'it starts in the FanControl folder'
Switch-FanControlProfile -ProfileName 'balance' -InstallDir $dir
Assert-Equal "-c $balance" ($script:Started[1].Args -join ' ') 'balance maps to its file'
Assert-Throws { Switch-FanControlProfile -ProfileName 'turbo' -InstallDir $dir } 'unknown profile' 'an unknown profile name is rejected'
Assert-Throws { Switch-FanControlProfile -ProfileName 'balance' -InstallDir (Join-Path $work 'nope') } 'not found' 'a missing FanControl is reported'
$empty = New-FakeInstall
Assert-Throws { Switch-FanControlProfile -ProfileName 'balance' -InstallDir $empty } 'not in FanControl' 'a missing profile file is reported'
Assert-Equal 2 $script:Started.Count 'failed switches launch nothing'

# The command line accepts exactly the two names.
$param = (Get-Command (Join-Path $work 'fancontrol-profile.ps1')).Parameters['ProfileName']
$allowed = ($param.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }).ValidValues
Assert-Equal 'balance,gpu-boost' ($allowed -join ',') 'the script accepts balance and gpu-boost only'

# --- The whole script, run for real against the fake install --------------------
# Shortcuts need COM, which only exists on Windows, so this runs there only.
if ($IsWindows) {
    $dir = New-FakeInstall
    $menu = Join-Path $work 'e2e-menu'
    $run = { pwsh -NoProfile -File (Join-Path $work 'fancontrol.ps1') -InstallDir $dir -ProfileSourceDir $profileSource -ShortcutDir $menu | Out-String }
    Assert-Equal $true ((& $run) -match 'RESULT changed=5 warnings=0 failures=0') 'first run changes the two profiles, the default and two shortcuts'
    Assert-Equal $true ((& $run) -match 'RESULT changed=0 warnings=0 failures=0') 'second run reports changed=0'
}

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
if ($script:TestFailures -gt 0) { Write-Host "$script:TestFailures failure(s)"; exit 1 }
Write-Host 'all passed'
