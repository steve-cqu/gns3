# Restoring a CQU GNS3 appliance from the archive

**Copy this file to the shared-drive folder with every release**, filling in the placeholders at
the top. It is written for someone — quite possibly you — opening the folder in 2028 with no
memory of how any of it works.

The appliance is deliberately frozen: it is built once, verified, archived, and then shipped
unchanged for as long as the unit content allows. Security updates are **not** applied between
releases. That is a decision, not an oversight — a lab appliance that behaves identically all
term is worth more here than one that silently patches itself.

---

## Fill this in per release

| | |
|---|---|
| Release | `vNNN` |
| Built | *date* |
| Built by | *name* |
| GNS3 version | *e.g. 2.2.61* — the appliance is pinned to the 2.2 line; **do not move to GNS3 3.x** |
| Terms shipped to | *e.g. T3 2026, T1 2027* |
| `gns3` repo tag | `vNNN` |
| `gns3-dev` repo tag | `vNNN` |

---

## What is in this folder

```
gns3-vNNN/
  gns3-cqu-vNNN-amd64.ova          + .sha256   the appliance, PC/Intel
  gns3-cqu-vNNN-arm64.ova          + .sha256   the appliance, Apple Silicon
  frozen-vNNN-amd64.tar.gz         + .json     every Docker image, saved
  frozen-vNNN-arm64.tar.gz         + .json
  qemu-images-vNNN.tar             + .sha256   the Qemu disk images
  gns3-vm-<version>/                           the upstream GNS3 VM appliance
  repos/gns3.bundle                            full git history + tags
  repos/gns3-dev.bundle
  RESTORE.md                                   this file
```

| File | What it is | Why it is here |
|---|---|---|
| `*.ova` | The complete built appliance | The whole answer. Everything else is a fallback. |
| `frozen-*.tar.gz` | `docker save` of all 16 node images, gzipped | Rebuild the appliance with **no network**. The `.json` sidecar records each image's ID and the archive's sha256. |
| `qemu-images-*.tar` | OpenWRT, OPNsense, Ubuntu cloud, FRR, NETem disks | All five are `optional:` as of 20 August 2026, so a default build installs none of them and this archive is only worth making for an appliance built `--with`. Keep the disks anyway: they live on SourceForge, a community mirror and a personal GitHub release, and at least one will have 404'd by the time they are wanted. |
| `gns3-vm-<version>/` | The upstream GNS3 VM the appliance is built on | GNS3 retires old downloads. 2.2.x will not be available forever. |
| `repos/*.bundle` | Both git repositories, full history | Source of truth for Dockerfiles, activities and build scripts. |

---

## Which path do I need?

Work down this list and stop at the first one that applies. **Higher is better** — each step
down adds dependencies that may no longer exist.

### 1. "I just need to give students the appliance again"

Import the `.ova`. Nothing else in this folder is needed. Verify first:

```sh
sha256sum -c gns3-cqu-vNNN-amd64.ova.sha256
```

Confirm the running appliance identifies itself — a renamed `.ova` proves nothing:

```sh
cat /etc/gns3-cqu-release
```

**This is the answer for a repeat term with unchanged content.** Do not rebuild.

### 2. "I need to change something, but keep everything else identical"

Adding an activity, a project file or a node — the normal between-terms case.

1. Start the VM from the `.ova`, or build a fresh VM from `gns3-vm-<version>/`.
2. Restore the Qemu disks into `qemu_images_dir` (`/opt/gns3/images/QEMU`), as the `gns3`
   user — it owns that directory, so no `sudo` is needed:
   ```sh
   sha256sum -c qemu-images-vNNN-amd64.tar.sha256
   tar -xf qemu-images-vNNN-amd64.tar -C /opt/gns3/images
   ```
   The archive carries the `.md5sum` sidecars with the disks, so `gns3build.py qemu` trusts the
   restored files instead of re-downloading them — which is the whole point, since several of
   those URLs will be dead.
3. Restore the Docker images — **no network, no upstream, byte-identical to what shipped**:
   ```sh
   python3 server/build/gns3build.py thaw --in frozen-vNNN-amd64.tar.gz
   ```
   `thaw` verifies the archive against its `.json`, loads it, then confirms every expected image
   is present. Add `--skip-verify` to skip the hash (it is several GB and slow).
4. Run the remaining phases **on the VM**, with `docker` skipped since `thaw` already did it:
   ```sh
   python3 server/build/gns3build.py build --profile amd64 \
           --skip docker,projects --server http://localhost
   ```
