#!/bin/bash
# Start the whole monitoring stack on this node, in order.
# Usage: start-monitoring.sh
#
# This is the shortcut for repeating a lab you have already done. The FIRST time, start the
# pieces one at a time with start-blackbox.sh, start-prometheus.sh and start-grafana.sh, and
# look at each one before moving on — when something is wrong later, knowing which piece came
# up cleanly is most of the diagnosis.

set -u

echo "=============================================="
echo "Starting the monitoring stack"
echo "=============================================="
echo

# node_exporter first: it is on this node too (from the base image), so the Monitor appears in
# its own dashboards alongside everything else it watches.
if pgrep -x node_exporter >/dev/null 2>&1; then
    echo "[1/4] node_exporter already running."
else
    echo "[1/4] Starting node_exporter on :9100 ..."
    node_exporter >/var/log/node_exporter.log 2>&1 &
    sleep 1
fi
echo

echo "[2/4] blackbox_exporter"
/usr/local/bin/start-blackbox.sh || exit 1
echo

echo "[3/4] Prometheus"
/usr/local/bin/start-prometheus.sh || exit 1
echo

echo "[4/4] Grafana"
/usr/local/bin/start-grafana.sh || exit 1
echo

echo "=============================================="
echo "All four are up. Check them with: monitor-status.sh"
echo "=============================================="
