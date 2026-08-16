#!/bin/bash
# Add a monitor interface so you can capture 802.11 frames — including the WPA2 four-way handshake —
# ON THIS NODE.
# Usage: start-monitor.sh            (adds mon0 on the same radio as wlan0, on the AP's channel)
#
# Why capture on the node and not on a GNS3 link: wireless frames never travel over a GNS3 link
# (the "air" is the mac80211_hwsim medium, not a cable), so the GUI's right-click link capture
# cannot see them. A monitor-mode interface is the authentic wireless capture tool, so for THIS
# activity an on-node capture is the correct instruction — the one documented exception to the
# "capture on the link, never tcpdump on a node" rule.

IFACE=wlan0
MON=mon0

if ! ip link show "$IFACE" >/dev/null 2>&1; then
    echo "FAILED: no $IFACE — attach the radio first (see start-ap.sh / start-sta.sh)."
    exit 1
fi

# Find the phy behind wlan0 and the channel it is on, so the monitor lands on the AP's channel.
PHY=$(basename "$(readlink -f "/sys/class/net/$IFACE/phy80211")" 2>/dev/null)
CH=$(iw dev "$IFACE" info 2>/dev/null | awk '/channel/{print $2; exit}')

if ip link show "$MON" >/dev/null 2>&1; then
    echo "$MON already exists; bringing it up."
else
    echo "Adding monitor interface $MON on $PHY ..."
    iw phy "$PHY" interface add "$MON" type monitor 2>/tmp/.mon || {
        echo "Could not add $MON:"; sed 's/^/   /' /tmp/.mon; exit 1; }
fi
ip link set "$MON" up

# Put the monitor on the AP's channel if we could read one (so it hears the handshake).
if [ -n "$CH" ]; then
    iw dev "$MON" set channel "$CH" 2>/dev/null
    echo "$MON is up, listening on channel $CH."
else
    echo "$MON is up."
fi

echo
echo "Capture the handshake to a file (run this, THEN make a station associate):"
echo "    tcpdump -i $MON -w /root/wifi.pcap"
echo "Watch it live, EAPOL (handshake) frames only:"
echo "    tcpdump -i $MON -e -n ether proto 0x888e"
echo "Move /root/wifi.pcap to your machine and open it in Wireshark (see Capture Basics)."
