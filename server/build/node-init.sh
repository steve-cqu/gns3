#!/bin/sh
# PID 1 for a GNS3 Docker node: normalise the persisted directories, then become the command the
# image would otherwise have run.
#
# WHY THIS RUNS AT START RATHER THAN AT BUILD. GNS3 2.2 refuses to import a project containing an
# absolute symlink, and a node's persisted /etc is seeded from the image — so relativising the
# image's links at build time removes almost all of them. Almost: the container RUNTIME writes
# /etc/mtab -> /proc/mounts into the bind at every start, after every layer has been applied, and
# ONE absolute link is all it takes to be refused. Measured 28 August 2026: a build-time pass took
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

/sbin/relativise-symlinks.sh /etc >/dev/null 2>&1 || true

exec "$@"
