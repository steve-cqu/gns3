# Dockerfile for the IPsec Gateway node (cqugns3/strongswan).
#
# A Linux IPsec gateway for the CLI half of the VPN material: two of these, a swanctl.conf on
# each, and an IKEv2 tunnel between them. It exists to replace the two Qemu OPNsense firewalls
# in `ipsec-site-to-site` with something that runs on a laptop with no nested virtualisation —
# see gns3-dev/notes/opnsense-replacement.md.
#
# DERIVED FROM alpinenode, deliberately, following ipv6node/servicenode/monitornode. That
# inherits every diagnostic the VPN activities already use (ip, ping, tcpdump, nano) instead of
# re-adding them, while keeping strongSwan off every *other* node in the appliance — which is
# what adding the package to alpinenode itself would have done, at the cost of a --force rebuild
# of the three images that derive from it.
#
# ORDER MATTERS in manifest.yml's per-platform `docker:` list: this must appear AFTER alpinenode
# or there is no base to build on.
FROM cqugns3/alpinenode

# One package, no new dependencies — strongSwan's openssl backing is already in the base image.
# strongSwan 6.0 removed the legacy `ipsec`/`starter` stack, so swanctl + vici is the only
# interface, which is exactly what the material teaches.
RUN apk add --no-cache strongswan

# Helper scripts go in /usr/local/bin, not /bin, so a student's edit survives a project being
# closed: the template persists /usr/local/bin, and /bin cannot be persisted without pinning the
# whole userland. /usr/local/bin precedes /bin in the default PATH, so they still run by bare
# name exactly as the activities say. (Same reasoning as ipv6node's scripts.)
COPY start-ipsec.sh   /usr/local/bin/start-ipsec.sh
COPY ipsec-status.sh  /usr/local/bin/ipsec-status.sh
RUN chmod +x /usr/local/bin/start-ipsec.sh /usr/local/bin/ipsec-status.sh

# The package's own /etc/swanctl/swanctl.conf is 588 lines of commented reference with exactly
# ONE active line in it (`include conf.d/*.conf`). That is genuinely useful material — every
# setting with its default — but it is the wrong thing to open in nano when the task is "write a
# tunnel into this file": a student scrolls 588 lines to find somewhere to type. Found by walking
# the activity on a live node, 18 Aug 2026.
#
# So the reference is kept, under a name that says what it is, and the file students actually
# edit is a short skeleton with the two sections they have to fill in and the one-setting-per-line
# trap stated at the top.
RUN mv /etc/swanctl/swanctl.conf /etc/swanctl/swanctl.conf.reference
COPY swanctl.conf /etc/swanctl/swanctl.conf
