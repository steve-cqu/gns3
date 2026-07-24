#!/usr/bin/env python3
"""
gns3build.py — data-driven, idempotent GNS3 VM build (Layer 0).

Reads build/manifest.yml and drives node/template installation without the fragile
gns3_controller.conf text-assembly of the legacy vm-install-*.sh scripts. Templates are
registered through the GNS3 REST API (POST /v2/templates), which is additive and
idempotent — existing template_ids are skipped — so re-running is safe and needs no
`systemctl stop/start gns3`.

Subcommands
  validate                  parse the manifest + every referenced template .conf; report issues
  plan     --profile P      show what a full build of profile P would install (no changes)
  templates --profile P     register profile P's templates via the controller API

Server selection: --server URL (default $GNS3_SERVER or http://localhost). Run from the
build host against the VM, e.g. --server http://<gns3-vm-ip>. Use --dry-run to preview
API writes without making them.

Status: Layer 0 in progress — `templates`/`validate`/`plan` implemented; docker-build and
qemu-download phases are described by the manifest and handled next (they run on the VM).
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("PyYAML required: pip install pyyaml")

HERE = Path(__file__).resolve().parent
DEFAULT_MANIFEST = HERE / "manifest.yml"


# --------------------------------------------------------------------------- #
# Manifest loading / resolution
# --------------------------------------------------------------------------- #
def load_manifest(path):
    m = yaml.safe_load(Path(path).read_text())
    m["_dir"] = Path(path).resolve().parent
    m["_templates_dir"] = (m["_dir"] / m["paths"]["templates_dir"]).resolve()
    return m


def profile_platform(m, profile):
    if profile not in m["profiles"]:
        sys.exit(f"unknown profile '{profile}' (have: {', '.join(m['profiles'])})")
    return m["profiles"][profile]["platform"]


def node_keys(m, platform):
    """Docker then Qemu node keys for a platform, in manifest order."""
    p = m["platforms"][platform]
    return list(p.get("docker", [])) + list(p.get("qemu", []))


def template_names(m, platform):
    """Ordered, de-duplicated list of template .conf names for a platform."""
    seen, out = set(), []
    for key in node_keys(m, platform):
        node = m["nodes"].get(key)
        if node is None:
            sys.exit(f"platform '{platform}' references unknown node '{key}'")
        for t in node.get("templates", []):
            if t not in seen:
                seen.add(t)
                out.append(t)
    return out


def read_template(m, name):
    """Load templates/<name>.conf as a JSON template object."""
    f = m["_templates_dir"] / f"{name}.conf"
    if not f.exists():
        raise FileNotFoundError(f"template file not found: {f}")
    return json.loads(f.read_text())


# --------------------------------------------------------------------------- #
# Minimal GNS3 v2 controller client
# --------------------------------------------------------------------------- #
class Controller:
    def __init__(self, base):
        self.base = base.rstrip("/")

    def _req(self, method, path, body=None, timeout=30):
        url = f"{self.base}/v2{path}"
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        if data is not None:
            req.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
            return json.loads(raw) if raw else None

    def version(self):
        return self._req("GET", "/version").get("version")

    def templates(self):
        return self._req("GET", "/templates")

    def add_template(self, body):
        return self._req("POST", "/templates", body=body)


# --------------------------------------------------------------------------- #
# Subcommands
# --------------------------------------------------------------------------- #
def cmd_validate(args):
    m = load_manifest(args.manifest)
    problems = []

    for platform in m["platforms"]:
        for key in node_keys(m, platform):
            if key not in m["nodes"]:
                problems.append(f"platform '{platform}': unknown node '{key}'")

    # Validate every referenced template file (parse + required fields).
    referenced = set()
    for platform in m["platforms"]:
        referenced |= set(template_names(m, platform))
    tid_of = {}
    for name in sorted(referenced):
        try:
            t = read_template(m, name)
        except Exception as e:
            problems.append(f"template '{name}': {e}")
            continue
        for field in ("template_id", "name", "template_type"):
            if field not in t:
                problems.append(f"template '{name}': missing '{field}'")
        tid_of[name] = t.get("template_id")

    # template_ids must be unique *within a platform* (a single VM installs one
    # platform). The same id may be shared across platforms on purpose — the pc and
    # mac arch variants of a node share an id so projects stay portable.
    for platform in m["platforms"]:
        seen = {}
        for name in template_names(m, platform):
            tid = tid_of.get(name)
            if tid and tid in seen:
                problems.append(
                    f"platform '{platform}': template_id {tid} in both "
                    f"'{name}' and '{seen[tid]}'")
            elif tid:
                seen[tid] = name

    print(f"manifest: {args.manifest}")
    print(f"profiles: {', '.join(m['profiles'])}")
    print(f"templates referenced: {len(referenced)}")
    if problems:
        print(f"\n{len(problems)} problem(s):")
        for p in problems:
            print(f"  - {p}")
        return 1
    print("OK — manifest and all referenced templates valid.")
    return 0


def cmd_plan(args):
    m = load_manifest(args.manifest)
    platform = profile_platform(m, args.profile)
    print(f"profile {args.profile}  (platform: {platform})\n")
    print("Docker images to build:")
    for key in m["platforms"][platform].get("docker", []):
        n = m["nodes"][key]
        src = n["source"]
        where = src.get("path") or src.get("dir")
        print(f"  {n['image']:32} <- {src['type']}:{where}")
    print("\nQemu images to download:")
    for key in m["platforms"][platform].get("qemu", []):
        n = m["nodes"][key]
        print(f"  {n['file']:48} md5={n.get('md5','-')}")
    print("\nTemplates to register:")
    for name in template_names(m, platform):
        print(f"  {name}")
    return 0


def cmd_templates(args):
    m = load_manifest(args.manifest)
    platform = profile_platform(m, args.profile)
    names = template_names(m, platform)

    ctrl = Controller(args.server)
    try:
        ver = ctrl.version()
    except urllib.error.URLError as e:
        sys.exit(f"cannot reach controller at {args.server}: {e}")
    print(f"controller {args.server} — GNS3 {ver}")

    existing = {t["template_id"]: t.get("name") for t in ctrl.templates()}
    created = skipped = failed = 0
    for name in names:
        try:
            body = read_template(m, name)
        except Exception as e:
            print(f"  ERROR  {name}: {e}")
            failed += 1
            continue
        tid = body.get("template_id")
        if tid in existing:
            print(f"  skip   {name:22} (already registered: {body.get('name')})")
            skipped += 1
            continue
        if args.dry_run:
            print(f"  +POST  {name:22} (would register '{body.get('name')}' {tid})")
            created += 1
            continue
        try:
            ctrl.add_template(body)
            print(f"  create {name:22} ('{body.get('name')}')")
            created += 1
        except urllib.error.HTTPError as e:
            print(f"  ERROR  {name}: HTTP {e.code} {e.read().decode(errors='replace')[:200]}")
            failed += 1

    verb = "would register" if args.dry_run else "registered"
    print(f"\n{verb} {created}, skipped {skipped}, failed {failed}")
    return 1 if failed else 0


# --------------------------------------------------------------------------- #
def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--manifest", default=str(DEFAULT_MANIFEST))
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("validate")

    pl = sub.add_parser("plan")
    pl.add_argument("--profile", required=True)

    tp = sub.add_parser("templates")
    tp.add_argument("--profile", required=True)
    tp.add_argument("--server", default=os.environ.get("GNS3_SERVER", "http://localhost"))
    tp.add_argument("--dry-run", action="store_true")

    args = ap.parse_args()
    return {"validate": cmd_validate, "plan": cmd_plan, "templates": cmd_templates}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main() or 0)
