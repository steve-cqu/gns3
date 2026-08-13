#!/bin/bash
# What is this DNS server actually doing?
# Usage: dns-status.sh

echo "================================================"
echo "DNS Server Status"
echo "================================================"
echo ""

echo "1. named process:"
if pgrep -x named >/dev/null 2>&1; then
    ps -o pid,args -C named 2>/dev/null || pgrep -a named
else
    echo "   named is NOT running — start it with start-dns.sh"
fi
echo ""

echo "2. This node's addresses (what clients should point at):"
ip -4 addr show | grep -E 'inet ' | grep -v '127.0.0.1' || echo "   no IPv4 address configured"
echo ""

echo "3. Configuration and zone check:"
named-checkconf -z /etc/bind/named.conf 2>&1 | sed 's/^/   /'
echo ""

echo "4. Zones served (from named.conf):"
grep -E '^\s*zone ' /etc/bind/named.conf | sed 's/^/   /'
echo ""

echo "5. Test query — forward (www.example.com):"
dig +short @127.0.0.1 www.example.com | sed 's/^/   /' || echo "   query failed"
echo ""

echo "6. Test query — reverse (192.168.1.20):"
dig +short @127.0.0.1 -x 192.168.1.20 | sed 's/^/   /' || echo "   query failed"
echo ""

echo "7. Is this server answering as authoritative?"
echo "   (look for 'flags: ... aa' — aa means authoritative answer)"
dig @127.0.0.1 www.example.com | grep -E '^;; flags' | sed 's/^/   /'
echo ""

echo "================================================"
echo "Zone files:   /var/bind/pri/"
echo "Config:       /etc/bind/named.conf"
echo "================================================"
