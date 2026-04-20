$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path $ScriptDir "logging.ps1")

function ConvertTo-RsyncPath {
    param([string]$WindowsPath)
    $WindowsPath = $WindowsPath.TrimEnd('\')
    if ($WindowsPath -match '^([A-Za-z]):\\(.+)$') {
        $drive = $Matches[1].ToLower()
        $rest = $Matches[2] -replace '\\', '/'
        return "/$drive/$rest"
    }
    elseif ($WindowsPath -match '^([A-Za-z]):$') {
        return "/$($Matches[1].ToLower())/"
    }
    return $WindowsPath -replace '\\', '/'
}

$RsyncExe = "C:\msys64\usr\bin\rsync.exe"
$DestRoot = "Z:\"

$Sources = @(
    "C:\Program Files (x86)\Steam\userdata",
    $env:USERPROFILE,
    $env:LOCALAPPDATA,
    $env:APPDATA
) | Select-Object -Unique | Where-Object { $_ -and $_ -ne "" }

$Jobs = @()

foreach ($Source in $Sources) {
    $RelativePath = $Source -replace '^[A-Za-z]:', ''
    $BackupPath = $DestRoot + $RelativePath

    if (-not (Test-Path $BackupPath)) {
        Write-Log "Skipping (no backup found): $BackupPath"
        continue
    }

    $SrcRsync = ConvertTo-RsyncPath $BackupPath
    $DstRsync = ConvertTo-RsyncPath $Source

    Write-Log "Queuing restore: $BackupPath -> $Source"

    $Job = Start-Job -ScriptBlock {
        param($SrcRsync, $DstRsync, $Source, $BackupPath, $RsyncExe)

        if (-not (Test-Path $Source)) {
            New-Item -ItemType Directory -Path $Source -Force | Out-Null
        }

        $output = & $RsyncExe -a --delete `
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
            Source   = $BackupPath
            Dest     = $Source
            ExitCode = $rsyncExit
            Output   = $output -join "`n"
        }
    } -ArgumentList $SrcRsync, $DstRsync, $Source, $BackupPath, $RsyncExe

    $Jobs += $Job
}

Write-Log "Running $($Jobs.Count) restore job(s) in parallel..."

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
Write-Log "All restores complete."
