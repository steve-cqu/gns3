<#
.SYNOPSIS
    Turn a fresh Windows 11 VM into the "Windows Host" used beside the GNS3 VM.

.DESCRIPTION
    Run this ONCE inside the Windows VM, in an Administrator PowerShell.

    Why: a stock Windows install cannot be used as a lab node. It does not answer ping, it
    has no way in from a GNS3 node, and its second network adapter is treated as a public
    network, which blocks nearly everything. This script fixes those, in one pass.

    What it does:
      - allows inbound ping (ICMPv4 and ICMPv6 echo). Windows blocks this by default, and
        it is the first thing a student tries
      - installs and starts the OpenSSH server, so a GNS3 node can `ssh` in
      - enables Remote Desktop, so you can reach the machine from your own desktop
      - marks the lab adapter as a Private network, not Public
      - optionally gives the lab adapter a static address, and renames the machine
      - stops the machine sleeping, which silently kills a running lab

    What it does NOT do: it does not create the VM, touch the hypervisor, or configure the
    GNS3 side. It also does not activate Windows - an unactivated Windows 11 runs fine for
    lab work, with a watermark and no personalisation.

    Safe to run more than once. Everything it does is checked first and reported as either
    changed or already correct.

.PARAMETER LabAdapter
    Name of the network adapter connected to the lab network, e.g. "Ethernet 2". If you
    leave this out, the script picks the adapter that has no default gateway - which on a
    two-adapter VM (one NAT for the internet, one for the lab) is the lab one.

.PARAMETER IPAddress
    Static address for the lab adapter, e.g. 192.168.10.50. Leave it out to keep whatever
    the adapter already has, which is what you want if the topology runs a DHCP server.

.PARAMETER PrefixLength
    Netmask length for -IPAddress. Defaults to 24.

.PARAMETER ComputerName
    Rename the machine, e.g. WinHost. Takes effect after a restart.

.PARAMETER DryRun
    Report what would change and change nothing.

.EXAMPLE
    .\configure-windows-host.ps1

.EXAMPLE
    .\configure-windows-host.ps1 -LabAdapter "Ethernet 2" -IPAddress 192.168.10.50 -ComputerName WinHost

.EXAMPLE
    .\configure-windows-host.ps1 -DryRun
#>

