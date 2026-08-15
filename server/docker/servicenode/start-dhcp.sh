#!/bin/bash
# Start the Kea DHCPv4 server on this node.
# Usage: start-dhcp.sh
#
# The configuration is checked BEFORE anything starts (kea-dhcp4 -t), so a JSON typo or a bad
# subnet is reported with a file and line rather than a daemon that silently is not there.

CONF=/etc/kea/kea-dhcp4.conf

# /run/kea holds Kea's lockfile and PID file; it lives on tmpfs and is gone after a restart, so it
# is recreated here rather than only in the image. Without it Kea aborts at startup with
# "Unable to open PID file '/run/kea/kea-dhcp4.kea-dhcp4.pid'".
mkdir -p /var/lib/kea /var/log/kea /run/kea
chown -R kea:kea /var/lib/kea /var/log/kea /run/kea 2>/dev/null

echo "Checking $CONF ..."
# -t parses the whole file, resolves the subnets and validates the options. WARN lines about
# multi-threading are normal; only a non-zero exit means the config was rejected.
if ! kea-dhcp4 -t "$CONF" >/tmp/kea-check.log 2>&1; then
    echo
    echo "FAILED: the configuration was rejected. Nothing was started."
    grep -iE 'error|cannot|invalid|unable' /tmp/kea-check.log | sed 's/^/   /'
    echo "Fix $CONF, then run start-dhcp.sh again."
    exit 1
fi

# Restart cleanly if already running, so this script is safe to run repeatedly.
if pgrep -x kea-dhcp4 >/dev/null 2>&1; then
    echo "Stopping the running kea-dhcp4..."
    pkill -x kea-dhcp4
    sleep 1
fi

echo "Starting kea-dhcp4..."
kea-dhcp4 -c "$CONF" >/var/log/kea/kea-dhcp4.stdout 2>&1 &

sleep 2
if pgrep -x kea-dhcp4 >/dev/null 2>&1; then
    echo "kea-dhcp4 started."
    echo
    echo "It serves 192.168.1.100-200 on subnet 192.168.1.0/24 (edit $CONF to change)."
    echo "On a client node, request a lease:   udhcpc -i eth0        (or: dhclient eth0)"
    echo "See the leases handed out:           dhcp-status.sh"
else
    echo "kea-dhcp4 did not stay running. Check /var/log/kea/kea-dhcp4.log"
    tail -n 10 /var/log/kea/kea-dhcp4.log 2>/dev/null | sed 's/^/   /'
    exit 1
fi
