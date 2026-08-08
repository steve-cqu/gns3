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
| `configure-windows-host.ps1` | inside the Windows VM, as Administrator | Turns a fresh Windows 11 install into a usable lab node: allows inbound ping, installs and starts the OpenSSH server, enables Remote Desktop, marks the lab adapter Private, optionally sets a static address and hostname, and stops the machine sleeping. Idempotent; `-DryRun` reports without changing. |

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
on the lab network), then in an Administrator PowerShell inside that VM:

```powershell
# see what it would do
.\configure-windows-host.ps1 -DryRun

# do it
.\configure-windows-host.ps1 -ComputerName WinHost
```

Leave `-IPAddress` off if the topology runs a DHCP server. To set an address by hand:

```powershell
.\configure-windows-host.ps1 -LabAdapter "Ethernet 2" -IPAddress 192.168.10.50 -ComputerName WinHost
```

The script picks the lab adapter automatically as the one with no default gateway, and
prints every adapter's name if it cannot decide.

**Windows licensing.** Students download the Windows 11 ISO themselves from Microsoft — x64
and ARM64 are both free direct downloads. A key from CQU's Azure account is optional:
unactivated Windows 11 runs indefinitely, with a desktop watermark and no personalisation,
neither of which matters for lab work.
