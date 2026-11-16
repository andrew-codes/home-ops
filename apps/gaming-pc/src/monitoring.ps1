# Installs the exporters that put this machine's sensors into the cluster's
# VictoriaMetrics, and keeps them converged. See README.md#metrics-and-sensors
# for what each one is, what it costs while gaming, and the anti-cheat position.
#
#   windows_exporter  GPU temperature, fan, power, clocks and utilisation, CPU
#                     load, memory, and the FPS textfile. No kernel driver.
#   PresentMon        Frame times through ETW, no injection into any game.
#                     Wrapped by fps-exporter.ps1 and run by a boot-time task.
#   OhmGraphite       CPU package temperature only, through LibreHardwareMonitor
#                     and the PawnIO driver FanControl already installs.
#
# Run elevated by scripts/deploy.yml. Every step is idempotent: it compares the
# state it wants against a marker under HKLM:\SOFTWARE\gaming-pc\monitoring and
# only changes the machine when they differ. The last line, RESULT, is what
# deploy.yml reads to decide changed or failed, so keep its shape.
#
# The firewall rules for the two scrape ports are not here: deploy.yml owns them
# because they need the cluster node's address, which comes from 1Password.

$ErrorActionPreference = 'Stop'
# Progress rendering slows Invoke-WebRequest to a crawl on large files.
$ProgressPreference = 'SilentlyContinue'

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path $ScriptDir 'logging.ps1')

$script:Changed = 0
$script:Failures = New-Object System.Collections.Generic.List[string]
$script:Warnings = New-Object System.Collections.Generic.List[string]

# ---------------------------------------------------------------------------
# What gets installed. Versions and hashes are pinned: a deploy installs exactly
# these bits, and bumping one is a reviewed change to this file. The hashes are
# the SHA-256 digests GitHub publishes for each release asset.
# ---------------------------------------------------------------------------

$WindowsExporter = @{
    Version    = '0.32.1'
    Url        = 'https://github.com/prometheus-community/windows_exporter/releases/download/v0.32.1/windows_exporter-0.32.1-amd64.msi'
    Sha256     = '8e1ade6a2fbcdeb4774c300b598667cd7888246be8fcc4b586d11b3680433981'
    # gpu is the point. cpu and memory are the load context for it, and textfile
    # carries the FPS summary. Everything else windows_exporter can do (service,
    # net, process...) is left off so a scrape does no work nobody reads.
    Collectors = 'cpu,gpu,memory,textfile'
    Port       = 9182
}

$PresentMon = @{
    Version = '2.6.0'
    Url     = 'https://github.com/GameTechDev/PresentMon/releases/download/v2.6.0/PresentMon-2.6.0-x64.exe'
    Sha256  = 'b2a706bc6ad475749e3b7e3409263aa1e6906d45bdcf993f6dbc0f660188f1af'
}

$OhmGraphite = @{
    Version = '0.38.0'
    Url     = 'https://github.com/nickbabcock/OhmGraphite/releases/download/v0.38.0/OhmGraphite-0.38.0.zip'
    Sha256  = '35dc1fea76f3f2f766ea0d416a1ac01ce61e3e6c239e13aad97b29d7ec9de418'
    Port    = 4445
}

$MonitoringRoot = 'C:\ProgramData\gaming-pc\monitoring'
$TextfileDirectory = Join-Path $MonitoringRoot 'textfile'
$StateKey = 'HKLM:\SOFTWARE\gaming-pc\monitoring'
$FpsTaskName = 'Gaming-PC-FPS'

# ---------------------------------------------------------------------------
# Step harness (same shape as software.ps1)
# ---------------------------------------------------------------------------

