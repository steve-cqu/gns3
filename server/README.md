# Building the CQU GNS3 VM (staff only)

How to turn a fresh GNS3 VM into the appliance handed out to students, and the staff
variant with the solution projects. One command does the build; you cut the OVA yourself.

Two appliances are produced from **one** VM, in this order:

| | Profile | Projects | Exported as |
|---|---|---|---|
| Student | `amd64-student` / `arm64-student` | the 7 in `projects-student.txt` | `GNS3-CQU-v<version>-student.ova` |
| Staff | `amd64-staff` / `arm64-staff` | those 7 **plus** the 17 in `projects-staff.txt` | `GNS3-CQU-v<version>-staff.ova` |

Staff is a superset of student — build the student VM, export it, then add the staff
projects to the same VM and export again. Never the other way round: a student OVA must
not contain solutions, and `export-check` (below) refuses to bless one that does.

**The profile names the GNS3 VM's architecture**, which is the only axis the build itself
varies on:

| Profile prefix | Docker | Qemu disks | Usual hypervisor |
|---|---|---|---|
| `amd64-*` | `linux/amd64` | amd64 | VirtualBox, on Windows or Linux |
| `arm64-*` | `linux/arm64/v8` | arm64 (`-arm64` templates) | VMware Fusion, on Apple Silicon |

The hypervisor is a **separate** concern and matters in exactly one place: `build.sh`
discovering the VM's IP. It defaults to VirtualBox for `amd64-*` and Fusion for `arm64-*`,
which covers the two setups in use, and `GNS3_HYPERVISOR=vbox|vmware` overrides that guess.
Anything else — Hyper-V on a Windows-on-ARM machine, a VM you reach over the network — needs
no support beyond `GNS3_VM_IP=<ip>`, since discovery is all that differs.

Naming the profiles by architecture rather than by machine (they were `pc-*`/`mac-*` until
July 2026) is what makes that separation expressible: nothing about an arm64 appliance is
Apple-specific.

The Docker images are always built **on the VM**, so they come out native for its
architecture — there is no cross-building. FRR and NETem are Docker nodes on both
architectures, since no arm64 Qemu images exist for them.

> **Tested status.** Both paths are validated live. `amd64` on VirtualBox through to exported
> student and staff OVAs; `arm64` on Apple Silicon through to a green `arm64-student` build and
> OVA, including `vmrun` IP discovery. Not yet exercised on a Mac: `verify=all` and a
> `arm64-staff` build.

---

## Before you start

**On your machine (the build host):**

- `ansible-core` (no Galaxy collections needed) and `rsync`. **PyYAML must be installed in
  the same python as `ansible-core`** — the playbook runs the control-node scripts with
  ansible's own interpreter, so a venv holding both (as below) always works, while
  `ansible` from a package manager plus `pip install pyyaml` somewhere else does not.
- **Either** an SSH key the VM accepts (`ssh-copy-id gns3@<vm-ip>` — recommended) **or**
  `sshpass` for the password login. The build and the verification tooling both probe for a
  working key first, so a key means you need `sshpass` nowhere.
- `VBoxManage` on the PATH for `amd64-*`, or `vmrun` + `ovftool` for `arm64-*`
- Both repos checked out side by side:
  - `gns3/` — this repo (public: build tooling, Dockerfiles, templates, logos)
  - `gns3-dev/` — the private repo (the `.gns3project` files and `tools/gns3_autotest.py`)
- The oversized projects that are too big for git, in `infiles/` alongside the repos.
  **SDN-Basics-Template.gns3project is 729 MB** and is not in either repo — you must have
  it locally or that project is skipped (with a clear `MISSING` line, not a failure).

### Setting up a PC build host

Ubuntu or another Debian derivative, from a fresh account:

```sh
# 1. Base tools. Ubuntu's rsync is the real thing, so nothing special is needed here.
#    sshpass is only a fallback for step 4 — harmless to install, unnecessary with a key.
sudo apt update
sudo apt install -y git rsync python3 python3-venv sshpass

# 2. VirtualBox, for VBoxManage (VM-IP discovery and the OVA export).
sudo apt install -y virtualbox

# 3. Build tooling in a venv, so ansible-core and PyYAML are not fighting apt's python.
python3 -m venv ~/gns3-build
source ~/gns3-build/bin/activate          # needed in every shell you build from
pip install ansible-core pyyaml

# 4. Give the VM your SSH key. With this, nothing in the build needs sshpass.
ssh-keygen -t ed25519                     # skip if the account already has a key
ssh-copy-id gns3@<vm-ip>

# 5. The repos, side by side.
mkdir -p ~/git && cd ~/git
git clone https://github.com/steve-cqu/gns3.git
git clone <gns3-dev remote>               # private: needs GitHub auth on this account

# 6. The oversized projects that git cannot hold, beside the repos.
mkdir -p ~/git/infiles                    # put SDN-Basics-Template.gns3project (729 MB) here
```

