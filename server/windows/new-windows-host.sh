#!/bin/sh
# new-windows-host.sh - create the Windows Host VM beside the GNS3 VM, on VMware Fusion.
#
# Run this ON YOUR MAC, in Terminal, once. It does what Steps 3 and 4 of the Windows Host
# guide ask you to do by hand: it builds a Windows 11 virtual machine with the two network
# adapters the lab needs, attaches your Windows ISO and the CQU unattend ISO, and starts it.
#
# Why this is a shell script and the PC has a PowerShell one: Fusion has no unattended-install
# command. VirtualBox answers Setup's questions itself; on Fusion the answers have to travel
# on a second CD as an autounattend.xml, which is what make-unattend-iso.sh builds.
#
# What it does:
#   - writes a .vmx by hand, so the adapter order - and therefore which interface is the lab
#     one - is fixed here rather than decided by Fusion. That is the whole problem on a Mac:
#     an adapter added later through Add Device gets a high PCI slot number and enumerates
#     EARLIER than the ones already there, which silently swaps the lab and NAT adapters
#   - gives the VM two adapters: NAT for the internet, and your custom cqulab network
#   - creates the virtual disk and attaches both ISOs
#   - starts the machine
#
# What it does NOT do:
#   - it does not touch the GNS3 VM. Its adapters are still yours to set, per the guide
#   - it does not create the cqulab network. Fusion's custom networks are made in
#     Settings > Network, and the vmnet number Fusion picks is local to your Mac, which is
#     exactly why this script cannot guess it. Run --list to see the ones you have
#   - it does not download a Windows ISO, and it does not activate Windows
#   - on Apple Silicon it cannot finish the job unaided: see APPLE SILICON below
#
# APPLE SILICON. Windows 11 ARM64 has no in-box driver for Fusion's default vmxnet3
# adapter, so a freshly installed machine has no network at all. This script asks for
# e1000e instead, which Windows should have a driver for - that is the intended fix and it
# is the first thing to verify when you test this. If the machine still has no network,
# install VMware Tools from Fusion's menu and it will appear. You may also have to bypass
# Setup's "Let's connect you to a network" screen: Fn+Shift+F10, then
#     start ms-cxh:localonly
#
# Safe to re-run: if the VM folder already exists this stops rather than overwriting it.
#
# Usage:
#   ./new-windows-host.sh --iso ~/Downloads/Win11_ARM64.iso --vmnet vmnet3
#   ./new-windows-host.sh --list                 show Fusion, the custom networks, the VM
#   ./new-windows-host.sh --dry-run --iso ...    print the .vmx and the commands, do nothing
#   ./new-windows-host.sh --help
#
# Options:
#   --iso <path>       Windows 11 ISO you downloaded                        (required)
#   --vmnet <name>     the custom network you named cqulab, e.g. vmnet3     (required)
#   --unattend <path>  CQU unattend ISO from make-unattend-iso.sh    (default: beside this script)
#   --name <name>      VM name                                       (default: WindowsHost)
#   --memory <MB>      RAM                                           (default: 4096)
#   --cpus <n>         processors                                    (default: 2)
#   --disk <GB>        virtual disk size                             (default: 64)
#   --dir <path>       where to put the VM      (default: ~/Virtual Machines.localized)
#   --no-tpm           omit the virtual TPM (then Windows 11 needs the bypass keys in
#                      autounattend.xml - see the comment block in that file)
#   --no-start         build it but do not start it
#   --dry-run          print everything, change nothing
#   --list             report what is here and stop

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

NAME=WindowsHost
MEMORY=4096
CPUS=2
DISK=64
ISO=
VMNET=
UNATTEND="$SCRIPT_DIR/cqu-unattend.iso"
VMDIR="$HOME/Virtual Machines.localized"
TPM=yes
START=yes
DRY=no
LIST=no

die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)   sed -n '2,58p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --iso)       ISO=${2:?--iso needs a path}; shift 2 ;;
        --vmnet)     VMNET=${2:?--vmnet needs a name}; shift 2 ;;
        --unattend)  UNATTEND=${2:?--unattend needs a path}; shift 2 ;;
        --name)      NAME=${2:?--name needs a value}; shift 2 ;;
        --memory)    MEMORY=${2:?--memory needs a value}; shift 2 ;;
        --cpus)      CPUS=${2:?--cpus needs a value}; shift 2 ;;
        --disk)      DISK=${2:?--disk needs a value}; shift 2 ;;
        --dir)       VMDIR=${2:?--dir needs a path}; shift 2 ;;
        --no-tpm)    TPM=no; shift ;;
        --no-start)  START=no; shift ;;
        --dry-run)   DRY=yes; shift ;;
        --list)      LIST=yes; shift ;;
        *)           die "unknown option: $1 (try --help)" ;;
    esac
done

# --------------------------------------------------------------------------- #
# Fusion's command-line tools. Neither is on the PATH, and they live in different
# directories inside the app bundle - the same trap the build host setup documents.
# --------------------------------------------------------------------------- #
FUSION="/Applications/VMware Fusion.app"
VMRUN="$FUSION/Contents/Public/vmrun"
VDISK="$FUSION/Contents/Library/vmware-vdiskmanager"

