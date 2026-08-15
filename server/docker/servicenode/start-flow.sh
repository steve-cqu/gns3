#!/bin/bash
# Start the NetFlow collector (nfcapd) on this node.
# Usage: start-flow.sh
#
# This is the "collect" half of flow telemetry. A router or host somewhere on the network runs a
# probe (start-flowprobe.sh) that exports NetFlow records; this node receives them on UDP 9995 and
# writes rotating capture files that you then query with nfdump (see flow-status.sh).
#
# Flows are the third way to see a network, beside packet capture and IDS signatures: not the bytes
# on the wire and not "was this an attack", but who talked to whom, how much, and when — the view
# you actually operate a network from, at a scale where capturing every packet is impossible.

# nfcapd writes into a SUBDIRECTORY of the persisted /var/flows volume, not its root. GNS3 drops a
# 0-byte `.gns3_perms` marker in the root of every persisted volume, and `nfdump -R <dir>` reads
# every file in the directory it is given — including that marker, which is not a flow file, so the
# read aborts with "read() error in nffile.c" and reports 0 flows even though nfcapd collected them.
# A subdirectory has no `.gns3_perms`, so `nfdump -R /var/flows/nfcapd` reads cleanly. Found live
# 15 August 2026 — see gns3-dev/notes/tier5-and-spike-designs.md.
FLOWDIR=/var/flows/nfcapd
PORT=9995

mkdir -p "$FLOWDIR"

# Restart cleanly if already running, so this script is safe to run repeatedly.
if pgrep -x nfcapd >/dev/null 2>&1; then
    echo "Stopping the running nfcapd..."
    pkill -x nfcapd
    sleep 1
fi

echo "Starting nfcapd, listening for NetFlow on UDP $PORT ..."
# -D fork to background, -w <dir> output directory, -p port, -t 10 rotate every 10s.
# The rotation interval matters for a lab: nfcapd buffers received flows in its open
# `nfcapd.current.<pid>` file and only writes a COMPLETE, nfdump-readable file when it rotates. At
# the 60s default a student runs flow-status.sh, sees nothing, and thinks it is broken. At 10s a
# flow shows up within ~10s of the probe exporting it. (In nfdump 1.7 the output directory is the
# argument to -w, not a separate -l.)
nfcapd -D -w "$FLOWDIR" -p "$PORT" -t 10

sleep 1
if pgrep -x nfcapd >/dev/null 2>&1; then
    echo "nfcapd started."
    echo
    echo "Point a probe at this node's address on UDP $PORT (see start-flowprobe.sh on the router)."
    echo "Generate traffic, wait ~15s, then see the flows:   flow-status.sh"
    echo "Query them directly:                               nfdump -R $FLOWDIR -s ip/bytes"
else
    echo "nfcapd did not stay running. Check the console output above."
    exit 1
fi
