#!/bin/bash
# What is this 802.1X Switch doing? One line per port, then the details behind it.
# Usage: 8021x-status.sh

CONF=/etc/nac/switch.conf
LOG=/var/log/nac
[ -f "$CONF" ] && . "$CONF"

echo "================================================"
echo "802.1X Switch Status"
echo "================================================"
echo ""

echo "1. Switch processes:"
if pgrep -x hostapd >/dev/null 2>&1; then
    echo "   hostapd (802.1X) running:  $(pgrep -x hostapd | tr '\n' ' ')"
    echo "   port watchers (hostapd_cli): $(pgrep -x hostapd_cli | wc -l) of $(echo $ACCESS_PORTS | wc -w)"
else
    echo "   hostapd is NOT running — start the switch with start-8021x-switch.sh"
fi
echo ""

echo "2. Management port and RADIUS server:"
MGMT_IP=$(ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | head -1)
echo "   eth0 (management): ${MGMT_IP:-no address}"
if ping -c 1 -W 1 "$RADIUS_SERVER" >/dev/null 2>&1; then
    echo "   RADIUS server $RADIUS_SERVER: reachable"
else
    echo "   RADIUS server $RADIUS_SERVER: NOT reachable from eth0"
fi
echo ""

echo "3. Access ports:"
printf "   %-6s %-6s %-5s %-19s %s\n" PORT STATE VLAN MAC USER
for p in $ACCESS_PORTS; do
    vid=$(bridge -j vlan show dev "$p" 2>/dev/null | grep -o '"vlan":[0-9]*' | head -1 | cut -d: -f2)
    if nft list set bridge nac authports 2>/dev/null | grep -q "\"$p\""; then
        state=OPEN
        mac=$(nft list set bridge nac authed 2>/dev/null | grep -o "[0-9a-f:]\{17\} \. \"$p\"" | head -1 | cut -d' ' -f1)
        user=$(hostapd_cli -p /run/hostapd -i "$p" sta "$mac" 2>/dev/null | sed -n 's/^dot1xAuthSessionUserName=//p')
    else
        state=SHUT; mac=-; user=-
    fi
    printf "   %-6s %-6s %-5s %-19s %s\n" "$p" "$state" "${vid:--}" "$mac" "$user"
done
echo ""

echo "4. Trunk port:"
tv=$(bridge -j vlan show dev "$TRUNK_PORT" 2>/dev/null | grep -o '"vlan":[0-9]*' | cut -d: -f2 | tr '\n' ' ')
echo "   $TRUNK_PORT carries VLANs: ${tv:-none (is the switch started?)}"
echo ""

echo "5. The gate (frames dropped on shut ports so far):"
nft list chain bridge nac gate 2>/dev/null | grep -E 'counter' | sed 's/^[[:space:]]*/   /' \
    || echo "   no gate installed"
echo ""

echo "6. Recent port events:"
if [ -s "$LOG/nac.log" ]; then
    tail -n 6 "$LOG/nac.log" | sed 's/^/   /'
else
    echo "   none yet"
fi
echo ""

echo "================================================"
echo "Settings:    $CONF   (then run start-8021x-switch.sh again)"
echo "Port log:    $LOG/nac.log"
echo "802.1X log:  $LOG/hostapd.log"
echo "================================================"
