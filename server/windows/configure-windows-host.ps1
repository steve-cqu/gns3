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
      - installs and starts the OpenSSH server, so a GNS3 node can `ssh` in - from the
        pinned Win32-OpenSSH MSI, falling back to Windows Update
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

    Prefer -LabAdapterMac. A Windows adapter name is an accident of the order Windows
    happened to enumerate the hardware, and it is NOT the hypervisor's adapter number:
    on 20 September 2026 a VM whose VirtualBox NIC 2 was the lab adapter presented it to
    Windows as "Ethernet", while "Ethernet 2" was the NAT one.

.PARAMETER LabAdapterMac
    MAC address of the lab adapter, in any punctuation: 08-00-27-3B-70-EA, 08:00:27:3b:70:ea
    and 0800273B70EA all work. This is the only identifier the hypervisor and Windows both
    agree on, so it is what an installer should pass. Overrides -LabAdapter.

.PARAMETER IPAddress
    Static address for the lab adapter, e.g. 192.168.10.50. Leave it out to keep whatever
    the adapter already has, which is what you want if the topology runs a DHCP server.

.PARAMETER PrefixLength
    Netmask length for -IPAddress. Defaults to 24.

.PARAMETER LabGateway
    Address of the router that reaches the rest of the lab, e.g. 10.10.1.1. Only needed
    when the topology has more than one subnet. Without it Windows sends anything outside
    its own subnet out of the NAT adapter, where it dies - the machine can ping its
    immediate neighbours and nothing beyond them.

.PARAMETER LabNetwork
    The address block -LabGateway routes to, in CIDR form. Defaults to 10.10.0.0/16, which
    covers the usual lab addressing. Ignored unless -LabGateway is given.

.PARAMETER ComputerName
    Rename the machine, e.g. WinHost. Takes effect after a restart.

.PARAMETER PreferWindowsUpdate
    Install the OpenSSH server from Windows Update first, falling back to the pinned MSI.
    The default is the other way round, because the capability install takes minutes and the
    MSI takes seconds. Use this on a network that can reach Windows Update but not GitHub.

.PARAMETER OpenSshMsiUrl
    Fetch the OpenSSH MSI from here instead of GitHub - a local mirror, or a copy on the
    lab network. A local path works too.

.PARAMETER OpenSshMsiSha256
    Expected SHA-256 of -OpenSshMsiUrl. Without it the installer's Authenticode signature
    must be a valid Microsoft one instead, or nothing is installed. The built-in GitHub
    URLs carry their own pinned hashes and need neither of these.

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
    [string] $LabAdapterMac,
    [string] $IPAddress,
    [int]    $PrefixLength = 24,
    [string] $LabGateway,
    [string] $LabNetwork = '10.10.0.0/16',
    [string] $ComputerName,
    [switch] $PreferWindowsUpdate,
    [string] $OpenSshMsiUrl,
    [string] $OpenSshMsiSha256,
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

# --------------------------------------------------------------------------- #
# Keep a record, because the most important runs are the ones nobody watches.
#
# When an installer calls this script at first logon, everything it prints goes to a window
# that closes itself. On 20 September 2026 that led to "the configure script did not run" -
# it had run, had set the address, and was still several minutes into installing OpenSSH,
# which nothing on screen could say. A log answers that in one command, and it is the file
# to ask a student for when their machine does not come up right.
#
# Appended, so re-runs accumulate rather than erase. A transcript is a convenience and never
# a reason to stop: some hosts do not support it, and that must not cost the student a
# working machine.
# --------------------------------------------------------------------------- #
$TranscriptPath = Join-Path $env:WINDIR 'Temp\configure-windows-host.log'
$transcriptOn = $false
try {
    Start-Transcript -Path $TranscriptPath -Append -ErrorAction Stop | Out-Null
    $transcriptOn = $true
} catch { }

# One line per run, in a file with an obvious name, so "did this machine configure itself?"
# is answerable without reading a transcript - and answerable over ssh, or by a student
# reading it out. Appended, so a re-run shows the history rather than hiding it.
$StatusPath = Join-Path $env:WINDIR 'Temp\configure-windows-host.status'

