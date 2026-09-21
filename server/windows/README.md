# Windows Host — host-side tooling

Unlike everything else under `server/`, nothing here runs on the GNS3 VM. These scripts run
on the **student's own machine** and inside the **Windows VM that sits beside** the GNS3 VM.

The Windows Host is not a node image. Windows runs as a separate VM on the student's own
hypervisor and is joined to a GNS3 topology through an isolated hypervisor network and a
GNS3 Cloud node. The reasoning — and why it is not a Qemu node inside the GNS3 VM — is in
`gns3-dev/notes/windows-host-node.md` (private repo).

```
GNS3 VM  eth2 ──┐                          ┌── NIC2  Windows 11 VM
   (eth1 on a   └── isolated lab network ──┘
    Mac)            (VirtualBox Internal Network / Fusion custom vmnet)
```

**The PC and Mac paths diverged on 21 September 2026 and are no longer the same procedure.** The PC
path installs unattended from one command. The Mac path cannot: Windows 11 25H2 ignores an answer
file on a second CD, so Setup is answered by hand, and two steps — adding a TPM and installing VMware
Tools — exist only in Fusion's menus. This was accepted deliberately rather than worked around; the
Mac is a small cohort. See **The Mac path** below before helping anyone with a Mac.

## What is here

| File | Runs on | What |
|---|---|---|
| `configure-windows-host.ps1` | inside the Windows VM, as Administrator | **Makes the machine reachable.** Logs to `C:\Windows\Temp\configure-windows-host.log`. Allows inbound ping, installs and starts the OpenSSH server (Windows Update, or the pinned Win32-OpenSSH MSI as a fallback), enables Remote Desktop where the edition supports it, marks the lab adapter Private, optionally sets a static address, a lab route and a hostname, and stops the machine sleeping. Quick, and every student needs it. |
| `setup-windows-tools.ps1` | inside the Windows VM, as Administrator | **Makes the machine useful.** Sysinternals, IIS, Python, iperf3, the telnet client, and optionally Sysmon. Slow and unit-dependent, so it is separate — a failed 185 MB download here cannot take the firewall rules and ssh access down with it. |
| `sysmon-lab.xml` | — | A deliberately small Sysmon configuration: process creation, network connections and DNS queries, and nothing else. Short enough for a student to read. |
| `New-WindowsHost.ps1` | on the student's PC, in PowerShell | **Creates the VM, on VirtualBox.** Builds a Windows 11 machine with EFI and TPM 2.0, gives it the NAT and `cqulab` adapters, and hands it to `VBoxManage unattended install`. Optionally runs `configure-windows-host.ps1` inside the guest afterwards. `-Edition` picks the Windows edition by name (`-ImageIndex` by number) and `-ProductKey` answers Setup's key screen; `-List`, `-DryRun` and `-Force`. |
| `new-windows-host.sh` | on the student's Mac, in Terminal | **Creates the VM, on VMware Fusion.** Writes the `.vmx` by hand so the adapter order — and therefore which interface is the lab one — is fixed here rather than decided by Fusion. Needs `--vmnet`, because the custom network's number is local to each Mac; `--list` prints the candidates. **It cannot finish the job on Apple Silicon**: a TPM must be added through Fusion's UI before first boot, and VMware Tools installed after. It also writes `vmxnet3` on arm64 and `e1000e` on x86_64 — see **The Mac path**. |
| `autounattend.xml`, `autounattend-arm64.xml` | read by Windows Setup | The answers Setup would otherwise stop for: disk layout, edition, no product key, the `gns3` account, the machine name, and a first-logon command that runs `configure-windows-host.ps1` off the same disc. Two files because **Setup silently ignores an answer file whose architecture is not its own**. They also name **different editions** — Education on x64, **Pro on arm64**, because the ARM64 ISO carries no Education image. **The arm64 file is not read at all by Windows 11 25H2 Setup** when it arrives on a second CD; it is kept because it documents the intended configuration and because the ISO is still how `configure-windows-host.ps1` reaches the guest. |
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
answer file had still never been run **when this section was written**; they were, the next day,
and found six more — see **The Mac path** below.

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
  that as unanswered and stops. The script now passes `--key` through, with **Microsoft's
  published generic volume-licence key for whichever edition `-Edition` names** — accepted
  from a retail consumer ISO, and it selects an edition without activating anything.
  `-ProductKey` overrides it, for a key you do want to activate with.

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

