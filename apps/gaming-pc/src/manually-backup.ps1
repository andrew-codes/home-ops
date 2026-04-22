$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path $ScriptDir "logging.ps1")
$script:LogFile = Join-Path $ScriptDir "backup.log"

function ConvertTo-RsyncPath {
    param([string]$WindowsPath)
    $WindowsPath = $WindowsPath.TrimEnd('\')
    if ($WindowsPath -match '^([A-Za-z]):\\(.+)$') {
        $drive = $Matches[1].ToLower()
        $rest = $Matches[2] -replace '\\', '/'
        return "/cygdrive/$drive/$rest"
    }
    elseif ($WindowsPath -match '^([A-Za-z]):$') {
        return "/cygdrive/$($Matches[1].ToLower())/"
    }
    return $WindowsPath -replace '\\', '/'
}

$RsyncExe = "C:\ProgramData\chocolatey\bin\rsync.exe"
$DestRoot = "Z:\"

$Sources = @(
    "C:\Program Files (x86)\Steam\userdata",
    $env:USERPROFILE,
) | Select-Object -Unique | Where-Object { $_ -and (Test-Path $_) }

$Jobs = @()

foreach ($Source in $Sources) {
    $RelativePath = $Source -replace '^[A-Za-z]:', ''
    $DestPath = $DestRoot.TrimEnd('\') + $RelativePath

    $SrcRsync = ConvertTo-RsyncPath $Source
    $DstRsync = ConvertTo-RsyncPath $DestPath

    Write-Log "Queuing backup: $Source -> $DestPath"

    $Job = Start-Job -ScriptBlock {
        param($SrcRsync, $DstRsync, $DestPath, $Source, $RsyncExe)

        if (-not (Test-Path $DestPath)) {
            New-Item -ItemType Directory -Path $DestPath -Force | Out-Null
        }

        $output = & $RsyncExe -a --delete `
            --include='AppData/' `
            --include='AppData/Roaming/' `
            --include='AppData/Roaming/SEGA/' `
            --include='AppData/Roaming/SEGA/**' `
            --include='AppData/LocalLow/' `
            --include='AppData/LocalLow/RedCandleGames/' `
            --include='AppData/LocalLow/RedCandleGames/**' `
            --include='AppData/Local/' `
            --include='AppData/Local/MGSDelta*/' `
            --include='AppData/Local/MGSDelta*/**' `
            --include='AppData/Local/Steam/' `
            --include='AppData/Local/Steam/userdata/' `
            --include='AppData/Local/Steam/userdata/**' `
            --include='AppData/Local/Ubisoft/' `
            --include='AppData/Local/Ubisoft/**' `
            --exclude='AppData/**' `
            --exclude='Application Data' `
            --exclude='Local Settings' `
            --exclude='OneDrive*/' `
            --exclude='PrintHood/' `
            --exclude='Start Menu/' `
            --exclude='Searches/' `
            --exclude='SendTo/' `
            --exclude='Contacts/' `
            --exclude='Links/' `
            --exclude='NetHood/' `
            --exclude='Recent/' `
            --exclude='Templates/' `
            --exclude='Favorites/' `
            "$SrcRsync/" "$DstRsync/" 2>&1
        $rsyncExit = $LASTEXITCODE
        [PSCustomObject]@{
            Source   = $Source
            Dest     = $DestPath
            ExitCode = $rsyncExit
            Output   = $output -join "`n"
        }
    } -ArgumentList $SrcRsync, $DstRsync, $DestPath, $Source, $RsyncExe

    $Jobs += $Job
}

Write-Log "Running $($Jobs.Count) backup job(s) in parallel..."

foreach ($Job in ($Jobs | Wait-Job)) {
    $Result = $Job | Receive-Job
    if ($Result.ExitCode -eq 0) {
        Write-Log "Completed: $($Result.Source) -> $($Result.Dest)"
    }
    else {
        Write-Log "ERROR: $($Result.Source) failed (exit $($Result.ExitCode))`n$($Result.Output)"
    }
}

$Jobs | Remove-Job
Write-Log "All backups complete."
