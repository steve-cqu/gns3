# How the Labs Simulate What GNS3 Cannot Do

This page is for educators who design or teach labs on this appliance. It explains, technique by
technique, how the appliance stands in for things a lab cannot have: radios, slow links, real
users, a working day, other people's clouds, Windows, the internet. For each one it says what the
student sees, how it is done, what is real and what is not, and the trap to know before writing a
lab around it.

Lab names in `code`, such as `link-performance`, are the activities written for the appliance,
which are also the practical labs of the book *Networking, Security and Cryptography*. The
activities themselves are not in this repository (see the [README](../README.md)).

Every node on the appliance is a **container on one shared virtual machine**. They share one
kernel and one clock. There is no radio hardware, no wide-area network, no internet unless a
project adds it, and nobody logs in but the student. So the labs follow one rule throughout:
**real protocols, simulated surroundings.** What the student configures is the real software
(hostapd, `tc`, Prometheus, rsyslog, WireGuard, nftables), and only the world around it is faked.
Wherever something is simulated, the lab says so, and generated events are labelled as simulated
in the data itself.

## 1. Wireless

**What the student sees.** An *Access Point* and a *Station* node on the canvas with no link
between them. After one command on the VM host, each has a `wlan0`, the station associates to the
access point with WPA2 or WPA3, and the student can capture the four-way handshake.

**How it is done.** The radios are the Linux `mac80211_hwsim` kernel module on the VM: virtual
802.11 radios that exchange frames in memory. A node is a container in its own network namespace
and cannot see them, so after the project starts, `gns3-wifi-attach` (run on the VM host, not in a
node) moves one radio into each wireless node. It is safe to run again and skips nodes that already
have one. When the project closes, the radios return to the pool by themselves. SSID, channel,
band and security are ordinary hostapd and wpa_supplicant settings in the node's config files,
exactly as on real hardware.

**What is real and what is not.** The 802.11 state machines are real: association, WPA2-PSK,
WPA3-SAE with protected management frames, WPA2-Enterprise with EAP, client isolation, monitor mode,
and a rogue access point with the same SSID (the evil-twin lab). The radio physics is not. Signal
strength is fixed at −30 dBm for every station, there is no distance, path loss or interference,
a station cannot roam by moving away, and throughput figures mean nothing because frames are
memory copies. Separate networks are kept apart by channel. That is a deliberate scope: the labs
teach wireless *security*, not radio engineering.

**Traps.** A node added after the attach has no `wlan0` until `gns3-wifi-attach` runs again. The
radio pool is shared by the whole VM, so two wireless projects open at once compete for radios.
There is no canvas link, so the GUI's link capture does not work: capture on the node's monitor
interface instead. That is the one exception to the labs' rule of capturing on the link. The image
has no `aircrack-ng`, so deauthentication and handshake cracking are not available.

## 2. Link performance

**What the student sees.** A *NETem* node placed in the middle of a link, with a menu on its
console: set a delay, jitter, loss or a rate limit, in both directions or in one only. Ping and
`iperf3` on either side show the effect at once.

**How it is done.** The NETem node bridges its two interfaces, so it is invisible to the hosts
(it has no address), and applies Linux `tc netem` to the outgoing side of each interface: the
setting on `eth1` shapes traffic travelling from `eth0` to `eth1`, and the reverse for `eth0`.
The *Traffic Generator* template is a host with `iperf3`, `ping` and the usual tools, for measuring
what the NETem node does.

**What is real and what is not.** The kernel's queueing and TCP's reaction to it are real: a
delay really does cut TCP's throughput, loss really does trigger retransmissions, and a one-way
delay really does break assumptions in a distributed system. The baseline is not real. Between
containers, a "link" is a memory copy whose speed is set by the VM's CPU, so an unshaped `iperf3`
run measured 571 Mbit/s on one appliance and will measure something else on the next, and it moves
with whatever else the VM is doing. Teach the ratios between conditions, not the digits, and mark
the shape of a student's results rather than the numbers.

**Traps.** NETem shapes a canvas link, so it cannot be put on the "air" between wireless nodes.
Every condition stays until it is cleared from the menu, so clear one before applying the next.

## 3. Traffic and load

