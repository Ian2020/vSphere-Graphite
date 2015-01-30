$ErrorActionPreference = "Stop"; #Make all errors terminating
$packageName = 'vSphereGraphite'

try {
    $toolsPath = Split-Path $MyInvocation.MyCommand.Definition

    #Clean-up existing Task if any
    $existingTask = schtasks /query /FO csv | ConvertFrom-Csv | Where-Object { $_.TaskName -match $packageName }
    if($existingTask) {
        if($existingTask.Status -eq "Running") {
            try { schtasks /End /TN $existingTask.TaskName } catch { <# Don't care #> }
        }
        schtasks /Delete /TN $existingTask.TaskName /F
    }

    $taskXML = (Join-Path $toolsPath "vSphere-Graphite.xml")
    #Chocolatey can install us to different places, we need to replace tokens in the task XML and PowerShell to take this into account
    (Get-Content $taskXML | Out-String).Replace("###TOOLSPATH###", $toolsPath) | Out-File $taskXML
    schtasks /Create /XML $taskXML /TN $packageName
    schtasks /Run /TN $packageName

    Write-ChocolateySuccess "$packageName"
} catch {
    Write-ChocolateyFailure "$packageName" "$($_.Exception.Message)"
    throw
}
