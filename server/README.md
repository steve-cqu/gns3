# Scripts

## Setting up GNS3 VM

Download/copy the following scripts into the GNS3 VM inside ``/home/gns3``, then run them. Make sure you have the .sh script and the ``template_gns3_controller.conf`` file in the GNS3 VM.


![Secure Copy Scripts](../../images/gns3-scp-install-scripts-1.png))

### Copy Firefox Logo

The Firefox.svg logo appears to be missing. So we download and copy into relevant directory.

```
bash vm-install-fflogo.sh
```

![Install Firefox Logo](../../images/gns3-install-script-fflogo-1.png)


### Install noVNC

NoVNC allows access to VNC node in the web browser (avoiding need for students to install VNC client). This installs noVNC in GNS3 VM and creates a simple script that can be run when needed:

```
bash vm-install-vnc.sh
```

![Install NoVNC](../../images/gns3-install-script-vnc-1.png)

### Install Containers (only needed for MacOS)

This manually adds Docker containers, which is sutiable for ARM64. Check the script before running it, as you may need to change USERNAME, PLATFORM.


```
bash vm-install-containers.sh
```

![Install containers](../../images/gns3-install-containers-1.png)


## Other (Obsolete)

This is no longer needed as created in above setup.

- [start-vnc.sh](./start-vnc.sh): Copy to GNS3 VM /home/gns3 directory. Used for VNC web access. See script comments for details.