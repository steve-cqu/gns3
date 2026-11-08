# Guide: Saving Your Work in GNS3

This guide explains why configuration you type into a GNS3 node can disappear, which directories
are kept, and what an exported project does and does not contain.

It applies to the Docker nodes in GNS3 – Linux Host, Linux Router, VPN Router, Ansible Host, Ubuntu
Host, Kerberos Host and Suricata IDS. Nodes that run a full virtual machine, such as OPNsense, keep
their own disk and are not affected.

This is a practical guide only. It does not tell you what network to build or what to submit – that
comes from your own unit's activity instructions.

## What Is Saved and What Is Not

A Docker node is not a computer with a hard disk. It is built fresh from a stored image, and GNS3
keeps only the directories it has been told to keep. Everything else lives in the running node and
disappears when that node is rebuilt.

Three things behave differently, and the difference matters:

- **Stopping and starting a node** keeps everything. The node is paused, not rebuilt.
- **Closing a project and opening it again** rebuilds every node from its image. Anything outside a
  kept directory is gone.
- **Restarting or shutting down the GNS3 VM** has the same effect as closing the project.

Which directories are kept depends on the node type and on how old your GNS3 VM is. On a current
appliance (v044 and later), the general-purpose nodes keep `/etc`, `/root`, `/home`, `/data` and
`/usr/local/bin` (Linux Host and Ubuntu Host also keep `/var/www`), and each server node also keeps
its own data directory. Some nodes keep far less: Suricata IDS keeps only its configuration, rule
and log directories, FRR keeps only `/etc/frr`, and NETem keeps nothing you would edit. Everything else, including `/tmp`, `/var/log`, `/opt` and any software you installed, is
lost when you close a project.

On an **older** appliance, only `/etc/ssh`, `/root/.ssh`, `/data` and `/home/student` were kept.
That is why work such as a certificate authority under `/root`, a WireGuard key in
`/etc/wireguard`, a user account in `/etc/shadow` or a Kerberos database in `/var/lib/krb5kdc` was
lost when you closed a project, even though your `sshd_config` survived. *Nodes That Keep Too
Little* below says what to do about a project from one.

There is one more thing that is never kept, no matter what you do: **running programs**. A web
server, `suricata`, a listener you started with `nc`, or the SSH daemon are processes, not files.
After you open a project again you must start them again, even when their configuration files are
exactly as you left them.

## Nodes That Keep Too Little

A current appliance (v044 and later) sets the kept directories for you, on every node type, so
there is nothing to set up. You only need the steps below in two cases: a project built on an older
appliance, whose nodes keep only the old short list, or a single node you want to keep an extra
directory on.

The kept directories are a property of each node, set when the node is created. Moving a project
to a newer appliance does not change the nodes already in it.

For a project from an older appliance, you have two choices. The simpler one
is to build the project again – for most activities this takes a few minutes, and the configuration
inside it was not being kept anyway. The alternative is to set the directories by hand on each node:

1. Stop the node.
2. Right-click the node and choose *Configure*.
3. Open the *Advanced* tab and find *Additional directories*.
4. Add one directory per line. For most nodes use `/etc`, `/root`, `/var/www` and `/usr/local/bin`.
5. Click *Apply*, then start the node again.

![The Advanced tab of a node, with directories listed one per line under Additional directories](../images/gns3-configure-advanced-additional-directories-1.png)

The same steps are how you fix a single node at any time, for example if you add one node to a
project you built earlier.

## Give a Node Its Name Before You Start It

One of the kept directories is `/etc`, and `/etc` holds the `hosts` file – the small table a node
uses to look up names, including its own. That file is written once, the first time the node starts,
with whatever the node was called at that moment.

So if you rename a node after it has run, the name in the topology changes but the name inside the
file does not. The node keeps answering to its new name, but looking up that name on the node itself
fails, and some commands print a warning about being unable to resolve the host.

Label your nodes as you add them, before you start them. If you do rename one later and see that
warning, open the node console and edit the first line of `/etc/hosts` – the one on `127.0.1.1` – to
the new name.

## What an Exported Project Contains

Exporting a project writes a single `.gns3project` file containing the topology – the nodes, how
they are connected, and their settings – together with the contents of every kept directory.

An export therefore contains your actual configuration, and
importing that file on another computer gives you your work back. This makes the export worth
keeping as your own record, and it is a habit worth having regardless of what any particular
activity asks you to submit.

Two things are worth knowing. First, an export contains private keys if your activity created any –
treat the file as something you would not post publicly. Second, an export never contains running
programs, so after importing you always start the services again.

Before you export, start all nodes, wait until they are green, then stop all nodes. GNS3 only makes
a node's kept directories readable for the export when it stops a node that has been started, so
skipping this can make the export fail with `Permission denied` on a folder such as
`/etc/wireguard`. The built-in switches stay green after stopping, and that is normal.

To export, right-click the project name and choose the export option, then save the file somewhere
outside the GNS3 VM.

## Starting a Node Again From Scratch

Keeping configuration has a cost. A mistake is now kept as faithfully as a success, so a broken
`sshd_config` or a half-finished database follows you into the next session instead of being cleared
when you open the project again.

When a node is in a state you cannot untangle, the quickest fix is to start it again from scratch:
delete the node, then add a new one of the same type from the palette and reconnect it. The new node
is built from the stored image with nothing carried over. Remember that you will need to set its
address again.

## Snapshots Are Not a Backup

GNS3 offers snapshots of a project. A snapshot captures only the same kept directories, so it is not
a way of protecting work that is not being kept in the first place. Use an export as your
record. Do not rely on a snapshot to bring back a configuration you
have lost.
