# Self-test for the NetCompat module, run INSIDE a PC node that is linked to a second PC.
# Not shipped in the image: copy it in, then
#   pwsh -NoLogo -File NetCompat.SelfTest.ps1 -Self 78.1.2.3 -Peer 78.1.2.4 -Unused 78.1.2.99
# The peer must already have its address and answer ping. This node's eth0 must have no IPv4
# address yet (the test adds and removes -Self). Prints PASS/FAIL lines; exit code = failures.
# Plain asserts rather than Pester: Pester is not bundled with PowerShell 7 and nodes are offline.
param(
    [Parameter(Mandatory)][string]$Self,
    [Parameter(Mandatory)][string]$Peer,
    [Parameter(Mandatory)][string]$Unused,
    [int]$PrefixLength = 24,
    [string]$Gateway = ''
)
$ErrorActionPreference = 'Continue'
$PSStyle.OutputRendering = 'PlainText'
Import-Module NetCompat -Force
$script:fail = 0

function Check([string]$Name, [scriptblock]$Test) {
    try { $ok = [bool](& $Test) } catch { $ok = $false; $Name += "  [threw: $($_.Exception.Message)]" }
    if ($ok) { "PASS  $Name" } else { "FAIL  $Name"; $script:fail++ }
}
# Everything a student would see, including warnings and terminating errors. A captured warning
# loses its "WARNING: " prefix (the console adds it), so patterns below do not require it.
function Text([scriptblock]$Block) {
    # A caught error is rendered as the prompt shows it ("New-NetIPAddress: message"); inside a
    # script, PowerShell's error view would add the source line and wrap at 80 columns.
    try { (& $Block 2>&1 3>&1 | Out-String -Width 200) } catch { "$($_.InvocationInfo.MyCommand): $($_.Exception.Message)" }
}

# --- adapter -----------------------------------------------------------------------------------
$ad = @(Get-NetAdapter)
Check 'Get-NetAdapter lists Ethernet, Up' { $ad.Count -ge 1 -and $ad[0].Name -eq 'Ethernet' -and $ad[0].Status -eq 'Up' }
Check 'LinkSpeed 10 Gbps, MAC with dashes' { $ad[0].LinkSpeed -eq '10 Gbps' -and $ad[0].MacAddress -match '^([0-9A-F]{2}-){5}[0-9A-F]{2}$' }
Check 'Get-NetAdapter -Name eth0 finds Ethernet' { (Get-NetAdapter -Name eth0).Name -eq 'Ethernet' }
Check 'Get-NetAdapter unknown name errors' { (Text { Get-NetAdapter -Name 'Wi-Fi' }) -match "No MSFT_NetAdapter objects found with property 'Name' equal to 'Wi-Fi'" }
Check 'Get-NetAdapter table header' { (Text { Get-NetAdapter }) -match 'Name\s+InterfaceDescription\s+ifIndex\s+Status\s+MacAddress\s+LinkSpeed' }

# --- addressing --------------------------------------------------------------------------------
$newArgs = @{ InterfaceAlias = 'Ethernet'; IPAddress = $Self; PrefixLength = $PrefixLength }
if ($Gateway) { $newArgs.DefaultGateway = $Gateway }
$new = @(New-NetIPAddress @newArgs)
Check 'New-NetIPAddress returns ActiveStore/Tentative + PersistentStore/Invalid' {
    $new.Count -eq 2 -and $new[0].PolicyStore -eq 'ActiveStore' -and $new[0].AddressState -eq 'Tentative' -and
    $new[1].PolicyStore -eq 'PersistentStore' -and $new[1].AddressState -eq 'Invalid' }
Check 'duplicate New-NetIPAddress: Windows message' { (Text { New-NetIPAddress @newArgs }) -match 'New-NetIPAddress: Instance MSFT_NetIPAddress already exists' }
Check 'bad alias: Windows message' { (Text { New-NetIPAddress -InterfaceAlias 'Ethernet 9' -IPAddress 10.9.9.9 -PrefixLength 24 }) -match "No MSFT_NetIPInterface objects found with property 'InterfaceAlias' equal to 'Ethernet 9'" }
Check 'persisted in /etc/network/interfaces' { (Get-Content /etc/network/interfaces -Raw) -match "address $([regex]::Escape($Self))" }
$ips = @(Get-NetIPAddress -InterfaceAlias Ethernet)
Check 'Get-NetIPAddress: IPv6 first, zone on link-local' { $ips[0].AddressFamily -eq 'IPv6' -and $ips[0].IPAddress -match '^fe80::.*%\d+$' }
Check 'Get-NetIPAddress -AddressFamily IPv4 finds Self, Manual' {
    $a = Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias Ethernet; $a.IPAddress -eq $Self -and $a.PrefixOrigin -eq 'Manual' }

