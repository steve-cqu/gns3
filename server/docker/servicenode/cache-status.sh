#!/bin/bash
# What is this Valkey cache actually doing?
# Usage: cache-status.sh

echo "================================================"
echo "Valkey Cache Status"
echo "================================================"
echo ""

echo "1. Server process:"
if pgrep -x valkey-server >/dev/null 2>&1; then
    ps -o pid,args -C valkey-server 2>/dev/null || pgrep -a valkey-server
else
    echo "   valkey-server is NOT running — start it with start-cache.sh"
fi
echo ""

echo "2. This node's addresses (what clients should point at):"
ip -4 addr show | grep -E 'inet ' | grep -v '127.0.0.1' || echo "   no IPv4 address configured"
echo ""

echo "3. Does it answer?"
valkey-cli ping 2>&1 | sed 's/^/   /'
echo ""

echo "4. Exposure check — is authentication required?"
echo "   (protected-mode and requirepass decide whether a remote client can issue commands)"
valkey-cli config get protected-mode 2>/dev/null | sed 's/^/   /'
valkey-cli config get requirepass 2>/dev/null | sed 's/^/   requirepass: /'
echo ""

echo "5. What is it bound to?"
valkey-cli config get bind 2>/dev/null | sed 's/^/   /'
echo ""

echo "6. Keys currently stored:"
valkey-cli dbsize 2>/dev/null | sed 's/^/   /'
echo ""

echo "================================================"
echo "Config:    /etc/valkey/valkey.conf"
echo "Log file:  /var/log/valkey/valkey.log"
echo "================================================"
