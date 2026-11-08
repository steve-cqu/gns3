# NetCompat: the Windows networking cmdlets, rebuilt on Linux's `ip -json` for the GNS3 PC node.
#
# On Windows these cmdlets are CDXML wrappers over CIM classes (MSFT_NetAdapter, MSFT_NetIPAddress…)
# and do not exist in PowerShell on Linux. This module returns objects with the same property names,
# so pipelines from the tutorials (Format-List *, Where-Object InterfaceAlias -eq …) work unchanged.
#
# Interface names: the kernel's eth0, eth1… are reported as Windows-style aliases ("Ethernet",
# "Ethernet 2"…). Every -InterfaceAlias / -Name parameter accepts either form.
#
# Persistence: Windows keeps an address across reboots. A GNS3 Docker node loses `ip addr add` at
# every project close, but GNS3 runs `ifup -a -f` on /etc/network/interfaces at every start and
# persists that file. So every change rewrites one marked block in it from the live state.

Set-StrictMode -Version Latest

$script:InterfacesFile = '/etc/network/interfaces'
$script:BlockBegin = '# NetCompat BEGIN: written by New-/Remove-NetIPAddress. Change it with those cmdlets.'
$script:BlockEnd   = '# NetCompat END'
# Kernel fallback tunnel devices that appear in privileged containers; Windows has no equivalent.
$script:HiddenDevs = '^(lo|sit\d+|tunl\d+|gre\d+|gretap\d+|erspan\d+|ip_vti\d+|ip6_vti\d+|ip6tnl\d+|ip6gre\d+)$'

#region helpers ---------------------------------------------------------------------------------

function Invoke-IpJson {
    param([Parameter(ValueFromRemainingArguments)][string[]]$IpArgs)
    $json = & ip -json @IpArgs 2>$null
    if (-not $json) { return @() }
    @($json | ConvertFrom-Json)
}

function ConvertTo-WinAlias {
    param([string]$Dev)
    if ($Dev -eq 'lo') { return 'Loopback Pseudo-Interface 1' }
    if ($Dev -match '^eth(\d+)$') {
        $n = [int]$Matches[1]
        if ($n -eq 0) { return 'Ethernet' }
        return "Ethernet $($n + 1)"
    }
    $Dev
}

function ConvertTo-WinDescription {
    param([string]$Dev)
    if ($Dev -match '^eth(\d+)$') {
        $n = [int]$Matches[1]
        if ($n -eq 0) { return 'GNS3 Virtual Ethernet Adapter' }
        return "GNS3 Virtual Ethernet Adapter #$($n + 1)"
    }
    "Linux interface $Dev"
}

# Every interface: kernel name, Windows alias, index. Includes lo (Get-NetIPAddress shows it).
function Get-IfTable {
    foreach ($l in Invoke-IpJson link show) {
        [pscustomobject]@{ Dev = $l.ifname; Alias = (ConvertTo-WinAlias $l.ifname); Index = [uint32]$l.ifindex; Link = $l }
    }
}

# Interfaces matching any of the names (kernel name or Windows alias, wildcards, any case).
function Select-If {
    param([object[]]$Table, [string[]]$Name)
    if (-not $Name) { return $Table }
    $Table | Where-Object {
        $row = $_
        @($Name | Where-Object { $row.Alias -like $_ -or $row.Dev -like $_ }).Count -gt 0
    }
}

# The single interface a set/remove cmdlet targets, or a Windows-style error.
function Resolve-OneIf {
    param([string]$InterfaceAlias, [uint32]$InterfaceIndex)
    $table = @(Get-IfTable)
    if ($InterfaceAlias) {
        $hit = @($table | Where-Object { $_.Alias -eq $InterfaceAlias -or $_.Dev -eq $InterfaceAlias })
        $what = "InterfaceAlias' equal to '$InterfaceAlias"
    } else {
        $hit = @($table | Where-Object { $_.Index -eq $InterfaceIndex })
        $what = "InterfaceIndex' equal to '$InterfaceIndex"
    }
    if ($hit.Count -ne 1) {
        throw "No MSFT_NetIPInterface objects found with property '$what'. Verify the value of the property and retry."
    }
    $hit[0]
}

# Terminate the calling cmdlet with a Windows-style error ("New-NetIPAddress: ..."), rather than a
# bare `throw`, which PowerShell prints as "Exception: ...".
function Stop-NetCompat {
    param($Cmdlet, [string]$Message, [string]$Category = 'InvalidArgument')
    $Cmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new(
        [System.Exception]::new($Message), 'NetCompat', $Category, $null))
}

function ConvertTo-Netmask {
    param([int]$PrefixLength)
    $bits = ('1' * $PrefixLength).PadRight(32, '0')
    (0..3 | ForEach-Object { [Convert]::ToInt32($bits.Substring($_ * 8, 8), 2) }) -join '.'
}

function Format-LinkSpeed {
    param([string]$Dev)
    # A GNS3 link has no real speed, and Linux reports a nominal 10 Mbps for the virtual Ethernet
    # pair. The lab's Windows VM shows its Hyper-V virtual adapter as 10 Gbps, so report that.
    if ($Dev -match '^eth\d+$') { return '10 Gbps' }
    $mbps = $null
    try { $mbps = [long](Get-Content "/sys/class/net/$Dev/speed" -ErrorAction Stop) } catch { }
    if ($null -eq $mbps -or $mbps -le 0) { return '0 bps' }
    if ($mbps -ge 1000) { return "$([math]::Round($mbps / 1000, 1)) Gbps" }
    "$mbps Mbps"
}

# Rewrite the NetCompat block of /etc/network/interfaces from the live IPv4 state of eth*.
# -Drop: addresses to leave out although still live (removed from the persistent store only).
# -Keep: @{ Dev; Local; PrefixLength } entries to write although no longer live (removed from the
# active store only). Windows keeps the two stores separately; these let one answer differ.
# Routes added by New-NetRoute carry `proto static`; they are persisted as `up ip route add` lines in
# their interface's stanza. -DropRoute / -KeepRoute do for routes what -Drop / -Keep do for addresses
# (objects with Dst, Gw, Dev, Metric).
function Save-NetConfig {
    param([string[]]$Drop = @(), [object[]]$Keep = @(), [object[]]$DropRoute = @(), [object[]]$KeepRoute = @())
    $routeKey = { param($r) "$($r.Dst)|$($r.Gw)|$($r.Dev)" }
    $dropKeys = @($DropRoute | ForEach-Object { & $routeKey $_ })
    $statics = [System.Collections.Generic.List[object]]::new()
    foreach ($r in Invoke-IpJson -4 route show proto static) {
        if ($r.dst -eq 'default') { continue }
        $o = [pscustomobject]@{ Dst = $r.dst; Gw = $(if ($r.PSObject.Properties['gateway']) { $r.gateway } else { '' })
                                Dev = $r.dev; Metric = $(if ($r.PSObject.Properties['metric']) { $r.metric } else { 0 }) }
        if ($dropKeys -notcontains (& $routeKey $o)) { $statics.Add($o) }
    }
    foreach ($k in $KeepRoute) { if ($k.Dst -ne '0.0.0.0/0') { $statics.Add($k) } }
    $keepDefault = @($KeepRoute | Where-Object { $_.Dst -eq '0.0.0.0/0' })
    $dropDefault = @($DropRoute | Where-Object { $_.Dst -eq '0.0.0.0/0' })
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add($script:BlockBegin)
    $defaults = @(Invoke-IpJson -4 route show default)
    foreach ($i in Invoke-IpJson addr show) {
        if ($i.ifname -notmatch '^eth\d+$') { continue }
        $addrs = @($i.addr_info | Where-Object { $_.family -eq 'inet' -and $_.scope -eq 'global' -and -not ($_.PSObject.Properties['dynamic'] -and $_.dynamic) -and $Drop -notcontains $_.local })
        foreach ($k in $Keep | Where-Object { $_.Dev -eq $i.ifname }) {
            $addrs += [pscustomobject]@{ local = $k.Local; prefixlen = $k.PrefixLength }
        }
        if ($addrs.Count -eq 0) { continue }
        $first = $addrs[0]
        $lines.Add("auto $($i.ifname)")
        $lines.Add("iface $($i.ifname) inet static")
        $lines.Add("    address $($first.local)")
        $lines.Add("    netmask $(ConvertTo-Netmask $first.prefixlen)")
        $lines.Add("    broadcast +")
        $gw = @($defaults | Where-Object { $_.dev -eq $i.ifname -and $_.PSObject.Properties['gateway'] -and
                                           @($dropDefault | Where-Object Gw -eq $_.gateway).Count -eq 0 } | ForEach-Object { $_.gateway })
        $gw += @($keepDefault | Where-Object Dev -eq $i.ifname | ForEach-Object { $_.Gw })
        if ($gw.Count -gt 0) { $lines.Add("    gateway $($gw[0])") }
        foreach ($a in $addrs | Select-Object -Skip 1) {
            $lines.Add("    up ip addr add $($a.local)/$($a.prefixlen) brd + dev $($i.ifname)")
        }
        foreach ($r in $statics | Where-Object Dev -eq $i.ifname) {
            $via = if ($r.Gw) { "via $($r.Gw) " } else { '' }
            $met = if ($r.Metric) { " metric $($r.Metric)" } else { '' }
            $lines.Add("    up ip route add $($r.Dst) $($via)dev $($i.ifname) proto static$met")
        }
    }
    $lines.Add($script:BlockEnd)

    $old = @()
    if (Test-Path $script:InterfacesFile) { $old = @(Get-Content $script:InterfacesFile) }
    $kept = [System.Collections.Generic.List[string]]::new()
    $inBlock = $false
    foreach ($l in $old) {
        if ($l -eq $script:BlockBegin) { $inBlock = $true; continue }
        if ($l -eq $script:BlockEnd) { $inBlock = $false; continue }
        if (-not $inBlock) { $kept.Add($l) }
    }
    # A stanza for the same interface outside our block (e.g. from GNS3's "Edit network
    # configuration") would make ifup configure it twice at the next start.
    foreach ($l in $kept) {
        if ($l -match '^\s*iface\s+(eth\d+)\s' -and ($lines -contains "iface $($Matches[1]) inet static")) {
            Write-Warning "$script:InterfacesFile also configures $($Matches[1]) outside the NetCompat block; the two may conflict when the node next starts."
        }
    }
    while ($kept.Count -gt 0 -and $kept[$kept.Count - 1] -eq '') { $kept.RemoveAt($kept.Count - 1) }
    $kept.Add('')
    Set-Content -Path $script:InterfacesFile -Value (@($kept) + @($lines))
}