5. Import the projects **from the control node**, not the VM:
   ```sh
   python3 server/build/gns3build.py projects --profile amd64 \
           --server http://<vm-ip> --roots ../gns3-dev/activities,../infiles
   ```
6. Verify before shipping — see *Verifying a restore* below.

### 3. "I have to rebuild from source"

The last resort. Clone from the bundles and run a normal build:

```sh
git clone repos/gns3.bundle gns3
git clone repos/gns3-dev.bundle gns3-dev
cd gns3 && git checkout vNNN
cd ../gns3-dev && git checkout vNNN
cd ../gns3/server/ansible && ./build.sh "GNS3 VM" amd64
```

**Expect this to fail, and read the next section before you start.**

---

## Why a from-source rebuild may not work

A rebuild resolves live software from the internet. The repo pins what it can — `registry_base`
is a commit SHA, every registry file carries a sha256, every Qemu image has an md5 — but these
are outside anyone's control:

| Dependency | How it fails |
|---|---|
| Docker Hub `alpine:3.24`, `ubuntu:24.04`, `debian:bookworm-slim`, `ubuntu:focal` | Tags persist but are rebuilt; content differs unless digest-pinned |
| Alpine CDN, **v3.24 main + community** | Alpine branches go EOL after ~2 years and leave the mirrors |
| Ubuntu **focal** archive (`net_toolbox`) | Already moving to `old-releases.ubuntu.com`; `apt-get update` fails |
| **`alpine/edge/testing`** for `tayga` (`ipv6node`) | A rolling branch — it *will* have moved |
| `packages.wazuh.com/4.x` | 4.x moves on |

The dangerous case is not a hard failure. It is a build that **succeeds** with different software
in it — a different Grafana whose UI no longer matches the monitoring activity's steps, or an
OpenSSH that dropped an algorithm three activities depend on. Both have happened before.

**So: if you get here, verify the result properly rather than assuming a green build is correct.**

---

## Verifying a restore

Never ship an unverified appliance. In order:

```sh
# 1. every image present and the templates registered
python3 server/build/gns3build.py export-check --profile amd64 --server http://<vm-ip>

# 2. the full activity matrix — tens of minutes, and the real gate
cd gns3-dev
python3 tools/gns3_autotest.py --all --arch amd64 --server http://<vm-ip>
```

Then by hand, because no harness covers them:

- **Open vSwitch actually switches.** `stp-basics`, `vlan-basics` and `vlan-router` are the
  canaries for the whole image set — they have failed before because a container exited at
  startup while everything else looked fine.
- **The monitoring activity end to end**, since its deliverable is a Grafana dashboard built in
  a browser.
- **Persistence** — build a Grafana dashboard, close the project, reopen it, confirm it is still
  there. It is an assessed output.

Compare the appliance against what shipped:

```sh
python3 server/build/gns3build.py provenance --profile amd64 --server http://localhost
```

Image **IDs** are content hashes, so they identify the exact bytes even for a `:latest` tag. Diff
them against `frozen-vNNN-amd64.tar.gz.json`. Any difference means you did not reproduce the
release, whatever the build log said.

---

## Making the archive (at release time)

```sh
# on the VM, after the build is verified
python3 server/build/gns3build.py freeze --profile amd64 --out frozen-vNNN-amd64.tar.gz
# Only if this build asked for an optional Qemu node (`--with`); a default build has none.
tar -cf qemu-images-vNNN-amd64.tar -C /opt/gns3/images QEMU     # ~3.7 GB, mostly OPNsense

# on the workstation
git -C gns3     bundle create gns3.bundle --all
git -C gns3-dev bundle create gns3-dev.bundle --all
```

**Or just run the script**, which does all of the above plus the checksums and this file:

```sh
server/archive-release.sh vNNN ~/archive --vm-host <vm-ip> \
    --ova ~/ova/gns3-cqu-vNNN-amd64.ova \
    --vm-appliance ~/Downloads/GNS3VM.VirtualBox.<ver>.zip
# then again with --arch arm64 --vm-host <arm64-vm>, same output directory
```

`git bundle` rather than a copied `.git` directory: one file, full history and tags, survives
being moved around a Windows share, and clones back with `git clone gns3.bundle`.

**Freeze only after verification.** An archive of a half-built or unverified set is worse than no
archive, because it looks authoritative.

The release checklist proper — tagging both repos, the RELEASES.md row, publishing the handout
projects — is in [`RELEASES.md`](../RELEASES.md).