**What the student sees.** Floods, scans and loads they generate themselves: `hping3` SYN floods,
`nmap` scans, a shell loop of 30 `curl` requests against a load balancer, `arpspoof` poisoning a
LAN, a fake reverse shell calling out with `nc`, `iperf3` filling a link for a dashboard.

**How it is done.** Ordinary tools on ordinary nodes. A project has no route out unless it adds a
NAT node, so attack traffic cannot leave the topology. The labs that use it give the attacker,
victim and honest client a node each, so the student can watch the attack from both sides.

**What is real and what is not.** The packets are real and so are the defences' responses to
them: a firewall rate limit really does drop the flood, and really does drop the honest client's
connection with it. The scale is not. A "denial of service" here is one container flooding another
on the same machine, so the labs are scoped to the mechanism (why a SYN flood fills a backlog, why
SYN cookies are the real fix) and never claim the volume of a real attack.

**Traps.** A flood competes for the same CPU as everything else on the VM, including other
students' projects on a shared appliance. Keep floods short and stop them at the end of the task.

## 4. Host events

**What the student sees.** A host that has a working day: users logging in, `sudo`, cron runs,
failed SSH logins with one burst that looks like a password-guessing attack, and a disk that
slowly fills and once runs away. It all appears in the host's log and in its metrics, ready for
monitoring, alerting and log analysis.

**How it is done.** The *Linux Host* and *Ubuntu Host* images include `eventgen`, a small shell
script. `eventgen start` plays a simulated day in 30 minutes and then starts the next day; `stop`
ends it and cleans up. The disk is a 64 MB memory-backed file system at `/srv/data`, so it fills
without touching the VM's real disk. The day is seeded from the node's name and address, so the
same node gives the same day every time, and the burst and the runaway always fall between minutes
8 and 25. `eventgen schedule` lists the day in advance, and `eventgen trigger <type>` runs any one
episode now, which is what a lab step uses when it needs something to happen on cue.

**What is real and what is not.** Nobody logs in and nothing attacks the host: the lines are
written through `logger` in the formats the real daemons use. Every line ends in `sim=` and the
simulated time of day, or `sim=now` for a triggered event, so no tutor or student can mistake one
for a real incident. The disk filling is real: the files exist, and `node_exporter` reports the
free space falling.

**Traps.** Simulated night is quiet. The first ten minutes of each day are midnight to 08:00, so a
lab that waits for the schedule may wait a while; use `trigger`. A day rolls over every 30 minutes
and empties the slow climb, so an alert on "any disk use" clears and fires again on the hour and
half hour. A node created on an older appliance has no `eventgen`: the script arrives with the
image, not with the project.

## 5. Log lines

**What the student sees.** Syslog files on each host, forwarded to a central collector, searched
with `grep`, and read by tools such as fail2ban and Wazuh.

**How it is done.** Containers run no logging daemon and have no journal, so the student starts
one: BusyBox `syslogd` on the Alpine-based nodes (it writes `/var/log/messages`), or `rsyslogd` on
the Ubuntu Host, which can also forward to and receive from other hosts. Lines come from the
services that really run, from `logger`, and from `eventgen`.

**What is real and what is not.** The pipeline is real: the daemons, the forwarding, the
collector, the parsing. The volume is not, unless `eventgen` is running. A host with no generator
writes almost nothing, which is the main reason the generator exists.

**Traps.** Logging is lost when the project closes, along with everything else in `/var/log`, and
the daemon has to be started again each session. BusyBox `syslogd` adds a `facility.priority`
field to every line, which fail2ban's default patterns reject, including for real SSH lines, so
fail2ban labs use rsyslog on Ubuntu Hosts. A count of failed logins in a busy log includes the
generator's background trickle; filter on `sim=now` to count only what the student triggered.

## 6. Time

**What the student sees.** Expired certificates, a clock that is "five minutes out", cron jobs and
backups that run on a short schedule, a day of events in half an hour.

**How it is done, and the one hard fact.** Every container reads the VM's clock. There is no
per-node clock, so **a `date -s` on one node moves the clock for every node on the VM**, in every
project, for everyone using that appliance. On the VirtualBox appliance, an error under 20 minutes
is slewed back so slowly that it persists for days; a larger one is stepped back within seconds.
Running `chronyd` on a client without `-Q` (query only) or `-x` (never adjust) can also step the
shared clock. So the labs never set the clock. They fake time in four other ways:

- **`faketime`**, on the Alpine-based nodes, shifts the clock for one command only:
  `faketime -f +60d openssl x509 -checkend 0`, or a client time check run five minutes "fast".
- **Certificates made already expired or not yet valid**, by giving OpenSSL explicit start and end
  dates. No clock change is needed to teach certificate expiry. No lab does this yet, but it has
  been tested on both the Alpine-based nodes and the Ubuntu Host.
- **A compressed day**, as `eventgen` does.
- **Short intervals**, such as a backup every two minutes, so a schedule can be seen working
  inside a class.

**What is real and what is not.** Time zones are real and per process (`TZ=`), but only some
images carry the time-zone data; on the rest a named zone silently prints UTC, while a POSIX string
such as `TZ=AEST-10` works everywhere. Clock skew between two machines cannot be shown for real,
because there are no two clocks; it needs `faketime` around one side.

**Traps.** If the clock does get moved, BusyBox `crond` re-runs the minutes it has already run
after a step back and skips the missed ones after a step forward, so a backup or patch lab gets
duplicate or missing runs rather than an error. Fixing the clock is a job for whoever manages the
appliance.

## 7. Simulated computers

**What the student sees.** A *PowerShell PC* that answers the same commands as a lab PC:
`Get-NetAdapter`, `New-NetIPAddress`, `Test-NetConnection`, `ipconfig`, with Windows-style output
and an adapter called `Ethernet`. Beside it, a *Lab Router* whose console imitates the lab's
routers.

**How it is done.** The PowerShell PC is a small Linux container running PowerShell 7, with the
Windows networking commands re-created on top of Linux. Its settings are saved, as on Windows, so
they survive closing the project. Where a lab needs real Windows (its firewall, SMB, RDP, Wireshark
on Windows), the *Windows Host* is a separate, real Windows virtual machine joined to the topology
through a Cloud node ([Adding a Windows Host](../students/windows-host.md)). It is not a container: GNS3 does not start or reset it, it needs a lot of
host memory, and only one open project can use it at a time.

**What is real and what is not.** The networking underneath is real Linux networking, so the
student's addressing, routes and tests behave correctly. A few details show the Linux underneath:
TTL starts at 64, not 128; there is no browser (`curl` instead); the web server is a Windows-style
service rather than the lab's usual stack; times are fractions of a millisecond. The student
guide that goes with the PowerShell PC labs lists every difference, so a student who meets one is
not caught out.

**Traps.** A PowerShell console can lose an Enter typed before PowerShell is ready; wait for the
prompt. A missing cable still shows the adapter as `Up` (see section 9).

## 8. Simulated cloud

**What the student sees.** "VPCs", "security groups", "network ACLs" and a "cloud VM" with a public
address, in a topology on their own appliance, with no cloud account.

**How it is done.** Linux routers and hosts stand in for the provider's building blocks. A VPC is
a router and its subnets; peering is a route added on each side, one at a time; a security group
is an nftables ruleset on the instance (stateful, deny by default); a network ACL is a stateless
ruleset on the subnet's router; the cloud VM is a host behind a router acting as the provider's
edge, and the lab site sits behind a NAT, so only one end of a VPN tunnel can be reached.

**What is real and what is not.** The packet behaviour is real, and it is the point: the student
sees why a stateful security group needs no rule for replies and a stateless ACL does, and why a
tunnel from behind NAT needs a keepalive. The provider is not. There is no console, no API, no
billing, no managed service and no provider-specific default. Each lab ends by asking the student
to map what they built onto the real AWS or Azure feature, and where the two differ, the lab says so.
Labs that use a real cloud are separate and need accounts.

**Traps.** Firewall rules are kernel state and are lost when the node restarts; students capture
each task's result before closing the project.

## 9. Failures and faults

**What the student sees.** A link that goes down, a host that stops answering, a site cut off, a
service that answers wrongly: in a lab task, or in a pre-broken network to troubleshoot.