function New-NetIPAddressObject {
    param($If, $AddrInfo, [string]$Store = 'ActiveStore')
    $isV6 = $AddrInfo.family -eq 'inet6'
    $origin = 'Manual'; $suffix = 'Manual'
    if ($If.Dev -eq 'lo') { $origin = 'WellKnown'; $suffix = 'WellKnown' }
    elseif ($isV6 -and $AddrInfo.local -like 'fe80:*') { $origin = 'WellKnown'; $suffix = 'Link' }
    elseif ($AddrInfo.PSObject.Properties['dynamic'] -and $AddrInfo.dynamic) { $origin = 'Dhcp'; $suffix = 'Dhcp' }
    $state = 'Preferred'
    if ($AddrInfo.PSObject.Properties['tentative'] -and $AddrInfo.tentative) { $state = 'Tentative' }
    $life = {
        param($v)
        if ($null -eq $v -or [uint64]$v -ge 4294967295) { [TimeSpan]::MaxValue } else { [TimeSpan]::FromSeconds([double]$v) }
    }
    [pscustomobject]@{
        PSTypeName        = 'NetCompat.NetIPAddress'
        # Windows appends the zone (the interface index) to a link-local address: fe80::1%12.
        IPAddress         = $(if ($isV6 -and $AddrInfo.local -like 'fe80:*') { "$($AddrInfo.local)%$($If.Index)" } else { $AddrInfo.local })
        InterfaceIndex    = $If.Index
        InterfaceAlias    = $If.Alias
        AddressFamily     = $(if ($isV6) { 'IPv6' } else { 'IPv4' })
        Type              = 'Unicast'
        PrefixLength      = [byte]$AddrInfo.prefixlen
        PrefixOrigin      = $origin
        SuffixOrigin      = $suffix
        AddressState      = $state
        ValidLifetime     = & $life $(if ($AddrInfo.PSObject.Properties['valid_life_time']) { $AddrInfo.valid_life_time })
        PreferredLifetime = & $life $(if ($AddrInfo.PSObject.Properties['preferred_life_time']) { $AddrInfo.preferred_life_time })
        SkipAsSource      = $false
        PolicyStore       = $Store
        ifName            = $If.Dev
    }
}

#endregion

<#
.SYNOPSIS
Emulation of the Windows cmdlet on Linux. Gets the basic network adapter properties.
.DESCRIPTION
Lists the PC's network adapters. Interfaces are shown with Windows-style names: eth0 is
"Ethernet", eth1 is "Ethernet 2", and so on. Either name works with -Name.
.EXAMPLE
Get-NetAdapter
.EXAMPLE
Get-NetAdapter -Name "Ethernet" | Format-List -Property *
#>
function Get-NetAdapter {
    [CmdletBinding(DefaultParameterSetName = 'ByName')]
    param(
        [Parameter(ParameterSetName = 'ByName', Position = 0)][Alias('ifAlias', 'InterfaceAlias')][string[]]$Name,
        [Parameter(ParameterSetName = 'ByIndex', Mandatory)][Alias('ifIndex')][uint32[]]$InterfaceIndex,
        [switch]$Physical,
        [switch]$IncludeHidden
    )
    $table = @(Get-IfTable | Where-Object { $IncludeHidden -or $_.Dev -notmatch $script:HiddenDevs })
    if ($Physical) { $table = @($table | Where-Object { $_.Dev -match '^eth\d+$' }) }
    if ($PSCmdlet.ParameterSetName -eq 'ByIndex') {
        $table = @($table | Where-Object { $InterfaceIndex -contains $_.Index })
    } else {
        $table = @(Select-If $table $Name)
    }
    if ($table.Count -eq 0 -and ($Name -or $InterfaceIndex)) {
        $prop = if ($Name) { "Name' equal to '$($Name -join ', ')" } else { "InterfaceIndex' equal to '$($InterfaceIndex -join ', ')" }
        Write-Error "No MSFT_NetAdapter objects found with property '$prop'. Verify the value of the property and retry."
        return
    }
    foreach ($row in $table | Sort-Object Alias) {
        $l = $row.Link
        $flags = @($l.flags)
        $status = if ($flags -notcontains 'UP') { 'Disabled' } elseif ($flags -contains 'LOWER_UP') { 'Up' } else { 'Disconnected' }
        $mac = if ($l.PSObject.Properties['address'] -and $l.address) { $l.address.ToUpper().Replace(':', '-') } else { '' }
        [pscustomobject]@{
            PSTypeName           = 'NetCompat.NetAdapter'
            Name                 = $row.Alias
            InterfaceDescription = ConvertTo-WinDescription $row.Dev
            ifIndex              = $row.Index
            Status               = $status
            MacAddress           = $mac
            LinkSpeed            = Format-LinkSpeed $row.Dev
            MediaConnectionState = $(if ($status -eq 'Up') { 'Connected' } else { 'Disconnected' })
            AdminStatus          = $(if ($flags -contains 'UP') { 'Up' } else { 'Down' })
            MtuSize              = [uint32]$l.mtu
            MediaType            = '802.3'
            PhysicalMediaType    = '802.3'
            FullDuplex           = $true
            Virtual              = $false
            InterfaceAlias       = $row.Alias
            ifName               = $row.Dev
        }
    }
}

<#
.SYNOPSIS
Emulation of the Windows cmdlet on Linux. Gets the IP address configuration.
.EXAMPLE
Get-NetIPAddress
.EXAMPLE
Get-NetIPAddress -InterfaceAlias "Ethernet" -AddressFamily IPv4
#>
function Get-NetIPAddress {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string[]]$IPAddress,
        [Alias('ifAlias')][string[]]$InterfaceAlias,
        [Alias('ifIndex')][uint32[]]$InterfaceIndex,
        [ValidateSet('IPv4', 'IPv6')][string[]]$AddressFamily,
        [ValidateRange(0, 128)][byte[]]$PrefixLength
    )
    $table = @(Select-If @(Get-IfTable) $InterfaceAlias)
    if ($InterfaceIndex) { $table = @($table | Where-Object { $InterfaceIndex -contains $_.Index }) }
    $byDev = @{}; foreach ($t in $table) { $byDev[$t.Dev] = $t }
    $all = [System.Collections.Generic.List[object]]::new()
    foreach ($i in Invoke-IpJson addr show) {
        if (-not $byDev.ContainsKey($i.ifname)) { continue }
        foreach ($a in @($i.addr_info)) {
            $o = New-NetIPAddressObject $byDev[$i.ifname] $a
            if ($AddressFamily -and $AddressFamily -notcontains $o.AddressFamily) { continue }
            $bare = ($o.IPAddress -split '%')[0]
            if ($IPAddress -and -not @($IPAddress | Where-Object { $o.IPAddress -like $_ -or $bare -like $_ }).Count) { continue }
            if ($PrefixLength -and $PrefixLength -notcontains $o.PrefixLength) { continue }
            $all.Add($o)
        }
    }
    # Windows lists IPv6 addresses before IPv4.
    $all | Sort-Object -Stable { if ($_.AddressFamily -eq 'IPv6') { 0 } else { 1 } }
    $found = $all.Count
    if ($found -eq 0 -and ($IPAddress -or $InterfaceAlias -or $InterfaceIndex)) {
        Write-Error 'No matching MSFT_NetIPAddress objects found by CIM query for instances of the ROOT/StandardCimv2/MSFT_NetIPAddress class on the  CIM server: SELECT * FROM MSFT_NetIPAddress. Verify query parameters and retry.'
    }
}

