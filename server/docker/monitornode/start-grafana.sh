#!/bin/bash
# Start Grafana on this node.
# Usage: start-grafana.sh
#
# Grafana is a web application: there is nothing to see on this console. Open it from a
# Firefox Host node placed in the same topology, or through the GNS3 VM's noVNC service.

CONF=/etc/grafana.ini
HOMEPATH=/usr/share/grafana
LOG=/var/log/grafana/grafana-stdout.log

if [ ! -f "$CONF" ]; then
    echo "FAILED: $CONF not found."
    exit 1
fi

# Restart cleanly if it is already running, so this script is safe to run repeatedly — which
# matters, because "edit grafana.ini then run this again" is how a setting is applied.
#
# It has to be `pgrep -f`, not `pgrep -x`. /usr/sbin/grafana-server is a two-line shim that
# does `exec /usr/bin/grafana server`, so the running process has comm=grafana but
# argv[0]=/usr/bin/grafana, and BusyBox pgrep matches argv[0] unless -f is given. Both
# `pgrep -x grafana-server` and `pgrep -x grafana` therefore come back empty while :3000
# answers perfectly happily. Measured on the built appliance, 14 August 2026: with -x the
# check never fired, a second run started a DUPLICATE Grafana that died with
# "bind: address already in use", and this script still reported success because the original
# was still answering — so the student's edited config was silently never applied.
if pgrep -f 'grafana server' >/dev/null 2>&1; then
    echo "Stopping the running Grafana..."
    pkill -f 'grafana server' 2>/dev/null
    sleep 2
fi

mkdir -p /var/lib/grafana /var/log/grafana

echo "Starting Grafana..."
grafana-server --homepath="$HOMEPATH" --config="$CONF" >"$LOG" 2>&1 &

# Grafana migrates its database and installs its bundled plugins before it binds the port.
#
# 20 seconds was not enough, and the failure was a lie: on a GNS3 VM with ONE vCPU, Grafana
# 12.4.4 took ~90 s to answer (measured 17 Aug 2026 on a 1-core 20.04 VM — the plugin installs
# alone, grafana-pyroscope-app and friends, run most of a second each). The old loop gave up at
# 20 s and printed "Grafana did not answer on port 3000" with a `tail` of a log holding one
# irrelevant line, so a student on a slower machine was told the node was broken while it was
# still starting normally. Connection-refused returns instantly, so this loop costs nothing
# where Grafana is quick.
echo "Waiting for Grafana to come up (up to 2 minutes on a slow or single-core VM)..."
for i in $(seq 1 120); do
    if curl -s -o /dev/null -m 2 "http://localhost:3000/login"; then
        break
    fi
    sleep 1
done

if curl -s -o /dev/null -m 2 "http://localhost:3000/login"; then
    IP=$(ip -4 addr show | grep -E 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d/ -f1 | head -1)
    echo "Grafana started on port 3000."
    echo
    echo "  URL:       http://${IP:-<this-node-ip>}:3000"
    echo "  Username:  admin"
    echo "  Password:  gns3"
    echo
    echo "Open that from a Firefox Host node in this topology."
    echo "Add Prometheus as a data source at http://localhost:9090 — 'localhost' because"
    echo "Grafana and Prometheus are on THIS node, not on the machine running your browser."
    echo
    echo "Log: $LOG  (and /var/log/grafana/grafana.log)"
    echo "Dashboards are stored in /var/lib/grafana/grafana.db and survive a project close."
elif pgrep -f 'grafana server' >/dev/null 2>&1; then
    # Alive but not listening yet. That is slow, not broken, and saying so is the difference
    # between a student waiting a minute and a student rebuilding a working node.
    echo "Grafana is still starting (the process is running but port 3000 is not open yet)."
    echo "Give it another minute, then check with:  monitor-status.sh"
    echo "Watch it finish with:  tail -f /var/log/grafana/grafana.log"
else
    echo "Grafana exited instead of starting. Last lines of /var/log/grafana/grafana.log:"
    tail -20 /var/log/grafana/grafana.log 2>/dev/null || tail -20 "$LOG"
    exit 1
fi