function Write-RunStatus {
    param([string] $Verdict)
    try {
        ("{0}  {1}  changed={2} already-correct={3} failed={4}" -f `
            $Verdict.PadRight(7), (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),
            $script:Changed, $script:Unchanged, $script:Failed) |
            Out-File -FilePath $StatusPath -Encoding ascii -Append -ErrorAction Stop
    } catch { }
}

# Every early exit goes through here. The status file exists so that a run nobody watched
# can be read afterwards, and the runs most worth reading are the ones that gave up early -
# so an `exit 1` that skips writing it defeats the whole point.
function Stop-Now {
    param([string] $Verdict = 'FAILED')
    Write-RunStatus $Verdict
    if ($transcriptOn) {
        Write-Host ""
        Write-Host "  log         : $TranscriptPath"
        Write-Host "  status      : $StatusPath"
        try { Stop-Transcript | Out-Null } catch { }
    }
    exit 1
}

Write-Host ""
Write-Host "Configuring this machine as the GNS3 Windows Host" -ForegroundColor Cyan
if ($DryRun) { Write-Host "DRY RUN - nothing will be changed." -ForegroundColor Yellow }
Write-Host ""

# --------------------------------------------------------------------------- #
# 1. Find the lab adapter
#
# Three ways, in order of how much they can be trusted:
#
#   -LabAdapterMac   a MAC address. The only identifier the hypervisor and Windows both
#                    agree on, so this is what an installer should pass.
#   -LabAdapter      a Windows adapter name. Fine when a person is reading the names off
#                    the screen in front of them; a guess when a script does it.
#   neither          the adapter with no default gateway. On the standard build the VM has
#                    two adapters - NAT for the internet, and the lab network - and only
#                    the NAT one has a default gateway, so the other is the lab adapter.
#
# Why the MAC matters, measured on 20 September 2026: a VM was built whose lab adapter
# Windows called "Ethernet", while "Ethernet 2" - the name the installer passed - was the
# NAT adapter. A Windows adapter name records the order Windows happened to enumerate the
# hardware in. It is not the hypervisor's adapter number, and the "#2" suffix in the device
# description is not either.
# --------------------------------------------------------------------------- #
Write-Host "Network adapter"

$adapter = $null
if ($LabAdapterMac) {
    # Accept any punctuation - hypervisors print these every which way. VBoxManage's
    # machine-readable output has no separators at all, showvminfo uses colons, and Windows
    # uses hyphens, so comparing the hex digits alone is the only thing that always works.
    $wantMac = ($LabAdapterMac -replace '[^0-9A-Fa-f]', '').ToUpper()
    if ($wantMac.Length -ne 12) {
        Report-Failed "lab adapter" "'$LabAdapterMac' is not a MAC address (needs 12 hex digits)"
        Stop-Now
    }
    $adapter = Get-NetAdapter |
               Where-Object { ($_.MacAddress -replace '[^0-9A-Fa-f]', '').ToUpper() -eq $wantMac } |
               Select-Object -First 1
    if (-not $adapter) {
        Report-Failed "lab adapter" "no adapter on this machine has MAC $LabAdapterMac"
        Write-Host ""
        Write-Host "Adapters on this machine:"
        Get-NetAdapter | Format-Table Name, InterfaceDescription, Status, MacAddress -AutoSize |
            Out-String | Write-Host
        Stop-Now
    }
} elseif ($LabAdapter) {
    $adapter = Get-NetAdapter -Name $LabAdapter -ErrorAction SilentlyContinue
    if (-not $adapter) {
        Report-Failed "lab adapter" "no adapter named '$LabAdapter'"
        Write-Host ""
        Write-Host "Adapters on this machine:"
        Get-NetAdapter | Format-Table Name, InterfaceDescription, Status, MacAddress -AutoSize |
            Out-String | Write-Host
        Stop-Now
    }
} else {
    $up = @(Get-NetAdapter | Where-Object Status -eq 'Up')
    $withGateway = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                     Select-Object -ExpandProperty ifIndex -Unique)
    $candidates = @($up | Where-Object { $withGateway -notcontains $_.ifIndex })

    if ($candidates.Count -eq 1) {
        $adapter = $candidates[0]
    } elseif ($candidates.Count -eq 0 -and $up.Count -eq 1) {
        # One adapter, and it has a default gateway - so it is almost certainly the NAT
        # adapter that gives this VM its internet, and the lab adapter has not been added
        # yet. Proceed, because a single lab adapter behind a topology router legitimately
        # looks the same, but say so loudly: configuring the NAT adapter and then wondering
        # why nothing pings is exactly the trap this warning exists to close (found on the
        # first spike run, 8 Aug 2026).
        $adapter = $up[0]
        Write-Host ""
        Write-Host "  WARNING  this VM has only ONE network adapter, and it has a default" -ForegroundColor Yellow
        Write-Host "           gateway - so it is probably the NAT adapter that gives this"  -ForegroundColor Yellow
        Write-Host "           machine its internet, NOT a lab adapter."                     -ForegroundColor Yellow
        Write-Host ""
        Write-Host "           A Windows Host normally has two adapters: one NAT for the"    -ForegroundColor Yellow
        Write-Host "           internet, and one on the isolated lab network shared with"    -ForegroundColor Yellow
        Write-Host "           the GNS3 VM. If nothing on the lab network can ping this"     -ForegroundColor Yellow
        Write-Host "           machine, add that second adapter and run this script again."  -ForegroundColor Yellow
        Write-Host ""
    } else {
        Report-Failed "lab adapter" "cannot tell which adapter is the lab one"
        Write-Host ""
        Write-Host "Re-run with -LabAdapterMac and one of these:"
        Get-NetAdapter | Format-Table Name, InterfaceDescription, Status, MacAddress -AutoSize |
            Out-String | Write-Host
        Stop-Now
    }
}

# The MAC is in this line because it is the identifier that ties this adapter to a NIC in
# the hypervisor, and a log that records only the name cannot be checked afterwards.
Report-Ok "lab adapter" "$($adapter.Name)  ($($adapter.InterfaceDescription))  $($adapter.MacAddress)"

# --------------------------------------------------------------------------- #
# The guard this script did not have on 20 September 2026.
#
# A lab network has no gateway - that is what makes it a lab network. So an adapter holding
# the default route is never the lab adapter when there is another one to choose, and
# giving it a static address is actively destructive: the block below removes the DHCP
# lease, disables DHCP and sets an address with no gateway, which takes the machine's
# internet away.
#
# That is exactly what happened. An installer passed the adapter NAME of what it believed
# was the lab adapter; on that machine the name belonged to the NAT adapter; this script
# dutifully cut the machine off from the internet, and the OpenSSH install below then failed
# against Windows Update several minutes later with an error that pointed nowhere near the
# cause. Every individual step reported success. The whole fault is visible in one line -
# "the adapter I was told to configure owns the default route" - and nothing was looking.
# --------------------------------------------------------------------------- #
$defaultRouteIfIndexes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                           Select-Object -ExpandProperty ifIndex -Unique)
$otherUp = @(Get-NetAdapter |
             Where-Object { $_.Status -eq 'Up' -and $_.ifIndex -ne $adapter.ifIndex })

if ($defaultRouteIfIndexes -contains $adapter.ifIndex -and $otherUp.Count -gt 0) {
    $better = $otherUp | Where-Object { $defaultRouteIfIndexes -notcontains $_.ifIndex } |
              Select-Object -First 1

    Write-Host ""
    Write-Host "  WARNING  '$($adapter.Name)' owns this machine's DEFAULT ROUTE."            -ForegroundColor Yellow
    Write-Host "           That makes it the adapter with the internet on it, and a lab"     -ForegroundColor Yellow
    Write-Host "           network has no gateway - so this is probably the wrong adapter."  -ForegroundColor Yellow
    if ($better) {
        Write-Host ""
        Write-Host "           The lab adapter is almost certainly '$($better.Name)'"        -ForegroundColor Yellow
        Write-Host "           ($($better.MacAddress)), which is up and has no default route." -ForegroundColor Yellow
    }

    if ($IPAddress) {
        Write-Host ""
        Write-Host "           REFUSING to continue. Setting a static address here would"    -ForegroundColor Red
        Write-Host "           remove the DHCP lease and the default route, and this machine" -ForegroundColor Red
        Write-Host "           would lose the internet - which the OpenSSH install needs."   -ForegroundColor Red
        Write-Host ""
        if ($better) {
            Write-Host "           Re-run with:  -LabAdapterMac $($better.MacAddress)"
        } else {
            Write-Host "           Re-run naming the lab adapter with -LabAdapterMac."
        }
        Write-Host ""
        Write-Host "Adapters on this machine:"
        Get-NetAdapter | Format-Table Name, InterfaceDescription, Status, MacAddress -AutoSize |
            Out-String | Write-Host
        Report-Failed "lab adapter" "'$($adapter.Name)' owns the default route - refusing to give it a static lab address"
        Stop-Now
    }

    Write-Host ""
    Write-Host "           Continuing: no -IPAddress was given, so addressing is untouched." -ForegroundColor Yellow
    Write-Host ""
}

# Private, not Public. Windows files any network it cannot identify as Public, and an isolated
# lab network - no gateway, no DNS - is never identifiable.
#
# This is a courtesy, NOT what makes the machine reachable. Windows re-classifies these
# networks as Public again on the next boot, and confirmed on a real machine on 8 Aug 2026:
# after a reboot BOTH adapters were back to Public. What actually keeps ssh and ping working
# is that every firewall rule this script creates is -Profile Any, so it does not care.
#
# Setting it still helps anything that does care about the profile - network discovery and
# file sharing - so it is worth doing. Just never rely on it holding.
# Not $profile - that is an automatic PowerShell variable holding the profile script path.
$connProfile = Get-NetConnectionProfile -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue
if ($connProfile -and $connProfile.NetworkCategory -ne 'Private') {
    # Catch it. Run early enough - at first logon, on a network Windows has not finished
    # classifying - this fails with NotImplemented (MI RESULT 7), and without -ErrorAction
    # the failure printed in red while the line below still announced a change that had not
    # happened. Seen 20 September 2026 on a machine configured from the answer file's
    # first-logon command, which runs earlier in the boot than VirtualBox's post-install
    # command does.
    $categorySet = $true
    if (-not $DryRun) {
        try {
            Set-NetConnectionProfile -InterfaceIndex $adapter.ifIndex -NetworkCategory Private -ErrorAction Stop
        } catch {
            $categorySet = $false
        }
    }
    if ($categorySet) {
        Report-Changed "network profile" "$($connProfile.NetworkCategory) -> Private"
    } else {
        Write-Host ("  note     {0,-26} {1}" -f "network profile", "could not be set - left $($connProfile.NetworkCategory)") -ForegroundColor Yellow
        Write-Host ("                                      harmless: every rule this script adds is -Profile Any") -ForegroundColor DarkGray
    }
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

# Route to the rest of the lab, if the topology has more than one subnet.
#
# Measured on the spike machine: the only default route is 0.0.0.0/0 -> 10.0.2.2 out of the
# NAT adapter, and the lab adapter contributes only its own on-link /24. So Windows can
# reach its immediate neighbours and nothing behind a lab router - those packets go out of
# NAT and are dropped. A persistent route for the lab block fixes it.
if ($LabGateway) {
    $haveRoute = Get-NetRoute -DestinationPrefix $LabNetwork -ErrorAction SilentlyContinue |
                 Where-Object { $_.NextHop -eq $LabGateway }
    if ($haveRoute) {
        Report-Ok "lab route" "$LabNetwork via $LabGateway already set"
    } else {
        try {
            if (-not $DryRun) {
                # Both stores: ActiveStore takes effect now, PersistentStore survives a reboot.
                foreach ($store in 'ActiveStore', 'PersistentStore') {
                    New-NetRoute -DestinationPrefix $LabNetwork `
                                 -InterfaceIndex $adapter.ifIndex `
                                 -NextHop $LabGateway `
                                 -PolicyStore $store -ErrorAction Stop | Out-Null
                }
            }
            Report-Changed "lab route" "$LabNetwork via $LabGateway"
        } catch {
            Report-Failed "lab route" $_.Exception.Message
        }
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