[CmdletBinding()]
param(
    [string] $LabAdapter,
    [string] $IPAddress,
    [int]    $PrefixLength = 24,
    [string] $ComputerName,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'

$script:Changed   = 0
$script:Unchanged = 0
$script:Failed    = 0
$script:Restart   = $false

function Report-Ok      { param($What, $Detail) Write-Host ("  ok       {0,-26} {1}" -f $What, $Detail); $script:Unchanged++ }
function Report-Changed { param($What, $Detail) Write-Host ("  {0}  {1,-26} {2}" -f $(if ($DryRun) {'would  '} else {'changed'}), $What, $Detail) -ForegroundColor Green; $script:Changed++ }
function Report-Failed  { param($What, $Detail) Write-Host ("  FAILED   {0,-26} {1}" -f $What, $Detail) -ForegroundColor Red; $script:Failed++ }
# For settings that are cheaper to re-apply than to read back, so we cannot honestly say
# whether they changed. Counted as neither.
function Report-Applied { param($What, $Detail) Write-Host ("  applied  {0,-26} {1}" -f $What, $Detail) }

# --------------------------------------------------------------------------- #
# Preconditions
# --------------------------------------------------------------------------- #
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole(
          [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "This script must run as Administrator." -ForegroundColor Red
    Write-Host "Right-click PowerShell and choose 'Run as administrator', then run it again."
    exit 1
}

Write-Host ""
Write-Host "Configuring this machine as the GNS3 Windows Host" -ForegroundColor Cyan
if ($DryRun) { Write-Host "DRY RUN - nothing will be changed." -ForegroundColor Yellow }
Write-Host ""

# --------------------------------------------------------------------------- #
# 1. Find the lab adapter
#
# On the standard build the VM has two adapters: NAT for the internet, and the lab
# network. Only the NAT one has a default gateway, so the other is the lab adapter.
# --------------------------------------------------------------------------- #
Write-Host "Network adapter"

$adapter = $null
if ($LabAdapter) {
    $adapter = Get-NetAdapter -Name $LabAdapter -ErrorAction SilentlyContinue
    if (-not $adapter) {
        Report-Failed "lab adapter" "no adapter named '$LabAdapter'"
        Write-Host ""
        Write-Host "Adapters on this machine:"
        Get-NetAdapter | Format-Table Name, InterfaceDescription, Status -AutoSize | Out-String | Write-Host
        exit 1
    }
} else {
    $up = @(Get-NetAdapter | Where-Object Status -eq 'Up')
    $withGateway = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                     Select-Object -ExpandProperty ifIndex -Unique)
    $candidates = @($up | Where-Object { $withGateway -notcontains $_.ifIndex })

    if ($candidates.Count -eq 1) {
        $adapter = $candidates[0]
    } elseif ($candidates.Count -eq 0 -and $up.Count -eq 1) {
        # Single-adapter VM: that adapter is the lab adapter, gateway or not.
        $adapter = $up[0]
    } else {
        Report-Failed "lab adapter" "cannot tell which adapter is the lab one"
        Write-Host ""
        Write-Host "Re-run with -LabAdapter and one of these names:"
        Get-NetAdapter | Format-Table Name, InterfaceDescription, Status -AutoSize | Out-String | Write-Host
        exit 1
    }
}
Report-Ok "lab adapter" "$($adapter.Name)  ($($adapter.InterfaceDescription))"

# Private, not Public. A Public profile blocks nearly all inbound traffic, so a lab node
# cannot reach this machine at all - and Windows chooses Public for any network it cannot
# identify, which an isolated lab network never is.
# Not $profile - that is an automatic PowerShell variable holding the profile script path.
$connProfile = Get-NetConnectionProfile -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue
if ($connProfile -and $connProfile.NetworkCategory -ne 'Private') {
    if (-not $DryRun) {
        Set-NetConnectionProfile -InterfaceIndex $adapter.ifIndex -NetworkCategory Private
    }
    Report-Changed "network profile" "$($connProfile.NetworkCategory) -> Private"
} elseif ($connProfile) {
    Report-Ok "network profile" "already Private"
} else {
    # No profile yet: the adapter is up but has not been assigned a network. Harmless here,
    # since Windows assigns one as soon as the link carries traffic.
    Report-Ok "network profile" "not assigned yet (adapter has seen no traffic)"
}

# Static address, only if asked for. With no -IPAddress the adapter keeps DHCP, which is
# what you want when the topology itself serves addresses.
if ($IPAddress) {
    $existing = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 `
                                 -ErrorAction SilentlyContinue |
                Where-Object IPAddress -eq $IPAddress
    if ($existing) {
        Report-Ok "lab address" "$IPAddress/$PrefixLength already set"
    } else {
        if (-not $DryRun) {
            Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 `
                             -ErrorAction SilentlyContinue |
                Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
            Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -Dhcp Disabled
            New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $IPAddress `
                             -PrefixLength $PrefixLength | Out-Null
        }
        Report-Changed "lab address" "$IPAddress/$PrefixLength"
    }
}

# --------------------------------------------------------------------------- #
# 2. Firewall: let the lab ping this machine
#
# Our own rules rather than the built-in "File and Printer Sharing (Echo Request)" ones:
# those have localised display names, and their internal names have changed between
# Windows releases. A rule we create ourselves is stable and obvious in the firewall UI.
# --------------------------------------------------------------------------- #
Write-Host ""
Write-Host "Firewall"

$icmpRules = @(
    @{ Name = 'CQU-Lab-ICMPv4-In'; Display = 'CQU Lab - Allow ping (ICMPv4)'; Protocol = 'ICMPv4'; Type = '8' }
    @{ Name = 'CQU-Lab-ICMPv6-In'; Display = 'CQU Lab - Allow ping (ICMPv6)'; Protocol = 'ICMPv6'; Type = '128' }
)
foreach ($rule in $icmpRules) {
    $have = Get-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue
    if ($have -and $have.Enabled -eq 'True') {
        Report-Ok $rule.Protocol "inbound echo already allowed"
        continue
    }
    try {
        if (-not $DryRun) {
            if ($have) {
                Set-NetFirewallRule -Name $rule.Name -Enabled True
            } else {
                New-NetFirewallRule -Name $rule.Name -DisplayName $rule.Display `
                                    -Direction Inbound -Action Allow -Enabled True `
                                    -Protocol $rule.Protocol `
                                    -IcmpType $rule.Type -Profile Any | Out-Null
            }
        }
        Report-Changed $rule.Protocol "inbound echo allowed"
    } catch {
        Report-Failed $rule.Protocol $_.Exception.Message
    }
}

# --------------------------------------------------------------------------- #
# 3. Remote Desktop, so the machine is reachable from the student's own desktop
#
# The firewall group is referenced by its resource string, which is the same in every
# language - unlike the display name shown in the firewall UI.
# --------------------------------------------------------------------------- #
Write-Host ""
Write-Host "Remote Desktop"

$tsKey = 'HKLM:\System\CurrentControlSet\Control\Terminal Server'
$denied = (Get-ItemProperty -Path $tsKey -Name fDenyTSConnections -ErrorAction SilentlyContinue).fDenyTSConnections
if ($denied -eq 0) {
    Report-Ok "remote desktop" "already enabled"
} else {
    try {
        if (-not $DryRun) { Set-ItemProperty -Path $tsKey -Name fDenyTSConnections -Value 0 }
        Report-Changed "remote desktop" "enabled"
    } catch {
        Report-Failed "remote desktop" $_.Exception.Message
    }
}

