#!/bin/sh
# PID 1 for a GNS3 Docker node: normalise the persisted directories, then become the command the
# image would otherwise have run.
#
# WHY THIS RUNS AT START RATHER THAN AT BUILD. GNS3 2.2 refuses to import a project containing an
# absolute symlink, and a node's persisted /etc is seeded from the image — so relativising the
# image's links at build time removes almost all of them. Almost: Docker writes
# /etc/mtab -> /proc/mounts into a container's own filesystem when the container is CREATED - it is
# not in the image at all (traced 28 Aug 2026: absent from every layer of cqugns3/alpinenode,
# present in `docker export` of a created-but-never-started container). GNS3 builds a new container
# each time a project is opened, so it reappears every session, lands in the persisted /etc bind,
# and ONE absolute link is all it takes to be refused. Measured 28 August 2026: a build-time pass took
# a node from 122 absolute links to 1, and the export was still refused with a 409 naming
# /etc/mtab. See gns3-dev/notes/node-persistence.md.
#
# `exec` matters: it keeps the shell as PID 1, so the console attaches to it and the process
# semantics every node script already reasons about (including the zombie trap that start-tailscale
# and friends guard against) are unchanged. Verified on a live node: /proc/1/comm is still `sh`.
#
# <CMD> below is substituted with the image's own original command when this is injected, because
# it is not /bin/sh everywhere — frrnode starts start-frr.sh, netemnode start-netem.sh, ubuntunode
# /bin/bash. Hard-coding a shell here would silently turn those nodes into bare shells.

# The same directories the build-time pass covers, not /etc alone: a node persists more than /etc
# (/root, /usr/local/bin, /var/www, /var/lib/grafana, ...), and anything absolute appearing in one
# of them after the image was built -- by the container runtime, or by a student -- travels into
# the export just as /etc/mtab does. Non-existent paths are skipped by the script, so one list is
# safe on every image.
#
# gns3build.py rewrites the line below at injection time with the list derived from the templates.
# The default keeps this script correct and runnable on its own.
DIRS="/etc"

# shellcheck disable=SC2086  # DIRS is a deliberate word-split list of paths
/sbin/relativise-symlinks.sh $DIRS >/dev/null 2>&1 || true

exec "$@"