<#
.SYNOPSIS
Emulation of the Windows cmdlet on Linux. Adds an IP address to an interface.
.DESCRIPTION
The address is applied at once and kept across node restarts and project close/reopen (it is
written to /etc/network/interfaces).
.EXAMPLE
New-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress 78.1.2.3 -PrefixLength 24
.EXAMPLE
New-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress 78.1.2.3 -PrefixLength 24 -DefaultGateway 78.1.2.1
#>
function New-NetIPAddress {
    [CmdletBinding(DefaultParameterSetName = 'ByAlias')]
    param(
        [Parameter(Mandatory, Position = 0)][string]$IPAddress,
        [Parameter(ParameterSetName = 'ByAlias', Mandatory)][Alias('ifAlias')][string]$InterfaceAlias,
        [Parameter(ParameterSetName = 'ByIndex', Mandatory)][Alias('ifIndex')][uint32]$InterfaceIndex,
        [ValidateRange(0, 128)][byte]$PrefixLength,
        [string]$DefaultGateway,
        [ValidateSet('IPv4', 'IPv6')][string]$AddressFamily
    )
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($IPAddress, [ref]$ip)) {
        Stop-NetCompat $PSCmdlet "Cannot convert value `"$IPAddress`" to type `"System.Net.IPAddress`". Error: `"An invalid IP address was specified.`""
    }
    $isV6 = $ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6
    if (-not $PSBoundParameters.ContainsKey('PrefixLength')) {
        Stop-NetCompat $PSCmdlet 'On the simulated PC, -PrefixLength is required (for example -PrefixLength 24).'
    }
    if (-not $isV6 -and $PrefixLength -gt 32) { Stop-NetCompat $PSCmdlet "The prefix length $PrefixLength is not valid for an IPv4 address." }
    try { $if = Resolve-OneIf -InterfaceAlias $InterfaceAlias -InterfaceIndex $InterfaceIndex }
    catch { Stop-NetCompat $PSCmdlet $_.Exception.Message 'ObjectNotFound' }

    $existing = @(Invoke-IpJson addr show | ForEach-Object { $_.addr_info } | Where-Object { $_.local -eq $ip.ToString() })
    if ($existing.Count -gt 0) { Stop-NetCompat $PSCmdlet 'Instance MSFT_NetIPAddress already exists' }
    if ($DefaultGateway) {
        $fam = if ($isV6) { '-6' } else { '-4' }
        if (@(Invoke-IpJson $fam route show default).Count -gt 0) { Stop-NetCompat $PSCmdlet 'Instance MSFT_NetRoute already exists' }
    }

    # brd + sets the subnet broadcast address, as Windows has one.
    $brd = if ($isV6) { @() } else { @('brd', '+') }
    $out = & ip addr add "$($ip)/$PrefixLength" @brd dev $if.Dev 2>&1
    if ($LASTEXITCODE -ne 0) { Stop-NetCompat $PSCmdlet "Could not add $($ip)/$PrefixLength to $($if.Alias): $out" }
    if ($DefaultGateway) {
        $out = & ip route add default via $DefaultGateway dev $if.Dev 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Error "The address was added, but the default gateway was not: $out" }
    }
    Save-NetConfig

    # Windows writes the address to two stores and prints both objects.
    foreach ($store in 'ActiveStore', 'PersistentStore') {
        $a = Invoke-IpJson addr show dev $if.Dev | ForEach-Object { $_.addr_info } | Where-Object { $_.local -eq $ip.ToString() } | Select-Object -First 1
        # Windows reports the new address as Tentative (duplicate-address detection under way)
        # in the active store and Invalid in the persistent store, so copy that.
        if ($a) {
            $o = New-NetIPAddressObject $if $a $store
            $o.AddressState = if ($store -eq 'ActiveStore') { 'Tentative' } else { 'Invalid' }
            $o
        }
    }
}

<#
.SYNOPSIS
Emulation of the Windows cmdlet on Linux. Removes an IP address from an interface.
.EXAMPLE
Remove-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress 78.1.2.3
.EXAMPLE
Remove-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress 78.1.2.3 -DefaultGateway 78.1.2.1 -Confirm:$false
#>
function Remove-NetIPAddress {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Position = 0, ValueFromPipelineByPropertyName)][string[]]$IPAddress,
        [Parameter(ValueFromPipelineByPropertyName)][Alias('ifAlias')][string[]]$InterfaceAlias,
        [Parameter(ValueFromPipelineByPropertyName)][Alias('ifIndex')][uint32[]]$InterfaceIndex,
        [Parameter(ValueFromPipelineByPropertyName)][ValidateSet('IPv4', 'IPv6')][string[]]$AddressFamily,
        [string]$DefaultGateway
    )
    begin {
        # Windows confirms once per store, Active then Persistent, with this wording:
        #   Performing operation "Remove" on Target "NetIPAddress -IPv4Address 49.1.1.20 -InterfaceIndex 12 -Store Active"
        $changed = $false
        $drop = [System.Collections.Generic.List[string]]::new()
        $keep = [System.Collections.Generic.List[object]]::new()
    }
    process {
        if (-not ($IPAddress -or $InterfaceAlias -or $InterfaceIndex)) {
            Stop-NetCompat $PSCmdlet 'On the simulated PC, give -IPAddress and/or -InterfaceAlias so only the intended address is removed.'
        }
        $get = @{}
        foreach ($k in 'IPAddress', 'InterfaceAlias', 'InterfaceIndex', 'AddressFamily') {
            if ($PSBoundParameters.ContainsKey($k)) { $get[$k] = $PSBoundParameters[$k] }
        }
        if ($get.ContainsKey('IPAddress')) { $get.IPAddress = @($get.IPAddress | ForEach-Object { ($_ -split '%')[0] }) }
        $targets = @(Get-NetIPAddress @get -ErrorAction SilentlyContinue | Where-Object { $_.PrefixOrigin -ne 'WellKnown' })
        if ($targets.Count -eq 0) {
            Write-Error 'No matching MSFT_NetIPAddress objects found by CIM query for instances of the ROOT/StandardCimv2/MSFT_NetIPAddress class on the  CIM server: SELECT * FROM MSFT_NetIPAddress. Verify query parameters and retry.'
            return
        }
        foreach ($t in $targets) {
            $bare = ($t.IPAddress -split '%')[0]
            $famWord = if ($t.AddressFamily -eq 'IPv6') { 'IPv6Address' } else { 'IPv4Address' }
            $removedActive = $false
            foreach ($store in 'Active', 'Persistent') {
                $desc = "NetIPAddress -$famWord $bare -InterfaceIndex $($t.InterfaceIndex) -Store $store"
                $ok = $PSCmdlet.ShouldProcess("Remove $desc",
                    "Are you sure you want to perform this action?`nPerforming operation `"Remove`" on Target `"$desc`"",
                    'Confirm')
                if ($store -eq 'Active') {
                    if (-not $ok) { continue }
                    $out = & ip addr del "$bare/$($t.PrefixLength)" dev $t.ifName 2>&1
                    if ($LASTEXITCODE -ne 0) { Write-Error "Could not remove $($t.IPAddress): $out"; continue }
                    if ($DefaultGateway) { & ip route del default via $DefaultGateway dev $t.ifName 2>$null }
                    $removedActive = $true; $changed = $true
                } elseif ($ok) {
                    $drop.Add($bare); $changed = $true
                } elseif ($removedActive -and $t.AddressFamily -eq 'IPv4') {
                    $keep.Add([pscustomobject]@{ Dev = $t.ifName; Local = $bare; PrefixLength = $t.PrefixLength })
                }
            }
        }
    }
    end {
        if ($changed) { Save-NetConfig -Drop $drop -Keep $keep }
    }
}

