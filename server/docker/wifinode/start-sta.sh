#!/bin/bash
# Start this node as a Wi-Fi Station (client): associate to the AP with wpa_supplicant (WPA2-PSK).
# Usage: start-sta.sh [ip/cidr]        (default 10.0.0.2/24)
#
# wpa_supplicant scans for the SSID in /etc/wpa_supplicant/wpa_supplicant.conf and completes the
# WPA2-PSK four-way handshake with the access point. Once associated, the static address below lets
# it pass data to the AP (and anything behind it).

CONF=/etc/wpa_supplicant/wpa_supplicant.conf
IFACE=wlan0
STAIP="${1:-10.0.0.2/24}"

# The radio has to be present first (see start-ap.sh for the same check).
if ! ip link show "$IFACE" >/dev/null 2>&1; then
    echo "FAILED: no $IFACE on this node — the radio has not been attached yet."
    echo
    echo "On the GNS3 VM host (not here), after starting the project, run once:"
    echo "    gns3-wifi-attach <project-name>"
    echo "That moves a simulated radio into each wireless node. Then run start-sta.sh again."
    exit 1
fi

if ! grep -q 'ssid=' "$CONF" || ! grep -q 'psk=' "$CONF"; then
    echo "FAILED: $CONF is missing an ssid or psk line. Fix it and retry."
    exit 1
fi

# Restart cleanly if already running.
if pgrep -x wpa_supplicant >/dev/null 2>&1; then
    echo "Stopping the running wpa_supplicant..."
    pkill -x wpa_supplicant
    sleep 1
fi

ip link set "$IFACE" up

echo "Starting wpa_supplicant on $IFACE ..."
# -B daemonize, -i interface, -c config, -D nl80211 driver.
wpa_supplicant -B -i "$IFACE" -c "$CONF" -D nl80211 -P /run/wpa_supplicant/wpa.pid \
    >/var/log/wifi/wpa_supplicant.log 2>&1

# Give the four-way handshake a moment to complete.
echo "Associating (four-way handshake) ..."
i=0; assoc=0
while [ $i -lt 10 ]; do
    if wpa_cli -i "$IFACE" status 2>/dev/null | grep -q 'wpa_state=COMPLETED'; then assoc=1; break; fi
    i=$((i+1)); sleep 1
done

if [ "$assoc" = 1 ]; then
    ip addr flush dev "$IFACE" 2>/dev/null
    ip addr add "$STAIP" dev "$IFACE"
    BSSID=$(wpa_cli -i "$IFACE" status 2>/dev/null | awk -F= '/^bssid=/{print $2}')
    SSID=$(wpa_cli -i "$IFACE" status 2>/dev/null | awk -F= '/^ssid=/{print $2}')
    echo "Associated to '$SSID' (AP $BSSID). This node is $STAIP on $IFACE."
    echo
    echo "Reach the AP:                ping 10.0.0.1"
    echo "See the link (signal, rate): wifi-status.sh"
else
    echo "Did not associate. Last lines of /var/log/wifi/wpa_supplicant.log:"
    tail -n 12 /var/log/wifi/wpa_supplicant.log 2>/dev/null | sed 's/^/   /'
    echo "Check that the AP is running (start-ap.sh) and the SSID/passphrase match."
    exit 1
fi
