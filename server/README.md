# Setting up GNS3 VM (for Staff)

## Copy Install Files

You can use Git to clone the GNS3 repository to obtain the install files. First login to the GNS3 VM with Shell access. then run:

```
mkdir git
cd git
git clone https://github.com/steve-cqu/gns3.git
cd gns3/server/
```

Now you can run the following install scripts.

## Install Logos

Some logos are not included in the standard directory. This downloads them and puts them in the correct directory:

```
bash vm-install-logos.sh
```


## Install noVNC

NoVNC allows access to VNC node in the web browser (avoiding need for students to install VNC client). This installs noVNC in GNS3 VM and creates a simple script that can be run when needed:

```
bash vm-install-vnc.sh
```

## Install Docker Containers

Install Docker containers, for a Windows/Linux host:

```
bash vm-install-containers.sh pc
```

or for an Apple Mac host:

```
bash vm-install-containers.sh mac
```

Example result is:
```
REPOSITORY             TAG       IMAGE ID       CREATED         SIZE
adosztal/net_toolbox   latest    485fb9402b4e   5 seconds ago   416MB
cqugns3/alpinenode     latest    3200f987131c   3 minutes ago   575MB
gns3/webterm           latest    453bb6679762   4 minutes ago   718MB
gns3/ipterm            latest    b6e30f6baefc   7 minutes ago   110MB
gns3/ipterm-base       latest    58d195564a49   7 minutes ago   110MB
gns3/openvswitch       latest    b9848ec79e6f   9 minutes ago   17.5MB
```


## Install Qemu VMs

Download the Qemu VM images, for a Windows/Linux host:

```
bash vm-install-qemuvms.sh pc
```

or for an Apple Mac host:

```
bash vm-install-qemuvms.sh mac
```

Example result is:
```
Windows/Linux detected
Downloading NETem-v4.qcow2 ...
NETem-v4.qcow2: OK
Downloading ubuntu-24.04-server-cloudimg-amd64.img ...
ubuntu-24.04-server-cloudimg-amd64.img: OK
ubuntu-cloud-init-data.iso: OK
Image resized.
Downloading openwrt-23.05.0-x86-64-generic-ext4-combined.img ...
gzip: openwrt-23.05.0-x86-64-generic-ext4-combined.img.gz: decompression OK, trailing garbage ignored
openwrt-23.05.0-x86-64-generic-ext4-combined.img: OK
Downloading OPNsense-24.1-nano-amd64.img ...
OPNsense-24.1-nano-amd64.img: OK
-rw-r--r-- 1 gns3 gns3    1048576 Apr  6  2020 /opt/gns3/images/QEMU/config.img
-rw-rw-r-- 1 gns3 gns3  126353408 Oct 12  2023 /opt/gns3/images/QEMU/openwrt-23.050-x86-64-generic-ext4-combined.img
-rw-rw-r-- 1 gns3 gns3 3221225472 Jan 29  2024 /opt/gns3/images/QEMU/OPNsense-241-nano-amd64.img
-rw-rw-r-- 1 gns3 gns3  587268184 Sep 24 11:20 /opt/gns3/images/QEMU/ubuntu-2404-server-cloudimg-amd64.img
```

## Install Templates

Update the tempplates for all Docker and Qemu images installed:

```
bash vm-install-templates.sh pc all
```

or for Apple Mac:

```
bash vm-install-templates.sh mac all
```


or if only Docker container templates needed:

```
bash vm-install-templates.sh pc docker
```

or if only Qemu VM templates needed:

```
bash vm-install-templates.sh pc qemu
```

## Cleanup

Temporary files can be deleted:
```
sudo apt clean
```

## Shutdown and Snapshot

You are recommended to now shutdown the GNS3 VM and take a snapshot.