function Invoke-Step {
    <#
    .SYNOPSIS
        Runs one unit of work, recording whether it changed anything or failed.
    .DESCRIPTION
        The action returns 'Installed' when it changed the machine and 'Present'
        when it did not. A required step's failure is collected rather than
        thrown so the other exporters still converge; the script exits non-zero
        at the end. An optional step's failure becomes a warning.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [switch]$Optional
    )

    try {
        $outcome = & $Action
        if ($outcome -eq 'Installed') {
            $script:Changed++
        }
    }
    catch {
        $message = "$Name : $($_.Exception.Message)"
        if ($Optional) {
            Write-Log "  WARNING $message"
            $script:Warnings.Add($message)
        }
        else {
            Write-Log "  FAILED $message"
            $script:Failures.Add($message)
        }
    }
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Get-State {
    param([Parameter(Mandatory = $true)][string]$Name)
    if (-not (Test-Path $StateKey)) { return $null }
    return (Get-ItemProperty -Path $StateKey -Name $Name -ErrorAction SilentlyContinue).$Name
}

function Set-State {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$Value)
    if (-not (Test-Path $StateKey)) { New-Item -Path $StateKey -Force | Out-Null }
    New-ItemProperty -Path $StateKey -Name $Name -Value $Value -PropertyType String -Force | Out-Null
}

function Get-TextHash {
    param([Parameter(Mandatory = $true)][string]$Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    return -join ([Security.Cryptography.SHA256]::HashData($bytes) | ForEach-Object { $_.ToString('x2') })
}

function Save-PinnedDownload {
    <#
    .SYNOPSIS
        Downloads a release asset and refuses it unless it matches the pinned SHA-256.
    .OUTPUTS
        The path of the verified file, in a fresh temporary directory the caller removes.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Sha256,
        [Parameter(Mandatory = $true)][string]$Directory
    )

    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $path = Join-Path $Directory ([IO.Path]::GetFileName(([Uri]$Url).AbsolutePath))
    Write-Log "  downloading $Url"
    Invoke-WebRequest -Uri $Url -OutFile $path -UseBasicParsing -Headers @{ 'User-Agent' = 'gaming-pc-deploy' }
    $actual = (Get-FileHash -Path $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Sha256) {
        Remove-Item -Path $path -Force
        throw "SHA-256 of $Url is $actual, expected $Sha256"
    }
    return $path
}

function New-TemporaryDirectory {
    $path = Join-Path ([IO.Path]::GetTempPath()) ('gaming-pc-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path | Out-Null
    return $path
}

function Initialize-MonitoringDirectory {
    <#
    .SYNOPSIS
        Creates the monitoring directory and locks it to administrators.
    .DESCRIPTION
        A SYSTEM scheduled task runs the scripts in here and windows_exporter
        reads the textfile directory, so a directory an ordinary user could write
        to would be a way to run code as SYSTEM or to forge metrics. Inheritance
        from C:\ProgramData is cut (it grants Users write access) and Users keep
        read and execute only.
    #>
    New-Item -ItemType Directory -Path $TextfileDirectory -Force | Out-Null
    & icacls.exe $MonitoringRoot /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "icacls failed with exit code $LASTEXITCODE"
    }
}

# ---------------------------------------------------------------------------
# windows_exporter
# ---------------------------------------------------------------------------

