#!/bin/bash
# Start fail2ban on this node to auto-ban SSH brute-force sources.
# Usage: start-fail2ban.sh
#
# fail2ban watches the auth log and, after too many failures from one address, tells the firewall
# to drop it for `bantime` (see /etc/fail2ban/jail.local). This node runs the SSH server every CQU
# node runs, so it makes a ready-made target: run a brute force at it from Kali and watch the ban
# appear, then expire.

# The auth log fail2ban watches has to exist, or the jail starts but never sees a failure. On these
# nodes OpenSSH logs via syslog; make sure something is collecting it.
if ! pgrep -x syslogd >/dev/null 2>&1; then
    echo "Starting syslogd so SSH failures are logged to /var/log/messages ..."
    syslogd
    sleep 1
fi
touch /var/log/messages

echo "Checking fail2ban configuration ..."
if ! fail2ban-client -t >/tmp/f2b-check.log 2>&1; then
    echo "FAILED: configuration was rejected. Nothing was started."
    sed 's/^/   /' /tmp/f2b-check.log
    exit 1
fi

# Restart cleanly if already running.
if fail2ban-client status >/dev/null 2>&1; then
    echo "Restarting the running fail2ban..."
    fail2ban-client stop >/dev/null 2>&1
    sleep 1
fi

echo "Starting fail2ban..."
fail2ban-client start >/dev/null 2>&1
sleep 2

if fail2ban-client status >/dev/null 2>&1; then
    echo "fail2ban started."
    echo
    echo "Jails active:"
    fail2ban-client status | sed 's/^/   /'
    echo
    echo "From Kali, brute-force this node's SSH (e.g. hydra), then watch:"
    echo "   fail2ban-status.sh"
else
    echo "fail2ban did not start. Check /var/log/fail2ban.log"
    tail -n 10 /var/log/fail2ban.log 2>/dev/null | sed 's/^/   /'
    exit 1
fi
