# Setting up GNS3 VM (for Staff)

## Copy Install Files

You can use Git to clone the GNS3 repository to obtain the install files. First login to the GNS3 VM with Shell access. then run:

```
mkdir git
cd git
git clone https://github.com/steve-cqu/gns3.git
cd git/gns3/server/
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

## Install Qemu VMs

Download the Qemu VM images, for a Windows/Linux host:

```
bash vm-install-qemuvms.sh pc
```

or for an Apple Mac host:

```
bash vm-install-qemuvms.sh mac
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
