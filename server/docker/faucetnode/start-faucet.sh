#!/bin/bash
# Start the Faucet SDN controller on this node.
# Usage: start-faucet.sh [config-file]        (default: /etc/faucet/faucet.yaml)
#
# The controller listens for switches on TCP 6653 and publishes its metrics for Prometheus on
# TCP 9302. It does not need to be restarted when a switch connects or disconnects — only when
# the configuration file changes.

CONF=${1:-${FAUCET_CONFIG:-/etc/faucet/faucet.yaml}}
LOG=${FAUCET_LOG:-/var/log/faucet/faucet.log}

# Explicit interpreter, deliberately. /opt/faucet/bin/faucet is a #!/opt/faucet/bin/python
# script sitting in an image layer, and an image-layer script executed through its own shebang
# is exactly the shape that fails inside a GNS3 node — see the wg-quick write-up in
# alpinenode's Dockerfile. Naming the interpreter is the proven way round it.
PYTHON=/opt/faucet/bin/python
FAUCET=/opt/faucet/bin/faucet
# A venv's python is a symlink to the system interpreter and /proc/<pid>/exe resolves symlinks,
# so a process started as /opt/faucet/bin/python reports /usr/bin/python3.14. The comparison
# below has to be against the resolved path or it never matches — which is how the first version
# of this script declared a running controller dead.
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

# Find the running controller, if there is one.
#
# NOT `pgrep -f`. BusyBox's pgrep matches any process whose command line merely CONTAINS the
# pattern — including the shell that is about to run the thing being looked for — so
# `pgrep -f /opt/faucet/bin/faucet` reports a controller that does not exist and this script
# would announce "stopping" on a node where nothing was ever started. Measured 15 August 2026.
# Requiring the process's executable to be the interpreter cannot false-positive on a shell,
# whatever that shell's command line happens to mention.
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

if [ ! -f "$CONF" ]; then
    echo "FAILED: $CONF not found."
    echo "Examples to start from are in /etc/faucet/examples/."
    exit 1
fi

# Validate before starting, so a typo produces a message naming the line rather than a
# controller that is not there. Same reason named-checkconf runs in start-dns.sh.
#
# On success the output is discarded: check_faucet_config prints the entire normalised
# configuration, which is a page and a half and buries the one line a student is waiting for.
# Run `check_faucet_config` directly to read it. On failure every word of it is shown.
echo "Checking $CONF ..."
CHECK_OUT=$(check_faucet_config "$CONF" 2>&1)
if [ $? -ne 0 ]; then
    echo "$CHECK_OUT"
    echo
    echo "FAILED: the configuration above is not valid, so the controller was NOT started."
    echo "Fix the file and run this script again."
    exit 1
fi
echo "Configuration is valid."

# Restart cleanly if it is already running, so this script is safe to run repeatedly — which is
# what a student does after every edit to faucet.yaml.
RUNNING=$(faucet_pids)
if [ -n "$RUNNING" ]; then
    echo "Stopping the running controller (pid $(echo "$RUNNING" | tr '\n' ' '))..."
    # shellcheck disable=SC2086
    kill $RUNNING 2>/dev/null
    sleep 2
    RUNNING=$(faucet_pids)
    # shellcheck disable=SC2086
    [ -n "$RUNNING" ] && kill -9 $RUNNING 2>/dev/null
fi

mkdir -p "$(dirname "$LOG")"
echo "Starting Faucet..."
nohup "$PYTHON" "$FAUCET" >/dev/null 2>&1 &

sleep 3
if [ -n "$(faucet_pids)" ]; then
    echo "Faucet is running."
    echo
    echo "  OpenFlow:    tcp/6653   — point the switch here:"
    echo "               ovs-vsctl set-controller br0 tcp:<this-node-ip>:6653"
    echo "  Metrics:     tcp/9302   — the Monitor node scrapes this"
    echo "  Config:      $CONF"
    echo "  Log:         $LOG"
    echo
    echo "Check this controller:   faucet-status.sh"
    echo "Watch switches connect:  tail -f $LOG"
else
    echo "FAILED: Faucet did not stay running. The last of $LOG:"
    tail -20 "$LOG" 2>/dev/null
    exit 1
fi
