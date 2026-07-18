# NETem network emulator node (Docker replacement for the NETem Qemu VM)
# Used on Apple Mac builds where no arm64 Qemu image of NETem exists.
# Transparently bridges eth0 <-> eth1 and applies tc/netem (delay, jitter, loss, rate)
# via a simple console menu.
# Note: requires the sch_netem kernel module on the GNS3 VM host
# (loaded by vm-install-nodes.sh).
FROM alpine:latest

RUN apk add --no-cache \
    bash \
    iproute2 \
    iproute2-tc

ADD start-netem.sh /bin/start-netem.sh
ADD netem-menu.sh /bin/netem-menu.sh
RUN chmod +x /bin/start-netem.sh /bin/netem-menu.sh

CMD [ "/bin/start-netem.sh" ]
