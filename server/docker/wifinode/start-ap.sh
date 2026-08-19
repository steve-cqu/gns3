#!/bin/bash
# Start this node as a Wi-Fi Access Point (hostapd, WPA2-PSK).
# Usage: start-ap.sh [ip/cidr]        (default 10.0.0.1/24)
#
# hostapd turns the node's radio into an access point beaconing the SSID in
# /etc/hostapd/hostapd.conf. A Station node running start-sta.sh then associates to it. The config
# is checked before anything starts, so a typo is reported rather than a daemon that silently is
# not there.

CONF=/etc/hostapd/hostapd.conf
IFACE=wlan0
APIP="${1:-10.0.0.1/24}"

# The radio has to be present first. wlan0 only exists after the host-side helper gns3-wifi-attach
# has moved a simulated radio into this node's namespace.
if ! ip link show "$IFACE" >/dev/null 2>&1; then
    echo "FAILED: no $IFACE on this node — the radio has not been attached yet."
    echo
    echo "On the GNS3 VM host (not here), after starting the project, run once:"
    echo "    gns3-wifi-attach <project-name>"
    echo "That moves a simulated radio into each wireless node. Then run start-ap.sh again."
    exit 1
fi

echo "Checking $CONF ..."
# -t would need the iface; instead let hostapd validate by starting. First, a quick sanity read.
if ! grep -q '^ssid=' "$CONF" || ! grep -q '^wpa_passphrase=' "$CONF"; then
    echo "FAILED: $CONF is missing an ssid= or wpa_passphrase= line. Fix it and retry."
    exit 1
fi

# Restart cleanly if already running.
if pgrep -x hostapd >/dev/null 2>&1; then
    echo "Stopping the running hostapd..."
    pkill -x hostapd
    sleep 1
fi

ip link set "$IFACE" up

echo "Starting hostapd on $IFACE ..."
# -B daemonize, -P pidfile. Logs go to the file so wifi-status.sh can show them.
hostapd -B -P /run/hostapd/hostapd.pid "$CONF" >/var/log/wifi/hostapd.log 2>&1

# Poll rather than sleep a flat 2 s, for the same reason start-sta.sh polls for 30: a fixed wait is
# a race with the slowest machine that will ever run this, and it exits as soon as hostapd is up.
i=0
while [ $i -lt 15 ]; do
    pgrep -x hostapd >/dev/null 2>&1 && break
    i=$((i+1)); sleep 1
done

if pgrep -x hostapd >/dev/null 2>&1; then
    ip addr flush dev "$IFACE" 2>/dev/null
    ip addr add "$APIP" dev "$IFACE"
    SSID=$(grep '^ssid=' "$CONF" | cut -d= -f2)
    echo "hostapd started. Access point '$SSID' is beaconing on $IFACE ($APIP)."
    echo
    echo "On a Station node, join it with:   start-sta.sh"
    echo "Watch for associated clients:      wifi-status.sh"
    echo "Capture the four-way handshake:    start-monitor.sh   (then tcpdump on mon0)"
else
    echo "hostapd did not stay running. Last lines of /var/log/wifi/hostapd.log:"
    tail -n 12 /var/log/wifi/hostapd.log 2>/dev/null | sed 's/^/   /'
    exit 1
fi
