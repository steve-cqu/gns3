#!/usr/bin/env bash
# Collect everything needed to restore a CQU GNS3 appliance years from now, into one folder
# ready to copy to the CQU shared drive.
#
#   ./archive-release.sh <version> <output-dir> --vm-host <ip> [options]
#
#   ./archive-release.sh v030 ~/archive --vm-host 192.168.56.109
#   ./archive-release.sh v030 ~/archive --vm-host 192.168.56.109 --arch arm64
#   ./archive-release.sh v030 ~/archive --vm-host 192.168.56.109 \
#        --ova ~/ova/gns3-cqu-v030-amd64.ova \
#        --vm-appliance ~/Downloads/GNS3VM.VirtualBox.0.15.0.zip
#
# Run it ONCE PER ARCHITECTURE, pointing --vm-host at that architecture's VM, into the SAME
# output directory. The two runs contribute different files and the folder accumulates.
#
# Options:
#   --vm-host <ip>        the GNS3 VM to archive from            (required)
#   --arch <amd64|arm64>  build profile on that VM               (default: amd64)
#   --ova <file>          an OVA to copy in; repeatable
#   --vm-appliance <p|url>  upstream GNS3 VM zip: local path or https:// URL
#   --vm-user <name>      ssh user on the VM                     (default: gns3)
#   --vm-repo <path>      gns3 checkout on the VM                (default: /home/gns3/git/gns3)
#   --skip-freeze         don't docker save the images
#   --skip-qemu           don't archive the Qemu disks
#   --skip-bundles        don't git bundle the repos
#   --dry-run             say what would happen, touch nothing
#
# WHAT THIS IS FOR. The appliance is frozen for years, not months. A from-source rebuild in 2028
# depends on Docker Hub, the Alpine CDN, Ubuntu's archive, alpine edge/testing and packages.wazuh.com
# all still serving what they serve today — several of which will have moved or gone. This folder
# removes that dependency. See server/RESTORE.md, which is copied in as part of the run.
#
# Requires: ssh, and sshpass for the default gns3/gns3 password login (an ssh key is used if one
# works). Run it from a workstation that can reach the VM, with both repos checked out side by side.
set -euo pipefail

usage() {
    # Every comment line after the shebang, up to the first line of code — so editing the header
    # above cannot silently truncate the help text, which a fixed line range did.
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit "${1:-1}"
}

[ $# -ge 2 ] || usage
case "$1" in -h|--help) usage 0 ;; esac

VERSION=$1
OUTDIR=$2
shift 2

VM_HOST=""; ARCH="amd64"; VM_USER="gns3"; VM_REPO="/home/gns3/git/gns3"
VM_APPLIANCE=""; DRY=0; SKIP_FREEZE=0; SKIP_QEMU=0; SKIP_BUNDLES=0
OVAS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --vm-host)       VM_HOST=$2; shift 2 ;;
        --arch)          ARCH=$2; shift 2 ;;
        --ova)           OVAS+=("$2"); shift 2 ;;
        --vm-appliance)  VM_APPLIANCE=$2; shift 2 ;;
        --vm-user)       VM_USER=$2; shift 2 ;;
        --vm-repo)       VM_REPO=$2; shift 2 ;;
        --skip-freeze)   SKIP_FREEZE=1; shift ;;
        --skip-qemu)     SKIP_QEMU=1; shift ;;
        --skip-bundles)  SKIP_BUNDLES=1; shift ;;
        --dry-run)       DRY=1; shift ;;
        -h|--help)       usage 0 ;;
        *) echo "error: unknown option '$1'" >&2; usage ;;
    esac
done

[ -n "$VM_HOST" ] || { echo "error: --vm-host is required" >&2; usage; }
case "$ARCH" in amd64|arm64) ;; *) echo "error: --arch must be amd64 or arm64" >&2; exit 2 ;; esac

HERE=$(cd "$(dirname "$0")" && pwd)          # <repo>/server
GNS3_REPO=$(cd "$HERE/.." && pwd)
DEV_REPO=$(cd "$GNS3_REPO/../gns3-dev" 2>/dev/null && pwd || echo "")
DEST="$OUTDIR/gns3-$VERSION"

