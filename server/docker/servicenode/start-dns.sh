#!/bin/bash
# Start the BIND DNS server on this node.
# Usage: start-dns.sh
#
# The configuration is checked BEFORE anything starts, so a typo produces a message that names
# the file and line rather than a daemon that silently is not there.

CONF=/etc/bind/named.conf

echo "Checking $CONF and its zone files..."
# -z loads every master zone as well as parsing the config, so a broken zone file (a missing
# trailing dot, an unbumped serial) is caught here rather than at the first query.
if ! named-checkconf -z "$CONF"; then
    echo
    echo "FAILED: the configuration or a zone file was rejected. Nothing was started."
    echo "Fix the file above, then run start-dns.sh again."
    exit 1
fi

# Restart cleanly if it is already running, so this script is safe to run repeatedly.
if pgrep -x named >/dev/null 2>&1; then
    echo "Stopping the running named..."
    pkill -x named
    sleep 1
fi

echo "Starting named..."
named -c "$CONF" -u named

sleep 1
if pgrep -x named >/dev/null 2>&1; then
    echo "named started."
    echo
    echo "Test it from this node:      dig @127.0.0.1 www.example.com"
    echo "Test it from another node:   dig @<this-node-ip> www.example.com"
    echo "Reverse lookup:              dig @127.0.0.1 -x 192.168.1.20"
    echo "Check what it is doing:      dns-status.sh"
else
    echo "named did not stay running. Check the console output above."
    exit 1
fi
