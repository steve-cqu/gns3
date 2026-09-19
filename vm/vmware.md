# VMware for GNS3

**VirtualBox is the recommended path and most instructions assume it** — at CQU because the lab computers have it installed, and generally because the appliance is exported and tested as a VirtualBox `.ova`.

However if you want to use VMware on your personal laptop (instead of VirtualBox), then it should be possible. 

## Installing VMware

### Installing VMware Workstation on Windows or Linux

VMware Workstation (for Intel chips, e.g., Windows, Linux) is free. However you do need a Broadcom Support account to download the software. 

Go to [https://support.broadcom.com/web/ecx](https://support.broadcom.com/web/ecx) and Register for a new Broadcom Support account. Once you have an account, login and visit *My Downloads* then search for VMware. Find *VMware Workstation Pro* for Windows (or Linux if you are running Linux natively). Follow the steps to download the installer. You may be required to supply your address and agree to various terms and conditions. You are responsible for abiding by them.

Once the installer is downloaded, run it to install VMware. You will need administrator privileges.

### Installing VMware Fusion on Apple Mac

VMware Fusion is for Apple Mac computers with M1, M2, ... chips (i.e., Apple Silicon). Follow the same approach as installed VMware Workstation on Windows, but look for VMware Fusion.

## Using VMware with GNS3

The existing .ova files provided for import into VirtualBox can also be imported into VMware **Workstation**, i.e. on an Intel or AMD machine. However there are several changes you may need to make.

**On an Apple Silicon Mac this does not apply:** those .ova files are built for Intel/AMD chips and will not boot under Fusion, no matter which settings you change. A separate Mac appliance is provided instead — see [Getting Started with GNS3 on an Apple Mac](./getting-started-mac.md), and follow that page rather than the Windows steps below.

From the *File* menu select *Open* and choose the .ova file (see [Getting Started with GNS3](./getting-started-pc.md) for the location of the .ova file). 

You will likely be presented with a *Question* saying the import failed due to OVF conformance. Don't worry, just select *Retry* to relax the checks:

![VMware import question](../images/vmware-import-question-1.png)

The .ova should now import. Once imported there are some settings that should be changed (via the *Settings* menu for the VM):
- Processors, Virtualize Intel VT-x/EPT or AMD-V/RVI can be enabled (if possible)
- Network Adapter, Host-only
- Network Adapter 2, NAT

Save the settings and start the VM.

![VMware Settings Processors VT-x](../images/vmware-settings-vtx-1.png)

![VMware Settings Network Adapter Host-only](../images/vmware-settings-hostonly-1.png)

![VMware Settings Network Adapter 2 NAT](../images/vmware-settings-nat-1.png)

Once the GNS3 VM starts you have the same environment as using VirtualBox. That is, you now use a web browser to visit the IP address shown in the GNS3 information screen.

![VMware GNS3 Information](../images/vmware-gns3-info-1.png)

Note however the IP addresses used by VMware host-only adatper (172.16.185.xx) are different than used by VirtualBox host-only adapter (192.168.56.xx). This normally will not cause any problems, as the nodes in GNS3 projects have their own IP address range. Just be aware that many activity instructions and demos use the VirtualBox host-only IP address range.

