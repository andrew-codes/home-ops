# Shared logging module for Update-Gaming-PC scripts

$script:LogDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$script:LogFile = Join-Path $script:LogDir 'log.txt'

function Write-Log {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Message
    )

    $timestamp = Get-Date -Format 'HH:mm:ss'
    $logMessage = "${timestamp}: $Message"

    Write-Host $logMessage
    # -WhatIf:$false so a dry run (storage.ps1 -WhatIf) still logs instead of printing "What if" lines.
    Add-Content -Path $script:LogFile -Value $logMessage -WhatIf:$false
}
