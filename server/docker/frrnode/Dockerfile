# FRR router node (Docker replacement for the FRR Qemu VM)
# Used on Apple Mac builds where no arm64 Qemu image of FRR exists.
# Debian bookworm ships FRR 8.4, close to the 8.2.2 Qemu VM so vtysh usage is the same.
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    frr \
    iproute2 \
    ifupdown \
    iputils-ping \
    tcpdump \
    procps \
    nano \
    && rm -rf /var/lib/apt/lists/*
# ifupdown provides ifup/ifdown and /etc/init.d/networking so the activities'
# "edit /etc/network/interfaces then restart networking" step works (Debian
# bookworm-slim has no networking tooling by default; Alpine nodes get it from
# BusyBox). GNS3 applies the interfaces file at container start; ifupdown lets a
# student re-apply edits at runtime without restarting the node.

# Pre-enable only the OSPF daemons (zebra and staticd always run). ospf-basics ships a
# preconfigured OSPF topology, so ospfd/ospf6d must be on out of the box. bgpd is deliberately
# left DISABLED: bgp-basics is a build-it-yourself lab where turning the BGP daemon on
# (bgpd=yes in /etc/frr/daemons, then restart FRR) is an explicit student step. No activity
# uses RIP, so ripd stays off as well; a future activity can enable it the same way as bgpd.
RUN sed -i \
    -e 's/^ospfd=no/ospfd=yes/' \
    -e 's/^ospf6d=no/ospf6d=yes/' \
    /etc/frr/daemons

# Use split per-daemon config files (ospfd.conf, bgpd.conf, …) like the FRR Qemu VM
# and the activities, instead of Debian's default integrated /etc/frr/frr.conf.
RUN echo 'no service integrated-vtysh-config' > /etc/frr/vtysh.conf \
    && chown frr:frr /etc/frr/vtysh.conf

ADD start-frr.sh /bin/start-frr.sh
RUN chmod +x /bin/start-frr.sh

# Persist router configuration within a GNS3 project
VOLUME /etc/frr

CMD [ "/bin/start-frr.sh" ]
