#!/bin/bash
# Start a NetFlow probe (softflowd) that exports flows to a collector.
# Usage: start-flowprobe.sh <interface> <collector-ip>
#   e.g. start-flowprobe.sh eth0 192.168.1.10
#
# Run this on the node whose traffic you want to measure — a router, or a host on a mirror/span
# link. It watches the interface, builds flow records, and exports them as NetFlow v9 to the
# collector's UDP 9995 (start-flow.sh on the collector node).
#
# This script lives on every service node so any of them can be the probe in a first flow lab; in a
# larger topology the probe usually rides a router. softflowd sees only traffic that reaches the
# interface, so on a switched segment you need a mirror/span port — the same rule as any sniffer.

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

# Restart cleanly if already running.
if pgrep -x softflowd >/dev/null 2>&1; then
    echo "Stopping the running softflowd..."
    pkill -x softflowd
    sleep 1
fi

echo "Starting softflowd on $IFACE, exporting NetFlow v9 to $COLLECTOR:$PORT ..."
# -i interface, -n host:port collector, -v 9 NetFlow v9, -t maxlife short so flows export promptly.
softflowd -i "$IFACE" -n "$COLLECTOR:$PORT" -v 9 -t maxlife=30

sleep 1
if pgrep -x softflowd >/dev/null 2>&1; then
    echo "softflowd started."
    echo
    echo "Generate some traffic through $IFACE (ping, curl, iperf3), then on the collector run:"
    echo "   flow-status.sh"
    echo "See the probe's own view:   softflowctl statistics 2>/dev/null || softflowctl -c /var/run/softflowd.ctl statistics"
else
    echo "softflowd did not stay running. Check the console output above."
    exit 1
fi
