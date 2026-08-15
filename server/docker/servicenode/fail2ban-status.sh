#!/bin/bash
# What has fail2ban banned, and is the ban real in the firewall?
# Usage: fail2ban-status.sh

echo "================================================"
echo "fail2ban Status"
echo "================================================"
echo ""

echo "1. Daemon:"
if fail2ban-client status >/dev/null 2>&1; then
    fail2ban-client status | sed 's/^/   /'
else
    echo "   fail2ban is NOT running — start it with start-fail2ban.sh"
    exit 0
fi
echo ""

echo "2. sshd jail — failures seen and addresses banned:"
fail2ban-client status sshd 2>/dev/null | sed 's/^/   /' || echo "   sshd jail not active"
echo ""

echo "3. Is the ban real? The rule fail2ban inserted into the firewall:"
echo "   (this is the point — a ban you can see enforced, not just logged)"
nft list ruleset 2>/dev/null | grep -iA2 f2b | sed 's/^/   /' \
  || iptables -S 2>/dev/null | grep -i f2b | sed 's/^/   /' \
  || echo "   no firewall rules found (check banaction in jail.local)"
echo ""

echo "4. Recent ban/unban activity:"
grep -E 'Ban|Unban' /var/log/fail2ban.log 2>/dev/null | tail -n 8 | sed 's/^/   /' || echo "   nothing yet"
echo ""

echo "================================================"
echo "Config:    /etc/fail2ban/jail.local"
echo "Log file:  /var/log/fail2ban.log"
echo "================================================"
