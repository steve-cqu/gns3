# Windows Host — host-side tooling

Unlike everything else under `server/`, nothing here runs on the GNS3 VM. These scripts run
on the **student's own machine** and inside the **Windows VM that sits beside** the GNS3 VM.

The Windows Host is not a node image. Windows runs as a separate VM on the student's own
hypervisor and is joined to a GNS3 topology through an isolated hypervisor network and a
GNS3 Cloud node. The reasoning — and why it is not a Qemu node inside the GNS3 VM — is in
`gns3-dev/notes/windows-host-node.md` (private repo).

```
GNS3 VM  eth2 ──┐                          ┌── NIC2  Windows 11 VM
                └── isolated lab network ──┘
                    (VirtualBox Internal Network / Fusion custom vmnet)
```

## What is here

| File | Runs on | What |
|---|---|---|
| `configure-windows-host.ps1` | inside the Windows VM, as Administrator | **Makes the machine reachable.** Allows inbound ping, installs and starts the OpenSSH server, enables Remote Desktop where the edition supports it, marks the lab adapter Private, optionally sets a static address, a lab route and a hostname, and stops the machine sleeping. Quick, and every student needs it. |
| `setup-windows-tools.ps1` | inside the Windows VM, as Administrator | **Makes the machine useful.** Sysinternals, IIS, Python, iperf3, the telnet client, and optionally Sysmon. Slow and unit-dependent, so it is separate — a failed 185 MB download here cannot take the firewall rules and ssh access down with it. |
| `sysmon-lab.xml` | — | A deliberately small Sysmon configuration: process creation, network connections and DNS queries, and nothing else. Short enough for a student to read. |

Both are idempotent, take `-DryRun`, and are safe to re-run after a part-finished attempt.

## The tools script

```powershell
.\setup-windows-tools.ps1 -List                  # what is already here, change nothing
.\setup-windows-tools.ps1 -DryRun -All           # what would change
.\setup-windows-tools.ps1 -All                   # everything except Sysmon
.\setup-windows-tools.ps1 -Sysinternals -Sysmon  # Sysmon needs the suite it lives in
```

| Switch | Installs | Notes |
|---|---|---|
| `-Sysinternals` | The suite to `C:\Tools\Sysinternals`, on the system PATH | 185 MB. Pre-accepts the licence for ~160 tools, or each one stops on a dialog — which over ssh means it hangs with no clue why |
| `-WebServer` | IIS | A Windows feature, nothing to download. Serves on port 80 **after a restart** |
| `-Python` | Python 3, machine-wide | Also deletes the Windows stub that opens the Microsoft Store instead of running Python |
| `-Iperf` | iperf3 | Pairs with the Linux nodes for throughput exercises |
| `-Telnet` | The telnet client | **After a restart** |
| `-Sysmon` | Sysmon with `sysmon-lab.xml` | Installs a driver, so it is deliberately **not** in `-All` |
| `-All` | Everything except `-Sysmon` | |

Three things learned the hard way, all handled by the script but worth knowing if you edit it:

- **`--source winget` is not optional.** The `msstore` source fails on a stock Windows 11 with
  `0x8a15005e` (server certificate mismatch), and that aborts the whole `winget install` even
  when the package is available from the working source.
- **Verify winget package IDs before using them.** They are version-pinned
  (`Python.Python.3.12`, not `Python.Python.3`) and a wrong one reports "No packages were
  found", which reads like a network fault. Check with `winget search <name> --source winget`.
- **Windows features need a restart.** IIS and the telnet client report `Enabled` immediately,
  but `W3SVC` and `telnet.exe` do not exist until the machine reboots. The script says so.

Reading what Sysmon collects needs no extra software:

```powershell
Get-WinEvent -LogName Microsoft-Windows-Sysmon/Operational -MaxEvents 20
Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Sysmon/Operational'; Id=3}
```

Event ID 3 records each network connection with the process that owns it and whether it was
inbound or outbound — something Windows does not log natively, and the retrospective
counterpart to TCPView.

## Still to come

Planned, not yet written — see the increments in `gns3-dev/notes/windows-host-node.md`:

- `New-WindowsHost.ps1` — creates the VM on a PC with `VBoxManage unattended install`
- `new-windows-host.sh` — the VMware Fusion equivalent for Apple Silicon
- `autounattend.xml`, `autounattend-arm64.xml`, `cqu-unattend.iso`, `make-unattend-iso.sh` —
  the answer file Fusion needs, since it has no unattended-install CLI

Both installers finish by running `configure-windows-host.ps1` in the guest, so that script
is the one piece a student can always fall back to running by hand.

## Using it now, before the installers exist

Install Windows 11 into a VM yourself, give it two adapters (one NAT for the internet, one
on the lab network), then open PowerShell **as Administrator** inside that VM:

