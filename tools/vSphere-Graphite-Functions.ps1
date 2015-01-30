function Get-Configuration($configPath) {
    if(-not (Test-Path  $configPath)) {
        throw "Could not find config file at: $configPath"
    }

    $content =  Get-Content $configPath      
        
    try {
        $xml = [xml]($content)
    } catch {
        throw "Config file is not valid XML: $configPath";
    }

    $vSphereHostname           = $xml.configuration.vSphere.hostname
    $vSphereUsername           = $xml.configuration.vSphere.username
    $vSpherePassword           = $xml.configuration.vSphere.password
    $vSpherevHostStatTypes     = $xml.configuration.vSphere.vHostStatTypes.statType
    $vSphereMaxLookBackMinutes = $xml.configuration.vSphere.maxLookBackMinutes
    $graphiteHostname          = $xml.configuration.graphite.hostname
    $graphiteMetricPrefix      = $xml.configuration.graphite.metricPrefix
    $graphitePortPlaintext     = $xml.configuration.graphite.portPlaintext
    $pollIntervalSeconds       = $xml.configuration.pollIntervalSeconds

    $configuration = New-Object -TypeName PSObject |
        Add-Member -MemberType NoteProperty -PassThru -Name vSphereHostname           -Value $vSphereHostname |
        Add-Member -MemberType NoteProperty -PassThru -Name vSphereUsername           -Value $vSphereUsername |
        Add-Member -MemberType NoteProperty -PassThru -Name vSpherePassword           -Value $vSpherePassword |
        Add-Member -MemberType NoteProperty -PassThru -Name vSpherevHostStatTypes     -Value $vSpherevHostStatTypes |
        Add-Member -MemberType NoteProperty -PassThru -Name vSphereMaxLookBackMinutes -Value $vSphereMaxLookBackMinutes |
        Add-Member -MemberType NoteProperty -PassThru -Name graphiteHostname          -Value $graphiteHostname |
        Add-Member -MemberType NoteProperty -PassThru -Name graphiteMetricPrefix      -Value $graphiteMetricPrefix |
        Add-Member -MemberType NoteProperty -PassThru -Name graphitePortPlaintext     -Value $graphitePortPlaintext |
        Add-Member -MemberType NoteProperty -PassThru -Name pollIntervalSeconds       -Value $pollIntervalSeconds

    return $configuration
}

function New-Logger($logPath) {
    $logger = New-Object -TypeName PSObject
    $logger | Add-Member -MemberType NoteProperty -Name _logFile -Value $logPath

    $logger | Add-Member -MemberType ScriptMethod -Name logDebug -Value {
        param($msg)
        ("{0}|DEBUG|{1}" -f (Get-Date).ToUniversalTime().ToString("O"), $msg) | Out-File -Append $this._logFile
    }
    $logger | Add-Member -MemberType ScriptMethod -Name logNotice -Value {
        param($msg)
        ("{0}|NOTICE|{1}" -f (Get-Date).ToUniversalTime().ToString("O"), $msg) | Out-File -Append $this._logFile
    }
    $logger | Add-Member -MemberType ScriptMethod -Name logError -Value {
        param($msg)
        ("{0}|ERROR|{1}" -f (Get-Date).ToUniversalTime().ToString("O"), $msg) | Out-File -Append $this._logFile
    }

    return $logger
}

function Sleep-For($seconds) {
    Start-Sleep -Seconds $seconds
}

function Get-AvailableStatsForHost($configuration, $vmHost) {
    $statTypes = Get-AvailableStats $vmHost
    return $statTypes | ? { $configuration.vSpherevHostStatTypes -contains $_ }
}

function Monitor-vSphere($configuration, $logger, $until) {

    $lastStatTimes = @{}
    $firstTime = $true

    do {
        try {
            $lastStatTimes = Record-Metrics $configuration $logger $lastStatTimes

            if($firstTime) {
                $firstTime = $false
                $logger.logNotice("One-off start-up message: successfully retrieved metrics from vSphere and sent them to Graphite.")
            }
        } catch {
            $logger.logError(($_ | Out-String))
        }

        Sleep-For $configuration.pollIntervalSeconds
    } while (& $until)
}

