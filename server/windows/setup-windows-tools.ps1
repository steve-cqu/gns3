<#
.SYNOPSIS
    Install the lab tooling on the GNS3 Windows Host.

.DESCRIPTION
    Run this inside the Windows VM, in an Administrator PowerShell, AFTER
    configure-windows-host.ps1 has made the machine reachable.

    That script and this one do different jobs on purpose. configure-windows-host.ps1 is
    quick, downloads almost nothing, and every student needs it. This one downloads
    hundreds of megabytes and installs things only some units want - so a failed download
    here cannot take your firewall rules and ssh access down with it.

    Everything here ADDS. Nothing is removed, and every switch is safe to run again, so a
    part-finished run can simply be repeated.

    What each switch installs:

      -Sysinternals  The Sysinternals Suite (185 MB) to C:\Tools\Sysinternals, on the
                     system PATH, with the licence agreement pre-accepted so the tools do
                     not stop on a dialog. TCPView, Process Explorer, Autoruns, PsExec and
                     about 160 others.
      -WebServer     IIS, so the machine serves a web page on port 80 that other nodes can
                     fetch. A Windows feature, so there is nothing to download.
      -Python        Python 3, machine-wide so it works over ssh, and removes the Windows
                     stub that opens the Microsoft Store instead of running Python.
      -Iperf         iperf3, for throughput testing against the Linux nodes.
      -Telnet        The telnet client, for checking whether a port answers.
      -Sysmon        Sysmon with a small teaching configuration, logging process creation,
                     network connections and DNS queries to the Windows event log. Needs
                     -Sysinternals, since Sysmon lives in that suite. Installs a driver,
                     which is why it is not part of -All.
      -All           Everything except -Sysmon.

    SOME OF THIS NEEDS A RESTART. Windows features (IIS, telnet) enable but their programs
    and services do not appear until the machine reboots. The script says so at the end if
    a restart is needed.

.PARAMETER PythonPackage
    winget package id for Python. Version-pinned by winget's own naming, so it goes stale:
    check with `winget search Python.Python --source winget` and pass a newer one if needed.

.PARAMETER List
    Report what is already installed and change nothing.

.PARAMETER DryRun
    Report what would change and change nothing.

.EXAMPLE
    .\setup-windows-tools.ps1 -All

.EXAMPLE
    .\setup-windows-tools.ps1 -Sysinternals -WebServer

.EXAMPLE
    .\setup-windows-tools.ps1 -List
#>

