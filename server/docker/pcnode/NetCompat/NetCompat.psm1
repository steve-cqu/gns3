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
function Save-NetConfig {
    param([string[]]$Drop = @(), [object[]]$Keep = @())
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
        $gw = @($defaults | Where-Object { $_.dev -eq $i.ifname -and $_.PSObject.Properties['gateway'] })
        if ($gw.Count -gt 0) { $lines.Add("    gateway $($gw[0].gateway)") }
        foreach ($a in $addrs | Select-Object -Skip 1) {
            $lines.Add("    up ip addr add $($a.local)/$($a.prefixlen) dev $($i.ifname)")
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

    $out = & ip addr add "$($ip)/$PrefixLength" dev $if.Dev 2>&1
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
        [Parameter(Position = 0)][string[]]$IPAddress,
        [Alias('ifAlias')][string[]]$InterfaceAlias,
        [Alias('ifIndex')][uint32[]]$InterfaceIndex,
        [ValidateSet('IPv4', 'IPv6')][string[]]$AddressFamily,
        [string]$DefaultGateway
    )
    if (-not ($IPAddress -or $InterfaceAlias -or $InterfaceIndex)) {
        Stop-NetCompat $PSCmdlet 'On the simulated PC, give -IPAddress and/or -InterfaceAlias so only the intended address is removed.'
    }
    $get = @{}
    foreach ($k in 'IPAddress', 'InterfaceAlias', 'InterfaceIndex', 'AddressFamily') {
        if ($PSBoundParameters.ContainsKey($k)) { $get[$k] = $PSBoundParameters[$k] }
    }
    $targets = @(Get-NetIPAddress @get -ErrorAction SilentlyContinue | Where-Object { $_.PrefixOrigin -ne 'WellKnown' })
    if ($targets.Count -eq 0) {
        Write-Error 'No matching MSFT_NetIPAddress objects found by CIM query for instances of the ROOT/StandardCimv2/MSFT_NetIPAddress class on the  CIM server: SELECT * FROM MSFT_NetIPAddress. Verify query parameters and retry.'
        return
    }
    # Windows confirms once per store, Active then Persistent, with this wording:
    #   Performing operation "Remove" on Target "NetIPAddress -IPv4Address 49.1.1.20 -InterfaceIndex 12 -Store Active"
    $changed = $false
    $drop = [System.Collections.Generic.List[string]]::new()
    $keep = [System.Collections.Generic.List[object]]::new()
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
    if ($changed) { Save-NetConfig -Drop $drop -Keep $keep }
}