**The Mac half was verified on 21 September 2026** — see **The Mac path** above. Both items that
were open here are now settled, and one of them was wrong:

| Where | Outcome |
|---|---|
| `new-windows-host.sh`, `guestOS` | `arm-windows11-64` is correct; Fusion accepts it |
| `new-windows-host.sh`, `e1000e` | **The hypothesis was wrong.** ARM64 Windows has no in-box driver for `e1000e` either, so the machine came up with no adapters at all. The script now writes `vmxnet3` on arm64 and `e1000e` on x86_64, and VMware Tools remains required on a Mac |

Use `--dry-run` (`-DryRun`) first on both. Each prints every command it would run, and the
Fusion one prints the whole `.vmx`, so the first test can be read before it is executed.

**`New-WindowsHost.ps1` finishes by running `configure-windows-host.ps1` in the guest;
`new-windows-host.sh` cannot.** Windows 11 25H2 never reads the ARM64 answer file from the
unattend CD, so nothing runs at first logon on a Mac and the student runs the script by hand
from that disc — step 5 of **The Mac path**. That fallback is the one piece a student can always
resort to, and it *is* proven, on a real Windows 11 VM on both architectures, and under
automation on the PC.

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

## The Mac path — Apple Silicon, 21 September 2026

Proven on **Fusion 26.0.0, Apple Silicon M1, macOS 26.6.1**, with
`Win11_25H2_EnglishInternational_Arm64_v2.iso`. The result scores `4 passed, 0 failed, 1 not
testable` on `windows-host-check.sh` — identical to the PC — and `configure-windows-host.ps1`
reported `changed=8 already-correct=4 failed=0` on its first run.

**It is not an unattended install and it will not become one.** Six defects were found bringing this
up; five are fixed in the scripts, and the sixth was accepted. In the order they bite:

| # | What goes wrong | Fixed by |
|---|---|---|
| 1 | The ARM64 ISO carries no **Education** image — Setup stops and asks which edition | `autounattend-arm64.xml` names **Pro** |
| 2 | Fusion refuses the VM: *No PCIe slot available for Ethernet0* | the `.vmx` declares `pciBridge4-7` as `pcieRootPort` |
| 3 | *No Media* on a good, bootable ISO, falling through to EFI Network | CDs start at `sata0:1`; **AHCI port 0 is unusable** |
| 4 | The guest looks hung — keyboard and mouse dead | the `.vmx` declares `usb_xhci`; the keyboard is an xHCI device |
| 5 | Setup stops on *must support TPM 2.0* | **manual** — Fusion's UI, see below |
| 6 | Setup asks every question; the unattend CD does nothing | **accepted** — Mac students answer Setup |

**Defects 2, 3 and 4 are one mistake in three costumes:** a hand-written `.vmx` is not a
Fusion-written one, and ARM64 is not x86. Slots 160 and 192 are slots *behind* bridges 4 and 5, so
pinning them without declaring the bridges leaves the adapter nowhere to go. AHCI port 0 hands the
firmware an empty drive however it is backed. And the keyboard is an xHCI HID, so a VM with only
`usb` (UHCI, x86 legacy) and `ehci` has an input device the guest cannot drive. All three are fixed
in `new-windows-host.sh` and verified on a VM built fresh by the fixed script.

### The procedure, in order

1. `./new-windows-host.sh --list` to find which `vmnetN` is `cqulab`, then
   `./new-windows-host.sh --iso <arm64.iso> --vmnet vmnetN --no-start`. **Pass `--no-start`**:
   the script starts the VM by default, and step 2 needs it powered off — a VM that boots without
   a TPM stops in Setup and has to be shut down again.
2. **Add a TPM, powered off.** *Settings* → turn on **Encryption** (partial is enough) → *Add
   Device* → *Trusted Platform Module*. This cannot be scripted: a vTPM needs Fusion-generated EK
   certificates (`vtpm.ekCSR` / `vtpm.ekCRT`) and an encrypted VM. `managedvm.autoAddVTPM` in the
   `.vmx` is ignored by Fusion 26 for a file it did not write; the line is kept in case a later
   build honours it.
