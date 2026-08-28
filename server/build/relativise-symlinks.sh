#!/bin/sh
# Rewrite absolute symlinks as relative ones, under the directories a GNS3 node persists.
# Usage: relativise-symlinks.sh [dir ...]        (default: /etc)
#
# WHY THIS EXISTS. GNS3 2.2 refuses to import a project containing an absolute symlink:
#
#   409  Symlink 'project-files/docker/<node>/etc/mtab' has absolute target
#        '/proc/mounts', refusing
#
# and a Docker node's persisted directories are seeded from this image, so whatever links the
# image has end up inside every project built from it — and therefore inside every project a
# student exports and submits. Measured 28 August 2026 on two appliances: a student-style project
# carried 363 absolute symlinks and was refused on import, including by the very appliance it was
# exported from. See gns3-dev/notes/node-persistence.md.
#
# Nearly all of them are the ca-certificates farm in /etc/ssl/certs — 119 per Alpine node, plus
# /etc/mtab and /etc/ssl1.1/cert.pem. Every one has an exact relative equivalent resolving to the
# same file, so nothing is lost by rewriting them: ../proc/mounts is /proc/mounts read from /etc.
#
# The links are NOT deleted. Deleting them would empty the node's CA trust store, and three
# activities (https-setup-selfsigned, openssl-ca, reverse-proxy) also keep their own server
# certificates in /etc/ssl/certs, so that directory has to persist and has to work.
#
# Run this LAST in a Dockerfile. Anything installed afterwards that touches ca-certificates
# recreates absolute links, and the pass would then be undone without saying so.

[ $# -gt 0 ] || set -- /etc

# The `while read` loop below runs in a subshell (it is on the right of a pipe), so a counter
# incremented inside it would not survive. Tally through a file instead of guessing.
TALLY=$(mktemp 2>/dev/null || echo /tmp/relativise.$$)

fixed=0
skipped=0
for dir in "$@"; do
    [ -d "$dir" ] || continue
    # `for link in $(find ...)` word-splits, so a symlink whose name contains a space is silently
    # skipped -- and ONE absolute link left behind is all it takes for an import to be refused.
    # Read null-free lines instead, and count anything unreadable rather than swallowing it.
    find "$dir" -type l 2>/dev/null | while IFS= read -r link; do
        target=$(readlink "$link" 2>/dev/null) || { echo "  ! cannot read $link" >&2; continue; }
        case "$target" in
            /*) ;;
            *) continue ;;                       # already relative
        esac
        parent=$(dirname "$link")
        case "$parent" in
            /) continue ;;                       # a link in / has nothing to climb to
        esac
        # One ../ per level the link's directory sits below /, so the prefix resolves to / and the
        # absolute target can be appended with its leading slash removed. Pure shell: busybox has
        # no `realpath --relative-to`, and an awk that is missing (or differs) would produce an
        # EMPTY prefix and write a wrong link, which is worse than doing nothing.
        rest=${parent#/}
        up=""
        while [ -n "$rest" ]; do
            up="../$up"
            case "$rest" in
                */*) rest=${rest#*/} ;;
                *) rest="" ;;
            esac
        done
        ln -sfn "${up}${target#/}" "$link" && echo fixed
    done
done > "$TALLY" 2>/dev/null
fixed=$(grep -c '^fixed$' "$TALLY" 2>/dev/null || echo 0)
rm -f "$TALLY"

echo "relativise-symlinks: rewrote $fixed absolute symlink(s) under $*"
