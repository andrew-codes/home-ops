# Tests for the VS Code removal in src/software.ps1. Run with:
#   pwsh -NoProfile -File apps/gaming-pc/tests/software-vscode.test.ps1
# software.ps1 acts on the machine when it is dot-sourced, so the functions are
# lifted out of it with the PowerShell parser and run against fakes: temp
# directories stand in for Program Files, %LOCALAPPDATA% and the registry's shell
# keys (Test-Path and Remove-Item treat both the same), and Get-Process,
# Start-Process, choco and the uninstall-entry lookup are replaced. Nothing is
# really uninstalled.

$ErrorActionPreference = 'Stop'

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

$source = Join-Path $PSScriptRoot '..' 'src' 'software.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$null)
foreach ($name in 'ConvertTo-SilentUninstallCommand', 'Remove-VSCodeChocolatey', 'Remove-VSCodeLeftovers') {
    $function = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
    if (-not $function) { throw "$name not found in software.ps1" }
    . ([scriptblock]::Create($function.Extent.Text))
}
$VSCodeChocolateyPackages = @('vscode', 'vscode-insiders')

# --- fakes -----------------------------------------------------------------
$script:Log = [Collections.Generic.List[string]]::new()
$script:Calls = [Collections.Generic.List[string]]::new()
$script:ChocoInstalled = @()       # package ids choco reports as installed
$script:ChocoPresent = $false
$script:Entries = @()              # what the registry lookup returns
$script:Running = $false
$script:UninstallerExit = 0
$script:OnUninstall = $null        # what the fake uninstaller does to the disk

function Write-Log { param([string]$Message) $script:Log.Add($Message) }
function Start-Sleep { param($Seconds) }
function Get-Command {
    param($Name, $ErrorAction)
    if ($Name -eq 'choco' -and $script:ChocoPresent) { return [pscustomobject]@{ Name = 'choco' } }
    return $null
}
function choco {
    $script:Calls.Add("choco $($args -join ' ')")
    $global:LASTEXITCODE = 0
    if ($args[0] -eq 'list') {
        foreach ($id in $script:ChocoInstalled) { if ($id -eq $args[-1]) { "$id|1.0.0" } }
    }
}
function Get-Process {
    param($Name, $ErrorAction)
    if ($script:Running) { [pscustomobject]@{ Name = 'Code' } }
}
function Stop-Process {
    param([Parameter(ValueFromPipeline = $true)]$InputObject, [switch]$Force)
    process { $script:Calls.Add('stop-process') }
}
function Get-VSCodeUninstallEntry { param($Scope) $script:Entries }
function Start-Process {
    param($FilePath, $ArgumentList, [switch]$Wait, [switch]$PassThru)
    $script:Calls.Add("start $FilePath $ArgumentList")
    if ($script:OnUninstall) { & $script:OnUninstall }
    [pscustomobject]@{ ExitCode = $script:UninstallerExit }
}

function Reset-Fakes {
    $script:Log.Clear(); $script:Calls.Clear()
    $script:ChocoInstalled = @(); $script:ChocoPresent = $false
    $script:Entries = @(); $script:Running = $false
    $script:UninstallerExit = 0; $script:OnUninstall = $null
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) "vscode-test-$([guid]::NewGuid())"
$env:ProgramFiles = Join-Path $tmp 'ProgramFiles'
${env:ProgramFiles(x86)} = Join-Path $tmp 'ProgramFilesX86'
$env:LOCALAPPDATA = Join-Path $tmp 'Local'
$userInstall = Join-Path $env:LOCALAPPDATA 'Programs' 'Microsoft VS Code'
$userInsiders = Join-Path $env:LOCALAPPDATA 'Programs' 'Microsoft VS Code Insiders'
$machineInstall = Join-Path $env:ProgramFiles 'Microsoft VS Code'
$settings = Join-Path $tmp 'Roaming' 'Code'
$extensions = Join-Path $tmp 'home' '.vscode'
$shellKey = Join-Path $tmp 'registry' 'shell' 'VSCode'

