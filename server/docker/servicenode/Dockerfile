# Network services node: DNS (BIND) and NTP (chrony).
#
# Derived from cqugns3/alpinenode rather than alpine:3.24 so a service node behaves like every
# other node when a student opens a console on it — dig, curl, vim, nano and the student
# account are all already there. The base layers are shared, so this costs ~1 MB on disk.
#
# One image, two templates (DNS Server, NTP Server). A service gets its own *template* when it
# occupies its own box on the topology diagram; it gets its own *image* only when it drags in a
# runtime the others do not need. BIND is 600 KB and chrony 390 KB, so splitting the image would
# buy nothing. The same image also serves a small-office activity where one box runs both.
# See gns3-dev/notes/tier1-service-nodes-plan.md, decision D2.
FROM cqugns3/alpinenode

# bind  - authoritative AND recursive in one daemon, which is what lets a topology hold a
#         delegating parent, an authoritative child and a resolver whose cache can be poisoned.
#         dnsmasq (what OpenWRT gives) cannot teach a zone file; unbound resolves well but
#         cannot be authoritative.
#
# chrony and libfaketime are NOT installed here — they come from the base image, so that every
# Linux Host can act as an NTP client and every node can run `faketime`. This node adds only
# the server-side chrony.conf below.
#
# On clocks: a container shares the host kernel's clock. `date -s` inside a GNS3 Docker node
# cannot set a per-node time, and chronyd on a client cannot step it either. So the NTP client
# side is measurement (`chronyd -Q`, `chronyc -h <server>`) rather than correction, and a skewed
# clock is simulated per-process with faketime. This is a real limit of container nodes, not a
# shortcut — it is written into the activities so nobody debugs a step that cannot work.
RUN apk add --no-cache \
    bind

# Runtime directories and service accounts.
#
# named drops privileges to the `named` user (start-dns.sh passes -u named) and chronyd does
# the same, so both accounts have to exist and own their data. The packages normally create
# them, but that happens in an install script rather than in the file list, so the guards below
# make the build work either way instead of failing on a chown for a user that is not there.
RUN mkdir -p /var/bind/pri /var/bind/sec /var/bind/dyn /run/named /var/log/named \
             /var/lib/chrony /run/chrony \
 && if ! grep -q '^named:'  /etc/group;  then addgroup -S named;  fi \
 && if ! grep -q '^named:'  /etc/passwd; then adduser -S -D -H -G named named;   fi \
 && if ! grep -q '^chrony:' /etc/group;  then addgroup -S chrony; fi \
 && if ! grep -q '^chrony:' /etc/passwd; then adduser -S -D -H -G chrony chrony; fi \
 && chown -R named:named   /var/bind /run/named /var/log/named \
 && chown -R chrony:chrony /var/lib/chrony /run/chrony

# Shipped configuration. Both are heavily commented and are meant to be edited: the config IS
# the lesson. They are also valid as they stand — `named-checkconf` passes and BIND answers for
# example.com with no student edits at all, the same standard as the empty custom.rules that
# makes `suricata -T` pass on the IDS node.
COPY named.conf         /etc/bind/named.conf
COPY example.com.zone   /var/bind/pri/example.com.zone
COPY 192.168.1.rev      /var/bind/pri/192.168.1.rev
COPY chrony.conf        /etc/chrony/chrony.conf
RUN chown named:named /var/bind/pri/example.com.zone /var/bind/pri/192.168.1.rev

# Helper scripts live in /usr/local/bin, not /bin, so a student's edit survives the project
# being closed: /usr/local/bin can be persisted, /bin cannot without pinning the whole
# userland, and it precedes /bin in PATH so they still run by bare name. This is the lesson
# recorded in ipv6node's Dockerfile.
COPY start-dns.sh    /usr/local/bin/start-dns.sh
COPY start-ntp.sh    /usr/local/bin/start-ntp.sh
COPY dns-status.sh   /usr/local/bin/dns-status.sh
COPY ntp-status.sh   /usr/local/bin/ntp-status.sh
RUN chmod +x /usr/local/bin/start-dns.sh /usr/local/bin/start-ntp.sh \
             /usr/local/bin/dns-status.sh /usr/local/bin/ntp-status.sh

# Declared here as well as in the templates' extra_volumes, so a node keeps its zone files and
# its config even under a template someone registered by hand.
VOLUME /var/bind /etc/bind /etc/chrony
