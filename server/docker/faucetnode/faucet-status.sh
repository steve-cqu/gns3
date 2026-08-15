#!/bin/bash
# Report what the Faucet SDN controller on this node is doing.
# Usage: faucet-status.sh
#
# Answers the three questions a stuck student actually has: is the controller running, does it
# agree with the configuration file on disk, and has the switch connected to it.

CONF=${FAUCET_CONFIG:-/etc/faucet/faucet.yaml}
LOG=${FAUCET_LOG:-/var/log/faucet/faucet.log}
PYTHON=/opt/faucet/bin/python
FAUCET=/opt/faucet/bin/faucet
# Resolved, because /proc/<pid>/exe follows the venv symlink — see start-faucet.sh.
PYREAL=$(readlink -f "$PYTHON")

# What a RUNNING controller actually looks like. /opt/faucet/bin/faucet is a two-line launcher
# that hands over to os_ken's manager, so the process in `ps` is
#     /opt/faucet/bin/python3 /opt/faucet/bin/osken-manager --config-file=... faucet.faucet
# and nothing in it contains the path this script starts. Matching the launcher path — the
# obvious thing to match — finds nothing at all, which is how the first version of this script
# announced a healthy controller as dead. Measured 15 August 2026. Both halves are required:
# faucet.gauge would otherwise match too.
RUN_MANAGER=/opt/faucet/bin/osken-manager
RUN_APP=faucet.faucet
PROM_PORT=${FAUCET_PROMETHEUS_PORT:-9302}

# See the long comment in start-faucet.sh: BusyBox pgrep -f matches the shell that names the
# path, so process detection is done on the executable behind the pid instead.
faucet_pids() {
    local d pid exe cmd
    for d in /proc/[0-9]*; do
        pid=${d#/proc/}
        exe=$(readlink -f "$d/exe" 2>/dev/null) || continue
        [ "$exe" = "$PYREAL" ] || continue
        cmd=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null) || continue
        case "$cmd" in
            *"$RUN_MANAGER"*"$RUN_APP"*) echo "$pid" ;;
        esac
    done
}

echo "=== Faucet SDN controller ==="
echo

PIDS=$(faucet_pids)
if [ -n "$PIDS" ]; then
    echo "RUNNING  faucet   (pid $(echo "$PIDS" | tr '\n' ' '))"
else
    echo "stopped  faucet   — start it with: start-faucet.sh"
fi

# Listening sockets. 6653 is where switches connect; 9302 is what the Monitor node scrapes.
for p in 6653 "$PROM_PORT"; do
    if netstat -ltn 2>/dev/null | grep -q ":$p "; then
        echo "LISTEN   tcp/$p"
    else
        echo "closed   tcp/$p"
    fi
done

echo
echo "=== Configuration: $CONF ==="
if [ -f "$CONF" ]; then
    if check_faucet_config "$CONF" >/dev/null 2>&1; then
        echo "valid"
        # The datapaths the file defines, which is what a student needs to compare against the
        # datapath-id actually set on the switch — a mismatch there is the usual reason a switch
        # connects and nothing works.
        echo
        echo "Datapaths and VLANs it defines:"
        awk '/^dps:/{s="dp"} /^vlans:/{s="vlan"} /dp_id:/{print "  " $0}
             s=="vlan" && /^    [a-zA-Z0-9_-]+:/{print "  vlan " $0}
             s=="dp"   && /^    [a-zA-Z0-9_-]+:/{print "  switch " $0}' "$CONF"
    else
        echo "INVALID — run: check_faucet_config $CONF"
    fi
else
    echo "MISSING — examples are in /etc/faucet/examples/"
fi

echo
echo "=== Switches connected (from $LOG) ==="
if [ -s "$LOG" ]; then
    # Faucet logs one of these per datapath as it comes up. Nothing here means no switch has
    # reached the controller: check the switch's set-controller line, and that the two nodes can
    # ping each other. "unknown datapath" means one did connect but its datapath-id is not in
    # the configuration above.
    MATCHES=$(grep -E "DPID|Configuring datapath|unknown datapath|CONFIG_CHANGE" "$LOG" | tail -10)
    if [ -n "$MATCHES" ]; then
        echo "$MATCHES" | sed 's/^/  /'
    else
        echo "  (nothing yet — no switch has connected)"
    fi
else
    echo "  (no log yet — the controller has not been started)"
fi

echo
echo "Metrics:  curl -s localhost:$PROM_PORT/ | head"
echo "Log:      tail -f $LOG"