# --- configuration -----------------------------------------------------------------------------
$cfg = Get-NetIPConfiguration -InterfaceAlias Ethernet
Check 'Get-NetIPConfiguration IPv4Address' { @($cfg.IPv4Address)[0].IPAddress -eq $Self }
Check 'Get-NetIPConfiguration layout' { (Text { Get-NetIPConfiguration }) -match '(?s)InterfaceAlias\s+: Ethernet.*InterfaceIndex.*InterfaceDescription.*IPv4Address\s+: ' + [regex]::Escape($Self) + '.*IPv4DefaultGateway.*DNSServer' }
if ($Gateway) { Check 'Get-NetIPConfiguration gateway' { @($cfg.IPv4DefaultGateway)[0] -eq $Gateway } }
Check 'ipconfig layout' { (Text { ipconfig }) -match '(?s)Windows IP Configuration.*Ethernet adapter Ethernet:.*IPv4 Address\. .*: ' + [regex]::Escape($Self) + '.*Subnet Mask .*: 255\.' }

# --- testing -----------------------------------------------------------------------------------
$t = Test-NetConnection $Peer
Check 'Test-NetConnection peer: PingSucceeded' { $t.PingSucceeded -and $t.InterfaceAlias -eq 'Ethernet' -and $t.SourceAddress -eq $Self }
Check 'Test-NetConnection layout' { (Text { Test-NetConnection $Peer }) -match '(?s)ComputerName\s+: .*RemoteAddress.*InterfaceAlias.*SourceAddress.*PingSucceeded\s+: True.*PingReplyDetails \(RTT\) : \d+ ms' }
Check 'Test-NetConnection unused: warning + False' {
    $o = Text { Test-NetConnection $Unused }; $o -match "Ping to $([regex]::Escape($Unused)) failed with status: \w+" -and $o -match 'PingSucceeded\s+: False' }
Check 'Test-NetConnection -InformationLevel Quiet' { (Test-NetConnection $Peer -InformationLevel Quiet) -eq $true }
$l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse($Self), 8089); $l.Start()
try { Check 'Test-NetConnection -Port open: TcpTestSucceeded' { (Test-NetConnection $Self -Port 8089).TcpTestSucceeded } }
finally { $l.Stop() }
Check 'Test-NetConnection -Port closed: warning + False' {
    $o = Text { Test-NetConnection $Peer -Port 8090 }; $o -match 'TCP connect to \(.* : 8090\) failed' -and $o -match 'TcpTestSucceeded\s+: False' }

$p = Text { ping -n 2 $Peer }
Check 'ping -n 2: Windows layout' { $p -match "Pinging $([regex]::Escape($Peer)) with 32 bytes of data:" -and ([regex]::Matches($p, 'Reply from .*: bytes=32 time[<=]\d+ms TTL=\d+')).Count -eq 2 -and $p -match 'Packets: Sent = 2, Received = 2, Lost = 0 \(0% loss\)' -and $p -match 'Minimum = \d+ms, Maximum = \d+ms, Average = \d+ms' }
$p = Text { ping -n 1 -w 1000 $Unused }
Check 'ping unused: unreachable or timed out, counted' { ($p -match 'Request timed out\.|Destination host unreachable\.') -and $p -match 'Sent = 1' }
Check 'ping no target: usage' { (Text { ping }) -match '^Usage: ping' }

$nb = @(Get-NetNeighbor -AddressFamily IPv4)
Check 'Get-NetNeighbor has the peer' { @($nb | Where-Object { $_.IPAddress -eq $Peer -and $_.LinkLayerAddress -match '^([0-9A-F]{2}-){5}' }).Count -eq 1 }
Check 'Get-NetNeighbor has subnet broadcast, Permanent' { @($nb | Where-Object { $_.LinkLayerAddress -eq 'FF-FF-FF-FF-FF-FF' -and $_.State -eq 'Permanent' }).Count -ge 1 }
Check 'Get-NetNeighbor -State Permanent filters' { @(Get-NetNeighbor -State Permanent | Where-Object State -ne 'Permanent').Count -eq 0 }

# --- routes (Phase 2) ----------------------------------------------------------------------------
$idx = (Get-NetAdapter -Name Ethernet).ifIndex
$rt = @(Get-NetRoute -InterfaceIndex $idx -AddressFamily IPv4)
$net = (Get-NetIPConfiguration -InterfaceAlias Ethernet).IPv4Address[0]
$expect = @('255.255.255.255/32', '224.0.0.0/4', "$Self/32")
Check 'Get-NetRoute has the Windows rows (broadcasts, multicast, host /32, subnet)' {
    $d = $rt.DestinationPrefix
    @($expect | Where-Object { $d -notcontains $_ }).Count -eq 0 -and @($d | Where-Object { $_ -like "*/$PrefixLength" }).Count -ge 1 -and
    @($rt | Where-Object { $_.RouteMetric -ne 256 -or $_.ifMetric -ne 25 -or $_.NextHop -ne '0.0.0.0' -and $_.DestinationPrefix -ne '0.0.0.0/0' }).Count -eq 0 }
