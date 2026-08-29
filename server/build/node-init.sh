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

# Re-apply GNS3's ownership record from a home directory that used to be its own bind root.
#
# WHY. GNS3 writes `.gns3_perms` at the root of each bind ("mode:uid:gid:path" per line) and
# re-applies it on later starts, which is what carries file ownership through an export and import.
# On 29 August 2026 alpinenode's volume widened from /home/student to /home, so that record now sits
# one level BELOW the bind root in every project exported before the change — and GNS3 reads it only
# at the root. Without this, a student's own home arrives owned by the uid of whoever exported it
# (1000, the gns3 account on the VM), and they cannot write their own ~/.ssh: `ssh-copy-id` fails,
# a shipped key is unusable, and the error names permissions rather than the cause. Measured on
# Ansible-Basics-Solution.gns3project, whose .ssh landed as 1000:1000.
#
# This also repairs the reverse direction, which matters more: a project a student exported from a
# T2 2026 appliance carries exactly this layout, and lands on a T3 appliance the same way.
#
# It is deliberately narrow — /home/<user>/.gns3_perms only, the one bind root that moved — and it
# applies the file GNS3 itself wrote, in GNS3's own format, so it can only restore what GNS3 would
# have restored. Paths that no longer exist are skipped.
for _perms in /home/*/.gns3_perms; do
    [ -f "$_perms" ] || continue
    while IFS=: read -r _mode _uid _gid _path; do
        [ -n "$_path" ] && [ -e "$_path" ] || continue
        chown "$_uid:$_gid" "$_path" 2>/dev/null || true
        chmod "$_mode" "$_path" 2>/dev/null || true
    done < "$_perms"
done

exec "$@"
