#!/bin/bash
# Leave the Tailscale mesh and remove this node's identity from it.
# Usage: stop-tailscale.sh [--quiet]
#
# Joining is deliberate and so is leaving. After this runs, the other sites cannot reach anything
# here and this node cannot reach them, until somebody runs start-tailscale.sh again on purpose.
#
# It also scrubs /var/lib/tailscale, which holds this machine's private key - the thing that lets
# it act as this machine inside somebody's tailnet. That directory is not one GNS3 keeps for this
# template, so closing the project clears it anyway; doing it here as well means the node is clean
# from the moment you finish, not from the next time the project happens to be closed.
#
# Safe to run when nothing is running: it says so and changes nothing.

QUIET=0
[ "$1" = "--quiet" ] && QUIET=1
[ -n "$1" ] && [ "$1" != "--quiet" ] && { echo "unknown option: $1"; exit 2; }

STATE_DIR=/var/lib/tailscale

# A backgrounded daemon whose parent has gone leaves a zombie behind: GNS3 runs each node with
# /bin/sh as PID 1, and that shell does not reap orphans. A zombie still matches `pgrep -x`, so the
# naive check reports a daemon that has actually exited as still running - and then this script
# would skip starting it and nothing would work. Measured on the appliance, 27 August 2026.
daemon_alive() {
    for p in $(pgrep -x tailscaled 2>/dev/null); do
        grep -q "^State:.*Z" "/proc/$p/status" 2>/dev/null && continue
        return 0
    done
    return 1
}

if ! daemon_alive; then
    echo "tailscaled was not running - this node is not on any mesh."
else
    # logout first, and while the daemon is still up: it tells the coordination server to
    # invalidate this machine's key, so the entry left in the owner's admin console is dead rather
    # than dormant. `down` alone only stops using the tunnel.
    echo "Logging out of the tailnet..."
    tailscale logout >/dev/null 2>&1 || echo "  (logout reported a problem; carrying on)"
    tailscale down >/dev/null 2>&1

    echo "Stopping tailscaled..."
    pkill -x tailscaled
    i=0
    while daemon_alive && [ "$i" -lt 10 ]; do sleep 1; i=$((i + 1)); done
    if daemon_alive; then
        echo "  WARNING: tailscaled is still running. Try again, or restart the node."
    else
        echo "  ok       tailscaled has stopped"
    fi
fi

# Scrub the state directory and then check that the scrub worked, rather than assuming it.
rm -rf "$STATE_DIR"/* 2>/dev/null
if [ -n "$(ls -A "$STATE_DIR" 2>/dev/null)" ]; then
    echo "  NOT SCRUBBED: $STATE_DIR still has files:"
    ls -A "$STATE_DIR" | sed 's/^/    /'
else
    echo "  ok       $STATE_DIR is empty - no machine key left on this node"
fi

if [ "$QUIET" = 0 ]; then
    echo
    echo "This node has left the mesh."
    echo
    echo "The machine entry stays listed in the tailnet owner's admin console until they delete"
    echo "it. Ask them to remove old entries when the group has finished - a logged-out machine"
    echo "cannot do anything, but a long list makes it hard to tell whose is whose."
    echo
    echo "Rejoin whenever you next need it:  start-tailscale.sh --key -"
fi