#region phase 1: testing and neighbours ------------------------------------------------------

# One ICMP echo through Linux `ping`, which reports the TTL reliably. Returns Status
# (Success | TimedOut | DestinationHostUnreachable | DestinationNetworkUnreachable), the RTT in
# milliseconds, the TTL, and the address that answered.
function Invoke-EchoOnce {
    param([string]$Address, [int]$TimeoutMs = 4000, [int]$Size = 32, [int]$Ttl = 0)
    $w = [math]::Max(1, [math]::Ceiling($TimeoutMs / 1000))
    $pingArgs = @('-n', '-c', '1', '-W', "$w", '-s', "$Size")
    if ($Ttl -gt 0) { $pingArgs += @('-t', "$Ttl") }
    $text = (& /bin/ping @pingArgs $Address 2>&1) -join "`n"
    if ($text -match 'from (\S+?):? icmp_seq=\d+ ttl=(\d+) time=([\d.]+) ms') {
        return [pscustomobject]@{ Status = 'Success'; From = $Matches[1]; Ttl = [int]$Matches[2]; RttMs = [double]$Matches[3] }
    }
    if ($text -match 'From (\S+) icmp_seq=\d+ Destination Host Unreachable') {
        return [pscustomobject]@{ Status = 'DestinationHostUnreachable'; From = $Matches[1]; Ttl = 0; RttMs = 0 }
    }
    if ($text -match 'Network is unreachable|Destination Net Unreachable') {
        return [pscustomobject]@{ Status = 'DestinationNetworkUnreachable'; From = ''; Ttl = 0; RttMs = 0 }
    }
    [pscustomobject]@{ Status = 'TimedOut'; From = ''; Ttl = 0; RttMs = 0 }
}

# Resolve a name or address to one IP address string, or $null.
function Resolve-Target {
    param([string]$Name)
    $ip = $null
    if ([System.Net.IPAddress]::TryParse($Name, [ref]$ip)) { return $ip.ToString() }
    try {
        $a = [System.Net.Dns]::GetHostAddresses($Name) |
            Sort-Object { if ($_.AddressFamily -eq 'InterNetwork') { 0 } else { 1 } } | Select-Object -First 1
        if ($a) { return $a.ToString() }
    } catch { }
    $null
}

# The interface and source address the kernel would use to reach an address.
function Get-RouteTo {
    param([string]$Address)
    $r = @(Invoke-IpJson route get $Address) | Select-Object -First 1
    if (-not $r) { return $null }
    $dev = $r.dev
    [pscustomobject]@{
        Dev    = $dev
        Alias  = ConvertTo-WinAlias $dev
        Source = $(if ($r.PSObject.Properties['prefsrc']) { $r.prefsrc } else { '' })
    }
}

<#
.SYNOPSIS
Emulation of the Windows cmdlet on Linux. Displays diagnostic information for a connection.
.DESCRIPTION
With just a computer name or address, sends one ping and reports whether it succeeded and the
round-trip time. With -Port, also tries a TCP connection to that port (for example a web server
on port 80).
.EXAMPLE
Test-NetConnection 78.1.2.4
.EXAMPLE
Test-NetConnection 78.1.2.4 -Port 80
#>
function Test-NetConnection {
    [CmdletBinding(DefaultParameterSetName = 'ICMP')]
    param(
        [Parameter(Position = 0)][Alias('RemoteAddress', 'cn')][string]$ComputerName,
        [Parameter(ParameterSetName = 'RemotePort', Mandatory)][Alias('RemotePort')][ValidateRange(1, 65535)][int]$Port,
        [Parameter(ParameterSetName = 'CommonTCPPort', Mandatory, Position = 1)][ValidateSet('HTTP', 'RDP', 'SMB', 'WINRM')][string]$CommonTCPPort,
        [ValidateSet('Quiet', 'Detailed')][string]$InformationLevel,
        [switch]$TraceRoute
    )
    if (-not $ComputerName) {
        Stop-NetCompat $PSCmdlet 'On the simulated PC, give a computer name or address, for example: Test-NetConnection 78.1.2.4'
    }
    if ($CommonTCPPort) { $Port = @{ HTTP = 80; RDP = 3389; SMB = 445; WINRM = 5985 }[$CommonTCPPort] }

    $addr = Resolve-Target $ComputerName
    if (-not $addr) {
        Write-Warning "Name resolution of $ComputerName failed"
        if ($InformationLevel -eq 'Quiet') { return $false }
        return
    }
    $route = Get-RouteTo $addr
    $result = [ordered]@{
        PSTypeName       = 'NetCompat.TestNetConnectionResult'
        ComputerName     = $ComputerName
        RemoteAddress    = $addr
        RemotePort       = $(if ($Port) { $Port } else { 0 })
        InterfaceAlias   = $(if ($route) { $route.Alias } else { '' })
        SourceAddress    = $(if ($route) { $route.Source } else { '' })
        PingSucceeded    = $false
        PingReplyDetails = $null
        TcpTestSucceeded = $false
        TraceRoute       = $null
    }

    $tcpOk = $null
    if ($Port) {
        $client = [System.Net.Sockets.TcpClient]::new()
        try {
            $task = $client.ConnectAsync($addr, $Port)
            $tcpOk = $task.Wait(5000) -and $client.Connected
        } catch { $tcpOk = $false } finally { $client.Dispose() }
        $result.TcpTestSucceeded = [bool]$tcpOk
    }
    # Windows pings when no port is given, and also when the TCP test fails.
    if (-not $Port -or -not $tcpOk) {
        $echo = Invoke-EchoOnce $addr 2000
        $result.PingSucceeded = $echo.Status -eq 'Success'
        $result.PingReplyDetails = [pscustomobject]@{
            PSTypeName    = 'NetCompat.PingReply'
            Address       = $addr
            Status        = $echo.Status
            RoundtripTime = [long][math]::Floor($echo.RttMs)
        }
        if ($Port) { Write-Warning "TCP connect to ($addr : $Port) failed" }
        if (-not $result.PingSucceeded) { Write-Warning "Ping to $addr failed with status: $($echo.Status)" }
    }
    if ($TraceRoute) {
        $hops = [System.Collections.Generic.List[string]]::new()
        Invoke-TraceHops $addr 30 2000 1 { param($ttl, $times, $from) $hops.Add($(if ($from) { $from } else { '0.0.0.0' })) }
        $result.TraceRoute = $hops.ToArray()
    }
    if ($InformationLevel -eq 'Quiet') {
        if ($Port) { return [bool]$tcpOk }
        return $result.PingSucceeded
    }
    [pscustomobject]$result
}

