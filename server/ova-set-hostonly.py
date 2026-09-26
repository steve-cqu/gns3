#!/usr/bin/env python3
"""Rewrite the host-only adapter name stored inside a VirtualBox `.ova`.

VirtualBox records the exporting host's own name for the host-only network in the `.ovf`, in the
`<vbox:Machine>` section: `vboxnet0` on Linux and macOS, `VirtualBox Host-Only Ethernet Adapter`
on Windows. An appliance exported on one and imported on the other refuses to start until the
user visits both adapter tabs in *Settings → Network* (`../vm/troubleshooting.md`). The amd64
appliance is built on Linux but almost every student imports it on Windows, so this rewrites the
name before release instead of leaving every student to hit the error.

    ./ova-set-hostonly.py GNS3-CQU-v044-amd64.ova --show        # what the file carries now
    ./ova-set-hostonly.py GNS3-CQU-v044-amd64.ova               # → Windows name, in place
    ./ova-set-hostonly.py in.ova -o out.ova --name vboxnet0     # or any name, to a new file

Only the `name` attribute of each `<HostOnlyInterface>` element changes, whether it belongs to the
active adapter or to an adapter's remembered `<DisabledModes>`. The `.mf` digest for the `.ovf`
is recomputed, keeping the algorithm the file already uses (SHA1 or SHA256). Every other member,
disks included, is streamed through unchanged in its original order, with the `.ovf` still first
as the OVF standard requires. The disk is never unpacked to its own file, but the new archive is
the same size as the old one, so the output directory needs that much free space. A `.cert`
signature can no longer be valid after the edit, so the tool refuses a signed `.ova` rather than
ship one that fails verification.
"""
import argparse
import copy
import hashlib
import io
import os
import re
import sys
import tarfile
import tempfile
from pathlib import Path

WINDOWS_NAME = "VirtualBox Host-Only Ethernet Adapter"
HOSTONLY = re.compile(rb'(<HostOnlyInterface\b[^>]*?\bname=")([^"]*)(")')
MF_LINE = re.compile(r"^(SHA1|SHA256|SHA512)\s*\((.+)\)\s*=\s*([0-9A-Fa-f]+)\s*$")


def xml_escape(s):
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
             .replace('"', "&quot;"))


def rewrite_mf(mf_text, ovf_name, ovf_bytes):
    out, hit = [], False
    for line in mf_text.splitlines():
        m = MF_LINE.match(line)
        if m and m.group(2) == ovf_name:
            algo = m.group(1)
            digest = hashlib.new(algo.lower(), ovf_bytes).hexdigest()
            line, hit = f"{algo} ({ovf_name}) = {digest}", True
        out.append(line)
    if not hit:
        sys.exit(f"error: manifest has no digest line for {ovf_name}")
    return ("\n".join(out) + "\n").encode()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("ova", type=Path)
    ap.add_argument("-o", "--output", type=Path,
                    help="write here instead of replacing the input")
    ap.add_argument("--name", default=WINDOWS_NAME,
                    help=f'host-only interface name to set (default: "{WINDOWS_NAME}")')
    ap.add_argument("--show", action="store_true",
                    help="print the names the file carries and change nothing")
    args = ap.parse_args()

    with tarfile.open(args.ova, "r:") as src:
        members = src.getmembers()
        ovfs = [m for m in members if m.name.endswith(".ovf")]
        if len(ovfs) != 1:
            sys.exit(f"error: expected one .ovf in {args.ova}, found {len(ovfs)}")
        ovf = ovfs[0]
        ovf_bytes = src.extractfile(ovf).read()
        current = [n.decode() for _, n, _ in HOSTONLY.findall(ovf_bytes)]

        if args.show:
            print(f"{ovf.name}:")
            for n in current or ["(no HostOnlyInterface elements)"]:
                print(f"  {n}")
            return
        if not current:
            sys.exit(f"error: {ovf.name} has no <HostOnlyInterface> — nothing to rewrite")
        if any(m.name.endswith(".cert") for m in members):
            sys.exit("error: this .ova is signed (.cert); rewriting it would break the signature")

        new_name = xml_escape(args.name).encode()
        new_ovf = HOSTONLY.sub(lambda m: m.group(1) + new_name + m.group(3), ovf_bytes)
        if new_ovf == ovf_bytes:
            print(f"already set to {args.name!r} — nothing to do")
            return

        dest = args.output or args.ova
        fd, tmp = tempfile.mkstemp(dir=dest.resolve().parent, prefix=".ova-", suffix=".tmp")
        os.close(fd)
        try:
            with tarfile.open(tmp, "w:", format=src.format) as out:
                for m in members:
                    info = copy.copy(m)
                    if m is ovf:
                        data = new_ovf
                    elif m.name.endswith(".mf"):
                        data = rewrite_mf(src.extractfile(m).read().decode(),
                                          ovf.name, new_ovf)
                    else:
                        out.addfile(info, src.extractfile(m) if m.isfile() else None)
                        continue
                    info.size = len(data)
                    out.addfile(info, io.BytesIO(data))
            os.replace(tmp, dest)
        except BaseException:
            os.unlink(tmp)
            raise

    for old in sorted(set(current)):
        print(f"{old!r} → {args.name!r}")
    print(f"wrote {dest}")


if __name__ == "__main__":
    main()