[ -x "$VMRUN" ] || VMRUN=$(command -v vmrun 2>/dev/null || true)
[ -x "$VDISK" ] || VDISK=$(command -v vmware-vdiskmanager 2>/dev/null || true)

[ -n "$VMRUN" ] && [ -x "$VMRUN" ] || die "vmrun not found. Install VMware Fusion, or pass its
  location on the PATH. It lives in '$FUSION/Contents/Public/'."
[ -n "$VDISK" ] && [ -x "$VDISK" ] || die "vmware-vdiskmanager not found. It lives in
  '$FUSION/Contents/Library/', which is a DIFFERENT directory from vmrun."

ARCH=$(uname -m)
case "$ARCH" in
    arm64)  GUEST_OS="arm-windows11-64" ;;
    x86_64) GUEST_OS="windows11-64" ;;
    *)      die "unexpected architecture: $ARCH" ;;
esac

VMPATH="$VMDIR/$NAME.vmwarevm"
VMX="$VMPATH/$NAME.vmx"
VMDK="$VMPATH/$NAME.vmdk"

# --------------------------------------------------------------------------- #
# --list
#
# The custom networks are the thing worth printing. Fusion numbers them itself, starting
# at vmnet2, and the number is local to this Mac - the one you named cqulab may be vmnet2
# here and vmnet4 on the machine beside you. vmnet1 (host-only) and vmnet8 (NAT) are
# Fusion's own and are never the lab network.
# --------------------------------------------------------------------------- #
NETCFG="/Library/Preferences/VMware Fusion/networking"

if [ "$LIST" = yes ]; then
    echo
    echo "Windows Host - what is already here"
    echo
    if [ -r "$FUSION/Contents/Info.plist" ]; then
        ver=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" \
                  "$FUSION/Contents/Info.plist" 2>/dev/null || echo "?")
        echo "  Fusion        $ver"
    fi
    echo "  architecture  $ARCH  (guestOS would be $GUEST_OS)"
    echo "  vmrun         $VMRUN"
    echo
    if [ -r "$NETCFG" ]; then
        echo "  custom networks in $NETCFG:"
        vnets=$(sed -n 's/^answer VNET_\([0-9][0-9]*\)_.*/\1/p' "$NETCFG" | sort -nu)
        for n in $vnets; do
            # vmnet1 is Fusion's host-only and vmnet8 its NAT; neither is ever the lab.
            case "$n" in 1|8) continue ;; esac
            detail=$(grep "^answer VNET_${n}_" "$NETCFG" | sed 's/^answer //' | tr '\n' ' ')
            echo "    vmnet$n   $detail"
        done
        echo
        echo "  Match one of those against the network you renamed cqulab in"
        echo "  Fusion > Settings > Network, and pass it as --vmnet vmnetN."
    else
        echo "  no $NETCFG - you have not created a custom network yet."
        echo "  Do Step A of the guide's Mac section first."
    fi
    echo
    if [ -d "$VMPATH" ]; then
        echo "  VM '$NAME'    exists at $VMPATH"
    else
        echo "  VM '$NAME'    does not exist - this script would create it"
    fi
    echo
    exit 0
fi

# --------------------------------------------------------------------------- #
# Preconditions
# --------------------------------------------------------------------------- #
[ -n "$ISO" ] || die "no --iso given. Download a Windows 11 ISO from Microsoft first - it is
  a free direct download, about 6 GB, and on Apple Silicon you want the ARM64 one."
[ -r "$ISO" ] || die "cannot read the ISO at: $ISO"

[ -n "$VMNET" ] || die "no --vmnet given. Run '$0 --list' to see the custom networks on this
  Mac, and pass the one you renamed cqulab."

if [ ! -r "$UNATTEND" ]; then
    die "no unattend ISO at: $UNATTEND
  Build it first:  $SCRIPT_DIR/make-unattend-iso.sh --arch ${ARCH}
  Without it Windows Setup asks every question by hand, which works but is not what this
  script is for. Pass --unattend <path> if yours is elsewhere."
fi

if [ -e "$VMPATH" ]; then
    echo "A VM already exists at:"
    echo "  $VMPATH"
    echo
    echo "Nothing has been changed. Delete it from Fusion (or 'rm -rf' that folder) if it is"
    echo "a half-finished attempt, then run this again."
    exit 0
fi

ISO_ABS=$(CDPATH= cd -- "$(dirname -- "$ISO")" && pwd)/$(basename -- "$ISO")
UNATTEND_ABS=$(CDPATH= cd -- "$(dirname -- "$UNATTEND")" && pwd)/$(basename -- "$UNATTEND")

echo
echo "Creating the GNS3 Windows Host VM"
if [ "$DRY" = yes ]; then echo "DRY RUN - nothing will be created."; fi
echo
echo "  name        : $NAME"
echo "  location    : $VMPATH"
echo "  iso         : $ISO_ABS"
echo "  unattend    : $UNATTEND_ABS"
echo "  lab network : $VMNET   (the one you named cqulab)"
echo "  hardware    : ${MEMORY} MB RAM, $CPUS CPUs, ${DISK} GB disk, EFI$([ "$TPM" = yes ] && echo ' + TPM')"
echo "  guest       : $GUEST_OS"
echo

