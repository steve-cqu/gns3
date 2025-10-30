#!/bin/bash

# This script configures the NAT64 router interfaces and routing.
# Router A ---- (eth0) Router B (NAT64) (eth1) ---- Subnet 3

echo "================================================"
echo "NAT64 Router Interface Configuration"
echo "================================================"

# eth0 - To Router A (Pre-configured dual stack)
echo "Configuring eth0 (to Router A - dual stack)..."
ip address add 192.168.2.2/24 dev eth0 2>/dev/null || echo "  IPv4 already configured"
ip -6 address add 2001:db8:1:2::2/64 dev eth0 2>/dev/null || echo "  IPv6 already configured"

# eth1 - To Subnet 3 (Pre-configured dual stack)
echo "Configuring eth1 (to Subnet 3 - dual stack)..."
ip address add 192.168.3.1/24 dev eth1 2>/dev/null || echo "  IPv4 already configured"
ip -6 address add 2001:db8:1:3::1/64 dev eth1 2>/dev/null || echo "  IPv6 already configured"

# Add routes to Subnet 1 via Router A
echo "Adding routes to Subnet 1 via Router A..."
ip -6 route add 2001:db8:1:1::/64 via 2001:db8:1:2::1 dev eth0 2>/dev/null || echo "  IPv6 route to Subnet 1 already exists"

# Enable IP forwarding
echo "Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1

echo "================================================"
echo "Interface Configuration Complete!"
echo "================================================"
echo ""
echo "Current Interface Status:"
ip address show eth0
ip address show eth1
echo ""
echo "IPv4 Routes:"
ip route show
echo ""
echo "IPv6 Routes:"
ip -6 route show
echo ""
