# Setting up GNS3 VM (for Staff)

These instructions are for staff that create a GNS3 VM for distribution. There are three steps:
1. Install the logos, software, Docker containers, Qemu VMs and templates needed
2. Importing projects for a student VM
3. Importing additional projects for a staff only VM

You are recommended to make a snapshot after each step, and export an appliance after step 2 (GNS3-CQU-vxxx-studentid.ova) and step 3 (GNS3-CQU-vxxx-StaffOnly.ova).

# Installing the GNS3 VM

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

## Install Nodes (Docker Containers and Qemu VMs)

The file ``nodelist-pc.txt`` lists the Docker containers and Qemu VMs to install. You can edit the file to comment (#) those that you do not want. 

On a PC:
```
bash vm-install-nodes.sh pc nodelist-pc.txt
```

On a Mac, edit ``nodelist-mac.txt`` and run:
```
bash vm-install-nodes.sh mac nodelist-mac.txt
```
## Shutdown and Snapshot

You are recommended to now shutdown the GNS3 VM and take a snapshot.

# Importing Student Projects

## Transfer Projects to the GNS3 VM

Start the GNS3 VM and login with the shell then:
```
mkdir -p /home/gns3/projects
cd git/gns3/server
```

Using a file transfer program (e.g., FileZilla in Windows or scp in Linux), copy the .gns3project files into the /home/gns3/projects directory inside GNS3. These projects are not available on this GitHub repository. Only staff have access to the actual projects.

## Import the Projects

Run the import script:
```
bash vm-import-projects.sh projects-student.txt
```

## Delete the Projects

This is only required if the projects you transferred included *staff only* projects. You should NOT leave them in the VM that is distributed to students.
```
rm -f /home/gns3/projects/*
```

## Shutdown, Snapshot and Export Appliance

Shutdown the VM, take a snapshort and export appliance, e.g., ``GNS3-CQU-vxxx-studentid.ova``.

# Importing Staff Only Projects

Start the GNS3 VM and login with the shell then:
```
mkdir -p /home/gns3/projects
cd git/gns3/server
```

Using a file transfer program (e.g., FileZilla in Windows or scp in Linux), copy the .gns3project files into the /home/gns3/projects directory inside GNS3. These projects are not available on this GitHub repository. Only staff have access to the actual projects.

## Import the Projects

Run the import script:
```
bash vm-import-projects.sh projects-staff.txt
```

You may optionally delete the projects, e.g., ``rm -f /home/gns3/projects/*`` but that is not required.

## Shutdown, Snapshot and Export Appliance

Shutdown the VM, take a snapshort and export appliance, e.g., ``GNS3-CQU-vxxx-StaffOnly.ova``.


