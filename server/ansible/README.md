# Host-driven GNS3 VM build

One command, run from your own machine, that turns a fresh GNS3 VM into a configured
appliance:

```sh
./build.sh "GNS3 VM" pc-student            # VirtualBox: the VM name
./build.sh "$(gns3vmx)" mac-staff          # VMware Fusion: a path to the .vmx
```

`gns3vmx` is the shell helper defined in [`../README.md`](../README.md) — it resolves the
VM's `.vmx` path each time rather than pinning one in your profile, where a rebuild or
rename would silently make it stale.

`build.sh` finds the VM's IP from the hypervisor and hands off to `site.yml`. To run the
playbook directly (IP already known):

```sh
ansible-playbook -i 192.168.56.106, site.yml -e profile=pc-student
ansible-playbook site.yml -e profile=pc-staff          # uses inventory.ini
```

## What it does

`../build/gns3build.py` is the engine and does all the real work; this playbook is a thin
wrapper around it. In order:

1. **check** the profile is set and the GNS3 API answers
2. **sync** `server/` and `images/` to `/home/gns3/git/gns3/` on the VM
3. **validate** the manifest, then run `gns3build.py build --skip projects` **on the VM**
   (`templates` → `docker` → `qemu` → `logos` → `novnc`)
4. **import projects** with `gns3build.py projects` **from your machine**, straight into
   the VM's API
5. **verify** with `gns3_autotest.py` and fail the build if anything comes back red
6. **export-check** — fail if the VM carries projects this audience must not ship
7. **provenance** — record what the appliance contains, and fetch a copy back here

Steps 6 and 7 are the pre-export gate. The playbook stops short of cutting the OVA
itself: that is one `VBoxManage export` / `ovftool` command and needs the VM shut down,
so it stays manual — see [`../README.md`](../README.md).

Every phase is idempotent, so re-running is safe and cheap — a second run of an
unchanged build reports `changed=0` and finishes in seconds.

Docker builds run on the VM so images are built for its architecture (this is why `pc`
and `mac` need no cross-building). Projects are imported from your machine instead of
being copied to the VM first: SDN-Basics-Template alone is 729 MB, and syncing it would
put that on the VM's disk *and* transfer it, for no benefit.

## Options

| | |
|---|---|
| `-e profile=…` | **required** — `pc-student`, `pc-staff`, `mac-student`, `mac-staff` |
| `-e verify=smoke` | default: four fast activities spanning docker, qemu and the custom images |
| `-e verify=all` | every activity with a test manifest — slow, and what you want before exporting an OVA |
| `-e verify=none` | skip verification (iterating on the build itself) |
| `-e gns3_dev_repo=…` | path to the private `gns3-dev` checkout (default: alongside `gns3`) |
| `-e extra_project_dir=…` | where the oversized out-of-git projects live (default: `../infiles`) |
| `--check` | dry run — passes `--dry-run` through to rsync *and* `gns3build.py`, so it reports what the build would actually do rather than skipping the tasks |

## Watching a run

Ansible shows no output while a task is running, and the build phase is half an hour of
Docker builds. The two long phases are teed to logs, and the playbook prints these
commands at the start, before it goes quiet:

```sh
ssh gns3@<vm-ip> 'tail -F /home/gns3/gns3build.log'   # build phases, on the VM
tail -F gns3build-verify.log                          # verification, here
```

Both are truncated at the start of each run, hence `tail -F` rather than `-f`.

## Artifacts a run leaves here

Both are per-build records, gitignored, and worth keeping alongside the OVA:

- `provenance-<profile>.json` — fetched from the VM. Date, profile, GNS3/kernel versions,
  every Docker image ID, every Qemu disk md5, every template and project, and the size +
  sha256 of each source `.gns3project`. Without it you cannot tell two `GNS3-CQU-*.ova`
  files apart later.
- `.gns3build-imports.json` — the source-side record the `projects` phase writes and
  `provenance` folds in. It is the only durable statement of which bytes the oversized
  out-of-git projects were built from, since git cannot hold them.

`build.sh` passes any extra arguments straight through, e.g.
`./build.sh "GNS3 VM" pc-student -e verify=all`.

## Tested status

The `pc` (VirtualBox) path is validated end to end for both audiences: build, idempotent
re-run (`changed=0`), `--check`, verification, export-check and provenance, through to an
exported OVA.

The `mac` (VMware Fusion, Apple Silicon) path was validated on 2026-07-26: a clean run of
`mac-student` finished green — Homebrew rsync, 14 arm64 Docker images, 3 arm64 Qemu disks
(md5s confirmed against real downloads for the first time), templates, logos, noVNC, 6 of 7
student projects imported (the seventh, SDN-Basics-Template, deliberately absent), smoke
verification passed, export-check clean, provenance written and fetched.

That build passed `GNS3_VM_IP=<ip>`, so discovery was bypassed; `vmrun getGuestIPAddress`
was confirmed separately on the same day and returns the reachable host-only address, not
the NAT one. Both hypervisor branches of `build.sh` are therefore exercised.

Before building, read **Setting up a Mac build host** and **Mac builds** in
[`../README.md`](../README.md): Homebrew's rsync is a hard requirement, `vmrun` is not on
the PATH, and `ansible-core` must be installed in the same venv as PyYAML.

## Requirements

- `ansible-core` (no collections needed) and `rsync`, with **PyYAML in the same python as
  `ansible-core`** — control-node scripts run under `ansible_playbook_python`, not whatever
  `#!/usr/bin/env python3` happens to find
- Either an SSH key the VM accepts (`ssh-copy-id gns3@<vm-ip>` — recommended) or `sshpass`
  for the password login. Both this playbook and `gns3_autotest.py` probe for a working key
  first and only fall back to `sshpass`, so if you can already ssh to the VM without a
  password you do not need it at all.
- The VM running, with SSH reachable and the GNS3 API on port 80
- For `build.sh`: `VBoxManage` on the PATH for `pc-*`, or `vmrun` for `mac-*`. Set
  `GNS3_VM_IP=<ip>` to skip discovery.

## Credentials

A stock GNS3 VM logs in as `gns3`/`gns3` with passwordless sudo, which is the default so
the playbook works out of the box. That is the vendor's published default, not a secret —
but change it before handing a VM out, and then either set `GNS3_VM_PASSWORD` in your
environment or (better) install an SSH key and set `ansible_ssh_private_key_file`, which
needs neither a password nor `sshpass`.

## Project sources

Projects are located by name under `project_roots`, **in order, first match wins**. The
default is the private repo's `activities/` tree followed by the oversized out-of-git
`infiles/` directory.

`gns3-dev/outfiles/` is deliberately *not* a root. It holds stale exports that share their
`project_id` with the rebuilt originals under `activities/`, so importing one silently
shadows the other — identical ids make the "already imported" check blind to the
difference. `gns3build.py` prints a `DUP` line whenever a name resolves under more than one
root; take those seriously.