function Get-LookBackMinutes($configuration, $logger, $lastStatTimes, $vmHostName) {
    $lookBackMins = 1
    
    if($lastStatTimes.Keys -contains $vmHostName) {
        $lookBackMins = [int]((Get-Now) - $lastStatTimes[$vmHostName]).TotalMinutes + 1

        if($lookBackMins -gt $configuration.vSphereMaxLookBackMinutes) {
            $logger.logNotice("$($vmHostName): The latest stats retrieved for this host are timestamped $($lastStatTimes[$vmHostName]). This is over $($configuration.vSphereMaxLookBackMinutes) minutes ago (configured by 'vSphereMaxLookBackMinutes'). We'll just retrieve the last minutes' worth instead.")
            $lookBackMins = 1
        }
    }

    return $lookBackMins
}

function Get-LastStatisticTime($stats) {
    return $stats | select -ExpandProperty Timestamp | Sort-Object -Descending | select -First 1
}

function Record-Metrics($configuration, $logger, $lastStatTimes) {
    try {
        ConnectTo-vSphere $configuration.vSphereHostname $configuration.vSphereUsername $configuration.vSpherePassword

        foreach($vmHost in Get-VirtualHosts) {
            #We have to check what stats are available per vmHost, otherwise we get errors if some are not when we call Get-Stat
            $statTypes = Get-AvailableStatsForHost $configuration $vmHost 

            if(-not $statTypes) {
                #If the vmHost is offline we'll get no stats
                continue
            }

            $lookBackMins = Get-LookBackMinutes $configuration $logger $lastStatTimes $vmHost.Name
            $stats = Get-HostStat $vmHost $lookBackMins $statTypes
            
            if($stats) {
                Send-ToGraphite ($stats | select @{Name="Name";Expression={[String]::Join(".", @($configuration.graphiteMetricPrefix, $_.Entity.Name.Replace(".","_"), $_.MetricId)) + "_" + $_.Unit}}, Timestamp, Value) $configuration.graphiteHostname $configuration.graphitePortPlaintext
            }
            $lastStatTimes[$vmHost.Name] = Get-LastStatisticTime $stats
        }
    } finally {
        DisconnectFrom-vSphere $configuration.vSphereHostname
    }

    return $lastStatTimes
}

function Get-Now() {
    return (Get-Date).ToUniversalTime()
}

function ConnectTo-vSphere($hostname, $username, $password) {
    Connect-VIServer -Server $hostname -User $username -Password $password | Out-Null
}

function DisconnectFrom-vSphere($hostname) {
    Disconnect-VIServer -Server $hostname -Force -Confirm:$false
}

function Get-AvailableStats($vmHost) {
    #You cannot feed all vmHosts in here (even though its allowed) as it seems to give you a set of all possible metrics, not the minimum set of what's available across all
    Get-StatType -Entity $vmHost -Realtime
}

function Get-HostStat($vmHost, $lookBackMins, $statTypes) {
    #We ask for stats with no instance, i.e. those for whole host. We must use ErrorAction SilentlyContinue otherwise the command fails (bug in PowerCLI?).
    #This is less then ideal as we are blind to other problems
    Get-Stat -Entity $vmHost -MaxSamples (3*$lookBackMins) -Realtime -Stat $statTypes -Instance "" -ErrorAction SilentlyContinue
}

function Get-VirtualHosts() {
    return Get-VMHost
}

function Send-ToGraphite([PSObject[]]$metrics, [string]$hostname, [string]$portPlaintext) {
    $writer = $null
    $stream = $null

    try {
        $socket = new-Object System.Net.Sockets.TcpClient($hostname, $portPlaintext)
        if($socket -eq $null) {
            throw "Could not connect to Graphite!"
        }

        $stream = $socket.GetStream()
        $writer = new-object System.IO.StreamWriter($stream)

        foreach($metric in $metrics) {
            #Replace bad chars for Graphite
            #TODO: there are probably more bad chars then this
            $key = $metric.Name.Replace(" ","_").Replace("(","_").Replace(")","_")
            $metricLine = ("{0} {1} {2}" -f $key, $metric.Value, ([int][double]::Parse((Get-Date -Date $metric.Timestamp -UFormat %s))))
            $writer.WriteLine($metricLine)
        }
        $writer.Flush()
    } finally {
        if($writer -ne $null) {
            $writer.Close()
        }
        if($stream -ne $null) {
            $stream.Close()
        }
    }
}