function Install-WindowsExporter {
    $desired = '{0}|{1}|{2}|{3}' -f $WindowsExporter.Version, $WindowsExporter.Collectors, $WindowsExporter.Port, $TextfileDirectory
    $service = Get-Service -Name 'windows_exporter' -ErrorAction SilentlyContinue

    if ($service -and (Get-State 'WindowsExporter') -eq $desired) {
        if ($service.Status -ne 'Running') {
            Start-Service -Name 'windows_exporter'
        }
        Write-Log "  windows_exporter $($WindowsExporter.Version): present"
        return 'Present'
    }

    $work = New-TemporaryDirectory
    try {
        $msi = Save-PinnedDownload -Url $WindowsExporter.Url -Sha256 $WindowsExporter.Sha256 -Directory $work
        # The MSI's firewall feature is off by default and stays off: deploy.yml
        # opens the port to the cluster node only. The same version re-installs in
        # place (the installer allows same-version upgrades), which is how a
        # changed collector list reaches an existing install.
        $arguments = @(
            '/i', "`"$msi`"", '/qn', '/norestart', '/L*v', "`"$(Join-Path $work 'msi.log')`""
            "ENABLED_COLLECTORS=$($WindowsExporter.Collectors)"
            "LISTEN_PORT=$($WindowsExporter.Port)"
            "TEXTFILE_DIRS=`"$TextfileDirectory`""
        )
        Write-Log "  windows_exporter $($WindowsExporter.Version): installing (collectors $($WindowsExporter.Collectors))"
        $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -Wait -PassThru
        if ($process.ExitCode -notin 0, 3010) {
            $log = Get-Content -Path (Join-Path $work 'msi.log') -Tail 20 -ErrorAction SilentlyContinue
            throw "msiexec exited with code $($process.ExitCode). $($log -join ' | ')"
        }
    }
    finally {
        Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
    }

    Set-State 'WindowsExporter' $desired
    Start-Service -Name 'windows_exporter' -ErrorAction SilentlyContinue
    Write-Log "  windows_exporter $($WindowsExporter.Version): installed"
    return 'Installed'
}

# ---------------------------------------------------------------------------
# PresentMon and the FPS summariser
# ---------------------------------------------------------------------------

function Install-PresentMon {
    $exeName = "PresentMon-$($PresentMon.Version)-x64.exe"
    $exePath = Join-Path $MonitoringRoot $exeName
    $changed = $false

    if (-not (Test-Path $exePath) -or (Get-FileHash -Path $exePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $PresentMon.Sha256) {
        $work = New-TemporaryDirectory
        try {
            $download = Save-PinnedDownload -Url $PresentMon.Url -Sha256 $PresentMon.Sha256 -Directory $work
            Stop-FpsExporter
            Copy-Item -Path $download -Destination $exePath -Force
            $changed = $true
        }
        finally {
            Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    # A bumped version leaves the old executable behind otherwise.
    Get-ChildItem -Path $MonitoringRoot -Filter 'PresentMon-*-x64.exe' -File |
        Where-Object { $_.Name -ne $exeName } | Remove-Item -Force

    # The scripts the task runs are copied out of the user profile, which the
    # deploy empties and refills, into the locked-down monitoring directory.
    $scripts = 'fps-exporter.ps1', 'fps-summary.ps1'
    foreach ($script in $scripts) {
        $source = Join-Path $ScriptDir $script
        $target = Join-Path $MonitoringRoot $script
        if (-not (Test-Path $target) -or (Get-FileHash $source -Algorithm SHA256).Hash -ne (Get-FileHash $target -Algorithm SHA256).Hash) {
            Stop-FpsExporter
            Copy-Item -Path $source -Destination $target -Force
            $changed = $true
        }
    }

    $task = Get-ScheduledTask -TaskName $FpsTaskName -ErrorAction SilentlyContinue
    # The task's command line names the executable, so a version bump re-registers it.
    $taskVersion = "1|$exeName"
    if (-not $task -or (Get-State 'FpsTask') -ne $taskVersion) {
        Stop-FpsExporter
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -PresentMonPath "{1}" -TextfileDirectory "{2}"' -f `
            (Join-Path $MonitoringRoot 'fps-exporter.ps1'), $exePath, $TextfileDirectory
        $action = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument $arguments -WorkingDirectory $MonitoringRoot
        # At boot, not at logon or per game: see the header of fps-exporter.ps1.
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
            -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName $FpsTaskName -Force `
            -InputObject (New-ScheduledTask -Action $action -Trigger $trigger -Settings $settings -Principal $principal) | Out-Null
        Set-State 'FpsTask' $taskVersion
        $changed = $true
    }

    $running = (Get-ScheduledTask -TaskName $FpsTaskName).State -eq 'Running'
    if ($changed -or -not $running) {
        Start-ScheduledTask -TaskName $FpsTaskName
    }

    if ($changed) {
        Write-Log "  PresentMon $($PresentMon.Version) and ${FpsTaskName}: installed"
        return 'Installed'
    }
    Write-Log "  PresentMon $($PresentMon.Version) and ${FpsTaskName}: present"
    return 'Present'
}

function Stop-FpsExporter {
    # Stopping the task ends the wrapper but can leave PresentMon, and with it an
    # ETW session and an open handle on its own executable, behind.
    $task = Get-ScheduledTask -TaskName $FpsTaskName -ErrorAction SilentlyContinue
    if ($task -and $task.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $FpsTaskName
    }
    Get-Process -Name 'PresentMon-*' -ErrorAction SilentlyContinue | Stop-Process -Force
}

# ---------------------------------------------------------------------------
# OhmGraphite
# ---------------------------------------------------------------------------

function Get-OhmGraphiteConfig {
    # Prometheus pull mode: sensors are read only when vmagent scrapes, so the
    # poll interval is the scrape interval and nothing runs between scrapes.
    # `type` is what selects it. OhmGraphite defaults to Graphite push when the
    # key is absent and then never opens the listener, so port 4445 stays closed
    # even though the service is Running. `prometheus_path` is the form
    # OhmGraphite hands to HttpListener, a relative path with a trailing slash.
    #
    # CPU only. Every other hardware class is switched off, so LibreHardwareMonitor
    # never opens it: the GPU is read by windows_exporter (and by FanControl),
    # and the motherboard, Super I/O and embedded controller are exactly what
    # FanControl is controlling fans through, which a second reader must not
    # touch. Storage is off because SMART reads are the classic in-game hitch.
    $disabled = 'gpu', 'motherboard', 'ram', 'network', 'storage', 'controller', 'psu', 'battery'
    $lines = foreach ($class in $disabled) { "    <add key=`"/$class/enabled`" value=`"false`" />" }
    return @"
<?xml version="1.0" encoding="utf-8" ?>
<configuration>
  <appSettings>
    <add key="type" value="prometheus" />
    <add key="prometheus_host" value="*" />
    <add key="prometheus_port" value="$($OhmGraphite.Port)" />
    <add key="prometheus_path" value="metrics/" />
$($lines -join "`r`n")
  </appSettings>
</configuration>
"@
}

function Install-OhmGraphite {
    $installDirectory = Join-Path $env:ProgramFiles 'OhmGraphite'
    $config = Get-OhmGraphiteConfig
    $desired = '{0}|{1}' -f $OhmGraphite.Version, (Get-TextHash $config)
    $service = Get-Service -Name 'OhmGraphite' -ErrorAction SilentlyContinue

    if ($service -and (Get-State 'OhmGraphite') -eq $desired) {
        if ($service.Status -ne 'Running') {
            Start-Service -Name 'OhmGraphite'
        }
        Write-Log "  OhmGraphite $($OhmGraphite.Version): present"
        return 'Present'
    }

    $exe = Join-Path $installDirectory 'OhmGraphite.exe'
    $binaryCurrent = $service -and (Test-Path $exe) -and (Get-State 'OhmGraphiteBinary') -eq $OhmGraphite.Version

    if ($service -and $service.Status -ne 'Stopped') {
        Stop-Service -Name 'OhmGraphite' -Force
    }
    New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null

    # The binary is 40 MB, so a changed config alone does not download it again.
    if (-not $binaryCurrent) {
        $work = New-TemporaryDirectory
        try {
            $zip = Save-PinnedDownload -Url $OhmGraphite.Url -Sha256 $OhmGraphite.Sha256 -Directory $work
            Expand-Archive -Path $zip -DestinationPath (Join-Path $work 'extracted') -Force
            Copy-Item -Path (Join-Path $work 'extracted\OhmGraphite.exe') -Destination $installDirectory -Force
            if (-not (Test-Path (Join-Path $installDirectory 'NLog.config'))) {
                Copy-Item -Path (Join-Path $work 'extracted\NLog.config') -Destination $installDirectory -Force
            }
        }
        finally {
            Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
        }
        Set-State 'OhmGraphiteBinary' $OhmGraphite.Version
    }
    Set-Content -Path (Join-Path $installDirectory 'OhmGraphite.exe.config') -Value $config -Encoding utf8

    # Program Files is administrator-only by default; say so for the install
    # directory the SYSTEM service runs from rather than assume it.
    & icacls.exe $installDirectory /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null

    if (-not $service) {
        & $exe install | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "OhmGraphite.exe install exited with code $LASTEXITCODE"
        }
        # Restart on failure, so a crash does not leave the CPU series dark.
        & sc.exe failure OhmGraphite reset= 86400 actions= restart/60000/restart/60000/restart/60000 | Out-Null
    }
    Start-Service -Name 'OhmGraphite'

    Set-State 'OhmGraphite' $desired
    Write-Log "  OhmGraphite $($OhmGraphite.Version): installed"
    return 'Installed'
}