Check it took:

```sh
rsync --version | head -1
ansible --version | head -1
VBoxManage list runningvms
command -v sshpass
python3 -c 'import yaml; print("pyyaml ok")'
```

Two things worth knowing:

- **An SSH key makes `sshpass` unnecessary.** Both the playbook and `gns3_autotest.py` probe
  for a working key and only fall back to the password login. Step 1 installs `sshpass`
  anyway because it is one apt package and covers you if the key is not in place yet.
- **On Windows, build from WSL2**, not from PowerShell: Ansible does not support Windows as
  a control node. Follow the Ubuntu steps inside WSL, but note that `VBoxManage` there is the
  Windows executable — call it as `VBoxManage.exe`, or sidestep discovery altogether with
  `GNS3_VM_IP=<ip> ./build.sh …`. This has not been tested; the validated PC host is Ubuntu.

### Setting up a Mac build host

From a completely fresh macOS account, in order:

```sh
# 1. Command line tools (git, compilers). Opens a GUI installer; wait for it to finish.
xcode-select --install

# 2. Homebrew. On Apple Silicon it installs to /opt/homebrew, which is NOT on the PATH
#    until you add it — the installer prints this too, and skipping it is the usual
#    "brew: command not found" straight after a successful install.
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv)"

# 3. rsync and python. See the note below on why Homebrew's rsync is not optional.
brew install rsync python@3.12

# 4. Build tooling in a venv. Homebrew's python refuses `pip install` into itself
#    (PEP 668, "externally-managed-environment"), and a venv is cleaner than fighting it.
#    Install ansible-core HERE rather than with brew: the playbook runs the control-node
#    scripts under ansible's own interpreter, so ansible and PyYAML must share one.
python3 -m venv ~/gns3-build
source ~/gns3-build/bin/activate          # needed in every shell you build from
pip install ansible-core pyyaml

# 5. Fusion's two command-line tools. Neither is on the PATH, and they live in different
#    directories inside the app bundle: vmrun in Contents/Public, ovftool one level over
#    in Contents/Library. Add both, plus a helper that finds the VM you mean (see below).
cat >> ~/.zprofile <<'PROFILE'
export PATH="/Applications/VMware Fusion.app/Contents/Public:/Applications/VMware Fusion.app/Contents/Library/VMware OVF Tool:$PATH"

# Print the path of a VM's .vmx: a running one if there is a match, else search on disk.
# Usage: gns3vmx            -> first VM whose path contains "gns3"
#        gns3vmx v029-staff -> narrow it when several match
gns3vmx() {
    local pat="${1:-gns3}"
    { vmrun list | tail -n +2
      find "$HOME/Virtual Machines.localized" "$HOME/VMs" -maxdepth 3 \
           -name '*.vmx' 2>/dev/null
    } | grep -i -- "$pat" | head -1
}
PROFILE
source ~/.zprofile

# 6. Give the VM your SSH key, and install sshpass as a fallback. See the note below —
#    the key alone is enough, but sshpass is cheap insurance and Homebrew hides it in a tap.
ssh-keygen -t ed25519                     # skip if the account already has a key
ssh-copy-id gns3@<vm-ip>
brew install hudochenkov/sshpass/sshpass

# 7. The repos, side by side.
mkdir -p ~/git && cd ~/git
git clone https://github.com/steve-cqu/gns3.git
git clone <gns3-dev remote>               # private: needs GitHub auth on this account
```

Check it took — from the shell you will build in, with the venv active:

```sh
rsync --version | head -1                 # must be rsync 3.x, NOT openrsync
which ansible-playbook                    # must be ~/gns3-build/bin/ansible-playbook
ansible --version | grep -i 'python version'   # that interpreter is the one that needs PyYAML
which vmrun ovftool
gns3vmx                                   # should print your VM's .vmx path
python3 -c 'import yaml; print("pyyaml ok")'
```

