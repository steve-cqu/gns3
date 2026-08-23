# Samba Active Directory Domain Controller — the "Domain Controller" template.
#
# The middle rung of the identity ladder: `auth-kerberos` teaches Kerberos as a protocol (an MIT
# KDC, principals typed by hand, a keytab copied between hosts), and this node is what a real
# organisation runs instead — Kerberos, LDAP and DNS as one domain, with users and groups that
# other machines can join and log in against. See gns3-dev/notes/directory-ad-dc-plan.md.
#
# Its OWN image, not a servicenode template: samba-dc drags in the whole Samba library set, ldb,
# winbind and py3-dnspython, which is exactly decision D2's "a runtime the others do not need".
# Derived from cqugns3/alpinenode so a console on it behaves like every other node (nano, dig,
# curl and the student account are all already there).
FROM cqugns3/alpinenode

# samba-dc          - the AD DC itself: /usr/sbin/samba (the one daemon that runs the whole DC),
#                     samba-tool, the ldb modules and the samba4 auth module. Alpine builds Samba
#                     --with-ads against its BUNDLED HEIMDAL, which is what makes the AD DC work
#                     at all; the APKBUILD says so in a comment ("heimdal is required (over mit
#                     krb5) for AD DC functionality"). This is why the node exists on Alpine.
# krb5              - MIT kinit/klist, so a student can get and read a ticket ON the DC. Samba's
#                     Heimdal is private to Samba and ships no kinit; the two coexist because
#                     they only ever share /etc/krb5.conf, which provisioning writes.
# openldap-clients  - ldapsearch, so the directory can be read as a directory rather than only
#                     through samba-tool. Task 5 of directory-ad-basics is entirely this.
#
# bind-tools (host, dig) already comes from alpinenode, which matters more here than usual: an AD
# domain IS a set of DNS SRV records, and `host -t SRV _ldap._tcp.<realm>` is how a student proves
# the domain is really up.
RUN apk add --no-cache \
    samba-dc \
    krb5 \
    openldap-clients

# The packaged smb.conf is moved aside, NOT deleted.
#
# `samba-tool domain provision` writes its own smb.conf, and refuses to run when one is already
# there — Alpine's samba package installs examples/smb.conf.default to /etc/samba/smb.conf, so a
# student's very first provisioning command would fail on a file they never created and cannot see
# the point of. Moving it keeps the file for reference (it is a good annotated example of the
# file-server side of Samba, which this node deliberately does not teach) and lets provisioning
# work first time.
RUN if [ -f /etc/samba/smb.conf ]; then mv /etc/samba/smb.conf /etc/samba/smb.conf.packaged; fi \
 && mkdir -p /var/lib/samba/private /var/log/samba /run/samba

# Helper scripts in /usr/local/bin (persisted, and ahead of /bin in PATH) so edits survive a
# project close — the lesson recorded in ipv6node's Dockerfile.
COPY start-samba-dc.sh   /usr/local/bin/start-samba-dc.sh
COPY samba-dc-status.sh  /usr/local/bin/samba-dc-status.sh
RUN chmod +x /usr/local/bin/start-samba-dc.sh /usr/local/bin/samba-dc-status.sh

# The image ships NO domain. Provisioning is the lesson — a pre-provisioned domain would hand the
# student the one command the activity is about, and would bake this image's hostname and realm
# into every project built on it.
#
# The directory itself lives in /var/lib/samba (sam.ldb, the private keytab, the DNS zones) and
# the configuration provisioning writes lands in /etc/samba. Both persist, so a student's domain,
# users and groups survive the project being closed — which directory-ad-basics Task 7 asks them
# to prove.
VOLUME /var/lib/samba /etc/samba
