#!/bin/bash
# Start the Gitea git server on this node.
# Usage: start-gitea.sh
#
# On the first run this initialises the database and creates an admin account; on every run it points
# the server at this node's current IP and (re)starts the web service. Safe to run repeatedly — it
# never wipes existing repositories or users.
#
# Admin account:   gitadmin  /  labpass123     (change it in the web UI for anything real)
# Web UI:          http://<this-node-ip>:3000/
# Git over HTTP:   git clone http://gitadmin:labpass123@<this-node-ip>:3000/gitadmin/<repo>.git

CONF=/etc/gitea/app.ini
export GITEA_WORK_DIR=/var/lib/gitea
ADMIN_USER=gitadmin
ADMIN_PASS=labpass123

# Gitea runs as its own unprivileged user (it refuses to run as root). Make sure it owns its data.
mkdir -p /var/lib/gitea/data/repositories /var/lib/gitea/custom /var/lib/gitea/log
chown -R gitea /var/lib/gitea /etc/gitea 2>/dev/null

# Point DOMAIN/ROOT_URL at this node's own address, so the clone URLs shown in the web UI work from
# other nodes. Falls back to localhost if the interface has no address yet.
IP=$(ip -4 addr show eth0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
[ -n "$IP" ] || IP=localhost
sed -i "s#^DOMAIN =.*#DOMAIN = $IP#; s#^ROOT_URL =.*#ROOT_URL = http://$IP:3000/#" "$CONF"

asgitea(){ su gitea -s /bin/sh -c "GITEA_WORK_DIR=/var/lib/gitea $*"; }

# First run only: initialise the database. `migrate` is idempotent, so it is safe every time.
echo "Preparing the database..."
if ! asgitea "gitea migrate -c $CONF" >/var/lib/gitea/log/migrate.log 2>&1; then
    echo "FAILED: database migration. Last lines:"; tail -n 8 /var/lib/gitea/log/migrate.log | sed 's/^/   /'
    exit 1
fi

# First run only: create the admin account (skip if it already exists).
if ! asgitea "gitea admin user list -c $CONF" 2>/dev/null | awk '{print $2}' | grep -qx "$ADMIN_USER"; then
    echo "Creating the admin account '$ADMIN_USER'..."
    asgitea "gitea admin user create --username $ADMIN_USER --password $ADMIN_PASS \
             --email $ADMIN_USER@lab.local --admin --must-change-password=false -c $CONF" \
        >/var/lib/gitea/log/admin.log 2>&1 \
        || { echo "Admin create warning:"; tail -n 3 /var/lib/gitea/log/admin.log | sed 's/^/   /'; }
fi

# Restart cleanly if already running.
if pgrep -x gitea >/dev/null 2>&1; then
    echo "Stopping the running gitea..."
    pkill -x gitea
    sleep 1
fi

echo "Starting gitea web server on port 3000..."
asgitea "gitea web -c $CONF" >/var/lib/gitea/log/web.log 2>&1 &
sleep 4

if curl -s -o /dev/null -m 5 "http://127.0.0.1:3000/api/v1/version"; then
    echo "Gitea is running."
    echo
    echo "Open the web UI in a browser:   http://$IP:3000/"
    echo "Sign in as:                     $ADMIN_USER  /  $ADMIN_PASS"
    echo "Clone a repo over HTTP:         git clone http://$ADMIN_USER:$ADMIN_PASS@$IP:3000/$ADMIN_USER/<repo>.git"
    echo "Check what it is doing:         gitea-status.sh"
else
    echo "Gitea did not answer on port 3000. Last lines of the log:"
    tail -n 12 /var/lib/gitea/log/web.log 2>/dev/null | sed 's/^/   /'
    exit 1
fi
