# Creates the games folder on the games drive (storage.ps1) and registers it as
# a Steam library, by adding an entry to Steam's config\libraryfolders.vdf.
# See README.md#games-drive-and-steam-library for what this can and cannot do.
#
# What it does:
#   * creates G:\SteamLibrary (and its steamapps folder) when the drive is there;
#   * adds that folder to libraryfolders.vdf unless it is already listed;
#   * leaves every other byte of the file alone - existing libraries, their app
#     lists and Steam's other data are kept exactly as they are;
#   * keeps a timestamped backup next to the file before it writes;
#   * writes through a temp file and a rename, so Steam never reads a half file;
#   * creates the file (with Steam's own folder as library 0) when Steam has
#     never run, so the first launch already knows the games library.
#
# What it will not do:
#   * edit the file while Steam is running - Steam rewrites it from memory when
#     it exits, which would drop the entry. It warns and changes nothing; close
#     Steam and re-run.
#   * make the games drive the DEFAULT install location. Steam picks the library
#     in its install dialog; the owner chooses it there (or, once, moves the
#     default - see the README).
#   * fail the deploy for a missing drive or Steam: those are warnings.
#
# Run elevated by scripts/deploy.yml after software.ps1 has installed Steam. The
# last line, RESULT, is what deploy.yml reads, so keep its shape.

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidatePattern('^[A-Za-z]$')]
    [string]$DriveLetter = 'G',
    [ValidatePattern('^[A-Za-z0-9 _.-]{1,64}$')]
    [string]$FolderName = 'SteamLibrary',
    # Overrides where Steam is installed. Empty means ask the registry.
    [string]$SteamPath = ''
)

$ErrorActionPreference = 'Stop'

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path $ScriptDir 'logging.ps1')

$script:Changed = 0
$script:Failures = New-Object System.Collections.Generic.List[string]
$script:Warnings = New-Object System.Collections.Generic.List[string]

function Add-SteamWarning {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Log "  WARNING $Message"
    $script:Warnings.Add($Message)
}

# ---------------------------------------------------------------------------
# libraryfolders.vdf
#
# Valve's text KeyValues format: quoted strings, { } blocks, // comments, and
# backslash escapes inside strings (so a Windows path is written with doubled
# backslashes). This is a tokenizer plus just enough structure to find the
# libraries and the root's closing brace; the edit is a text insertion, never a
# re-serialisation, which is what keeps every other byte intact.
# ---------------------------------------------------------------------------

function ConvertTo-VdfTokens {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    $tokens = New-Object System.Collections.Generic.List[object]
    $i = 0
    while ($i -lt $Text.Length) {
        $c = $Text[$i]
        if ([char]::IsWhiteSpace($c)) { $i++; continue }
        if ($c -eq '/' -and $i + 1 -lt $Text.Length -and $Text[$i + 1] -eq '/') {
            while ($i -lt $Text.Length -and $Text[$i] -ne "`n") { $i++ }
            continue
        }
        if ($c -eq '{' -or $c -eq '}') {
            $tokens.Add(@{ Type = [string]$c; Value = [string]$c; Start = $i })
            $i++
            continue
        }
        if ($c -eq '"') {
            $start = $i
            $i++
            $sb = New-Object System.Text.StringBuilder
            $closed = $false
            while ($i -lt $Text.Length) {
                $d = $Text[$i]
                if ($d -eq '\' -and $i + 1 -lt $Text.Length) {
                    $e = $Text[$i + 1]
                    switch ($e) {
                        'n' { [void]$sb.Append("`n") }
                        't' { [void]$sb.Append("`t") }
                        default { [void]$sb.Append($e) }
                    }
                    $i += 2
                    continue
                }
                if ($d -eq '"') { $closed = $true; $i++; break }
                [void]$sb.Append($d)
                $i++
            }
            if (-not $closed) { throw 'unterminated string' }
            $tokens.Add(@{ Type = 'String'; Value = $sb.ToString(); Start = $start })
            continue
        }
        throw "unexpected character '$c' at offset $i"
    }
    return , $tokens
}

