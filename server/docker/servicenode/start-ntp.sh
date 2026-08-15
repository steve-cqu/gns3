#!/bin/bash
# Start the chrony NTP server on this node.
# Usage: start-ntp.sh
#
# Note the -x flag below. A container shares the host kernel's clock, so chronyd must not try
# to discipline it — see the header of /etc/chrony/chrony.conf for what that means for the
# client side of an NTP activity.

CONF=/etc/chrony/chrony.conf

if [ ! -f "$CONF" ]; then
    echo "FAILED: $CONF not found."
    exit 1
fi

# Restart cleanly if it is already running, so this script is safe to run repeatedly.
if pgrep -x chronyd >/dev/null 2>&1; then
    echo "Stopping the running chronyd..."
    pkill -x chronyd
    sleep 1
fi

echo "Starting chronyd..."
# -f  use this config file
# -x  do NOT control the system clock. Without it chronyd tries to adjust a clock it does not
#     own (the GNS3 VM's), which it is not permitted to do from inside a container.
chronyd -f "$CONF" -x

sleep 1
if pgrep -x chronyd >/dev/null 2>&1; then
    echo "chronyd started, serving time at stratum 8."
    echo
    echo "Check this server:            ntp-status.sh"
    echo "See who is asking for time:   chronyc clients"
    echo
    echo "From a CLIENT node, measure the offset without setting any clock:"
    echo "    chronyd -Q 'server <this-node-ip> iburst'"
    echo "    chronyc -h <this-node-ip> tracking"
else
    echo "chronyd did not stay running. Check the console output above."
    exit 1
fi