# ---------------------------------------------------------------------------
# Checks that cannot fail the deploy but tell you what to look at
# ---------------------------------------------------------------------------

function Test-PawnIO {
    # OhmGraphite reads CPU temperature through the PawnIO driver, which
    # FanControl installs. This script does not add a driver, so say so when it
    # is missing instead of letting OhmGraphite quietly emit nothing useful.
    if (-not (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\PawnIO')) {
        throw 'The PawnIO driver is not installed. FanControl installs it; without it OhmGraphite reports no CPU temperature.'
    }
    Write-Log '  PawnIO driver: present'
    return 'Present'
}

function Test-Endpoint {
    <#
    .SYNOPSIS
        Fetches an exporter's own /metrics and checks one series is in it.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string[]]$ExpectedSeries
    )

    # The services need a moment after a first install, and OhmGraphite's first
    # scrape initialises LibreHardwareMonitor.
    $body = $null
    for ($attempt = 1; $attempt -le 6 -and -not $body; $attempt++) {
        try { $body = (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 20).Content }
        catch { Start-Sleep -Seconds 5 }
    }
    if (-not $body) {
        throw "$Name did not answer on $Url"
    }
    foreach ($series in $ExpectedSeries) {
        if ($body -notmatch [regex]::Escape($series)) {
            throw "$Name answered but has no $series"
        }
    }
    Write-Log "  ${Name}: answers with $($ExpectedSeries -join ', ')"
    return 'Present'
}