function Get-VdfLibraryFolders {
    <#
    .SYNOPSIS
        Reads libraryfolders.vdf text into its libraries and the insertion point.
    .OUTPUTS
        An object with Libraries (Key, Path), NextKey (the next free index) and
        InsertAt (offset of the root's closing brace). Throws when the text is
        not a well-formed libraryfolders file, so the caller leaves it alone.
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    $tokens = ConvertTo-VdfTokens -Text $Text
    if ($tokens.Count -lt 3 -or $tokens[0].Type -ne 'String' -or $tokens[0].Value -ne 'libraryfolders' -or $tokens[1].Type -ne '{') {
        throw 'it does not start with a "libraryfolders" block'
    }

    $libraries = New-Object System.Collections.Generic.List[object]
    $nextKey = 0
    $i = 2
    $closeAt = -1
    while ($i -lt $tokens.Count) {
        $token = $tokens[$i]
        if ($token.Type -eq '}') { $closeAt = $token.Start; $i++; break }
        if ($token.Type -ne 'String') { throw "unexpected '$($token.Type)' at offset $($token.Start)" }
        $key = $token.Value
        $i++
        if ($i -ge $tokens.Count) { throw 'it ends in the middle of an entry' }
        if ($tokens[$i].Type -eq 'String') { $i++; continue }

        # A block: collect its direct "path" value, skip nested blocks (apps).
        $i++
        $depth = 1
        $path = $null
        while ($i -lt $tokens.Count -and $depth -gt 0) {
            $t = $tokens[$i]
            if ($t.Type -eq '{') { $depth++; $i++; continue }
            if ($t.Type -eq '}') { $depth--; $i++; continue }
            if ($depth -eq 1 -and $t.Value -eq 'path' -and $i + 1 -lt $tokens.Count -and $tokens[$i + 1].Type -eq 'String') {
                $path = $tokens[$i + 1].Value
                $i += 2
                continue
            }
            $i++
        }
        if ($depth -ne 0) { throw 'it ends inside an unclosed block' }
        $libraries.Add([pscustomobject]@{ Key = $key; Path = $path })
        $parsed = 0
        if ([int]::TryParse($key, [ref]$parsed) -and $parsed -ge $nextKey) { $nextKey = $parsed + 1 }
    }
    if ($closeAt -lt 0) { throw 'the "libraryfolders" block is never closed' }

    return [pscustomobject]@{ Libraries = $libraries.ToArray(); NextKey = $nextKey; InsertAt = $closeAt }
}

function ConvertTo-VdfString {
    param([Parameter(Mandatory = $true)][string]$Value)
    return $Value.Replace('\', '\\').Replace('"', '\"')
}

function ConvertTo-ComparablePath {
    param([string]$Path)
    if (-not $Path) { return '' }
    return $Path.Replace('/', '\').TrimEnd('\').ToLowerInvariant()
}

function New-VdfLibraryEntry {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$NewLine
    )
    $lines = @(
        "`t`"$Key`"",
        "`t{",
        "`t`t`"path`"`t`t`"$(ConvertTo-VdfString $Path)`"",
        "`t`t`"label`"`t`t`"`"",
        "`t`t`"contentid`"`t`t`"0`"",
        "`t`t`"totalsize`"`t`t`"0`"",
        "`t`t`"apps`"",
        "`t`t{",
        "`t`t}",
        "`t}"
    )
    return ($lines -join $NewLine) + $NewLine
}

function Add-VdfLibrary {
    <#
    .SYNOPSIS
        Returns the vdf text with the library added, or the same text when it is
        already listed.
    .DESCRIPTION
        $Text may be $null or empty (Steam has never run): then the result is a
        new file listing Steam's own folder as library 0 and the games folder as 1.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string]$LibraryPath,
        [Parameter(Mandatory = $true)][string]$SteamPath
    )

    $nl = if ($Text -and $Text.Contains("`r`n")) { "`r`n" } else { "`n" }

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ('"libraryfolders"' + $nl + '{' + $nl +
            (New-VdfLibraryEntry -Key '0' -Path $SteamPath -NewLine $nl) +
            (New-VdfLibraryEntry -Key '1' -Path $LibraryPath -NewLine $nl) +
            '}' + $nl)
    }

    $parsed = Get-VdfLibraryFolders -Text $Text
    $wanted = ConvertTo-ComparablePath $LibraryPath
    if ($parsed.Libraries | Where-Object { (ConvertTo-ComparablePath $_.Path) -eq $wanted }) {
        return $Text
    }

    # Insert at the start of the line holding the root's closing brace, so the
    # file keeps its own indentation and line endings.
    $at = $parsed.InsertAt
    while ($at -gt 0 -and ($Text[$at - 1] -eq ' ' -or $Text[$at - 1] -eq "`t")) { $at-- }
    $entry = New-VdfLibraryEntry -Key ([string]$parsed.NextKey) -Path $LibraryPath -NewLine $nl
    if ($at -gt 0 -and $Text[$at - 1] -ne "`n") { $entry = $nl + $entry }
    return $Text.Insert($at, $entry)
}

# ---------------------------------------------------------------------------
# The machine
# ---------------------------------------------------------------------------

function Get-PathDrive {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ($Path -match '^([A-Za-z]:)') { return $Matches[1] }
    return ''
}

function Get-SteamInstallPath {
    param([string]$Override)
    if ($Override) { return $Override }
    $registered = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -Name InstallPath -ErrorAction SilentlyContinue).InstallPath
    if ($registered) { return $registered }
    return Join-Path ${env:ProgramFiles(x86)} 'Steam'
}

