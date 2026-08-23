#!/bin/sh
# What is this domain controller doing?
# Usage: samba-dc-status.sh
#
# Written to answer, in order, the four questions a stuck student actually has: is there a domain,
# is it running, does DNS answer for it, and does Kerberos issue a ticket. Both activities send
# students here from their troubleshooting section, so every line is meant to be readable without
# knowing Samba.

PRIVATE=/var/lib/samba/private
SMBCONF=/etc/samba/smb.conf

echo "================================================"
echo "Active Directory Domain Controller Status"
echo "================================================"
echo ""

echo "1. Is there a domain on this node?"
if [ -f "$PRIVATE/sam.ldb" ]; then
    REALM=$(grep -i '^\s*realm' "$SMBCONF" 2>/dev/null | head -1 | sed 's/.*=\s*//')
    DOMAIN=$(grep -i '^\s*workgroup' "$SMBCONF" 2>/dev/null | head -1 | sed 's/.*=\s*//')
    echo "   yes — realm ${REALM:-?}, NetBIOS domain ${DOMAIN:-?}"
else
    echo "   NO — this node has not been provisioned yet (no $PRIVATE/sam.ldb)."
    echo "   Everything below will fail until it is."
fi
echo ""

echo "2. Is the daemon running?"
if pgrep -x samba >/dev/null 2>&1; then
    echo "   yes — $(pgrep -x samba | wc -l) samba process(es)"
else
    echo "   NO — start it with start-samba-dc.sh"
fi
echo ""

echo "3. This node's addresses (what clients must use as their DNS server):"
ip -4 addr show | grep -E 'inet ' | grep -v '127.0.0.1' | sed 's/^/   /' \
    || echo "   no IPv4 address configured"
echo ""

echo "4. Does the domain answer over LDAP?"
if nc -z 127.0.0.1 389 2>/dev/null; then
    echo "   yes — port 389 is open"
    samba-tool user list 2>/dev/null | sed 's/^/   user: /' || echo "   (samba-tool user list failed)"
else
    echo "   NO — nothing is listening on port 389"
fi
echo ""

echo "5. Do the domain's DNS records resolve? (this is what clients look up to find a DC)"
REALM=$(grep -i '^\s*realm' "$SMBCONF" 2>/dev/null | head -1 | sed 's/.*=\s*//' | tr 'A-Z' 'a-z')
if [ -n "$REALM" ]; then
    host -t SRV "_ldap._tcp.$REALM" 127.0.0.1 2>&1 | sed 's/^/   /'
    host -t SRV "_kerberos._udp.$REALM" 127.0.0.1 2>&1 | sed 's/^/   /'
else
    echo "   (no realm in $SMBCONF — is the domain provisioned?)"
fi
echo ""

echo "6. Is /etc/krb5.conf pointing at the realm configuration?"
if [ -L /etc/krb5.conf ]; then
    echo "   yes — $(readlink /etc/krb5.conf)"
elif [ -f /etc/krb5.conf ]; then
    echo "   a plain file, not the provisioned one — start-samba-dc.sh re-links it"
else
    echo "   MISSING — kinit will not find the realm. Run start-samba-dc.sh"
fi
echo ""

echo "================================================"
echo "Config:    $SMBCONF"
echo "Directory: $PRIVATE/sam.ldb   (persisted, with /etc/samba)"
echo "Log:       /var/log/samba/log.samba"
echo "================================================"
