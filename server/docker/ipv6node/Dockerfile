# Dockerfile for NAT64 Router
FROM cqugns3/alpinenode

# Install required packages
RUN apk update && \
    apk add --no-cache \
    tayga \
    iptables \
    ip6tables

# Create tayga data directory
RUN mkdir -p /var/db/tayga

# Create tayga configuration file
ADD tayga.conf /etc/tayga.conf
ADD start-nat64.sh /bin/start-nat64.sh
ADD configure-nat64-router.sh /bin/configure-nat64-router.sh
ADD setup-nat64.sh /bin/setup-nat64.sh
ADD nat64-status.sh /bin/nat64-status.sh
ADD nat64-welcome.sh /etc/profile.d/nat64-welcome.sh

# Make all scripts executable
RUN chmod +x /bin/start-nat64.sh \
             /bin/configure-nat64-router.sh \
             /bin/setup-nat64.sh \
             /bin/nat64-status.sh \
             /etc/profile.d/nat64-welcome.sh

# Set bash as default shell for better script support
#ENV SHELL=/bin/bash

# Default command
#CMD ["/bin/bash"]