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
COPY tayga.conf /etc/tayga.conf

# The helper scripts live in /usr/local/bin, not /bin, so that an edit to them survives a
# project being closed: the NAT64Router template persists /usr/local/bin, and /bin cannot be
# persisted without pinning the whole userland. The ipv6-basics instructions tell students to
# edit configure-nat64-router.sh when they use different addresses, and that edit was lost on
# every reopen while these sat in /bin. /usr/local/bin precedes /bin in the default PATH, so
# they are still run by bare name exactly as the activities say.
COPY start-nat64.sh            /usr/local/bin/start-nat64.sh
COPY configure-nat64-router.sh /usr/local/bin/configure-nat64-router.sh
COPY nat64-status.sh           /usr/local/bin/nat64-status.sh

# Make all scripts executable
RUN chmod +x /usr/local/bin/start-nat64.sh \
             /usr/local/bin/configure-nat64-router.sh \
             /usr/local/bin/nat64-status.sh