# --------------------------------------------------------------------------- #
# The .vmx
#
# Written by hand on purpose. Two things in here are load-bearing:
#
#  1. pciSlotNumber on both adapters. Fusion assigns these itself when an adapter is added
#     through the UI, and a later-added adapter can get a high bridge-encoded slot that the
#     guest enumerates FIRST. Pinning 160 and 192 here fixes NAT as the first interface and
#     the lab as the second, on every machine this builds.
#  2. virtualDev = e1000e rather than Fusion's default vmxnet3. Windows 11 ARM64 ships no
#     vmxnet3 driver, so a default Fusion VM installs with no network at all. e1000e is
#     expected to be in-box on both architectures. UNVERIFIED on ARM64 - it is the first
#     thing to check when this script is tested, and --list prints the guest type so you
#     can see what was asked for.
# --------------------------------------------------------------------------- #
vmx_body() {
    cat <<VMXEOF
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "20"
displayName = "$NAME"
guestOS = "$GUEST_OS"
firmware = "efi"

memsize = "$MEMORY"
numvcpus = "$CPUS"
cpuid.coresPerSocket = "1"

nvme0.present = "TRUE"
nvme0:0.present = "TRUE"
nvme0:0.fileName = "$NAME.vmdk"

sata0.present = "TRUE"
sata0:0.present = "TRUE"
sata0:0.deviceType = "cdrom-image"
sata0:0.fileName = "$ISO_ABS"
sata0:0.startConnected = "TRUE"
sata0:1.present = "TRUE"
sata0:1.deviceType = "cdrom-image"
sata0:1.fileName = "$UNATTEND_ABS"
sata0:1.startConnected = "TRUE"

ethernet0.present = "TRUE"
ethernet0.connectionType = "nat"
ethernet0.virtualDev = "e1000e"
ethernet0.addressType = "generated"
ethernet0.pciSlotNumber = "160"

ethernet1.present = "TRUE"
ethernet1.connectionType = "custom"
ethernet1.vnet = "$VMNET"
ethernet1.virtualDev = "e1000e"
ethernet1.addressType = "generated"
ethernet1.pciSlotNumber = "192"

usb.present = "TRUE"
ehci.present = "TRUE"
svga.autodetect = "TRUE"
sound.present = "FALSE"
floppy0.present = "FALSE"
tools.syncTime = "TRUE"
powerType.powerOff = "soft"
powerType.reset = "soft"
VMXEOF
    if [ "$TPM" = yes ]; then
        cat <<'VMXEOF'

# Windows 11 requires a TPM. Fusion adds a software one when asked, so the requirement is
# MET rather than bypassed - which is why autounattend.xml ships with its bypass registry
# keys commented out. If Fusion refuses this VM for want of encryption, either accept
# Fusion's offer to encrypt it, or re-run with --no-tpm and uncomment that block instead.
managedvm.autoAddVTPM = "software"
VMXEOF
    fi
}

if [ "$DRY" = yes ]; then
    echo "--- $VMX ---"
    vmx_body
    echo "--- commands ---"
    echo "mkdir -p '$VMPATH'"
    echo "'$VDISK' -c -s ${DISK}GB -a lsilogic -t 0 '$VMDK'"
    if [ "$START" = yes ]; then echo "'$VMRUN' -T fusion start '$VMX' gui"; fi
    echo
    echo "Dry run: nothing was created."
    exit 0
fi

mkdir -p "$VMPATH"

echo "Storage"
"$VDISK" -c -s "${DISK}GB" -a lsilogic -t 0 "$VMDK" >/dev/null
echo "  done     disk                     ${DISK} GB (growable)"

vmx_body > "$VMX"
chmod 600 "$VMX"
echo "  done     vmx                      $VMX"

echo
echo "Network"
echo "  done     ethernet0                NAT (internet), e1000e, slot 160"
echo "  done     ethernet1                $VMNET (the lab), e1000e, slot 192"

if [ "$START" = yes ]; then
    echo
    echo "Starting"
    "$VMRUN" -T fusion start "$VMX" gui
    echo "  done     started                  Windows is installing"
fi

echo
echo "The Windows Host VM is building."
echo
echo "  Windows takes 30 to 60 minutes and restarts itself several times."
echo
echo "  Watch for two things on Apple Silicon:"
echo "    - if Setup stops at 'Let's connect you to a network', press Fn+Shift+F10 and run"
echo "        start ms-cxh:localonly"
echo "    - when it reaches the desktop, check it has a network. If not, install VMware"
echo "      Tools from Fusion's Virtual Machine menu."
echo
echo "  Then run configure-windows-host.ps1 inside Windows - Step 5 of the guide - unless"
echo "  your unattend ISO already did it for you."
echo
echo "  The GNS3 VM's own adapter still has to point at $VMNET. This script did not touch it."
