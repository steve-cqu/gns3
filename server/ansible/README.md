# Host-driven GNS3 VM build

One command, run from your own machine, that turns a fresh GNS3 VM into a configured
appliance:

```sh
./build.sh "GNS3 VM" pc-student            # VirtualBox, student VM
./build.sh ~/VMs/GNS3.vmx mac-staff        # VMware Fusion, staff VM
```

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
| `--check` | dry run |

`build.sh` passes any extra arguments straight through, e.g.
`./build.sh "GNS3 VM" pc-student -e verify=all`.

## Requirements

- `ansible-core` (no collections needed), `rsync`, and `sshpass` for the default
  password login
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