```powershell
cd $HOME
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/steve-cqu/gns3/refs/heads/main/server/windows/configure-windows-host.ps1" -OutFile .\configure-windows-host.ps1

# see what it would do, then do it
powershell -ExecutionPolicy Bypass -File .\configure-windows-host.ps1 -DryRun
powershell -ExecutionPolicy Bypass -File .\configure-windows-host.ps1 -ComputerName WinHost
```

Two things bite here, both found on the first real run:

- **Run it via `powershell -ExecutionPolicy Bypass -File`.** A downloaded `.ps1` will not run
  otherwise — PowerShell refuses with "running scripts is disabled on this system". This is
  better than `Set-ExecutionPolicy Bypass`, which prompts and changes a machine setting.
- **`Invoke-WebRequest` can fail the first time** with "The remote name could not be
  resolved". The VM's network is usually still settling just after install. Wait a few
  seconds and run it again.

Leave `-IPAddress` off if the topology runs a DHCP server. To set an address by hand:

```powershell
.\configure-windows-host.ps1 -LabAdapter "Ethernet 2" -IPAddress 192.168.10.50 -ComputerName WinHost
```

The script picks the lab adapter automatically as the one with no default gateway, and
prints every adapter's name if it cannot decide.

## If nothing on the lab network can ping Windows

Work down this list. The first two are what a first run gets wrong.

**1. Does the Windows VM have a lab adapter at all?** A VM built by clicking through
VirtualBox has one NAT adapter, which is what gives it internet. That adapter is not on the
lab network, and putting a lab address on it changes nothing. Windows needs **two**: NAT for
the internet, and a second on the same isolated network as the GNS3 VM's third adapter.

```
VBoxManage showvminfo "<windows-vm>" --machinereadable | findstr /i "nic"
VBoxManage modifyvm  "<windows-vm>" --nic2 intnet --intnet2 cqulab --cableconnected2 on
```

The internal network name (`cqulab` above) must match the GNS3 VM's third adapter
**exactly** — VirtualBox creates a new, separate network for any name it has not seen, with
no warning. Then set the lab address on that second adapter, not the first:

```powershell
.\configure-windows-host.ps1 -LabAdapter "Ethernet 2" -IPAddress 10.10.1.20
```

**2. Is the GNS3 VM's lab adapter in promiscuous mode?** It must be. A Cloud node forwards
frames carrying the *GNS3 node's* MAC address, not the VM adapter's own, and VirtualBox
drops those unless the adapter is allowed to receive them.

```
VBoxManage modifyvm "GNS3 VM" --nic3 intnet --intnet3 cqulab --nicpromisc3 allow-all
```

**3. Is `eth2` up on the GNS3 VM?** It has no address by design, but it must be `UP`:

```sh
ip -br link show eth2          # want: eth2  UP
sudo ip link set eth2 up       # until the appliance brings it up at boot
```

**4. Watch the wire.** This says exactly where frames stop. On the GNS3 VM:

```sh
sudo tcpdump -ni eth2 arp or icmp
```

Then ping from each side in turn. Nothing at all means the two VMs are not on the same
network (step 1). ARP requests going out with no reply means Windows is not answering —
check its firewall and that its lab adapter really holds the address. Requests arriving but
replies never reaching the GNS3 node means promiscuous mode (step 2).

## Windows licensing, and which edition you get

Students download the Windows 11 ISO themselves from Microsoft — x64 and ARM64 are both free
direct downloads. A key from CQU's Azure account is optional: unactivated Windows 11 runs
indefinitely, with a desktop watermark and no personalisation, neither of which matters for
lab work.

**Expect to end up on Windows Home.** Installing Windows 11 25H2 with *I don't have a
product key* offered no edition list and produced Home — `Get-WindowsEdition -Online`
reports `Core` — even from an ISO believed to be Education. Assume Home unless you check.

Home matters in exactly one way: it has no Remote Desktop **server**, so nothing can RDP
into the machine. `ssh` is unaffected and works on every edition, which is why activities
should be built on it. `configure-windows-host.ps1` detects Home and reports Remote Desktop
as unavailable rather than opening port 3389 in front of a service that is not there.

To get Education, enter an Azure Education key after installing — Settings → System →
Activation → Change product key. That changes the edition in place and brings the RDP server
with it.

Either way, **`ssh` is the access path activities should be built on**: it works on every
edition, it is what a GNS3 Linux node uses to reach this machine, and it is what the staff
check script depends on.

## Reaching the machine over ssh

From any Linux node in the topology:

```sh
ssh gns3@10.10.1.20
```

The shell you land in is **`cmd.exe`** — the Windows OpenSSH default — so the classic tools
all work directly, either interactively or as a one-shot command:

```sh
ssh gns3@10.10.1.20 ipconfig
ssh gns3@10.10.1.20 "route print"
ssh gns3@10.10.1.20 "powershell -Command Get-NetIPAddress"
```

The default shell is deliberately left as `cmd.exe`. It is what Windows ships, it is what
students expect from a Windows command line, and `ipconfig` / `ping` / `tracert` /
`route print` / `netstat` / `nslookup` are the tools an activity is going to use anyway.