**Why a function and not `export GNS3VMX=…`.** Fusion's default paths contain spaces and
the VM's name changes — new version, student vs staff, a clone made for an export — so a
path fixed in your profile goes stale silently and you build the wrong VM. `gns3vmx`
resolves it each time, preferring a running VM and falling back to a disk search, so it
works whether the VM is up (building) or shut down (exporting). Keep the quotes:

```sh
./build.sh "$(gns3vmx)" arm64-student
./build.sh "$(gns3vmx v029-staff)" arm64-staff
```

If your VMs live somewhere other than `~/Virtual Machines.localized` or `~/VMs`, add that
directory to the `find` line in the function.

Three things about macOS specifically:

- **Homebrew's `rsync` is not optional.** macOS 14.4 and later ship openrsync as
  `/usr/bin/rsync`, and the sync step reads `--itemize-changes` output to decide whether
  anything changed. Step 2 must come before step 3 for `/opt/homebrew/bin` to win the PATH.
- **`vmrun` is not on the PATH** by default, hence step 5. Without it `build.sh` cannot
  discover the VM's IP, though `GNS3_VM_IP=<ip>` works around that.
- **`sshpass` hides in a third-party tap.** Homebrew core omits it deliberately. The
  playbook and `gns3_autotest.py` both probe for a working ssh key first, so step 6's
  `ssh-copy-id` is what actually matters — but install `sshpass` too. It costs nothing, and
  a `gns3-dev` checkout predating the key probe still calls it for Open vSwitch nodes.

**Run `build.sh` from a shell with the venv active.** Forgetting it is the failure this
setup is most prone to, and it surfaces late: everything up to the project import runs on
the VM, so a control node with the wrong python gets an hour into the build before
complaining. The playbook now checks for this up front, but the check is only as good as the
shell you launched it from.

You can skip `infiles/` on a Mac. SDN-Basics-Template is 729 MB and amd64, so it cannot
run there regardless — the build logs `MISSING` and carries on.

**The VM:**

- A stock GNS3 VM 2.2.54, running, with SSH reachable and the GNS3 API on **port 80**
- Default login `gns3`/`gns3` with passwordless sudo. If you have changed it, set
  `GNS3_VM_PASSWORD`, or install an SSH key and set `ansible_ssh_private_key_file`.
- About **12 GB** free where GNS3 keeps its data (`/opt` on a stock VM): ~5.5 GB of Docker
  images after layer sharing, ~3.7 GB of Qemu disks, and ~2.3 GB of projects — most of
  that last figure being SDN-Basics-Template, which expands to 2.2 GB once imported

---

## 1. Build

From your own machine, not the VM:

```sh
cd gns3/server/ansible
./build.sh "GNS3 VM" amd64-student            # VirtualBox (PC)
./build.sh "$(gns3vmx)" arm64-student        # VMware Fusion (Apple Silicon)
```

`build.sh` finds the VM's IP from the hypervisor and runs the playbook. If discovery
fails or you already know the address, skip it:

```sh
GNS3_VM_IP=192.168.56.106 ./build.sh "GNS3 VM" amd64-student
```

That syncs this repo to the VM, builds every Docker image and downloads every Qemu disk,
registers the templates, installs the logos and noVNC, imports the student projects, and
finally runs a handful of activities against the live VM and **fails if any go red**.

The first build takes a while — 14 Docker images built from source (including a 2.9 GB
Kali) and about 3.7 GB of Qemu disks downloaded and checksummed. Everything is idempotent,
so a re-run does only what is outstanding: a fully-built VM re-runs in well under a second
per phase.

**Ansible prints nothing while a task runs**, so it looks stalled for the whole of that
first build. Both long phases are teed to logs — the playbook prints these commands before
it goes quiet:

```sh
ssh gns3@<vm-ip> 'tail -F /home/gns3/gns3build.log'   # the build phases, on the VM
tail -F ansible/gns3build-verify.log                  # the verification runs, here
```

Useful flags (anything after the profile is passed to `ansible-playbook`):

| | |
|---|---|
| `-e verify=all` | run every activity with a test manifest, not the 4-activity smoke set. Slow (tens of minutes) — **use this before cutting an OVA you will hand out** |
| `-e verify=none` | skip verification while iterating on the build itself |
| `--check` | dry run: reports what would change without changing anything |
| `-e gns3_dev_repo=/path/to/gns3-dev` | if the private repo is not beside this one |
| `-e extra_project_dir=/path/to/infiles` | if the oversized projects live elsewhere |

