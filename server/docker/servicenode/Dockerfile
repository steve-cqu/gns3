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

# ---------------------------------------------------------------------------------------------
# RADIUS Server (FreeRADIUS) — network access control, Design 1 (added 11 October 2026).
#
# The AAA server behind wired 802.1X and WPA2-Enterprise. It joins servicenode because it drags
# in no new runtime: FreeRADIUS is C, and the whole group below measured 12.4 MB on the v044
# appliance, taking servicenode from 120 to ~133 MB over alpinenode (decision D2's budget is 150).
# Design and spikes: gns3-dev/notes/nac-8021x-radius.md.
#
#   freeradius, freeradius-eap  - the server and its EAP methods (PEAP, TTLS, TLS). Alpine has
#                                 3.0.27, not 3.2; everything the labs need is in 3.0.
#   freeradius-utils            - radtest/radclient, so the node can test itself and a second
#                                 RADIUS Server node can act as the NAS in a RADIUS-only lab.
#   wpa_supplicant              - for /sbin/eapol_test, which Alpine ships in this package: an
#                                 EAP client (PEAP, TTLS, EAP-TLS) that needs no switch or radio.
#   make                        - the certs/ Makefile, below and for students who regenerate.
RUN apk add --no-cache \
    freeradius freeradius-eap freeradius-utils \
    wpa_supplicant \
    make