<#
.SYNOPSIS
Emulation of the Windows cmdlet on Linux. Gets neighbour cache entries (the ARP table for IPv4).
.EXAMPLE
Get-NetNeighbor -AddressFamily IPv4
.EXAMPLE
Get-NetNeighbor -State Reachable
#>
function Get-NetNeighbor {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string[]]$IPAddress,
        [Alias('ifAlias')][string[]]$InterfaceAlias,
        [Alias('ifIndex')][uint32[]]$InterfaceIndex,
        [ValidateSet('IPv4', 'IPv6')][string[]]$AddressFamily,
        [ValidateSet('Unreachable', 'Incomplete', 'Probe', 'Delay', 'Stale', 'Reachable', 'Permanent')][string[]]$State
    )
    $table = @(Get-IfTable | Where-Object { $_.Dev -notmatch $script:HiddenDevs })
    $table = @(Select-If $table $InterfaceAlias)
    if ($InterfaceIndex) { $table = @($table | Where-Object { $InterfaceIndex -contains $_.Index }) }
    $byDev = @{}; foreach ($t in $table) { $byDev[$t.Dev] = $t }
    $stateMap = @{ REACHABLE = 'Reachable'; STALE = 'Stale'; DELAY = 'Delay'; PROBE = 'Probe'; FAILED = 'Unreachable';
                   INCOMPLETE = 'Incomplete'; PERMANENT = 'Permanent'; NOARP = 'Permanent' }
    $rows = [System.Collections.Generic.List[object]]::new()
    $add = {
        param($If, [string]$Ip, [string]$Mac, [string]$St)
        $rows.Add([pscustomobject]@{
            PSTypeName       = 'NetCompat.NetNeighbor'
            ifIndex          = $If.Index
            InterfaceAlias   = $If.Alias
            IPAddress        = $Ip
            LinkLayerAddress = $(if ($Mac) { $Mac.ToUpper().Replace(':', '-') } else { '' })
            State            = $St
            AddressFamily    = $(if ($Ip -like '*:*') { 'IPv6' } else { 'IPv4' })
            PolicyStore      = 'ActiveStore'
        })
    }
    foreach ($n in Invoke-IpJson neigh show) {
        if (-not $byDev.ContainsKey($n.dev)) { continue }
        $st = 'Stale'
        foreach ($s in @($n.state)) { if ($stateMap.ContainsKey($s)) { $st = $stateMap[$s]; break } }
        $mac = if ($n.PSObject.Properties['lladdr']) { $n.lladdr } else { '' }
        & $add $byDev[$n.dev] $n.dst $mac $st
    }
    # Windows also lists each subnet's broadcast address as a permanent entry. Computed from the
    # address and prefix, since an address added without `brd` has none set in Linux.
    foreach ($i in Invoke-IpJson -4 addr show) {
        if (-not $byDev.ContainsKey($i.ifname)) { continue }
        foreach ($a in @($i.addr_info)) {
            if ($a.scope -ne 'global' -or $a.prefixlen -ge 31) { continue }
            $bytes = [System.Net.IPAddress]::Parse($a.local).GetAddressBytes()
            [array]::Reverse($bytes)
            $n = [BitConverter]::ToUInt32($bytes, 0) -bor ([uint32]::MaxValue -shr $a.prefixlen)
            $b = [BitConverter]::GetBytes([uint32]$n); [array]::Reverse($b)
            & $add $byDev[$i.ifname] ([System.Net.IPAddress]::new($b)).ToString() 'ff:ff:ff:ff:ff:ff' 'Permanent'
        }
    }
    $rows | Where-Object {
        $r = $_
        (-not $AddressFamily -or $AddressFamily -contains $r.AddressFamily) -and
        (-not $State -or $State -contains $r.State) -and
        (-not $IPAddress -or @($IPAddress | Where-Object { $r.IPAddress -like $_ }).Count -gt 0)
    } | Sort-Object -Stable { if ($_.AddressFamily -eq 'IPv6') { 0 } else { 1 } }
}

<#
.SYNOPSIS
Emulation of the Windows cmdlet on Linux. Gets the IP configuration: addresses, gateway, DNS servers.
.EXAMPLE
Get-NetIPConfiguration
.EXAMPLE
Get-NetIPConfiguration -InterfaceAlias "Ethernet"
#>
function Get-NetIPConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][Alias('ifAlias')][string[]]$InterfaceAlias,
        [Alias('ifIndex')][uint32[]]$InterfaceIndex,
        [switch]$All,
        [switch]$Detailed
    )
    $table = @(Get-IfTable | Where-Object { $_.Dev -notmatch $script:HiddenDevs })
    $table = @(Select-If $table $InterfaceAlias)
    if ($InterfaceIndex) { $table = @($table | Where-Object { $InterfaceIndex -contains $_.Index }) }
    if ($table.Count -eq 0 -and ($InterfaceAlias -or $InterfaceIndex)) {
        $what = if ($InterfaceAlias) { "InterfaceAlias' equal to '$($InterfaceAlias -join ', ')" } else { "InterfaceIndex' equal to '$($InterfaceIndex -join ', ')" }
        Write-Error "No MSFT_NetIPInterface objects found with property '$what'. Verify the value of the property and retry."
        return
    }
    $dns = @()
    if (Test-Path /etc/resolv.conf) {
        $dns = @(Get-Content /etc/resolv.conf | Where-Object { $_ -match '^\s*nameserver\s+(\S+)' } | ForEach-Object { ($_ -split '\s+')[1] })
    }
    $v4def = @(Invoke-IpJson -4 route show default)
    $v6def = @(Invoke-IpJson -6 route show default)
    $addrs = @(Get-NetIPAddress -ErrorAction SilentlyContinue)
    foreach ($row in $table | Sort-Object Alias) {
        $v4 = @($addrs | Where-Object { $_.ifName -eq $row.Dev -and $_.AddressFamily -eq 'IPv4' })
        $v6 = @($addrs | Where-Object { $_.ifName -eq $row.Dev -and $_.AddressFamily -eq 'IPv6' -and $_.PrefixOrigin -ne 'WellKnown' })
        $ll = @($addrs | Where-Object { $_.ifName -eq $row.Dev -and $_.AddressFamily -eq 'IPv6' -and $_.SuffixOrigin -eq 'Link' })
        $flags = @($row.Link.flags)
        $status = if ($flags -notcontains 'UP') { 'Disabled' } elseif ($flags -contains 'LOWER_UP') { 'Up' } else { 'Disconnected' }
        [pscustomobject]@{
            PSTypeName           = 'NetCompat.NetIPConfiguration'
            InterfaceAlias       = $row.Alias
            InterfaceIndex       = $row.Index
            InterfaceDescription = ConvertTo-WinDescription $row.Dev
            IPv4Address          = $v4
            IPv6Address          = $v6
            IPv6LinkLocalAddress = $ll
            IPv4DefaultGateway   = @($v4def | Where-Object { $_.dev -eq $row.Dev -and $_.PSObject.Properties['gateway'] } | ForEach-Object { $_.gateway })
            IPv6DefaultGateway   = @($v6def | Where-Object { $_.dev -eq $row.Dev -and $_.PSObject.Properties['gateway'] } | ForEach-Object { $_.gateway })
            DNSServer            = $dns
            NetAdapterStatus     = $status
            Detailed             = [bool]$Detailed
        }
    }
}

#endregion

#region legacy commands students also type ------------------------------------------------------

<#
.SYNOPSIS
Windows-style ping on the simulated PC: 4 echoes by default, Windows output layout.
.DESCRIPTION
Options: -n <count>, -t (until Ctrl+C), -l <size>, -w <timeout ms>, -i <TTL>. The TTL in replies
is whatever the other device sets: 64 for the simulated PCs and routers, which are Linux.
.EXAMPLE
ping 78.1.2.4
.EXAMPLE
ping -n 10 78.1.2.4
#>
function ping {
    $count = 4; $forever = $false; $size = 32; $timeout = 4000; $ttl = 0; $target = $null
    for ($i = 0; $i -lt $args.Count; $i++) {
        $a = [string]$args[$i]
        switch -Regex ($a) {
            '^[-/]n$' { $count = [int]$args[++$i]; continue }
            '^[-/]t$' { $forever = $true; continue }
            '^[-/]l$' { $size = [int]$args[++$i]; continue }
            '^[-/]w$' { $timeout = [int]$args[++$i]; continue }
            '^[-/]i$' { $ttl = [int]$args[++$i]; continue }
            '^[-/][46aR]$' { continue }
            '^[-/]' { "Bad option $a."; return }
            default { $target = $a }
        }
    }
    if (-not $target) {
        'Usage: ping [-t] [-n count] [-l size] [-w timeout] [-i TTL] target_name'
        return
    }
    $addr = Resolve-Target $target
    if (-not $addr) { "Ping request could not find host $target. Please check the name and try again."; return }
    $label = if ($addr -eq $target) { $addr } else { "$target [$addr]" }
    ''
    "Pinging $label with $size bytes of data:"
    $sent = 0; $recv = 0; $rtts = [System.Collections.Generic.List[double]]::new()
    try {
        while ($forever -or $sent -lt $count) {
            $start = [DateTime]::UtcNow
            $r = Invoke-EchoOnce $addr $timeout $size $ttl
            $sent++
            switch ($r.Status) {
                'Success' {
                    $recv++; $rtts.Add($r.RttMs)
                    $ms = [math]::Floor($r.RttMs)
                    $t = if ($ms -lt 1) { 'time<1ms' } else { "time=$($ms)ms" }
                    "Reply from $($r.From): bytes=$size $t TTL=$($r.Ttl)"
                }
                'DestinationHostUnreachable' {
                    # Windows counts this as a received reply (it came from this PC's own stack).
                    $recv++
                    "Reply from $($r.From): Destination host unreachable."
                }
                'DestinationNetworkUnreachable' { 'PING: transmit failed. General failure.' }
                default { 'Request timed out.' }
            }
            if ($forever -or $sent -lt $count) {
                $left = 1000 - ([DateTime]::UtcNow - $start).TotalMilliseconds
                if ($left -gt 0) { Start-Sleep -Milliseconds ([int]$left) }
            }
        }
    } finally {
        $lost = $sent - $recv
        $pct = if ($sent) { [math]::Floor(100 * $lost / $sent) } else { 0 }
        $stats = @('', "Ping statistics for $($addr):", "    Packets: Sent = $sent, Received = $recv, Lost = $lost ($pct% loss),")
        if ($rtts.Count) {
            $min = [math]::Floor(($rtts | Measure-Object -Minimum).Minimum)
            $max = [math]::Floor(($rtts | Measure-Object -Maximum).Maximum)
            $avg = [math]::Floor(($rtts | Measure-Object -Average).Average)
            $stats += @('Approximate round trip times in milli-seconds:', "    Minimum = $($min)ms, Maximum = $($max)ms, Average = $($avg)ms")
        }
        # After Ctrl+C the pipeline is stopping, so write straight to the console.
        if ($forever) { $stats | ForEach-Object { [Console]::WriteLine($_) }; [Console]::WriteLine('Control-C') }
        else { $stats }
    }
}