See [`ansible/README.md`](ansible/README.md) for the full option list.

---

## 2. Check before you export

Run these from your machine — they are also run automatically at the end of every build,
so a green build has already passed them.

```sh
ssh gns3@<vm-ip> '~/git/gns3/server/build/gns3build.py export-check --profile amd64-student'
```

It fails (exit 1) if the VM carries anything the audience must not ship, and reports:

- **LEAK** — a project from another audience is imported. A student OVA containing
  `*-Solution` projects is the failure this exists to prevent.
- **BROKEN** — a project references a Docker image or Qemu disk that is not installed, so
  its nodes cannot start. Warns by default; `--strict` makes it fail. See
  [Mac limitations](#mac-limitations) — this is expected there.
- **WARN** — a stray `.gns3project` left in `/home/gns3/projects`. Nothing imports it, but
  it still ships inside the OVA. Delete them: `rm -f /home/gns3/projects/*`.

The build also writes a provenance manifest to `/home/gns3/gns3-build-provenance.json` on
the VM (and fetches a copy to `ansible/provenance-<profile>.json`). It records the date,
profile, GNS3 and kernel versions, every Docker image ID, every Qemu disk md5, every
template and project, and the size + sha256 of each source `.gns3project` — including the
out-of-git 729 MB one, which nothing else records. Keep the fetched copy with the OVA:
without it, two `GNS3-CQU-*.ova` files are indistinguishable months later.

---

## 3. Cut the student OVA

Not automated — it is a single command and the VM has to be shut down anyway.

```sh
ssh gns3@<vm-ip> 'rm -f /home/gns3/projects/*'     # if export-check warned about staged files
```

**VirtualBox (PC):**

```sh
VBoxManage controlvm "GNS3 VM" acpipowerbutton     # or shut down from the VM's own menu
VBoxManage snapshot  "GNS3 VM" take "v<version>-student"
VBoxManage export    "GNS3 VM" -o GNS3-CQU-v<version>-student.ova
```

**VMware Fusion (Mac):**

`ovftool` ships with Fusion but is not on the PATH, and lives in a different directory from
`vmrun`:

```sh
export PATH="/Applications/VMware Fusion.app/Contents/Library/VMware OVF Tool:$PATH"
```

Note the order is the **reverse** of VirtualBox: `ovftool` will not export a VM that has
snapshots, so export first and snapshot afterwards.

```sh
vmrun stop "$(gns3vmx)" soft                    # graceful; `vmrun list` must not show it
ovftool --compress=9 "$(gns3vmx)" GNS3-CQU-v<version>-student-arm64.ova
vmrun snapshot "$(gns3vmx)" "v<version>-student"
```

To export a state you already snapshotted, clone it out rather than reverting — the clone
has no snapshots, and the original keeps its history:

```sh
vmrun listSnapshots "$(gns3vmx)"
vmrun clone "$(gns3vmx)" ~/VMs/GNS3-export.vmx full \
      -snapshot="v<version>-student" -cloneName="GNS3-export"
ovftool --compress=9 "$(gns3vmx GNS3-export)" GNS3-CQU-v<version>-student-arm64.ova
rm -rf ~/VMs/GNS3-export.vmwarevm                 # or delete it from Fusion
```

`--compress=9` roughly halves a ~10 GB appliance and costs several minutes.

**Name Mac appliances distinctly** — `-arm64`, as above. They import happily on an Intel
machine and then never boot, so a student who grabs the wrong file sees a broken download
rather than an obvious mismatch. The student instructions in
[`../vm/getting-started-mac.md`](../vm/getting-started-mac.md) tell them to look for the Mac
appliance; the filename is what makes that possible.

---

## 4. Add the staff projects and cut the staff OVA

Start the VM again, then re-run the build with the staff profile. Only the extra projects
are imported — everything else is already in place and skips:

```sh
cd gns3/server/ansible
./build.sh "GNS3 VM" amd64-staff -e verify=all              # VirtualBox
./build.sh "$(gns3vmx)" arm64-staff -e verify=all          # VMware Fusion
```

Then repeat step 2's checks with the staff profile and step 3's export, naming it
`GNS3-CQU-v<version>-staff.ova` (or `-staff-arm64.ova` on a Mac).

---

## Running phases individually

`build/gns3build.py` is the engine; the playbook is a thin wrapper around it. Run it on
the VM (`cd ~/git/gns3/server/build`):

```sh
./gns3build.py validate                       # check the manifest and every template
./gns3build.py plan      --profile amd64-staff   # show what would be installed, change nothing
./gns3build.py build     --profile amd64-staff   # all six phases below, in order
./gns3build.py templates --profile amd64-staff   # register templates via the GNS3 API
./gns3build.py docker    --profile amd64-staff   # build the Docker node images
./gns3build.py qemu      --profile amd64-staff   # download + verify the Qemu disks
./gns3build.py logos                          # install the CQU node symbols
./gns3build.py novnc                          # install noVNC + start-vnc.sh
./gns3build.py projects  --profile amd64-staff   # import the audience's projects
./gns3build.py export-check --profile amd64-staff
./gns3build.py provenance   --profile amd64-staff
```

Common options:

- `--only frrnode,netemnode` — work on just those nodes while iterating. On `build` it
  selects *phases* instead, and `--skip` leaves phases out.
- `--force` — rebuild an image or re-download a disk that is already present. **Needed
  after editing a Dockerfile**, since an existing image is otherwise skipped.
- `--dry-run` — print what would happen and change nothing.
- `qemu --verify` — re-hash disks already present instead of trusting their `.md5sum`
  sidecar (the sidecar check is what makes a re-run take 0.07 s instead of re-reading 3 GB).
- `projects --roots dirA,dirB` — where to look for `<Name>.gns3project`, searched
  recursively, **first match wins so order matters**. If a name resolves under more than
  one root the phase prints a `DUP` line naming the file used and the ones ignored. Heed
  it: stale exports can share a `project_id` with the rebuilt original, and because the
  ids match, importing one silently shadows the other. In particular do **not** put
  `gns3-dev/outfiles` before `gns3-dev/activities`.

`validate`, `plan`, `templates`, `projects`, `export-check` and `provenance` also accept
`--server http://<vm-ip>` and can be run from your own machine. `docker`, `qemu`, `logos`
and `novnc` must run on the VM itself, because they need its Docker daemon and filesystem
— which is also why images are always built natively for the VM's architecture.

Nothing edits `gns3_controller.conf` or restarts the GNS3 service. Templates are
registered through the REST API, which is additive and safe to repeat.

### What the manifest controls

`build/manifest.yml` is the single source of truth: which nodes each platform installs,
where each image comes from, the Qemu URLs and md5s, which templates each node registers,
the kernel modules the containers need, and which project lists each audience gets. Adding
a node means editing that file, not the code. `./gns3build.py validate` checks it, and
also cross-checks that every disk a Qemu template names is one its node actually installs.

---

## Mac builds

Note the first argument differs by hypervisor: `amd64-*` takes the VM **name**, `arm64-*` takes
a **path to the `.vmx`**.

```sh
source ~/gns3-build/bin/activate                        # every new shell — see setup above
cd ~/git/gns3/server/ansible
./build.sh "$(gns3vmx)" arm64-student
GNS3_VM_IP=<ip> ./build.sh "$(gns3vmx)" arm64-student   # if vmrun discovery misbehaves
```

Before building, confirm the VM is the one you think it is:

```sh
vmrun list                                    # running, and the .vmx path
curl -s http://<vm-ip>/v2/version             # port 80, expect 2.2.54
ssh gns3@<vm-ip> 'uname -m; df -h /opt'       # expect aarch64 and ~10 GB free
```

`aarch64` is the one that matters: the `arm64` profile builds Docker images **on the VM** so
they come out native, which only holds if the VM really is arm64.

A correct `arm64-student` build installs 14 Docker images, **3** Qemu disks and 18 templates
— three rather than the PC build's four because FRR and NETem are Docker on both
platforms. The disks should all be arm64 variants:

```
openwrt-23.05.0-armsr-armv8-generic-ext4-combined.img
OPNsense-24.1-ufs-efi-vm-aarch64.qcow2
ubuntu-24.04-server-cloudimg-arm64.img
```

### Mac limitations

The `arm64` profile builds arm64 Docker images and downloads arm64 Qemu disks. FRR and NETem
are Docker on both platforms (no arm64 Qemu images exist for them), so those activities
work everywhere and the templates keep the same names — activity instructions are
unchanged.

What does **not** work on a Mac VM: projects containing **amd64 Qemu** nodes. A
`.gns3project` stores each Qemu node's emulator and disk by name, so a project exported on
a PC carries `qemu_path: /usr/bin/qemu-system-x86_64` and an `…amd64.img` disk — neither of
which exists on an arm64 VM, whatever the templates say. Every project holding a Qemu node
is affected; all five currently do:

| Project | Qemu node(s) | Autotest |
|---|---|---|
| DHCP-Client-Solution | amd64 OpenWrt | `dhcp-client` |
| IPsec-Site-to-Site-Solution | 2 × amd64 OPNsense | `ipsec-site-to-site` |
| OPNsense-Firewall-Solution | amd64 OPNsense | `opnsense-firewall` |
| Small-Internet-Demo | amd64 OpenWrt | skipped (manual) |
| SDN-Basics-Template | amd64 Ubuntu cloud image | skipped (GUI) |

`export-check` reports these as `BROKEN` on a Mac build, and under `-e verify=all` the
first three fail with **`HTTP 403 Forbidden`** — GNS3's response when it cannot resolve a
node's emulator or disk. It logs nothing server-side, so the bare 403 is all you get; if
you see it on a Mac, this is why.

Fixing one means rebuilding it on a Mac against the arm64 templates — not something the
build can do for you. Everything else, which is every Docker-based activity, works normally.

**Where a rebuild goes.** Keep the project's *name* identical (the audience lists and
`export-check` match on it) and add `-arm64` to the *filename*:

```
activities/dhcp-client/DHCP-Client-Solution-arm64.gns3project
```

`platforms.arm64.project_suffix` in the manifest makes both the `projects` phase and
verification prefer `<Name>-arm64.gns3project` wherever one exists, falling back to the
plain file otherwise — so only the projects that genuinely differ need a variant. To test a
rebuild before wiring it into a build:

```sh
python3 -u gns3-dev/tools/gns3_autotest.py <slug> --project-suffix=-arm64 --server http://<vm-ip>
```

Note `--project-suffix=-arm64`, with the equals sign: a value starting with `-` is read as
an option name if passed as a separate argument.

Delete the project from the VM once exported. A hand-built copy is indistinguishable from a
wrongly imported one, so leaving a staff project on a student VM fails `export-check`.

### Why the arm64 Qemu templates carry `options`

Building topologies by hand from the arm64 Qemu templates does work, but only because
those templates set things their x86 counterparts can leave empty:

```
options: -machine virt -cpu cortex-a72 -bios /usr/share/qemu-efi-aarch64/QEMU_EFI.fd
hda_disk_interface: virtio
```

Three reasons, each of which stops the node dead within seconds if missed:

- **`-machine virt`** — `qemu-system-x86_64` defaults to machine `amd64`, but
  `qemu-system-aarch64` has *no* default and exits with "No machine specified, and there is
  no default for this architecture".