# Windows Home has no Remote Desktop *server* - it can only be a client. Setting the
# registry key and opening port 3389 on Home therefore achieves nothing, and leaves a
# firewall hole in front of a port nothing listens on. Detect it and say so instead.
#
# Get-WindowsEdition returns DISM's edition ID, which is not localised: Core / CoreN /
# CoreSingleLanguage / CoreCountrySpecific are the Home family.
#
# This is defensive rather than expected. CQU's Azure ISO is single-edition Education, and
# the consumer multi-edition ISO offers an edition list at install time - so a student only
# ends up on Home by choosing it. The check costs nothing and turns a silently useless
# firewall rule into a clear message.
$edition = $null
try { $edition = (Get-WindowsEdition -Online -ErrorAction Stop).Edition } catch { }

if ($edition -and $edition -like 'Core*') {
    Report-Ok "remote desktop" "not available on Windows Home (edition: $edition)"
    Write-Host "           Use ssh instead - it works on every edition. Remote Desktop"  -ForegroundColor Yellow
    Write-Host "           needs Pro, Education or Enterprise. Pick Pro at the edition"   -ForegroundColor Yellow
    Write-Host "           list during Windows Setup next time: it installs unactivated"  -ForegroundColor Yellow
    Write-Host "           just like Home, so it costs nothing extra."                    -ForegroundColor Yellow
    $skipRdp = $true
} else {
    $skipRdp = $false
}

