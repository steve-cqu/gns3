#!/bin/bash
# Start Prometheus on this node.
# Usage: start-prometheus.sh
#
# The configuration is checked BEFORE anything starts, so a typo in a scrape job produces a
# message naming the file and line rather than a server that comes up with no targets.

CONF=/etc/prometheus/prometheus.yml
DATA=/var/lib/prometheus/data
LOG=/var/log/prometheus.log

echo "Checking $CONF ..."
if ! promtool check config "$CONF"; then
    echo
    echo "FAILED: promtool rejected the configuration. Nothing was started."
    echo "Fix the file above, then run start-prometheus.sh again."
    echo
    echo "YAML is picky about indentation — a scrape job that is indented by one space too"
    echo "few or too many is the most common cause."
    exit 1
fi

# Restart cleanly if it is already running, so this script is safe to run after every edit.
if pgrep -x prometheus >/dev/null 2>&1; then
    echo "Stopping the running Prometheus..."
    pkill -x prometheus
    sleep 2
fi

mkdir -p "$DATA"
echo "Starting Prometheus..."
prometheus \
    --config.file="$CONF" \
    --storage.tsdb.path="$DATA" \
    --web.listen-address=":9090" \
    >"$LOG" 2>&1 &

sleep 3
if pgrep -x prometheus >/dev/null 2>&1; then
    echo "Prometheus started on port 9090."
    echo
    echo "Targets:   http://<this-node-ip>:9090/targets"
    echo "Log:       $LOG"
    echo "Check it:  curl -s http://localhost:9090/-/healthy"
    echo
    echo "Open the web interface from a Firefox Host node in the topology."
else
    echo "Prometheus did not stay running. Last lines of $LOG:"
    tail -20 "$LOG"
    exit 1
fi
