#!/bin/bash
# What is this wireless node doing?
# Usage: wifi-status.sh
#
# Works on both roles: on an Access Point it shows hostapd and the associated stations; on a Station
# it shows the association (SSID, signal, rate). Run it on either node.

IFACE=wlan0

echo "================================================"
echo "Wireless Node Status"
echo "================================================"
echo ""

echo "1. Radio present?"
if ip link show "$IFACE" >/dev/null 2>&1; then
    PHY=$(basename "$(readlink -f "/sys/class/net/$IFACE/phy80211")" 2>/dev/null)
    echo "   $IFACE is present (on $PHY)"
else
    echo "   NO $IFACE — the radio has not been attached. On the GNS3 VM host run:"
    echo "       gns3-wifi-attach <project-name>"
    echo "================================================"
    exit 0
fi
echo ""

echo "2. Addresses:"
ip -4 addr show dev "$IFACE" 2>/dev/null | grep -E 'inet ' | sed 's/^/   /' || echo "   none on $IFACE"
echo ""

if pgrep -x hostapd >/dev/null 2>&1; then
    echo "3. Role: ACCESS POINT (hostapd running)"
    echo ""
    echo "4. SSID / channel:"
    iw dev "$IFACE" info 2>/dev/null | grep -E 'ssid|channel' | sed 's/^/   /'
    echo ""
    echo "5. Associated stations:"
    n=$(iw dev "$IFACE" station dump 2>/dev/null | grep -c '^Station')
    if [ "$n" -ge 1 ] 2>/dev/null; then
        iw dev "$IFACE" station dump 2>/dev/null \
            | grep -E '^Station|signal:|tx bitrate:' | sed 's/^/   /'
    else
        echo "   none yet — start a Station with start-sta.sh"
    fi
elif pgrep -x wpa_supplicant >/dev/null 2>&1; then
    echo "3. Role: STATION (wpa_supplicant running)"
    echo ""
    echo "4. Association:"
    wpa_cli -i "$IFACE" status 2>/dev/null \
        | grep -E 'wpa_state|ssid|bssid|key_mgmt' | sed 's/^/   /'
    echo ""
    echo "5. Link (signal, rate):"
    iw dev "$IFACE" link 2>/dev/null | grep -E 'Connected|signal|rx bitrate|tx bitrate' | sed 's/^/   /' \
        || echo "   not connected"
else
    echo "3. Role: not started. Run start-ap.sh (access point) or start-sta.sh (station)."
fi
echo ""
echo "================================================"
echo "AP config:   /etc/hostapd/hostapd.conf"
echo "STA config:  /etc/wpa_supplicant/wpa_supplicant.conf"
echo "Logs:        /var/log/wifi/"
echo "================================================"
