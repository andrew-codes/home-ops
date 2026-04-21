$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path $ScriptDir "logging.ps1")
$script:LogFile = Join-Path $ScriptDir "restore.log"

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
    $env:LOCALAPPDATA,
    $env:APPDATA
) | Select-Object -Unique | Where-Object { $_ -and $_ -ne "" }

foreach ($Source in $Sources) {
    $RelativePath = $Source -replace '^[A-Za-z]:', ''
    $BackupPath = $DestRoot.TrimEnd('\') + $RelativePath

    if (-not (Test-Path $BackupPath)) {
        Write-Log "Skipping (no backup found): $BackupPath"
        continue
    }

    $SrcRsync = ConvertTo-RsyncPath $BackupPath
    $DstRsync = ConvertTo-RsyncPath $Source

    Write-Log "Restoring: $BackupPath -> $Source"

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

    if ($rsyncExit -eq 0) {
        Write-Log "Completed: $BackupPath -> $Source"
    }
    else {
        Write-Log "ERROR: $BackupPath failed (exit $rsyncExit)`n$($output -join "`n")"
    }
}

Write-Log "All restores complete."
