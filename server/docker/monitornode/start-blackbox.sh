#!/bin/bash
# Start blackbox_exporter on this node.
# Usage: start-blackbox.sh
#
# blackbox_exporter runs as root here so its icmp module can open a raw socket. That is why
# ping probes work from this node without the container being put in privileged mode.

CONF=/etc/prometheus/blackbox.yml
LOG=/var/log/blackbox_exporter.log

if [ ! -f "$CONF" ]; then
    echo "FAILED: $CONF not found."
    exit 1
fi

if pgrep -x blackbox_exporter >/dev/null 2>&1; then
    echo "Stopping the running blackbox_exporter..."
    pkill -x blackbox_exporter
    sleep 1
fi

echo "Starting blackbox_exporter..."
blackbox_exporter \
    --config.file="$CONF" \
    --web.listen-address=":9115" \
    >"$LOG" 2>&1 &

sleep 2
if pgrep -x blackbox_exporter >/dev/null 2>&1; then
    echo "blackbox_exporter started on port 9115."
    echo
    echo "Test a probe by hand before wiring it into Prometheus:"
    echo "    curl -s \"http://localhost:9115/probe?target=<host-ip>&module=icmp\" | grep probe_success"
    echo "probe_success 1 = the probe worked, 0 = it did not."
    echo
    echo "Modules available: $(grep -E '^  [a-z0-9_]+:' "$CONF" | tr -d ' :' | tr '\n' ' ')"
    echo "Log: $LOG"
else
    echo "blackbox_exporter did not stay running. Last lines of $LOG:"
    tail -20 "$LOG"
    exit 1
fi