<#
.SYNOPSIS
Windows-style ipconfig on the simulated PC (no options; use Get-NetIPConfiguration for more).
#>
function ipconfig {
    if ($args.Count -gt 0) { "On the simulated PC, ipconfig takes no options. Use Get-NetIPConfiguration -Detailed for more."; return }
    ''
    'Windows IP Configuration'
    ''
    foreach ($c in Get-NetIPConfiguration) {
        ''
        "Ethernet adapter $($c.InterfaceAlias):"
        ''
        if ($c.NetAdapterStatus -ne 'Up') {
            '   Media State . . . . . . . . . . . : Media disconnected'
            '   Connection-specific DNS Suffix  . :'
            continue
        }
        '   Connection-specific DNS Suffix  . :'
        foreach ($l in $c.IPv6LinkLocalAddress) { "   Link-local IPv6 Address . . . . . : $($l.IPAddress)" }
        foreach ($a in $c.IPv4Address) {
            "   IPv4 Address. . . . . . . . . . . : $($a.IPAddress)"
            "   Subnet Mask . . . . . . . . . . . : $(ConvertTo-Netmask $a.PrefixLength)"
        }
        $gw = @($c.IPv4DefaultGateway)
        "   Default Gateway . . . . . . . . . : $(if ($gw.Count) { $gw[0] })"
    }
}

#endregion

#region phase 2: routes, web server, tracert -----------------------------------------------------

# Parse an address into a big-endian BigInteger, for sorting routes the way Windows lists them
# (destination address descending).
function ConvertTo-AddrKey {
    param([string]$Prefix)
    $a = [System.Net.IPAddress]::Parse(($Prefix -split '/')[0])
    $b = $a.GetAddressBytes(); [array]::Reverse($b)
    [System.Numerics.BigInteger]::new([byte[]]($b + 0))
}

function ConvertTo-Network {
    param([string]$Address, [int]$PrefixLength)
    $bytes = [System.Net.IPAddress]::Parse($Address).GetAddressBytes()
    $bits = $PrefixLength
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $keep = [math]::Max(0, [math]::Min(8, $bits)); $bits -= 8
        $bytes[$i] = $bytes[$i] -band ([byte](0xFF -shl (8 - $keep) -band 0xFF))
    }
    "$([System.Net.IPAddress]::new($bytes))/$PrefixLength"
}

function ConvertTo-Broadcast {
    param([string]$Address, [int]$PrefixLength)
    $bytes = [System.Net.IPAddress]::Parse($Address).GetAddressBytes(); [array]::Reverse($bytes)
    $n = [BitConverter]::ToUInt32($bytes, 0) -bor ([uint32]::MaxValue -shr $PrefixLength)
    $b = [BitConverter]::GetBytes([uint32]$n); [array]::Reverse($b)
    [System.Net.IPAddress]::new($b).ToString()
}

# Build the route table Windows would show. Linux's main table has only the subnet and any
# default/static routes; Windows also lists, per interface, the limited broadcast, multicast, the
# subnet broadcast and the host's own /32 (IPv4), and ff00::/8 and each address's /128 (IPv6).
function Get-WinRouteTable {
    $rows = [System.Collections.Generic.List[object]]::new()
    $ifs = @(Get-IfTable | Where-Object { $_.Dev -eq 'lo' -or $_.Dev -notmatch $script:HiddenDevs })
    $addrs = @(Invoke-IpJson addr show)
    $mk = {
        param($If, [string]$Dst, [string]$Hop, [int]$Metric = 256, [string]$Proto = 'Local')
        $isLo = $If.Dev -eq 'lo'
        [pscustomobject]@{
            PSTypeName        = 'NetCompat.NetRoute'
            ifIndex           = $If.Index
            InterfaceAlias    = $If.Alias
            DestinationPrefix = $Dst
            NextHop           = $Hop
            RouteMetric       = $Metric
            ifMetric          = $(if ($isLo) { 75 } else { 25 })
            PolicyStore       = 'ActiveStore'
            AddressFamily     = $(if ($Dst -like '*:*') { 'IPv6' } else { 'IPv4' })
            Protocol          = $Proto
            ifName            = $If.Dev
        }
    }
    foreach ($if in $ifs) {
        $info = $addrs | Where-Object ifname -eq $if.Dev | Select-Object -First 1
        $ai = if ($info) { @($info.addr_info) } else { @() }
        & $mk $if '255.255.255.255/32' '0.0.0.0' | ForEach-Object { $rows.Add($_) }
        & $mk $if '224.0.0.0/4' '0.0.0.0' | ForEach-Object { $rows.Add($_) }
        foreach ($a in $ai | Where-Object family -eq 'inet') {
            if ($a.prefixlen -lt 31) { $rows.Add((& $mk $if "$(ConvertTo-Broadcast $a.local $a.prefixlen)/32" '0.0.0.0')) }
            $rows.Add((& $mk $if "$($a.local)/32" '0.0.0.0'))
            $rows.Add((& $mk $if (ConvertTo-Network $a.local $a.prefixlen) '0.0.0.0'))
        }
        $rows.Add((& $mk $if 'ff00::/8' '::'))
        foreach ($a in $ai | Where-Object family -eq 'inet6') {
            $rows.Add((& $mk $if "$($a.local)/128" '::'))
            if ($a.local -like 'fe80:*') { $rows.Add((& $mk $if 'fe80::/64' '::')) }
            elseif ($a.prefixlen -lt 128) { $rows.Add((& $mk $if (ConvertTo-Network $a.local $a.prefixlen) '::')) }
        }
    }
    $byDev = @{}; foreach ($if in $ifs) { $byDev[$if.Dev] = $if }
    foreach ($fam in '-4', '-6') {
        foreach ($r in Invoke-IpJson $fam route show) {
            if (-not $r.PSObject.Properties['gateway'] -and $r.dst -ne 'default' -and
                -not ($r.PSObject.Properties['protocol'] -and $r.protocol -eq 'static')) { continue }  # connected: done above
            if (-not $byDev.ContainsKey($r.dev)) { continue }
            $dst = if ($r.dst -eq 'default') { if ($fam -eq '-4') { '0.0.0.0/0' } else { '::/0' } }
                   elseif ($r.dst -notlike '*/*') { if ($fam -eq '-4') { "$($r.dst)/32" } else { "$($r.dst)/128" } }
                   else { $r.dst }
            $hop = if ($r.PSObject.Properties['gateway']) { $r.gateway } elseif ($fam -eq '-4') { '0.0.0.0' } else { '::' }
            $met = if ($r.PSObject.Properties['metric'] -and $r.metric -gt 0) { [int]$r.metric } else { 256 }
            $rows.Add((& $mk $byDev[$r.dev] $dst $hop $met 'NetMgmt'))
        }
    }
    # Windows order: IPv4 then IPv6; destination descending; then interface metric, then index.
    $rows | Sort-Object @{ Expression = { $_.AddressFamily -eq 'IPv6' } },
                        @{ Expression = { ConvertTo-AddrKey $_.DestinationPrefix }; Descending = $true },
                        @{ Expression = { [int]($_.DestinationPrefix -split '/')[1] }; Descending = $true },
                        ifMetric, ifIndex
}

