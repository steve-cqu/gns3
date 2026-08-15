#!/bin/bash
# What is this NTP server actually doing?
# Usage: ntp-status.sh

echo "================================================"
echo "NTP Server Status"
echo "================================================"
echo ""

echo "1. chronyd process:"
if pgrep -x chronyd >/dev/null 2>&1; then
    pgrep -a chronyd
else
    echo "   chronyd is NOT running — start it with start-ntp.sh"
fi
echo ""

echo "2. This node's addresses (what clients should point at):"
ip -4 addr show | grep -E 'inet ' | grep -v '127.0.0.1' || echo "   no IPv4 address configured"
echo ""

echo "3. System time as this node sees it:"
echo "   $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "   (shared with the GNS3 VM and every other container node — see chrony.conf)"
echo ""

echo "4. Tracking — what this server believes about its own clock:"
chronyc tracking 2>/dev/null | sed 's/^/   /' || echo "   chronyc could not reach chronyd"
echo ""

echo "5. Sources — upstream servers, if any are configured:"
chronyc sources 2>/dev/null | sed 's/^/   /' || echo "   none"
echo "   (empty is normal in an isolated topology: 'local stratum 8' in chrony.conf is what"
echo "    lets this node serve time with no upstream at all)"
echo ""

echo "6. Clients — nodes that have asked this server for the time:"
chronyc clients 2>/dev/null | sed 's/^/   /' || echo "   none yet"
echo ""

echo "================================================"
echo "Config: /etc/chrony/chrony.conf"
echo ""
echo "From a CLIENT node:"
echo "    chronyd -Q 'server <this-node-ip> iburst'   measure the offset, set nothing"
echo "    chronyc -h <this-node-ip> tracking          ask this server about itself"
echo "================================================"