- **`-bios …`** — every arm64 image here boots via UEFI (OpenWrt `armsr` is ARM
  SystemReady, the OPNsense file is `…-ufs-efi-vm-aarch64`, and Ubuntu's arm64 cloud images
  have no legacy path). Without firmware Qemu runs with nothing to execute: a blank console
  and no error at all. The GNS3 VM already ships the firmware; if a future one does not,
  `apt install qemu-efi-aarch64`.
- **`virtio` disks** — the `virt` machine has no IDE controller, so the x86 templates'
  `hda_disk_interface: ide` fails with "machine type does not support if=ide".

Fusion on Apple Silicon also gives the guest no nested virtualisation — there is no
`/dev/kvm` — so these run under TCG emulation, slower than their PC equivalents. Set
`enable_kvm = false` in `gns3_server.conf` if a node complains about KVM.

**Editing a template is not enough on its own.** The `templates` phase keys on
`template_id`, so a changed `.conf` is skipped on a controller that already has it; push it
with `gns3build.py templates --profile arm64-student --force`. Existing *nodes* keep whatever
they were created with, so delete and re-add any node made before the change.

All three were booted on Apple Silicon on 2026-07-26 — the first time the arm64 Qemu path
had ever run. Logins:

| Node | Login | Notes |
|---|---|---|
| OpenWRT | none | boots straight to a shell |
| Ubuntu VM | `ubuntu` / `ubuntu` | set by the cloud-init ISO. `systemd-networkd-wait-online` stalls for its full timeout on an unconnected interface, then boot continues — not a fault |
| OPNsense | `root` / `opnsense` | slow under TCG. Boot ends at the interface assignments and the GUI certificate fingerprint; the console then goes quiet because the interactive menu is on a video tty the `virt` machine has no equivalent for. Configure it through the web GUI on the LAN address instead |

