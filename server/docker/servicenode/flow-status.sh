#!/bin/bash
# What flows has this collector seen?
# Usage: flow-status.sh

# nfcapd writes into this SUBDIRECTORY of the persisted /var/flows volume so that `nfdump -R` is not
# tripped by GNS3's `.gns3_perms` marker in the volume root — see start-flow.sh for the full note.
FLOWDIR=/var/flows/nfcapd

echo "================================================"
echo "NetFlow Collector Status"
echo "================================================"
echo ""

echo "1. Collector process (nfcapd):"
if pgrep -x nfcapd >/dev/null 2>&1; then
    ps -o pid,args -C nfcapd 2>/dev/null || pgrep -a nfcapd
else
    echo "   nfcapd is NOT running — start it with start-flow.sh"
fi
echo ""

echo "2. This node's addresses (what the probe should export to):"
ip -4 addr show | grep -E 'inet ' | grep -v '127.0.0.1' || echo "   no IPv4 address configured"
echo ""

echo "3. Capture files collected so far:"
ls -1 "$FLOWDIR"/nfcapd.* 2>/dev/null | sed 's/^/   /' || echo "   none yet — is a probe exporting to UDP 9995?"
echo ""

echo "4. Top talkers by traffic (all flows collected):"
if ls "$FLOWDIR"/nfcapd.* >/dev/null 2>&1; then
    nfdump -R "$FLOWDIR" -s ip/bytes -n 5 2>/dev/null | sed 's/^/   /'
else
    echo "   no data yet"
fi
echo ""

echo "5. Top conversations (source -> destination):"
if ls "$FLOWDIR"/nfcapd.* >/dev/null 2>&1; then
    nfdump -R "$FLOWDIR" -s srcip/bytes -A srcip,dstip -n 5 2>/dev/null | sed 's/^/   /'
fi
echo ""

echo "================================================"
echo "Flow files:  $FLOWDIR   (persisted)"
echo "Query more:  nfdump -R $FLOWDIR 'proto tcp and port 80'"
echo "================================================"
