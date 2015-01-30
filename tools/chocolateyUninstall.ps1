$ErrorActionPreference = "Stop"; #Make all errors terminating
$packageName = 'vSphere-Graphite'

try {
    #Clean-up existing Task if any
    $existingTask = schtasks /query /FO csv | ConvertFrom-Csv | Where-Object { $_.TaskName -match $packageName }
    if($existingTask) {
        if($existingTask.Status -eq "Running") {
            try { 
                schtasks /End /TN $existingTask.TaskName 
            } catch {
                <# Don't care #>
            }
        }
        schtasks /Delete /TN $existingTask.TaskName /F
    }

    Write-ChocolateySuccess "$packageName"
} catch {
    Write-ChocolateyFailure "$packageName" "$($_.Exception.Message)"
    throw
}
