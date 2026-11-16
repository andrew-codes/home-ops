# Test for Get-OhmGraphiteConfig in src/monitoring.ps1. Run with:
#   pwsh -NoProfile -File apps/gaming-pc/tests/ohmgraphite-config.test.ps1
# monitoring.ps1 installs things when it is dot-sourced, so the function is
# lifted out of the script with the PowerShell parser instead and run alone.

$ErrorActionPreference = 'Stop'

$script:Failures = 0
function Assert-Equal {
    param($Expected, $Actual, [string]$What)
    if ($Expected -ne $Actual) {
        Write-Host "FAIL $What`n  expected: $Expected`n  actual:   $Actual"
        $script:Failures++
    }
    else {
        Write-Host "ok   $What"
    }
}

$source = Join-Path $PSScriptRoot '..' 'src' 'monitoring.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$null)
$function = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-OhmGraphiteConfig'
    }, $true)
if (-not $function) { throw 'Get-OhmGraphiteConfig not found in monitoring.ps1' }
. ([scriptblock]::Create($function.Extent.Text))

$OhmGraphite = @{ Port = 4445 }
$settings = @{}
foreach ($add in ([xml](Get-OhmGraphiteConfig)).configuration.appSettings.add) {
    $settings[$add.key] = $add.value
}

# Without `type` OhmGraphite pushes to Graphite and never listens on the port.
Assert-Equal 'prometheus' $settings['type'] 'exporter type is prometheus'
Assert-Equal '4445' $settings['prometheus_port'] 'listener port'
Assert-Equal '*' $settings['prometheus_host'] 'listens on all interfaces'
Assert-Equal 'metrics/' $settings['prometheus_path'] 'path has the trailing slash HttpListener needs'
Assert-Equal 'false' $settings['/gpu/enabled'] 'gpu class disabled'
Assert-Equal $null $settings['/cpu/enabled'] 'cpu class left on'

if ($script:Failures -gt 0) { Write-Host "$script:Failures failure(s)"; exit 1 }
Write-Host 'all passed'
