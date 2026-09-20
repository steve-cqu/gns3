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
| `New-WindowsHost.ps1` | on the student's PC, in PowerShell | **Creates the VM, on VirtualBox.** Builds a Windows 11 machine with EFI and TPM 2.0, gives it the NAT and `cqulab` adapters, and hands it to `VBoxManage unattended install`. Optionally runs `configure-windows-host.ps1` inside the guest afterwards. `-ImageIndex` picks the Windows edition and `-ProductKey` answers Setup's key screen; `-List`, `-DryRun` and `-Force`. |
| `new-windows-host.sh` | on the student's Mac, in Terminal | **Creates the VM, on VMware Fusion.** Writes the `.vmx` by hand so the adapter order — and therefore which interface is the lab one — is fixed here rather than decided by Fusion. Needs `--vmnet`, because the custom network's number is local to each Mac; `--list` prints the candidates. |
| `autounattend.xml`, `autounattend-arm64.xml` | read by Windows Setup | The answers Setup would otherwise stop for: disk layout, edition, no product key, the `gns3` account, the machine name, and a first-logon command that runs `configure-windows-host.ps1` off the same disc. Two files because **Setup silently ignores an answer file whose architecture is not its own**. |
| `make-unattend-iso.sh` | staff, on a Mac or Linux | Builds `cqu-unattend.iso` from one of those answer files plus `configure-windows-host.ps1`. Students never run this — they get the ISO, or install by hand. |

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

## The first real run — 20 September 2026

`New-WindowsHost.ps1` met a hypervisor for the first time on 20 September 2026: **VirtualBox
7.0.20 on a Linux host**, a retail Windows 11 25H2 x64 consumer ISO, against a live GNS3
appliance. It built the machine, Windows installed, and the machine joined a topology and
answered ssh from a GNS3 node. Two cycles were run: the first needed a person at two screens
and found six defects; the second closed both screens. `new-windows-host.sh` and the ARM64
answer file have still never been run.

**What the run proved:**

- The machine it builds is right — EFI, TPM 2.0, 4 GB, 64 GB disk, NAT plus the `cqulab`
  adapter — and Windows 11 installs on it without bypassing any requirement.
- **`--post-install-command` survives the quoting**, which this file called the least-tested
  part of the script. Windows fetched `configure-windows-host.ps1` from GitHub over NAT and
  ran it at first logon with nobody watching.
- **Automation reproduces the hand-run result.** Lab adapter resolved to `Ethernet 2` with no
  ambiguity, profile Public → Private, `10.10.1.20/24`, inbound ICMP allowed, OpenSSH
  installed and running, Remote Desktop enabled.
- **End to end from inside GNS3**: `ping` both ways — `ttl=128` from Windows, `ttl=64` from
  the Alpine node — and `ssh gns3@10.10.1.20 ipconfig` returning both adapters.
- **`--image-index` reaches Windows Setup.** That is how the edition is chosen, and it changes
  what this file used to say about Home. See *Windows licensing* below.

**Four defects found and fixed during the run**, all in `New-WindowsHost.ps1`:

- **`Find-VBoxManage` crashed instead of reporting.** It built its candidate paths with
  `Join-Path` on environment variables that are empty on any machine without VirtualBox
  installed — so the friendly "VirtualBox was not found, install it from virtualbox.org"
  message was unreachable by exactly the student who needs it. The candidates are now built
  conditionally.
- **Nothing checked that `VBoxManage` runs.** A launcher that rejected the name it was called
  by had its error text printed in the slot where a version belongs, and `-List` then reported
  a VM as absent when it had simply failed to ask. A `--version` check now gates everything.
