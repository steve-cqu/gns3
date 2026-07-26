# Building the CQU GNS3 VM (staff only)

How to turn a fresh GNS3 VM into the appliance handed out to students, and the staff
variant with the solution projects. One command does the build; you cut the OVA yourself.

Two appliances are produced from **one** VM, in this order:

| | Profile | Projects | Exported as |
|---|---|---|---|
| Student | `pc-student` / `mac-student` | the 7 in `projects-student.txt` | `GNS3-CQU-v<version>-student.ova` |
| Staff | `pc-staff` / `mac-staff` | those 7 **plus** the 17 in `projects-staff.txt` | `GNS3-CQU-v<version>-staff.ova` |

Staff is a superset of student — build the student VM, export it, then add the staff
projects to the same VM and export again. Never the other way round: a student OVA must
not contain solutions, and `export-check` (below) refuses to bless one that does.

Two platforms, chosen by the profile prefix:

| | Hypervisor | Arch | Images |
|---|---|---|---|
| `pc-*` | VirtualBox | amd64 | amd64 Docker images, amd64 Qemu disks |
| `mac-*` | VMware Fusion | arm64 | arm64 Docker images, the `-mac` Qemu disks |

The Docker images are always built **on the VM**, so they come out native for its
architecture — there is no cross-building. FRR and NETem are Docker nodes on both
platforms, since no arm64 Qemu images exist for them.

> **Tested status.** The `pc` path is validated end to end against a VirtualBox GNS3 VM:
> full build, idempotent re-run, verification, export-check and provenance. The `mac` path
> shares all of that code and its profile has been checked in dry-run (correct
> `linux/arm64/v8` platform and arm64 image URLs), but **it has never been run on Apple
> Silicon**. Expect to shake out VMware-specific issues on the first Mac build — the most
> likely spot is `vmrun getGuestIPAddress` in `build.sh`; `GNS3_VM_IP=<ip>` bypasses it.

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
- `VBoxManage` on the PATH for `pc-*`, or `vmrun` + `ovftool` for `mac-*`
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

# 5. vmrun, which lives inside the Fusion app bundle rather than on the PATH.
echo 'export PATH="/Applications/VMware Fusion.app/Contents/Public:$PATH"' >> ~/.zprofile
export PATH="/Applications/VMware Fusion.app/Contents/Public:$PATH"

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
vmrun list
python3 -c 'import yaml; print("pyyaml ok")'
```

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
./build.sh "GNS3 VM" pc-student            # VirtualBox (PC)
./build.sh ~/VMs/GNS3.vmx mac-student      # VMware Fusion (Apple Silicon)
```

`build.sh` finds the VM's IP from the hypervisor and runs the playbook. If discovery
fails or you already know the address, skip it:

```sh
GNS3_VM_IP=192.168.56.106 ./build.sh "GNS3 VM" pc-student
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
ssh gns3@<vm-ip> '~/git/gns3/server/build/gns3build.py export-check --profile pc-student'
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

```sh
vmrun stop ~/VMs/GNS3.vmx soft
ovftool ~/VMs/GNS3.vmx GNS3-CQU-v<version>-student.ova
```

---

## 4. Add the staff projects and cut the staff OVA

Start the VM again, then re-run the build with the staff profile. Only the extra projects
are imported — everything else is already in place and skips:

```sh
cd gns3/server/ansible
./build.sh "GNS3 VM" pc-staff -e verify=all
```

Then repeat step 2's checks with `--profile pc-staff` and step 3's export, naming it
`GNS3-CQU-v<version>-staff.ova`.

---

## Running phases individually

`build/gns3build.py` is the engine; the playbook is a thin wrapper around it. Run it on
the VM (`cd ~/git/gns3/server/build`):

```sh
./gns3build.py validate                       # check the manifest and every template
./gns3build.py plan      --profile pc-staff   # show what would be installed, change nothing
./gns3build.py build     --profile pc-staff   # all six phases below, in order
./gns3build.py templates --profile pc-staff   # register templates via the GNS3 API
./gns3build.py docker    --profile pc-staff   # build the Docker node images
./gns3build.py qemu      --profile pc-staff   # download + verify the Qemu disks
./gns3build.py logos                          # install the CQU node symbols
./gns3build.py novnc                          # install noVNC + start-vnc.sh
./gns3build.py projects  --profile pc-staff   # import the audience's projects
./gns3build.py export-check --profile pc-staff
./gns3build.py provenance   --profile pc-staff
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

Note the first argument differs by hypervisor: `pc-*` takes the VM **name**, `mac-*` takes
a **path to the `.vmx`**.

```sh
source ~/gns3-build/bin/activate                        # every new shell — see setup above
cd ~/git/gns3/server/ansible
./build.sh ~/VMs/GNS3.vmx mac-student
GNS3_VM_IP=<ip> ./build.sh ~/VMs/GNS3.vmx mac-student   # if vmrun discovery misbehaves
```

Before building, confirm the VM is the one you think it is:

```sh
vmrun list                                    # running, and the .vmx path
curl -s http://<vm-ip>/v2/version             # port 80, expect 2.2.54
ssh gns3@<vm-ip> 'uname -m; df -h /opt'       # expect aarch64 and ~10 GB free
```

`aarch64` is the one that matters: the `mac` profile builds Docker images **on the VM** so
they come out native, which only holds if the VM really is arm64.

A correct `mac-student` build installs 14 Docker images, **3** Qemu disks and 18 templates
— three rather than the PC build's four because FRR and NETem are Docker on both
platforms. The disks should all be arm64 variants:

```
openwrt-23.05.0-armsr-armv8-generic-ext4-combined.img
OPNsense-24.1-ufs-efi-vm-aarch64.qcow2
ubuntu-24.04-server-cloudimg-arm64.img
```

### Mac limitations

The `mac` profile builds arm64 Docker images and downloads arm64 Qemu disks. FRR and NETem
are Docker on both platforms (no arm64 Qemu images exist for them), so those activities
work everywhere and the templates keep the same names — activity instructions are
unchanged.

What does **not** work on a Mac VM: projects containing **amd64 Qemu** nodes. On the
current student list that is:

- **SDN-Basics-Template** — its SDN controller disk is a qcow2 overlay backed by
  `ubuntu-24.04-server-cloudimg-amd64.img`
- **Small-Internet-Demo** — contains an amd64 OpenWrt node
- **DHCP-Client-Solution** (staff) — likewise

`export-check` reports these as `BROKEN` on a Mac build. That is expected, not a bug in
the build: those projects must be rebuilt on a Mac using its own templates before they
will run there. Everything else — all Docker-based activities — is fine.

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

**The playbook reports no hosts matched.** `build.sh` refuses to continue in that case
rather than reporting a successful build that did nothing. Check the VM name/`.vmx` path,
or use `GNS3_VM_IP=`.

**`rsync: Failed to exec sshpass`.** You have no SSH key for the VM and no `sshpass`.
Either `ssh-copy-id gns3@<vm-ip>` (preferred) or install `sshpass`. The playbook now
detects this before the sync and says so plainly.

**Verification fails.** `-e verify=none` gets you a build for debugging, but do not export
an appliance that has not passed `-e verify=all`.
