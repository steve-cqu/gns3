# Dockerfile for NAT64 Router
FROM cqugns3/alpinenode

# Testing needed for tayga package
RUN echo "https://dl-cdn.alpinelinux.org/alpine/edge/testing" >> /etc/apk/repositories

# Install required packages
RUN apk add --no-cache \
    tayga \
    iptables \
    ip6tables

# Create tayga data directory
RUN mkdir -p /var/db/tayga

# Create tayga configuration file
ADD tayga.conf /etc/tayga.conf
ADD start-nat64.sh /bin/start-nat64.sh
ADD configure-nat64-router.sh /bin/configure-nat64-router.sh
ADD nat64-status.sh /bin/nat64-status.sh

# Make all scripts executable
RUN chmod +x /bin/start-nat64.sh \
             /bin/configure-nat64-router.sh \
             /bin/nat64-status.sh

