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
 && chown -R chrony:chrony /var/lib/chrony /run/chrony \
 # 0750 on /run/chrony, and it is not cosmetic. chronyd checks that directory before it will
 # create its command socket, and at the default 0755 it refuses:
 #     Wrong permissions on /run/chrony
 #     Disabled command socket /run/chrony/chronyd.sock
 # Without the socket, `chronyc clients` and `chronyc serverstats` answer "501 Not authorised"
 # even for root on the server itself — those two commands are authorised only over the socket,
 # never over the network, however generous cmdallow is. `chronyc clients` is a documented step
 # in ntp-basics (instructions Task 5, solution Task 6), so this broke a student step while
 # `chronyc tracking` kept working, which is why it survived the first build.
 # Measured on the appliance 15 August 2026 (chrony 4.8); one chmod fixes it.
 && chmod 750 /run/chrony

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

# ---------------------------------------------------------------------------------------------
# Tier 5 services and operations tooling (added 15 August 2026).
#
# Live-verified on the appliance before building — all of these install from Alpine v3.24 for both
# architectures and run without systemd; see gns3-dev/notes/tier5-and-spike-designs.md. They join
# servicenode rather than getting their own images because none drags in a runtime the node does
# not already have (python3 and openssh come from alpinenode), and the whole group stays well under
# decision D2's 150 MB-over-alpinenode budget.
#
#   postgresql / valkey / kea-dhcp4  - the three "own box" data services, each with its own
#                                      template below. PostgreSQL is the first stateful node.
#   nfdump / fprobe                  - NetFlow collection and probing: the flow view of a network,
#                                      the third telemetry modality beside packet capture and IDS.
#                                      fprobe, not softflowd: softflowd 1.1.0 receives packets via
#                                      libpcap but processes 0 of them inside a GNS3 container, so it
#                                      exports nothing; fprobe builds flows correctly in the same
#                                      container and is packaged for both arches. Verified live
#                                      15 Aug 2026 — see gns3-dev/notes/tier5-and-spike-designs.md.
#   fail2ban + nftables              - auto-ban brute-force sources; the "respond" half of
#                                      detect-and-respond, protecting the sshd every node runs.
#   monit / goaccess                 - cheap operations tools (service supervision, web-log
#                                      analysis) available on any service node; no template needed.
RUN apk add --no-cache \
    postgresql17 postgresql17-client postgresql17-contrib pgbackrest \
    valkey valkey-cli \
    kea-dhcp4 kea-admin \
    nfdump fprobe \
    fail2ban nftables \
    monit goaccess

# Runtime directories and ownership. The service accounts (postgres, valkey, kea) are created by
# their packages; the guards make the build work either way rather than failing on a chown for a
# user that is not there — the same pattern as named/chrony above. The data directories are the
# ones the templates persist, so a student's database, leases and captured flows survive a project
# being closed.
RUN mkdir -p /var/lib/postgresql/data /run/postgresql \
             /var/lib/valkey /var/log/valkey \
             /var/lib/kea /var/log/kea \
             /var/flows \
             /var/lib/fail2ban \
 && if grep -q '^postgres:' /etc/passwd; then chown -R postgres:postgres /var/lib/postgresql /run/postgresql; fi \
 && if grep -q '^valkey:'   /etc/passwd; then chown -R valkey:valkey     /var/lib/valkey /var/log/valkey; fi \
 && if grep -q '^kea:'      /etc/passwd; then chown -R kea:kea           /var/lib/kea /var/log/kea; fi

# File Server (Samba) — the "File Server" template. samba is the SMB/CIFS server (smbd); the client
# tools (smbclient, mount.cifs) are on alpinenode so any Linux Host can be a client. mount.cifs on
# the client needs the `cifs` kernel module on the VM host (kernel_modules in manifest.yml).
# ~25 MB, keeping servicenode well under decision D2's 150 MB-over-alpinenode budget. See
# gns3-dev/notes/tier2-file-backup-git.md, Module 1.
RUN apk add --no-cache \
    samba \
    samba-common-tools
RUN mkdir -p /srv/public /srv/private /var/lib/samba/private /run/samba /var/log/samba \
 && if id student >/dev/null 2>&1; then chown student /srv/private; fi

# Backup tooling for the backup-basics activity (Tier 2 Module 2). rsync is already on alpinenode;
# restic adds versioned, deduplicated, encrypted snapshots — the modern backup story — in one ~25 MB
# static binary. No new node: a servicenode node with data backs itself up, and the backup target is
# Module 1's File Server share. See gns3-dev/notes/tier2-file-backup-git.md, Module 2.
RUN apk add --no-cache restic

# Shipped configuration — valid as it stands and meant to be edited; the config is the lesson, the
# same standard as named.conf above. valkey.conf ships deliberately exposed (the teaching example);
# kea-dhcp4.conf ships as a working single-subnet server; jail.local enables the sshd jail; smb.conf
# ships two shares (public/guest and private/user) for the access-control lesson.
COPY valkey.conf      /etc/valkey/valkey.conf
COPY kea-dhcp4.conf   /etc/kea/kea-dhcp4.conf
COPY jail.local       /etc/fail2ban/jail.local
COPY smb.conf         /etc/samba/smb.conf

# Helper scripts in /usr/local/bin (persisted, and ahead of /bin in PATH) so a student's edits
# survive a project close — the lesson recorded in ipv6node's Dockerfile.
COPY start-db.sh         /usr/local/bin/start-db.sh
COPY db-status.sh        /usr/local/bin/db-status.sh
COPY start-cache.sh      /usr/local/bin/start-cache.sh
COPY cache-status.sh     /usr/local/bin/cache-status.sh
COPY start-dhcp.sh       /usr/local/bin/start-dhcp.sh
COPY dhcp-status.sh      /usr/local/bin/dhcp-status.sh
COPY start-flow.sh       /usr/local/bin/start-flow.sh
COPY flow-status.sh      /usr/local/bin/flow-status.sh
COPY start-flowprobe.sh  /usr/local/bin/start-flowprobe.sh
COPY start-fail2ban.sh   /usr/local/bin/start-fail2ban.sh
COPY fail2ban-status.sh  /usr/local/bin/fail2ban-status.sh
COPY start-fileserver.sh /usr/local/bin/start-fileserver.sh
COPY fileshare-status.sh /usr/local/bin/fileshare-status.sh
RUN chmod +x /usr/local/bin/start-db.sh /usr/local/bin/db-status.sh \
             /usr/local/bin/start-cache.sh /usr/local/bin/cache-status.sh \
             /usr/local/bin/start-dhcp.sh /usr/local/bin/dhcp-status.sh \
             /usr/local/bin/start-flow.sh /usr/local/bin/flow-status.sh \
             /usr/local/bin/start-flowprobe.sh \
             /usr/local/bin/start-fail2ban.sh /usr/local/bin/fail2ban-status.sh \
             /usr/local/bin/start-fileserver.sh /usr/local/bin/fileshare-status.sh

# Declared here as well as in the templates' extra_volumes, so a node keeps its zone files, its
# database, its leases, its captured flows and its shared files even under a template someone
# registered by hand.
VOLUME /var/bind /etc/bind /etc/chrony /var/lib/postgresql /var/lib/valkey /var/lib/kea /var/flows /srv
