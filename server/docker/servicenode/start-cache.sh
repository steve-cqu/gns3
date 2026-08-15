#!/bin/bash
# Start the Valkey (Redis-compatible) cache server on this node.
# Usage: start-cache.sh
#
# The config is checked before the server starts, so a typo is reported rather than silently
# ignored. Edit /etc/valkey/valkey.conf (the exposure lesson lives there), then run this again.

CONF=/etc/valkey/valkey.conf

mkdir -p /var/lib/valkey /var/log/valkey
chown -R valkey:valkey /var/lib/valkey /var/log/valkey 2>/dev/null

echo "Checking $CONF ..."
# valkey-server --test-... has no offline check; the cheapest validation is to have it parse the
# file and refuse to start on a bad directive, which it does. We catch that below.

# Restart cleanly if already running, so this script is safe to run repeatedly.
# No -x: valkey rewrites its process title to "valkey-server 0.0.0.0:6379", which BusyBox
# pgrep/pkill -x can never match exactly — found live when this restart path silently never fired.
if pgrep valkey-server >/dev/null 2>&1; then
    echo "Stopping the running valkey-server..."
    pkill valkey-server
    sleep 1
fi

echo "Starting valkey-server..."
valkey-server "$CONF" --daemonize yes

sleep 1
# NOAUTH is a healthy answer, not a failure: once a student sets requirepass — the fix the
# activity asks for — an unauthenticated PING is *refused*, and treating that as "did not
# answer" would tell them their fix broke the server. Found walking the activity live.
REPLY=$(valkey-cli ping 2>&1)
if echo "$REPLY" | grep -q PONG; then
    echo "valkey-server started (replied PONG)."
    echo
    echo "Set and read a key here:      valkey-cli set course COIT12202 ; valkey-cli get course"
    echo "From another node (exposed):  valkey-cli -h <this-node-ip> ping"
    echo "See every setting in force:   valkey-cli config get '*' | head"
    echo "Check what it is doing:       cache-status.sh"
elif echo "$REPLY" | grep -q NOAUTH; then
    echo "valkey-server started, and requirepass is set: it now refuses commands until you"
    echo "authenticate. Talk to it with:   valkey-cli -a <password>"
else
    echo "valkey-server did not answer. Check /var/log/valkey/valkey.log"
    tail -n 10 /var/log/valkey/valkey.log 2>/dev/null | sed 's/^/   /'
    exit 1
fi
