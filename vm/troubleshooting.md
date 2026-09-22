# Troubleshooting

Things that go wrong with the appliance, and what to do about them. Each entry names the error as
you will actually see it, so searching this page for the text on your screen should find it.

**Three layers, and they fail independently.** Most confusion here comes from fixing the wrong one:

| Layer | What it is |
|---|---|
| Your computer | The host running VirtualBox or VMware |
| The GNS3 VM | The appliance itself — one virtual machine |
| A node | A container or Qemu VM *inside* a topology |

A fix applied to one does nothing for the others, and a node keeps its own state once it has
started. When in doubt, work down the list in that order.

**Before anything else, confirm which release you are running.** A renamed `.ova` proves nothing,
and several fixes below depend on the appliance version:

```sh
cat /etc/gns3-cqu-release
```

---

## Importing and starting the appliance

### Import of the appliance (.ova) fails

**Applies to:** PC (VirtualBox) and Mac (VMware)

If importing the `.ova` produces an error, the two common causes are insufficient disk space and a
corrupt download.

Once the `.ova` is on your computer you need at least another 15 GB free. Importing unzips several
large disk images, and depending on the projects included in the GNS3 VM they may need 15 to 20 GB
(or more). If your disk is close to full — less than 20 GB remaining — expect errors, and free up
space before trying again.

You can delete the `.ova` *after* a successful import, though you may want to download it again
later to get back to a clean appliance.

A corrupt `.ova` usually means the download was interrupted. Check with your teacher or colleagues
to confirm the expected file size.

*Verified 22 September 2026.*

### The VM will not start: network adapter errors

**Applies to:** PC (VirtualBox)

Two versions of the same fault. Either the VM refuses to start with a message about network
adapters, or — commonly the first time you import — it reports that a host-only interface such as
`vboxnet0` cannot be found:

![Error Vboxnet0 interface not found](../images/vbox-error-vboxnet-not-found-1.png)

The adapter information saved inside the appliance does not match the host-only networks your copy
of VirtualBox actually has. Importing an appliance exported on a different operating system — a
Windows host to a Linux one, say — is a common way to end up here.

**Fix.** Stop the VM, open *Settings → Network*, click the *Adapter 1* tab and then the *Adapter 2*
tab, and press *OK*. Visiting both tabs refreshes the adapter information to match your machine.

![VirtualBox Settings Network Adapters](../images/vbox-network-adapters-1.png)

You can ignore any 'Invalid settings detected' message. Now start the VM again.

If that does not fix it, check that Adapter 1 is Host-only and Adapter 2 is NAT, and that the
host-only network itself exists — see
[Host-only Networks in VirtualBox](./virtualbox.md#host-only-networks-in-virtualbox).

*Verified 22 September 2026.*

---

## Starting nodes

### `KVM acceleration cannot be used (/dev/kvm doesn't exist)`

**Applies to:** Qemu nodes only — OpenWRT, OPNsense. Docker nodes are unaffected, so most
activities still work.

Your host has no nested virtualisation to pass through to the GNS3 VM. The usual causes are a
managed Windows laptop where Credential Guard or memory integrity keeps Hyper-V holding VT-x, so
VirtualBox cannot pass it on; and VMware Fusion on Apple Silicon, which has none to give.

**Appliances built from August 2026 onwards already carry the fix** — the build's `accel` phase
writes it. Check before changing anything:

```sh
grep -A2 '\[Qemu\]' ~/.config/GNS3/2.2/gns3_server.conf
```

If that shows `require_kvm = false`, this is not your problem and the error means something else.

**Fix.** In the GNS3 server — the hypervisor's terminal window — enter a shell and edit the config:

```sh
nano ~/.config/GNS3/2.2/gns3_server.conf
```

Add these lines at the bottom:

```
[Qemu]
require_kvm = false
```

Save and start the node again. No restart of the GNS3 service is needed; it watches this file and
reloads within about a second.

> **Use `require_kvm`, not `enable_kvm`.** This was documented as `enable_kvm = false` until August
> 2026, which works but is the wrong lever. `require_kvm = false` keeps hardware acceleration
> wherever it exists and only falls back to emulation where it does not; `enable_kvm = false` turns
> acceleration off everywhere, including on machines that have it. OPNsense boots in about 20
> seconds with KVM and takes minutes without, so the difference is worth having. On Linux the older
> `enable_kvm`/`require_kvm` names override the newer
> `enable_hardware_acceleration`/`require_hardware_acceleration` ones, which is why a stray
> `enable_kvm = false` left in this file silently makes everything slow.

*Verified 22 September 2026, appliance v035.*

---

## Inside a node

### A node's date is wrong by years, breaking Python, TLS or login

**Applies to:** Qemu nodes (OPNsense, OpenWRT) most severely; any node in principle

A node reports a date far in the future or the past — a year such as 2319 rather than the current
one. Anything that checks a certificate's validity window then fails, because every certificate
looks either expired or not yet valid. Python scripts error, TLS connections are refused, and login
can stop working entirely.

**Check all three clocks, in order.** They are independent.

1. **Your computer.** Confirm its own clock and time zone are right.

2. **The GNS3 VM.** You do not need to log in — from the machine running the GNS3 web interface:

   ```sh
   curl -sI http://<gns3-vm-ip>/v2/version | grep -i date
   ```

   That returns the appliance's clock in GMT, so add 10 hours for AEST.

3. **The node.** Run `date` at its console.

**Fix.** Correct the GNS3 VM first, then **stop and start the node**. A node takes its start time
from the appliance when it boots and keeps its own clock afterwards, so correcting the VM does
nothing for a node that is already running — it has to be restarted to pick the new time up.

If the node is still wrong after a restart, set it at the console. OPNsense is FreeBSD, which takes
`CCYYMMDDhhmm.ss`:

```sh
date 202609221830.00
```

**Take that value from your phone or your computer — never read it off a clock you already know is
wrong.** Copying a time out of the broken clock is an easy way to end up further out than you
started.

**Why.** A Qemu node keeps time by counting on emulated hardware, and that is much less accurate
where the host cannot offer KVM — see the `/dev/kvm` entry above. Where the emulated timer is
mis-calibrated the node's clock does not merely drift, it runs away, which is how a node ends up
centuries out rather than minutes.

*Reported September 2026. The GNS3 VM check above is verified; the node-side fix has not yet been
confirmed against a node actually showing this fault.*

---

## Still stuck

- The guide for your hypervisor — [VirtualBox](./virtualbox.md) or [VMware](./vmware.md) — covers
  settings and networking.
- [Using the GNS3 web interface](./using-gns3.md) covers topologies, consoles and importing a
  project.
- [Saving your work](./gns3-saving-work.md) explains why configuration on a node disappears when a
  project is closed. That is expected behaviour, not a fault.

At CQU, ask on your unit's discussion forum, and say which release
(`cat /etc/gns3-cqu-release`) and which hypervisor you are running.