[CmdletBinding()]
param(
    [switch] $Sysinternals,
    [switch] $WebServer,
    [switch] $Python,
    [switch] $Iperf,
    [switch] $Telnet,
    [switch] $Sysmon,
    [switch] $All,
    [switch] $List,
    [switch] $DryRun,
    [string] $PythonPackage = 'Python.Python.3.12'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # or Invoke-WebRequest is very slow

$SYSINTERNALS_DIR = 'C:\Tools\Sysinternals'
$SYSINTERNALS_URL = 'https://download.sysinternals.com/files/SysinternalsSuite.zip'
$SYSMON_CONFIG    = 'sysmon-lab.xml'
$SYSMON_CONFIG_URL = 'https://raw.githubusercontent.com/steve-cqu/gns3/refs/heads/main/server/windows/sysmon-lab.xml'
$IPERF_PACKAGE    = 'ar51an.iPerf3'

$script:Changed = 0; $script:Unchanged = 0; $script:Failed = 0; $script:Restart = $false

function Report-Ok      { param($W,$D) Write-Host ("  ok       {0,-16} {1}" -f $W,$D); $script:Unchanged++ }
function Report-Changed { param($W,$D) Write-Host ("  {0}  {1,-16} {2}" -f $(if($DryRun){'would  '}else{'changed'}),$W,$D) -ForegroundColor Green; $script:Changed++ }
function Report-Failed  { param($W,$D) Write-Host ("  FAILED   {0,-16} {1}" -f $W,$D) -ForegroundColor Red; $script:Failed++ }
function Report-Info    { param($W,$D) Write-Host ("  info     {0,-16} {1}" -f $W,$D) }
# For a step that is cheaper to re-apply than to read back, so we cannot honestly say whether
# it changed anything. Counted as neither, same as its sibling script does for power settings.
function Report-Applied { param($W,$D) Write-Host ("  applied  {0,-16} {1}" -f $W,$D) }

# --------------------------------------------------------------------------- #
# Preconditions
# --------------------------------------------------------------------------- #
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
          [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "This script must run as Administrator." -ForegroundColor Red
    Write-Host "Right-click PowerShell, choose 'Run as administrator', and try again."
    exit 1
}

if ($All) { $Sysinternals = $WebServer = $Python = $Iperf = $Telnet = $true }

if (-not ($Sysinternals -or $WebServer -or $Python -or $Iperf -or $Telnet -or $Sysmon -or $List)) {
    Write-Host "Nothing selected. Choose what to install, for example:" -ForegroundColor Yellow
    Write-Host "    .\setup-windows-tools.ps1 -All"
    Write-Host "    .\setup-windows-tools.ps1 -Sysinternals -WebServer"
    Write-Host "    .\setup-windows-tools.ps1 -List        (show what is already here)"
    Write-Host ""
    Write-Host "Full details:  Get-Help .\setup-windows-tools.ps1 -Detailed"
    exit 0
}

# --------------------------------------------------------------------------- #
# -List: report and stop
# --------------------------------------------------------------------------- #
function Get-FeatureState {
    param($Name)
    try { (Get-WindowsOptionalFeature -Online -FeatureName $Name).State } catch { 'unknown' }
}

if ($List) {
    Write-Host ""
    Write-Host "Windows Host tooling" -ForegroundColor Cyan
    Report-Info "sysinternals" $(if (Test-Path (Join-Path $SYSINTERNALS_DIR 'tcpview.exe'))
                                 { "installed in $SYSINTERNALS_DIR" } else { 'not installed' })
    Report-Info "iis"          (Get-FeatureState 'IIS-WebServerRole')
    Report-Info "telnet"       (Get-FeatureState 'TelnetClient')
    $py = Get-Command python -ErrorAction SilentlyContinue
    Report-Info "python" $(if (-not $py) { 'not installed' }
                           elseif ($py.Source -like '*WindowsApps*') { "Store stub only - $($py.Source)" }
                           else { $py.Source })
    $ip = Get-Command iperf3 -ErrorAction SilentlyContinue
    Report-Info "iperf3"       $(if ($ip) { $ip.Source } else { 'not installed' })
    $sm = Get-Service Sysmon64 -ErrorAction SilentlyContinue
    Report-Info "sysmon"       $(if ($sm) { "service $($sm.Status)" } else { 'not installed' })
    Write-Host ""
    exit 0
}

Write-Host ""
Write-Host "Installing lab tooling on the GNS3 Windows Host" -ForegroundColor Cyan
if ($DryRun) { Write-Host "DRY RUN - nothing will be changed." -ForegroundColor Yellow }

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #

# Enable a Windows optional feature. These never take effect until a reboot: the feature
# reports Enabled straight away, but its programs and services do not exist until then.
function Enable-Feature {
    param([string[]] $Name, [string] $Label, [string] $Probe)

    if ($Probe -and (Test-Path $Probe)) { Report-Ok $Label 'already enabled'; return }
    if ((Get-FeatureState $Name[0]) -eq 'Enabled' -and -not $Probe) {
        Report-Ok $Label 'already enabled'; return
    }
    if ($DryRun) { Report-Changed $Label "would enable $($Name -join ', ')"; return }
    try {
        $r = Enable-WindowsOptionalFeature -Online -FeatureName $Name -All -NoRestart
        Report-Changed $Label 'enabled'
        if ($r.RestartNeeded) { $script:Restart = $true }
    } catch {
        Report-Failed $Label $_.Exception.Message
    }
}

# Install a winget package.
#
# --source winget is NOT optional: the msstore source fails on a stock Windows 11 with
# 0x8a15005e (server certificate did not match), and that error aborts the whole command
# even when the package is available from the working source.
#
# --exact avoids a near-miss match on a different package. --scope machine puts it on the
# system PATH, so it works over ssh and not only for the interactive user.
function Install-WingetPackage {
    param([string] $Id, [string] $Label, [string] $Probe)

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Report-Failed $Label 'winget not found - update App Installer from the Microsoft Store'
        return
    }
    if ($Probe) {
        $have = Get-Command $Probe -ErrorAction SilentlyContinue
        if ($have -and $have.Source -notlike '*WindowsApps*') {
            Report-Ok $Label "already installed ($($have.Source))"; return
        }
    }
    $listed = (& winget list --id $Id --source winget --exact 2>$null | Out-String)
    if ($listed -match [regex]::Escape($Id)) { Report-Ok $Label 'already installed'; return }
    if ($DryRun) { Report-Changed $Label "would install $Id"; return }

    Write-Host ("  ...      {0,-16} downloading" -f $Label)
    $out = (& winget install --id $Id --source winget --exact --scope machine --silent `
                             --accept-source-agreements --accept-package-agreements 2>&1 | Out-String)
    if ($LASTEXITCODE -eq 0) {
        Report-Changed $Label 'installed'
    } else {
        $why = ($out -split "`n" | Where-Object { $_ -match '\S' } | Select-Object -Last 1).Trim()
        Report-Failed $Label "winget exit $LASTEXITCODE - $why"
    }
}