function New-Fixture {
    foreach ($d in $userInstall, $userInsiders, $machineInstall, $settings, $extensions, $shellKey) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $d 'file.txt') 'x'
    }
}
function Clear-Fixture { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

try {
    # --- command parsing ------------------------------------------------------
    $c = ConvertTo-SilentUninstallCommand '"C:\Program Files\Microsoft VS Code\unins000.exe"'
    Assert-Equal 'C:\Program Files\Microsoft VS Code\unins000.exe' $c.File 'quoted path is split from the arguments'
    Assert-Equal '/VERYSILENT /NORESTART /SUPPRESSMSGBOXES' $c.Arguments 'an Inno uninstaller gets the silent flags'
    $c = ConvertTo-SilentUninstallCommand '"C:\u\unins000.exe" /SILENT'
    Assert-Equal '/SILENT /NORESTART /SUPPRESSMSGBOXES' $c.Arguments 'a quiet string keeps its own flag'
    $c = ConvertTo-SilentUninstallCommand 'MsiExec.exe /X{ABC}'
    Assert-Equal '/X{ABC} /qn /norestart' $c.Arguments 'an msiexec command gets /qn'

    # --- already absent: nothing found, nothing flagged ------------------------
    Reset-Fakes; New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    foreach ($scope in 'Machine', 'User') {
        Reset-Fakes
        Assert-Equal 'Absent' (Remove-VSCodeLeftovers -Scope $scope -ContextMenuKeys @($shellKey)) "$scope already absent returns Absent"
        Assert-Equal 0 $script:Calls.Count "$scope already absent runs nothing, not even stopping VS Code"
    }
    Reset-Fakes; $script:ChocoPresent = $true
    Assert-Equal 'Absent' (Remove-VSCodeLeftovers -Scope Machine -ContextMenuKeys @($shellKey)) 'choco present but no vscode package returns Absent'
    Assert-Equal 'choco list --local-only --exact --limit-output vscode|choco list --local-only --exact --limit-output vscode-insiders' ($script:Calls -join '|') 'choco is only listed, never uninstalled, when the packages are not there'

    # --- Chocolatey ---------------------------------------------------------------
    Reset-Fakes; $script:ChocoPresent = $true; $script:ChocoInstalled = @('vscode', 'vscode-insiders')
    Assert-Equal 'Removed' (Remove-VSCodeLeftovers -Scope Machine -ContextMenuKeys @($shellKey)) 'chocolatey packages are removed'
    Assert-Equal 2 @($script:Calls | Where-Object { $_ -like 'choco uninstall*' }).Count 'both chocolatey packages are uninstalled'
    Assert-Equal 1 @($script:Log | Where-Object { $_ -like '*removed by chocolatey (vscode), chocolatey (vscode-insiders)*' }).Count 'the log names chocolatey as the method'
    Reset-Fakes; $script:ChocoPresent = $true; $script:ChocoInstalled = @('vscode')
    $null = Remove-VSCodeLeftovers -Scope User -ContextMenuKeys @($shellKey)
    Assert-Equal 0 @($script:Calls | Where-Object { $_ -like 'choco*' }).Count 'the user phase does not touch chocolatey'

    # --- registry uninstall entry, machine-wide and per-user ----------------------
    Clear-Fixture; New-Fixture
    Reset-Fakes
    $script:Entries = @([pscustomobject]@{ Name = 'Microsoft Visual Studio Code'; Command = "`"$machineInstall/unins000.exe`"" })
    $script:OnUninstall = { Remove-Item -LiteralPath $machineInstall -Recurse -Force }
    Assert-Equal 'Removed' (Remove-VSCodeLeftovers -Scope Machine -ContextMenuKeys @()) 'machine-wide install is removed through its uninstall entry'
    Assert-Equal "start $machineInstall/unins000.exe /VERYSILENT /NORESTART /SUPPRESSMSGBOXES" (@($script:Calls | Where-Object { $_ -like 'start*' }) -join '|') 'the entry is run silently'
    Assert-Equal $false (Test-Path -LiteralPath $machineInstall) 'machine install directory is gone'
    Assert-Equal $true (Test-Path -LiteralPath $userInstall) 'the machine phase leaves the per-user install to the user phase'

    Reset-Fakes
    $script:Entries = @([pscustomobject]@{ Name = 'Microsoft Visual Studio Code (User)'; Command = "`"$userInstall/unins000.exe`" /SILENT" })
    $script:OnUninstall = { Remove-Item -LiteralPath $userInstall -Recurse -Force }
    Assert-Equal 'Removed' (Remove-VSCodeLeftovers -Scope User -ContextMenuKeys @()) 'per-user install is removed through its uninstall entry'
    Assert-Equal $false (Test-Path -LiteralPath $userInstall) 'per-user install directory is gone'
    Assert-Equal $false (Test-Path -LiteralPath $userInsiders) 'the directory step clears the Insiders copy the uninstaller did not'

    Reset-Fakes; $script:Entries = @([pscustomobject]@{ Name = 'Microsoft Visual Studio Code'; Command = '"C:\x\unins000.exe"' }); $script:UninstallerExit = 5
    $failed = $false
    try { $null = Remove-VSCodeLeftovers -Scope User -ContextMenuKeys @() } catch { $failed = $_.Exception.Message -like '*exited with code 5*' }
    Assert-Equal $true $failed 'a failing uninstaller is reported as a failure'

    # --- last resort: directories and shell entries --------------------------------
    Clear-Fixture; New-Fixture
    Reset-Fakes
    Assert-Equal 'Removed' (Remove-VSCodeLeftovers -Scope User -ContextMenuKeys @($shellKey)) 'leftover directories and shell entry are removed'
    Assert-Equal $false (Test-Path -LiteralPath $userInstall) 'per-user directory removed'
    Assert-Equal $false (Test-Path -LiteralPath $userInsiders) 'per-user Insiders directory removed'
    Assert-Equal $false (Test-Path -LiteralPath $shellKey) 'shell entry removed'
    Assert-Equal $true (Test-Path -LiteralPath $machineInstall) 'user scope leaves Program Files alone'
    Assert-Equal $true (Test-Path -LiteralPath $settings) 'user settings are kept'
    Assert-Equal $true (Test-Path -LiteralPath $extensions) 'extensions are kept'
    Assert-Equal 0 @($script:Calls | Where-Object { $_ -like 'start*' }).Count 'no uninstaller runs when there is no entry'
    Assert-Equal 'Removed' (Remove-VSCodeLeftovers -Scope Machine -ContextMenuKeys @()) 'Program Files directory is removed in the machine phase'
    Assert-Equal $false (Test-Path -LiteralPath $machineInstall) 'machine directory removed'
    Assert-Equal 'Absent' (Remove-VSCodeLeftovers -Scope Machine -ContextMenuKeys @($shellKey)) 'a second run is Absent'
    Assert-Equal 'Absent' (Remove-VSCodeLeftovers -Scope User -ContextMenuKeys @($shellKey)) 'a second user run is Absent'

    # --- running editor ------------------------------------------------------------
    Clear-Fixture; New-Fixture
    Reset-Fakes; $script:Running = $true
    $null = Remove-VSCodeLeftovers -Scope User -ContextMenuKeys @()
    Assert-Equal 1 @($script:Calls | Where-Object { $_ -eq 'stop-process' }).Count 'a running VS Code is closed before removal'
    Assert-Equal $false (Test-Path -LiteralPath $userInstall) 'and the install is removed anyway'
    Reset-Fakes; $script:Running = $true
    $null = Remove-VSCodeLeftovers -Scope User -ContextMenuKeys @()
    Assert-Equal 0 $script:Calls.Count 'a running VS Code is left alone when nothing of this scope is installed'
}
finally {
    Clear-Fixture
}

if ($script:Failures -gt 0) {
    Write-Host "$script:Failures failure(s)"
    exit 1
}
Write-Host 'all passed'