try {
    $rdpRules = @(Get-NetFirewallRule -Group '@FirewallAPI.dll,-28752' -ErrorAction Stop)
    $off = @($rdpRules | Where-Object Enabled -ne 'True')
    if ($off.Count -eq 0) {
        Report-Ok "remote desktop firewall" "already allowed"
    } else {
        if (-not $DryRun) { $off | Enable-NetFirewallRule }
        Report-Changed "remote desktop firewall" "$($off.Count) rule(s) enabled"
    }
} catch {
    Report-Failed "remote desktop firewall" $_.Exception.Message
}

# --------------------------------------------------------------------------- #
# 4. OpenSSH server, so a GNS3 node can log in
#
# This is what makes the machine usable as a lab node rather than only as a desktop: a
# Linux node in the topology can `ssh` in, and staff test scripts can drive it. Installing
# the capability needs internet access on the NAT adapter (Windows fetches it from Windows
# Update); if that fails the rest of the script still applies.
# --------------------------------------------------------------------------- #
Write-Host ""
Write-Host "OpenSSH server"

$sshInstalled = $false
try {
    $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
    if ($cap.State -eq 'Installed') {
        Report-Ok "openssh package" "already installed"
        $sshInstalled = $true
    } else {
        if (-not $DryRun) { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }
        Report-Changed "openssh package" "installed"
        $sshInstalled = $true
    }
} catch {
    Report-Failed "openssh package" "$($_.Exception.Message) - is the NAT adapter online?"
}

# Gate on this step's own result, not on $script:Failed - an unrelated earlier failure
# (say a firewall rule) must not silently skip starting the service.
if (-not $DryRun -and $sshInstalled) {
    try {
        $svc = Get-Service sshd -ErrorAction Stop
        if ($svc.StartType -ne 'Automatic') {
            Set-Service sshd -StartupType Automatic
            Report-Changed "sshd startup" "set to Automatic"
        } else {
            Report-Ok "sshd startup" "already Automatic"
        }
        if ($svc.Status -ne 'Running') {
            Start-Service sshd
            Report-Changed "sshd" "started"
        } else {
            Report-Ok "sshd" "already running"
        }
    } catch {
        Report-Failed "sshd service" $_.Exception.Message
    }
} elseif ($DryRun) {
    Report-Changed "sshd" "would be set to Automatic and started"
}

# The OpenSSH capability normally adds its own firewall rule. Add ours if it did not.
$sshRule = Get-NetFirewallRule -Name 'CQU-Lab-SSH-In' -ErrorAction SilentlyContinue
$anySsh  = Get-NetFirewallRule -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -like '*OpenSSH*' -and $_.Enabled -eq 'True' }
if ($sshRule -or $anySsh) {
    Report-Ok "ssh firewall" "inbound 22 already allowed"
} else {
    try {
        if (-not $DryRun) {
            New-NetFirewallRule -Name 'CQU-Lab-SSH-In' -DisplayName 'CQU Lab - Allow SSH' `
                                -Direction Inbound -Action Allow -Enabled True `
                                -Protocol TCP -LocalPort 22 -Profile Any | Out-Null
        }
        Report-Changed "ssh firewall" "inbound 22 allowed"
    } catch {
        Report-Failed "ssh firewall" $_.Exception.Message
    }
}

# --------------------------------------------------------------------------- #
# 5. Stop the machine sleeping mid-lab
# --------------------------------------------------------------------------- #
Write-Host ""
Write-Host "Power"

try {
    if (-not $DryRun) {
        powercfg /change standby-timeout-ac 0
        powercfg /change hibernate-timeout-ac 0
        powercfg /change monitor-timeout-ac 0
    }
    Report-Applied "sleep" "disabled on AC power"
} catch {
    Report-Failed "sleep" $_.Exception.Message
}

# --------------------------------------------------------------------------- #
# 6. Hostname, if asked for
# --------------------------------------------------------------------------- #
if ($ComputerName) {
    Write-Host ""
    Write-Host "Name"
    if ($env:COMPUTERNAME -eq $ComputerName) {
        Report-Ok "computer name" "already $ComputerName"
    } else {
        try {
            if (-not $DryRun) { Rename-Computer -NewName $ComputerName -Force | Out-Null }
            Report-Changed "computer name" "$env:COMPUTERNAME -> $ComputerName (after restart)"
            $script:Restart = $true
        } catch {
            Report-Failed "computer name" $_.Exception.Message
        }
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
    Write-Host "Some steps failed. The most common cause is no internet on the NAT adapter," -ForegroundColor Yellow
    Write-Host "which the OpenSSH install needs. Fix that and run this script again."       -ForegroundColor Yellow
    exit 1
}

$labIp = (Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 `
                           -ErrorAction SilentlyContinue).IPAddress -join ', '
Write-Host ""
Write-Host "This machine is ready to use as the GNS3 Windows Host." -ForegroundColor Green
Write-Host "  lab adapter : $($adapter.Name)"
Write-Host "  lab address : $(if ($labIp) { $labIp } else { 'none yet - waiting on the topology DHCP server' })"
Write-Host "  reachable by: ping, ssh $env:USERNAME@<address>, and Remote Desktop"
if ($script:Restart) {
    Write-Host ""
    Write-Host "Restart Windows for the new computer name to take effect." -ForegroundColor Yellow
}