# --------------------------------------------------------------------------- #
# Sysinternals
# --------------------------------------------------------------------------- #
if ($Sysinternals) {
    Write-Host ""
    Write-Host "Sysinternals"

    $marker = Join-Path $SYSINTERNALS_DIR 'tcpview.exe'
    if (Test-Path $marker) {
        Report-Ok 'suite' "already in $SYSINTERNALS_DIR"
    } elseif ($DryRun) {
        Report-Changed 'suite' "would download 185 MB to $SYSINTERNALS_DIR"
    } else {
        try {
            New-Item -ItemType Directory -Path $SYSINTERNALS_DIR -Force | Out-Null
            $zip = Join-Path $env:TEMP 'SysinternalsSuite.zip'
            Write-Host "  ...      suite            downloading 185 MB, this takes a few minutes"
            Invoke-WebRequest -Uri $SYSINTERNALS_URL -OutFile $zip -UseBasicParsing
            Expand-Archive -Path $zip -DestinationPath $SYSINTERNALS_DIR -Force
            Remove-Item $zip -Force
            Report-Changed 'suite' "$((Get-ChildItem $SYSINTERNALS_DIR -File).Count) files in $SYSINTERNALS_DIR"
        } catch {
            Report-Failed 'suite' $_.Exception.Message
        }
    }

    # On the system PATH, so the tools work from an ssh session and from a test script,
    # not just for the interactive user.
    if (Test-Path $SYSINTERNALS_DIR) {
        $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        if ($machinePath -like "*$SYSINTERNALS_DIR*") {
            Report-Ok 'path' 'already on the system PATH'
        } elseif ($DryRun) {
            Report-Changed 'path' "would add $SYSINTERNALS_DIR to the system PATH"
        } else {
            [Environment]::SetEnvironmentVariable('Path', "$machinePath;$SYSINTERNALS_DIR", 'Machine')
            Report-Changed 'path' 'added to the system PATH (open a new window to use it)'
        }
    }

    # Pre-accept the licence for every tool. Without this each one opens a dialog the first
    # time it runs - which for a command-line tool over ssh means it hangs with no clue why.
    # One registry write per tool, and there are about 160, so it is slow enough on a small
    # VM to look stuck. Hence the progress line.
    if ((Test-Path $SYSINTERNALS_DIR) -and -not $DryRun) {
        try {
            $exes = @(Get-ChildItem $SYSINTERNALS_DIR -Filter *.exe)
            # Only write the ones that are missing. Writing all ~160 every time takes minutes
            # on a 4 GB VM and would make every re-run of -All look like it had hung.
            $todo = @($exes | Where-Object {
                $k = "HKCU:\Software\Sysinternals\$($_.BaseName)"
                (Get-ItemProperty -Path $k -Name EulaAccepted -ErrorAction SilentlyContinue).EulaAccepted -ne 1
            })
            if ($todo.Count -eq 0) {
                Report-Ok 'licence' "already accepted for $($exes.Count) tool(s)"
            } else {
                $n = 0
                foreach ($exe in $todo) {
                    $n++
                    if ($n % 25 -eq 0) { Write-Host ("  ...      licence          $n of $($todo.Count)") }
                    $k = "HKCU:\Software\Sysinternals\$($exe.BaseName)"
                    if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
                    New-ItemProperty -Path $k -Name EulaAccepted -Value 1 `
                                     -PropertyType DWord -Force | Out-Null
                }
                Report-Changed 'licence' "pre-accepted for $n tool(s)"
            }
        } catch {
            Report-Failed 'licence' $_.Exception.Message
        }
    } elseif ($DryRun) {
        Report-Changed 'licence' 'pre-accept the licence for every tool'
    }
}

# --------------------------------------------------------------------------- #
# IIS
#
# No firewall rule needed: enabling IIS creates IIS-WebServerRole-HTTP-In-TCP with
# Profile=Any, which is why the web server keeps working after a reboot even though
# Windows puts the lab network back into the Public profile. Verified 8 Aug 2026.
# --------------------------------------------------------------------------- #
if ($WebServer) {
    Write-Host ""
    Write-Host "Web server (IIS)"
    Enable-Feature -Name @('IIS-WebServerRole','IIS-WebServer','IIS-CommonHttpFeatures',
                           'IIS-StaticContent','IIS-DefaultDocument') -Label 'iis'
    Report-Info 'iis' 'serves the default page on port 80 once the machine has restarted'
}

# --------------------------------------------------------------------------- #
# Telnet client
# --------------------------------------------------------------------------- #
if ($Telnet) {
    Write-Host ""
    Write-Host "Telnet client"
    Enable-Feature -Name @('TelnetClient') -Label 'telnet' `
                   -Probe "$env:SystemRoot\System32\telnet.exe"
}

# --------------------------------------------------------------------------- #
# Python
# --------------------------------------------------------------------------- #
if ($Python) {
    Write-Host ""
    Write-Host "Python"
    Install-WingetPackage -Id $PythonPackage -Label 'python' -Probe 'python'

    # Windows ships a python.exe that opens the Microsoft Store instead of running Python.
    # It sits ahead of the real one on PATH, so a student typing 'python' gets a shop.
    $stubs = @(Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WindowsApps\python*.exe" -ErrorAction SilentlyContinue)
    if (-not $stubs) {
        Report-Ok 'store stub' 'not present'
    } elseif ($DryRun) {
        Report-Changed 'store stub' "would remove $($stubs.Count) stub(s)"
    } else {
        try {
            $stubs | Remove-Item -Force -ErrorAction Stop
            Report-Changed 'store stub' "removed $($stubs.Count) stub(s)"
        } catch {
            Report-Failed 'store stub' $_.Exception.Message
        }
    }
}

# --------------------------------------------------------------------------- #
# iperf3
# --------------------------------------------------------------------------- #
if ($Iperf) {
    Write-Host ""
    Write-Host "iperf3"
    Install-WingetPackage -Id $IPERF_PACKAGE -Label 'iperf3' -Probe 'iperf3'
    Report-Info 'iperf3' 'run "iperf3 -s" here, then "iperf3 -c <this address>" on a Linux node'
}

# --------------------------------------------------------------------------- #
# Sysmon
# --------------------------------------------------------------------------- #
if ($Sysmon) {
    Write-Host ""
    Write-Host "Sysmon"

    $exe = Join-Path $SYSINTERNALS_DIR 'Sysmon64.exe'
    if (-not (Test-Path $exe)) {
        Report-Failed 'sysmon' "not found - run with -Sysinternals first, Sysmon is part of that suite"
    } else {
        # The config lives beside this script. Fall back to fetching it, since a student who
        # downloaded only the .ps1 will not have it.
        $cfg = Join-Path $PSScriptRoot $SYSMON_CONFIG
        if (-not (Test-Path $cfg)) { $cfg = Join-Path (Get-Location) $SYSMON_CONFIG }
        if (-not (Test-Path $cfg) -and -not $DryRun) {
            try {
                Invoke-WebRequest -Uri $SYSMON_CONFIG_URL -OutFile $cfg -UseBasicParsing
                Report-Changed 'config' "downloaded $SYSMON_CONFIG"
            } catch {
                Report-Failed 'config' "could not fetch $SYSMON_CONFIG - $($_.Exception.Message)"
            }
        }

        $svc = Get-Service Sysmon64 -ErrorAction SilentlyContinue
        if ($DryRun) {
            Report-Changed 'sysmon' $(if ($svc) { 'would update the configuration' } else { 'would install' })
        } elseif (-not (Test-Path $cfg)) {
            Report-Failed 'sysmon' 'no configuration file, not installing'
        } elseif ($svc) {
            & $exe -accepteula -c $cfg | Out-Null
            Report-Applied 'sysmon' 'configuration re-applied'
        } else {
            & $exe -accepteula -i $cfg | Out-Null
            $svc = Get-Service Sysmon64 -ErrorAction SilentlyContinue
            if ($svc) { Report-Changed 'sysmon' "installed, service $($svc.Status)" }
            else      { Report-Failed  'sysmon' 'installer ran but the service is not there' }
        }
        Report-Info 'sysmon' 'read it with: Get-WinEvent -LogName Microsoft-Windows-Sysmon/Operational'
    }
}

# --------------------------------------------------------------------------- #
# Summary
# --------------------------------------------------------------------------- #
Write-Host ""
if ($DryRun) {
    Write-Host "Dry run: $script:Changed change(s) would be made, $script:Unchanged already correct."
    exit 0
}

Write-Host "$script:Changed change(s), $script:Unchanged already correct, $script:Failed failed."
if ($script:Failed) {
    Write-Host ""
    Write-Host "Something failed. The usual cause is no internet on the NAT adapter -" -ForegroundColor Yellow
    Write-Host "check that first, then run this script again. It picks up where it left off." -ForegroundColor Yellow
    exit 1
}

if ($script:Restart) {
    Write-Host ""
    Write-Host "RESTART WINDOWS NOW." -ForegroundColor Yellow
    Write-Host "The Windows features you just enabled report themselves as on, but their" -ForegroundColor Yellow
    Write-Host "programs and services do not exist until the machine has restarted." -ForegroundColor Yellow
}
