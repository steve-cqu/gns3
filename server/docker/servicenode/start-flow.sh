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

FLOWDIR=/var/flows
PORT=9995

mkdir -p "$FLOWDIR"

# Restart cleanly if already running, so this script is safe to run repeatedly.
if pgrep -x nfcapd >/dev/null 2>&1; then
    echo "Stopping the running nfcapd..."
    pkill -x nfcapd
    sleep 1
fi

echo "Starting nfcapd, listening for NetFlow on UDP $PORT ..."
# -D fork to background, -w <dir> output directory, -p port, -t 60 rotate every 60s so data
# appears quickly. (In nfdump 1.7 the output directory is the argument to -w, not a separate -l.)
nfcapd -D -w "$FLOWDIR" -p "$PORT" -t 60

sleep 1
if pgrep -x nfcapd >/dev/null 2>&1; then
    echo "nfcapd started."
    echo
    echo "Point a probe at this node's address on UDP $PORT (see start-flowprobe.sh on the router)."
    echo "After a minute, see the flows:   flow-status.sh"
    echo "Query them directly:             nfdump -R $FLOWDIR -s ip/bytes"
else
    echo "nfcapd did not stay running. Check the console output above."
    exit 1
fi
