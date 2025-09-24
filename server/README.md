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
adosztal/net_toolbox   latest    1151fe7a6c65   6 seconds ago   416MB
cqugns3/vpnrouter      latest    a93c8dbe0d47   3 minutes ago   122MB
cqugns3/ansible        latest    77492798867b   3 minutes ago   542MB
gns3/webterm           latest    aec4f5bad4c6   4 minutes ago   718MB
gns3/ipterm            latest    71e5bf020d19   6 minutes ago   110MB
gns3/ipterm-base       latest    9c54f1940ebc   6 minutes ago   110MB
gns3/openvswitch       latest    d660265052ce   9 minutes ago   17.5MB
gns3/endhost           latest    169af3eab1da   9 minutes ago   92.3MB
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
