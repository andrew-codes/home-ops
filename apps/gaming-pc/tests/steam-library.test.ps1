# Tests for src/steam-library.ps1. Run with:
#   pwsh -NoProfile -File apps/gaming-pc/tests/steam-library.test.ps1
# Plain assertions, no Pester. It runs against a throwaway folder standing in for
# Steam's install directory and the games drive; nothing real is touched.

$ErrorActionPreference = 'Stop'

$work = Join-Path ([IO.Path]::GetTempPath()) "gaming-pc-steam-test-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $work | Out-Null
foreach ($f in 'steam-library.ps1', 'logging.ps1') { Copy-Item (Join-Path $PSScriptRoot '..' 'src' $f) $work }
. (Join-Path $work 'steam-library.ps1')

$script:TestFailures = 0
function Assert-Equal {
    param($Expected, $Actual, [string]$What)
    if ("$Expected" -ne "$Actual") {
        Write-Host "FAIL $What`n  expected: $Expected`n  actual:   $Actual"
        $script:TestFailures++
    }
    else { Write-Host "ok   $What" }
}

# What Steam writes: tabs, LF, nested apps blocks, and a second library.
$steamDir = 'C:\Program Files (x86)\Steam'
$existing = @'
"libraryfolders"
{
	"0"
	{
		"path"		"C:\\Program Files (x86)\\Steam"
		"label"		""
		"contentid"		"1234567890"
		"totalsize"		"0"
		"apps"
		{
			"228980"		"302140"
			"730"		"41203958"
		}
	}
	"1"
	{
		"path"		"D:\\Games"
		"label"		""
		"contentid"		"987"
		"totalsize"		"1000204883968"
		"apps"
		{
			"1245620"		"61204811"
		}
	}
}
'@ -replace "`r`n", "`n"

# --- Parsing ---------------------------------------------------------------

$parsed = Get-VdfLibraryFolders -Text $existing
Assert-Equal 2 $parsed.Libraries.Count 'parses both libraries'
Assert-Equal 'D:\Games' $parsed.Libraries[1].Path 'unescapes the doubled backslashes in a path'
Assert-Equal 2 $parsed.NextKey 'the next key follows the highest one'

# --- Adding a library keeps everything else ---------------------------------

$updated = Add-VdfLibrary -Text $existing -LibraryPath 'G:\SteamLibrary' -SteamPath $steamDir
$after = Get-VdfLibraryFolders -Text $updated
Assert-Equal 3 $after.Libraries.Count 'adds one library'
Assert-Equal 'G:\SteamLibrary' $after.Libraries[2].Path 'the new library is G:\SteamLibrary'
Assert-Equal '2' $after.Libraries[2].Key 'the new library takes the next key'
Assert-Equal 'C:\Program Files (x86)\Steam' $after.Libraries[0].Path 'library 0 is untouched'
Assert-Equal 'D:\Games' $after.Libraries[1].Path 'library 1 is untouched'
Assert-Equal 'True' ($updated.Contains('"228980"		"302140"') -and $updated.Contains('"1245620"		"61204811"') -and $updated.Contains('"contentid"		"987"')) 'app lists and other values are preserved verbatim'
Assert-Equal 'True' ($updated.StartsWith($existing.Substring(0, $existing.LastIndexOf('}')))) 'every original byte before the closing brace is unchanged'
Assert-Equal 'True' $updated.Contains('"path"		"G:\\SteamLibrary"') 'the path is written with escaped backslashes'
Assert-Equal 'False' $updated.Contains("`r") 'LF files stay LF'

# Idempotent, whatever the case or slashes.
Assert-Equal 'True' ((Add-VdfLibrary -Text $updated -LibraryPath 'G:\SteamLibrary' -SteamPath $steamDir) -ceq $updated) 'adding a registered library changes nothing'
Assert-Equal 'True' ((Add-VdfLibrary -Text $updated -LibraryPath 'g:/steamlibrary/' -SteamPath $steamDir) -ceq $updated) 'path comparison ignores case, slashes and a trailing separator'

