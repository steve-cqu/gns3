#!/bin/bash
# Start the FRR daemons then drop to a shell on the GNS3 console

# FRR is a router: enable packet forwarding
sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null

/usr/lib/frr/frrinit.sh start

echo ""
echo "FRR router started. Type 'vtysh' for the router CLI."
echo ""
exec bash
