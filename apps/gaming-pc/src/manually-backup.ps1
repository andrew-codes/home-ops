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
) | Select-Object -Unique | Where-Object { $_ -and (Test-Path $_) }

$Jobs = @()

foreach ($Source in $Sources) {
    $RelativePath = $Source -replace '^[A-Za-z]:', ''
    $DestPath = $DestRoot + $RelativePath

    $SrcRsync = ConvertTo-RsyncPath $Source
    $DstRsync = ConvertTo-RsyncPath $DestPath

    Write-Log "Queuing backup: $Source -> $DestPath"

    $Job = Start-Job -ScriptBlock {
        param($SrcRsync, $DstRsync, $DestPath, $Source, $RsyncExe)

        if (-not (Test-Path $DestPath)) {
            New-Item -ItemType Directory -Path $DestPath -Force | Out-Null
        }

        $output = & $RsyncExe -a "$SrcRsync/" "$DstRsync/" 2>&1
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
