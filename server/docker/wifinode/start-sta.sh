#!/bin/bash
# Start this node as a Wi-Fi Station (client): associate to the AP with wpa_supplicant
# (WPA2-PSK, WPA3-SAE or WPA2-Enterprise, whichever wpa_supplicant.conf asks for).
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

# A network needs a name and a way to authenticate: a passphrase (psk=, WPA2-PSK), a WPA3
# password (sae_password=), or an 802.1X login (key_mgmt=WPA-EAP, WPA2-Enterprise, where the
# identity and password are checked by a RADIUS server, not by the AP). Until 14 October 2026 this
# gate accepted psk= only, so a SAE or Enterprise config was refused before wpa_supplicant ran.
if ! grep -q 'ssid=' "$CONF" \
   || ! grep -Eq 'psk=|sae_password=|key_mgmt=.*WPA-EAP' "$CONF"; then
    echo "FAILED: $CONF is missing an ssid line, or has no psk=, sae_password= or"
    echo "key_mgmt=WPA-EAP line. Fix it and retry."
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
# -i interface, -c config, -D nl80211 driver. Run in the background with setsid rather than with
# wpa_supplicant's own -B: once daemonised it writes nothing more to stdout, and this build has no
# -f (log file) option, so the log held only two start-up lines. In the foreground it prints every
# event (association, the EAP method, the server's certificate, a certificate error, the four-way
# handshake), and those lines are what a student needs when a login fails. Measured 14 October 2026.
setsid wpa_supplicant -i "$IFACE" -c "$CONF" -D nl80211 \
    </dev/null >/var/log/wifi/wpa_supplicant.log 2>&1 &
echo $! > /run/wpa_supplicant/wpa.pid

# Give the four-way handshake time to complete. THIRTY seconds, not ten: the poll exits the moment
# the state reaches COMPLETED, so a longer window costs a fast host nothing and saves a slow one —
# and ten seconds was measurably too tight. On 19 August 2026 wireless-basics failed on amd64 with
# this script reporting "Did not associate" while the test's own check, seconds later, found the
# handshake COMPLETED. Re-running it passed. A slower box (Apple Silicon under TCG) loses that race
# more often, not less.
echo "Associating (four-way handshake) ..."
i=0; assoc=0
while [ $i -lt 30 ]; do
    if wpa_cli -i "$IFACE" status 2>/dev/null | grep -q 'wpa_state=COMPLETED'; then assoc=1; break; fi
    i=$((i+1)); sleep 1
done

# Set the address WHETHER OR NOT the poll won its race. This is the other half of the same defect:
# the address used to be assigned only inside the success branch, so a station that associated a
# second after we stopped looking was left associated with no IP — which looks like a working link
# and cannot pass a packet, and is the hardest possible state to diagnose from the node. A late
# association now simply starts working.
ip addr flush dev "$IFACE" 2>/dev/null
ip addr add "$STAIP" dev "$IFACE"

if [ "$assoc" = 1 ]; then
    BSSID=$(wpa_cli -i "$IFACE" status 2>/dev/null | awk -F= '/^bssid=/{print $2}')
    SSID=$(wpa_cli -i "$IFACE" status 2>/dev/null | awk -F= '/^ssid=/{print $2}')
    echo "Associated to '$SSID' (AP $BSSID). This node is $STAIP on $IFACE."
    echo
    # A station cannot learn the AP's IP address from the association — it knows a BSSID, which is a
    # MAC. So the hint below is only safe when this node kept the default address, because then the
    # AP is start-ap.sh's matching default (10.0.0.1). In any lab that chose its own addressing,
    # naming 10.0.0.1 sends a student to ping a host that does not exist and blame the radio.
    if [ "$STAIP" = "10.0.0.2/24" ]; then
        echo "Reach the AP:                ping 10.0.0.1"
    else
        echo "Reach the AP:                ping its address (start-ap.sh printed it on the AP)"
    fi
    echo "See the link (signal, rate): wifi-status.sh"
else
    echo "Did not associate within 30s. Last lines of /var/log/wifi/wpa_supplicant.log:"
    tail -n 12 /var/log/wifi/wpa_supplicant.log 2>/dev/null | sed 's/^/   /'
    echo "Check that the AP is running (start-ap.sh) and the SSID/passphrase match"
    echo "(for WPA2-Enterprise: the identity, password and certificate settings)."
    echo
    echo "$STAIP has been set on $IFACE anyway, so if the handshake completes late the link will"
    if [ "$STAIP" = "10.0.0.2/24" ]; then
        echo "simply start working. Check with:   wifi-status.sh   then   ping 10.0.0.1"
    else
        echo "simply start working. Check with:   wifi-status.sh   then ping the AP's address"
    fi
    exit 1
fi