---

## The previous manual build

Until July 2026 this directory held a set of shell scripts run by hand on the VM —
`vm-install-nodes.sh`, `vm-install-containers.sh`, `vm-install-qemuvms.sh`,
`vm-install-templates.sh`, `vm-install-logos.sh`, `vm-install-vnc.sh`,
`vm-import-projects.sh` — driven by `nodelist-{pc,mac}.txt` and the
`templates_*.conf` bundles. Every one of them is now a `gns3build.py` phase, so they were
removed once both OVAs had been built and verified by the pipeline. `git log --diff-filter=D`
finds them if you ever need to look.

Nothing was lost in the move: every template in the old bundles is in `templates/`, and
every node in the old nodelists is in `manifest.yml`. The manifest also carries nodes the
nodelists lacked — notably `ubuntu-cloud`, whose absence meant SDN-Basics-Template's
controller node could never start on a VM built the old way.

The rewrite also fixed what the scripts got wrong: no idempotency (`docker build
--no-cache` every time, Qemu images re-downloaded on every run), a hardcoded `python3.9`
path for the logos, and hand-assembly of `gns3_controller.conf` with a `head -n -1` to
strip a trailing comma, in place of the REST API.

---

## Troubleshooting

**`export-check` says a project belongs to another audience.** You are building a student
OVA on a VM that already has staff projects. Delete them through the GNS3 GUI or the API
(`DELETE /v2/projects/<id>`), or start from a clean VM snapshot.

**A node fails to start after a rebuild.** If you edited a Dockerfile, the image is only
rebuilt with `--force` — an existing image is skipped by design.

**`projects` reports MISSING for SDN-Basics-Template.** It is not in git; put the 729 MB
file in `infiles/` or pass `-e extra_project_dir=...`.

**`projects` fails with `HTTP 409 ... invalid zip`.** The controller could not extract the
archive. The phase then tests the file locally and tells you which side is at fault: a
corrupt or unreadable local copy, or a clean file and therefore a server-side problem
(usually no space on the VM — these projects expand to several times their stored size).

The out-of-git projects in `infiles/` are the ones this happens to, because nothing checks
their integrity between builds. Every successful build records their size and sha256 in
`ansible/provenance-<profile>.json`, so compare against that:

```sh
sha256sum infiles/SDN-Basics-Template.gns3project
python3 -c "
import json,glob
for f in glob.glob('ansible/provenance-*.json'):
    for s in json.load(open(f)).get('sources',[]):
        print(f, s['name'], s['bytes'], s['sha256'])
"
```

That record is the only durable statement of what those files should be — which is the
reason it exists.

**The playbook reports no hosts matched.** `build.sh` refuses to continue in that case
rather than reporting a successful build that did nothing. Check the VM name/`.vmx` path,
or use `GNS3_VM_IP=`.

**`rsync: Failed to exec sshpass`.** You have no SSH key for the VM and no `sshpass`.
Either `ssh-copy-id gns3@<vm-ip>` (preferred) or install `sshpass`. The playbook now
detects this before the sync and says so plainly.

**`HTTP 403 Forbidden` from a Qemu node, on a Mac.** GNS3 could not resolve that node's
emulator or disk image, and logs nothing about it. Almost always the project was exported
on a PC and holds `qemu_path: /usr/bin/qemu-system-x86_64`; see **Mac limitations**. Check
with:

```sh
python3 -c 'import zipfile,json,sys; z=zipfile.ZipFile(sys.argv[1]); \
  d=json.loads(z.read([n for n in z.namelist() if n.endswith("project.gns3")][0])); \
  print([(n["name"], n["properties"].get("platform")) for n in d["topology"]["nodes"] \
  if n["node_type"]=="qemu"])' <file>.gns3project
```

**Verification fails.** `-e verify=none` gets you a build for debugging, but do not export
an appliance that has not passed `-e verify=all`. On a Mac, `dhcp-client`,
`ipsec-site-to-site` and `opnsense-firewall` fail inherently — see above — so `verify=all`
cannot go green there until those projects are rebuilt for arm64.