function Test-SteamRunning {
    return $null -ne (Get-Process -Name 'steam', 'steamwebhelper' -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Register-SteamLibrary {
    <#
    .OUTPUTS
        'Installed' when it changed anything, 'Present' otherwise.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$LibraryPath,
        [Parameter(Mandatory = $true)][string]$SteamPath
    )

    $changed = $false
    $drive = Get-PathDrive -Path $LibraryPath
    if (-not (Test-Path "$drive\")) {
        Add-SteamWarning ("the games drive $drive is not present, so no Steam library was registered. " +
            'Remedy: build the games drive first (storage.ps1 and the runbook in apps/gaming-pc/docs/rebuild-runbook.md), then re-run the deploy.')
        return 'Present'
    }

    $steamsApps = Join-Path $LibraryPath 'steamapps'
    if (-not (Test-Path $steamsApps)) {
        if ($WhatIfPreference) { Write-Log "  WHATIF: would create $steamsApps" }
        else { New-Item -ItemType Directory -Path $steamsApps -Force | Out-Null }
        Write-Log "  created $steamsApps"
        $changed = $true
    }

    if (-not (Test-Path (Join-Path $SteamPath 'steam.exe'))) {
        Add-SteamWarning "Steam is not installed at $SteamPath, so the library was not registered. Remedy: re-run the deploy once software.ps1 has installed Steam."
        return $(if ($changed) { 'Installed' } else { 'Present' })
    }

    $configDir = Join-Path $SteamPath 'config'
    $vdf = Join-Path $configDir 'libraryfolders.vdf'
    $existing = if (Test-Path $vdf) { [System.IO.File]::ReadAllText($vdf) } else { $null }

    try {
        $updated = Add-VdfLibrary -Text $existing -LibraryPath $LibraryPath -SteamPath $SteamPath
    }
    catch {
        Add-SteamWarning "$vdf could not be read ($($_.Exception.Message)); it was left untouched. Remedy: open Steam > Settings > Storage and add $LibraryPath by hand, or fix the file."
        return $(if ($changed) { 'Installed' } else { 'Present' })
    }

    if ($updated -eq $existing) {
        Write-Log "  Steam library $LibraryPath is already registered"
        return $(if ($changed) { 'Installed' } else { 'Present' })
    }

    if (Test-SteamRunning) {
        Add-SteamWarning "Steam is running, so $LibraryPath was not added to $vdf (Steam rewrites the file when it exits and would drop the entry). Remedy: exit Steam from its tray icon and re-run the deploy."
        return $(if ($changed) { 'Installed' } else { 'Present' })
    }

    if ($WhatIfPreference) {
        Write-Log "  WHATIF: would add $LibraryPath to $vdf"
        return 'Installed'
    }

    if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
    if ($null -ne $existing) {
        $backup = "$vdf.gaming-pc-$(Get-Date -Format 'yyyyMMddHHmmss').bak"
        Copy-Item -LiteralPath $vdf -Destination $backup
        Write-Log "  backed up $vdf to $backup"
    }
    $temp = "$vdf.gaming-pc.tmp"
    [System.IO.File]::WriteAllText($temp, $updated, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temp -Destination $vdf -Force

    # Prove the write: what is on disk must parse and list the library.
    $check = Get-VdfLibraryFolders -Text ([System.IO.File]::ReadAllText($vdf))
    if (-not ($check.Libraries | Where-Object { (ConvertTo-ComparablePath $_.Path) -eq (ConvertTo-ComparablePath $LibraryPath) })) {
        throw "$vdf does not list $LibraryPath after the write"
    }
    Write-Log "  registered Steam library $LibraryPath in $vdf"
    return 'Installed'
}

# Dot-sourcing (the tests do) defines the functions and runs nothing.
if ($MyInvocation.InvocationName -eq '.') { return }

$libraryPath = "${DriveLetter}:\$FolderName"
$steam = Get-SteamInstallPath -Override $SteamPath
Write-Log "=== steam-library.ps1 library=$libraryPath steam=$steam whatif=$($WhatIfPreference) ==="

try {
    $outcome = Register-SteamLibrary -LibraryPath $libraryPath -SteamPath $steam
    if ($outcome -eq 'Installed' -and -not $WhatIfPreference) { $script:Changed++ }
}
catch {
    $message = "steam library : $($_.Exception.Message)"
    Write-Log "  FAILED $message"
    $script:Failures.Add($message)
}

foreach ($warning in $script:Warnings) {
    Write-Log "SUMMARY warning: $warning"
}
foreach ($failure in $script:Failures) {
    Write-Log "SUMMARY failure: $failure"
}

# Parsed by scripts/deploy.yml to decide changed/failed, so keep the shape.
Write-Log ("RESULT changed={0} warnings={1} failures={2}" -f `
        $script:Changed, $script:Warnings.Count, $script:Failures.Count)

if ($script:Failures.Count -gt 0) {
    exit 1
}
exit 0
