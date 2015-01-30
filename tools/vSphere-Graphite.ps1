$ErrorActionPreference = "Stop"
$workingDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$logPath = (Join-Path $workingDir "vSphere-Graphite.log")
$functionsPath = (Join-Path $workingDir "vSphere-Graphite-Functions.ps1")

try { . $functionsPath } catch { throw "Unable to dot source $functionsPath" }
$logger = New-Logger $logPath
try { $logger.logNotice("Starting up") } catch { throw "Unable to access/create logfile $logPath" }

$failed = $false

try {
    try { if ( (Get-PSSnapin -Name VMware.VimAutomation.Core -ErrorAction SilentlyContinue) -eq $null ) { Add-PsSnapin VMware.VimAutomation.Core } } catch { throw "Unable to load the PowerCLI snap-in (VMware.VimAutomation.Core). Have you installed the PowerCLI?" }
    $configuration = Get-Configuration (Join-Path $workingDir "vSphere-Graphite.config")
    $logger.logNotice("Configuration loaded")
    $logger.logNotice(($configuration | Out-String))
    Monitor-vSphere $configuration $logger { $true }
} catch {
    $logger.logError(($_ | Out-String))
    Write-Error $_
    $failed = $true
} finally {
    $logger.logNotice("Stopped")
    if($failed) {
        exit 1
    }
}