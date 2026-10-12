#!/bin/bash
# Start the FreeRADIUS server on this node.
# Usage: start-radius.sh        check the configuration, then run radiusd in the background
#        start-radius.sh -X     check, then run it in the FOREGROUND in debug mode (Ctrl-C stops it)
#
# The configuration is checked BEFORE anything starts (radiusd -C), so a typo in clients.conf or
# the users file is reported with a file and line rather than a daemon that silently is not there.
#
# Debug mode is the single most useful thing FreeRADIUS has: it prints every request, every
# attribute, which entry in the users file matched and why a login was rejected. When a login
# fails and the reason is not obvious, stop the server and run start-radius.sh -X.

RADDB=/etc/raddb
LOG=/var/log/radius/radius.log
DEBUG=0
[ "$1" = "-X" ] && DEBUG=1

# /run/radiusd holds the PID file; it lives on tmpfs and is gone after a restart, so it is
# recreated here rather than only in the image. The log directory is persisted but may be new.
mkdir -p /run/radiusd /var/log/radius/radacct
chown -R radius:radius /run/radiusd /var/log/radius 2>/dev/null

echo "Checking the configuration in $RADDB ..."
# -XC, not -C: plain -C writes its errors to radius.log and prints nothing here. -X sends them
# to the screen, and every useful line starts with the file and line number it is about.
if ! radiusd -XC >/tmp/radiusd-check.log 2>&1; then
    echo
    echo "FAILED: the configuration was rejected. Nothing was started."
    grep -E '^/etc/raddb/[^ ]*\[[0-9]+\]|^Failed|^Errors' /tmp/radiusd-check.log \
        | tail -n 4 | sed 's/^/   /'
    echo "The number in [brackets] is the line in that file. Full output: /tmp/radiusd-check.log"
    echo "Fix the file it names, then run start-radius.sh again."
    exit 1
fi
echo "   OK"

# Restart cleanly if already running, so this script is safe to run repeatedly. radiusd reads
# clients.conf and the users file only at start-up, so a restart is how an edit takes effect.
if pgrep -x radiusd >/dev/null 2>&1; then
    echo "Stopping the running radiusd..."
    pkill -x radiusd
    for i in 1 2 3 4 5; do pgrep -x radiusd >/dev/null 2>&1 || break; sleep 1; done
fi

if [ "$DEBUG" = 1 ]; then
    echo "Starting radiusd in debug mode. Press Ctrl-C to stop it, then run start-radius.sh"
    echo "(without -X) to start it normally again."
    echo
    exec radiusd -X
fi

echo "Starting radiusd..."
radiusd

sleep 2
if pgrep -x radiusd >/dev/null 2>&1; then
    echo "radiusd started. It listens on UDP 1812 (authentication) and 1813 (accounting)."
    echo
    echo "Test it from this node:     radtest sam staffpass 127.0.0.1 0 testing123"
    echo "Lab clients and secrets:    $RADDB/clients.conf"
    echo "Users, passwords, VLANs:    $RADDB/users"
    echo "The lab CA certificate:     $RADDB/certs/ca.pem   (copy it to clients that validate the server)"
    echo "Log file:                   $LOG"
    echo "See what it is doing:       radius-status.sh      (or stop it and run: start-radius.sh -X)"
else
    echo "radiusd did not stay running. The end of $LOG:"
    tail -n 10 "$LOG" 2>/dev/null | sed 's/^/   /'
    echo "For the full story run:  start-radius.sh -X"
    exit 1
fi
