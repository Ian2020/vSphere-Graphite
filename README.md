vSphere-Graphite
================

A PowerShell script that pushes vSphere stats to Graphite. Runs as a scheduled task, installed via Chocolatey.

##Installation

The project builds to a [Chocolatey](https://chocolatey.org/) package which can then be installed the usual Chocolatey way.

###Prerequisites

* [Chocolatey](https://chocolatey.org/)

###Building

1. Clone the repo
2. Run cpack - if successful a vSphere-Graphite.nupkg file will be built.

###Installing

From the repo directory run:

    choco install vSphereGraphite -source '"$((Resolve-Path .).Path);https://chocolatey.org/api/v2/"'

This will install the scheduled task that polls vSphere.

##Usage

* Configure the script by editing %CHOCOLATEYINSTALL%\lib\vSphereGraphite.[VERSION]\tools\vSphere-Graphite.config. Restart the scheduled task for changes to take effect.
* Check the log for any issues: %CHOCOLATEYINSTALL%\lib\vSphereGraphite.[VERSION]\tools\vSphere-Graphite.log