**How it is done.** Inside a node, `ip link set eth0 down` takes an interface down, and
`ifdown`/`ifup` brings it back with its routes. On a NETem node, 100% loss cuts a link or splits a
network into two halves (a partition), and a long one-way delay makes one machine lag. Stopping a
node on the canvas is a crash. For troubleshooting, the broken-network and broken-services demos
come with a catalogue of faults, each with the commands that cause it, the symptom a user would
report and the fix, and a script that applies and undoes them. Most faults are runtime state and
vanish when the project reopens; a lab handed out pre-broken puts the fault in the node's saved
network configuration instead.

**What is real and what is not.** The failure as the rest of the network sees it is real: probes
fail, routes go, a distributed system loses quorum. The physical layer is not. **A container keeps
carrier when its link is deleted or moved, and when the node at the other end stops.** There is no
`NO-CARRIER`, so a "pulled cable" is invisible on the interface and routing protocols notice a
failure only when their timers run out (OSPF took 29 seconds at its default timers, 2 seconds with
short ones).

**Traps.** Design "the cable fails" as an interface going down or 100% loss on a NETem node, not
as a deleted link. `ip link set eth0 up` restores the link but not the routes that went with it;
use `ifdown` and `ifup`.

## 10. The outside world

**What the student sees.** Either nothing outside the topology, which is the default and
deliberate, or real internet through a NAT node; and, in between, stand-ins for the services the
internet normally provides.

**How it is done.** Nodes have no internet and no DNS: `/etc/resolv.conf` is empty, and `apt` or
`apk` installs fail. So anything a lab needs is in the image already. Where a lab needs what the
internet would provide, the topology provides it: a *Patch Server* node that serves packages and
updates, so a patching lab has updates to apply and gives the same answers every term; DNS servers
and `/etc/hosts` entries that make `www.example.com` mean a node in the topology; a "small
internet" of routers and servers. When a lab really needs the internet, a GNS3 NAT node gives
outbound access, if the VM itself has it.

**What is real and what is not.** Inside the topology everything is real: the DNS, the package
manager, the web servers. Only the scale and the names are invented, and the names come from the
reserved `example.com` and documentation address ranges, so nothing collides with a real site.

**Traps.** A NAT node's subnet differs between appliances, so a lab never names it; students read
it from DHCP. Real websites can refuse the BusyBox `wget` the small nodes have; use `example.com`.
Anything a lab installs at run time is lost when the project closes, so a lab never depends on an
install step; [Saving your work](../students/gns3-saving-work.md) explains what does survive.

## Summary

| Technique | Node or template | Labs that use it | Check this first |
|---|---|---|---|
| Wireless | Access Point, Station, plus `gns3-wifi-attach` on the VM | `wireless-basics`, `wifi-enterprise`, `evil-twin-8021x`, `wireless-site-demo` | No RF at all; radios attach per session |
| Link performance | NETem, Traffic Generator | `link-performance`, `ds-fault-testbed` | Throughput is set by the VM's CPU; teach ratios |
| Traffic and load | any host; `hping3`, `nmap`, `iperf3`, `curl` | `syn-flood-dos`, `port-scanning`, `suricata-basics`, `load-balancing-basics`, `arp-spoofing` | Mechanism, not scale |
| Host events | `eventgen` on Linux Host and Ubuntu Host | `network-monitoring-basics`, `central-logging` | Night is quiet; use `trigger` |
| Log lines | `syslogd` (Alpine), `rsyslogd` (Ubuntu Host) | `central-logging`, `host-detection-basics`, `ssh-hardening`, `wazuh-basics` | No daemon runs until started |
| Time | `faketime`, OpenSSL dates, short schedules | `ntp-basics`, `backup-basics`, `patch-management`, the `eventgen` labs | One clock for the whole VM; never set it |
| Simulated computers | PowerShell PC, Lab Router; Windows Host (real) | `pc-two-computers`, `pc-switched-lan`, `pc-small-internet`, `windows-host` | Linux shows through: TTL 64, no browser |
| Simulated cloud | Linux Router, Linux Host, nftables, WireGuard | `cloud-vpc-simulated`, `cloud-vpn-simulated` | No provider; map to the real feature |
| Failures and faults | NETem, `ip link`, fault catalogues | `broken-network`, `broken-services`, `ds-fault-testbed`, `resilience-demo` | Carrier never drops |
| The outside world | Patch Server, DNS nodes, NAT node | `patch-management`, `dns-server-basics`, `small-internet`, `gns3-internet-nat` | No internet by default; everything must be in the image |
