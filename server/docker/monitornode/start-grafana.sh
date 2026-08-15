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

# Grafana takes a few seconds to migrate its database and bind the port on first start.
echo "Waiting for Grafana to come up..."
for i in $(seq 1 20); do
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
else
    echo "Grafana did not answer on port 3000. Last lines of $LOG:"
    tail -20 "$LOG"
    exit 1
fi
