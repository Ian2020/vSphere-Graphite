$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$sut = (Split-Path -Leaf $MyInvocation.MyCommand.Path).Replace(".Tests.", ".")
. "$here\$sut"

#TODO: Nicer way to find Pester?
$pesterPath = 'C:\ProgramData\chocolatey\lib\pester.3.0.1.1\tools\Pester.psm1'

if(-not (Get-Module Pester)) {
    Import-Module $pesterPath
}

function Mock-Logger() {
    $logger = New-Object -TypeName PSObject
    $logger | Add-Member -MemberType NoteProperty -Name loggedDebugMessages -Value @()
    $logger | Add-Member -MemberType NoteProperty -Name loggedNoticeMessages -Value @()
    $logger | Add-Member -MemberType NoteProperty -Name loggedErrorMessages -Value @()

    $logger | Add-Member -MemberType ScriptMethod -Name logDebug -Value {
        param($msg)
        $this.loggedDebugMessages += $msg
    }
    $logger | Add-Member -MemberType ScriptMethod -Name logNotice -Value {
        param($msg)
        $this.loggedNoticeMessages += $msg
    }
    $logger | Add-Member -MemberType ScriptMethod -Name logError -Value {
        param($msg)
        $this.loggedErrorMessages += $msg
    }

    return $logger
}

function Loop-For($numInterations) {
    $global:iterations = $numInterations
    return { $global:iterations-- ; $global:iterations -gt 0 }
}

Describe "Loading configuration" {

    Context "Missing configuration file" {
        It "Throws exception" {
            { Get-Configuration "C:\Gibberish\Nonsense.config" } | Should Throw
        }
    }

    Context "Configuration file not valid XML" {
        $configFile = [System.IO.Path]::GetTempFileName()
        "<xml>BAD <XML></xml>" | Out-File $configFile
        
        It "Throws exception" {
            { Get-Configuration $configFile } | Should Throw
        }

        Remove-Item $configFile -Force
    }

    Context "Valid configuration file" {
        $configFile = [System.IO.Path]::GetTempFileName()
        $content = @"
<configuration>
    <vSphere>
        <hostname>vSphereHostname</hostname>
        <username>vSphereUsername</username>
        <password>vSpherePassword</password>
        <maxLookBackMinutes>vSphereMaxLookBackMinutes</maxLookBackMinutes>
        <vHostStatTypes>
            <statType>cpu.usage.average</statType>
            <statType>power.power.average</statType>
        </vHostStatTypes>
    </vSphere>
    <graphite>
        <hostname>graphiteHostname</hostname>
        <metricPrefix>graphiteMetricPrefix</metricPrefix>
        <portPlaintext>graphitePortPlaintext</portPlaintext>
    </graphite>
    <pollIntervalSeconds>pollIntervalSeconds</pollIntervalSeconds>
</configuration>
"@
        $content | Out-File $configFile
        $configuration = Get-Configuration $configFile

        It "Reads configuration correctly" {
            $configuration.vSphereHostname           | Should Be "vSphereHostname"
            $configuration.vSphereUsername           | Should Be "vSphereUsername"
            $configuration.vSpherePassword           | Should Be "vSpherePassword"
            $configuration.vSphereMaxLookBackMinutes | Should Be "vSphereMaxLookBackMinutes"
            $configuration.vSpherevHostStatTypes     | Should Be @("cpu.usage.average","power.power.average")
            $configuration.graphiteHostname          | Should Be "graphiteHostname"
            $configuration.graphiteMetricPrefix      | Should Be "graphiteMetricPrefix"
            $configuration.graphitePortPlaintext     | Should Be "graphitePortPlaintext"
            $configuration.pollIntervalSeconds       | Should Be "pollIntervalSeconds"
        }

        Remove-Item $configFile -Force
    }
}

