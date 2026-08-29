#!/bin/bash
# Start this node as a Wi-Fi Access Point (hostapd, WPA2-PSK).
# Usage: start-ap.sh [ip/cidr] [wired-iface]      (defaults 10.0.0.1/24, eth0)
#
# hostapd turns the node's radio into an access point beaconing the SSID in
# /etc/hostapd/hostapd.conf. A Station node running start-sta.sh then associates to it. The config
# is checked before anything starts, so a typo is reported rather than a daemon that silently is
# not there.
#
# TWO SHAPES, decided by one line in hostapd.conf:
#
#   no bridge= line   the AP stands alone. The address goes on wlan0 and wireless clients can
#                     reach this node and each other, and nothing else. This is wireless-basics.
#
#   bridge=<name>     the AP is bridged onto its wired segment, which is what a real access point
#                     is: wireless clients land on the same layer-2 network as whatever eth0 is
#                     cabled to, and the address belongs on the BRIDGE, not on the radio. This
#                     script then builds that bridge (creating it, enslaving the wired interface,
#                     bringing both up) before hostapd starts, and hostapd adds wlan0 to it.
#
# The wired interface defaults to eth0 and can be named as the second argument. An interface that
# already carries an IPv4 address is left alone and reported, rather than silently swallowed by the
# bridge along with the address a student just configured.

CONF=/etc/hostapd/hostapd.conf
IFACE=wlan0
APIP="${1:-10.0.0.1/24}"
WIRED="${2:-eth0}"

# The bridge= line is hostapd's own option, so the config file stays the single statement of what
# this AP is — there is no second switch to keep in step with it. Trailing whitespace and CR are
# stripped because this file is meant to be edited, and an editor may leave either behind.
BRIDGE=$(sed -n 's/^[[:space:]]*bridge=//p' "$CONF" | head -n1 | tr -d '[:space:]')

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

# --- bridged AP: the bridge has to exist before hostapd, which puts wlan0 into it ---
if [ -n "$BRIDGE" ]; then
    echo "Bridged access point: $CONF asks for bridge '$BRIDGE'."
    if ! ip link show "$BRIDGE" >/dev/null 2>&1; then
        if ! ip link add "$BRIDGE" type bridge 2>/dev/null; then
            echo "FAILED: could not create bridge '$BRIDGE'."
            echo "The bridge kernel module is missing on the GNS3 VM host. A container cannot load"
            echo "it from inside its own namespace — it is listed in the appliance manifest's"
            echo "kernel_modules:, so an appliance built from that manifest already has it."
            exit 1
        fi
    fi
    ip link set "$BRIDGE" up

    if ip link show "$WIRED" >/dev/null 2>&1; then
        # An address on the wired interface means it is doing another job. Enslaving it would move
        # that address out from under whoever set it, so say so and bridge nothing.
        if ip -4 addr show dev "$WIRED" 2>/dev/null | grep -q 'inet '; then
            echo "   NOTE: $WIRED has an IPv4 address, so it was NOT added to $BRIDGE."
            echo "   Remove the address first if this AP should be bridged onto that segment."
        else
            ip link set "$WIRED" up
            ip link set "$WIRED" master "$BRIDGE" 2>/dev/null
        fi
    else
        echo "   NOTE: no $WIRED on this node — $BRIDGE has no wired side yet."
        echo "   Cable this node's Ethernet port on the GNS3 canvas, then run start-ap.sh again."
    fi
fi

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
    SSID=$(grep '^ssid=' "$CONF" | cut -d= -f2)
    if [ -n "$BRIDGE" ]; then
        # The radio is a port on the bridge now, so the address goes on the bridge. An address left
        # on wlan0 would be on an interface that no longer terminates traffic, which looks right in
        # `ip addr` and answers nothing.
        ip addr flush dev "$IFACE" 2>/dev/null
        ip addr flush dev "$BRIDGE" 2>/dev/null
        ip addr add "$APIP" dev "$BRIDGE"
        MEMBERS=$(ls /sys/class/net/"$BRIDGE"/brif 2>/dev/null | tr '\n' ' ')
        echo "hostapd started. Access point '$SSID' is beaconing on $IFACE,"
        echo "bridged onto $BRIDGE ($APIP) with: ${MEMBERS:-nothing yet}"
    else
        ip addr flush dev "$IFACE" 2>/dev/null
        ip addr add "$APIP" dev "$IFACE"
        echo "hostapd started. Access point '$SSID' is beaconing on $IFACE ($APIP)."
    fi
    echo
    echo "On a Station node, join it with:   start-sta.sh"
    echo "Watch for associated clients:      wifi-status.sh"
    echo "Capture the four-way handshake:    start-monitor.sh   (then tcpdump on mon0)"
else
    echo "hostapd did not stay running. Last lines of /var/log/wifi/hostapd.log:"
    tail -n 12 /var/log/wifi/hostapd.log 2>/dev/null | sed 's/^/   /'
    exit 1
fi