3. **Answer Setup by hand.** Choose **Windows 11 Pro**. Bypass the network screen with
   `Fn + Shift + F10`, then `start ms-cxh:localonly`. Create `gns3` / `gns3`, machine name `WinHost`.
4. **Install VMware Tools**, then confirm `Get-NetAdapter` lists two adapters. Until this is done
   the machine has no network and `Get-NetAdapter` returns nothing at all.
5. **Run the script from the disc**, not by downloading it:
   `E:\configure-windows-host.ps1 -IPAddress 10.10.1.20 -ComputerName WinHost`. Do not pass
   `-LabAdapter`; the MAC-based selection picks correctly on Fusion.
6. **Point the Cloud node at `eth1`**, not `eth2`.

### Two consequences worth knowing

**Adding the TPM locks `vmrun` out.** The encryption it requires means `vmrun start`, `stop` and
`list` all answer `A password is required for this operation` unless given `-vp <password>`. The
machine is normally driven from Fusion's window from then on. `new-windows-host.sh` still ends with
a `vmrun start`, which therefore cannot work on a TPM-equipped VM — a known wart, not yet fixed.

**Why the unattend CD is still built.** Windows 11 25H2's `SetupHost.exe` engine does not read
`autounattend.xml` from a second CD. Everything else was ruled out: the disc is readable in the
guest, `dir e:\` shows the file under its full long name, all six components declare `arm64`, and
Setup logs no rejection — `X:\Windows\Panther\` holds neither `setupact.log` nor `setuperr.log`. The
ISO is kept because it is how `configure-windows-host.ps1` reaches the guest, and because it
documents the intended configuration.

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
.\configure-windows-host.ps1 -LabAdapterMac 08-00-27-3B-70-EA -IPAddress 192.168.10.50 -ComputerName WinHost
```

The script picks the lab adapter automatically as the one with no default gateway, and
prints every adapter's name and MAC if it cannot decide. That default is right on the
standard two-adapter build, so most runs need neither switch.

### Name the adapter by MAC, not by name

**A Windows adapter name is not the hypervisor's adapter number**, and on 20 September 2026
that cost most of a day. A VM built by `New-WindowsHost.ps1` — NIC 1 NAT, NIC 2 on the lab
network — presented them to Windows as:

| Windows name | MAC | Actually attached to |
|---|---|---|
| `Ethernet` | `08-00-27-3B-70-EA` | the **lab** network |
| `Ethernet 2` (`…Desktop Adapter #2`) | `08-00-27-B0-BF-0F` | **NAT** |

The installer passed `-LabAdapter 'Ethernet 2'`, this script gave that adapter a static lab
address — which removes its DHCP lease and the default route — and the machine lost its
internet. The OpenSSH install then failed against Windows Update several minutes later with
`0x80240438`, pointing nowhere near the cause, and every individual step reported success.
Neither the `2` in the name nor the `#2` in the device description means NIC 2; both record
the order Windows happened to enumerate the hardware in.

So `New-WindowsHost.ps1` now reads adapter 2's MAC back from `VBoxManage` and passes
`-LabAdapterMac`. The MAC is the only identifier the hypervisor and the guest both agree on.
`-LabAdapter` still works for a person reading names off the screen in front of them.

**And the script now refuses the mistake outright.** If the adapter it is about to configure
owns the machine's default route, and another adapter is up, it says so — and with
`-IPAddress` it stops rather than cutting the machine off, naming the adapter you probably
meant:

```
  WARNING  'Ethernet 2' owns this machine's DEFAULT ROUTE.
           That makes it the adapter with the internet on it, and a lab
           network has no gateway - so this is probably the wrong adapter.

           The lab adapter is almost certainly 'Ethernet'
           (08-00-27-3B-70-EA), which is up and has no default route.

           REFUSING to continue. ...
           Re-run with:  -LabAdapterMac 08-00-27-3B-70-EA
```

## OpenSSH: two sources, and why there are two

`ssh` is the access path every activity is built on, so the machine is not usable without it.
`configure-windows-host.ps1` will get the OpenSSH server from either of two places:

1. **The signed Win32-OpenSSH MSI from GitHub**, pinned in the script by release tag and
   SHA-256. **Tried first.** A 6 MB download and an `msiexec` run — seconds.
2. **The Windows capability** (Feature on Demand), fetched from Windows Update. The right
   build for this OS and what Microsoft documents, but **minutes every time**. The fallback.

**The MSI leads because of speed, and that was measured, not assumed.** The capability's
payload is only a few MB; the time goes on component-based servicing against the live image —
single-threaded, disk-bound — and on a machine minutes old it queues behind Windows Update's
first scan. It was costing several minutes of every unattended build, for every student, on
every rebuild. Nothing tunes it away: pointing `-Source` at a local Features-on-Demand ISO
removes the download, which was never the expensive part.

Reliability pushed the same way. On 20 September 2026 a build came up with no `sshd` at all:
three capability attempts, thirty seconds apart, every one `0x80240438` —
`WU_E_PT_ENDPOINT_UNKNOWN`, the update client could not work out which service endpoint to talk
to. That machine turned out to have had its default route removed by this same script (see
*Name the adapter by MAC, not by name*), so Windows Update was unreachable and the MSI would
have failed too — but it showed how silently this step can fail. A pinned MSI fails the same
way every time, or not at all.

What it costs: a version pin somebody has to bump, and GitHub has to be reachable at first
logon. The capability covers both. Some Windows Update failures are worth retrying and some are
not, so when the capability runs the script knows the second kind (`0x80240438`, `0x8024402C`,
`0x8024500C`, `0x800F0954`, `0x800F0950`, `0x80070422`) and stops retrying into a wall.

**The MSI is verified before it runs.** Downloading an installer at first logon and running it
as SYSTEM is only defensible if you check what you got, so the script compares a SHA-256
against the pin and refuses to install on a mismatch, deleting the file. The Authenticode
signature is checked as a second opinion and is allowed to disagree — a machine that cannot
reach a CRL reports something other than `Valid` for a perfectly good file, and that must not
cost a student a working lab host.

```powershell
# swap the order back, for a network that reaches Windows Update but not GitHub
.\configure-windows-host.ps1 -PreferWindowsUpdate

# take the MSI from a local mirror instead of GitHub
.\configure-windows-host.ps1 -OpenSshMsiUrl https://mirror.example.edu/OpenSSH-Win64-v10.0.0.0.msi `
                             -OpenSshMsiSha256 DDEC9C53...B96B7D9
```

Without `-OpenSshMsiSha256`, a custom URL must carry a valid Microsoft Authenticode signature
or nothing is installed. There is no pin to fall back on in that case, so the signature becomes
the gate rather than a second opinion.

**The two sources install to different places**, which is the first thing that confuses anyone
debugging the machine later:

| | Capability | MSI |
|---|---|---|
| Binaries | `C:\Windows\System32\OpenSSH\` | `C:\Program Files\OpenSSH\` |
| Config, host keys, `administrators_authorized_keys` | `C:\ProgramData\ssh\` | `C:\ProgramData\ssh\` |
| Service name | `sshd` | `sshd` |

Because the config directory is the same either way, the key setup in
`tools/tests/windows-host-check.sh` and everything in *Reaching the machine over ssh* below is
unaffected. The script says which source it used, and re-running it on a machine that already
has `sshd` from either source leaves it alone.

**To move the pin to a newer release**, take the tag, the asset names and the digests from
`https://api.github.com/repos/PowerShell/Win32-OpenSSH/releases/latest` and edit
`$OpenSshRelease` and `$OpenSshAssets` in `configure-windows-host.ps1`. Every release that
project has ever cut is named "Beta" or "Preview", and none is flagged as a prerelease on
GitHub — `latest` is simply the newest one, and the naming is not a warning about stability.

## Did it work? Three ways to tell

`configure-windows-host.ps1` usually runs where nobody is watching — an installer calls it at
first logon, in a window that closes when it finishes — so it leaves evidence behind.

```powershell
type C:\Windows\Temp\configure-windows-host.status     # one line per run: OK or FAILED, with counts
type C:\Windows\Temp\configure-windows-host.log        # the full transcript of every run
.\configure-windows-host.ps1 -DryRun                    # "0 change(s) would be made" = all in place
```