Describe "Monitoring vSphere" {

    Context "Error when recording metrics" {
        $mockLogger = Mock-Logger
        $pollInterval = 5
        $configuration = @{ pollIntervalSeconds = $pollInterval }
        Mock Sleep-For {} -Verifiable -ParameterFilter { $seconds -eq $pollInterval }
        Mock Record-Metrics { throw "An error" }

        Monitor-vSphere $configuration $mockLogger (Loop-For 2 Iteration) 

        It "Logs an error" {
            $mockLogger.loggedErrorMessages.Count | Should Be 2
        }
        It "Sleeps between recording metrics" {
            Assert-VerifiableMocks
        }
        It "Continues despite error" {
            Assert-MockCalled Record-Metrics -Times 2 -Exactly
        }
    }

    Context "Metrics recorded OK" {
        $mockLogger = Mock-Logger
        $pollInterval = 5
        $configuration = @{ pollIntervalSeconds = $pollInterval }
        Mock Sleep-For {} -Verifiable -ParameterFilter { $seconds -eq $pollInterval }
        Mock Record-Metrics { }

        Monitor-vSphere $configuration $mockLogger (Loop-For 2 Iteration) 

        It "Logs a notice message once to indicate success" {
            $mockLogger.loggedNoticeMessages.Count | Should Be 1
        }
        It "Sleeps between recording metrics" {
            Assert-VerifiableMocks
        }
        It "Continues to record" {
            Assert-MockCalled Record-Metrics -Times 2 -Exactly
        }
    }
}

Describe "Filtering of available statistics" {

    Context "No statistics available" {
        $configuration = @{ vSpherevHostStatTypes = @("cpu")}
        Mock Get-AvailableStats { return $null }
        
        $stats = Get-AvailableStatsForHost $configuration "vmhost"

        It "Should return nothing" {
            $stats | Should Be $null
        }
    }

    Context "No statistics match those we are interested in" {
        $configuration = @{ vSpherevHostStatTypes = @("cpu")}
        Mock Get-AvailableStats { return @("power") }
        
        $stats = Get-AvailableStatsForHost $configuration "vmhost"

        It "Should return nothing" {
            $stats | Should Be $null
        }
    }

    Context "Some statistics match those we are interested in" {
        $configuration = @{ vSpherevHostStatTypes = @("cpu", "power", "disk", "memory")}
        Mock Get-AvailableStats { return @("power", "disk") }
        
        $stats = Get-AvailableStatsForHost $configuration "vmhost"

        It "Should return nothing" {
            $stats | Should Be @("power", "disk")
        }
    }

    Context "All statistics match those we are interested in" {
        $configuration = @{ vSpherevHostStatTypes = @("cpu", "power", "disk", "memory")}
        Mock Get-AvailableStats { return @("cpu", "power", "disk", "memory") }
        
        $stats = Get-AvailableStatsForHost $configuration "vmhost"

        It "Should return nothing" {
            $stats | Should Be @("cpu", "power", "disk", "memory")
        }
    }

}

Describe "Calculate how far back to retrieve statistics" {
    Context "No previous data" {
        $configuration = @{ vSphereMaxLookBackMinutes = 10 }
        $logger = Mock-Logger
        $lastStatTimes = @{}
        $mins = Get-LookBackMinutes $configuration $logger $lastStatTimes "vmHostName"

        It "Should use the default look back" {
            $mins | Should Be 1
        }
    }

    Context "We have previous, recent data" {
        $configuration = @{ vSphereMaxLookBackMinutes = 10 }
        $logger = Mock-Logger
        $ageOfStatsMins = 2
        $lastStatTimes = @{ "vmHostName" = (Get-Date).AddMinutes(-$ageOfStatsMins)}
        $mins = Get-LookBackMinutes $configuration $logger $lastStatTimes "vmHostName"

        It "Should look back to last stats plus a minutes overlap" {
            $mins | Should Be ($ageOfStatsMins + 1)
        }
    }

    Context "We have previous but old data" {
        $configuration = @{ vSphereMaxLookBackMinutes = 10 }
        $logger = Mock-Logger
        $ageOfStatsMins = $configuration.vSphereMaxLookBackMinutes
        $lastStatTimes = @{ "vmHostName" = (Get-Date).AddMinutes(-$ageOfStatsMins)}
        $mins = Get-LookBackMinutes $configuration $logger $lastStatTimes "vmHostName"

        It "Should use the default look back" {
            $mins | Should Be 1
        }
    }
}

