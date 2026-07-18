# FRR router node (Docker replacement for the FRR Qemu VM)
# Used on Apple Mac builds where no arm64 Qemu image of FRR exists.
# Debian bookworm ships FRR 8.4, close to the 8.2.2 Qemu VM so vtysh usage is the same.
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    frr \
    iproute2 \
    iputils-ping \
    tcpdump \
    procps \
    nano \
    && rm -rf /var/lib/apt/lists/*

# Enable the routing daemons used in activities (zebra and staticd always run)
RUN sed -i \
    -e 's/^ospfd=no/ospfd=yes/' \
    -e 's/^ospf6d=no/ospf6d=yes/' \
    -e 's/^bgpd=no/bgpd=yes/' \
    -e 's/^ripd=no/ripd=yes/' \
    /etc/frr/daemons

ADD start-frr.sh /bin/start-frr.sh
RUN chmod +x /bin/start-frr.sh

# Persist router configuration within a GNS3 project
VOLUME /etc/frr

CMD [ "/bin/start-frr.sh" ]
