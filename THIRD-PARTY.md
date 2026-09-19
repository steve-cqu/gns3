# Third-party material

What this repository does not own, where it comes from, and under what terms.
The repository's own licences are in [`LICENSE`](LICENSE): MIT for code, CC BY 4.0 for
documentation and images.

Nothing here is redistributed as a binary. The build downloads what it needs at build time,
so an appliance contains third-party software that this repository only ever *fetched*.

## Vendored into this repository

| What | Where | Licence | Notes |
|---|---|---|---|
| **net_toolbox** | `server/docker/net_toolbox/` | **GPL-3.0** — see its own `LICENSE` | A clone of András Dosztál's GNS3 network toolbox image, kept locally so the build does not depend on an upstream branch. It is the one directory here under a copyleft licence, and it keeps its own licence file for that reason. |

## Fetched from the GNS3 registry at build time

Five node images are built from Dockerfiles held in the
[GNS3 registry](https://github.com/GNS3/gns3-registry), not in this repository:

`openvswitch`, `ipterm-base`, `ipterm`, `webterm`, `kali`

They are fetched from a **pinned commit** (`eba400be` — see `registry_base` in
`server/build/manifest.yml`), and every file carries a sha256 in the manifest that is verified
after download. The pin is deliberate: an unpinned branch once changed an image's behaviour
between a passing build and a failing one with nothing in this repository changing.

The GNS3 registry is licensed by its authors; the images built from those Dockerfiles pull
their own upstream packages under their own terms. `kali` is `optional:` as of 19 September
2026 and a default build does not install it.

## Base images

Locally-built nodes derive from these, pulled from Docker Hub at build time:

| Base | Used by |
|---|---|
| `alpine:3.24` | `alpinenode` (and through it nine further images), `suricata`, `netemnode` |
| `ubuntu:24.04` | `ubuntunode`, and `patchnode` which derives from it |
| `ubuntu:focal` | `net_toolbox` |
| `debian:bookworm-slim` | `frrnode`, `wazuh-agent` |
| `openwrt/rootfs` | `openwrtnode` |

Each carries its distribution's own licensing, and the packages installed into them carry
theirs. **These four bases are not yet pinned by digest** — see the reproducibility mandate in
`server/README.md`; they are to be pinned immediately before a golden build.

## Qemu disk images

All Qemu nodes are `optional:` and a default build installs **none** of them. When one is
requested with `--with`, the disk is downloaded from its upstream and checked against the md5
in `server/build/manifest.yml`:

| Node | Source |
|---|---|
| `opnsense` / `opnsense-arm64` | OPNsense (BSD-2-Clause); the arm64 image is a community build by Maurice W |
| `openwrt` / `openwrt-arm64` | OpenWrt project releases (GPL-2.0 and others) |
| `ubuntu-cloud` / `ubuntu-cloud-arm64` | Canonical Ubuntu cloud images |
| `frr-qemu` | FRRouting appliance published on the GNS3 SourceForge project |
| `netem-qemu` | NETem appliance published on the GNS3 SourceForge project |

## Software installed into the node images

Every node image installs packages from its distribution's repositories — FRR, strongSwan,
Suricata, Faucet, Samba, PostgreSQL, Valkey, Kea, Prometheus, Grafana, Gitea, hostapd, nginx,
BIND and others, each under its own licence. The images are built, not shipped from here, so
this repository redistributes none of them. `server/build/manifest.yml` and the Dockerfiles
under `server/docker/` are the authoritative list of what goes into each one.

## Not distributed here

**Windows.** The Windows Host scripts in `server/windows/` automate an installation from media
the user downloads themselves from Microsoft, under Microsoft's licence terms. No Windows
image, key or installer is held in this repository.

**GNS3 itself.** The appliance is built on top of the official GNS3 VM
(see `gns3_version` in the manifest). GNS3 is GPL-3.0 and is obtained from its own project.