# CRLF files stay CRLF.
$crlf = $existing -replace "`n", "`r`n"
$crlfUpdated = Add-VdfLibrary -Text $crlf -LibraryPath 'G:\SteamLibrary' -SteamPath $steamDir
Assert-Equal 'False' ($crlfUpdated -match "[^\r]\n") 'CRLF files stay CRLF'
Assert-Equal 3 (Get-VdfLibraryFolders -Text $crlfUpdated).Libraries.Count 'CRLF: adds one library'

# Steam has never run: a correct file with Steam's own folder as library 0.
$fresh = Add-VdfLibrary -Text $null -LibraryPath 'G:\SteamLibrary' -SteamPath $steamDir
$freshParsed = Get-VdfLibraryFolders -Text $fresh
Assert-Equal "$steamDir,G:\SteamLibrary" (($freshParsed.Libraries | ForEach-Object Path) -join ',') 'no file yet: creates Steam and games libraries'
Assert-Equal '0,1' (($freshParsed.Libraries | ForEach-Object Key) -join ',') 'no file yet: keys are 0 and 1'

# A damaged file is refused, never repaired by guessing.
foreach ($bad in '', '"other" { }', '"libraryfolders" { "0" { "path" "C:\\x" ', '"libraryfolders" "oops"') {
    $threw = $false
    try { [void](Get-VdfLibraryFolders -Text $bad) } catch { $threw = $true }
    Assert-Equal 'True' $threw "refuses malformed input: $bad"
}

# --- On a machine ----------------------------------------------------------

# Register-SteamLibrary against real folders under $work. The "drive" of the
# library path is stubbed to a throwaway folder, since these paths are not drive
# letters on the machines the tests run on.
function Get-PathDrive { param([string]$Path) $script:GamesRoot.TrimEnd('/') }

function New-World {
    param([bool]$SteamInstalled = $true, [string]$Vdf = $null, [bool]$DriveExists = $true)
    $root = Join-Path $work ([guid]::NewGuid().ToString('N'))
    $script:GamesRoot = Join-Path $root 'drive'
    $steam = Join-Path $root 'Steam'
    New-Item -ItemType Directory -Path $steam | Out-Null
    if ($DriveExists) { New-Item -ItemType Directory -Path $script:GamesRoot | Out-Null }
    if ($SteamInstalled) { New-Item -ItemType File -Path (Join-Path $steam 'steam.exe') | Out-Null }
    if ($Vdf) {
        New-Item -ItemType Directory -Path (Join-Path $steam 'config') | Out-Null
        [IO.File]::WriteAllText((Join-Path $steam 'config' 'libraryfolders.vdf'), $Vdf)
    }
    @{ Steam = $steam; Library = (Join-Path $script:GamesRoot 'SteamLibrary'); Vdf = (Join-Path $steam 'config' 'libraryfolders.vdf') }
}
$script:SteamRunning = $false
function Test-SteamRunning { $script:SteamRunning }

function Invoke-Register {
    param($World)
    $script:Warnings.Clear()
    $outcome = Register-SteamLibrary -LibraryPath $World.Library -SteamPath $World.Steam 6>&1 | Where-Object { $_ -is [string] -or $true } | Select-Object -Last 1
    [pscustomobject]@{ Outcome = "$outcome"; Warnings = @($script:Warnings) }
}