Describe "Get latest statistics timestamp" {
    Context "One statistic" {
        $time = Get-Date
        $stat = New-Object -TypeName PSObject | Add-Member -MemberType NoteProperty -Name Timestamp -Value $time -PassThru
        $latestStatTime = Get-LastStatisticTime @($stat)

        It "Should use that statistics timestamp" {
            $latestStatTime | Should Be $time
        }
    }

    Context "Two statistics, reverse order" {
        $time = Get-Date
        $statYoung = New-Object -TypeName PSObject | Add-Member -MemberType NoteProperty -Name Timestamp -Value $time -PassThru
        $statOld = New-Object -TypeName PSObject | Add-Member -MemberType NoteProperty -Name Timestamp -Value $time.AddMinutes(-1) -PassThru
        $latestStatTime = Get-LastStatisticTime @($statYoung, $statOld)

        It "Should use the younger statistic's timestamp" {
            $latestStatTime | Should Be $time
        }
    }

    Context "Two statistics, in order" {
        $time = Get-Date
        $statYoung = New-Object -TypeName PSObject | Add-Member -MemberType NoteProperty -Name Timestamp -Value $time -PassThru
        $statOld = New-Object -TypeName PSObject | Add-Member -MemberType NoteProperty -Name Timestamp -Value $time.AddMinutes(-1) -PassThru
        $latestStatTime = Get-LastStatisticTime @($statOld, $statYoung)

        It "Should use the younger statistic's timestamp" {
            $latestStatTime | Should Be $time
        }
    }
}

Describe "Record metrics" {
    Context "Error getting stats" {
        $configuration = @{}
        $mockLogger = Mock-Logger
        Mock ConnectTo-vSphere
        Mock DisconnectFrom-vSphere
        Mock Get-VirtualHosts { throw "Error" }

        It "Should throw an exception" {
            { Record-Metrics $configuration $logger $lastStatTimes } | Should Throw
        }
        It "Should disconnect" {
            Assert-MockCalled DisconnectFrom-vSphere -Exactly -Times 1
        }

    }

    Context "One statistic for one vHost" {
        $configuration = @{graphiteMetricPrefix = "graphitePrefix"; graphiteHostname = "graphiteHostname" ; graphitePortPlaintext = 2003 }
        $mockLogger = Mock-Logger
        $time = Get-Date
        $lastStatTimes = @{}
        $vmHostName = "vmHost"
        $metricId = "cpu"
        $unit = "%"
        $value = 10
        $hostStat = New-Object -TypeName PSObject | 
            Add-Member -MemberType NoteProperty -Name Timestamp -Value $time -PassThru |
            Add-Member -MemberType NoteProperty -Name Entity -Value @{Name=$vmHostName} -PassThru |
            Add-Member -MemberType NoteProperty -Name MetricId -Value $metricId -PassThru |
            Add-Member -MemberType NoteProperty -Name Unit -Value $unit -PassThru |
            Add-Member -MemberType NoteProperty -Name Value -Value $value -PassThru
        Mock ConnectTo-vSphere
        Mock DisconnectFrom-vSphere
        Mock Get-VirtualHosts { return @(@{Name = $vmHostName}) }
        Mock Get-AvailableStatsForHost { return "cpu" }
        Mock Get-HostStat { return @($hostStat) }
        Mock Send-ToGraphite { $global:metric = $metrics[0] } -Verifiable -ParameterFilter { $metrics.Count -eq 1 }

        Record-Metrics $configuration $logger $lastStatTimes

        It "Should record one metric" {
            Assert-VerifiableMocks
        }
        It "Should record the correct metric" {
            $metric.Name      | Should Be "graphitePrefix.vmHost.cpu_%"
            $metric.Timestamp | Should Be $time
            $metric.Value     | Should Be $value
        }
    }

    Context "No stat types available for vhost" {
        $mockLogger = Mock-Logger
        $lastStatTimes = @{}
        $vmHostName = "vmHost"
        Mock ConnectTo-vSphere
        Mock DisconnectFrom-vSphere
        Mock Get-VirtualHosts { return @(@{Name = $vmHostName}) }
        Mock Get-AvailableStatsForHost { return @() }
        Mock Send-ToGraphite

        Record-Metrics $configuration $logger $lastStatTimes

        It "Should not record anything" {
            Assert-MockCalled Send-ToGraphite -Exactly 0
        }
    }

    Context "No stats returned for vhost" {
        $mockLogger = Mock-Logger
        $lastStatTimes = @{}
        $vmHostName = "vmHost"
        Mock ConnectTo-vSphere
        Mock DisconnectFrom-vSphere
        Mock Get-VirtualHosts { return @(@{Name = $vmHostName}) }
        Mock Get-AvailableStatsForHost { return "cpu" }
        Mock Get-HostStat { return @() }
        Mock Send-ToGraphite

        Record-Metrics $configuration $logger $lastStatTimes

        It "Should not record anything" {
            Assert-MockCalled Send-ToGraphite -Exactly 0
        }
    }
}