The **status** file is the quick answer and reads over ssh or down a phone: `OK` or `FAILED`, a
timestamp, and how many steps changed, were already correct, or failed. The **log** says what
happened and is the file to ask a student for. The **dry run** checks the machine as it is now
rather than what some earlier run did, so it catches a setting that has since been undone — a
reboot re-filing the network as Public, for instance.

If the machine simply does not answer, work down the list below.

## If nothing on the lab network can ping Windows

Work down this list. The first two are what a first run gets wrong.

**0. Read the status file and the log**, per the section above. When an installer ran the script
at first logon there was no console to watch, and those files are the only account of what it did.

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
.\configure-windows-host.ps1 -LabAdapterMac <that adapter's MAC> -IPAddress 10.10.1.20
```

Use the MAC, not the name — `VBoxManage showvminfo "<windows-vm>" | grep -i 'NIC 2'` prints
the one to use. *Name the adapter by MAC, not by name* above says why that matters.

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

**Three Mac-only traps. The first two look like a firewall problem; the third looks like nothing at
all, which is worse.**

- **The lab adapter is `eth1` on a Mac, not `eth2`.** The GNS3 VM keeps the **two** adapters it
  ships with — `eth0` *Share with my Mac*, `eth1` `cqulab` — and a Cloud node bound to `eth2` fails
  with `eth2 not found`. Standardised 21 September 2026.

  | Fusion adapter | Attached to | Guest |
  |---|---|---|
  | Network Adapter | *Share with my Mac* | `eth0` |
  | Network Adapter 2 | `cqulab` | **`eth1`** |

  **Do not add a third adapter to make it match the PC.** Adapters present when the VM is created
  take low sequential slots; one added later through *Add Device* takes a high bridge-encoded slot
  that enumerates **earlier**, silently swapping the lab and internet networks. That is what the
  9 August spike measured, and it is why two adapters is now the standard — with both present from
  the start, the order is deterministic. Confirm by MAC if in doubt:

  ```sh
  ip -br addr show                                             # in the GNS3 VM: eth1 has NO address
  grep ethernet ~/Virtual\ Machines.localized/*.vmwarevm/*.vmx  # connectionType "custom" is cqulab
  ```

  Because the demo project must name an interface, there are **two files**:
  `Windows-Host-Demo.gns3project` (`eth2`, PC) and `Windows-Host-Demo-arm64.gns3project` (`eth1`,
  Mac). Neither is on the appliance from the T3 2026 release — both are handed out through Moodle,
  and the student imports the one for their machine.

- **Windows 11 ARM64 has no network until VMware Tools is installed.** Windows on ARM has no in-box
  driver for **either** adapter Fusion can offer, so a fresh install cannot download this script and
  nothing can reach it. It is also why Setup's *Let's connect you to a network* screen has to be
  bypassed — `Fn + Shift + F10`, then `start ms-cxh:localonly` (`oobe\bypassnro` on builds before
  24H2). Tools installs from a local disc and so needs no network itself.

  **The symptom is silence, not an error.** `Get-NetAdapter` returns *nothing* — no adapter, no
  warning, no yellow bang in Device Manager to notice. If a Mac student reports "no network", ask for
  `Get-NetAdapter` output before anything else; an empty list means Tools, and nothing else.

- **`e1000e` is not a fix for that and was briefly used as one.** Between August and 21 September
  `new-windows-host.sh` asked for `e1000e` on the assumption that ARM64 Windows had an in-box driver
  for it. It does not. Machines built in that window install perfectly and have no network at all.
  The script now writes `vmxnet3` on arm64 and `e1000e` on x86_64. **A student whose VM predates
  that fix does not need rebuilding** — install Tools, then change both adapters to `vmxnet3` in
  Fusion with the machine powered off.

The `10.10.1.2/24`-on-`eth1` test in step 4 is the fastest way to split these apart: it uses `eth1`'s
own MAC, so it proves the two VMs share a wire **without** involving promiscuous mode or the Cloud
node. Remove the address afterwards — `eth1` must carry none.

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

**On x64 the lab standardises on Windows 11 Education, and installs it with no key.** Verified 20
September 2026: `Get-WindowsEdition -Online` → `Education`, unactivated, from a retail consumer
ISO. Education rather than Pro because it carries the Enterprise-grade security features —
AppLocker, Application Control, Credential Guard, the full BitLocker policy set — that Pro
does not, and an edition cannot be changed later without a key. Both have Remote Desktop.

**On ARM64 the standard is Windows 11 Pro, because Education is not on the disc.** Measured 21
September 2026 by reading the image list out of `sources/install.wim` on
`Win11_25H2_EnglishInternational_Arm64_v2.iso` — **three images, and no Education**:

| index | edition |
|---|---|
| 1 | Windows 11 Home |
| 2 | Windows 11 Home Single Language |
| 3 | **Windows 11 Pro** |

Home and Home Single Language are not usable here: `configure-windows-host.ps1` needs Pro, Education
or Enterprise for the Remote Desktop server. So `autounattend-arm64.xml` names Pro while
`autounattend.xml` and `New-WindowsHost.ps1`'s `-Edition` default still name Education. **That split
is deliberate — the edition is a property of the ISO, not of the lab**, and flattening it either way
breaks one of the two paths. Nothing in the teaching material depends on the Education-only features
today.

There is no `VBoxManage` on a Mac to list the images with. Read them straight from the WIM instead —
mount the ISO, and note the `hdiutil detach` at the end, because an ISO left attached to macOS is a
plausible-looking cause of unrelated failures:

```sh
hdiutil attach -readonly -nobrowse <path to the arm64 .iso>
# the image list lives in the XML resource at the end of sources/install.wim
hdiutil detach /Volumes/<volume name>
```

**Say the name, never the number.** `New-WindowsHost.ps1` takes `-Edition 'Windows 11
Education'` (its default), runs `unattended detect` against your ISO, and converts the name
into the index Setup wants; if the name is not on the ISO it prints what is and stops. The
answer files do the same thing directly, with `<Key>/IMAGE/NAME</Key>`. Nothing in either
path depends on an index number, because indexes belong to the ISO rather than to Windows.
`-ImageIndex` still overrides, for an ISO that names its images oddly.

**The key follows the edition.** Naming an edition and then being asked for a product key
would be two defaults disagreeing, so the script looks the edition up in Microsoft's
[published GVLK list](https://learn.microsoft.com/en-us/windows-server/get-started/kms-client-activation-keys)
and passes it. A GVLK is not a licence: it names an edition to Setup and does not activate.
So the whole command is:

```powershell
.\New-WindowsHost.ps1 -IsoPath C:\Users\me\Downloads\Win11_25H2_x64.iso
```

Matching is exact, deliberately: `Windows 11 Education` and `Windows 11 Education N` differ,
and the N editions ship without Media Player.

Home is what a **manual** install gives you, and its one consequence is that it has no Remote
Desktop **server**. `configure-windows-host.ps1` detects Home and reports Remote Desktop as
unavailable rather than opening port 3389 in front of a service that is not there.

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

**The default build negotiates a post-quantum key exchange, and prints no warning.** Measured
on a machine built 20 September 2026:

```
debug1: Remote protocol version 2.0, remote software version OpenSSH_for_Windows_10.0 Win32-OpenSSH-GitHub
debug1: kex: algorithm: mlkem768x25519-sha256
```

That is `ssh -v gns3@10.10.1.20`, and it is the one command to re-run whenever the OpenSSH pin
moves. ML-KEM-768 with X25519 is what OpenSSH 10 offers by default, and the node images' client
takes it.

**A machine built from the Windows capability instead** — `-PreferWindowsUpdate`, or anything
built before 20 September 2026 — runs an OpenSSH 9.x server that has no post-quantum key
exchange, and every connection to it prints:

```
** WARNING: connection is not using a post-quantum key exchange algorithm.
** This session may be vulnerable to "store now, decrypt later" attacks.
** The server may need to be upgraded. See https://openssh.com/pq.html
```

Nothing is broken there either: the client says so and connects anyway. But **an activity must
not tell students to expect that warning**, because on a current build they will not see one.
If an activity wants to talk about it, the honest framing is now the opposite — *this connection
is protected against store-now-decrypt-later, and here is how you can tell* — which in a
security unit is the better lesson anyway.