Check 'Get-NetRoute order: 255.255.255.255 first' { $rt[0].DestinationPrefix -eq '255.255.255.255/32' }
Check 'Get-NetRoute loopback rows ifMetric 75' { @(Get-NetRoute -InterfaceIndex 1 | Where-Object ifMetric -ne 75).Count -eq 0 }
Check 'Get-NetRoute table header' { (Text { Get-NetRoute }) -match 'ifIndex DestinationPrefix\s+NextHop\s+RouteMetric ifMetric PolicyStore' }
$nr = @(New-NetRoute -DestinationPrefix 10.99.0.0/16 -InterfaceAlias Ethernet -NextHop $Peer)
Check 'New-NetRoute returns ActiveStore + PersistentStore' { $nr.Count -eq 2 -and $nr[1].PolicyStore -eq 'PersistentStore' }
Check 'New-NetRoute duplicate: Windows message' { (Text { New-NetRoute -DestinationPrefix 10.99.0.0/16 -InterfaceAlias Ethernet -NextHop $Peer }) -match 'Instance MSFT_NetRoute already exists' }
Check 'New-NetRoute host bits: helpful message' { (Text { New-NetRoute -DestinationPrefix 10.99.1.0/8 -InterfaceAlias Ethernet -NextHop $Peer }) -match 'Did you mean 10\.0\.0\.0/8' }
Check 'New-NetRoute persisted' { (Get-Content /etc/network/interfaces -Raw) -match 'up ip route add 10\.99\.0\.0/16 via' }
Set-NetRoute -DestinationPrefix 10.99.0.0/16 -RouteMetric 10
Check 'Set-NetRoute changes the metric' { (Get-NetRoute -DestinationPrefix 10.99.0.0/16).RouteMetric -eq 10 }
Get-NetRoute -DestinationPrefix 10.99.0.0/16 | Remove-NetRoute -Confirm:$false
Check 'Remove-NetRoute (pipeline) removes and unpersists' {
    -not (Get-NetRoute -DestinationPrefix 10.99.0.0/16 -ErrorAction SilentlyContinue) -and (Get-Content /etc/network/interfaces -Raw) -notmatch '10\.99\.0\.0' }
Check 'Remove-NetRoute on a connected route explains' { (Text { Remove-NetRoute -DestinationPrefix "$Self/32" -Confirm:$false }) -match 'Remove the address instead' }

# --- web server and tracert (Phase 2) -------------------------------------------------------------
Stop-Service W3SVC
Check 'Get-Service W3SVC Stopped' { (Get-Service W3SVC).Status -eq 'Stopped' }
Start-Service W3SVC
Check 'Start-Service W3SVC: Running, port 80 answers' { (Get-Service W3SVC).Status -eq 'Running' -and (Test-NetConnection $Self -Port 80).TcpTestSucceeded }
Check 'default page names the PC' { (Invoke-WebRequest "http://$Self/" -UseBasicParsing).Content -match [System.Net.Dns]::GetHostName() }
Stop-Service W3SVC
Check 'Stop-Service W3SVC' { (Get-Service W3SVC).Status -eq 'Stopped' }
Check 'unknown service: clear message' { (Text { Start-Service Spooler }) -match "Cannot find any service with service name 'Spooler'" }
$tr = Text { tracert $Peer }
Check 'tracert to peer: one hop, Trace complete' { $tr -match "Tracing route to $([regex]::Escape($Peer))" -and $tr -match "\s1\s+(<1 ms|\d+ ms).*$([regex]::Escape($Peer))" -and $tr -match 'Trace complete\.' }
Check 'Test-NetConnection -TraceRoute' { @((Test-NetConnection $Peer -TraceRoute).TraceRoute)[-1] -eq $Peer }

# --- removal -----------------------------------------------------------------------------------
Get-NetIPAddress -IPAddress $Self | Remove-NetIPAddress -Confirm:$false   # the pipeline idiom
Check 'Remove-NetIPAddress removes live address' { -not (Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias Ethernet -ErrorAction SilentlyContinue) }
Check 'Remove-NetIPAddress clears persisted block' { (Get-Content /etc/network/interfaces -Raw) -notmatch "address $([regex]::Escape($Self))" }

"---"
"$script:fail failure(s)"
exit $script:fail
