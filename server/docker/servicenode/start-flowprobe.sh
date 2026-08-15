#!/bin/bash
# Start a NetFlow probe (fprobe) that exports flows to a collector.
# Usage: start-flowprobe.sh <interface> <collector-ip>
#   e.g. start-flowprobe.sh eth0 192.168.1.10
#
# Run this on the node whose traffic you want to measure — a router, or a host on a mirror/span
# link. It watches the interface, builds flow records, and exports them as NetFlow to the
# collector's UDP 9995 (start-flow.sh on the collector node).
#
# This script lives on every service node so any of them can be the probe in a first flow lab; in a
# larger topology the probe usually rides a router. fprobe sees only traffic that reaches the
# interface, so on a switched segment you need a mirror/span port — the same rule as any sniffer.
#
# Why fprobe and not softflowd: softflowd 1.1.0 receives packets via libpcap but processes none of
# them inside a GNS3 container (its own stats show "received: N, processed: 0"), so nothing is ever
# exported — verified live 15 August 2026. fprobe builds and exports flows correctly in the same
# container, is 32 KB, and is packaged for both amd64 and arm64. See
# gns3-dev/notes/tier5-and-spike-designs.md.

IFACE="$1"
COLLECTOR="$2"
PORT=9995

if [ -z "$IFACE" ] || [ -z "$COLLECTOR" ]; then
    echo "Usage: start-flowprobe.sh <interface> <collector-ip>"
    echo "   e.g. start-flowprobe.sh eth0 192.168.1.10"
    exit 1
fi

if ! ip link show "$IFACE" >/dev/null 2>&1; then
    echo "FAILED: interface $IFACE does not exist on this node. Available:"
    ip -o link show | awk -F': ' '{print "   "$2}'
    exit 1
fi

# Restart cleanly if already running, so this script is safe to run repeatedly.
if pgrep -x fprobe >/dev/null 2>&1; then
    echo "Stopping the running fprobe..."
    pkill -x fprobe
    sleep 1
fi

echo "Starting fprobe on $IFACE, exporting NetFlow to $COLLECTOR:$PORT ..."
# -i interface, remote collector as the trailing argument.
# -f filter: measure the real traffic, not the probe's own export packets to the collector, which
#    would otherwise clutter "top talkers" with the collector's own address.
# -e/-d/-s: short active (30s) and idle (15s) timers with a 5s expiry scan, so flows export within
#    the span of a lab instead of the 300s/60s defaults. A flow appears at the collector once it
#    has been idle for 15s or has run for 30s.
# NetFlow v5 (fprobe's default) — nfcapd/nfdump read it directly.
fprobe -i "$IFACE" -f "not (udp and dst port $PORT)" -e 30 -d 15 -s 5 "$COLLECTOR:$PORT"

sleep 1
if pgrep -x fprobe >/dev/null 2>&1; then
    echo "fprobe started."
    echo
    echo "Generate some traffic through $IFACE (ping, curl, iperf3), wait ~15s for flows to expire,"
    echo "then on the collector ($COLLECTOR) run:   flow-status.sh"
    echo "Stop the probe with:   pkill fprobe"
else
    echo "fprobe did not stay running. Check the console output above."
    exit 1
fi
