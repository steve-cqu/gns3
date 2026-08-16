# Gitea git server node — a self-hosted GitHub/GitLab with a web UI, for the "run your own Git
# server" lab (Tier 2 Module 3b). See gns3-dev/notes/tier2-file-backup-git.md.
#
# Its OWN image, not a servicenode template: Gitea is a ~133 MB Go binary plus a web-app's worth of
# templates and assets, which is exactly the "drags in a runtime the others do not need" case that
# decision D2 splits an image on. Derived from cqugns3/alpinenode so a console on it behaves like
# every other node (git, curl, nano, the student account are all there).
FROM cqugns3/alpinenode

# gitea ships with SQLite compiled in, so this needs no separate database node — the whole server is
# one binary + one file. The package also creates the unprivileged `gitea` user that the service
# runs as (Gitea refuses to run as root).
RUN apk add --no-cache gitea

# Data directories the service owns: the SQLite database, the bare repositories, custom assets and
# logs. gitea's group is not named "gitea" (it is a shared low gid), so chown by owner only.
RUN mkdir -p /var/lib/gitea/data/repositories /var/lib/gitea/custom /var/lib/gitea/log \
 && chown -R gitea /var/lib/gitea /etc/gitea

# Shipped configuration — a working lab config (SQLite, HTTP git, web installer locked). Meant to be
# read more than edited; start-gitea.sh rewrites DOMAIN/ROOT_URL to the node's own IP at start.
COPY app.ini /etc/gitea/app.ini
RUN chown gitea /etc/gitea/app.ini

# Helper scripts in /usr/local/bin (persisted, ahead of /bin in PATH) so edits survive a project
# close — the lesson recorded in ipv6node's Dockerfile.
COPY start-gitea.sh   /usr/local/bin/start-gitea.sh
COPY gitea-status.sh  /usr/local/bin/gitea-status.sh
RUN chmod +x /usr/local/bin/start-gitea.sh /usr/local/bin/gitea-status.sh

# The database and repositories persist, so a student's server and its repos survive a project close.
VOLUME /var/lib/gitea /etc/gitea
