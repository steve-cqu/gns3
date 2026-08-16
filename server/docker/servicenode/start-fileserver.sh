#!/bin/bash
# Start the Samba file server on this node.
# Usage: start-fileserver.sh
#
# It validates the config (testparm) before starting, makes sure the two shared folders exist,
# registers a Samba password for the 'student' user so the private share works, and starts smbd.
# Safe to run again — it restarts cleanly.

CONF=/etc/samba/smb.conf

# The shared folders, plus Samba's own runtime dirs.
mkdir -p /srv/public /srv/private /var/lib/samba/private /run/samba /var/log/samba
chmod 0777 /srv/public                         # public share: anyone may write
if id student >/dev/null 2>&1; then
    chown student /srv/private                  # owner only (student's group is 'class', not 'student')
    chmod 0700 /srv/private                     # private share: only student
fi
# A fresh share should not be empty — seed one readable file so `ls` shows something.
[ -e /srv/public/welcome.txt ] || \
    echo "This folder is shared to everyone on the network — try creating a file here." \
        > /srv/public/welcome.txt

echo "Checking $CONF ..."
# testparm parses smb.conf and reports errors with a line, rather than a daemon that silently is not
# there. WARN/NOTE lines are normal; only a non-zero exit means the config was rejected.
if ! testparm -s "$CONF" >/tmp/testparm.log 2>&1; then
    echo "FAILED: smb.conf was rejected. Nothing started."
    grep -iE 'error|unknown parameter|no such' /tmp/testparm.log | sed 's/^/   /'
    echo "Fix $CONF, then run start-fileserver.sh again."
    exit 1
fi

# Samba keeps its OWN password database, separate from the Linux user database — a common surprise.
# Register the student user's SMB password (gns3 is the appliance's throwaway lab password) so the
# [private] share is reachable. This is idempotent.
if id student >/dev/null 2>&1; then
    printf 'gns3\ngns3\n' | smbpasswd -s -a student >/dev/null 2>&1
    smbpasswd -e student >/dev/null 2>&1
fi

# Restart cleanly if already running.
if pgrep -x smbd >/dev/null 2>&1; then
    echo "Stopping the running smbd..."
    pkill smbd
    sleep 1
fi

echo "Starting smbd ..."
smbd -D                                        # -D daemonize
sleep 1
if pgrep -x smbd >/dev/null 2>&1; then
    echo "Samba file server started. It is sharing:"
    echo "   \\\\<this-node-ip>\\public    anyone, read/write"
    echo "   \\\\<this-node-ip>\\private   user 'student' (password: gns3)"
    echo
    echo "From a client (a Linux Host), list the shares:  smbclient -L //<this-node-ip> -N"
    echo "Copy files in/out:                              smbclient //<this-node-ip>/public -N"
    echo "Mount it as a folder (a 'mapped drive'):        mount -t cifs //<this-node-ip>/public /mnt -o guest"
    echo "See who is connected:                           fileshare-status.sh"
else
    echo "smbd did not stay running. Last lines of /var/log/samba/log.smbd:"
    tail -n 12 /var/log/samba/log.smbd 2>/dev/null | sed 's/^/   /'
    exit 1
fi
