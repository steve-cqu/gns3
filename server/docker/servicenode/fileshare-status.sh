#!/bin/bash
# What is this Samba file server doing?
# Usage: fileshare-status.sh

CONF=/etc/samba/smb.conf

echo "================================================"
echo "Samba File Server Status"
echo "================================================"
echo ""

echo "1. Server process (smbd):"
if pgrep -x smbd >/dev/null 2>&1; then
    pgrep -a smbd | sed 's/^/   /'
else
    echo "   smbd is NOT running — start it with start-fileserver.sh"
fi
echo ""

echo "2. This node's addresses (what clients should point at):"
ip -4 addr show | grep -E 'inet ' | grep -v '127.0.0.1' | sed 's/^/   /' || echo "   no IPv4 address configured"
echo ""

echo "3. Shares offered:"
testparm -s "$CONF" 2>/dev/null | grep -E '^\[|path =|guest ok|read only|valid users' | sed 's/^/   /'
echo ""

echo "4. Samba users registered (own password db, separate from Linux):"
pdbedit -L 2>/dev/null | sed 's/^/   /' || echo "   none"
echo ""

echo "5. Connected clients / open sessions:"
smbstatus -b 2>/dev/null | sed 's/^/   /' || echo "   (smbstatus unavailable)"
echo ""

echo "6. What is in each share:"
echo "   /srv/public:";  ls -la /srv/public  2>/dev/null | sed 's/^/     /'
echo "   /srv/private:"; ls -la /srv/private 2>/dev/null | sed 's/^/     /'
echo ""

echo "================================================"
echo "Config:   $CONF"
echo "Logs:     /var/log/samba/"
echo "Shares:   /srv/public (guest), /srv/private (user student)"
echo "================================================"