<#
.SYNOPSIS
Emulation of the Windows cmdlet on Linux. Gets the IP route table.
.EXAMPLE
Get-NetRoute -AddressFamily IPv4
.EXAMPLE
Get-NetRoute -InterfaceIndex 12
#>
function Get-NetRoute {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string[]]$DestinationPrefix,
        [Alias('ifAlias')][string[]]$InterfaceAlias,
        [Alias('ifIndex')][uint32[]]$InterfaceIndex,
        [string[]]$NextHop,
        [ValidateSet('IPv4', 'IPv6')][string[]]$AddressFamily
    )
    $rows = @(Get-WinRouteTable | Where-Object {
        $r = $_
        (-not $InterfaceAlias -or @($InterfaceAlias | Where-Object { $r.InterfaceAlias -like $_ -or $r.ifName -like $_ }).Count) -and
        (-not $InterfaceIndex -or $InterfaceIndex -contains $r.ifIndex) -and
        (-not $AddressFamily -or $AddressFamily -contains $r.AddressFamily) -and
        (-not $DestinationPrefix -or @($DestinationPrefix | Where-Object { $r.DestinationPrefix -like $_ }).Count) -and
        (-not $NextHop -or $NextHop -contains $r.NextHop)
    })
    if ($rows.Count -eq 0 -and ($DestinationPrefix -or $InterfaceAlias -or $InterfaceIndex -or $NextHop)) {
        Write-Error 'No matching MSFT_NetRoute objects found by CIM query for instances of the ROOT/StandardCimv2/MSFT_NetRoute class on the  CIM server: SELECT * FROM MSFT_NetRoute. Verify query parameters and retry.'
        return
    }
    $rows
}

<#
.SYNOPSIS
Emulation of the Windows cmdlet on Linux. Adds a route to the route table.
.DESCRIPTION
The route is applied at once and kept across restarts (written to /etc/network/interfaces).
-NextHop 0.0.0.0 means the destination is directly connected on that interface.
.EXAMPLE
New-NetRoute -DestinationPrefix 0.0.0.0/0 -InterfaceAlias "Ethernet" -NextHop 78.1.1.1
.EXAMPLE
New-NetRoute -DestinationPrefix 78.1.2.0/24 -InterfaceAlias "Ethernet" -NextHop 78.1.1.1
#>
function New-NetRoute {
    [CmdletBinding(DefaultParameterSetName = 'ByAlias')]
    param(
        [Parameter(Mandatory, Position = 0)][string]$DestinationPrefix,
        [Parameter(ParameterSetName = 'ByAlias', Mandatory)][Alias('ifAlias')][string]$InterfaceAlias,
        [Parameter(ParameterSetName = 'ByIndex', Mandatory)][Alias('ifIndex')][uint32]$InterfaceIndex,
        [string]$NextHop,
        [ValidateRange(0, 9999)][int]$RouteMetric = 256,
        [ValidateSet('ActiveStore', 'PersistentStore')][string]$PolicyStore
    )
    $parts = $DestinationPrefix -split '/'
    $ip = $null
    if ($parts.Count -ne 2 -or -not [System.Net.IPAddress]::TryParse($parts[0], [ref]$ip) -or $parts[1] -notmatch '^\d+$') {
        Stop-NetCompat $PSCmdlet "The DestinationPrefix `"$DestinationPrefix`" is not valid. Use an address and prefix length, for example 78.1.2.0/24."
    }
    $isV6 = $ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6
    $len = [int]$parts[1]
    $norm = ConvertTo-Network $parts[0] $len
    if ($norm -ne "$($ip)/$len") {
        Stop-NetCompat $PSCmdlet "The DestinationPrefix `"$DestinationPrefix`" has host bits set. Did you mean $($norm)?"
    }
    try { $if = Resolve-OneIf -InterfaceAlias $InterfaceAlias -InterfaceIndex $InterfaceIndex }
    catch { Stop-NetCompat $PSCmdlet $_.Exception.Message 'ObjectNotFound' }
    $onLink = -not $NextHop -or $NextHop -in '0.0.0.0', '::'
    $hopShown = if ($onLink) { if ($isV6) { '::' } else { '0.0.0.0' } } else { $NextHop }
    if (@(Get-WinRouteTable | Where-Object { $_.DestinationPrefix -eq $norm -and $_.NextHop -eq $hopShown -and $_.ifName -eq $if.Dev }).Count) {
        Stop-NetCompat $PSCmdlet 'Instance MSFT_NetRoute already exists'
    }
    $dst = if ($len -eq 0) { 'default' } else { $norm }
    $via = if ($onLink) { @() } else { @('via', $NextHop) }
    $fam = if ($isV6) { '-6' } else { '-4' }
    $out = & ip $fam route add $dst @via dev $if.Dev proto static metric $RouteMetric 2>&1
    if ($LASTEXITCODE -ne 0) {
        if ("$out" -match 'Nexthop has invalid gateway|Network is unreachable') {
            Stop-NetCompat $PSCmdlet "The next hop $NextHop is not on a network connected to $($if.Alias)."
        }
        Stop-NetCompat $PSCmdlet "Could not add the route: $out"
    }
    Save-NetConfig
    foreach ($store in 'ActiveStore', 'PersistentStore') {
        $o = Get-WinRouteTable | Where-Object { $_.DestinationPrefix -eq $norm -and $_.ifName -eq $if.Dev -and $_.NextHop -eq $hopShown } | Select-Object -First 1
        if ($o) { $o.PolicyStore = $store; $o }
    }
}

<#
.SYNOPSIS
Emulation of the Windows cmdlet on Linux. Changes a route's metric.
.EXAMPLE
Set-NetRoute -DestinationPrefix 78.1.2.0/24 -InterfaceAlias "Ethernet" -RouteMetric 10
#>
function Set-NetRoute {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0, ValueFromPipelineByPropertyName)][string[]]$DestinationPrefix,
        [Parameter(ValueFromPipelineByPropertyName)][Alias('ifAlias')][string[]]$InterfaceAlias,
        [Parameter(ValueFromPipelineByPropertyName)][Alias('ifIndex')][uint32[]]$InterfaceIndex,
        [Parameter(ValueFromPipelineByPropertyName)][string[]]$NextHop,
        [Parameter(Mandatory)][ValidateRange(0, 9999)][int]$RouteMetric
    )
    process {
        $get = @{}
        foreach ($k in 'DestinationPrefix', 'InterfaceAlias', 'InterfaceIndex', 'NextHop') {
            if ($PSBoundParameters.ContainsKey($k)) { $get[$k] = $PSBoundParameters[$k] }
        }
        $targets = @(Get-NetRoute @get -ErrorAction SilentlyContinue | Where-Object Protocol -eq 'NetMgmt')
        if ($targets.Count -eq 0) {
            Write-Error 'No matching MSFT_NetRoute objects found by CIM query for instances of the ROOT/StandardCimv2/MSFT_NetRoute class on the  CIM server: SELECT * FROM MSFT_NetRoute. Verify query parameters and retry.'
            return
        }
        foreach ($t in $targets) {
            if (-not $PSCmdlet.ShouldProcess("NetRoute -DestinationPrefix $($t.DestinationPrefix) -InterfaceIndex $($t.ifIndex) -NextHop $($t.NextHop)", 'Set')) { continue }
            $fam = if ($t.AddressFamily -eq 'IPv6') { '-6' } else { '-4' }
            $dst = if ($t.DestinationPrefix -in '0.0.0.0/0', '::/0') { 'default' } else { $t.DestinationPrefix }
            $via = if ($t.NextHop -in '0.0.0.0', '::') { @() } else { @('via', $t.NextHop) }
            & ip $fam route del $dst @via dev $t.ifName 2>$null
            & ip $fam route add $dst @via dev $t.ifName proto static metric $RouteMetric 2>&1 | Out-Null
        }
        Save-NetConfig
    }
}