# Existing file: edited, backed up, folder created.
$w = New-World -Vdf $existing.Replace('D:\\Games', 'D:\\Games')
$before = [IO.File]::ReadAllText($w.Vdf)
$r = Invoke-Register $w
Assert-Equal 'Installed' $r.Outcome 'registers the library'
Assert-Equal 'True' (Test-Path (Join-Path $w.Library 'steamapps')) 'creates the library folder and its steamapps'
Assert-Equal 3 (Get-VdfLibraryFolders -Text ([IO.File]::ReadAllText($w.Vdf))).Libraries.Count 'the file now lists three libraries'
$backups = @(Get-ChildItem (Split-Path -Parent $w.Vdf) -Filter 'libraryfolders.vdf.gaming-pc-*.bak')
Assert-Equal 1 $backups.Count 'keeps one backup'
Assert-Equal 'True' ([IO.File]::ReadAllText($backups[0].FullName) -ceq $before) 'the backup is the original file, byte for byte'
Assert-Equal 'False' (Test-Path "$($w.Vdf).gaming-pc.tmp") 'leaves no temp file behind'

# Second run: nothing to do, no second backup.
$r = Invoke-Register $w
Assert-Equal 'Present' $r.Outcome 're-running changes nothing'
Assert-Equal 1 @(Get-ChildItem (Split-Path -Parent $w.Vdf) -Filter 'libraryfolders.vdf.gaming-pc-*.bak').Count 're-running makes no second backup'

# Steam has never run: no config folder, no file.
$w = New-World
$r = Invoke-Register $w
Assert-Equal 'Installed' $r.Outcome 'Steam never run: creates the file'
Assert-Equal "$($w.Steam),$($w.Library)" (((Get-VdfLibraryFolders -Text ([IO.File]::ReadAllText($w.Vdf))).Libraries | ForEach-Object Path) -join ',') 'Steam never run: lists Steam and the games library'
Assert-Equal 0 @(Get-ChildItem (Split-Path -Parent $w.Vdf) -Filter '*.bak').Count 'Steam never run: nothing to back up'

# Steam is running: the file is not touched.
$w = New-World -Vdf $existing
$script:SteamRunning = $true
$r = Invoke-Register $w
$script:SteamRunning = $false
Assert-Equal 'True' ([IO.File]::ReadAllText($w.Vdf) -ceq $existing) 'Steam running: the file is untouched'
Assert-Equal 1 $r.Warnings.Count 'Steam running: warns'
Assert-Equal 'True' ($r.Warnings[0] -match 'exit Steam') 'Steam running: says what to do'

# Steam running but the library is already registered: nothing to say.
$w = New-World
New-Item -ItemType Directory -Path (Split-Path -Parent $w.Vdf) -Force | Out-Null
[IO.File]::WriteAllText($w.Vdf, (Add-VdfLibrary -Text $existing -LibraryPath $w.Library -SteamPath $w.Steam))
$script:SteamRunning = $true
$r = Invoke-Register $w
$script:SteamRunning = $false
Assert-Equal 0 $r.Warnings.Count 'Steam running but already registered: no warning'

# A damaged file is left alone.
$w = New-World -Vdf '"libraryfolders" { "0" { "path" '
$r = Invoke-Register $w
Assert-Equal 'True' ([IO.File]::ReadAllText($w.Vdf) -ceq '"libraryfolders" { "0" { "path" ') 'damaged file: untouched'
Assert-Equal 1 $r.Warnings.Count 'damaged file: warns'

# No games drive, no Steam: warnings, nothing created, no failure.
$w = New-World -DriveExists $false
$r = Invoke-Register $w
Assert-Equal 1 $r.Warnings.Count 'no games drive: warns'
Assert-Equal 'False' (Test-Path $w.Library) 'no games drive: creates nothing'
$w = New-World -SteamInstalled $false
$r = Invoke-Register $w
Assert-Equal 1 $r.Warnings.Count 'Steam not installed: warns'
Assert-Equal 'False' (Test-Path $w.Vdf) 'Steam not installed: writes no file'

Remove-Item -LiteralPath $work -Recurse -Force
if ($script:TestFailures -gt 0) { Write-Host "$script:TestFailures failure(s)"; exit 1 }
Write-Host 'all passed'
