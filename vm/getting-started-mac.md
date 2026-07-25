# Getting Started with GNS3 VM on an Apple Mac

Here are quick instructions for getting GNS3 running as a Virtual Machine (VM) in an Apple Mac. There are different instructions for [getting started with a PC](./getting-started-pc.md) (e.g., Windows or Linux).

These are written for CQUniversity students.

## What do you need?

- **VMWare Fusion virtualisation software**. Fusion is the Mac version of VMWare and is free for personal use, but you do need a Broadcom Support account to download it — see [VMWare for GNS3](./vmware.md) for how to get an account and download the installer.
- **The GNS3 VM Appliance for Mac**. This is a ``.ova`` file, usually multiple GB in size. Your teacher will tell you where to download it from.
- **A web browser**, e.g., Safari or Chrome on your Mac.

> **Make sure you download the Mac appliance.** Macs with Apple Silicon (M1, M2, M3, ...) can only run ARM virtual machines. The appliance used on lab PCs is built for Intel/AMD chips and will import into Fusion but never finish booting. If you are unsure which chip your Mac has, click the Apple menu then *About This Mac*.

In the following we assume you have VMWare Fusion installed and have downloaded the Mac GNS3 VM Appliance (``.ova`` file).

## Import the Appliance into VMWare Fusion

Start VMWare Fusion and from the *File* menu select *Open*, then choose the ``.ova`` file you downloaded.

You may be presented with a *Question* saying the import failed due to OVF conformance. Don't worry, just select *Retry* to relax the checks:

![VMware import question](../images/vmware-import-question-1.png)

Fusion will convert the appliance, which takes a few minutes. It then asks where to save the VM — the default location is fine.

Once imported, open the VM's *Settings* and check the two network adapters:

- **Network Adapter** — *Private to my Mac* (this is Fusion's name for a host-only network)
- **Network Adapter 2** — *Share with my Mac* (this is Fusion's name for NAT)

The first is how your browser reaches GNS3; the second is how the VM reaches the internet. Save the settings.

> Fusion on Apple Silicon has no *Virtualize Intel VT-x/EPT* option — that setting only exists on Intel machines, so ignore it if you are following the [VMWare for GNS3](./vmware.md) instructions written for Windows.

## Start the GNS3 VM

In Fusion select the GNS3 VM and start it. It may take several minutes to boot. Eventually you will see a blue screen with a grey information box:

![GNS3 VM information screen](../images/vmware-gns3-info-1.png)

Take note of the IP address shown. It may be different for different users, and it may change if you add, delete or import other VMs in Fusion.

## Access the GNS3 User Interface with Your Web Browser

Open your web browser on your Mac and visit the IP address from the previous step. That is, in your web browser address bar type in:
```
http://172.16.x.y/
```

**Note carefully** it is *http* (not *https*) and the actual IP address from the information screen must be given (replace x and y with your values).

Also note that this is done in your web browser on the Mac, not inside the GNS3 VM itself.

You should see the main GNS3 UI, such as:
![GNS User Interface](../images/gns3ui-projects-1.png)

You may see a list of pre-loaded projects. If so, click on one to get started using that project. Alternatively, you can import projects (``.gns3project`` files).

You are now ready to use GNS3!

## Differences you may notice on a Mac

- **The IP address range is different.** VMWare's host-only network uses 172.16.x.y addresses, where VirtualBox uses 192.168.56.x. Many activity instructions and demos were written on VirtualBox and show the 192.168.56.x range. This does not affect the activities themselves — the nodes inside a GNS3 project have their own addresses, which are the same on both.
- **A few activities will not run.** Some projects contain nodes that were built for Intel/AMD chips and have no Apple Silicon equivalent. If a node fails to start and your classmates on lab PCs have no trouble, this is the likely reason — ask your teacher rather than assuming you have set something up incorrectly.

---

*Staff:* building the Mac appliance itself is a separate process — see [Building the CQU GNS3 VM](../server/README.md).
