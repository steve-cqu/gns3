# CQU GNS3 lab appliance

A ready-made virtual machine for running networking, system-security and cryptography labs.
It is a stock [GNS3](https://gns3.com) VM with a curated set of node types added — Linux hosts
and routers, switches, an SDN controller, DNS/DHCP/NTP/web/database servers, a Samba domain
controller, VPN gateways, an IDS, wireless access points and more — so that a lab topology can
be built from working parts instead of assembled from scratch.

It is meant for three kinds of reader:

- **Students** in a CQUniversity unit that uses GNS3. Start with
  [Getting started on a PC](./vm/getting-started-pc.md) or
  [on a Mac](./vm/getting-started-mac.md); your unit tells you where to download the appliance.
- **Readers of *Networking, Security and Cryptography*** who are not at CQU. The book's labs and
  its self-learning lab projects are built for this appliance — the project files it gives you
  reference these node types and will not open on a stock GNS3 VM.
- **Educators and builders** who want a Docker-based GNS3 lab appliance of their own. Everything
  that makes it is in this repository, and [`server/README.md`](./server/README.md) is the build
  manual. It is reproducible from source, without the private repository.

## Getting the appliance

At CQU, your unit's site has the download link and the project files. Elsewhere, a public
download is being set up — one archived record per release, so a given appliance stays citable
and retrievable — and until it exists the route that works today is to
[build it yourself](./server/README.md), which takes one command against a fresh GNS3 VM.

Whichever way you get it, confirm which release you are running. A renamed `.ova` proves
nothing:

```sh
cat /etc/gns3-cqu-release
```

[`RELEASES.md`](./RELEASES.md) records which appliance each cohort was given and what went into it.

## Guides

Student-facing, written to be handed out, and versioned with the appliance they describe:

| Guide | What it covers |
|---|---|
| [Getting started on a PC](./vm/getting-started-pc.md) | VirtualBox, importing the appliance, finding its address |
| [Getting started on a Mac](./vm/getting-started-mac.md) | The same on VMware Fusion, including Apple Silicon |
| [Using the GNS3 web interface](./vm/using-gns3.md) | Building a topology, consoles, and [importing a project](./vm/using-gns3.md#importing-a-project) |
| [VirtualBox for GNS3](./vm/virtualbox.md) | Installing VirtualBox, and the host-only network the appliance needs |
| [VMware for GNS3](./vm/vmware.md) | The same for VMware |
| [Saving your work](./vm/gns3-saving-work.md) | Why configuration on a node disappears when a project is closed, and the one-off setup that stops it |
| [Adding a Windows Host](./vm/windows-host.md) | Running a real Windows machine beside the appliance and joining it to a topology |
| [Troubleshooting](./vm/troubleshooting.md) | Import failures, nodes that will not start, and other common problems |

## Where things live

| Path | What |
|---|---|
| [`vm/`](./vm/) | The student guides above |
| [`server/`](./server/) | Everything that builds the appliance: the manifest, the build engine, the node Dockerfiles, the GNS3 templates and the Ansible wrapper |
| [`server/windows/`](./server/windows/) | Host-side scripts for running a real Windows machine beside the appliance as a lab node |
| [`images/`](./images/) | Screenshots for the guides, and the node symbols installed on the appliance |
| [`RELEASES.md`](./RELEASES.md) | What each release contains, and which cohort got it |

The **activities** that run on the appliance — instructions, worked solutions and project files —
are not here. They belong to the units that set them, and links to `gns3-dev/…` anywhere in this
repository point at that separate, private repository and will not resolve for you. The
appliance is the runtime; the activities are content that travels separately.

## Building it

[`server/README.md`](./server/README.md) is the full build and release runbook. One command
against a freshly imported GNS3 VM produces a configured appliance; see *Building without
`gns3-dev`* there for the short version if you are not at CQU.

Note that `cqugns3/` is a **local image namespace, not a registry**. The build creates those
images on the VM itself; there is nothing to pull, and `docker pull cqugns3/alpinenode` will
fail by design.

## The book

*Networking, Security and Cryptography* — a practical, Linux-based introduction — is the
companion text: <https://steve-cqu.github.io/netsec-crypto/>. This appliance is the environment
its practical half assumes.

## Licence

Code is MIT; the guides, screenshots and node symbols are CC BY 4.0. See [`LICENSE`](./LICENSE)
for both, and [`THIRD-PARTY.md`](./THIRD-PARTY.md) for what is vendored or downloaded at build
time and under what terms — notably `server/docker/net_toolbox/`, which is GPL-3.0.

Windows is never distributed here. The Windows Host scripts automate an installation from media
you download from Microsoft under Microsoft's own terms.