# ---------------------------------------------------------------------------

Write-Log '=== monitoring.ps1 ==='

Invoke-Step -Name 'Monitoring directory' -Action { Initialize-MonitoringDirectory; 'Present' }
Invoke-Step -Name 'windows_exporter' -Action { Install-WindowsExporter }
Invoke-Step -Name 'PresentMon' -Action { Install-PresentMon }
Invoke-Step -Name 'OhmGraphite' -Action { Install-OhmGraphite }

# Warnings, not failures: a missing sensor is something to read about and fix on
# the machine, not a reason to fail a deploy that changed everything else.
Invoke-Step -Name 'PawnIO' -Optional -Action { Test-PawnIO }
Invoke-Step -Name 'windows_exporter GPU sensors' -Optional -Action {
    # The first thing to confirm on the real machine: the RTX 5090 must report a
    # non-zero temperature through the graphics kernel, from a service account.
    Test-Endpoint -Name 'windows_exporter' -Url "http://localhost:$($WindowsExporter.Port)/metrics" `
        -ExpectedSeries 'windows_gpu_temperature_celsius', 'windows_exporter_collector_success{collector="gpu"} 1', 'windows_exporter_collector_success{collector="textfile"} 1'
}
Invoke-Step -Name 'OhmGraphite CPU sensors' -Optional -Action {
    Test-Endpoint -Name 'OhmGraphite' -Url "http://localhost:$($OhmGraphite.Port)/metrics" `
        -ExpectedSeries 'ohm_cpu_celsius'
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
