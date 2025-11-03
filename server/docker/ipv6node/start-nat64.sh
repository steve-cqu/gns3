# Create NAT64 startup script
#!/bin/bash

echo "================================================"
echo "Starting NAT64 Configuration"
echo "================================================"

# Create and configure NAT64 TUN interface
echo "Creating NAT64 TUN interface..."
tayga --mktun 2>/dev/null || echo "TUN device already exists"

echo "Bringing up nat64 interface..."
ip link set nat64 up

echo "Configuring nat64 interface addresses..."
ip addr add 192.168.255.1 dev nat64 2>/dev/null || echo "IPv4 address already configured"
ip -6 addr add 2001:db8:64::192.168.255.1/96 dev nat64 2>/dev/null || echo "IPv6 address already configured"
ip -6 route add 2001:db8:1:1::/64 via 2001:db8:1:2::1 dev eth0 2>/dev/null || echo "IPv6 default route already exists"

# Add routes
echo "Adding NAT64 routes..."
ip -6 route add 2001:db8:64::/96 dev nat64 2>/dev/null || echo "IPv6 route already exists"
ip route add 192.168.255.0/24 dev nat64 2>/dev/null || echo "IPv4 route already exists"

# Start TAYGA daemon
echo "Starting TAYGA daemon..."
tayga 2>/dev/null || echo "TAYGA already running"

# Configure iptables for masquerading
echo "Configuring iptables NAT..."
iptables -t nat -C POSTROUTING -s 192.168.255.0/24 -o eth0 -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -s 192.168.255.0/24 -o eth0 -j MASQUERADE

echo "================================================"
echo "NAT64 Configuration Complete!"
echo "================================================"
