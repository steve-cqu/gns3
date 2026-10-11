#!/bin/bash
# Start (or restart) the 802.1X Switch.
# Usage: start-8021x-switch.sh
#
# Builds the switch from /etc/nac/switch.conf: a VLAN-aware Linux bridge, br0, with the access
# ports shut by an nftables gate, a trunk port carrying every VLAN, and hostapd on each access port
# as the 802.1X authenticator. Safe to run again: it tears down what it built and starts over, so
# that is how an edit to switch.conf takes effect.
#
# A real switch does all of this in one box of silicon. Here each part is a tool you can inspect:
#   bridge vlan show          which VLAN each port is in
#   nft list table bridge nac the gate: which MAC is allowed in on which port
#   hostapd_cli -i eth1 all_sta   the 802.1X state of a port
# 8021x-status.sh shows all three.

CONF=/etc/nac/switch.conf
LOG=/var/log/nac
RUN=/run/hostapd

if [ ! -f "$CONF" ]; then
    echo "FAILED: $CONF is missing."; exit 1
fi
. "$CONF"

# ---- Checks before touching anything ------------------------------------------------------------
fail=0
for p in $ACCESS_PORTS $TRUNK_PORT; do
    if ! ip link show "$p" >/dev/null 2>&1; then
        echo "FAILED: port $p (from $CONF) does not exist on this node."; fail=1
    fi
done
MGMT_IP=$(ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
if [ -z "$MGMT_IP" ]; then
    echo "FAILED: eth0, the management port, has no address. The switch needs one to talk to"
    echo "        the RADIUS server. For example: ip addr add 192.168.1.2/24 dev eth0"
    fail=1
fi
case " $VLANS " in
    *" $QUARANTINE_VLAN "*) ;;
    *) echo "FAILED: QUARANTINE_VLAN=$QUARANTINE_VLAN is not in VLANS=\"$VLANS\"."; fail=1 ;;
esac
[ "$fail" = 0 ] || { echo "Fix $CONF or the node, then run start-8021x-switch.sh again."; exit 1; }

mkdir -p "$LOG" "$RUN"

# ---- Tear down a previous run -------------------------------------------------------------------
if pgrep -x hostapd >/dev/null 2>&1 || ip link show br0 >/dev/null 2>&1; then
    echo "Stopping the running switch..."
fi
pkill -x hostapd_cli 2>/dev/null
pkill -x hostapd 2>/dev/null
for i in 1 2 3 4 5; do pgrep -x hostapd >/dev/null 2>&1 || break; sleep 1; done
nft delete table bridge nac 2>/dev/null
ip link del br0 2>/dev/null
rm -f "$RUN"/*

# ---- The bridge: VLAN-aware, every access port shut in the quarantine VLAN ----------------------
# vlan_default_pvid 0: a port gets no VLAN unless this script gives it one, so nothing is
# forwarded by accident in VLAN 1.
ip link add br0 type bridge vlan_filtering 1 vlan_default_pvid 0
ip link set br0 up

ip link set "$TRUNK_PORT" master br0
ip link set "$TRUNK_PORT" up
for v in $VLANS; do bridge vlan add vid "$v" dev "$TRUNK_PORT"; done

for p in $ACCESS_PORTS; do
    ip link set "$p" master br0
    ip link set "$p" up
    bridge vlan add vid "$QUARANTINE_VLAN" dev "$p" pvid untagged
done

# ---- The gate: an access port forwards nothing until a user on it logs in -----------------------
# Linux bridges cannot lock a port on this appliance's kernel (5.15; locked ports need 5.18), so the
# gate is nftables in the bridge family. `authed` holds MAC . port pairs, so an authorised MAC is
# let in only on the port it logged in on. `authports` lets traffic OUT to a port only once someone
# on it has logged in. 802.1X login frames (EAPOL) are not forwarded by a bridge at all: hostapd
# reads them straight off the port, so the gate never sees them.
PORTSET=$(echo $ACCESS_PORTS | sed 's/[^ ][^ ]*/"&"/g; s/ /, /g')
nft -f - <<EOF
table bridge nac {
	set authed {
		type ether_addr . ifname
	}
	set authports {
		type ifname
	}
	chain gate {
		type filter hook forward priority 0; policy accept;
		iifname { $PORTSET } ether saddr . iifname @authed accept
		iifname { $PORTSET } counter drop
		oifname { $PORTSET } oifname @authports accept
		oifname { $PORTSET } counter drop
	}
}
EOF
if [ $? -ne 0 ]; then
    echo "FAILED: could not install the nftables gate. Nothing is protecting the ports."; exit 1
fi

# ---- hostapd: the 802.1X authenticator, one config per access port ------------------------------
# driver=wired: hostapd speaks EAPOL on a wired port and RADIUS to the server.
# dynamic_vlan=0: the wired driver cannot apply a VLAN from the Access-Accept (with 1 it reports
#   the user authorised and never opens the port). The VLAN is applied by nac-port-action.sh.
# eap_reauth_period=0: no periodic re-login; a user stays in until they log off.
# use_pae_group_addr=1: send EAPOL to the 802.1X group address, as a real switch does.
CONFS=""
for p in $ACCESS_PORTS; do
    cat > "$RUN/$p.conf" <<EOF
interface=$p
driver=wired
ctrl_interface=$RUN
ieee8021x=1
eapol_version=2
eap_reauth_period=0
use_pae_group_addr=1
dynamic_vlan=0
logger_stdout=-1
logger_stdout_level=1
own_ip_addr=$MGMT_IP
nas_identifier=$SWITCH_NAME
auth_server_addr=$RADIUS_SERVER
auth_server_port=1812
auth_server_shared_secret=$RADIUS_SECRET
acct_server_addr=$RADIUS_SERVER
acct_server_port=1813
acct_server_shared_secret=$RADIUS_SECRET
EOF
    CONFS="$CONFS $RUN/$p.conf"
done

echo "Starting hostapd on$(printf ' %s' $ACCESS_PORTS)..."
hostapd -t $CONFS >> "$LOG/hostapd.log" 2>&1 &

# Wait for each port's control socket, then attach the action script that opens and shuts it.
for p in $ACCESS_PORTS; do
    for i in $(seq 1 20); do [ -S "$RUN/$p" ] && break; sleep 0.25; done
    if [ ! -S "$RUN/$p" ]; then
        echo "FAILED: hostapd did not start on $p. The end of $LOG/hostapd.log:"
        tail -n 8 "$LOG/hostapd.log" | sed 's/^/   /'
        exit 1
    fi
    hostapd_cli -p "$RUN" -i "$p" -a /usr/local/bin/nac-port-action.sh -B >/dev/null
done
echo "$(date '+%F %T') switch started: access$(printf ' %s' $ACCESS_PORTS), trunk $TRUNK_PORT, RADIUS $RADIUS_SERVER" >> "$LOG/nac.log"

echo "802.1X Switch started."
echo
echo "Management address:   $MGMT_IP (eth0)   RADIUS server: $RADIUS_SERVER   name: $SWITCH_NAME"
echo "Access ports (shut until a user logs in):$(printf ' %s' $ACCESS_PORTS)"
echo "Trunk port (VLANs $VLANS, tagged): $TRUNK_PORT"
echo
echo "See every port's state:   8021x-status.sh"
echo "Port log (who, which VLAN): $LOG/nac.log"
echo "802.1X log (hostapd):       $LOG/hostapd.log"
echo "The RADIUS server must list this switch: client sw1 { ipaddr = $MGMT_IP ... } in clients.conf"
