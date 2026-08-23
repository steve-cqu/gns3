#!/bin/sh
# Start the Active Directory Domain Controller on this node.
# Usage: start-samba-dc.sh [--restart]
#
# Run this after `samba-tool domain provision`, and again every time the project is reopened.
# It is safe to run repeatedly: it never touches the directory, it only starts the daemon and
# repairs the two things a container loses on restart.
#
# What it does, and why each step is here:
#   1. Refuses to start if the domain has not been provisioned yet, and says so in one line.
#   2. Refuses to start if eth0 has no address. Samba binds its listeners at startup, so a DC
#      started before the interface is addressed logs "WARNING: no network interfaces found" and
#      then serves nothing to anybody — while still looking like a running daemon. This is the
#      single most confusing failure on a reopened project, where the address comes back from the
#      image empty, and it cost a live debugging session to find. Checked here so it cannot recur.
#   3. Re-links /etc/krb5.conf to the realm configuration provisioning wrote. GNS3 rebuilds a node
#      from its image on every project open, so /etc is the image's /etc again — but the directory
#      under /var/lib/samba is persisted. Without this link, kinit on the DC looks for a realm it
#      cannot find, which reads as "Cannot find KDC for realm" on a DC that is running perfectly.
#      Samba's own provisioning advice says not to symlink it; on a node whose /etc is rebuilt
#      every time, a copy is what goes stale, so the link is the safe form here.
#   4. Starts /usr/sbin/samba — ONE daemon runs the whole DC (LDAP, Kerberos, DNS and SMB). This
#      is the difference from the file-server side of Samba, where smbd and nmbd are separate.
#   5. Waits until LDAP actually answers before reporting success, so a failure is loud and
#      immediate rather than a silent daemon that died three seconds later.

PRIVATE=/var/lib/samba/private
SAMDB="$PRIVATE/sam.ldb"
KRB5="$PRIVATE/krb5.conf"
PIDFILE=/run/samba/samba.pid
RESTART=no

[ "$1" = "--restart" ] && RESTART=yes

if [ ! -f "$SAMDB" ]; then
    echo "No domain on this node yet — $SAMDB does not exist."
    echo "Provision one first with:  samba-tool domain provision --help"
    exit 1
fi

# Samba binds at startup, so the address has to exist FIRST.
if ! ip -4 addr show eth0 2>/dev/null | grep -q 'inet '; then
    echo "eth0 has no IPv4 address."
    echo "Samba binds its listeners when it starts, so a domain controller started now would"
    echo "serve nothing. Address the interface first, for example:"
    echo "    ip addr add 10.10.1.10/24 dev eth0"
    echo "    ip link set eth0 up"
    echo "then run this again."
    exit 1
fi

# The realm configuration lives with the directory, and /etc does not persist.
if [ -f "$KRB5" ]; then
    ln -sf "$KRB5" /etc/krb5.conf
else
    echo "WARNING: $KRB5 is missing — kinit on this node will not find the realm."
fi

# /run does not persist either, and samba wants its pid directory to exist.
mkdir -p /run/samba /var/log/samba

stop_samba() {
    # `pkill samba` is not enough: the master forks a dozen helpers and killing one of those
    # leaves the DC half-running, which then reports "already running" forever. Signal the master
    # from its own pid file and wait for the whole tree to go.
    if [ -f "$PIDFILE" ]; then
        kill "$(cat "$PIDFILE")" 2>/dev/null
    else
        pkill -x samba 2>/dev/null
    fi
    i=0
    while [ "$i" -lt 15 ]; do
        pgrep -x samba >/dev/null 2>&1 || return 0
        i=$((i + 1))
        sleep 1
    done
    pkill -9 -x samba 2>/dev/null
    sleep 1
}

if pgrep -x samba >/dev/null 2>&1; then
    if [ "$RESTART" = yes ]; then
        echo "Stopping the domain controller..."
        stop_samba
    else
        echo "samba is already running."
        echo "If it was started before this node had an address, it is serving nothing —"
        echo "restart it with:  start-samba-dc.sh --restart"
        exit 0
    fi
fi

echo "Starting the domain controller..."
samba -D

# Wait for LDAP on 389. A DC that has started answers this within a second or two; one that is
# going to fail has usually failed by now, and the log line below is what says why.
i=0
while [ "$i" -lt 15 ]; do
    if nc -z 127.0.0.1 389 2>/dev/null; then
        REALM=$(grep -i '^\s*realm' /etc/samba/smb.conf 2>/dev/null | head -1 | sed 's/.*=\s*//')
        echo "Domain controller is up. Realm: ${REALM:-unknown}"
        echo "Check it with:  samba-dc-status.sh"
        exit 0
    fi
    i=$((i + 1))
    sleep 1
done

echo "FAILED: samba started but nothing is answering on port 389 after 15 seconds."
echo "Last lines of /var/log/samba:"
tail -n 12 /var/log/samba/log.samba 2>/dev/null | sed 's/^/   /' || echo "   (no log file yet)"
exit 1
