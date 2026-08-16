#!/bin/bash
# What is this Gitea git server doing?
# Usage: gitea-status.sh

CONF=/etc/gitea/app.ini
export GITEA_WORK_DIR=/var/lib/gitea
asgitea(){ su gitea -s /bin/sh -c "GITEA_WORK_DIR=/var/lib/gitea $*"; }

echo "================================================"
echo "Gitea Git Server Status"
echo "================================================"
echo ""

echo "1. Server process:"
if pgrep -x gitea >/dev/null 2>&1; then
    # The [g] trick matches the gitea daemon without also matching the *-gitea.sh helper scripts
    # (pgrep would substring-match those) or the grep itself.
    ps -o pid,args 2>/dev/null | grep -E '[g]itea web' | sed 's/^/   /'
else
    echo "   gitea is NOT running — start it with start-gitea.sh"
fi
echo ""

echo "2. This node's addresses (what a browser and clients point at, port 3000):"
ip -4 addr show | grep -E 'inet ' | grep -v '127.0.0.1' | sed 's/^/   /' || echo "   no IPv4 address configured"
echo ""

echo "3. Answering on port 3000?"
if curl -s -m 5 http://127.0.0.1:3000/api/v1/version >/tmp/gv 2>/dev/null; then
    echo "   yes — $(cat /tmp/gv)"
else
    echo "   no response on http://127.0.0.1:3000/"
fi
echo ""

echo "4. Users:"
asgitea "gitea admin user list -c $CONF" 2>/dev/null | sed 's/^/   /' || echo "   (query failed)"
echo ""

echo "5. Repositories on disk:"
ls -1 /var/lib/gitea/data/repositories/*/ 2>/dev/null | sed 's/^/   /' || echo "   none yet — create one in the web UI"
echo ""

echo "================================================"
echo "Config:   $CONF"
echo "Data:     /var/lib/gitea/data   (SQLite DB + repositories; persisted)"
echo "Logs:     /var/lib/gitea/log/"
echo "Web UI:   http://<this-node-ip>:3000/   (admin: gitadmin / labpass123)"
echo "================================================"
