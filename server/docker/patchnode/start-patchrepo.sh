#!/bin/bash
# Start the CQU lab package repository on this node.
# Usage: start-patchrepo.sh
#
# Safe to run more than once, and it must be run again after a project is closed and reopened:
# these are containers with no systemd, so nothing starts a daemon at boot.

REPO=/opt/cqu-repo
SITE=/etc/nginx/sites-enabled/cqu-repo.conf

if [ ! -d "$REPO/dists" ]; then
    echo "FAILED: no repository at $REPO. This image is built wrong; rebuild cqugns3/patchnode."
    exit 1
fi

# The site config is written here rather than baked into the image because /etc is a GNS3
# volume: a file placed there at build time can be shadowed by the node's own persisted /etc,
# and the failure mode is nginx serving the default Ubuntu welcome page instead of the
# repository — which looks like a network problem and is not. Writing it at start makes the
# node's behaviour depend on this script alone. Same reasoning as start-gitea.sh.
rm -f /etc/nginx/sites-enabled/default
cat > "$SITE" <<EOF
server {
    listen 80 default_server;
    root $REPO;
    autoindex on;
    access_log /var/log/nginx/repo-access.log;
}
EOF

# Restart cleanly if it is already running, so re-running this is harmless.
nginx -s quit 2>/dev/null
sleep 1

if ! nginx -t 2>/dev/null; then
    echo "FAILED: nginx rejected the configuration. Nothing was started."
    nginx -t
    exit 1
fi

nginx || { echo "FAILED: nginx did not start."; exit 1; }

echo "Package repository serving on port 80. Suites available:"
for d in "$REPO"/dists/*/; do
    suite=$(basename "$d")
    n=$(grep -c '^Package: ' "$d/main/binary-amd64/Packages" 2>/dev/null || echo 0)
    printf '  %-14s %s package(s)\n' "$suite" "$n"
done
echo
echo "A client adds it with a line like:"
echo "  deb [trusted=yes] http://<this-node-ip>/ cqu-base main"
