#!/bin/sh
# nac-port-action.sh — opens and shuts an 802.1X Switch port. Run by hostapd_cli -a, one per
# access port, which calls it with: <port> <event> <MAC address>.
#
#   AP-STA-CONNECTED     a user's 802.1X login on this port succeeded: ask the RADIUS server
#                        which VLAN the user belongs in, put the port in that VLAN, and let the
#                        user's MAC address through the gate.
#   AP-STA-DISCONNECTED  the user logged off (or the switch gave up on them): shut the port again.
#
# Why the switch asks the server a second question. A vendor switch reads the user's VLAN from the
# Access-Accept that ends the login. hostapd's wired driver cannot apply it, so once the login has
# succeeded this script sends the server an Authorize-Only request for the user's name and takes
# the VLAN from that answer. The VLAN still comes from the server's users file: change it there,
# and the next login lands in the new VLAN with nothing changed on the switch. The server answers
# that request only from the client named sw1 (its policy.d/nac).

PORT=$1; EVENT=$2; MAC=$3
. /etc/nac/switch.conf
LOG=/var/log/nac/nac.log
log() { echo "$(date '+%F %T') $PORT $*" >> "$LOG"; }

set_vlan() {    # set_vlan <vid>: make <vid> the port's only VLAN, untagged
    for v in $(bridge -j vlan show dev "$PORT" 2>/dev/null | grep -o '"vlan":[0-9]*' | cut -d: -f2); do
        bridge vlan del vid "$v" dev "$PORT"
    done
    bridge vlan add vid "$1" dev "$PORT" pvid untagged
}

case "$EVENT" in
AP-STA-CONNECTED)
    # The name the user logged in as. With PEAP and an anonymous outer identity this is still the
    # real name: the server's use_tunneled_reply copies it into the Access-Accept, and hostapd
    # takes it from there.
    WHO=$(hostapd_cli -p /run/hostapd -i "$PORT" sta "$MAC" 2>/dev/null \
          | sed -n 's/^dot1xAuthSessionUserName=//p')
    VID=$(echo "User-Name = \"$WHO\", Service-Type = Authorize-Only, NAS-Identifier = \"$SWITCH_NAME\"" \
          | radclient -x -r 2 -t 3 "$RADIUS_SERVER" auth "$RADIUS_SECRET" 2>/dev/null \
          | sed -n 's/.*Tunnel-Private-Group-Id:0 = "\([0-9]*\)".*/\1/p' | head -n 1)
    case " $VLANS " in
        *" $VID "*) WHY="from the RADIUS server" ;;
        *)          WHY="no VLAN from the RADIUS server${VID:+ (VLAN $VID is not on this switch)}"
                    VID=$QUARANTINE_VLAN ;;
    esac
    set_vlan "$VID"
    nft add element bridge nac authed "{ $MAC . \"$PORT\" }"
    nft add element bridge nac authports "{ \"$PORT\" }"
    log "OPEN  $MAC user=$WHO vlan=$VID ($WHY)"
    ;;
AP-STA-DISCONNECTED)
    nft delete element bridge nac authed "{ $MAC . \"$PORT\" }" 2>/dev/null
    nft delete element bridge nac authports "{ \"$PORT\" }" 2>/dev/null
    set_vlan "$QUARANTINE_VLAN"
    log "SHUT  $MAC logged off; port back in VLAN $QUARANTINE_VLAN"
    ;;
esac
exit 0