- **The ISO attach was one call and had to be two.** `storageattach … --type dvddrive --medium
  <iso>` against an empty slot goes down VBoxManage's *mount* path and fails with `No drive
  attached to device slot 0 on port 1 of controller 'SATA'`. Attaching `emptydrive` first
  creates the drive; the disc goes in second.
- **The SATA controller had two ports.** The disk and the Windows ISO fill both, leaving the
  unattended installer nowhere for its own media. Now four.

**Two defects stopped it being unattended. Both were closed the same day**, in a second
cycle that used `-NoStart` to read the prepared machine before booting it:

- **Nothing pressed "Press any key to boot from CD or DVD."** The prompt appeared, no key
  arrived, and the VM dropped into VirtualBox's *failed to boot* dialog. The auxiliary disc
  VirtualBox generates is **not bootable** — `cat` its `.viso` and it lists
  `autounattend.xml`, `VBOXPOST.CMD` and a copy of the Guest Additions, and no boot files —
  so it is the retail Windows ISO that boots, prompt and all, and 7.0.20 does not patch that
  out. The script now taps space once a second for twelve seconds after starting the VM
  (`controlvm … keyboardputscancode 39 b9`). Windows Setup reads the answer file off the
  auxiliary disc regardless of what booted, which is why everything downstream already
  worked.
- **The generated answer file's `<ProductKey>` element was empty**, and 25H2 Setup treats
  that as unanswered and stops. `-ProductKey` now passes `--key` through, which puts the key
  into that element. **Microsoft's generic volume-licence key for the edition is accepted
  from a retail consumer ISO** — verified with the Education GVLK, which answers Setup's
  question without activating anything.

**The second cycle then installed unattended, start to finish.** Nothing was typed inside
Windows at any point, and the machine came up as: `Get-WindowsEdition -Online` → `Education`
(from `-ImageIndex 4`), `whoami` → `winhost\gns3` and `$env:COMPUTERNAME` → `WINHOST` (from
the answer file), and `Ethernet 2` holding `10.10.1.20` (from the post-install command).

**`make-unattend-iso.sh` was run for the first time the same day**, on Linux with `xorriso`,
for both architectures. Each disc carries exactly `autounattend.xml` and
`configure-windows-host.ps1` at 406 KB under the label `CQU_UNATTEND`, the extracted script
is byte-identical to the one in the repo, and the architecture guard — which greps the
answer file rather than trusting its name, because Setup ignores a mismatched one in
silence — passed against the real ARM64 file. The ISO's **contents** are therefore verified;
what an ARM64 Windows Setup does with them is not.

**A third run then did the whole thing in one command**, with different values to exercise
`-Name`, `-ComputerName` and `-LabIPAddress`: a Windows 11 Education machine named `WINHOST2`
on `10.10.1.21`, from one line, with nothing typed at any point. Re-running
`configure-windows-host.ps1` on the finished machine reported **0 changed**, which is the
first test of the idempotence this file has always claimed.

One refinement came out of that run. The keypress was space, and space also **activates the
focused control** on Setup's first screen — it hit the Support link and Setup put up "Unable
to open link", which WinPE cannot open. That install recovered, but a modal dialog in front
of an unattended install is what an unattended install cannot clear. The script now sends
**Tab**, which satisfies "press any key" and activates nothing. *The Tab variant has not
itself been through a full install yet.*

**Still unverified — the Mac half**, unchanged from the draft:

| Where | What is unverified |
|---|---|
| `new-windows-host.sh`, `guestOS` | `arm-windows11-64` / `windows11-64`. If Fusion rejects the VM, this is the line to change; `--list` prints what would be asked for |
| `new-windows-host.sh`, `e1000e` | Chosen over Fusion's default `vmxnet3`, which Windows 11 ARM64 has no in-box driver for. **This is a hypothesis about fixing the "no network until VMware Tools" problem, not a measurement** |

Use `--dry-run` (`-DryRun`) first on both. Each prints every command it would run, and the
Fusion one prints the whole `.vmx`, so the first test can be read before it is executed.

Both installers finish by running `configure-windows-host.ps1` in the guest, so that script
is the one piece a student can always fall back to running by hand — and it *is* proven, on
a real Windows 11 VM on both architectures, and now under automation as well.

### A Linux host is not a case this script knows about

The plan contemplates two hosts: a PC running VirtualBox and a Mac running Fusion. A Linux
machine running VirtualBox is neither, and nothing here accounts for it — `New-WindowsHost.ps1`
is PowerShell and looks for `VBoxManage.exe` by its Windows name. It does run, with `pwsh`
installed and a wrapper that answers to that name:

```sh
sudo tee /usr/local/bin/VBoxManage.exe >/dev/null <<'EOF'
#!/bin/sh
exec /usr/bin/VBoxManage "$@"
EOF
sudo chmod +x /usr/local/bin/VBoxManage.exe
pwsh ./New-WindowsHost.ps1 -List
```

**A symlink does not work** and fails in a way that looks like success: VirtualBox's Linux
launcher dispatches on the name it was called by, so `VBoxManage.exe` gets `Unknown
application - VBoxManage.exe` from every call, which the script reported as a version and as
a VM that does not exist. That is what the `--version` check above now catches.

One layer stays untested this way: Windows PowerShell 5.1 passes arguments to a native
program differently from `pwsh` on Linux, and 5.1 is what a student's PC has.

## Installing by hand

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

**Check it with `showvminfo`, not `--machinereadable`.** On VirtualBox 7.0.20 the machine-readable
output carries no `nicpromisc3` key at all, so grepping for one reports nothing on a correctly
configured VM. The human-readable form always says:

```
VBoxManage showvminfo "GNS3 VM" | grep -A1 '^NIC 3'
```

Want `Attachment: Internal Network 'cqulab'` and `Promisc Policy: allow-all` on that line.

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

### On a Mac — the same list, in Fusion's words

Proven on Apple Silicon 9 Aug 2026. Steps 1, 3 and 4 above are unchanged; steps 2 and the internal
network name work differently.

| VirtualBox | Fusion |
|---|---|
| Internal Network `cqulab` | A custom vmnet with *NAT*, *Connect the host Mac* and *DHCP* all off, renamed `cqulab` |
| Adapter → Advanced → *Promiscuous Mode: Allow All* | **No per-adapter setting.** Fusion → Settings → Network → *Require authentication to enter promiscuous mode* |

Left ticked (the default), macOS prompts for the Mac password when the Cloud node starts. That prompt
appearing is the sign promiscuous mode is being requested at all; never being asked usually means the
Cloud node is bound to the wrong interface.

**Two Mac-only traps, both of which look like a firewall problem:**

- **The third adapter is not reliably `eth2`.** Fusion's PCI slot numbers do not sort in the order
  adapters appear in the UI — on the spike machine the adapter added third came up as `eth1`. Check
  by MAC: `ip -br link show` in the VM against the `generatedAddress` of the `.vmx` block whose
  `connectionType` is `custom`. Fix by swapping which network Adapters 2 and 3 attach to in the GUI;
  the slot number belongs to the *position*, not the network.

  The arrangement that tested working, which is **not** the intuitive one — the lab network sits in
  the middle and the internet adapter last:

  | Fusion adapter | Attached to | Guest |
  |---|---|---|
  | Network Adapter | *Private to my Mac* | `eth0` |
  | Network Adapter 2 | `cqulab` | **`eth2`** |
  | Network Adapter 3 | *Share with my Mac* | `eth1` |

  Adapters present when the VM is created take low sequential slots; one added later through *Add
  Device* takes a high bridge-encoded slot that enumerates earlier. Verified on one machine only, so
  check rather than assume.

  ```sh
  grep ethernet ~/Virtual\ Machines.localized/*.vmwarevm/*.vmx
  ```

- **Windows 11 ARM64 has no network until VMware Tools is installed.** Fusion presents a `vmxnet3`
  adapter and Windows on ARM has no in-box driver for it, so a fresh install cannot even download
  this script. It is also why Setup's *Let's connect you to a network* screen has to be bypassed —
  `Fn + Shift + F10`, then `start ms-cxh:localonly` (`oobe\bypassnro` on builds before 24H2).

The `10.10.1.2/24`-on-`eth2` test in step 4 is the fastest way to split these apart: it uses `eth2`'s
own MAC, so it proves the two VMs share a wire **without** involving promiscuous mode or the Cloud
node. Remove the address afterwards — `eth2` must carry none.

## After rebuilding the Windows Host: "REMOTE HOST IDENTIFICATION HAS CHANGED"

A rebuilt Windows machine has **new ssh host keys** but keeps the **same lab address**, so every
GNS3 node that has ever ssh'd to it now refuses to connect, with a warning that reads like an
attack in progress:

```
@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@
Host key verification failed.
```

Nothing is wrong. On the node, forget the old key and connect again:

```sh
ssh-keygen -R 10.10.1.20
ssh gns3@10.10.1.20 ipconfig
```

This is the same hazard that made `Windows-Host-Demo.gns3project` ship with its `known_hosts`
stripped — a project that remembers one machine's keys is unusable against anybody else's. Expect
it whenever the Windows Host is rebuilt, which during development is often.

## Windows licensing, and which edition you get

Students download the Windows 11 ISO themselves from Microsoft — x64 and ARM64 are both free
direct downloads. A key from CQU's Azure account is optional: unactivated Windows 11 runs
indefinitely, with a desktop watermark and no personalisation, neither of which matters for
lab work.

**A retail ISO holds a dozen editions, and which one you get is decided by an argument.**
Ask the ISO what is in it:

```sh
VBoxManage unattended detect --iso=<path to the .iso>
```

On the 25H2 consumer ISO of September 2026 that lists eleven images — Home at index 1,
Education at 4, Pro at 6 — and confirms `Unattended installation supported = yes`.

**Installing by hand gets you Home, and offers no choice about it.** With *I don't have a
product key*, 25H2's Setup showed no edition list at all and installed image 1;
`Get-WindowsEdition -Online` reports `Core`. That is what August 2026's run produced, and it
was read at the time as a licensing limit. It is not — it is the default image.

**`New-WindowsHost.ps1 -ImageIndex 4` installs Education, with no key.** Verified 20
September 2026: `Get-WindowsEdition -Online` → `Education`, unactivated, on a consumer ISO.
The indexes differ per ISO, so run `unattended detect` rather than trusting the number.

The edition matters in exactly one way: **Home has no Remote Desktop server**, so nothing can
RDP into a Home machine. Education and Pro have one, and `configure-windows-host.ps1` enables
it. `configure-windows-host.ps1` detects Home and reports Remote Desktop as unavailable
rather than opening port 3389 in front of a service that is not there.

Entering an Azure Education key after installing — Settings → System → Activation → Change
product key — still works, and is the way to change the edition of a machine already built.

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

**Every student will see a post-quantum warning, and it is not a fault:**

```
** WARNING: connection is not using a post-quantum key exchange algorithm.
** This session may be vulnerable to "store now, decrypt later" attacks.
** The server may need to be upgraded. See https://openssh.com/pq.html
```

The node images' OpenSSH client offers a post-quantum key exchange; the Windows OpenSSH
server does not yet, so the client says so and connects anyway. Nothing is broken and nothing
needs changing. Say this in any activity that ssh's into Windows — otherwise it reads as a
security failure the student has caused, and in a security unit it is worth two sentences of
explanation rather than none.
