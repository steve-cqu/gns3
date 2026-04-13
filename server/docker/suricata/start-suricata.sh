#!/bin/bash
# Start Suricata IDS in AF-PACKET mode
# Usage: start-suricata.sh [interface]
# Default interface: eth0

IFACE="${1:-eth0}"

# Ensure custom rules file exists (even if empty)
touch /var/lib/suricata/rules/custom.rules

echo "Starting Suricata on interface $IFACE..."
echo "Alerts will appear in /var/log/suricata/fast.log"
echo "Full EVE JSON in /var/log/suricata/eve.json"

suricata -c /etc/suricata/suricata.yaml -i "$IFACE" --pidfile /var/run/suricata/suricata.pid &

echo "Suricata started (PID $!)"
echo "To check alerts: tail -f /var/log/suricata/fast.log"
