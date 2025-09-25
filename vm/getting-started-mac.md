# Getting Started with GNS3 VM on an Apple Mac

Here are quick instructions for getting GNS3 running as a Virtual Machine (VM) in an Apple Mac. There are different instructions for [getting started with a PC](./getting-started-pc.md) (e.g., Windows or Linux).

These are written for CQUniversity students.

## What do you need?

- VMWare virtualisation software.
-  GNS3 VM Appliance. This is a ``.ova`` file. It is usually multiple GB in size. Your teacher will tell you where to download the ``.ova`` file from. 
- A web browser, e.g., Safari on Mac.

In the following we assume you have VMWare running successfully and have downloaded the GNS3 VM Appliance (``.ova`` file).

## Import the Appliance into VMWare


## Start the GNS3 VM

In VMWare select the new GNS3 VM and *Start* the VM. It may take several minutes to boot. Eventually you will see a blue screen with a grey information box:

![GNS3 VM information screen](../images/)

Take note of the IP address shown. It may be different across different users, and it may change if you add/delete/import other VMs in VMWare.

## Access the GNS3 User Interface with Your Web Browser

Open your web browser on Windows and visit the IP address from the previous step. That is, in your web browser address bar type in:
```
http://192.168.x.y/
```

**Note carefully** it is *http* (not *https*) and the actual IP address must be given (replace x and y with your values).

Also note that this is done on your web browser in Windows, not inside VirtualBox. 

You should see the main GNS3 UI, such as:
![GNS User Interface](../images/gns3ui-projects-1.png)

You may see a list of pre-loaded projects. If so, click on one to get started using that project. Alternatively, you can import projects (``.gns3project`` files).

You are now ready to use GNS3!
