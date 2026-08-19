# Building the CQU GNS3 VM (staff only)

How to turn a fresh GNS3 VM into the appliance handed out to students. One command does the
build; you cut the OVA yourself.

**One appliance per architecture**, given to staff and students alike:

| Profile | Projects | Exported as |
|---|---|---|
| `amd64` | the 5 in `projects.txt` | `GNS3-CQU-v<version>.ova` |
| `arm64` | the same 5, preferring any `-arm64` rebuild | `GNS3-CQU-v<version>-arm64.ova` |

There used to be a second, staff-only appliance carrying the 17 solution projects — four
OVAs a release and two export passes, for a few megabytes of project data. It was retired in
August 2026. Solutions now reach staff through Moodle, like every other handout.

**What ships on the appliance is demonstration projects only.** The templates students
complete, and the solutions, are downloaded and imported — importing a `.gns3project` is two
clicks. The consequence is worth stating plainly, because it is easy to get backwards:

> The appliance is the **runtime**, not the content. It must be able to run *every* activity,
> not just the five projects it carries. Never trim the image set in `manifest.yml` to match
> `projects.txt` — `ubuntu-cloud` is installed for a project nobody ships, and a student who
> imports `SDN-Basics-Template` needs it there.

Because `export-check` only inspects the projects the appliance ships, it can no longer prove
the image set covers everything. **`-e verify=all` is what proves that** — it imports each
activity from `gns3-dev` and exercises it. Run it before cutting a release.

**The profile names the GNS3 VM's architecture**, which is the only axis the build varies on:

| Profile | Docker | Qemu disks | Usual hypervisor |
|---|---|---|---|
| `amd64` | `linux/amd64` | amd64 | VirtualBox, on Windows or Linux |
| `arm64` | `linux/arm64/v8` | arm64 (`-arm64` templates) | VMware Fusion, on Apple Silicon |

The hypervisor is a **separate** concern and matters in exactly one place: `build.sh`
discovering the VM's IP. It defaults to VirtualBox for `amd64` and Fusion for `arm64`,
which covers the two setups in use, and `GNS3_HYPERVISOR=vbox|vmware` overrides that guess.
Anything else — Hyper-V on a Windows-on-ARM machine, a VM you reach over the network — needs
no support beyond `GNS3_VM_IP=<ip>`, since discovery is all that differs.

Naming the profiles by architecture rather than by machine (they were `pc-*`/`mac-*` until
July 2026) is what makes that separation expressible: nothing about an arm64 appliance is
Apple-specific.

The Docker images are always built **on the VM**, so they come out native for its
architecture — there is no cross-building. FRR and NETem are Docker nodes on both
architectures, since no arm64 Qemu images exist for them.

> **Tested status.** Both paths were validated live under the previous two-appliance scheme:
> `amd64` on VirtualBox through to exported OVAs, `arm64` on Apple Silicon through to a green
> build and OVA including `vmrun` IP discovery. `verify=all` has never been exercised on a Mac.
> The single-appliance change (August 2026) has not yet been run end to end on hardware — it
> touches the project list and the export gate, not any image phase, but the first build after
> it should be treated as a validation run.

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
- `VBoxManage` on the PATH for `amd64`, or `vmrun` + `ovftool` for `arm64`
- Both repos checked out side by side:
  - `gns3/` — this repo (public: build tooling, Dockerfiles, templates, logos)
  - `gns3-dev/` — the private repo (the `.gns3project` files and `tools/gns3_autotest.py`)

`infiles/` is **no longer needed to build the appliance.** Every project on `projects.txt` is
committed to `gns3-dev`, so a fresh checkout of the two repos is the whole prerequisite. The
729 MB `SDN-Basics-Template.gns3project` still lives out of git in `infiles/` and is still
worth having on the build host if you want to test that import by hand, but its absence no
longer changes what the appliance contains.

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
the VM's name changes — a new version, a clone made for an export — so a path fixed in your
profile goes stale silently and you build the wrong VM. `gns3vmx` resolves it each time,
preferring a running VM and falling back to a disk search, so it works whether the VM is up
(building) or shut down (exporting). Keep the quotes:

```sh
./build.sh "$(gns3vmx)" arm64
./build.sh "$(gns3vmx v030)" arm64        # a named VM, when you keep more than one
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

**The VM:**

- A stock GNS3 VM, running, with SSH reachable and the GNS3 API on **port 80**. Built and
  verified on 2.2.54 and 2.2.61; the two differ in where `gns3_server.conf` lives, which the
  build discovers rather than assumes (see
  [Which `gns3_server.conf`](#which-gns3_serverconf--the-phase-discovers-it))
- **arm64 is capped at 2.2.54, and that is upstream's decision, not a choice made here.**
  GNS3 ships the ARM64 VM as a release asset on `GNS3/gns3-gui`, and
  `GNS3.VM.ARM64.2.2.54.zip` (v2.2.54, 21 Apr 2025) is the last one: every release from 2.2.55
  on carries only the Hyper-V, KVM, VirtualBox, ESXi and VMware Workstation images, and the
  ARM64 image in the older `GNS3/gns3-vm` repo stops at v0.15.0 (Feb 2024). Checked against the
  releases API 17 Aug 2026. So the two appliances are built on different GNS3 versions, and the
  build supports that rather than levelling them down — see
  [Two appliances, two GNS3 versions](#two-appliances-two-gns3-versions)
- Default login `gns3`/`gns3` with passwordless sudo. If you have changed it, set
  `GNS3_VM_PASSWORD`, or install an SSH key and set `ansible_ssh_private_key_file`.
- About **10 GB** free where GNS3 keeps its data (`/opt` on a stock VM): ~5.5 GB of Docker
  images after layer sharing, ~3.7 GB of Qemu disks, and well under 100 MB of projects.
  It was ~12 GB until SDN-Basics-Template came off the appliance; that one project expanded
  to 2.2 GB on import

---

## 1. Build

From your own machine, not the VM:

```sh
cd gns3/server/ansible
./build.sh "GNS3 VM" amd64            # VirtualBox (PC)
./build.sh "$(gns3vmx)" arm64        # VMware Fusion (Apple Silicon)
```

`build.sh` finds the VM's IP from the hypervisor and runs the playbook. If discovery
fails or you already know the address, skip it:

```sh
GNS3_VM_IP=192.168.56.106 ./build.sh "GNS3 VM" amd64
```

That syncs this repo to the VM, builds every Docker image and downloads every Qemu disk,
registers the templates, installs the logos and the noVNC gateway, imports the projects named in
`projects.txt`, and finally runs a handful of activities against the live VM and **fails if
any go red**.

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
| `-e verify=all` | run every activity with a test manifest, not the 4-activity smoke set. Slow (tens of minutes) — **use this before cutting an OVA you will hand out.** It is now the only check that the appliance can run the activities students import themselves, since `export-check` sees only the five it ships |
| `-e verify=none` | skip verification while iterating on the build itself |
| `--check` | dry run: reports what would change without changing anything |
| `-e gns3_dev_repo=/path/to/gns3-dev` | if the private repo is not beside this one |
| `-e extra_project_dir=/path/to/infiles` | if the oversized projects live elsewhere |
| `-e qemu_cache=/path/to/QEMU` | seed the Qemu disks from a local folder instead of downloading them — see below |

See [`ansible/README.md`](ansible/README.md) for the full option list.

### Building from a local Qemu cache

The `qemu` phase skips any disk already in `qemu_images_dir` on the VM whose `.md5sum`
sidecar matches the manifest:

```
skip   OPNsense-24.1-nano-amd64.img       (sidecar, 3.0 GiB)
```

That makes a rebuild of an existing VM free. It does nothing for a **fresh** VM, though,
where the copies you already have are on *your* machine — so the build pulls ~3.7 GB again
from SourceForge, a community mirror and a personal GitHub release. Point it at them
instead:

```sh
./build.sh "GNS3 VM" amd64 -e qemu_cache=~/gns3-archive/gns3-v030/QEMU
```

They are rsynced to the VM before the build, and the phase then reports every one as
`skip`. The folder can be one you assembled by hand or one restored from a release archive
(`qemu-images-vNNN-<arch>.tar` — see [`RESTORE.md`](RESTORE.md)); files arriving **without**
a sidecar are still md5-verified against the manifest, so a hand-made cache is exactly as
safe, it just re-hashes once.

The seed does not use `--delete` — it adds to the VM's images without removing anything
that is only there. Note the sidecars matter for `ubuntu-cloud`, which the build `resize`s
after verification: its md5 no longer matches the manifest afterwards, and the sidecar is
what records that it was verified before being mutated. Copy sidecars with the images.

This matters more over time than it does today. It is the difference between a 2028 rebuild
that works offline and one that depends on three third-party hosts still being up.

---

## 2. Check before you export

Run these from your machine — they are also run automatically at the end of every build,
so a green build has already passed them.

```sh
ssh gns3@<vm-ip> '~/git/gns3/server/build/gns3build.py export-check --profile amd64'
```

It fails (exit 1) unless the appliance carries **exactly** `projects.txt`, and reports:

- **UNLISTED** — a project is imported, or a `.gns3project` is staged in
  `/home/gns3/projects`, that is not on the list. This is the one that matters: the appliance
  is public, and a solution opened to answer a student's question is one export away from
  shipping. Delete it, or add it to `projects.txt` if it genuinely belongs there.
  (`rm -f /home/gns3/projects/*` clears staged files.)
- **BROKEN** — a project references a Docker image or Qemu disk that is not installed, so
  its nodes cannot start. Warns by default; `--strict` makes it fail. See
  [Mac limitations](#mac-limitations).
- **INCOMPLETE** — a project on the list did not make it in, usually because its file was
  not under any root. Reported, not fatal.

**Run it on the VM, as above.** It also accepts `--server http://<vm-ip>` from your own
machine, but staged `.gns3project` files are a question about the *VM's disk* and nothing
over the API can see them — so a remote run reports `staged files NOT CHECKED` and ends in
`PARTIAL` rather than `OK`. Treat `PARTIAL` as "not yet gated". The image checks work either
way: they ask the controller what it has installed (`/v2/computes/local/{qemu,docker}/images`)
rather than reading the local filesystem, which until August 2026 they did — so a remote run
used to invent BROKEN lines for disks the appliance had all along.

Until August 2026 this compared the VM against the *other* audience's list, so it only ever
caught a staff solution on a student OVA. With one appliance there is no other list, so the
rule is now exact-match — which is stricter, not looser: anything unplanned fails.

Note what it does **not** prove. It inspects the five projects the appliance ships, so it
says nothing about whether the image set still runs the activities students download for
themselves. Only `-e verify=all` shows that.

One thing to eyeball by hand, because no phase can: open `http://<vm-ip>:6080/` in a browser.
It should render the VNC-node page (an empty list is correct when no project is open). That
is the whole of the student's VNC workflow — see [Reaching a VNC node](#reaching-a-vnc-node).

The build also writes a provenance manifest to `/home/gns3/gns3-build-provenance.json` on
the VM (and fetches a copy to `ansible/provenance-<profile>.json`). It records the date,
profile, GNS3 and kernel versions, whether the appliance's auto-update units are masked and
whether it has a pending reboot, whether Qemu acceleration is genuinely in effect (below),
the commit of **both** repositories, every Docker image ID, every Qemu disk md5, every
template and project, and the size + sha256 of each source `.gns3project`. Keep the fetched
copy with the OVA: without it, two `GNS3-CQU-*.ova` files are indistinguishable months later.

The `qemu_accel` block is the one that reports rather than describes — it re-reads the config
file the server actually loads and says whether the setting is *there*:

```
  accel        applied: [Qemu] require_kvm = false in /opt/gns3/server/gns3_server.conf
               ignored (not read by this server): /home/gns3/.config/GNS3/2.2/gns3_server.conf
```

`NOT APPLIED` **fails the phase** (exit 1), on the same footing as a missing Docker image: a
Qemu node that will not start on a student's laptop is a broken appliance, and unlike a
missing image nothing else in the build would notice. This exists because it happened — see
[Which `gns3_server.conf`](#which-gns3_serverconf--the-phase-discovers-it). `applied` is also
allowed to be `null`, meaning the config file was not found at all, which is what a
`provenance` run from a control node rather than the VM looks like; that does not fail.

The two commits are read in different places, because the phases run in different places —
this repository on the VM, and each projects root (`gns3-dev`) on the control node during
`projects --record`. Either one showing `DIRTY` in the phase output means that tree had
uncommitted changes, so the recorded commit does not describe what was built.

### Releasing a build

A build becomes a *release* when it goes out to students. Add `-e release=<version>`:

```sh
./build.sh "GNS3 VM" amd64 -e release=v030
```

That labels the provenance manifest, files a copy under `releases/<version>/` where it is
committed rather than gitignored, and stamps `/etc/gns3-cqu-release` (plus the motd) on the
appliance so it can name itself — the check to give a student who has been told "use v030
this term, not v027". It also warns if either work tree was dirty.

Leave the flag off for a test build. Not every build is released: version numbers count
builds, so the released sequence has gaps.

The full checklist — including tagging both repositories, which the build cannot do for you
— is in [`RELEASES.md`](../RELEASES.md), along with the record of what each cohort was
given.

### Freezing the image set — `freeze` / `thaw`

Pinning inputs makes a rebuild *likely* to reproduce. Freezing the output makes it *certain*,
and it is the only one of the two that survives an upstream going away — which over an
appliance's life is the more probable failure. Once a build is verified:

```sh
python3 server/build/gns3build.py freeze --profile amd64 \
        --out /home/gns3/frozen-v030-amd64.tar.gz
```

That `docker save`s every image the profile ships (20 on amd64, checked 17 Aug 2026 — take it
from `plan --profile amd64` rather than this line) through gzip in one pass, and
writes a `.json` sidecar recording the profile, the date, the archive's sha256 and **each
image's ID** — two archives can carry the same `:latest` tags and different bytes, and the
sidecar is what says which. Keep both files with the OVA.

A later rebuild then restores instead of rebuilding, with no network and no upstream involved:

```sh
python3 server/build/gns3build.py thaw --in /home/gns3/frozen-v030-amd64.tar.gz
```

`thaw` verifies the archive against the sidecar (skip with `--skip-verify`; it is several GB),
loads it, and then checks that every expected image is actually present — a load that silently
dropped one is the failure worth catching, because everything downstream still succeeds and one
node type is simply absent. After a successful `thaw`, run the remaining phases **on the VM**
with the `docker` phase skipped:

```sh
python3 server/build/gns3build.py build --profile amd64 \
        --skip docker,projects --server http://localhost
```

(`projects` is skipped because it runs from the control node, which is what `build.sh` does for
you — see *Running phases individually*.)

Neither is part of `build` — freezing is a release step, not a build phase, and it must happen
*after* verification, never before. Freezing a half-built or unverified set is worse than not
freezing, because it looks authoritative.

**What freeze does not cover:** the Qemu disk images. They are already pinned by URL *and* md5,
but several are hosted on SourceForge, a community mirror and a personal GitHub release, any of
which can 404 over a couple of years. Archive `qemu_images_dir` alongside the frozen Docker
archive and the same guarantee extends to them.

### Archiving a release — `archive-release.sh`

One command does the whole thing: freeze the images, tar the Qemu disks, bundle both repos,
copy in the OVAs and the upstream GNS3 VM, add `RESTORE.md` and checksum the lot.

```sh
server/archive-release.sh v030 ~/archive --vm-host <vm-ip> \
    --ova ~/ova/gns3-cqu-v030-amd64.ova \
    --vm-appliance ~/Downloads/GNS3VM.VirtualBox.0.15.0.zip
```

Run it **once per architecture** into the same output directory (`--arch arm64 --vm-host <arm64
vm>` for the second), then copy the folder to the shared drive and check it landed intact with
`sha256sum -c SHA256SUMS`. `--dry-run` prints what it would do. It warns rather than proceeding
silently when a work tree is dirty, a repo has no tag for the version, or the OVAs are missing.

[`RESTORE.md`](RESTORE.md) is copied in by that script and is what a future reader follows — the
folder layout, which of the three restore paths to use, and how to verify the result. **Fill in
its header**, because in two years nobody will remember this section exists.

---

## 3. Cut the OVA

Not automated — it is a single command and the VM has to be shut down anyway.

```sh
ssh gns3@<vm-ip> 'rm -f /home/gns3/projects/*'     # if export-check warned about staged files
```

**VirtualBox (PC):**

```sh
VBoxManage controlvm "GNS3 VM" acpipowerbutton     # or shut down from the VM's own menu
VBoxManage snapshot  "GNS3 VM" take "v<version>"
VBoxManage export    "GNS3 VM" -o GNS3-CQU-v<version>.ova
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
ovftool --compress=9 "$(gns3vmx)" GNS3-CQU-v<version>-arm64.ova
vmrun snapshot "$(gns3vmx)" "v<version>"
```

To export a state you already snapshotted, clone it out rather than reverting — the clone
has no snapshots, and the original keeps its history:

```sh
vmrun listSnapshots "$(gns3vmx)"
vmrun clone "$(gns3vmx)" ~/VMs/GNS3-export.vmx full \
      -snapshot="v<version>" -cloneName="GNS3-export"
ovftool --compress=9 "$(gns3vmx GNS3-export)" GNS3-CQU-v<version>-arm64.ova
rm -rf ~/VMs/GNS3-export.vmwarevm                 # or delete it from Fusion
```

`--compress=9` roughly halves a ~10 GB appliance and costs several minutes.

**Name Mac appliances distinctly** — `-arm64`, as above. They import happily on an Intel
machine and then never boot, so a student who grabs the wrong file sees a broken download
rather than an obvious mismatch. The student instructions in
[`../vm/getting-started-mac.md`](../vm/getting-started-mac.md) tell them to look for the Mac
appliance; the filename is what makes that possible.

That is the whole export. There is no second pass: the staff appliance was retired in
August 2026, and staff use the same OVA as students.

---

## Running phases individually

`build/gns3build.py` is the engine; the playbook is a thin wrapper around it. Run it on
the VM (`cd ~/git/gns3/server/build`):

```sh
./gns3build.py validate                    # check the manifest and every template
./gns3build.py plan      --profile amd64   # show what would be installed, change nothing
./gns3build.py build     --profile amd64   # all nine phases below, in order
./gns3build.py templates --profile amd64   # register templates via the GNS3 API
./gns3build.py docker    --profile amd64   # build the Docker node images
./gns3build.py qemu      --profile amd64   # download + verify the Qemu disks
./gns3build.py accel                       # Qemu acceleration in gns3_server.conf
./gns3build.py quiesce                     # mask Ubuntu's unattended-upgrade timers
./gns3build.py logos                       # install the CQU node symbols
./gns3build.py novnc                       # install noVNC + the gns3-novnc service
./gns3build.py labnic                      # the Windows Host lab NIC (eth2)
./gns3build.py projects  --profile amd64   # import the projects in projects.txt
./gns3build.py export-check --profile amd64
./gns3build.py provenance   --profile amd64
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
`--server http://<vm-ip>` and can be run from your own machine — though `export-check` can
only half-answer from there and says so (see [Check before you export](#2-check-before-you-export)). `docker`, `qemu`, `logos`,
`novnc`, `labnic` and `quiesce` must run on the VM itself, because they touch its Docker
daemon, filesystem and systemd — which is also why images are always built natively for the
VM's architecture.

Nothing edits `gns3_controller.conf` or restarts the GNS3 service. Templates are
registered through the REST API, which is additive and safe to repeat.

### What the manifest controls

`build/manifest.yml` is the single source of truth: which nodes each platform installs,
where each image comes from, the Qemu URLs and md5s, which templates each node registers,
and the kernel modules the containers need. (The projects are the one thing it does *not*
name — they live in `projects.txt` beside it.) Adding a node means editing the manifest, not
the code. `./gns3build.py validate` checks it, and
also cross-checks that every disk a Qemu template names is one its node actually installs.

### Optional nodes — retiring one without deleting it

A node whose job has moved elsewhere is **retired, not deleted**: it keeps its `nodes:` entry, its
download URL and md5, and its `templates/*.conf`, and moves out of its platform's `qemu:` (or
`docker:`) list into `optional:`.

```yaml
platforms:
  amd64:
    qemu:   [opnsense]
    optional:
      qemu: [openwrt, ubuntu-cloud, frr-qemu, netem-qemu]
```

Nothing installs an optional node. Every phase that installs or registers something takes `--with`
to put one back for a single build:

```sh
./gns3build.py plan  --profile amd64                    # what a normal build ships,
                                                        # and what it could
./gns3build.py build --profile amd64 --with openwrt     # this build also gets the Qemu OpenWRT
./gns3build.py qemu  --profile amd64 --with all         # every optional node
./gns3build.py templates --profile amd64 --with ubuntu-cloud --force
```

`--with` names a node key, not a template; naming something that is not optional on that platform is
an error rather than a no-op, because it is nearly always a node that was deleted outright or a typo.

That is what makes a special-purpose appliance a build flag rather than a git revert — a staff VM
that still wants a full Qemu Ubuntu to demonstrate something, say. It costs nothing to keep the
option open: `validate` covers optional nodes exactly like installed ones, so a retired node cannot
rot unnoticed, and `plan` lists what each platform offers. (This also put `frr-qemu` and `netem-qemu`
back under `validate` — they had been in no platform's list at all since the July 2026 Docker
migration, which is precisely how three orphaned template files accumulated unseen.)

**As of 19 August 2026 OPNsense is the only Qemu node a default build installs.** The other three
are optional, and `provenance` records an optional disk only when a build actually installed it, so
an ordinary build does not report them as missing.

---

## The appliance does not update itself

The `quiesce` phase masks `apt-daily.timer`, `apt-daily-upgrade.timer`, the two services they
activate and `unattended-upgrades.service`, then writes
`/etc/apt/apt.conf.d/99-cqu-no-auto-upgrades` turning the `APT::Periodic` keys off. The units
and the file both come from `auto_updates:` in the manifest.

**Why.** An OVA is meant to be the machine that was tested. A stock Ubuntu appliance is not:
it upgrades itself on a schedule, so what a student runs in week 8 is whatever the archive
held the day they first booted it, and no two students necessarily have the same appliance.

It also costs real time on a one-core VM. On 15 August 2026 `apt-daily-upgrade.service`
started 80 seconds into an autotest batch and spent 05:42:54–05:44:18 installing 38 packages
— `libc6`, `systemd`, `udev`, `openssl` and a new kernel. The `link-performance` test ran
inside that window; its node console went quiet for 105 seconds and the run was recorded as
`FAIL`. Nothing was wrong with the activity — it passed five times in a row once the VM was
idle. In a classroom the same event is a node that stops answering mid-activity for no
visible reason.

`mask`, not `disable`: a disabled unit is still startable, and an apt upgrade of
`unattended-upgrades` or `systemd` re-enables what the package ships enabled. Masking
symlinks the unit to `/dev/null` and survives that. Check it with:

```sh
systemctl is-enabled apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service
# expect: masked  masked  masked
```

**Updating the appliance is a build-time decision.** To take new packages, upgrade
deliberately (`sudo apt-get update && sudo apt-get upgrade`), reboot, re-run the build and
the autotests, then cut a new OVA — so what ships is again the thing that was tested.

**Pending reboots.** If an upgrade has already run, the VM is left running one kernel with
another installed. `quiesce` warns when `/var/run/reboot-required` exists, and `provenance`
records both `system.reboot_required` and the state of each masked unit. Reboot before
`export-check`: an OVA cut in that state ships a machine that changes on its first boot,
which is the whole thing this phase exists to prevent.

---

## Qemu hardware acceleration

The `accel` phase writes a `[Qemu]` section into the appliance's `gns3_server.conf`:

```ini
[Qemu]
require_kvm = false
```

That one line is the difference between "Qemu nodes work everywhere" and "Qemu nodes work only
on hardware with nested virtualisation". It is worth understanding, because the obvious setting
is the wrong one.

**What GNS3 2.2.54 actually does** (`gns3server/compute/qemu/qemu_vm.py`,
`_run_with_hardware_acceleration`):

| Setting | Default | Meaning |
|---|---|---|
| `enable_hardware_acceleration` | `true` | use KVM/HAXM at all |
| `require_hardware_acceleration` | `true` | a missing `/dev/kvm` **raises**, rather than falling back |
| `enable_kvm`, `require_kvm` | unset | pre-2.0 names, still honoured on Linux and they **override** the two above |

Both defaults are `true` and "require" means *raise*. So out of the box, a host without nested
virtualisation fails every Qemu node with `KVM acceleration cannot be used (/dev/kvm doesn't
exist)`. That is not hypothetical: a managed Windows laptop with Credential Guard enabled has
Hyper-V holding VT-x, so VirtualBox cannot pass it through and the guest has no `/dev/kvm`.
Docker nodes are unaffected — they share the host kernel — so most activities still work and
only the Qemu ones break, which makes the fault look stranger than it is.

**`require_kvm = false`, not `enable_kvm = false`.** The two do different things:

- `require_kvm = false` — keep acceleration wherever it exists, and fall back to TCG emulation
  where it does not. No penalty on capable hardware.
- `enable_kvm = false` — turn acceleration off *unconditionally*, including on machines that
  have it. OPNsense boots in about 20 seconds with KVM and takes minutes without, so this
  costs every capable machine that difference. It is what the older troubleshooting notes
  recommended, and it is the wrong lever for an appliance handed to a whole cohort.

**On arm64 this is mandatory, not a nicety.** The acceleration check runs *before* the
architecture check, and its list of supported binaries is x86-only (`qemu-system-x86_64`,
`qemu-system-i386`, `qemu-kvm`). With the defaults, `qemu-system-aarch64` therefore raises
`Hardware acceleration can only be used with the following Qemu executables: …` on every Qemu
node, regardless of the hardware. `require_kvm = false` returns `False` at that point instead.

**No restart.** `gns3server` watches its config files (`FileWatcher`, mtime, one second) and
reloads on change, so the phase writes the file and nothing else — the build still never
restarts the GNS3 service. The one caveat is that only files present when the server started
are watched; this file always exists on a stock appliance, and the phase warns if it does not.

### Which `gns3_server.conf` — the phase discovers it

**Do not assume the path.** It moved, and the assumption failed silently:

| GNS3 VM | Server config |
|---|---|
| up to 2.2.54 | `~/.config/GNS3/2.2/gns3_server.conf` (gns3server's own default) |
| 2.2.61 | `/opt/gns3/server/gns3_server.conf`, passed as `--config` from `gns3.service` |

An explicit `--config` makes that file the **only** one loaded — `gns3.log` shows a single
`Config file … loaded` line, and nothing merges the user path in. So on a 2.2.61 VM the phase
was writing `require_kvm = false` into a file the server never reads: the build went green, the
provenance recorded it, and the setting was absent. It costs nothing where `/dev/kvm` exists,
which is most build hosts — and breaks every Qemu node on a Credential Guard laptop and on all
of arm64, which is exactly the population this section exists to protect.

The phase now reads the `--config` of the **running gns3server** (`/proc/<pid>/cmdline`), falls
back to `gns3.service`'s `ExecStart` if the service is down, and only then to
`qemu_accel.config_file` in the manifest. It prints which of the three answered:

```
  config /opt/gns3/server/gns3_server.conf (from the running process)
  WARN   /home/gns3/.config/GNS3/2.2/gns3_server.conf also has a [Qemu] section and is NOT
         read by this server — it is ignored, not merged
```

That `WARN` is the residue of the bug — a stale `[Qemu]` section an earlier build left behind.
It is reported rather than deleted, since the file may be hand-written; it is inert either way.

Discovery makes the phase write to the right file; it does not prove the setting survived to
the OVA. `provenance` re-reads the file and fails if it did not — see
[Check before you export](#2-check-before-you-export).

Change the values in `qemu_accel.settings` in `manifest.yml`, not on the appliance.

### The phase also repairs the console screen

Writing `require_kvm` **creates a `[Qemu]` section where a stock VM has none**, and that alone
breaks `/usr/local/bin/gns3welcome.py` — the blue info screen, run from `~/.bash_profile` on
every interactive login, which both getting-started guides tell students to read the VM's IP
address off. Its `kvm_control()` ends:

```python
        if config.getboolean("Qemu", "enable_kvm") is True:
            ...
    except configparser.NoSectionError:
        return
```

No section → `NoSectionError` → caught → the check quietly does nothing. Section present but no
`enable_kvm` key → **`NoOptionError`**, which nothing catches. Students get the info box, then a
Python traceback, then `.bash_profile`'s "Please run 'sudo gns3restore' in case the menu is no
longer showing". The IP is still readable, so it is cosmetic — but it reads as a broken
appliance. Found 17 Aug 2026 on a 2.2.61 VM built on the 15th, i.e. already shipping.

The phase now widens that guard to `except (configparser.NoSectionError,
configparser.NoOptionError):`, which restores the stock "say nothing" behaviour. It is
idempotent, runs on the skip path too, and refuses to touch the file if the line it expects is
not there exactly once:

```
  welcome /usr/local/bin/gns3welcome.py kvm_control() now catches NoOptionError too
  welcome /usr/local/bin/gns3welcome.py already tolerates [Qemu] without enable_kvm
```

**Only 2.2.61-class VMs are affected**, for a reason worth knowing: `gns3welcome.py` hardcodes
`/opt/gns3/server/gns3_server.conf`, which does not exist on a 2.2.54 VM (no `--config`, so
this phase writes the user path instead). The read returns an empty config and `NoSectionError`
still wins. The repair is applied there anyway — harmless, and it guards against the config
path moving a third time.

**Do not "fix" this by also writing `enable_kvm`.** Any value makes it worse. `true` makes
`kvm_control()` offer a student on a machine without `/dev/kvm` a *"Disable KVM and get lower
performance?"* dialog, and accepting writes `enable_kvm = false` and reboots — the setting the
manifest explicitly warns against, since it overrides `require_kvm` and disables acceleration
unconditionally. `false` produces the mirror-image dialog wherever `/dev/kvm` does exist. With
the key absent, the guard returns early and asks nothing.

This is a GNS3 bug — the same file catches `NoOptionError` correctly ~280 lines earlier — and
is worth reporting upstream.

---

## What survives a project being closed

A Docker node is rebuilt from its image every time a project is closed and reopened, so only the
directories GNS3 was told to keep come back. What it keeps is the **union of three things**
(`gns3server/compute/docker/docker_vm.py`, `_mount_binds`):

```
/etc/network  +  the image's own VOLUME list  +  the template's extra_volumes
```

then collapsed so that a **more general path absorbs a more specific one** — adding `/etc` swallows
`/etc/ssh` and `/etc/network`, which is harmless because GNS3 writes its sample network config into
the same working directory and it ends up inside the wider mount.

**So `extra_volumes` is a delta, not a list of everything a node needs.** Read the image first:

```sh
docker image inspect cqugns3/alpinenode:latest --format '{{json .Config.Volumes}}'
```

| Image | Declares in its Dockerfile |
|---|---|
| `alpinenode`, `ubuntunode`, `ipv6node` | `/data` `/etc/ssh` `/home/student` `/root/.ssh` |
| `auth-kerberos` | those four **plus `/etc`** |
| `net_toolbox` | `/etc` `/root` `/var/www` `/tftpboot` `/var/log` |
| `suricata` | `/etc/suricata` `/var/lib/suricata/rules` `/var/log/suricata` |
| `frrnode` | `/etc/frr` |
| `gns3/openvswitch` | `/etc/openvswitch` `/root` |
| `gns3/webterm` | `/root` |
| `wazuh-agent` | `/var/ossec/etc` `/var/ossec/logs` |
| `gns3/kalilinux`, `netemnode` | *nothing* |

What each template adds on top, in `templates/docker-*.conf`:

| Template | `extra_volumes` | Covers |
|---|---|---|
| Linux Host, Linux Router, VPN Router, Ansible Host | `/etc` `/root` `/var/www` `/usr/local/bin` | `hosts`, `shadow`, `pam.d`, `ssl`, `nginx`, `wireguard`, `nftables.conf`; the openssl CA tree under `/root/ca`; web roots; exporter binaries |
| Ubuntu Host | those four **plus `/home`** | extra accounts made in `password-hashing` |
| Kerberos Host | `/root` `/var/lib/krb5kdc` | the KDC database (`/etc` is already in the image) |
| NAT64Router | `/etc` `/root` `/usr/local/bin` | `tayga.conf`, and the three helper scripts |
| Kali Linux CLI | `/root` | the image declares nothing, so scan output and notes were lost |
| everything else | *(empty)* | the image already covers what the activities write |

The four alpinenode roles deliberately share one set. They are one image, a Linux Router gets used
as a host all the time, and the difference is about 2 MB per node — a per-role minimal set would only
produce "why did my page survive on Host1 and not on Router1".

The empty ones are empty on purpose, not by omission. **Linux Server** (`net_toolbox`) already
declares everything it needs; **Suricata IDS** keeps its config, custom rules and logs in the three
directories its image declares; **FRR** writes `vtysh` output to `/etc/frr`; **Firefox Host** keeps
its browser profile under `/root`; **Wazuh Agent** keeps its key and config under `/var/ossec`;
**NETem**'s settings are `tc` state in the kernel, so no directory would help.

### Verified on hardware, 13 August 2026

Two `Linux Host` nodes on 192.168.56.108, identical edits, project closed and reopened. The control
node had image defaults only; the other had the four directories above.

| Edit | Control | With `extra_volumes` |
|---|---|---|
| entry appended to `/etc/hosts` | **lost** | kept |
| file in `/etc`, `/root`, `/var/www`, `/usr/local/bin` | **lost** | kept |
| file in `/home/student` | kept | kept |

Three things that came out of it and are not obvious:

- **`/etc/hosts` cannot be kept any other way.** Docker mounts it as an individual file, and a
  volume must be a directory — so `/etc` is the only route. It is also the single most-referenced
  path in the activity handouts (`dns-hosts` is built on editing it), and it was being lost on every
  reopen.
- **There is no stale-DNS risk.** Keeping `/etc` does shadow Docker's managed `/etc/resolv.conf`
  with a first-start snapshot, but that file is *empty* on these nodes to begin with, so there is
  nothing to freeze. `/etc/hostname` is likewise empty and unused — the container hostname comes
  from Docker's own config and follows a rename correctly.
- **A rename after first start leaves `/etc/hosts` stale**, holding `127.0.1.1 <old-name>`. The node
  can no longer resolve its own name. The student guide (`gns3-dev/guides/gns3-saving-work.md`) now
  says to name nodes before starting them, and how to fix one afterwards.

Cost measured on the same nodes: **2.9 MB per node** with `/etc` kept, against 856 KB without.

### Applying a change

`extra_volumes` reaches **nodes created after** the template changes; existing nodes keep what they
were built with. Two consequences worth knowing:

- On a controller that already has the templates, the `templates` phase skips them (it keys on
  `template_id`) — push the change with `gns3build.py templates --profile amd64 --force`.
- The NAT64Router entry only pays off once `ipv6node` is rebuilt: its three helper scripts moved
  from `/bin` to `/usr/local/bin` so that the edit `ipv6-basics` asks students to make survives.
  An existing image is skipped, so that needs `gns3build.py docker --only ipv6node --force`.

`vm-fix-persistence.sh` in this directory does the same job over the REST API on an appliance that
is already built. It was the July 2026 post-release fix for `v027` and is still what those
appliances need; it is not part of the build.

## Reaching a VNC node

A few nodes have a **VNC console** instead of a terminal — the Firefox Host is the one
students meet. The GNS3 web UI cannot open those: it draws consoles with xterm.js and ships
no VNC client at all, so *Web console* works for every other node and does nothing for these.

The appliance answers that with **`gns3-novnc`**, a service the `novnc` phase installs and
enables. It runs one `websockify` on **port 6080** from boot, serving stock noVNC. A student
opens

```
http://<gns3-vm-ip>:6080/
```

and gets a list of the VNC nodes in whatever project is open, with an **Open console** button
on each. Nothing else: no VM shell, no port numbers, no second bridge for the second Firefox
Host, and nothing to redo after a reboot. The URL is the same for every activity, so it can
be bookmarked once.

**How one listener reaches every node.** websockify normally proxies to one fixed target.
Its `--token-plugin` hook is asked, per connection, where to connect instead — so the token
in the URL names the node. The plugin (`novnc/gns3_vnc_console.py`) answers from the GNS3
API: the console port of a *started* VNC node in an *open* project, on localhost. Anything
else — a stopped node, a port that is not a node console, an unknown name — is refused, which
is narrower than the script this replaced would allow.

A token is a **console port** (`5900`, what the page uses, since it has just read the list) or
a **node name** (`Host2`, or `Project/Host2` if two open projects both have one). The name
form is the one to put in an activity, because it survives the port changing:

```
http://<gns3-vm-ip>:6080/novnc/vnc.html?path=websockify/?token=Host2&autoconnect=true&resize=scale
```

**Parts.** `novnc/gns3_vnc_console.py` (the service: token plugin, `/nodes.json`, the proxy),
`novnc/index.html` (the picker page), `novnc/gns3-novnc.service` (the unit, with `@LIB@`,
`@WEB@` and `@PORT@` substituted from `novnc.service` in the manifest). They install to
`/usr/local/lib/gns3-novnc`, `/usr/local/share/gns3-novnc` (plus a `novnc` symlink to
`/usr/share/novnc`) and `/etc/systemd/system`.

The page cannot ask the GNS3 API for the node list itself, which is why the service serves
`/nodes.json`: `gns3server`'s CORS whitelist is six hardcoded origins (127.0.0.1 and
localhost on 3080 and 4200, gns3.github.io), so a page served from `:6080` is refused.

**Finding the API's port.** This appliance serves it on **80** so students can browse to the
bare IP, while a stock GNS3 VM uses 3080 — so the service resolves it rather than assuming, in
four steps: `$GNS3_SERVER`, then `[Server] port` from the config file the running gns3server
was *given* (see [Which `gns3_server.conf`](#which-gns3_serverconf--the-phase-discovers-it)),
then the same key at the historical user path, and finally by asking 80 and 3080 which one
answers `/v2/version`. A live endpoint is the only answer that cannot go stale, and it is what
should carry this across the next time the VM's layout moves.

It also **re-resolves on failure**: the unit is `After=gns3.service` but not bound to it, so it
can start first, and `Restart=always` means a wrong guess would otherwise stick until someone
noticed. An explicit `--api` is treated as a promise and never overridden.

Getting this wrong is what the page reports as

```
cannot reach the GNS3 server: <urlopen error [Errno 111] Connection refused>
```

which reads like a firewall or a dead controller and is neither — it is the gateway talking to
a port nothing listens on. `journalctl -u gns3-novnc` names the port it chose, which settles it
in one line.

**Checking it.** On the VM:

```sh
systemctl status gns3-novnc
python3 /usr/local/lib/gns3-novnc/gns3_vnc_console.py --list   # what it can see right now
journalctl -u gns3-novnc -n 30                                 # refused tokens are logged
```

An empty list is usually correct: a project has to be **open** and the node **started**
before its console exists. `curl http://<vm>:6080/nodes.json` asks the same question from
outside.

**`start-vnc.sh`** is still installed in the `gns3` home directory as a staff fallback, for
bridging a VNC port the service will not resolve because it is not a GNS3 node console. Give
it a web port other than 6080 — `./start-vnc.sh 5901 6081` — or it cannot bind.

---

## The Windows Host

Windows runs as a **separate VM on the student's own hypervisor**, not as a node inside the
GNS3 VM — Fusion on Apple Silicon has no nested virtualisation, and `/opt` has nowhere near
the space for a Windows disk. It joins a topology through an isolated hypervisor network and
a GNS3 Cloud node. The reasoning and the spike results are in
`gns3-dev/notes/windows-host-node.md`; the student-facing setup is
[`windows/README.md`](windows/README.md).

The build contributes three things, all automatic:

| Piece | Where |
|---|---|
| The **Windows Host** template — a Cloud node locked to `eth2` | `templates/cloud-windowshost.conf`, registered by `templates` |
| The `computer-windows.svg` symbol | `../images/symbols/`, installed by `logos` |
| DHCP turned **off** on `eth2` | the `labnic` phase, `lab_nic:` in the manifest |

**Why `labnic` exists.** The stock appliance already declares `eth2`–`eth8` in
`80_gns3vm_default_netcfg.yaml` and brings them up — but with `dhcp4: yes`. A Cloud node
bridges the *topology* onto `eth2`, so the moment an activity runs a DHCP server
(`dhcp-server-basics`, `dhcp-client`, any OpenWrt LAN) the GNS3 VM itself takes a lease from
the student's lab: an unexplained extra host, holding an address the student thinks is free
and answering ARP for it. The phase writes `/etc/netplan/95-cqu-lab-nic.yaml`, which netplan
merges over the appliance's own file — hence the `95-` prefix, since netplan merges in
lexical order and the last definition wins. Check the merged result with:

```sh
sudo netplan get ethernets.eth2      # expect dhcp4: false, dhcp6: false, optional: true
```

It deliberately does **not** run `netplan apply`: that can bounce every interface, and the
phase runs over ssh on `eth0`, so applying would kill the connection driving the build. The
file covers every future boot; `ip link set eth2 up` covers the current one.

On a VM with only two adapters the phase writes the file, reports that `eth2` is absent and
exits 0 — nothing is wrong, the interface appears when a third adapter is attached.

**Editing the template:** cloud templates reject a `usage` field, unlike qemu and docker
ones, so the node cannot carry its own explanation in the GNS3 UI; that lives in the student
guide. Adding one fails the `templates` phase with `Additional properties are not allowed
('usage' was unexpected)`.

## Mac builds

Note the first argument differs by hypervisor: `amd64` takes the VM **name**, `arm64` takes
a **path to the `.vmx`**.

```sh
source ~/gns3-build/bin/activate                 # every new shell — see setup above
cd ~/git/gns3/server/ansible
./build.sh "$(gns3vmx)" arm64
GNS3_VM_IP=<ip> ./build.sh "$(gns3vmx)" arm64    # if vmrun discovery misbehaves
```

Before building, confirm the VM is the one you think it is:

```sh
vmrun list                                    # running, and the .vmx path
curl -s http://<vm-ip>/v2/version             # port 80, expect 2.2.54
ssh gns3@<vm-ip> 'uname -m; df -h /opt'       # expect aarch64 and ~10 GB free
```

`aarch64` is the one that matters: the `arm64` profile builds Docker images **on the VM** so
they come out native, which only holds if the VM really is arm64.

A correct `arm64` build installs 20 Docker images, **3** Qemu disks and 33 templates
— three disks rather than the four the PC build once needed, because FRR and NETem are Docker
on both platforms. Take the counts from `gns3build.py plan --profile arm64` rather than from
this line, which has gone stale twice as nodes were added. The disks should all be arm64
variants:

```
openwrt-23.05.0-armsr-armv8-generic-ext4-combined.img
OPNsense-24.1-ufs-efi-vm-aarch64.qcow2
ubuntu-24.04-server-cloudimg-arm64.img
```

### Two appliances, two GNS3 versions

The PC appliance is built on a **2.2.61** VM and the Mac appliance on a **2.2.54** one, because
2.2.54 is the last GNS3 release that shipped an ARM64 VM image at all (see
[Before you start](#before-you-start) for the evidence). That split is deliberate and it is not
a problem, for one reason:

**Students never run the GNS3 desktop client.** Both `vm/getting-started-pc.md` and
`vm/getting-started-mac.md` send them to the web UI the appliance serves on port 80 — the only
software they install is the hypervisor. So the version check that would otherwise force the
issue never runs. In GNS3 2.2 that check is a hard refusal, not a warning
(`gns3-gui/gns3/http_client.py:437-448`, read at tag v2.2.61):

```python
if parse_version(__version__)[:3] != parse_version(params["version"])[:3]:
    # "Client version 2.2.61 is not the same as server (controller) version 2.2.54"
```

Only a fourth component may differ (2.2.32 vs 2.2.32.1, which downgrades to a warning). So
**anyone who does use the desktop client — staff, mostly — must install the client matching the
appliance they are pointing it at**: 2.2.61 for a PC appliance, 2.2.54 for a Mac one, both
still downloadable from their respective `GNS3/gns3-gui` release pages.

Levelling the PC appliance back down to 2.2.54 would buy nothing students can see, and would
give up the 2.2.55–2.2.61 fixes: a project-import symlink-traversal fix (2.2.61, and students
import projects from Moodle), Docker container-naming and stop-state fixes (2.2.55, 2.2.60,
2.2.61), and a telnet console hang fix (2.2.59) — consoles being the thing every activity uses.

#### The GNS3 version is the smallest of the differences

The appliances are two Ubuntu LTS releases and a kernel generation apart, which matters far more
than the server version does. Measured on both live VMs, 18 Aug 2026:

| | 2.2.54 VM | 2.2.61 VM |
|---|---|---|
| Ubuntu | **20.04.6 LTS** (standard support ended May 2025) | **26.04 LTS** |
| Kernel | 5.15.0-136 | 7.0.0-28 |
| Docker | 28.1.1, `overlay2` | 29.6.2, `overlayfs` (containerd snapshotter) |
| cgroups | **v1**, `cgroupfs` driver | **v2**, `systemd` driver |
| containerd | 1.7.27 | 2.2.6 |
| Qemu | 8.0.4 | 10.2.1 |
| noVNC | 1.0.0 (2018) | 1.6.0 |
| System python3 | 3.8.10 | 3.14.4 |
| gns3server venv python | 3.9.5 | 3.14 |
| `gns3server` invocation | venv, **no** `--config` | venv, `--config /opt/gns3/server/…` |

What this does **not** break: the node images. They are built natively on whichever VM they are
destined for, and a container's userspace depends on the kernel, not the host distribution —
Alpine 3.24, Ubuntu 24.04 and Debian bookworm all run on 5.15. All four `kernel_modules:`
(`wireguard`, `sch_netem`, `mac80211_hwsim`, `cifs`) are present on the 20.04 kernel too; the
module *paths* differ (`fs/cifs` vs `fs/smb/client`, `wireless/` vs `wireless/virtual/`) but the
phase modprobes by name, so that is invisible. `eth0/eth1/eth2` naming holds on both, so
`labnic` is safe, and the `apt-daily*` units `quiesce` masks exist on both.

#### Measured on 20.04, 17 August 2026

Keep the scale of this in perspective: **20.04 is not a new risk for the Mac appliance, it is
the status quo.** Every arm64 build there has ever been ran on this stack, because 2.2.54 is
the only ARM64 VM there has ever been. What was untested was the node set added since the last
Mac build — Tier 1, Tier 5, OpenWRT, Gitea, wireless, Faucet. So that is what was checked, on a
20.04 amd64 VM standing in for the Mac (same OS, Docker, kernel and cgroup version; only the
architecture differs).

| Check | Result |
|---|---|
| Rebuild every locally-authored image | **built 15, skipped 0, failed 0** |
| `readiness.sh` in each image | **READY** for all 12 that have a profile, 0 MISS, 0 FAIL |
| Kernel modules the phase loads | `wireguard`, `sch_netem`, `mac80211_hwsim` all loaded on 5.15 |
| noVNC end to end | VNC node started → picker listed it → websocket **101** → `RFB 003.008` banner returned through websockify 0.9.0 / noVNC 1.0.0 |
| Wireless, WPA2 | `gns3-wifi-attach` moved a phy into each node; station associated, CCMP, ping across the link |
| Wireless, WPA3-SAE | `key_mgmt=SAE`, `pmf=2`, `wpa_state=COMPLETED`, AP shows `[MFP]` — matching the 7.0 kernel result |
| `monitornode` on cgroup v1 | all four services up; `node_exporter` serves 489 `node_*` metrics; Prometheus target healthy |
| OpenWRT node | LuCI CGI present, `askconsole` inittab, `fw4`/`nft`, uci-defaults hook, 24.10.8 |

Two things came out of it:

- **A real defect, now fixed.** `start-grafana.sh` waited 20 s for Grafana to bind port 3000.
  On a **one-vCPU** VM Grafana 12.4.4 takes ~90 s (plugin installs), so the script declared
  "Grafana did not answer on port 3000" and exited 1 on a node that was starting perfectly
  normally. The wait is now 120 s, and a timeout with the process still alive says *still
  starting* instead of failing. Re-measured on the same 1-vCPU VM: `All four are up`, 1m13s.
  Nothing to do with 20.04 — the 26.04 VM simply had two cores and got under the old limit.
- **`frrnode` and `netemnode` have no `readiness.sh` profile** and exit 2 ("unknown image
  type"). Not a 20.04 issue; a gap in the checker worth closing in `gns3-dev`.

Still not covered, and honestly so:

- **The noVNC 1.0.0 browser UI.** The transport is proven; six years of clipboard, scaling and
  keyboard handling are not. That needs a human with a browser.
- **Qemu 8.0 vs 10.2.** Less relevant than it first appeared: the amd64 `qemu-opnsense`
  template uses no UEFI at all (`options` empty, no `bios_image`). The `-bios
  /usr/share/qemu-efi-aarch64/QEMU_EFI.fd` path exists only in `qemu-opnsense-arm64`, which can
  only be exercised on a Mac — where it has always run on this same Qemu.

The **bundled web UI** also differs — 2.2.54 bundles web-ui 2.2.54, 2.2.61 bundles web-ui 2.2.58
(the last bump in that range; the two VMs' bundle hashes confirm they are different builds).
That is what students look at, so check the screenshots in `vm/using-gns3.md` against the other
appliance when either is rebuilt.

#### Why not just upgrade the ARM VM's gns3server to 2.2.61

It would probably install — both VMs run gns3server from their own venv, the 2.2.54 VM's venv is
on **Python 3.9.5**, and 2.2.61 requires `>=3.9` (2.2.56.1 dropped 3.8, which is why the *system*
python3 on 20.04 could not host it). But it buys the version number and nothing else: the VM
stays on Ubuntu 20.04, kernel 5.15, Docker 28, cgroup v1 and noVNC 1.0.0, which is where every
difference in the table above actually lives. It also makes the Mac appliance non-stock, and
"a stock GNS3 VM" is the assumption the whole build starts from. Not recommended.

Levelling the *other* way — putting the PC appliance back on 2.2.54 — is worse than the version
number suggests for the same reason: it would move the PC build back to Ubuntu 20.04, whose
standard support ended in May 2025.

`manifest.yml` carries a single `gns3_version:` used only as `manifest_expects` in provenance,
so an arm64 build silently records `controller_version: 2.2.54` against `manifest_expects:
2.2.61`. Read the pair, not either alone.

### Mac limitations

The `arm64` profile builds arm64 Docker images and downloads arm64 Qemu disks. FRR and NETem
are Docker on both platforms (no arm64 Qemu images exist for them), so those activities
work everywhere and the templates keep the same names — activity instructions are
unchanged.

What does **not** work on a Mac VM: projects containing **amd64 Qemu** nodes. A
`.gns3project` stores each Qemu node's emulator and disk by name, so a project exported on
a PC carries `qemu_path: /usr/bin/qemu-system-x86_64` and an `…amd64.img` disk — neither of
which exists on an arm64 VM, whatever the templates say. Every project holding a Qemu node
is affected:

| Project | Qemu node(s) | Ships on the appliance? | Autotest |
|---|---|---|---|
| Small-Internet-Demo | amd64 OpenWrt | **yes** — needs an `-arm64` rebuild | skipped (manual) |
| DHCP-Client-Solution | amd64 OpenWrt | no — `-arm64` rebuild exists | `dhcp-client` |
| IPsec-Site-to-Site-Solution | 2 × amd64 OPNsense | no | `ipsec-site-to-site` |
| OPNsense-Firewall-Solution | amd64 OPNsense | no | `opnsense-firewall` |
| SDN-Basics-Template | amd64 Ubuntu cloud image | no — downloaded by the student | skipped (GUI) |

Only the first now affects the appliance, and it matters more than it used to: it is one of
five projects a student sees on first boot, so on Apple Silicon a broken flagship demo is
conspicuous. The rest are reached by import, and fail at that point rather than on the OVA.

`export-check` reports whichever of these are imported as `BROKEN` on an arm64 build, and
under `-e verify=all` the Qemu ones fail with **`HTTP 403 Forbidden`** — GNS3's response when
it cannot resolve a node's emulator or disk. It logs nothing server-side, so the bare 403 is
all you get; if you see it on a Mac, this is why.

Fixing one means rebuilding it on a Mac against the arm64 templates — not something the
build can do for you. Everything else, which is every Docker-based activity, works normally.

**Where a rebuild goes.** Keep the project's *name* identical (`projects.txt` and
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

Delete the project from the VM once exported, unless it is on `projects.txt`. A hand-built
copy is indistinguishable from a wrongly imported one, and anything unlisted now fails
`export-check` outright.

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
`/dev/kvm` — so these run under TCG emulation, slower than their PC equivalents. **The
`accel` phase is what makes that work**, and on arm64 it is not optional: see
[Qemu hardware acceleration](#qemu-hardware-acceleration) below. Until that phase existed,
the arm64 Qemu nodes only booted because someone had set `enable_kvm = false` by hand while
debugging something else — an invisible dependency that a rebuild from a fresh VM would have
lost.

**Editing a template is not enough on its own.** The `templates` phase keys on
`template_id`, so a changed `.conf` is skipped on a controller that already has it; push it
with `gns3build.py templates --profile arm64 --force`. Existing *nodes* keep whatever
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

**`export-check` says a project is UNLISTED.** Something is imported that is not on
`projects.txt`. The usual causes are a solution opened to answer a question, and a VM built
under the old two-appliance scheme — the projects that were legitimate then are unlisted now.
Delete them through the GNS3 GUI or the API (`DELETE /v2/projects/<id>`), or start from a
clean VM snapshot. Add it to `projects.txt` only if it really should ship to everyone.

**A node fails to start after a rebuild.** If you edited a Dockerfile, the image is only
rebuilt with `--force` — an existing image is skipped by design.

**`http://<vm-ip>:6080/` says "cannot reach the GNS3 server: … Connection refused".** The
gateway is up (it is the page saying so) and pointed at the wrong port. Check which one it
chose, and against what:

```sh
journalctl -u gns3-novnc -n 5      # "controller http://127.0.0.1:<port>"
curl -s http://127.0.0.1/v2/version ; curl -s http://127.0.0.1:3080/v2/version
```

Since August 2026 the service resolves the port from the running server and falls back to
probing both, so this should self-correct — a mismatch now means neither port answered, i.e.
`gns3.service` is genuinely down. On an appliance built before that fix, on a 2.2.61 VM, it
fell back to 3080 and stayed there; `gns3build.py novnc` installs the fixed module.

**`projects` reports MISSING.** The named project is not under any root. Every project on
`projects.txt` is committed to `gns3-dev`, so this normally means the private repo is not
beside this one — pass `-e gns3_dev_repo=/path/to/gns3-dev`.

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
