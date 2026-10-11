#!/bin/bash
# What is this FreeRADIUS server actually doing?
# Usage: radius-status.sh

RADDB=/etc/raddb
LOG=/var/log/radius/radius.log

echo "================================================"
echo "FreeRADIUS Server Status"
echo "================================================"
echo ""

echo "1. Server process:"
if pgrep -x radiusd >/dev/null 2>&1; then
    pgrep -a radiusd | sed 's/^/   /'
else
    echo "   radiusd is NOT running — start it with start-radius.sh"
fi
echo ""

echo "2. Listening (1812 authentication, 1813 accounting):"
LISTEN=$(netstat -lnu 2>/dev/null | grep -E ':(1812|1813) ')
[ -n "$LISTEN" ] && echo "$LISTEN" | sed 's/^/   /' || echo "   nothing listening on 1812/1813"
echo ""

echo "3. This node's addresses:"
ADDRS=$(ip -4 addr show | grep -E 'inet ' | grep -v '127.0.0.1')
[ -n "$ADDRS" ] && echo "$ADDRS" | sed 's/^ */   /' || echo "   no IPv4 address configured"
echo ""

echo "4. Configuration check:"
radiusd -XC >/tmp/radiusd-check.log 2>&1 && echo "   OK — configuration is valid" \
    || { echo "   FAILED:"; grep -E '^/etc/raddb/[^ ]*\[[0-9]+\]|^Failed|^Errors' /tmp/radiusd-check.log \
             | tail -n 4 | sed 's/^/   /'; }
echo ""

echo "5. RADIUS clients (devices allowed to ask; from $RADDB/clients.conf):"
awk '/^[[:space:]]*#/ {next}
     /^[[:space:]]*client[[:space:]]/ {name=$2; next}
     name && /ipaddr|ipv6addr/ {sub(/^[[:space:]]*/, ""); printf "   %-14s %s\n", name, $0; name=""}' \
    "$RADDB/clients.conf"
echo ""

echo "6. Users defined in $RADDB/users (first match wins):"
grep -vE '^(#|[[:space:]]|DEFAULT|$)' "$RADDB/users" | awk '{print "   " $1}'
echo ""

echo "7. Lab CA certificate (clients that validate the server need a copy of ca.pem):"
if [ -f "$RADDB/certs/ca.pem" ]; then
    openssl x509 -in "$RADDB/certs/ca.pem" -noout -subject -enddate 2>/dev/null | sed 's/^/   /'
    openssl x509 -in "$RADDB/certs/server.pem" -noout -subject 2>/dev/null \
        | sed 's/^subject=/   server certificate: /'
else
    echo "   no certificates in $RADDB/certs"
fi
echo ""

echo "8. Recent log entries:"
if [ -s "$LOG" ]; then
    tail -n 8 "$LOG" | sed 's/^/   /'
else
    echo "   the log is empty (no requests yet, or the server has not been started)"
fi
echo ""

echo "================================================"
echo "Clients:     $RADDB/clients.conf"
echo "Users:       $RADDB/users"
echo "Log file:    $LOG"
echo "Accounting:  /var/log/radius/radacct/<client address>/   (persisted)"
echo "Debug mode:  stop it, then run  start-radius.sh -X"
echo "================================================"
