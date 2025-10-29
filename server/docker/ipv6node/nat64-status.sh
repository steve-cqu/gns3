#!/bin/bash

echo "================================================"
echo "NAT64 Status Check"
echo "================================================"
echo ""

echo "1. IP Forwarding Status:"
echo "   IPv4: $(sysctl -n net.ipv4.ip_forward)"
echo "   IPv6: $(sysctl -n net.ipv6.conf.all.forwarding)"
echo ""

echo "2. TAYGA Process:"
ps aux | grep tayga | grep -v grep || echo "   TAYGA not running!"
echo ""

echo "3. nat64 Interface Status:"
ip link show nat64 2>/dev/null || echo "   nat64 interface not found!"
echo ""

echo "4. NAT64 Interface Addresses:"
ip addr show nat64 2>/dev/null | grep -E 'inet|inet6' || echo "   No addresses configured"
echo ""

echo "5. NAT64 Routes:"
echo "   IPv6 routes:"
ip -6 route show | grep 64:ff9b || echo "     No NAT64 IPv6 route found"
echo "   IPv4 routes:"
ip route show | grep 192.168.255 || echo "     No NAT64 IPv4 route found"
echo ""

echo "6. iptables NAT Rules:"
iptables -t nat -L POSTROUTING -n -v | grep 192.168.255 || echo "   No masquerade rule found"
echo ""

echo "7. Router Interfaces:"
ip addr show eth0
ip addr show eth1
echo ""

echo "================================================"