say()  { printf '\n=== %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
run()  { if [ "$DRY" = 1 ]; then printf '    [dry-run] %s\n' "$*"; else eval "$@"; fi; }

# ---------------------------------------------------------------- ssh plumbing ----
# An ssh key if one works, else sshpass with the appliance's default password — the same
# fallback the test harness uses, so this works on a stock VM and on a hardened one.
SSH_BASE="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
if ssh $SSH_BASE -o BatchMode=yes "$VM_USER@$VM_HOST" true 2>/dev/null; then
    SSH()  { ssh $SSH_BASE "$VM_USER@$VM_HOST" "$@"; }
    SCPF() { scp $SSH_BASE "$VM_USER@$VM_HOST:$1" "$2"; }
    AUTH="ssh key"
elif command -v sshpass >/dev/null; then
    VM_PASS=${GNS3_VM_SSH_PASS:-gns3}
    SSH()  { sshpass -p "$VM_PASS" ssh $SSH_BASE "$VM_USER@$VM_HOST" "$@"; }
    SCPF() { sshpass -p "$VM_PASS" scp $SSH_BASE "$VM_USER@$VM_HOST:$1" "$2"; }
    AUTH="sshpass"
else
    echo "error: cannot ssh to $VM_USER@$VM_HOST with a key, and sshpass is not installed." >&2
    echo "       install sshpass, or set up an ssh key, or set GNS3_VM_SSH_PASS." >&2
    exit 2
fi
SSH true >/dev/null 2>&1 || { echo "error: cannot reach $VM_USER@$VM_HOST" >&2; exit 2; }

say "Archiving $VERSION ($ARCH) from $VM_USER@$VM_HOST [$AUTH] -> $DEST"
run "mkdir -p '$DEST'"

# ---------------------------------------------------------------- preflight ----
say "Preflight"

# freeze/thaw were added Aug 2026. A VM synced from an older checkout has no `freeze`, and the
# failure would otherwise be an opaque argparse error most of the way into the run.
if [ "$SKIP_FREEZE" = 0 ]; then
    if ! SSH "python3 $VM_REPO/server/build/gns3build.py freeze --help" >/dev/null 2>&1; then
        echo "error: gns3build.py on the VM has no 'freeze' command." >&2
        echo "       $VM_REPO is older than the freeze/thaw change. Run a build first so the" >&2
        echo "       ansible repo phase syncs the current checkout, then re-run this." >&2
        exit 2
    fi
    note "VM gns3build.py has freeze: ok"
fi

# docker save writes to the VM's disk before it comes over the wire.
FREE_MB=$(SSH "df -Pm /home/$VM_USER | awk 'NR==2 {print \$4}'" 2>/dev/null || echo 0)
note "VM free space on /home/$VM_USER: ${FREE_MB} MB"
if [ "$SKIP_FREEZE" = 0 ] && [ "${FREE_MB:-0}" -lt 6000 ]; then
    echo "warning: less than 6 GB free on the VM; the frozen archive may not fit." >&2
fi

for r in "$GNS3_REPO" "$DEV_REPO"; do
    [ -n "$r" ] || continue
    if [ -n "$(git -C "$r" status --porcelain 2>/dev/null)" ]; then
        echo "warning: $(basename "$r") work tree is DIRTY — the bundle will not match any tag." >&2
    fi
    if ! git -C "$r" rev-parse "$VERSION" >/dev/null 2>&1; then
        echo "warning: $(basename "$r") has no tag '$VERSION' — tag both repos before releasing." >&2
    fi
done
[ -n "$DEV_REPO" ] || echo "warning: no gns3-dev checkout beside $GNS3_REPO; skipping its bundle." >&2

# ---------------------------------------------------------------- 1. frozen images ----
if [ "$SKIP_FREEZE" = 0 ]; then
    say "1. Freezing the Docker image set ($ARCH)"
    FRZ="frozen-$VERSION-$ARCH.tar.gz"
    run "SSH \"python3 $VM_REPO/server/build/gns3build.py freeze --profile $ARCH --out /home/$VM_USER/$FRZ\""
    run "SCPF '/home/$VM_USER/$FRZ' '$DEST/$FRZ'"
    run "SCPF '/home/$VM_USER/$FRZ.json' '$DEST/$FRZ.json'"
    run "SSH \"rm -f /home/$VM_USER/$FRZ /home/$VM_USER/$FRZ.json\""
    note "-> $FRZ (+ .json sidecar)"
else
    say "1. Frozen images: SKIPPED"
fi

# ---------------------------------------------------------------- 2. qemu disks ----
# Pinned by URL and md5 in the manifest, but hosted on SourceForge, a community mirror and a
# personal GitHub release. Assume at least one has 404'd by the time this is needed.
if [ "$SKIP_QEMU" = 0 ]; then
    say "2. Archiving the Qemu disk images ($ARCH)"
    # No sudo: qemu_images_dir is owned by the gns3 user, and not needing root keeps this
    # working on an appliance where passwordless sudo has been taken away.
    QT="qemu-images-$VERSION-$ARCH.tar"
    run "SSH \"tar -cf /home/$VM_USER/$QT -C /opt/gns3/images QEMU\""
    run "SCPF '/home/$VM_USER/$QT' '$DEST/$QT'"
    run "SSH \"rm -f /home/$VM_USER/$QT\""
    note "-> $QT (~3.7 GB; the .md5sum sidecars come with it)"
else
    say "2. Qemu disks: SKIPPED"
fi

# ---------------------------------------------------------------- 3. repos ----
# `git bundle`, not a copied .git: one file, full history and tags, survives being moved around
# a Windows share, and clones back with `git clone gns3.bundle`.
if [ "$SKIP_BUNDLES" = 0 ]; then
    say "3. Bundling the repositories"
    run "mkdir -p '$DEST/repos'"
    run "git -C '$GNS3_REPO' bundle create '$DEST/repos/gns3.bundle' --all"
    note "-> repos/gns3.bundle"
    if [ -n "$DEV_REPO" ]; then
        run "git -C '$DEV_REPO' bundle create '$DEST/repos/gns3-dev.bundle' --all"
        note "-> repos/gns3-dev.bundle"
    fi
else
    say "3. Repo bundles: SKIPPED"
fi

# ---------------------------------------------------------------- 4. OVAs ----
say "4. OVAs"
if [ ${#OVAS[@]} -eq 0 ]; then
    note "none given (--ova). The OVA is the MOST important artefact here — add it before"
    note "this folder is any use for a plain re-release."
else
    for o in "${OVAS[@]}"; do
        [ -f "$o" ] || { echo "error: no such OVA: $o" >&2; exit 2; }
        run "cp -n '$o' '$DEST/'"
        note "-> $(basename "$o")"
    done
fi

# ---------------------------------------------------------------- 5. GNS3 VM ----
# GNS3 versions the VM appliance separately from the server (0.15.0 vs 2.2.61), so there is no
# reliable mapping to guess from. Give it the file or the URL you actually used.
say "5. Upstream GNS3 VM appliance"
if [ -z "$VM_APPLIANCE" ]; then
    note "none given (--vm-appliance). GNS3 retires old downloads; without this a 2028 rebuild"
    note "has no VM to start from. Add the .zip you built this appliance on."
else
    run "mkdir -p '$DEST/gns3-vm'"
    case "$VM_APPLIANCE" in
        http://*|https://*)
            run "curl -fL --retry 3 -o '$DEST/gns3-vm/$(basename "$VM_APPLIANCE")' '$VM_APPLIANCE'" ;;
        *)
            [ -f "$VM_APPLIANCE" ] || { echo "error: no such file: $VM_APPLIANCE" >&2; exit 2; }
            run "cp -n '$VM_APPLIANCE' '$DEST/gns3-vm/'" ;;
    esac
    note "-> gns3-vm/$(basename "$VM_APPLIANCE")"
fi

# ---------------------------------------------------------------- 6. RESTORE.md ----
say "6. Restore instructions"
run "cp '$HERE/RESTORE.md' '$DEST/RESTORE.md'"
note "-> RESTORE.md  (FILL IN ITS HEADER: version, date, GNS3 version, terms, repo tags)"

# ---------------------------------------------------------------- 7. checksums ----
# Last, so it covers everything above. Verify later with: sha256sum -c SHA256SUMS
say "7. Checksums"
if [ "$DRY" = 1 ]; then
    note "[dry-run] sha256sum over $DEST -> SHA256SUMS"
else
    ( cd "$DEST" && find . -type f ! -name SHA256SUMS -print0 \
        | sort -z | xargs -0 sha256sum > SHA256SUMS )
    note "-> SHA256SUMS ($(wc -l < "$DEST/SHA256SUMS") files)"
fi

# ---------------------------------------------------------------- summary ----
say "Done"
if [ "$DRY" = 1 ]; then
    echo "    dry run — nothing was written."
else
    du -sh "$DEST" 2>/dev/null | sed 's/^/    total  /'
    echo
    ls -la "$DEST" | sed 's/^/    /'
fi
cat <<EOF

Next:
  1. Fill in the header of $DEST/RESTORE.md.
  2. Add the OVAs and the GNS3 VM zip if they were not passed in.
  3. Run this again with --arch arm64 --vm-host <arm64 vm> into the same output directory.
  4. Copy $DEST to the CQU shared drive.
  5. Verify the copy landed intact:  cd <drive>/gns3-$VERSION && sha256sum -c SHA256SUMS

Only archive a build that has passed verify=all. An archive of an unverified appliance is
worse than none, because it looks authoritative.
EOF
