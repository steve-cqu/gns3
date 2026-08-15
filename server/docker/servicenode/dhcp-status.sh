#!/bin/bash
# What is this Kea DHCP server actually doing?
# Usage: dhcp-status.sh

CONF=/etc/kea/kea-dhcp4.conf
LEASES=/var/lib/kea/kea-leases4.csv

echo "================================================"
echo "Kea DHCPv4 Server Status"
echo "================================================"
echo ""

echo "1. Server process:"
if pgrep -x kea-dhcp4 >/dev/null 2>&1; then
    ps -o pid,args -C kea-dhcp4 2>/dev/null || pgrep -a kea-dhcp4
else
    echo "   kea-dhcp4 is NOT running — start it with start-dhcp.sh"
fi
echo ""

echo "2. This node's addresses:"
ip -4 addr show | grep -E 'inet ' | grep -v '127.0.0.1' || echo "   no IPv4 address configured"
echo ""

echo "3. Configuration check:"
kea-dhcp4 -t "$CONF" >/tmp/kea-check.log 2>&1 && echo "   OK — config is valid" || sed 's/^/   /' /tmp/kea-check.log
echo ""

echo "4. Subnets and pools served:"
grep -E '"subnet"|"pool"' "$CONF" | sed 's/^[[:space:]]*/   /'
echo ""

echo "5. Leases handed out (address, MAC, expiry):"
if [ -s "$LEASES" ]; then
    # CSV columns: address,hwaddr,client_id,valid_lifetime,expire,subnet_id,...
    awk -F, 'NR==1{next} {print "   "$1"  "$2"  expires(epoch) "$5}' "$LEASES"
else
    echo "   no leases yet — request one from a client node"
fi
echo ""

echo "================================================"
echo "Config:      $CONF"
echo "Lease file:  $LEASES   (persisted)"
echo "Log file:    /var/log/kea/kea-dhcp4.log"
echo "================================================"
