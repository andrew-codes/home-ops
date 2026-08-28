# WinNUT-Client (NUT UPS monitoring client) helpers for software.ps1 and
# scripts/configure-nut-client.ps1.
#
# WinNUT-Client has no CLI or plain config file of its own to script against:
# its settings are a per-user .NET ClientSettingsSection (My.Settings), stored
# at a path derived from a hash of the installed exe's location that is not
# practical to reproduce by hand. Rather than guess that path, this loads the
# app's own compiled Settings class by reflection and calls its own Save() -
# the same mechanism its Preferences dialog uses - so the file this writes is
# guaranteed to match what the running app actually reads. Verified against
# the published source at https://github.com/nutdotnet/WinNUT-Client
# (WinNUT_V2/WinNUT-Client/My Project/Settings.settings and
# WinNUT_V2/WinNUT-Client_Common/SerializedProtectedString.vb), not
# execution-tested against a real Windows host - see README.md.
#
# Requires logging.ps1 (Write-Log) to be dot-sourced first.

function Get-WinNutClientInstallDirectory {
    <#
    .SYNOPSIS
        Finds where winget installed WinNUT-Client.
    .DESCRIPTION
        Matched by registered DisplayName rather than a hardcoded MSI
        ProductCode: upstream mints a new ProductCode per release, but the
        registered name has stayed "WinNUT-Client". The winget manifest
        installs a per-user MSI, so this only needs to check HKCU - but both
        hives are checked in case a future release ships a machine-scope
        installer.
    #>
    $uninstallRoots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $entry = Get-ItemProperty -Path $uninstallRoots -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like 'WinNUT-Client*' -and $_.InstallLocation } |
        Select-Object -First 1

    if (-not $entry) {
        return $null
    }
    return $entry.InstallLocation.TrimEnd('\')
}

function Set-WinNutClientSettings {
    <#
    .SYNOPSIS
        Points WinNUT-Client at the NUT server and configures its shutdown
        thresholds, via the app's own compiled Settings class.
    .DESCRIPTION
        Idempotent: only calls Save() when a value actually needs to change.
        Must run in the same Windows user session WinNUT-Client will run in -
        its NUT_Username/NUT_Password fields are DPAPI-protected with
        DataProtectionScope.CurrentUser, so a value protected under one
        account cannot be read back correctly under another.
    .OUTPUTS
        'Configured' if any setting changed, otherwise 'Present'.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$ServerAddress,
        [Parameter(Mandatory = $true)] [int]$ServerPort,
        [Parameter(Mandatory = $true)] [string]$UpsName,
        [Parameter(Mandatory = $true)] [string]$MonitorUsername,
        [Parameter(Mandatory = $true)] [string]$MonitorPassword,
        [Parameter(Mandatory = $true)] [int]$BatteryChargeFloor
    )

    $installDir = Get-WinNutClientInstallDirectory
    if (-not $installDir) {
        throw 'WinNUT-Client install directory could not be found via its registered uninstall entry.'
    }

    $exePath = Join-Path $installDir 'WinNUT-Client.exe'
    $commonDllPath = Join-Path $installDir 'WinNUT-Client_Common.dll'
    if (-not (Test-Path $exePath) -or -not (Test-Path $commonDllPath)) {
        throw "WinNUT-Client.exe or WinNUT-Client_Common.dll not found under $installDir."
    }

    # Loading these only inspects their types via reflection - it does not run
    # the app's Sub Main or show its UI.
    $commonAssembly = [System.Reflection.Assembly]::LoadFrom($commonDllPath)
    $exeAssembly = [System.Reflection.Assembly]::LoadFrom($exePath)

    $settingsType = $exeAssembly.GetType('WinNUT_Client.My.MySettings')
    if (-not $settingsType) {
        throw 'WinNUT_Client.My.MySettings type not found - WinNUT-Client may have changed its internal structure.'
    }
    $settings = $settingsType.GetProperty('Default').GetValue($null)

    $protectedStringType = $commonAssembly.GetType('WinNUT_Client_Common.SerializedProtectedString')
    if (-not $protectedStringType) {
        throw 'WinNUT_Client_Common.SerializedProtectedString type not found - WinNUT-Client may have changed its internal structure.'
    }

    function New-ProtectedStringValue([string]$PlainText) {
        return [Activator]::CreateInstance($protectedStringType, @([string]$PlainText, $false))
    }

    function Get-CurrentPlainValue([string]$PropertyName) {
        $value = $settings.$PropertyName
        if (-not $value) { return $null }
        return $value.ToString()
    }

    $changed = $false

    $desired = [ordered]@{
        NUT_ServerAddress = $ServerAddress
        NUT_ServerPort    = $ServerPort
        NUT_UPSName       = $UpsName
        NUT_AutoReconnect = $true
        StartWithWindows  = $true
        MinimizeOnStart   = $true
        CloseToTray       = $true
        MinimizeToTray    = $true
        PW_RespectFSD     = $true
        PW_BattChrgFloor  = $BatteryChargeFloor
        IsFirstRun        = $false
    }

    foreach ($key in $desired.Keys) {
        if ("$($settings.$key)" -ne "$($desired[$key])") {
            $settings.$key = $desired[$key]
            $changed = $true
        }
    }

    if ((Get-CurrentPlainValue 'NUT_Username') -ne $MonitorUsername) {
        $settings.NUT_Username = New-ProtectedStringValue $MonitorUsername
        $changed = $true
    }
    if ((Get-CurrentPlainValue 'NUT_Password') -ne $MonitorPassword) {
        $settings.NUT_Password = New-ProtectedStringValue $MonitorPassword
        $changed = $true
    }

    if ($changed) {
        $settings.Save()
        Write-Log '  WinNUT-Client: settings updated'
        return 'Configured'
    }

    Write-Log '  WinNUT-Client: settings already up to date'
    return 'Present'
}

function Start-WinNutClientIfNotRunning {
    <#
    .SYNOPSIS
        Ensures WinNUT-Client is actually running and monitoring, not just
        installed and configured - StartWithWindows only takes effect on the
        next login, and this is monitoring plus auto-shutdown, not merely a
        setting.
    .OUTPUTS
        'Started' if it was launched, otherwise 'Present'.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$InstallDirectory
    )

    if (Get-Process -Name 'WinNUT-Client' -ErrorAction SilentlyContinue) {
        Write-Log '  WinNUT-Client: already running'
        return 'Present'
    }

    Start-Process -FilePath (Join-Path $InstallDirectory 'WinNUT-Client.exe')
    Write-Log '  WinNUT-Client: started'
    return 'Started'
}