<#
.SYNOPSIS
Emulation of the Windows cmdlet on Linux. Removes a route from the route table.
.EXAMPLE
Remove-NetRoute -DestinationPrefix 78.1.2.0/24 -InterfaceAlias "Ethernet"
#>
function Remove-NetRoute {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Position = 0, ValueFromPipelineByPropertyName)][string[]]$DestinationPrefix,
        [Parameter(ValueFromPipelineByPropertyName)][Alias('ifAlias')][string[]]$InterfaceAlias,
        [Parameter(ValueFromPipelineByPropertyName)][Alias('ifIndex')][uint32[]]$InterfaceIndex,
        [Parameter(ValueFromPipelineByPropertyName)][string[]]$NextHop
    )
    begin {
        $changed = $false
        $dropR = [System.Collections.Generic.List[object]]::new()
        $keepR = [System.Collections.Generic.List[object]]::new()
    }
    process {
        if (-not ($DestinationPrefix -or $InterfaceAlias -or $InterfaceIndex -or $NextHop)) {
            Stop-NetCompat $PSCmdlet 'On the simulated PC, give -DestinationPrefix (and -InterfaceAlias or -NextHop) so only the intended route is removed.'
        }
        $get = @{}
        foreach ($k in 'DestinationPrefix', 'InterfaceAlias', 'InterfaceIndex', 'NextHop') {
            if ($PSBoundParameters.ContainsKey($k)) { $get[$k] = $PSBoundParameters[$k] }
        }
        $all = @(Get-NetRoute @get -ErrorAction SilentlyContinue)
        $targets = @($all | Where-Object Protocol -eq 'NetMgmt')
        if ($targets.Count -eq 0) {
            if ($all.Count) { Stop-NetCompat $PSCmdlet 'On the simulated PC, only routes added with New-NetRoute or a default gateway can be removed; the others belong to an IP address. Remove the address instead.' }
            Write-Error 'No matching MSFT_NetRoute objects found by CIM query for instances of the ROOT/StandardCimv2/MSFT_NetRoute class on the  CIM server: SELECT * FROM MSFT_NetRoute. Verify query parameters and retry.'
            return
        }
        foreach ($t in $targets) {
            $removedActive = $false
            $rec = [pscustomobject]@{ Dst = $t.DestinationPrefix; Gw = $(if ($t.NextHop -in '0.0.0.0', '::') { '' } else { $t.NextHop }); Dev = $t.ifName; Metric = $t.RouteMetric }
            foreach ($store in 'Active', 'Persistent') {
                $desc = "NetRoute -DestinationPrefix $($t.DestinationPrefix) -InterfaceIndex $($t.ifIndex) -NextHop $($t.NextHop) -Store $store"
                $ok = $PSCmdlet.ShouldProcess("Remove $desc",
                    "Are you sure you want to perform this action?`nPerforming operation `"Remove`" on Target `"$desc`"", 'Confirm')
                if ($store -eq 'Active') {
                    if (-not $ok) { continue }
                    $fam = if ($t.AddressFamily -eq 'IPv6') { '-6' } else { '-4' }
                    $dst = if ($t.DestinationPrefix -in '0.0.0.0/0', '::/0') { 'default' } else { $t.DestinationPrefix }
                    $via = if ($rec.Gw) { @('via', $rec.Gw) } else { @() }
                    & ip $fam route del $dst @via dev $t.ifName 2>&1 | Out-Null
                    $removedActive = $true; $changed = $true
                } elseif ($ok) { $dropR.Add($rec); $changed = $true }
                elseif ($removedActive) { $keepR.Add($rec) }
            }
        }
    }
    end { if ($changed) { Save-NetConfig -DropRoute $dropR -KeepRoute $keepR } }
}

# --- the web server: IIS's service name, backed by nginx ------------------------------------------

$script:WebRoot = '/var/www/html'

function Get-W3svcObject {
    $running = [bool](& pgrep -x nginx 2>$null)
    [pscustomobject]@{
        PSTypeName  = 'NetCompat.Service'
        Status      = $(if ($running) { 'Running' } else { 'Stopped' })
        Name        = 'W3SVC'
        DisplayName = 'World Wide Web Publishing Service'
    }
}

function Assert-W3svcName {
    param($Cmdlet, [string[]]$Name)
    foreach ($n in $Name) {
        if ($n -notlike 'W3SVC' -and 'W3SVC' -notlike $n) {
            Stop-NetCompat $Cmdlet "Cannot find any service with service name '$n'. The simulated PC has one service, W3SVC (the web server)." 'ObjectNotFound'
        }
    }
}

<#
.SYNOPSIS
Simulated PC: shows the web server service (W3SVC). Web pages go in /var/www/html.
.EXAMPLE
Get-Service W3SVC
#>
function Get-Service {
    [CmdletBinding()]
    param([Parameter(Position = 0)][Alias('ServiceName')][string[]]$Name = @('*'))
    Assert-W3svcName $PSCmdlet $Name
    Get-W3svcObject
}

<#
.SYNOPSIS
Simulated PC: starts the web server (W3SVC). It serves the files in /var/www/html on port 80.
.EXAMPLE
Start-Service W3SVC
#>
function Start-Service {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][Alias('ServiceName')][string[]]$Name, [switch]$PassThru)
    Assert-W3svcName $PSCmdlet $Name
    if (-not (Test-Path $script:WebRoot)) { New-Item -ItemType Directory -Path $script:WebRoot -Force | Out-Null }
    if (-not (Get-ChildItem $script:WebRoot -Filter 'index.*' -ErrorAction SilentlyContinue)) {
        $h = [System.Net.Dns]::GetHostName()
        Set-Content -Path (Join-Path $script:WebRoot 'index.html') -Value "<!DOCTYPE html>`n<html><head><title>$h</title></head><body><h1>Web server on $h</h1><p>Put your pages in $script:WebRoot</p></body></html>"
    }
    if ((Get-W3svcObject).Status -ne 'Running') {
        $out = & nginx 2>&1
        if ($LASTEXITCODE -ne 0) { Stop-NetCompat $PSCmdlet "Service 'World Wide Web Publishing Service (W3SVC)' cannot be started: $out" 'OpenError' }
    }
    if ($PassThru) { Get-W3svcObject }
}

<#
.SYNOPSIS
Simulated PC: stops the web server (W3SVC).
#>
function Stop-Service {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][Alias('ServiceName')][string[]]$Name, [switch]$PassThru, [switch]$Force)
    Assert-W3svcName $PSCmdlet $Name
    if ((Get-W3svcObject).Status -eq 'Running') { & nginx -s stop 2>&1 | Out-Null; Start-Sleep -Milliseconds 300 }
    if ($PassThru) { Get-W3svcObject }
}

<#
.SYNOPSIS
Simulated PC: restarts the web server (W3SVC).
#>
function Restart-Service {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][Alias('ServiceName')][string[]]$Name, [switch]$PassThru, [switch]$Force)
    Stop-Service -Name $Name
    Start-Service -Name $Name -PassThru:$PassThru
}

# --- tracert / Test-NetConnection -TraceRoute ----------------------------------------------------

# Probe hop by hop with ICMP echo and a rising TTL, as Windows tracert does. .NET's Ping reports
# TtlExpired with the router's address on Linux (measured in Phase 2).
function Invoke-TraceHops {
    param([string]$Address, [int]$MaxHops = 30, [int]$TimeoutMs = 4000, [int]$Probes = 3, [scriptblock]$OnHop)
    $p = [System.Net.NetworkInformation.Ping]::new()
    $buf = [byte[]]::new(32)
    try {
        for ($ttl = 1; $ttl -le $MaxHops; $ttl++) {
            $times = @(); $from = $null; $done = $false
            for ($i = 0; $i -lt $Probes; $i++) {
                $r = $null
                try { $r = $p.Send($Address, $TimeoutMs, $buf, [System.Net.NetworkInformation.PingOptions]::new($ttl, $true)) } catch { }
                if ($r -and $r.Status -in 'Success', 'TtlExpired', 'TimeExceeded') {
                    $times += [long]$r.RoundtripTime
                    if (-not $from) { $from = $r.Address.ToString() }
                    if ($r.Status -eq 'Success') { $done = $true }
                } else { $times += $null }
            }
            & $OnHop $ttl $times $from      # whatever OnHop outputs flows to the caller as it happens
            if ($done) { return }
        }
    } finally { $p.Dispose() }
}

<#
.SYNOPSIS
Windows-style tracert on the simulated PC.
.EXAMPLE
tracert 78.1.2.10
#>
function tracert {
    $max = 30; $timeout = 4000; $target = $null
    for ($i = 0; $i -lt $args.Count; $i++) {
        $a = [string]$args[$i]
        switch -Regex ($a) {
            '^[-/]h$' { $max = [int]$args[++$i]; continue }
            '^[-/]w$' { $timeout = [int]$args[++$i]; continue }
            '^[-/][d46]$' { continue }
            '^[-/]' { "Bad option $a."; return }
            default { $target = $a }
        }
    }
    if (-not $target) { 'Usage: tracert [-d] [-h maximum_hops] [-w timeout] target_name'; return }
    $addr = Resolve-Target $target
    if (-not $addr) { "Unable to resolve target system name $target."; return }
    $label = if ($addr -eq $target) { $addr } else { "$target [$addr]" }
    ''
    "Tracing route to $label"
    "over a maximum of $max hops:"
    ''
    $fmt = { param($t) if ($null -eq $t) { '    *   ' } elseif ($t -lt 1) { '   <1 ms' } else { '{0,5} ms' -f $t } }
    Invoke-TraceHops $addr $max $timeout 3 {
        param($ttl, $times, $from)
        $cols = ($times | ForEach-Object { & $fmt $_ }) -join ' '
        $tail = if ($from) { $from } else { 'Request timed out.' }
        '{0,3} {1}  {2}' -f $ttl, $cols, $tail
    }
    ''
    'Trace complete.'
}

#endregion
