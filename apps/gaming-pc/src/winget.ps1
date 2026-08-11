# Shared winget helpers for software.ps1.
#
# winget is preferred over Chocolatey (HO-239), which costs three things this
# module exists to absorb:
#
#   1. winget.exe is an MSIX app execution alias. It is on PATH for an
#      interactive session but frequently is not for the non-interactive,
#      elevated session Ansible lands in, so it has to be resolved by hand.
#   2. Its exit codes are a wide unsigned space in which several distinct
#      values all mean "nothing to do". Treating any non-zero as failure would
#      make every second deploy fail.
#   3. `winget install` on an already-installed package is not reliably a
#      no-op, so presence is tested first rather than relied upon.
#
# Requires logging.ps1 (Write-Log) to be dot-sourced first.

# 0x8A15002B / 0x8A150062 etc. surface through $LASTEXITCODE as signed ints.
$script:WingetNoApplicableUpdate = -1978335189   # 0x8A15002B
$script:WingetPackageAlreadyInstalled = -1978335135 # 0x8A150061
$script:WingetNoInstalledPackage = -1978335212   # 0x8A150014
$script:WingetRebootRequiredCodes = @(3010, 1641)

$script:WingetPath = $null

function Get-WingetPath {
    <#
    .SYNOPSIS
        Resolves winget.exe, or throws with a message that says what to fix.
    .DESCRIPTION
        Tries PATH first, then the per-user app execution alias, then the
        WindowsApps package directory. The last one needs elevation to
        enumerate, which the machine phase of software.ps1 has.
    #>
    if ($script:WingetPath) {
        return $script:WingetPath
    }

    $onPath = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($onPath) {
        $script:WingetPath = $onPath.Source
        Write-Log "winget resolved from PATH: $($script:WingetPath)"
        return $script:WingetPath
    }

    $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path $alias) {
        $script:WingetPath = $alias
        Write-Log "winget resolved from the app execution alias: $alias"
        return $script:WingetPath
    }

    $packaged = Get-ChildItem -Path (Join-Path $env:ProgramFiles 'WindowsApps') `
        -Filter 'winget.exe' -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -like '*Microsoft.DesktopAppInstaller*' } |
        Sort-Object FullName -Descending |
        Select-Object -First 1
    if ($packaged) {
        $script:WingetPath = $packaged.FullName
        Write-Log "winget resolved from WindowsApps: $($script:WingetPath)"
        return $script:WingetPath
    }

    throw @'
winget.exe could not be found. It ships as the "App Installer" package from the
Microsoft Store; install or repair it on the machine, then re-run the deploy:

  Get-AppxPackage -Name Microsoft.DesktopAppInstaller | Reset-AppxPackage
'@
}

function Invoke-Winget {
    <#
    .SYNOPSIS
        Runs winget and returns its combined output plus exit code.
    .OUTPUTS
        Hashtable with 'ExitCode' and 'Output'.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    # Every caller here inspects the exit code itself - "not installed" and
    # "nothing to update" both arrive as non-zero and are not errors. Newer
    # PowerShell can turn a non-zero native exit into a terminating error under
    # $ErrorActionPreference = 'Stop', which would defeat that, so it is pinned
    # off for the duration of the call. Harmless on versions without it.
    $PSNativeCommandUseErrorActionPreference = $false

    $winget = Get-WingetPath
    $output = & $winget @Arguments 2>&1 | Out-String
    return @{ ExitCode = $LASTEXITCODE; Output = $output.Trim() }
}

function Test-WingetPackageInstalled {
    <#
    .SYNOPSIS
        Whether winget already tracks an installed package with this exact id.
    .DESCRIPTION
        Deliberately queries without --source. Filtering `winget list` by source
        restricts it to packages whose *available* version comes from that
        source, which hides a package installed outside winget - exactly the
        case where re-installing would be wrong.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id
    )

    $result = Invoke-Winget @(
        'list', '--id', $Id, '--exact',
        '--accept-source-agreements', '--disable-interactivity'
    )

    if ($result.ExitCode -ne 0) {
        return $false
    }

    # `winget list` with no match still exits 0 on some versions, printing
    # "No installed package found matching input criteria." Match the id
    # instead of trusting the exit code alone.
    return $result.Output -match [regex]::Escape($Id)
}

function Test-WingetSuccess {
    param(
        [Parameter(Mandatory = $true)]
        [int]$ExitCode
    )

    if ($ExitCode -eq 0) { return $true }
    if ($ExitCode -eq $script:WingetNoApplicableUpdate) { return $true }
    if ($ExitCode -eq $script:WingetPackageAlreadyInstalled) { return $true }
    if ($script:WingetRebootRequiredCodes -contains $ExitCode) { return $true }
    return $false
}

function Install-WingetPackage {
    <#
    .SYNOPSIS
        Installs a package if it is not already present.
    .OUTPUTS
        'Present' when nothing was done, 'Installed' on a successful install.
        Throws on failure so the caller decides whether that is fatal.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [ValidateSet('winget', 'msstore')]
        [string]$Source = 'winget',

        [ValidateSet('machine', 'user', 'default')]
        [string]$Scope = 'default'
    )

    if (Test-WingetPackageInstalled -Id $Id) {
        Write-Log "  $Name ($Id): already installed"
        return 'Present'
    }

    $arguments = @(
        'install', '--id', $Id, '--exact',
        '--source', $Source,
        '--silent',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity'
    )
    # msstore packages are MSIX and have no installer scope to choose; passing
    # --scope there makes winget reject the command outright.
    if ($Scope -ne 'default' -and $Source -eq 'winget') {
        $arguments += @('--scope', $Scope)
    }

    Write-Log "  $Name ($Id): installing from $Source..."
    $result = Invoke-Winget $arguments

    if (-not (Test-WingetSuccess -ExitCode $result.ExitCode)) {
        # Name the source and the scope that were asked for: the likeliest
        # cause of an unrecognised code is a manifest that no longer publishes
        # an installer matching them, and a bare code does not say that.
        throw "winget install of $Name ($Id) from source '$Source' with scope '$Scope' failed with exit code $($result.ExitCode).`n$($result.Output)"
    }

    # winget reporting the package as already installed, or as having no
    # applicable update, is a genuine no-op - Test-WingetPackageInstalled
    # cannot see an installed MSIX by its Store product id, so this is the
    # path the msstore entries take on every deploy after the first.
    if ($result.ExitCode -eq $script:WingetPackageAlreadyInstalled -or
        $result.ExitCode -eq $script:WingetNoApplicableUpdate) {
        Write-Log "  $Name ($Id): already installed"
        return 'Present'
    }

    if ($script:WingetRebootRequiredCodes -contains $result.ExitCode) {
        Write-Log "  $Name ($Id): installed; the machine wants a reboot to finish"
    }
    else {
        Write-Log "  $Name ($Id): installed"
    }
    return 'Installed'
}

function Uninstall-WingetPackage {
    <#
    .SYNOPSIS
        Removes a package if winget tracks it as installed.
    .OUTPUTS
        'Absent' when nothing was done, 'Removed' on a successful uninstall.
        Throws on failure.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (-not (Test-WingetPackageInstalled -Id $Id)) {
        Write-Log "  $Name ($Id): not installed via winget"
        return 'Absent'
    }

    Write-Log "  $Name ($Id): uninstalling..."
    $result = Invoke-Winget @(
        'uninstall', '--id', $Id, '--exact',
        '--silent',
        '--accept-source-agreements',
        '--disable-interactivity'
    )

    if ($result.ExitCode -eq $script:WingetNoInstalledPackage) {
        Write-Log "  $Name ($Id): already absent"
        return 'Absent'
    }

    if (-not (Test-WingetSuccess -ExitCode $result.ExitCode)) {
        throw "winget uninstall of $Name ($Id) failed with exit code $($result.ExitCode).`n$($result.Output)"
    }

    Write-Log "  $Name ($Id): removed"
    return 'Removed'
}
