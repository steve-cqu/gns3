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

if pgrep -x grafana-server >/dev/null 2>&1 || pgrep -x grafana >/dev/null 2>&1; then
    echo "Stopping the running Grafana..."
    pkill -x grafana-server 2>/dev/null
    pkill -x grafana 2>/dev/null
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
