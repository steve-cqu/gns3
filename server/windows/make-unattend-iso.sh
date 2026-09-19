#!/bin/sh
# make-unattend-iso.sh - build the small ISO that answers Windows Setup's questions.
#
# Staff tool. Students never run this: they are given the ISO it produces, or they install
# Windows by hand from the guide. Run it on a Mac or on Linux.
#
# Why an ISO at all: VirtualBox answers Setup itself, through `VBoxManage unattended
# install`, so New-WindowsHost.ps1 needs nothing from here. VMware Fusion has no equivalent,
# so on a Mac the answers have to arrive as a file named autounattend.xml in the root of
# some removable media. That is all this ISO is - about 400 KB of XML and one script.
#
# What it puts on the ISO:
#   autounattend.xml              the architecture-specific answer file, renamed to the
#                                 name Windows Setup looks for
#   configure-windows-host.ps1    run by the answer file at first logon, so the machine
#                                 comes up reachable without anybody fetching anything
#
# What it does NOT do: it does not modify your Windows ISO, and it makes nothing bootable.
# This disc is only ever read by a Setup that has already booted from the Windows media.
#
# Usage:
#   ./make-unattend-iso.sh                    build for this machine's architecture
#   ./make-unattend-iso.sh --arch arm64       build for Apple Silicon Windows
#   ./make-unattend-iso.sh --arch x64         build for Intel/AMD Windows
#   ./make-unattend-iso.sh --list             show what would go on the ISO
#   ./make-unattend-iso.sh --dry-run          show the commands, build nothing
#   ./make-unattend-iso.sh -o /tmp/mine.iso   write somewhere other than beside this script
#
# The architecture matters and the failure is silent: Windows Setup ignores an
# autounattend.xml whose processorArchitecture is not its own, and simply asks every
# question by hand instead. If an "unattended" install stops on the first screen, this is
# the first thing to check.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

ARCH=
OUT="$SCRIPT_DIR/cqu-unattend.iso"
LABEL=CQU_UNATTEND
DRY=no
LIST=no

die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --arch)     ARCH=${2:?--arch needs x64 or arm64}; shift 2 ;;
        -o|--out)   OUT=${2:?--out needs a path}; shift 2 ;;
        --label)    LABEL=${2:?--label needs a value}; shift 2 ;;
        --dry-run)  DRY=yes; shift ;;
        --list)     LIST=yes; shift ;;
        *)          die "unknown option: $1 (try --help)" ;;
    esac
done

if [ -z "$ARCH" ]; then
    case "$(uname -m)" in
        arm64|aarch64) ARCH=arm64 ;;
        x86_64|amd64)  ARCH=x64 ;;
        *)             die "cannot tell this machine's architecture - pass --arch x64 or --arch arm64" ;;
    esac
    GUESSED=" (guessed from this machine)"
else
    GUESSED=""
fi

case "$ARCH" in
    x64)   ANSWER="$SCRIPT_DIR/autounattend.xml" ;;
    arm64) ANSWER="$SCRIPT_DIR/autounattend-arm64.xml" ;;
    *)     die "--arch must be x64 or arm64, not '$ARCH'" ;;
esac

CONFIGURE="$SCRIPT_DIR/configure-windows-host.ps1"

[ -r "$ANSWER" ]    || die "missing answer file: $ANSWER"
[ -r "$CONFIGURE" ] || die "missing: $CONFIGURE"

# Cheap guard against handing out an ISO for the wrong Windows. The answer file names its
# own architecture, so check it rather than trusting the filename.
want_arch=$( [ "$ARCH" = x64 ] && echo amd64 || echo arm64 )
grep -q "processorArchitecture=\"$want_arch\"" "$ANSWER" \
    || die "$ANSWER does not declare processorArchitecture=\"$want_arch\" - wrong file?"

if [ "$LIST" = yes ]; then
    echo
    echo "Unattend ISO contents for $ARCH$GUESSED"
    echo
    echo "  autounattend.xml            <- $(basename "$ANSWER")"
    echo "  configure-windows-host.ps1  <- $(basename "$CONFIGURE")"
    echo
    echo "  volume label                $LABEL"
    echo "  output                      $OUT"
    echo
    exit 0
fi

# --------------------------------------------------------------------------- #
# Stage the two files under the names the ISO must carry. autounattend.xml is the
# name Windows Setup searches for; the architecture lives inside the file, not in
# its name, which is why both variants are called the same thing on disc.
# --------------------------------------------------------------------------- #
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/cqu-unattend.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT INT TERM

cp "$ANSWER"    "$STAGE/autounattend.xml"
cp "$CONFIGURE" "$STAGE/configure-windows-host.ps1"

# --------------------------------------------------------------------------- #
# Build it with whatever this machine has. hdiutil ships with macOS; xorriso and
# genisoimage are the usual Linux answers. Joliet so Windows reads long names.
# --------------------------------------------------------------------------- #
if command -v hdiutil >/dev/null 2>&1; then
    TOOL=hdiutil
    set -- hdiutil makehybrid -iso -joliet -default-volume-name "$LABEL" -o "$OUT" "$STAGE"
elif command -v xorriso >/dev/null 2>&1; then
    TOOL=xorriso
    set -- xorriso -as mkisofs -J -r -V "$LABEL" -o "$OUT" "$STAGE"
elif command -v genisoimage >/dev/null 2>&1; then
    TOOL=genisoimage
    set -- genisoimage -J -r -V "$LABEL" -o "$OUT" "$STAGE"
elif command -v mkisofs >/dev/null 2>&1; then
    TOOL=mkisofs
    set -- mkisofs -J -r -V "$LABEL" -o "$OUT" "$STAGE"
elif [ "$DRY" = yes ]; then
    # A dry run is for reading, so it must survive on a machine with no ISO builder -
    # which is exactly where someone checks the staging before copying this to a Mac.
    TOOL="none found"
    set -- "(no ISO builder on this machine - install xorriso, or run this on a Mac)"
else
    die "no ISO builder found. macOS has hdiutil built in; on Linux install one of
  xorriso or genisoimage."
fi

if [ "$DRY" = yes ]; then
    echo
    echo "Would stage:"
    echo "  $ANSWER    -> autounattend.xml"
    echo "  $CONFIGURE -> configure-windows-host.ps1"
    echo
    echo "Would run ($TOOL):"
    echo "  $*"
    echo
    echo "Dry run: nothing was built."
    exit 0
fi

if [ -e "$OUT" ]; then
    echo "Replacing the existing $OUT"
    rm -f "$OUT"
fi

"$@" >/dev/null

[ -f "$OUT" ] || die "$TOOL reported success but produced no file at $OUT"

size=$(wc -c < "$OUT" | tr -d ' ')
echo
echo "Built $OUT"
echo "  architecture  $ARCH$GUESSED"
echo "  volume label  $LABEL"
echo "  size          $size bytes"
echo "  contents      autounattend.xml, configure-windows-host.ps1"
echo
echo "Attach it as a SECOND CD alongside the Windows ISO. new-windows-host.sh does that"
echo "for you, and looks for it beside this script by default."