# The lab CA and server certificate, generated at BUILD time with FreeRADIUS's own certs/
# Makefile. Alpine does not run it at install, so without this step there are no certificates and
# every EAP method fails. The .cnf files are edited first: the stock subject is "Example Inc." in
# France, and the stock lifetime is 60 days, which would expire mid-term. Five years outlives any
# appliance. The server certificate also gets a subjectAltName, which upstream's xpserver_ext
# leaves out: modern supplicants (Android, Windows 11, wpa_supplicant's domain_match) check the
# server's name there, and Design 3's evil-twin lesson depends on that check. The CA's private
# key ships too — this is a lab CA, and students issuing their own client certificate
# (`make client`) is part of the EAP-TLS lesson. A fresh build makes a fresh CA, so a client's
# copy of ca.pem belongs to the node it was copied from.
RUN cd /etc/raddb/certs \
 && for f in ca.cnf server.cnf client.cnf; do \
      sed -i -E \
        -e 's/^(default_days[[:space:]]*=).*/\1 1825/' \
        -e 's/^(countryName[[:space:]]*=)[[:space:]]*FR$/\1 AU/' \
        -e 's/^(stateOrProvinceName[[:space:]]*=)[[:space:]]*Radius$/\1 Queensland/' \
        -e 's/^(localityName[[:space:]]*=)[[:space:]]*Somewhere$/\1 Rockhampton/' \
        -e 's/^(organizationName[[:space:]]*=)[[:space:]]*Example Inc\.$/\1 CQU GNS3 Lab/' \
        -e 's/admin@example\.org/admin@lab.example/' \
        -e 's/user@example\.org/student@lab.example/g' \
        -e 's/"Example Certificate Authority"/"CQU GNS3 Lab CA"/' \
        -e 's/"Example Server Certificate"/"radius.lab.example"/' \
        -e 's/radius\.example\.com/radius.lab.example/' \
        -e 's/\*\.example\.com/*.lab.example/' \
        -e 's#http://www\.example\.org/example_ca\.crl#http://ca.lab.example/ca.crl#' \
        "$f"; \
    done \
 && sed -i \
      -e 's#http://www\.example\.com/example_ca\.crl#http://ca.lab.example/ca.crl#' \
      -e '/^\[ *xpserver_ext *\]/a subjectAltName = DNS:radius.lab.example' \
      xpextensions \
 && grep -q '^subjectAltName = DNS:radius.lab.example$' xpextensions \
 && ! grep -qE 'Example Inc|= FR$|example\.(com|org)|= 60$' ca.cnf server.cnf client.cnf xpextensions \
 && if ! make all >/tmp/certs-make.log 2>&1; then cat /tmp/certs-make.log; exit 1; fi \
 && openssl verify -CAfile ca.pem server.pem client.pem \
 && chown -R root:radius /etc/raddb/certs \
 && chmod 640 /etc/raddb/certs/*.key /etc/raddb/certs/*.pem /etc/raddb/certs/*.p12 \
 && chmod 644 /etc/raddb/certs/ca.pem /etc/raddb/certs/ca.der \
 && rm -f /tmp/certs-make.log

# The lab configuration, layered onto FreeRADIUS's stock files rather than replacing them, so the
# hundreds of lines of upstream comments stay where students and the documentation expect them.
# Every edit is checked with grep afterwards: a sed that silently matches nothing would ship a
# server without the fix and no build error to say so.
#
#   clients.conf  - the lab-nas client (192.168.1.0/24) appended; sw1 for Design 2, commented.
#   users         - three lab users with VLANs (10 Staff, 20 Student, 50 Guest) put FIRST,
#                   since the file is first-match.
#   eap           - use_tunneled_reply = yes in BOTH peap {} and ttls {}. With PEAP the VLAN is
#                   set inside the tunnel, and without this the outer Access-Accept leaves it out
#                   (measured 7 Oct 2026: 174 bytes without, 190 with). It also copies the real
#                   user name out of the tunnel, which is what lets a switch see "fariza" behind
#                   the anonymous outer identity. Both sections, so TTLS behaves the same.
#   policy.d/nac  - the Authorize-Only VLAN lookup the Design 2 switch makes, called first in
#                   authorize {}. It does nothing to an ordinary request.
#   radiusd.conf  - auth = yes, so radius.log records "Login OK" / "Login incorrect" per
#                   request. auth_badpass/auth_goodpass stay off: they would log passwords.
COPY radius-clients.conf /tmp/radius-clients.conf
COPY radius-users        /tmp/radius-users
COPY radius-nac-policy   /etc/raddb/policy.d/nac
RUN cd /etc/raddb \
 && cat /tmp/radius-clients.conf >> clients.conf \
 && cat /tmp/radius-users mods-config/files/authorize > /tmp/authorize \
 && cat /tmp/authorize > mods-config/files/authorize \
 && rm /tmp/radius-clients.conf /tmp/radius-users /tmp/authorize \
 && sed -i -E 's/^([[:space:]]*use_tunneled_reply[[:space:]]*=)[[:space:]]*no$/\1 yes/' mods-available/eap \
 && [ "$(grep -cE '^[[:space:]]*use_tunneled_reply = yes$' mods-available/eap)" = 2 ] \
 && awk '!done && /^authorize \{/ { print; \
          print "\t#  The 802.1X lab switch'"'"'s VLAN lookup (policy.d/nac). Does nothing unless the"; \
          print "\t#  request carries Service-Type = Authorize-Only."; \
          print "\tnac_authorize_only"; print ""; done=1; next } { print }' \
        sites-available/default > /tmp/default \
 && cat /tmp/default > sites-available/default && rm /tmp/default \
 && grep -q '^	nac_authorize_only$' sites-available/default \
 && sed -i -E 's/^([[:space:]]*auth[[:space:]]*=)[[:space:]]*no$/\1 yes/' radiusd.conf \
 && grep -qE '^[[:space:]]*auth = yes$' radiusd.conf \
 && chown root:radius clients.conf mods-config/files/authorize policy.d/nac \
 && chmod 640 clients.conf mods-config/files/authorize policy.d/nac \
 && mkdir -p /var/log/radius/radacct /run/radiusd \
 && chown -R radius:radius /var/log/radius /run/radiusd \
 && radiusd -C >/dev/null

COPY start-radius.sh   /usr/local/bin/start-radius.sh
COPY radius-status.sh  /usr/local/bin/radius-status.sh
RUN chmod +x /usr/local/bin/start-radius.sh /usr/local/bin/radius-status.sh

# ---------------------------------------------------------------------------------------------
# 802.1X Switch — network access control, Design 2 (added 11 October 2026).
#
# A wired access switch whose ports stay shut until a user logs in with 802.1X. It joins
# servicenode because everything it needs is already here except hostapd (~1 MB): the bridge and
# VLAN tools, nftables for the port gate, and radclient for the VLAN lookup. Design and the spikes
# that proved it on this kernel: gns3-dev/notes/nac-8021x-radius.md §4 and §6.
#
#   hostapd  - the 802.1X authenticator (driver=wired), one config per access port.
RUN apk add --no-cache hostapd \
 && mkdir -p /etc/nac /var/log/nac /run/hostapd

COPY 8021x-switch.conf       /etc/nac/switch.conf
COPY start-8021x-switch.sh   /usr/local/bin/start-8021x-switch.sh
COPY nac-port-action.sh      /usr/local/bin/nac-port-action.sh
COPY 8021x-status.sh         /usr/local/bin/8021x-status.sh
RUN chmod +x /usr/local/bin/start-8021x-switch.sh /usr/local/bin/nac-port-action.sh \
             /usr/local/bin/8021x-status.sh

# Declared here as well as in the templates' extra_volumes, so a node keeps its zone files, its
# database, its leases, its captured flows, its shared files and its RADIUS configuration and
# accounting records even under a template someone registered by hand.
VOLUME /var/bind /etc/bind /etc/chrony /var/lib/postgresql /var/lib/valkey /var/lib/kea /var/flows /srv /etc/raddb /var/log/radius
