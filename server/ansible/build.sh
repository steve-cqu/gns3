#!/usr/bin/env bash
# One command to build a GNS3 VM: find the VM's IP, then run the playbook.
#
#   ./build.sh <vm-name> <profile> [ansible-playbook args...]
#
#   ./build.sh "GNS3 VM" pc-student              # VirtualBox (PC)
#   ./build.sh ~/VMs/GNS3.vmx mac-staff          # VMware Fusion (Apple Silicon)
#   ./build.sh "GNS3 VM" pc-student -e verify=all
#
# The hypervisor follows from the profile, which is the split the whole build uses:
#   pc-*  -> VirtualBox  (VBoxManage guestproperty)   <vm-name> is the VM name
#   mac-* -> VMware      (vmrun getGuestIPAddress)    <vm-name> is a path to the .vmx
# Override with GNS3_VM_IP=<ip> to skip discovery entirely.
#
# Requires: ansible-playbook, rsync, and (for the default password login) sshpass.
set -euo pipefail

usage() {
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-1}"
}

[ $# -ge 2 ] || usage
VM_NAME=$1
PROFILE=$2
shift 2

case "$PROFILE" in
    pc-student|pc-staff|mac-student|mac-staff) ;;
    *) echo "error: unknown profile '$PROFILE'" >&2
       echo "       expected one of pc-student, pc-staff, mac-student, mac-staff" >&2
       exit 2 ;;
esac

need() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "error: '$1' not found — $2" >&2
        exit 3
    }
}
need ansible-playbook "install ansible (pip install ansible-core)"
need rsync "install rsync"

# --------------------------------------------------------------------------- #
# Find the VM's IP
# --------------------------------------------------------------------------- #
discover_virtualbox() {
    # The guest additions publish an address per NIC; the host-only adapter is
    # usually Net/1 but is not guaranteed, so try each in turn and take the first
    # address that answers.
    local n ip
    for n in 0 1 2 3; do
        ip=$(VBoxManage guestproperty get "$VM_NAME" \
             "/VirtualBox/GuestInfo/Net/$n/V4/IP" 2>/dev/null \
             | sed -n 's/^Value: //p')
        [ -n "$ip" ] && [ "$ip" != "No value set!" ] && { echo "$ip"; return 0; }
    done
    return 1
}

discover_vmware() {
    vmrun getGuestIPAddress "$VM_NAME" -wait 2>/dev/null | tr -d '\r'
}

if [ -n "${GNS3_VM_IP:-}" ]; then
    VM_IP=$GNS3_VM_IP
    echo "==> using GNS3_VM_IP=$VM_IP"
elif [ "${PROFILE%%-*}" = "pc" ]; then
    need VBoxManage "VirtualBox is required for the pc profiles"
    echo "==> asking VirtualBox for the IP of '$VM_NAME'"
    VM_IP=$(discover_virtualbox) || {
        echo "error: no IPv4 address from VirtualBox for '$VM_NAME'" >&2
        echo "       is the VM running, and are the guest additions up?" >&2
        echo "       (VBoxManage list runningvms), or set GNS3_VM_IP=<ip>" >&2
        exit 4
    }
else
    need vmrun "VMware Fusion is required for the mac profiles"
    echo "==> asking VMware for the IP of '$VM_NAME'"
    VM_IP=$(discover_vmware) || true
    [ -n "$VM_IP" ] || {
        echo "error: no IPv4 address from vmrun for '$VM_NAME'" >&2
        echo "       expected a path to the .vmx; is the VM running?" >&2
        echo "       (vmrun list), or set GNS3_VM_IP=<ip>" >&2
        exit 4
    }
fi

case "$VM_IP" in
    *.*.*.*) ;;
    *) echo "error: '$VM_IP' does not look like an IPv4 address" >&2; exit 4 ;;
esac

# --------------------------------------------------------------------------- #
# Build
# --------------------------------------------------------------------------- #
cd "$(dirname "$0")"
echo "==> building $PROFILE on $VM_IP"

# Trailing comma: an inline host list, so no inventory file is consulted. The group
# vars in inventory.ini would not apply to it, so pass the connection vars here.
set -- -i "$VM_IP," site.yml \
    -e "profile=$PROFILE" \
    -e "ansible_user=${GNS3_VM_USER:-gns3}" \
    -e "ansible_password=${GNS3_VM_PASSWORD:-gns3}" \
    "$@"

# ansible-playbook exits 0 when a play matches no hosts, so a target/inventory mismatch
# would look like a successful build that did nothing. Check before committing to it.
if ! ansible-playbook --list-hosts "$@" 2>/dev/null | grep -q "$VM_IP"; then
    echo "error: the playbook matched no hosts for $VM_IP — refusing to report success" >&2
    exit 5
fi

exec ansible-playbook "$@"
