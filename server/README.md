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

## Building the VM — new way

### One command, from your own machine

``ansible/build.sh`` finds the VM's IP from the hypervisor, syncs this repo to it, runs the
whole build, imports the projects and verifies the result:

```
cd ansible
./build.sh "GNS3 VM" pc-student            # VirtualBox (PC)
./build.sh ~/VMs/GNS3.vmx mac-staff        # VMware Fusion (Apple Silicon)
```

See ``ansible/README.md``. Everything below is what that runs under the hood, and is
still the way to drive individual steps.

### The engine, run on the VM

``build/gns3build.py`` builds the whole VM from a single manifest (``build/manifest.yml``)
instead of the ``vm-install-*.sh`` scripts. Every phase is idempotent, so re-running only
does the work still outstanding:

```
cd git/gns3/server/build
./gns3build.py build --profile pc-student
```

That runs, in order: ``templates`` → ``docker`` → ``qemu`` → ``logos`` → ``novnc`` →
``projects``. Each is also a subcommand you can run on its own:

```
./gns3build.py plan      --profile pc-staff   # show what would be installed, change nothing
./gns3build.py templates --profile pc-staff   # register templates via the GNS3 API
./gns3build.py docker    --profile pc-staff   # build the Docker node images
./gns3build.py qemu      --profile pc-staff   # download + verify the Qemu disk images
./gns3build.py logos                          # install the CQU node symbols
./gns3build.py novnc                          # install noVNC + start-vnc.sh
./gns3build.py projects  --profile pc-staff   # import the audience's .gns3project files
./gns3build.py validate                       # check the manifest and templates
```

Profiles are ``{pc,mac}-{student,staff}``: the platform picks the arch (``pc`` = amd64
images and amd64 Qemu disks, ``mac`` = arm64), the audience picks the project set
(``projects-student.txt`` / ``projects-staff.txt``). Useful options:

* ``--only frrnode,netemnode`` — work on just those nodes (handy while iterating);
  on ``build`` it selects phases instead, and ``--skip`` leaves phases out
* ``--force`` — rebuild an image / re-download a disk that is already present
  (needed after editing a Dockerfile, since an existing image is otherwise skipped)
* ``--dry-run`` — print what would happen and change nothing
* ``qemu --verify`` — re-hash disks already present instead of trusting their ``.md5sum``
* ``projects --roots dirA,dirB`` — where to look for ``<Name>.gns3project`` (searched
  recursively, first match wins); defaults to ``/home/gns3/projects``. **Order matters** —
  put the authoritative copy first. If a project is found under more than one root the
  phase prints a ``DUP`` line naming which file it used and which it ignored; heed it,
  because stale exports can share a ``project_id`` with the rebuilt original and
  importing one silently shadows the other.

``templates``, ``projects``, ``plan`` and ``validate`` also take ``--server
http://<vm-ip>`` and can be run from your own machine — importing projects that way
streams them straight to the VM's API, so you don't have to copy them onto the VM first.
``docker``, ``qemu``, ``logos`` and ``novnc`` must run on the VM itself.

Nothing here edits ``gns3_controller.conf`` or restarts the GNS3 service — templates are
registered through the REST API, which is additive and safe to repeat. The ``logos`` phase
finds gns3server's symbols directory by globbing rather than assuming a ``python3.9``
path, and warns if any template names a symbol that isn't there.

## Install Nodes (Docker Containers and Qemu VMs) — old way

The file ``nodelist-pc.txt`` lists the Docker containers and Qemu VMs to install. You can edit the file to comment (#) those that you do not want. 

On a PC:
```
bash vm-install-nodes.sh pc nodelist-pc.txt
```

On a Mac, edit ``nodelist-mac.txt`` and run:
```
bash vm-install-nodes.sh mac nodelist-mac.txt
```

Note the Mac differences: Docker images are built for arm64, and Qemu VMs use arm64 images (``-mac`` node names). No arm64 Qemu images exist for FRR and NETem, so on a Mac these are installed as Docker containers instead (``docker-cqugns3-frrnode`` and ``docker-cqugns3-netemnode``). The templates keep the same names (*FRR*, *NETem*) so activity instructions are unchanged, but projects exported from a PC VM that contain Qemu FRR/NETem/OpenWrt/OPNsense nodes will not run on a Mac VM - solution projects must be rebuilt on the Mac using its templates.
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