if (-not $skipRdp) {

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

# Match on rule NAME, not on the group. The group resource string '@FirewallAPI.dll,-28752'
# is what most guides use, but no rule carries it on Windows 11 - a spike run on 8 Aug 2026
# failed here with "No MSFT_NetFirewallRule objects found". Rule names are stable across
# releases and are not localised, unlike the display names shown in the firewall UI.
$rdpRuleNames = @('RemoteDesktop-UserMode-In-TCP', 'RemoteDesktop-UserMode-In-UDP')
$rdpRules = @(foreach ($name in $rdpRuleNames) {
    Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue
})

if ($rdpRules.Count -gt 0) {
    $off = @($rdpRules | Where-Object Enabled -ne 'True')
    if ($off.Count -eq 0) {
        Report-Ok "remote desktop firewall" "already allowed"
    } else {
        try {
            if (-not $DryRun) { $off | Enable-NetFirewallRule }
            Report-Changed "remote desktop firewall" "$($off.Count) built-in rule(s) enabled"
        } catch {
            Report-Failed "remote desktop firewall" $_.Exception.Message
        }
    }
} else {
    # No built-in rules at all (a stripped image, or Microsoft renames them again). Our own
    # rule does the same job and is obvious in the firewall UI.
    $ownRule = Get-NetFirewallRule -Name 'CQU-Lab-RDP-In' -ErrorAction SilentlyContinue
    if ($ownRule -and $ownRule.Enabled -eq 'True') {
        Report-Ok "remote desktop firewall" "inbound 3389 already allowed"
    } else {
        try {
            if (-not $DryRun) {
                if ($ownRule) {
                    Set-NetFirewallRule -Name 'CQU-Lab-RDP-In' -Enabled True
                } else {
                    New-NetFirewallRule -Name 'CQU-Lab-RDP-In' `
                                        -DisplayName 'CQU Lab - Allow Remote Desktop' `
                                        -Direction Inbound -Action Allow -Enabled True `
                                        -Protocol TCP -LocalPort 3389 -Profile Any | Out-Null
                }
            }
            Report-Changed "remote desktop firewall" "inbound 3389 allowed (no built-in rule found)"
        } catch {
            Report-Failed "remote desktop firewall" $_.Exception.Message
        }
    }
}

}  # end if (-not $skipRdp)

# --------------------------------------------------------------------------- #
# 4. OpenSSH server, so a GNS3 node can log in
#
# This is what makes the machine usable as a lab node rather than only as a desktop: a
# Linux node in the topology can `ssh` in, and staff test scripts can drive it.
#
# There are two ways to get it, and this script will use either:
#
#   1. The signed Win32-OpenSSH MSI from GitHub, pinned by version and SHA-256 below.
#      Tried FIRST. A 6 MB download and an msiexec run: seconds.
#   2. The Windows capability (Feature on Demand), fetched from Windows Update. The right
#      build for this OS, nothing to keep current, and what Microsoft documents - but
#      several minutes every time, and on 20 September 2026 it failed outright.
#
# Why the MSI leads, decided 20 September 2026 after measuring both:
#
#   SPEED. The capability's payload is a few MB, but the time goes on component-based
#   servicing against the live image - single-threaded, disk-bound - and on a machine
#   minutes old it queues behind Windows Update's first scan. It cost several minutes of
#   every unattended build, for every student, on every rebuild. Nothing tunes that away:
#   a local -Source removes the download, which was never the expensive part.
#
#   RELIABILITY. A build that day came up with no ssh at all. Three capability attempts
#   thirty seconds apart failed with 0x80240438 (WU_E_PT_ENDPOINT_UNKNOWN). That machine
#   turned out to have had its default route removed by this very script - see section 1 -
#   so Windows Update was not reachable and nor would the MSI have been. But it showed how
#   silently this step can fail, and a pinned MSI fails the same way every time or not at
#   all.
#
#   DETERMINISM. The same OpenSSH on every machine, pinned and hash-verified, instead of
#   whatever the servicing stack produces on the day.
#
# What that costs: a version pin somebody has to bump, and GitHub has to be reachable at
# first logon. The capability catches both - it is the fallback now, and a code in
# $WuDeadEnds stops it retrying into a wall. -PreferWindowsUpdate swaps the order back, for
# a network that can reach Windows Update but not GitHub.
# --------------------------------------------------------------------------- #

# Pinned on purpose: an unattended build must install the same OpenSSH every time, and a
# hash that is actually checked is the only thing that makes "download an installer at
# first logon" defensible. GitHub publishes these digests in its release metadata; both
# were confirmed by downloading the files, 20 September 2026.
#
# To move to a newer release, take the tag, the asset names and the digests from
#   https://api.github.com/repos/PowerShell/Win32-OpenSSH/releases/latest
# Every release this project has ever cut is named "Beta" or "Preview" and none is flagged
# as a prerelease on GitHub, so "latest" is simply the newest one - the naming is not a
# warning about stability.
$OpenSshRelease = '10.0.0.0p2-Preview'
$OpenSshAssets  = @{
    'AMD64' = @{ Name   = 'OpenSSH-Win64-v10.0.0.0.msi'
                 Sha256 = 'DDEC9C53864280759CF9F74791CEFD387100E3946AA849A1C138A4ED1B96B7D9' }
    'ARM64' = @{ Name   = 'OpenSSH-ARM64-v10.0.0.0.msi'
                 Sha256 = '7A17D0E22D004FB47CA4BFD8FEF926FA305DE4EBF70A6F3C7A29C39AABEF0023' }
}

# Windows Update failures that no amount of retrying will fix. Seeing one of these is the
# signal to stop asking Windows Update and fetch the MSI instead.
$WuDeadEnds = @{
    '0x80240438' = 'the update client could not determine a service endpoint'
    '0x8024402C' = 'the update client could not resolve or reach the service (DNS or proxy)'
    '0x8024500C' = 'the update service refused the request'
    '0x800F0954' = 'DISM could not reach Windows Update'
    '0x800F0950' = 'the Feature on Demand source was unavailable'
    '0x80070422' = 'the Windows Update service is disabled'
}

# Download, verify and install the pinned Win32-OpenSSH MSI. Throws on any failure, so the
# caller can report Windows Update's error and this one together.
#
# $Sha256 may be empty, which only happens when someone passes their own -OpenSshMsiUrl.
# In that case the Authenticode signature becomes the gate and a bad one is fatal: there is
# no pin to fall back on, and silently running an unverified installer as SYSTEM is not
# something to ship, least of all in a security unit's teaching appliance.
function Install-OpenSshFromMsi {
    param(
        [Parameter(Mandatory)] [string] $Url,
        [string] $Sha256
    )

    $msi    = Join-Path $env:WINDIR 'Temp\openssh-server.msi'
    $msiLog = Join-Path $env:WINDIR 'Temp\openssh-msi.log'

    Write-Host "  working  openssh MSI                fetching $Url" -ForegroundColor DarkGray

    # Invoke-WebRequest's progress bar costs more wall-clock than the 6 MB download itself,
    # and in an unattended window nobody is there to watch it.
    $oldProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
        Invoke-WebRequest -Uri $Url -OutFile $msi -UseBasicParsing -ErrorAction Stop
    } finally {
        $ProgressPreference = $oldProgress
    }

    $actual = (Get-FileHash -Path $msi -Algorithm SHA256).Hash
    if ($Sha256 -and $actual -ne $Sha256) {
        Remove-Item $msi -Force -ErrorAction SilentlyContinue
        throw "SHA-256 mismatch - expected $Sha256, got $actual. Nothing was installed and the file was deleted."
    }

    # With a matching pin this is a second opinion rather than the gate, and it is allowed
    # to fail: a machine that cannot fetch a CRL reports something other than Valid for a
    # file that is perfectly good, and that must not cost the student a working lab host.
    $sig = Get-AuthenticodeSignature -FilePath $msi
    $signedByMicrosoft = $sig.Status -eq 'Valid' -and $sig.SignerCertificate.Subject -match 'Microsoft Corporation'
    if ($signedByMicrosoft) {
        Report-Applied "openssh MSI signature" "valid, Microsoft Corporation"
    } elseif ($Sha256) {
        Write-Host ("  note     {0,-26} {1}" -f "openssh MSI signature", "$($sig.Status) - continuing, the SHA-256 matched") -ForegroundColor Yellow
    } else {
        Remove-Item $msi -Force -ErrorAction SilentlyContinue
        throw "no SHA-256 was given for this URL and the signature is $($sig.Status), not a valid Microsoft one. Nothing was installed."
    }

    # No ADDLOCAL: the default installs both client and server, and naming a feature this
    # MSI does not have fails the entire install with a bare 1603.
    $proc = Start-Process -FilePath 'msiexec.exe' -Wait -PassThru -ArgumentList @(
        '/i', "`"$msi`"", '/qn', '/norestart', '/l*v', "`"$msiLog`"")
    if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
        throw "msiexec exited $($proc.ExitCode) - the verbose log is $msiLog"
    }
    Remove-Item $msi -Force -ErrorAction SilentlyContinue
}

# Install the OpenSSH server capability from Windows Update. Throws with a reason on
# failure, so the caller can report both sources' reasons together.
function Install-OpenSshCapability {
    param([Parameter(Mandatory)] $Capability)

    # This is far slower than its size suggests, and the wait reads as a hang. The payload
    # is a few MB; the time goes on component-based servicing against the live image -
    # single-threaded, disk-bound - and on a machine minutes old it queues behind Windows
    # Update's first scan. Say so before it starts, and report how long it took, so the next
    # person has a number rather than a fear. It is also the whole reason the MSI is tried
    # first: this step alone was costing several minutes of every unattended build.
    Write-Host "  working  openssh package            installing from Windows Update - usually a few minutes." -ForegroundColor DarkGray
    Write-Host "                                      Most of that is Windows servicing the image, not downloading." -ForegroundColor DarkGray
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            Add-WindowsCapability -Online -Name $Capability.Name -ErrorAction Stop | Out-Null
            $sw.Stop()
            return " in {0:0} min {1:00} s" -f [math]::Floor($sw.Elapsed.TotalMinutes), $sw.Elapsed.Seconds
        } catch {
            $code = '0x{0:X8}' -f $_.Exception.HResult
            if ($WuDeadEnds.ContainsKey($code)) {
                $sw.Stop()
                throw "$code - $($WuDeadEnds[$code]); retrying cannot fix that"
            }
            if ($attempt -ge 3) {
                $sw.Stop()
                throw "$code after $attempt attempts"
            }
            Write-Host ("                                      attempt $attempt failed ($code) - retrying in 30 s") -ForegroundColor Yellow
            Start-Sleep -Seconds 30
        }
    }
}

Write-Host ""
Write-Host "OpenSSH server"

$sshInstalled  = $false
$sshSource     = ''
$whyMsi        = ''
$whyCapability = ''

# Is it already here? Either source counts. A machine that got the MSI has no capability
# installed, and must not be handed one on top of it.
$existingSvc = Get-Service sshd -ErrorAction SilentlyContinue
$cap = $null
try { $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1 } catch { }

if ($existingSvc) {
    Report-Ok "openssh package" "already installed (sshd service present)"
    $sshInstalled = $true
} elseif ($cap -and $cap.State -eq 'Installed') {
    Report-Ok "openssh package" "already installed (Windows capability)"
    $sshInstalled = $true
} elseif ($DryRun) {
    Report-Changed "openssh package" "would install - the pinned MSI, or the Windows capability if that fails"
    $sshInstalled = $true
} else {
    $order = if ($PreferWindowsUpdate) { @('capability', 'msi') } else { @('msi', 'capability') }

    foreach ($source in $order) {
        if ($sshInstalled) { break }

        if ($source -eq 'msi') {
            $url = $OpenSshMsiUrl
            $sha = $OpenSshMsiSha256
            if (-not $url) {
                $asset = $OpenSshAssets[$env:PROCESSOR_ARCHITECTURE]
                if ($asset) {
                    $url = "https://github.com/PowerShell/Win32-OpenSSH/releases/download/$OpenSshRelease/$($asset.Name)"
                    $sha = $asset.Sha256
                } else {
                    $whyMsi = "no MSI is pinned for $env:PROCESSOR_ARCHITECTURE"
                }
            }
            if ($url) {
                try {
                    $sw = [System.Diagnostics.Stopwatch]::StartNew()
                    Install-OpenSshFromMsi -Url $url -Sha256 $sha
                    $sw.Stop()
                    Report-Changed "openssh package" ("installed from the Win32-OpenSSH MSI ($OpenSshRelease) in {0:0} s" -f $sw.Elapsed.TotalSeconds)
                    $sshInstalled = $true
                    $sshSource    = 'msi'
                } catch {
                    $whyMsi = $_.Exception.Message
                    Write-Host ("  note     {0,-26} {1}" -f "openssh MSI", "failed: $whyMsi") -ForegroundColor Yellow
                }
            } else {
                Write-Host ("  note     {0,-26} {1}" -f "openssh MSI", $whyMsi) -ForegroundColor Yellow
            }
        }

        if ($source -eq 'capability') {
            if (-not $cap) {
                $whyCapability = 'this image offers no OpenSSH.Server capability'
                Write-Host ("  note     {0,-26} {1}" -f "openssh package", $whyCapability) -ForegroundColor Yellow
            } else {
                try {
                    $elapsed = Install-OpenSshCapability -Capability $cap
                    Report-Changed "openssh package" "installed from Windows Update$elapsed"
                    $sshInstalled = $true
                    $sshSource    = 'capability'
                } catch {
                    $whyCapability = $_.Exception.Message
                    Write-Host ("                                      $whyCapability") -ForegroundColor Yellow
                }
            }
        }
    }

    if (-not $sshInstalled) {
        Report-Failed "openssh package" "both sources failed - MSI: $whyMsi / Windows Update: $whyCapability"
    } elseif ($whyMsi -and $sshSource -eq 'capability') {
        Write-Host "                                      the MSI had failed: $whyMsi" -ForegroundColor DarkGray
    } elseif ($whyCapability -and $sshSource -eq 'msi') {
        Write-Host "                                      Windows Update had failed: $whyCapability" -ForegroundColor DarkGray
    }
}

# Worth one line, because it is the first thing that confuses anyone debugging this machine
# later: the two sources put the binaries in different places.
if ($sshSource -eq 'msi') {
    Write-Host ("  note     {0,-26} {1}" -f "openssh location", "C:\Program Files\OpenSSH, not System32\OpenSSH") -ForegroundColor Yellow
    Write-Host  "                                      Config and host keys stay in C:\ProgramData\ssh either way," -ForegroundColor DarkGray
    Write-Host  "                                      so administrators_authorized_keys is unchanged." -ForegroundColor DarkGray
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

# Always ensure OUR rule exists, even when the OpenSSH capability added one of its own.
#
# The capability's rule is scoped to the Private and Domain profiles. The lab network has no
# gateway and no DNS, so Windows files it as an "unidentified network" and puts it in the
# PUBLIC profile — and re-does that after a reboot, even once it has been set to Private,
# because it treats it as a network it has not seen before. The symptom is nasty: ping keeps
# working (our ICMP rules are -Profile Any) while ssh silently stops answering.
#
# Ours is -Profile Any, so it survives the profile flipping back.
$sshRule = Get-NetFirewallRule -Name 'CQU-Lab-SSH-In' -ErrorAction SilentlyContinue
if ($sshRule -and $sshRule.Enabled -eq 'True') {
    Report-Ok "ssh firewall" "inbound 22 allowed on every profile"
} else {
    try {
        if (-not $DryRun) {
            if ($sshRule) {
                Set-NetFirewallRule -Name 'CQU-Lab-SSH-In' -Enabled True
            } else {
                New-NetFirewallRule -Name 'CQU-Lab-SSH-In' -DisplayName 'CQU Lab - Allow SSH' `
                                    -Direction Inbound -Action Allow -Enabled True `
                                    -Protocol TCP -LocalPort 22 -Profile Any | Out-Null
            }
        }
        Report-Changed "ssh firewall" "inbound 22 allowed on every profile"
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

Write-RunStatus $(if ($script:Failed) { 'FAILED' } else { 'OK' })

if ($script:Failed) {
    Write-Host ""
    Write-Host "Some steps failed. The most common cause is no internet on the NAT adapter," -ForegroundColor Yellow
    Write-Host "which both OpenSSH sources need. Fix that and run this script again."       -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  what happened : $TranscriptPath"
    Write-Host "  one-line check: $StatusPath"
    if ($transcriptOn) { try { Stop-Transcript | Out-Null } catch { } }
    exit 1
}

$labIps = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 `
                             -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty IPAddress)
$labIp = $labIps -join ', '

# 169.254.x.x is APIPA: Windows invented it because nothing gave the adapter an address.
# The machine looks configured and is not reachable at any lab address, so say so rather
# than printing the APIPA address as if it were usable.
$apipaOnly = $labIps.Count -gt 0 -and -not ($labIps | Where-Object { $_ -notlike '169.254.*' })

Write-Host ""
if ($apipaOnly) {
    Write-Host "Almost - this machine has NO LAB ADDRESS." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  $($adapter.Name) has only $labIp, which Windows makes up when nothing" -ForegroundColor Yellow
    Write-Host "  assigns it an address. Nothing on the lab network can reach it."       -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Either the topology has no DHCP server, in which case set the address"  -ForegroundColor Yellow
    Write-Host "  yourself:"                                                              -ForegroundColor Yellow
    Write-Host ""
    Write-Host "      .\configure-windows-host.ps1 -LabAdapter `"$($adapter.Name)`" -IPAddress 10.10.1.20"
    Write-Host ""
    Write-Host "  or this adapter is not on the lab network at all - check that its"      -ForegroundColor Yellow
    Write-Host "  VirtualBox internal network name matches the GNS3 VM's exactly."        -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Everything else above was applied."
    if ($transcriptOn) { Write-Host "  log         : $TranscriptPath"; try { Stop-Transcript | Out-Null } catch { } }
    exit 0
}

Write-Host "This machine is ready to use as the GNS3 Windows Host." -ForegroundColor Green
Write-Host "  lab adapter : $($adapter.Name)"
Write-Host "  lab address : $(if ($labIp) { $labIp } else { 'none yet - waiting on the topology DHCP server' })"
Write-Host "  reachable by: ping, ssh $env:USERNAME@<address>$(if (-not $skipRdp) { ', and Remote Desktop' })"
if ($transcriptOn) { Write-Host "  log         : $TranscriptPath" }
Write-Host "  status      : $StatusPath"
if ($script:Restart) {
    Write-Host ""
    Write-Host "Restart Windows for the new computer name to take effect." -ForegroundColor Yellow
}
if ($transcriptOn) { try { Stop-Transcript | Out-Null } catch { } }
