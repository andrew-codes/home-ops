# WinNUT-Client (NUT UPS monitoring client) helpers for software.ps1 and
# scripts/configure-nut-client.ps1.
#
# WinNUT-Client has no CLI or plain config file of its own to script against.
# An earlier version of this file loaded the app's compiled Settings class by
# reflection (My.Settings), matching the schema on GitHub's main branch and
# documented as "not execution-tested". Running it against a real host (winget
# currently publishes v2.2.8719) showed that schema does not exist in any
# shipped release: MySettings has zero properties, compile-time or dynamic, at
# both v2.2.8719 and the latest real tag (v7.7.1.0) - main is ahead of every
# release. The real, confirmed mechanism (found via a before/after registry
# diff around WinNUT-Client's own Preferences dialog, against v2.2.8719) is a
# plain flat key tree under HKCU:\Software\WinNUT, one subkey per settings
# page:
#
#   Appareance\{MinimizeToTray,MinimizeOnStart,CloseToTray,StartWithWindows}
#   Connexion\{ServerAddress,Port,UPSName,NutLogin,NutPassword,AutoReconnect}
#   Power\{ShutdownLimitBatteryCharge,Follow_FSD,...}
#
# NutLogin/NutPassword are DPAPI-protected (DataProtectionScope.CurrentUser)
# and Unicode-encoded before protecting, matching WinNUT-Client_Common's
# SerializedProtectedString.vb exactly - same CryptProtectData blob format,
# reproduced directly here rather than through that type.
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

function Protect-NutClientString {
    <#
    .SYNOPSIS
        DPAPI-protects a string the same way SerializedProtectedString.vb
        does: Unicode bytes, CurrentUser scope, no extra entropy.
    #>
    param([Parameter(Mandatory = $true)] [string]$PlainText)

    $bytes = [System.Text.Encoding]::Unicode.GetBytes($PlainText)
    $protected = [System.Security.Cryptography.ProtectedData]::Protect(
        $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Convert]::ToBase64String($protected)
}

function Unprotect-NutClientString {
    <#
    .SYNOPSIS
        Reverses Protect-NutClientString, for idempotency comparisons.
    .OUTPUTS
        The plaintext, or $null if the stored value is absent or cannot be
        unprotected (e.g. it was written under a different Windows account -
        DPAPI CurrentUser-scoped values are not portable across accounts).
    #>
    param([string]$Protected)

    if ([string]::IsNullOrEmpty($Protected)) {
        return $null
    }
    try {
        $bytes = [Convert]::FromBase64String($Protected)
        $plain = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        return [System.Text.Encoding]::Unicode.GetString($plain)
    }
    catch {
        return $null
    }
}

function Set-NutClientRegistryValues {
    <#
    .SYNOPSIS
        Idempotently applies a table of registry values under one key,
        creating the key first if it does not exist yet (a machine that has
        never launched WinNUT-Client once has none of this key tree).
    .OUTPUTS
        $true if anything actually changed, otherwise $false.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [hashtable]$Values
    )

    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }

    $changed = $false
    $current = Get-ItemProperty -Path $Path -ErrorAction SilentlyContinue

    foreach ($name in $Values.Keys) {
        $desired = $Values[$name]
        $existing = if ($current) { $current.$name } else { $null }
        if ("$existing" -ne "$desired") {
            New-ItemProperty -Path $Path -Name $name -Value $desired -Force | Out-Null
            $changed = $true
        }
    }

    return $changed
}

function Set-WinNutClientSettings {
    <#
    .SYNOPSIS
        Points WinNUT-Client at the NUT server and configures its shutdown
        thresholds, by writing its registry settings directly.
    .DESCRIPTION
        Idempotent: only writes a value when it actually needs to change.
        Must run in the same Windows user session WinNUT-Client will run in -
        NutLogin/NutPassword are DPAPI-protected with
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

    $base = 'HKCU:\Software\WinNUT'
    $changed = $false

    $changed = (Set-NutClientRegistryValues -Path "$base\Appareance" -Values @{
            MinimizeToTray   = 'True'
            MinimizeOnStart  = 'True'
            CloseToTray      = 'True'
            StartWithWindows = 'True'
        }) -or $changed

    $connexionPath = "$base\Connexion"
    $changed = (Set-NutClientRegistryValues -Path $connexionPath -Values @{
            ServerAddress = $ServerAddress
            Port          = $ServerPort
            UPSName       = $UpsName
            AutoReconnect = 'True'
        }) -or $changed

    # NutLogin/NutPassword are handled separately from the flat values above:
    # DPAPI protection is not deterministic (a fresh random blob each time),
    # so equality has to be checked against the *decrypted* current value,
    # not the stored ciphertext.
    $currentConnexion = Get-ItemProperty -Path $connexionPath -ErrorAction SilentlyContinue
    if ((Unprotect-NutClientString $currentConnexion.NutLogin) -ne $MonitorUsername) {
        New-ItemProperty -Path $connexionPath -Name 'NutLogin' `
            -Value (Protect-NutClientString $MonitorUsername) -Force | Out-Null
        $changed = $true
    }
    if ((Unprotect-NutClientString $currentConnexion.NutPassword) -ne $MonitorPassword) {
        New-ItemProperty -Path $connexionPath -Name 'NutPassword' `
            -Value (Protect-NutClientString $MonitorPassword) -Force | Out-Null
        $changed = $true
    }

    $changed = (Set-NutClientRegistryValues -Path "$base\Power" -Values @{
            ShutdownLimitBatteryCharge = $BatteryChargeFloor
            Follow_FSD                 = 'True'
        }) -or $changed

    if ($changed) {
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
