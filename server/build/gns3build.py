#!/usr/bin/env python3
"""
gns3build.py — data-driven, idempotent GNS3 VM build.

Reads build/manifest.yml and drives node/template installation. Templates are registered
through the GNS3 REST API (POST /v2/templates), which is additive and idempotent —
existing template_ids are skipped — so there is no gns3_controller.conf text-assembly and
no `systemctl stop/start gns3`.

Subcommands
  validate                  parse the manifest + every referenced template .conf; report issues
  plan      --profile P     show what a full build of profile P would install (no changes)
  templates --profile P     register profile P's templates via the controller API
  docker    --profile P     build the profile's docker node images        [run on the VM]
  qemu      --profile P     download + unpack the profile's Qemu images   [run on the VM]
  accel                     Qemu acceleration in gns3_server.conf         [run on the VM]
  quiesce                   mask Ubuntu's unattended-upgrade timers       [run on the VM]
  logos                     install the CQU node symbols                  [run on the VM]
  novnc                     install noVNC + the gns3-novnc service        [run on the VM]
  projects  --profile P     import the .gns3project files named in projects.txt
  build     --profile P     every phase above, in order

Before cutting an OVA:
  export-check --profile P  fail unless the VM carries exactly projects.txt
  provenance   --profile P  record what this appliance actually contains

`validate`/`plan`/`templates`/`projects` work from anywhere (they take --server URL,
default $GNS3_SERVER or http://localhost). `docker`, `qemu`, `logos` and `novnc` touch the
local docker daemon and filesystem, so they run **on the GNS3 VM** — the Ansible wrapper
syncs this tree there and invokes them over SSH.

Profiles are amd64 and arm64, naming the architecture of the GNS3 VM: that picks the Docker
platform, the Qemu disks, the templates and any project variants. It is the only axis the
build varies on — one appliance per architecture goes to staff and students alike.

Every phase is idempotent: an image that already exists (docker) or a verified disk image
already in place (qemu) is skipped, so re-running is cheap. --force rebuilds/re-downloads,
--dry-run previews without writing.
"""
import argparse
import bz2
import configparser
import datetime
import gzip
import hashlib
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile
import zlib
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("PyYAML required: pip install pyyaml")

HERE = Path(__file__).resolve().parent
DEFAULT_MANIFEST = HERE / "manifest.yml"
REPO_ROOT = HERE.parents[1]          # <repo>/server/build/gns3build.py -> <repo>

# Written to the VM by `provenance --release`, so the appliance can say which release it
# is without opening a JSON file. os-release format: readable, and `. ` -sourceable.
RELEASE_FILE = "/etc/gns3-cqu-release"


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
    """Docker, Qemu then builtin node keys for a platform, in manifest order.

    `builtin` nodes install nothing — they are a template over a GNS3 built-in node type
    (the Windows Host is a Cloud node bound to the lab NIC). They appear here so the
    `templates` phase and `validate` pick their templates up; the `docker` and `qemu`
    phases select by kind and so ignore them.
    """
    p = m["platforms"][platform]
    return list(p.get("docker", [])) + list(p.get("qemu", [])) + list(p.get("builtin", []))


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


def select_nodes(m, platform, kind, only):
    """Node keys of `kind` ('docker'|'qemu') for a platform, optionally filtered by --only."""
    keys = list(m["platforms"][platform].get(kind, []))
    if only:
        wanted = [k.strip() for k in only.split(",") if k.strip()]
        unknown = [k for k in wanted if k not in keys]
        if unknown:
            sys.exit(f"--only: {', '.join(unknown)} not in platform '{platform}' {kind} list "
                     f"(have: {', '.join(keys)})")
        keys = [k for k in keys if k in wanted]
    for key in keys:
        if key not in m["nodes"]:
            sys.exit(f"platform '{platform}' references unknown node '{key}'")
    return keys


# --------------------------------------------------------------------------- #
# Shell / filesystem helpers
# --------------------------------------------------------------------------- #
def run(cmd, check=True, capture=False):
    """Run a command. Output streams to the console unless capture=True."""
    # Our stdout is block-buffered when piped (ssh/ansible); flush first so the child's
    # output doesn't overtake the log lines that introduce it.
    sys.stdout.flush()
    r = subprocess.run(cmd, stdout=subprocess.PIPE if capture else None,
                       stderr=subprocess.STDOUT if capture else None,
                       universal_newlines=True)
    if check and r.returncode != 0:
        out = f"\n{r.stdout}" if capture and r.stdout else ""
        raise RuntimeError(f"command failed ({r.returncode}): {' '.join(cmd)}{out}")
    return r


def _digest(path, algo, chunk=1 << 20):
    h = hashlib.new(algo)
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(chunk), b""):
            h.update(block)
    return h.hexdigest()


def md5_of(path, chunk=1 << 20):
    return _digest(path, "md5", chunk)


def sha256_of(path, chunk=1 << 20):
    return _digest(path, "sha256", chunk)


def dir_bytes(path):
    total = 0
    for root, _dirs, files in os.walk(str(path)):
        for name in files:
            try:
                total += os.lstat(os.path.join(root, name)).st_size
            except OSError:
                pass
    return total


def human(n):
    for unit in ("B", "KiB", "MiB", "GiB"):
        if n < 1024:
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024.0
    return f"{n:.1f} TiB"


def download(url, dest):
    """Fetch url -> dest with curl (preferred) or wget, retrying a few times."""
    dest = Path(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    # A progress bar is useful interactively but unreadable in an ansible/ssh log, so
    # only ask for one when stderr is a terminal.
    tty = sys.stderr.isatty()
    if shutil.which("curl"):
        cmd = ["curl", "-fL", "--retry", "3", "--retry-delay", "2",
               "-#" if tty else "-sS", "-o", str(dest), url]
    elif shutil.which("wget"):
        cmd = ["wget", "--tries=3", "--progress=bar" if tty else "-nv", "-O", str(dest), url]
    else:
        raise RuntimeError("neither curl nor wget found — cannot download")
    run(cmd)


def sudo_write(path, text):
    """Write a root-owned file; no-op if it already has this content."""
    p = Path(path)
    try:
        if p.read_text() == text:
            return False
    except OSError:
        pass
    subprocess.run(["sudo", "tee", str(p)], input=text, universal_newlines=True,
                   stdout=subprocess.DEVNULL, check=True)
    return True


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

    def update_template(self, template_id, body):
        # template_id is immutable and rejected in the body of a PUT.
        return self._req("PUT", f"/templates/{template_id}",
                         body={k: v for k, v in body.items() if k != "template_id"})

    def projects(self):
        return self._req("GET", "/projects")

    def project_nodes(self, project_id):
        return self._req("GET", f"/projects/{project_id}/nodes")

    # The compute is the machine that actually runs the nodes, so these two answer "does the
    # appliance have this image?" — the question `export-check` needs — rather than "does the
    # machine running this script have it?", which is a different question with the same shape.
    def qemu_images(self, compute_id="local"):
        return self._req("GET", f"/computes/{compute_id}/qemu/images")

    def docker_images(self, compute_id="local"):
        return self._req("GET", f"/computes/{compute_id}/docker/images")

    def import_project(self, project_id, path, timeout=3600):
        """POST a .gns3project as the raw body, streamed — SDN-Basics-Template is 729 MB."""
        url = f"{self.base}/v2/projects/{project_id}/import"
        size = Path(path).stat().st_size
        with open(str(path), "rb") as body:
            req = urllib.request.Request(url, data=body, method="POST")
            req.add_header("Content-Type", "application/octet-stream")
            req.add_header("Content-Length", str(size))
            with urllib.request.urlopen(req, timeout=timeout) as r:
                raw = r.read()
                return json.loads(raw) if raw else None


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

    # Host scripts installed to the VM must have a readable source relative to the manifest.
    for s in m.get("host_scripts", []):
        src = (m["_dir"] / s["src"]).resolve()
        if not src.is_file():
            problems.append(f"host_scripts: source not found: {src}")

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

    # Every disk/ISO a Qemu template names must be a file the node actually installs,
    # and the node's own disk must be referenced — otherwise the node fails to start
    # with an "image not found" long after the build.
    image_fields = ("hda_disk_image", "hdb_disk_image", "hdc_disk_image",
                    "hdd_disk_image", "cdrom_image")
    for key, node in m["nodes"].items():
        if node.get("kind") != "qemu":
            continue
        installs = {spec["file"] for spec in qemu_files(node)}
        for name in node.get("templates", []):
            try:
                t = read_template(m, name)
            except Exception:
                continue                       # already reported above
            needs = {t.get(f) for f in image_fields if t.get(f)}
            for missing in sorted(needs - installs):
                problems.append(f"qemu node '{key}': template '{name}' needs '{missing}' "
                                f"but the node installs {sorted(installs)}")
            if node["file"] not in needs:
                problems.append(f"qemu node '{key}': template '{name}' does not reference "
                                f"{node['file']} (has {sorted(needs)})")

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

    # The novnc service ships three files. A rename that missed the manifest would otherwise
    # only surface an hour into a build, on the VM, at the phase that installs them.
    svc = (m.get("novnc") or {}).get("service") or {}
    if svc:
        src_dir = (m["_dir"] / svc.get("dir", "../novnc")).resolve()
        for f in ("gns3_vnc_console.py", "index.html",
                  svc.get("unit", "gns3-novnc.service")):
            if not (src_dir / f).exists():
                problems.append(f"novnc service: missing {src_dir / f}")

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
    p = m["platforms"][platform]
    print(f"profile {args.profile}  (platform: {platform}, "
          f"docker --platform {p.get('docker_platform', '?')})\n")
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
    builtin = m["platforms"][platform].get("builtin", [])
    if builtin:
        print("\nBuilt-in nodes (template only, nothing to install):")
        for key in builtin:
            print(f"  {key}")
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
        # Registration is keyed on template_id, so an edited .conf does NOT reach a
        # controller that already has that id — the phase would report "skip" and leave the
        # old definition in place. --force pushes the file over the top instead.
        if tid in existing and not args.force:
            print(f"  skip   {name:22} (already registered: {body.get('name')})")
            skipped += 1
            continue
        if args.dry_run:
            verb = "update" if tid in existing else "register"
            print(f"  +{verb.upper()[:5]:5} {name:22} (would {verb} '{body.get('name')}' {tid})")
            created += 1
            continue
        try:
            if tid in existing:
                ctrl.update_template(tid, body)
                print(f"  update {name:22} ('{body.get('name')}')")
            else:
                ctrl.add_template(body)
                print(f"  create {name:22} ('{body.get('name')}')")
            created += 1
        except urllib.error.HTTPError as e:
            print(f"  ERROR  {name}: HTTP {e.code} {e.read().decode(errors='replace')[:200]}")
            failed += 1

    verb = "would register" if args.dry_run else "registered"
    print(f"\n{verb} {created}, skipped {skipped}, failed {failed}")
    if created and not args.dry_run:
        print("  note: existing nodes keep the settings they were created with — "
              "a changed template only affects nodes made after it")
    return 1 if failed else 0


# --------------------------------------------------------------------------- #
# Phase: docker — build the node images (runs on the VM)
# --------------------------------------------------------------------------- #
def image_exists(image):
    return subprocess.run(["docker", "image", "inspect", image],
                          stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode == 0


def _frozen_images(m, profile, only):
    """The docker images a profile ships, in build order."""
    platform = profile_platform(m, profile)
    keys = select_nodes(m, platform, "docker", only)
    return keys, [m["nodes"][k]["image"] for k in keys]


def cmd_freeze(args):
    """`docker save` the built image set to one archive, with a provenance sidecar.

    WHY THIS EXISTS. Pinning inputs (registry_base, base-image digests, package versions) makes a
    rebuild *likely* to reproduce. Freezing the output makes it *certain*, and it is the only one
    of the two that survives an upstream disappearing — which, over a multi-year appliance life,
    is the more probable failure. A frozen archive rebuilds the appliance with no network at all.

    Use it as the release artefact beside the OVA: build, verify, freeze, and keep the archive.
    A later rebuild is `thaw` + the non-docker phases, not `docker`.
    """
    m = load_manifest(args.manifest)
    keys, images = _frozen_images(m, args.profile, args.only)

    print(f"profile {args.profile} — {len(images)} image(s)\n")
    missing = [i for i in images if not image_exists(i)]
    if missing:
        sys.exit("these images are not built here, so there is nothing to freeze:\n  "
                 + "\n  ".join(missing)
                 + "\n\nRun the `docker` phase first — freeze captures what a VERIFIED build "
                   "produced, and freezing a half-built set is worse than not freezing.")

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    for key, image in zip(keys, images):
        print(f"  {key:14} {image}")
    if args.dry_run:
        print(f"\n[dry-run] docker save -> {out}")
        return

    # Stream through gzip rather than saving then compressing: the uncompressed set is several
    # GB and a VM with room for one copy may not have room for two.
    print(f"\nsaving -> {out} ...")
    sys.stdout.flush()
    proc = subprocess.Popen(["docker", "save"] + images, stdout=subprocess.PIPE)
    try:
        if str(out).endswith(".gz"):
            with gzip.open(str(out), "wb", compresslevel=6) as fout:
                shutil.copyfileobj(proc.stdout, fout, length=1 << 20)
        else:
            with open(str(out), "wb") as fout:
                shutil.copyfileobj(proc.stdout, fout, length=1 << 20)
    finally:
        proc.stdout.close()
        rc = proc.wait()
    if rc != 0:
        sys.exit(f"docker save failed ({rc}); {out} is incomplete — delete it")

    digest = sha256_of(out)
    side = Path(str(out) + ".json")
    # Image IDs, not just names: two archives can carry the same :latest tags and different
    # bytes, and the whole point of this file is to say which bytes.
    ids = {}
    for image in images:
        r = subprocess.run(["docker", "image", "inspect", "-f", "{{.Id}}", image],
                           stdout=subprocess.PIPE, universal_newlines=True)
        ids[image] = r.stdout.strip() if r.returncode == 0 else "?"
    side.write_text(json.dumps({
        "profile": args.profile,
        # timezone-aware: utcnow() is deprecated from Python 3.12 and prints a warning into
        # the build log. (The `provenance` phase still uses the old form — same fix applies.)
        "created": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "archive": out.name,
        "bytes": out.stat().st_size,
        "sha256": digest,
        "images": ids,
    }, indent=2) + "\n")

    print(f"\nfroze {len(images)} image(s)")
    print(f"  archive  {out}  ({human(out.stat().st_size)})")
    print(f"  sha256   {digest}")
    print(f"  manifest {side}")
    print("\nKeep BOTH files with the OVA. Restore with:  gns3build.py thaw --in " + str(out))


def cmd_thaw(args):
    """`docker load` a frozen archive back onto a VM, then confirm the set is complete."""
    m = load_manifest(args.manifest)
    src = Path(args.inp)
    if not src.exists():
        sys.exit(f"no such archive: {src}")

    side = Path(str(src) + ".json")
    meta = json.loads(side.read_text()) if side.exists() else {}
    if meta:
        print(f"archive from {meta.get('created','?')} (profile {meta.get('profile','?')}), "
              f"{len(meta.get('images', {}))} image(s)")
    else:
        print(f"no sidecar {side.name} — loading anyway, but provenance is unknown")

    if not args.skip_verify and meta.get("sha256"):
        print("verifying archive sha256 ...")
        got = sha256_of(src)
        if got != meta["sha256"]:
            sys.exit(f"archive sha256 mismatch\n  expected {meta['sha256']}\n  got      {got}\n"
                     "The archive is corrupt or is not the one the sidecar describes.")
        print("  ok")

    if args.dry_run:
        print(f"[dry-run] docker load -i {src}")
        return

    print(f"loading {src} ...")
    run(["docker", "load", "-i", str(src)])

    # A load that silently dropped an image is the failure worth catching: everything downstream
    # then builds fine and one node type is simply absent.
    expected = list(meta.get("images", {})) or _frozen_images(m, args.profile, None)[1]
    missing = [i for i in expected if not image_exists(i)]
    print()
    for image in expected:
        print(f"  {'ok  ' if image not in missing else 'MISS'} {image}")
    if missing:
        sys.exit(f"\n{len(missing)} image(s) missing after load — the archive is incomplete")
    print(f"\nloaded {len(expected)} image(s). The `docker` phase can now be skipped.")


def ensure_kernel_modules(mods, dry_run):
    """Docker nodes share the VM's kernel: load what they need, and persist it across reboots."""
    for mod in mods:
        conf = f"/etc/modules-load.d/{mod}.conf"
        if dry_run:
            print(f"  [dry-run] modprobe {mod}; persist to {conf}")
            continue
        ok = subprocess.run(["sudo", "modprobe", mod],
                            stderr=subprocess.DEVNULL).returncode == 0
        sudo_write(conf, mod + "\n")
        state = "loaded" if ok else "UNAVAILABLE (nodes needing it will not work)"
        print(f"  module {mod:12} {state}")


def install_host_scripts(m, dry_run):
    """Install helper scripts the VM HOST needs (not a node) to /usr/local/bin, executable.

    Some node features have a host-side companion that a container cannot provide from inside its
    own namespace -- e.g. the wireless nodes need `gns3-wifi-attach` to move a simulated radio into
    each node after the topology starts. Listed in the manifest's `host_scripts:` so a fresh
    appliance carries them; idempotent (sudo_write no-ops when the content already matches)."""
    scripts = m.get("host_scripts", [])
    if not scripts:
        return
    print("\nHost scripts:")
    for s in scripts:
        src = (m["_dir"] / s["src"]).resolve()
        dst = s["dst"]
        if dry_run:
            print(f"  [dry-run] install {src.name} -> {dst} (0755)")
            continue
        try:
            text = src.read_text()
        except OSError as e:
            print(f"  FAIL   {dst}: cannot read {src} ({e})")
            continue
        changed = sudo_write(dst, text)
        subprocess.run(["sudo", "chmod", "0755", dst], check=False)
        print(f"  {'installed' if changed else 'current  '}  {dst}")


def docker_context(m, node, tmpdir):
    """Build-context directory for a node; registry sources are fetched into tmpdir."""
    src = node["source"]
    if src["type"] == "local":
        ctx = (m["_dir"] / m["paths"]["docker_dir"] / src["path"]).resolve()
        if not (ctx / "Dockerfile").exists():
            raise FileNotFoundError(f"no Dockerfile in build context {ctx}")
        return ctx
    if src["type"] == "registry":
        ctx = Path(tmpdir)
        base = m["registry_base"].rstrip("/") + "/" + src["dir"].strip("/")
        for entry in src["files"]:
            # An entry is either a bare filename or {name, sha256}. Both forms are accepted so
            # a new file can be added without a checksum while it is being worked out, but a
            # release build should have one on every line — see registry_base's note.
            fname = entry if isinstance(entry, str) else entry["name"]
            want = None if isinstance(entry, str) else entry.get("sha256")
            dest = ctx / fname
            download(f"{base}/{fname}", dest)
            if want:
                got = sha256_of(dest)
                if got != want:
                    raise RuntimeError(
                        f"{fname}: sha256 mismatch from {base}/{fname}\n"
                        f"  expected {want}\n  got      {got}\n"
                        f"Upstream moved, or registry_base is not pinned to the commit these "
                        f"checksums were taken at. Do NOT just paste the new value in: read the "
                        f"diff first, then re-run the OVS activities if openvswitch changed.")
            else:
                print(f"    WARN {fname}: no sha256 in the manifest — build is not reproducible")
            # HTTP carries no permission bits, so a downloaded script lands 0644/0664 and
            # the image ships it non-executable. Normally the upstream Dockerfile's
            # `RUN chmod +x` would fix that — but gns3/openvswitch declares
            # `VOLUME ["/root", "/etc/openvswitch"]` BEFORE it copies init.sh there, and
            # Docker discards RUN changes made to an already-declared VOLUME path. The
            # chmod is silently thrown away, the container's CMD hits "Permission denied",
            # it exits 126 before building any bridge, and every OVS activity fails with
            # "container is not running" (found 14 Aug 2026 via a stp-basics FAIL; the
            # same symptom for saved projects is in gns3-dev/tools/tests/ovs-init-perms-fix.md).
            # COPY *does* preserve the source mode, so setting it here survives — verified
            # on Docker 29.6.2 against all three variants of the Dockerfile ordering.
            if fname.endswith(".sh"):
                dest.chmod(0o755)
        return ctx
    raise ValueError(f"unknown source type '{src['type']}'")


def cmd_docker(args):
    m = load_manifest(args.manifest)
    platform = profile_platform(m, args.profile)
    keys = select_nodes(m, platform, "docker", args.only)
    docker_platform = m["platforms"][platform].get("docker_platform")
    if not docker_platform:
        sys.exit(f"platform '{platform}': manifest has no docker_platform")
    have_docker = bool(shutil.which("docker"))
    if not have_docker and not args.dry_run:
        sys.exit("docker not found — the `docker` phase must run on the GNS3 VM")

    print(f"profile {args.profile}  (platform: {platform}, --platform {docker_platform})")
    print(f"{len(keys)} image(s): {', '.join(keys)}\n")
    if not have_docker:
        print("note: no docker here, so this dry run cannot tell which images already exist\n")

    print("Kernel modules:")
    ensure_kernel_modules(m.get("kernel_modules", []), args.dry_run)
    install_host_scripts(m, args.dry_run)

    print("\nImages:")
    built = skipped = 0
    failures = []
    for key in keys:
        node = m["nodes"][key]
        image = node["image"]
        if have_docker and not args.force and image_exists(image):
            print(f"  skip   {key:14} {image} (already built)")
            skipped += 1
            continue
        src = node["source"]
        where = src.get("path") or src.get("dir")
        if args.dry_run:
            print(f"  [dry-run] build {image} <- {src['type']}:{where}")
            built += 1
            continue
        print(f"\n=== {key}: building {image} <- {src['type']}:{where}")
        tmpdir = tempfile.mkdtemp(prefix="gns3build-")
        try:
            ctx = docker_context(m, node, tmpdir)
            cmd = ["docker", "build", "--platform", docker_platform, "-t", image]
            for k, v in (node.get("build_args") or {}).items():
                cmd += ["--build-arg", f"{k}={v}"]
            cmd.append(str(ctx))
            run(cmd)
            built += 1
            print(f"=== {key}: OK")
        except Exception as e:
            print(f"=== {key}: FAILED — {e}")
            failures.append(key)
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)

    verb = "would build" if args.dry_run else "built"
    print(f"\n{verb} {built}, skipped {skipped}, failed {len(failures)}"
          + (f" ({', '.join(failures)})" if failures else ""))
    return 1 if failures else 0


# --------------------------------------------------------------------------- #
# Phase: qemu — download + unpack the disk images (runs on the VM)
# --------------------------------------------------------------------------- #
ARCHIVE_EXT = {"gzip": ".gz", "bzip2": ".bz2", "zip": ".zip"}


def stream_decompress(archive, dest, kind):
    """Decompress concatenated members, ignoring trailing non-member bytes.

    This mirrors `gzip -d` / `bzip2 -d`, which warn about trailing garbage and keep the
    data — the stdlib's gzip/bz2 file objects raise instead. It matters: OpenWrt appends
    a 34-byte "# fake certificate" signature after the gzip stream of its combined
    images, so `gzip.open()` cannot read them at all. The manifest md5 (taken over the
    decompressed member, as the legacy script did) is what verifies we got it right.
    """
    if kind == "gzip":
        magic, new_decoder = b"\x1f\x8b", lambda: zlib.decompressobj(16 + zlib.MAX_WBITS)
    else:
        magic, new_decoder = b"BZh", bz2.BZ2Decompressor

    size = archive.stat().st_size
    dec, trailing = new_decoder(), 0
    with open(str(archive), "rb") as fin, open(str(dest), "wb") as fout:
        buf = fin.read(1 << 20)
        while buf:
            fout.write(dec.decompress(buf))
            if not dec.eof:
                buf = fin.read(1 << 20)
                continue
            buf = dec.unused_data + fin.read(1 << 20)   # member ended — another one?
            if not buf.startswith(magic):
                trailing = len(buf) + (size - fin.tell())
                break
            dec = new_decoder()
        if not dec.eof:
            raise RuntimeError(f"{archive.name}: truncated {kind} stream")
    if trailing:
        print(f"  note   ignored {trailing} trailing byte(s) after the {kind} stream")


def decompress(archive, dest, kind):
    """Unpack archive -> dest. Stdlib only, so no zip/unzip packages are needed."""
    if kind != "zip":
        return stream_decompress(archive, dest, kind)
    with zipfile.ZipFile(str(archive)) as z:
        names = [n for n in z.namelist() if not n.endswith("/")]
        member = dest.name if dest.name in names else (names[0] if len(names) == 1 else None)
        if member is None:
            raise RuntimeError(f"{archive.name}: cannot pick a member for {dest.name} "
                               f"among {names}")
        with z.open(member) as fin, open(str(dest), "wb") as fout:
            shutil.copyfileobj(fin, fout, 1 << 20)


def qemu_files(node):
    """Every file a qemu node installs: the disk itself plus any companion `extra`.

    Companions are things a template needs alongside the disk but that are not the disk —
    the Ubuntu cloud image's cloud-init ISO (the template's cdrom_image) being the case
    that exists today.
    """
    return [node] + list(node.get("extra") or [])


def install_qemu_file(spec, images_dir, force, verify, dry_run):
    """Ensure one file is present and verified. Returns 'installed'|'skipped'."""
    node = spec
    dest = images_dir / node["file"]
    sidecar = Path(str(dest) + ".md5sum")
    want = node.get("md5")

    if dest.exists() and not force:
        # The sidecar records the md5 of the verified download. Trusting it avoids
        # re-hashing gigabytes every run, and is the only workable check for images
        # that `resize` mutates after verification. --verify forces a real re-hash.
        trusted = (want and not verify and sidecar.exists()
                   and sidecar.read_text().strip() == want)
        if trusted or (md5_of(dest) == want if want else True):
            if want and not sidecar.exists():
                sidecar.write_text(want)
            how = "sidecar" if trusted else ("md5 ok" if want else "present")
            print(f"  skip   {node['file']:52} ({how}, {human(dest.stat().st_size)})")
            return "skipped"
        print(f"  stale  {node['file']} — md5 mismatch, re-downloading")

    if dry_run:
        print(f"  [dry-run] download {node['url']}")
        return "installed"

    unpack = node.get("unpack") or "none"
    if unpack != "none" and unpack not in ARCHIVE_EXT:
        raise ValueError(f"unknown unpack '{unpack}' (want {'|'.join(ARCHIVE_EXT)}|none)")

    images_dir.mkdir(parents=True, exist_ok=True)
    # Stage inside images_dir so the final move is a same-filesystem rename, not a
    # multi-GB copy, and so a failed run leaves no half-written image behind.
    tmpdir = tempfile.mkdtemp(prefix=".gns3build-", dir=str(images_dir))
    try:
        staged = Path(tmpdir) / dest.name
        if unpack == "none":
            print(f"  fetch  {node['file']}")
            download(node["url"], staged)
        else:
            archive = Path(tmpdir) / (dest.name + ARCHIVE_EXT[unpack])
            print(f"  fetch  {node['file']} ({unpack})")
            download(node["url"], archive)
            print(f"  unpack {archive.name} -> {dest.name}")
            decompress(archive, staged, unpack)
            archive.unlink()
        got = md5_of(staged)
        if want and got != want:
            raise RuntimeError(f"md5 mismatch: got {got}, manifest says {want}")
        shutil.move(str(staged), str(dest))
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    if node.get("resize"):
        print(f"  resize {dest.name} {node['resize']}")
        run(["qemu-img", "resize", str(dest), str(node["resize"])])

    sidecar.write_text(want or got)
    print(f"  ok     {node['file']:52} ({human(dest.stat().st_size)})")
    return "installed"


def qemu_install(node, images_dir, force, verify, dry_run):
    """Install a qemu node's disk and its companion files. Returns 'installed'|'skipped'."""
    results = [install_qemu_file(spec, images_dir, force, verify, dry_run)
               for spec in qemu_files(node)]
    return "installed" if "installed" in results else "skipped"


def cmd_qemu(args):
    m = load_manifest(args.manifest)
    platform = profile_platform(m, args.profile)
    keys = select_nodes(m, platform, "qemu", args.only)
    images_dir = Path(args.images_dir or m.get("qemu_images_dir", "/opt/gns3/images/QEMU"))

    print(f"profile {args.profile}  (platform: {platform}, images: {images_dir})")
    print(f"{len(keys)} image(s): {', '.join(keys) or '-'}\n")

    installed = skipped = 0
    failures = []
    for key in keys:
        try:
            if qemu_install(m["nodes"][key], images_dir, args.force,
                            args.verify, args.dry_run) == "skipped":
                skipped += 1
            else:
                installed += 1
        except Exception as e:
            print(f"  ERROR  {key}: {e}")
            failures.append(key)

    verb = "would install" if args.dry_run else "installed"
    print(f"\n{verb} {installed}, skipped {skipped}, failed {len(failures)}"
          + (f" ({', '.join(failures)})" if failures else ""))
    return 1 if failures else 0


# --------------------------------------------------------------------------- #
# Phase: logos — install the CQU node symbols (runs on the VM)
# --------------------------------------------------------------------------- #
SYMBOLS_GLOBS = (
    "~/.venv/*/lib/python3*/site-packages/gns3server/symbols",
    "/opt/gns3/.venv/*/lib/python3*/site-packages/gns3server/symbols",
    "/usr/lib/python3/dist-packages/gns3server/symbols",
    "/usr/local/lib/python3*/*-packages/gns3server/symbols",
)


def find_symbols_dir():
    """Locate gns3server's symbols dir, preferring the `classic` set the templates use.

    Globbed rather than hardcoded: the legacy script's `python3.9` path is right on the
    current VM purely by luck and breaks on any other gns3server build.
    """
    import glob as _glob
    found = []
    for pattern in SYMBOLS_GLOBS:
        found += sorted(_glob.glob(os.path.expanduser(pattern)))
    if not found:
        raise RuntimeError("could not find gns3server's symbols directory "
                           f"(looked in: {', '.join(SYMBOLS_GLOBS)})")
    base = Path(found[0])
    return base / "classic" if (base / "classic").is_dir() else base


def cmd_logos(args):
    m = load_manifest(args.manifest)
    src = Path(args.symbols_dir) if args.symbols_dir else \
        (m["_dir"] / m["paths"]["symbols_dir"]).resolve()
    if not src.is_dir():
        sys.exit(f"symbols source dir not found: {src}")
    svgs = sorted(src.glob("*.svg"))
    if not svgs:
        sys.exit(f"no .svg files in {src}")

    try:
        dest = Path(args.dest) if args.dest else find_symbols_dir()
    except RuntimeError as e:
        sys.exit(str(e))
    print(f"symbols {src}  ->  {dest}")
    print(f"{len(svgs)} logo(s)\n")

    copied = skipped = 0
    for svg in svgs:
        target = dest / svg.name
        if target.exists() and target.read_bytes() == svg.read_bytes():
            skipped += 1
            continue
        if args.dry_run:
            print(f"  [dry-run] copy {svg.name}")
        else:
            shutil.copyfile(str(svg), str(target))
            print(f"  copy   {svg.name}")
        copied += 1
    if skipped:
        print(f"  skip   {skipped} logo(s) already identical")

    # End-state check: every symbol our templates name must now resolve on disk. This
    # catches both a missing CQU logo and a template pointing at a built-in that this
    # gns3server does not ship.
    missing = []
    if not args.dry_run:
        for platform in m["platforms"]:
            for name in template_names(m, platform):
                try:
                    sym = read_template(m, name).get("symbol", "")
                except Exception:
                    continue
                if sym.startswith(":/symbols/classic/"):
                    leaf = sym.split("/")[-1]
                    if not (dest / leaf).exists() and leaf not in missing:
                        missing.append(leaf)
        if missing:
            print(f"\n  WARN   template symbol(s) not present in {dest}: {', '.join(missing)}")

    if args.dry_run:
        print(f"\nwould copy {copied}, skipped {skipped}")
    else:
        print(f"\ncopied {copied}, skipped {skipped}, template symbols missing {len(missing)}")
    return 0


# --------------------------------------------------------------------------- #
# Phase: quiesce — stop the appliance updating itself          [run on the VM]
# --------------------------------------------------------------------------- #
# systemctl's own vocabulary. Anything outside it is not a verdict we can act on — a
# container's systemd stub, for one, answers `is-enabled` with a paragraph of advice.
_UNIT_STATES = {"masked", "masked-runtime", "enabled", "enabled-runtime", "disabled",
                "static", "indirect", "generated", "transient", "alias", "linked",
                "linked-runtime", "not-found"}


def unit_state(unit):
    """`systemctl is-enabled` verdict for one unit: masked / enabled / disabled / absent."""
    try:
        r = subprocess.run(["systemctl", "is-enabled", unit],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           universal_newlines=True)
    except OSError:                              # no systemctl at all
        return "unknown"
    if "No such file" in (r.stderr or ""):
        return "absent"
    first = next((ln.strip() for ln in (r.stdout or "").splitlines() if ln.strip()), "")
    if first == "not-found":                     # newer systemd says it on stdout instead
        return "absent"
    return first if first in _UNIT_STATES else "unknown"


def cmd_quiesce(args):
    """Mask Ubuntu's unattended-upgrade timers so the appliance stops rewriting itself.

    See the `auto_updates:` comment in the manifest for the incident that prompted this. The
    short version: an appliance is meant to be the thing that was tested, and a machine that
    upgrades libc6 and the kernel behind your back on first boot is not that. It also steals
    the CPU — this VM has one core — for minutes at a time, which on a lab machine lands as a
    node that mysteriously stops responding mid-activity.

    `mask` rather than `disable`: disable leaves the unit startable, and an apt upgrade of
    unattended-upgrades or systemd re-enables what it shipped enabled. A masked unit is
    symlinked to /dev/null and stays masked across upgrades.
    """
    m = load_manifest(args.manifest)
    cfg = m.get("auto_updates") or {}
    units = cfg.get("mask_units") or []
    if not units:
        print("  skip   no auto_updates.mask_units in the manifest")
        return 0

    print("auto-updates: masking Ubuntu's own upgrade schedule\n")
    changed = failed = 0
    for unit in units:
        state = unit_state(unit)
        if state == "masked":
            print(f"  skip   {unit} (already masked)")
            continue
        if state == "absent":
            # Not an error: unattended-upgrades is not installed on every Ubuntu variant, and
            # a unit that does not exist cannot start an upgrade.
            print(f"  none   {unit} is not installed on this VM")
            continue
        if args.dry_run:
            print(f"  [dry-run] systemctl mask --now {unit} (currently {state})")
            continue
        # --now also stops it, so an upgrade already in flight is halted rather than left to
        # finish under the build.
        rc = subprocess.run(["sudo", "systemctl", "mask", "--now", unit],
                            stdout=subprocess.DEVNULL).returncode
        if rc:
            print(f"  FAIL   could not mask {unit} (rc={rc})")
            failed += 1
        else:
            print(f"  mask   {unit} (was {state})")
            changed += 1

    path = cfg.get("apt_periodic_file", "/etc/apt/apt.conf.d/99-cqu-no-auto-upgrades")
    text = (
        '// Installed by gns3build.py (quiesce phase) — do not edit by hand.\n'
        '//\n'
        '// Turns off the periodic apt work that /etc/apt/apt.conf.d/20auto-upgrades enables.\n'
        '// The units are masked as well; this file is what survives an apt upgrade putting\n'
        '// 20auto-upgrades back, since apt reads this directory in lexical order and the last\n'
        '// setting of a key wins.\n'
        '//\n'
        '// Updating the appliance is a build-time decision: rebuild from the manifest and cut\n'
        '// a new OVA, so what students run is what was tested.\n'
        'APT::Periodic::Enable "0";\n'
        'APT::Periodic::Update-Package-Lists "0";\n'
        'APT::Periodic::Unattended-Upgrade "0";\n'
        'APT::Periodic::Download-Upgradeable-Packages "0";\n'
        'APT::Periodic::AutocleanInterval "0";\n'
    )
    if args.dry_run:
        print(f"\n  [dry-run] write {path}")
    elif sudo_write(path, text):
        subprocess.run(["sudo", "chmod", "644", path], check=False)
        print(f"\n  write  {path}")
        changed += 1
    else:
        print(f"\n  skip   {path} (already correct)")

    # An upgrade that already ran leaves the VM running one kernel with another installed.
    # Exporting in that state ships an appliance whose first boot changes it — exactly what
    # this phase exists to prevent — so say so loudly enough to act on.
    if Path("/var/run/reboot-required").exists():
        pkgs = ""
        try:
            pkgs = Path("/var/run/reboot-required.pkgs").read_text().split()
            pkgs = " (" + ", ".join(sorted(set(pkgs))) + ")" if pkgs else ""
        except OSError:
            pass
        print(f"\n  WARN   this VM has a pending reboot{pkgs}")
        print("         An upgrade has already been applied under the running system. Reboot "
              "before")
        print("         running export-check, or the OVA ships a machine that changes on first "
              "boot.")

    if not args.dry_run:
        print(f"\nquiesced: {changed} change(s), {failed} failure(s)")
    return 1 if failed else 0


# --------------------------------------------------------------------------- #
# Phase: novnc — browser access to VNC nodes (runs on the VM)
# --------------------------------------------------------------------------- #
def apt_installed(pkg):
    r = subprocess.run(["dpkg-query", "-W", "-f=${Status}", pkg],
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                       universal_newlines=True)
    return r.returncode == 0 and "install ok installed" in (r.stdout or "")


def cmd_labnic(args):
    """Stop the GNS3 VM being a DHCP client on the lab network.

    The VM's third adapter sits on an isolated hypervisor network shared with a Windows VM
    running beside it, and a Cloud node bound to that interface bridges it into a topology.

    The stock appliance already declares eth2..eth8 in 80_gns3vm_default_netcfg.yaml, so the
    interface comes up on its own — but with `dhcp4: yes`. That is wrong here, and quietly so:
    the Cloud node bridges the *topology* onto this interface, so the moment an activity runs
    a DHCP server (dhcp-server-basics, dhcp-client, any OpenWrt LAN) the GNS3 VM itself takes
    a lease from the student's lab. It then shows up as an unexplained extra host, consumes an
    address the student believes is free, and answers ARP for it.

    So this phase writes a later-sorting netplan file that turns DHCP off for that one
    interface. Netplan merges files in lexical order, last definition winning, which is why
    the name must sort after the appliance's own 80_/90_ files.

    `optional: true` is kept from the stock config: without it systemd-networkd-wait-online
    blocks boot for its full timeout whenever the adapter is not connected to anything.
    """
    m = load_manifest(args.manifest)
    cfg = m.get("lab_nic") or {}
    iface = args.interface or cfg.get("interface", "eth2")
    path = args.netplan_file or cfg.get("netplan_file", "/etc/netplan/95-cqu-lab-nic.yaml")

    text = (
        "# Installed by gns3build.py (labnic phase) — do not edit by hand.\n"
        "#\n"
        "# The lab NIC: an isolated hypervisor network shared with a Windows VM running\n"
        "# beside this one. A GNS3 Cloud node binds this interface raw, so it carries the\n"
        "# topology's own addressing and must NOT have an address of its own here.\n"
        "#\n"
        "# This overrides 80_gns3vm_default_netcfg.yaml, which sets dhcp4: yes on eth2..eth8.\n"
        "# Left alone, the GNS3 VM takes a DHCP lease from the student's own topology as soon\n"
        "# as an activity runs a DHCP server. The filename must keep sorting AFTER the\n"
        "# appliance's own netplan files — netplan merges in lexical order, last one wins.\n"
        "network:\n"
        "  version: 2\n"
        "  ethernets:\n"
        f"    {iface}:\n"
        "      dhcp4: false\n"
        "      dhcp6: false\n"
        "      optional: true\n"
    )

    print(f"lab NIC {iface}  ->  {path}")

    if args.dry_run:
        print(f"  [dry-run] write {path}")
        print(f"  [dry-run] ip link set {iface} up")
        return 0

    if sudo_write(path, text):
        # 0644, matching the appliance's own netplan files. NOT 0600: sudo_write compares the
        # file's current contents by reading it as the build user, so a root-only file is
        # unreadable, every run looks like a change, and the phase stops being idempotent.
        # These files hold no secrets, so there is nothing to protect by tightening them.
        subprocess.run(["sudo", "chmod", "644", path], check=False)
        print(f"  write  {path}")
    else:
        print(f"  skip   {path} (already correct)")

    # Deliberately NOT `netplan apply`: it can bounce every interface, and this phase runs
    # over ssh on eth0 — taking that down mid-build would kill the connection driving it.
    # Writing the file covers every future boot; `ip link set … up` covers this one.
    if not Path(f"/sys/class/net/{iface}").exists():
        print(f"  INFO   {iface} is not present on this VM")
        print(f"         Nothing is wrong: the appliance ships the config, and the interface")
        print(f"         appears once a third adapter is attached to the VM. See the Windows")
        print(f"         Host section of server/README.md.")
        return 0

    rc = subprocess.run(["sudo", "ip", "link", "set", iface, "up"]).returncode
    if rc != 0:
        print(f"  WARN   could not bring {iface} up (rc={rc})")
        return 1

    # `ip -br link show eth2` -> "eth2  UP  08:00:27:b9:99:3f <BROADCAST,MULTICAST,UP,...>"
    fields = (_cmd_out(["ip", "-br", "link", "show", iface]) or "").split()
    link_state = fields[1] if len(fields) > 1 else "?"
    mac = fields[2] if len(fields) > 2 else "?"
    print(f"  link   {iface} {link_state}  mac {mac}")
    print(f"  note   DHCP is off for {iface} from the next boot; a Cloud node bound to it "
          f"carries the topology's own addressing")
    return 0


# --------------------------------------------------------------------------- #
# Phase: accel — Qemu hardware acceleration in gns3_server.conf   [run on the VM]
# --------------------------------------------------------------------------- #
def config_from_cmdline():
    """The `--config` path of the running gns3server, or None.

    Read from /proc rather than from a constant, because the constant has already gone stale
    once. The GNS3 VM up to 2.2.54 left gns3server on its default user path; the 2.2.61 VM
    runs it from a venv with an explicit `--config /opt/gns3/server/gns3_server.conf` — and
    an explicit --config makes that file the *only* one loaded, so anything written to the
    old path is read by nobody. The running process is the one answer that cannot be wrong.
    """
    for cmdline in Path("/proc").glob("[0-9]*/cmdline"):
        try:
            argv = cmdline.read_bytes().decode("utf-8", "replace").split("\0")
        except OSError:
            continue                      # the process exited while we were walking /proc
        if not any(a.endswith("gns3server") for a in argv):
            continue
        for i, a in enumerate(argv):
            if a.startswith("--config="):
                return a.split("=", 1)[1]
            if a == "--config" and i + 1 < len(argv):
                return argv[i + 1]
    return None


def config_from_unit(unit="gns3.service"):
    """The `--config` path in gns3.service's ExecStart, or None.

    The fallback for a build run while the GNS3 service is down — `systemctl cat` reads the
    unit file, so it answers whether or not anything is running. `_cmd_out` returns None
    where there is no systemctl at all, which is the normal case on a Mac control node.
    """
    out = _cmd_out(["systemctl", "cat", unit])
    if not out:
        return None
    for line in out.splitlines():
        if not line.strip().startswith("ExecStart"):
            continue
        argv = line.split("=", 1)[-1].split()
        for i, a in enumerate(argv):
            if a.startswith("--config="):
                return a.split("=", 1)[1]
            if a == "--config" and i + 1 < len(argv):
                return argv[i + 1]
    return None


def server_config_path(fallback):
    """(path, how) for the gns3_server.conf the server on this VM actually reads.

    `fallback` is the manifest's `qemu_accel.config_file` — used only when nothing on the VM
    names a config file, which on a stock appliance means gns3server is on its built-in
    default path. Discovery wins over the manifest deliberately: a hardcoded path is exactly
    what broke here, and a phase that writes a file nobody reads reports success while
    changing nothing.
    """
    for how, found in (("process", config_from_cmdline()), ("unit", config_from_unit())):
        if found:
            return Path(os.path.expanduser(found)), how
    return Path(os.path.expanduser(fallback)), "manifest"


def ini_set(text, section, settings):
    """Set key=value inside an INI section, returning the new text.

    A surgical line edit rather than configparser, which would drop comments and rewrite
    sections it was not asked to touch. This file is also hand-edited when someone follows a
    troubleshooting note, so leaving the rest of it byte-identical matters.

    Keys already present in the section are replaced in place; missing ones are appended to
    the end of the section; a missing section is appended to the file.
    """
    lines = text.splitlines()
    head = f"[{section}]"
    start = next((i for i, ln in enumerate(lines) if ln.strip() == head), None)

    if start is None:
        block = [""] if (lines and lines[-1].strip()) else []
        block += [head] + [f"{k} = {v}" for k, v in settings.items()]
        return "\n".join(lines + block) + "\n"

    end = next((i for i in range(start + 1, len(lines))
                if lines[i].lstrip().startswith("[")), len(lines))
    for key, value in settings.items():
        for i in range(start + 1, end):
            bare = lines[i].split("#", 1)[0]
            if "=" in bare and bare.split("=", 1)[0].strip().lower() == key.lower():
                lines[i] = f"{key} = {value}"
                break
        else:
            # Append after the section's last non-blank line, so a blank separating this
            # section from the next one stays where it is.
            at = end
            while at > start + 1 and not lines[at - 1].strip():
                at -= 1
            lines.insert(at, f"{key} = {value}")
            end += 1
    return "\n".join(lines) + "\n"


def cmd_accel(args):
    """Write the [Qemu] acceleration settings that keep Qemu nodes startable everywhere.

    See the long comment on `qemu_accel:` in the manifest for why `require_kvm` and not
    `enable_kvm`. Nothing is restarted: gns3server watches its config files and reloads.

    The file is *discovered*, not assumed — see server_config_path().
    """
    m = load_manifest(args.manifest)
    cfg = m.get("qemu_accel") or {}
    if not cfg.get("settings"):
        print("  skip   no qemu_accel.settings in the manifest")
        return 0
    fallback = cfg.get("config_file", "~/.config/GNS3/2.2/gns3_server.conf")
    path, how = server_config_path(fallback)
    section = cfg.get("section", "Qemu")
    settings = {k: ("true" if v is True else "false" if v is False else str(v))
                for k, v in cfg["settings"].items()}

    # Say which mode this VM is actually in — the whole point of the phase is that both are
    # meant to work, so the operator should be able to see which one they just built.
    kvm = Path("/dev/kvm").exists()
    print(f"  host   /dev/kvm {'present — Qemu nodes run accelerated' if kvm else 'ABSENT'}"
          + ("" if kvm else " — Qemu nodes fall back to TCG emulation (minutes, not seconds)"))
    print(f"  config {path} (from the running {how})" if how != "manifest"
          else f"  config {path} (manifest fallback — no --config on this VM)")

    if not path.exists():
        # gns3server only watches files that existed when it started, so creating this one
        # now would not take effect until a restart. Say so rather than silently misleading.
        print(f"  WARN   {path} does not exist — creating it, but gns3server will not pick "
              f"it up until the service restarts")
    old = path.read_text() if path.exists() else ""
    new = ini_set(old, section, settings)
    shown = ", ".join(f"{k} = {v}" for k, v in settings.items())

    # A [Qemu] section in a file the server does not load is the failure this phase used to
    # have, and it is invisible: everything downstream succeeds and the setting is simply
    # absent. Name the stale file rather than deleting it — it may be hand-written.
    stale = Path(os.path.expanduser(fallback))
    if stale != path and stale.exists() and f"[{section}]" in stale.read_text():
        print(f"  WARN   {stale} also has a [{section}] section and is NOT read by this "
              f"server — it is ignored, not merged")

    if new == old:
        print(f"  skip   {path} already has [{section}] {shown}")
        return 0
    if args.dry_run:
        print(f"  [dry-run] set [{section}] {shown} in {path}")
        return 0
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(new)
    except OSError:
        # /opt/gns3/server is gns3-owned on the appliances seen so far, but a root-owned
        # config is a plausible variation and is not a reason to fail the build.
        sudo_write(path, new)
    print(f"  accel  [{section}] {shown} -> {path}")
    print("  note   picked up live (gns3server watches its config); no restart needed")
    return 0


def accel_state(m):
    """What the `accel` settings actually are on this VM — recorded by `provenance`.

    This is here because the failure it catches is invisible everywhere else. The phase spent
    a release writing `require_kvm = false` into a file the server did not read: every build
    went green, every check passed, and the setting was simply absent. It costs nothing on a
    host with `/dev/kvm` — which every build host so far has had — and breaks *every* Qemu node
    on a Credential Guard laptop and on all of arm64. A build that cannot prove the setting
    landed cannot prove the appliance runs its Qemu nodes on the machines students actually
    have, so the answer ships beside the OVA rather than being inferred from a green log.

    `applied` is three-valued: True, False, or None when the config file is absent — usually
    because this ran from a control node instead of on the VM, which is not the same as a
    setting that failed to apply.
    """
    cfg = m.get("qemu_accel") or {}
    settings = cfg.get("settings") or {}
    if not settings:
        return None
    fallback = cfg.get("config_file", "~/.config/GNS3/2.2/gns3_server.conf")
    path, how = server_config_path(fallback)
    section = cfg.get("section", "Qemu")
    want = {k.lower(): ("true" if v is True else "false" if v is False else str(v)).lower()
            for k, v in settings.items()}

    found, applied = {}, None
    if path.exists():
        cp = configparser.ConfigParser(strict=False)
        try:
            cp.read(str(path))
            if cp.has_section(section):
                found = {k.lower(): v.strip().lower() for k, v in cp.items(section)}
        except configparser.Error:
            pass
        applied = all(found.get(k) == v for k, v in want.items())

    # Every other gns3_server.conf carrying this section is inert: an explicit --config makes
    # one file the only one loaded, and nothing merges the rest. Naming them is what turns
    # "the setting is in a gns3_server.conf" back into "the setting is in effect".
    ignored = []
    other = Path(os.path.expanduser(fallback))
    try:
        if other != path and other.exists() and f"[{section}]" in other.read_text():
            ignored.append(str(other))
    except OSError:
        pass

    return {
        "config_file": str(path),
        "discovered_from": how,
        "section": section,
        "expected": want,
        "found": {k: found.get(k) for k in want},
        "applied": applied,
        # Why nobody noticed: with /dev/kvm present the setting changes nothing observable.
        "kvm_present": Path("/dev/kvm").exists(),
        "ignored_config_files": ignored,
    }


def install_novnc_service(src_dir, cfg, dry_run):
    """Install and enable gns3-novnc: one websockify serving every VNC console on this VM.

    Replaces what used to be a student task — enter the VM's shell, run start-vnc.sh with a
    VNC port and a web port, remember the URL, do it again for the second Firefox Host, and
    redo the lot after a reboot. The service does it once, from boot, for every node: the
    student opens http://<vm-ip>:6080/ and clicks the node. Why one listener can reach them
    all (websockify's token plugin) is explained in novnc/gns3_vnc_console.py.

    Four things go on the VM, all idempotent and all reported: the module, the picker page, a
    symlink giving the page stock noVNC under ./novnc, and the systemd unit with the
    manifest's paths substituted in. The unit is only restarted when something changed —
    restarting it drops any console a student happens to have open.

    Returns non-zero if the service will not start, which fails the phase and the build: an
    appliance whose VNC gateway is dead is broken for every GUI activity, and nothing later
    in the build would notice.
    """
    port = int(cfg.get("port", 6080))
    lib_dir = Path(cfg.get("lib_dir", "/usr/local/lib/gns3-novnc"))
    web_dir = Path(cfg.get("web_dir", "/usr/local/share/gns3-novnc"))
    novnc_dir = Path(cfg.get("novnc_dir", "/usr/share/novnc"))
    unit_name = cfg.get("unit", "gns3-novnc.service")
    unit_path = Path("/etc/systemd/system") / unit_name

    module = src_dir / "gns3_vnc_console.py"
    page = src_dir / "index.html"
    unit_src = src_dir / unit_name
    for f in (module, page, unit_src):
        if not f.exists():
            sys.exit(f"novnc service source missing: {f}")

    unit_text = (unit_src.read_text()
                 .replace("@LIB@", str(lib_dir))
                 .replace("@WEB@", str(web_dir))
                 .replace("@PORT@", str(port)))
    installs = [(module, lib_dir / module.name),
                (page, web_dir / page.name),
                (unit_src, unit_path)]

    if dry_run:
        for src, dst in installs:
            print(f"  [dry-run] install {src.name} -> {dst}")
        print(f"  [dry-run] symlink {web_dir / 'novnc'} -> {novnc_dir}")
        print(f"  [dry-run] systemctl enable --now {unit_name}")
        return

    for d in (lib_dir, web_dir):
        if not d.is_dir():
            subprocess.run(["sudo", "mkdir", "-p", str(d)], check=True)

    changed = False
    for src, dst in installs:
        text = unit_text if src is unit_src else src.read_text()
        if sudo_write(dst, text):
            # 0644 for the same reason as the netplan file in cmd_labnic: sudo_write compares
            # by reading the file as the build user, so a root-only file would look changed
            # on every run and the phase would stop being idempotent.
            subprocess.run(["sudo", "chmod", "644", str(dst)], check=False)
            print(f"  install {src.name} -> {dst}")
            changed = True
        else:
            print(f"  skip   {dst} (already correct)")

    # The picker page links to stock noVNC as ./novnc/vnc.html, so the web root has to offer
    # it. A symlink to the whole package directory rather than to each file inside it: the
    # page never has to know noVNC's layout, and a package update cannot leave it half wired.
    link = web_dir / "novnc"
    if not novnc_dir.is_dir():
        print(f"  WARN   {novnc_dir} is missing — is the novnc package installed?")
    if not (link.is_symlink() and os.readlink(str(link)) == str(novnc_dir)):
        subprocess.run(["sudo", "ln", "-sfn", str(novnc_dir), str(link)], check=True)
        print(f"  link   {link} -> {novnc_dir}")
        changed = True
    else:
        print(f"  skip   {link} (already linked)")

    if changed:
        subprocess.run(["sudo", "systemctl", "daemon-reload"], check=True)
    active = subprocess.run(["systemctl", "is-active", "--quiet", unit_name]).returncode == 0
    if changed or not active:
        rc = subprocess.run(["sudo", "systemctl", "enable", "--now", unit_name]).returncode
        if rc == 0 and changed and active:
            rc = subprocess.run(["sudo", "systemctl", "restart", unit_name]).returncode
        print(f"  service {unit_name} {'started' if rc == 0 else 'FAILED to start'}")
        if rc != 0:
            print(f"         journalctl -u {unit_name} -n 30")
            return
    else:
        print(f"  skip   {unit_name} already enabled and running")
    print(f"  url    http://<gns3-vm-ip>:{port}/ — every VNC node on this VM, one click each")


def cmd_novnc(args):
    m = load_manifest(args.manifest)
    cfg = m.get("novnc") or {}
    packages = cfg.get("packages", [])
    script = (m["_dir"] / cfg.get("script", "../start-vnc.sh")).resolve()
    target = Path(os.path.expanduser(cfg.get("install_to", "~/start-vnc.sh")))

    missing = [p for p in packages if not apt_installed(p)]
    if not missing:
        print(f"  skip   packages already installed: {', '.join(packages)}")
    elif args.dry_run:
        print(f"  [dry-run] apt-get install {' '.join(missing)}")
    else:
        print(f"  apt    installing {', '.join(missing)}")
        env = dict(os.environ, DEBIAN_FRONTEND="noninteractive")
        sys.stdout.flush()
        subprocess.run(["sudo", "-E", "apt-get", "-y", "update"], env=env, check=True)
        subprocess.run(["sudo", "-E", "apt-get", "-y", "install"] + missing,
                       env=env, check=True)

    if not script.exists():
        sys.exit(f"start-vnc script not found: {script}")
    want = script.read_text()
    if target.exists() and target.read_text() == want and os.access(str(target), os.X_OK):
        print(f"  skip   {target} already installed")
    elif args.dry_run:
        print(f"  [dry-run] install {script} -> {target}")
    else:
        target.write_text(want)
        target.chmod(0o755)
        print(f"  install {script.name} -> {target}")

    svc = cfg.get("service") or {}
    if svc:
        install_novnc_service((m["_dir"] / svc.get("dir", "../novnc")).resolve(),
                              svc, args.dry_run)
    return 0


# --------------------------------------------------------------------------- #
# Phase: projects — import the .gns3project files named in projects.txt via the API
# --------------------------------------------------------------------------- #
def read_project_list(m):
    """The project names the appliance ships, in order, from ../projects.txt.

    One list for one appliance — there is no per-audience variation any more. Blank lines
    and `#` comments are skipped and names de-duplicated; a file with no trailing newline
    is fine, which splitlines() handles.
    """
    f = (m["_dir"] / m["paths"].get("project_list", "../projects.txt")).resolve()
    if not f.exists():
        sys.exit(f"project list not found: {f}")
    names, seen = [], set()
    for line in f.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and line not in seen:
            seen.add(line)
            names.append(line)
    return f, names


def local_zip_verdict(path):
    """Say whether a .gns3project is readable here, for when the controller rejects it.

    The oversized projects are too big for git, so nothing checks their integrity between
    builds; a damaged file is indistinguishable from a server-side failure until tested.
    Only called after an import has already failed, so the CRC pass is worth its cost.
    """
    try:
        with zipfile.ZipFile(str(path)) as z:
            bad = z.testzip()
    except Exception as e:                           # noqa: BLE001
        return (f"local file is NOT a readable zip ({type(e).__name__}: {e}) — "
                f"replace it and compare sha256 against provenance-*.json")
    if bad:
        return (f"local file is CORRUPT (first bad member: {bad}) — replace it and compare "
                f"sha256 against provenance-*.json")
    return ("local file verifies clean, so the fault is server-side — check free space on "
            "the VM (this project expands to several times its stored size)")


def find_project_files(name, roots, suffix=""):
    """Every <name>.gns3project under roots, in root order — the first one is used.

    All matches are returned, not just the winner, because copies of one project can
    disagree while sharing a project_id (an exported byproduct left in outfiles/ next to
    a rebuilt project in activities/). Identical ids make the skip-if-exists check blind
    to the difference, so importing the stale copy silently shadows the good one. Put the
    authoritative root first, and heed the warning when this returns more than one.

    `suffix` names a platform variant (see platforms.<p>.project_suffix). <name><suffix>
    wins wherever it exists, and only the plain name is looked for otherwise — so a
    platform needs a rebuilt file only for the projects that actually differ.
    """
    def _hits(stem):
        out = []
        for root in roots:
            root = Path(os.path.expanduser(str(root)))
            if not root.is_dir():
                continue
            direct = root / f"{stem}.gns3project"
            if direct.is_file():
                out.append(direct)
                continue
            out.extend(sorted(root.rglob(f"{stem}.gns3project")))
        return out

    return (suffix and _hits(f"{name}{suffix}")) or _hits(name)


def project_id_of(path):
    """Read project_id out of the project.gns3 inside the .gns3project zip."""
    with zipfile.ZipFile(str(path)) as z:
        with z.open("project.gns3") as f:
            return json.load(f).get("project_id")


def cmd_projects(args):
    m = load_manifest(args.manifest)
    if args.profile not in m["profiles"]:
        sys.exit(f"unknown profile '{args.profile}' (have: {', '.join(m['profiles'])})")
    list_file, names = read_project_list(m)
    roots = ([r.strip() for r in args.roots.split(",") if r.strip()] if args.roots
             else m.get("project_roots", ["/home/gns3/projects"]))
    platform = profile_platform(m, args.profile)
    suffix = m.get("platforms", {}).get(platform, {}).get("project_suffix", "")

    ctrl = Controller(args.server)
    try:
        ver = ctrl.version()
    except urllib.error.URLError as e:
        sys.exit(f"cannot reach controller at {args.server}: {e}")
    print(f"controller {args.server} — GNS3 {ver}")
    print(f"profile {args.profile} — {list_file.name}, {len(names)} project(s)")
    print(f"roots: {', '.join(str(r) for r in roots)}"
          + (f"   (preferring *{suffix}.gns3project)" if suffix else "") + "\n")

    existing = {p["project_id"] for p in ctrl.projects()}
    imported = skipped = 0
    notfound, failures, shadowed, records = [], [], [], []
    for name in names:
        hits = find_project_files(name, roots, suffix)
        if not hits:
            print(f"  MISSING {name:34} (not under any root — skipped)")
            notfound.append(name)
            continue
        path = hits[0]
        if len(hits) > 1:
            shadowed.append(name)
            others = ", ".join(f"{p} ({human(p.stat().st_size)})" for p in hits[1:])
            print(f"  DUP    {name:34} {len(hits)} copies — using {path} "
                  f"({human(path.stat().st_size)}); ignoring {others}")
        try:
            pid = project_id_of(path)
        except Exception as e:
            print(f"  ERROR  {name:34} unreadable: {e}")
            failures.append(name)
            continue
        if not pid:
            print(f"  ERROR  {name:34} no project_id in project.gns3")
            failures.append(name)
            continue
        # Recorded whether or not we import: git cannot hold the oversized project files,
        # so this is the only durable statement of which bytes a build was made from.
        if args.record:
            records.append({"name": name, "project_id": pid, "source": str(path),
                            "bytes": path.stat().st_size, "sha256": sha256_of(path)})
        if pid in existing:
            print(f"  skip   {name:34} (already imported: {pid})")
            skipped += 1
            continue
        size = human(path.stat().st_size)
        if args.dry_run:
            print(f"  [dry-run] import {name} ({size}) from {path}")
            imported += 1
            continue
        print(f"  import {name:34} {size} <- {path}")
        try:
            ctrl.import_project(pid, path)
            existing.add(pid)
            imported += 1
        except urllib.error.HTTPError as e:
            body = e.read().decode(errors="replace")[:200]
            print(f"  ERROR  {name}: HTTP {e.code} {body}")
            # "invalid zip" names the symptom, not the cause, and arrives only after the
            # whole file has been uploaded — for SDN-Basics-Template that is 729 MB. Say
            # which side is at fault, since the answer decides what to do next.
            if "invalid zip" in body.lower():
                print(f"         checking {path} locally ...")
                print("         " + local_zip_verdict(path))
            failures.append(name)
        except Exception as e:
            print(f"  ERROR  {name}: {e}")
            failures.append(name)

    if args.record and not args.dry_run:
        write_import_record(args.record, args.profile, records, roots)
        print(f"\n  record {args.record} ({len(records)} source file(s))")

    verb = "would import" if args.dry_run else "imported"
    print(f"\n{verb} {imported}, skipped {skipped}, not found {len(notfound)}, "
          f"failed {len(failures)}")
    if notfound:
        # Not fatal: the private/oversized project files are not always on the build host.
        print(f"  not found: {', '.join(notfound)}")
    if shadowed:
        print(f"  WARN  {len(shadowed)} project(s) found under more than one root "
              f"({', '.join(shadowed)}) — check the root order puts the authoritative "
              f"copy first")
    if failures:
        print(f"  failed: {', '.join(failures)}")
    return 1 if failures else 0


# --------------------------------------------------------------------------- #
# Phase: export-check — the gate that runs before an OVA is cut
# --------------------------------------------------------------------------- #
def controller_is_local(server):
    """Is the controller at `server` this same machine?

    Decides whether the host-local parts of `export-check` are inspecting the appliance or
    some other computer entirely. Name resolution can fail on an offline build host, so a
    failure here means "assume remote" — the cautious answer, since it downgrades a check to
    "not run" rather than silently reporting someone else's disk as the appliance's.
    """
    host = (urllib.parse.urlparse(server).hostname or "").lower()
    if host in ("", "localhost", "127.0.0.1", "::1", socket.gethostname().lower()):
        return True
    try:
        return host in {ai[4][0] for ai in socket.getaddrinfo(socket.gethostname(), None)}
    except OSError:
        return False


def installed_images(ctrl):
    """(qemu filenames, docker image tags) the *controller* reports, or None where unknown.

    None means "could not ask" — an older controller without these endpoints, say. It is
    deliberately not an empty set: an empty set would mark every node unstartable, which is
    the same false alarm this function exists to remove, only louder.
    """
    try:
        qemu = {os.path.basename(i.get("filename") or i.get("path") or "")
                for i in (ctrl.qemu_images() or [])}
        qemu.discard("")
    except Exception:                                    # noqa: BLE001
        qemu = None
    try:
        docker = set()
        for i in (ctrl.docker_images() or []):
            img = i.get("image") or ""
            if img:
                docker.add(img)
                # A node's `image` property may or may not carry the tag; the API always does.
                if img.endswith(":latest"):
                    docker.add(img[: -len(":latest")])
    except Exception:                                    # noqa: BLE001
        docker = None
    return qemu, docker


def cmd_export_check(args):
    """Refuse to bless an appliance whose contents are not exactly projects.txt.

    Two ways content reaches an OVA: a project imported into the controller, and a stray
    .gns3project staged on the VM's disk (the manual build copied them to /home/gns3/projects,
    and `rm -f` was a step you had to remember). Both are checked.

    This used to compare against the *other* audience's list, so it only caught a solution
    on a student VM. With one appliance there is no other list to compare against, and an
    unlisted project is simply one nobody decided to ship — a leftover from a manual test, a
    solution opened to answer a question. That is now fatal rather than a warning: it is the
    only thing standing between an off-hand import and a public OVA.

    Run from another machine (`--server http://<vm-ip>`), the parts that read a *filesystem*
    are answering about the wrong computer. The image checks therefore go through the API, and
    the staged-file scan reports itself as not run rather than as clean — a gate that cannot
    see half of what it guards must say so, or it reads as a pass.
    """
    m = load_manifest(args.manifest)
    if args.profile not in m["profiles"]:
        sys.exit(f"unknown profile '{args.profile}' (have: {', '.join(m['profiles'])})")
    list_file, allowed = read_project_list(m)
    allowed_set = set(allowed)

    ctrl = Controller(args.server)
    try:
        ctrl.version()
    except urllib.error.URLError as e:
        sys.exit(f"cannot reach controller at {args.server}: {e}")

    print(f"profile {args.profile} — {len(allowed)} project(s) permitted "
          f"by {list_file.name}\n")

    problems, warnings = [], []

    imported = {p["name"]: p["project_id"] for p in ctrl.projects()}
    for name in sorted(imported):
        if name not in allowed_set:
            problems.append(f"project '{name}' is imported but is not in {list_file.name}")
    missing = [n for n in allowed if n not in imported]

    # Staged .gns3project files ship inside the OVA even though nothing imports them.
    # Matching is on the filename here, not the controller's project name, so strip the
    # platform variant suffix first: Small-Internet-Demo-arm64.gns3project holds the project
    # *named* Small-Internet-Demo, and calling that unlisted would be a lie.
    suffix = m.get("platforms", {}).get(profile_platform(m, args.profile), {}) \
              .get("project_suffix", "")
    local = controller_is_local(args.server)
    staged_dirs = [Path(os.path.expanduser(str(d)))
                   for d in (m.get("project_roots") or [])]
    staged = []
    if local:
        for d in staged_dirs:
            if d.is_dir():
                staged += sorted(d.rglob("*.gns3project"))
    for f in staged:
        name = f.name[: -len(".gns3project")]
        if suffix and name.endswith(suffix) and name[: -len(suffix)] in allowed_set:
            name = name[: -len(suffix)]
        if name not in allowed_set:
            problems.append(f"staged file {f} ({human(f.stat().st_size)}) is not in "
                            f"{list_file.name} and would ship inside the OVA")
        else:
            warnings.append(f"staged file {f} ({human(f.stat().st_size)}) would ship "
                            f"inside the OVA for no benefit — it is already imported, so "
                            f"delete it")

    # Will the nodes actually start? A project can be perfectly legal and still be unusable
    # because it names an image this platform does not install. The arm64 profile is where
    # this bites: a project exported on a PC carries amd64 Qemu nodes, none of which exist
    # on an arm64 build. Note this only inspects the projects the appliance *ships*, which
    # is now five — it is not evidence that the image set covers the activities students
    # import themselves. Only `verify=all` shows that.
    have_qemu, have_docker = installed_images(ctrl)
    for kind, have in (("qemu", have_qemu), ("docker", have_docker)):
        if have is None:
            warnings.append(f"the controller did not answer for its {kind} images, so no "
                            f"node using one was checked for being startable")
    broken = []
    for name, pid in sorted(imported.items()):
        for node in ctrl.project_nodes(pid):
            props = node.get("properties") or {}
            if node.get("node_type") == "qemu" and have_qemu is not None:
                for field in ("hda_disk_image", "hdb_disk_image", "cdrom_image"):
                    disk = props.get(field)
                    if disk and os.path.basename(disk) not in have_qemu:
                        broken.append(f"{name}: qemu disk '{os.path.basename(disk)}' "
                                      f"is not installed")
            elif node.get("node_type") == "docker" and have_docker is not None:
                img = props.get("image")
                if img and img not in have_docker and f"{img}:latest" not in have_docker:
                    broken.append(f"{name}: docker image '{img}' is not built")
    broken = sorted(set(broken))

    print(f"  imported projects   {len(imported)}")
    print(f"  permitted           {len(allowed)}")
    print(f"  staged files        "
          + (str(len(staged)) if local else
             "NOT CHECKED — the controller is another machine, and staged files are on its "
             "disk"))
    if missing:
        print(f"\n  INCOMPLETE  {len(missing)} permitted project(s) not imported: "
              f"{', '.join(missing)}")
    for b in broken:
        print(f"  BROKEN {b}")
    for w in warnings:
        print(f"  WARN   {w}")
    for p in problems:
        print(f"  UNLISTED {p}")

    if broken and args.strict:
        problems += [f"unstartable node: {b}" for b in broken]
    if problems:
        print(f"\nFAIL — {len(problems)} problem(s). Do NOT export this VM until they are "
              f"fixed: delete anything unlisted, or add it to {list_file.name} if it belongs "
              f"on the appliance; an unstartable node needs its image installed instead.")
        return 1
    # "exactly" only if nothing is missing either — INCOMPLETE stays non-fatal (a project file
    # absent from the build host is a known, survivable case) but must not read as a clean bill.
    verdict = (f"the appliance carries exactly {list_file.name}" if not missing else
               f"nothing unlisted is present, but {len(missing)} project(s) on "
               f"{list_file.name} did not make it in")
    counts = (f"{len(broken)} unstartable, " if broken else "") + f"{len(warnings)} warning(s)"
    print(f"\n{'OK' if local else 'PARTIAL'} — {verdict}. ({counts})")
    if broken:
        print("       the BROKEN entries above will not start on this platform — "
              "on arm64 that means a PC-built Qemu project needs an -arm64 rebuild; "
              "use --strict to fail on them.")
    if not local:
        # Not a warning in the list above, because it is about this *run* rather than about
        # the appliance: everything reported is true, and one whole check did not happen.
        print("       PARTIAL because a staged .gns3project on the VM's own disk would ship "
              "inside the\n       OVA and nothing here can see it. Re-run on the VM before "
              "cutting the OVA.")
    return 0


# --------------------------------------------------------------------------- #
# Phase: provenance — record what this appliance actually contains
# --------------------------------------------------------------------------- #
# /2 added `release` and `git`; /3 dropped `audience` when the staff appliance was retired;
# /4 added system.auto_update_units + system.reboot_required (see the `quiesce` phase)
PROVENANCE_SCHEMA = "gns3build-provenance/5"      # /5 adds qemu_accel


def write_import_record(path, profile, records, roots=None):
    """Source-side record written by `projects`, merged into the provenance manifest."""
    p = Path(os.path.expanduser(path))
    p.parent.mkdir(parents=True, exist_ok=True)
    doc = {"profile": profile, "sources": records}
    if roots:
        doc["roots"] = [{"path": str(r), "git": git_info(r)} for r in roots]
    p.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n")


def _cmd_out(cmd):
    try:
        r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           universal_newlines=True)
        return r.stdout.strip() if r.returncode == 0 else None
    except OSError:
        return None


def git_info(path):
    """Identify the commit a work tree was built from; None if it is not one.

    Two of these pin a build, and they are read in different places because the phases run
    in different places: this repo, read on the VM where the engine runs, and each projects
    root (gns3-dev), read on the control node by `projects --record`. A release tag means
    nothing if the tree was dirty when the OVA was cut, so `dirty` is recorded rather than
    assumed — None there means the question could not be answered, which is not the same
    as clean.
    """
    d = str(path)
    head = _cmd_out(["git", "-C", d, "rev-parse", "HEAD"])
    if not head:
        return None
    status = _cmd_out(["git", "-C", d, "status", "--porcelain"])
    return {
        "commit": head,
        "describe": _cmd_out(["git", "-C", d, "describe", "--tags", "--always", "--dirty"]),
        "branch": _cmd_out(["git", "-C", d, "rev-parse", "--abbrev-ref", "HEAD"]),
        "origin": _cmd_out(["git", "-C", d, "remote", "get-url", "origin"]),
        "dirty": None if status is None else bool(status),
    }


def stamp_release(prov):
    """Write /etc/gns3-cqu-release so the appliance can name its own release.

    A renamed .ova tells you nothing, and `gns3-build-provenance.json` answers the question
    only if you know to look for it. This is the two-second check a student or a tutor at a
    lab machine can run when told "use v030 this term, not v027".
    """
    git = (prov.get("git") or {}).get("gns3") or {}
    lines = [
        "# CQUniversity GNS3 appliance — written at build time, do not edit.",
        f"GNS3_CQU_RELEASE={prov['release']}",
        f"GNS3_CQU_PROFILE={prov['profile']}",
        f"GNS3_CQU_PLATFORM={prov['platform']}",
        f"GNS3_CQU_BUILT={prov['generated_utc']}",
        f"GNS3_CQU_GNS3={prov['gns3']['controller_version']}",
        f"GNS3_CQU_COMMIT={(git.get('commit') or '')[:12]}",
    ]
    text = "\n".join(lines) + "\n"
    try:
        changed = sudo_write(RELEASE_FILE, text)
    except subprocess.CalledProcessError as e:
        print(f"  WARN   could not write {RELEASE_FILE} ({e}) — appliance will not "
              f"self-identify")
        return
    print(f"  release {RELEASE_FILE} ({'written' if changed else 'unchanged'})")

    # Also greet the shell, since that is where students are sent (Shell from the VM menu)
    # and nobody reads a file they were not told about.
    banner = f"\nCQUniversity GNS3 appliance — release {prov['release']} " \
             f"({prov['profile']}, built {prov['generated_utc'][:10]})\n"
    try:
        sudo_write("/etc/motd", banner)
    except subprocess.CalledProcessError:
        print("  WARN   could not write /etc/motd")


def cmd_provenance(args):
    """Emit a manifest of what is in this appliance.

    Two OVAs with the same filename are otherwise indistinguishable. This answers "which
    build is a student running, and exactly what is in it" months later, when the only
    thing you have is the .ova and a bug report.
    """
    m = load_manifest(args.manifest)
    if args.profile not in m["profiles"]:
        sys.exit(f"unknown profile '{args.profile}' (have: {', '.join(m['profiles'])})")
    prof = m["profiles"][args.profile]
    platform = prof["platform"]

    ctrl = Controller(args.server)
    try:
        gns3_version = ctrl.version()
    except urllib.error.URLError as e:
        sys.exit(f"cannot reach controller at {args.server}: {e}")

    prov = {
        "schema": PROVENANCE_SCHEMA,
        "generated_utc": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
        # Set only when the build is actually being released to students. An unreleased
        # build is a build; a release is the one students are told to download, and only
        # those get a tag, a RELEASES.md row and a stamp on the appliance.
        "release": args.release or None,
        "profile": args.profile,
        "platform": platform,
        # What built this. The projects roots are filled in from the import record below,
        # because that phase runs on the control node and this one runs on the VM.
        "git": {"gns3": git_info(REPO_ROOT), "project_roots": []},
        "gns3": {"controller_version": gns3_version,
                 "manifest_expects": m.get("gns3_version")},
        "system": {
            "hostname": _cmd_out(["hostname"]),
            "arch": _cmd_out(["uname", "-m"]),
            "kernel": _cmd_out(["uname", "-r"]),
            "docker": _cmd_out(["docker", "--version"]),
            # Two ways an appliance stops being the machine that was tested, both invisible
            # in a package list: an upgrade timer still running (it will rewrite the VM on
            # some future boot), and an upgrade already applied but not booted into. The
            # `quiesce` phase fixes the first and warns about the second; recording them
            # here is how you can tell after the fact which OVA had which.
            "auto_update_units": {u: unit_state(u) for u in
                                  ((m.get("auto_updates") or {}).get("mask_units") or [])},
            "reboot_required": Path("/var/run/reboot-required").exists(),
        },
        # Whether Qemu nodes will start on a host without nested virtualisation. Absent from
        # the manifest until August 2026, which is how a release shipped with it unset —
        # see accel_state().
        "qemu_accel": accel_state(m),
    }

    # Docker: the image ID is the content hash, so it identifies the exact bytes even for
    # a :latest tag that has been rebuilt.
    images = []
    for key in m["platforms"][platform].get("docker", []):
        image = m["nodes"][key]["image"]
        raw = _cmd_out(["docker", "image", "inspect", image,
                        "--format", "{{.Id}}\t{{.Size}}\t{{.Created}}"])
        if raw:
            iid, size, created = (raw.split("\t") + ["", "", ""])[:3]
            images.append({"node": key, "image": image, "id": iid,
                           "bytes": int(size) if size.isdigit() else None,
                           "created": created})
        else:
            images.append({"node": key, "image": image, "id": None, "missing": True})
    prov["docker_images"] = images

    # Qemu: md5 comes from the sidecar the qemu phase wrote, so this costs nothing.
    images_dir = Path(args.images_dir or m.get("qemu_images_dir", "/opt/gns3/images/QEMU"))
    disks = []
    for key in m["platforms"][platform].get("qemu", []):
        for spec in qemu_files(m["nodes"][key]):
            f = images_dir / spec["file"]
            sidecar = Path(str(f) + ".md5sum")
            disks.append({
                "node": key, "file": spec["file"],
                "present": f.exists(),
                "bytes": f.stat().st_size if f.exists() else None,
                "md5": sidecar.read_text().strip() if sidecar.exists()
                       else spec.get("md5"),
                "resize": spec.get("resize"),
            })
    prov["qemu_images"] = disks

    prov["templates"] = sorted(
        ({"name": t.get("name"), "template_id": t.get("template_id"),
          "type": t.get("template_type")} for t in ctrl.templates()),
        key=lambda t: (t["name"] or ""))

    projects_dir = Path(args.projects_dir)
    projects = []
    for p in sorted(ctrl.projects(), key=lambda p: p["name"]):
        d = projects_dir / p["project_id"]
        projects.append({"name": p["name"], "project_id": p["project_id"],
                         "bytes": dir_bytes(d) if d.is_dir() else None})
    prov["projects"] = projects

    # Source checksums recorded by `projects --record`, if that record reached us.
    record = Path(os.path.expanduser(args.imports)) if args.imports else None
    if record and record.is_file():
        rec = json.loads(record.read_text())
        prov["sources"] = rec.get("sources", [])
        prov["git"]["project_roots"] = rec.get("roots", [])
    else:
        prov["sources"] = []
        if args.imports:
            print(f"  note   no import record at {record} — source checksums omitted")

    out = Path(os.path.expanduser(args.out))
    if args.dry_run:
        print(json.dumps(prov, indent=2, sort_keys=True))
        return 0
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(prov, indent=2, sort_keys=True) + "\n")

    missing_imgs = [i["image"] for i in images if i.get("missing")]
    missing_disks = [d["file"] for d in disks if not d["present"]]
    print(f"provenance -> {out}")
    print(f"  generated    {prov['generated_utc']}")
    print(f"  profile      {args.profile} ({platform})")
    print(f"  gns3         {gns3_version}  on {prov['system']['arch']} "
          f"kernel {prov['system']['kernel']}")
    print(f"  docker       {len(images)} image(s)"
          + (f" — MISSING: {', '.join(missing_imgs)}" if missing_imgs else ""))
    print(f"  qemu         {len(disks)} disk(s)"
          + (f" — MISSING: {', '.join(missing_disks)}" if missing_disks else ""))
    accel = prov["qemu_accel"]
    if accel:
        shown = ", ".join(f"{k} = {v}" for k, v in accel["expected"].items())
        verdict = ("applied" if accel["applied"] else
                   "NOT APPLIED" if accel["applied"] is False else
                   "unknown — config file not found (are you on the VM?)")
        print(f"  accel        {verdict}: [{accel['section']}] {shown}"
              f" in {accel['config_file']}")
        if accel["ignored_config_files"]:
            print(f"               ignored (not read by this server): "
                  f"{', '.join(accel['ignored_config_files'])}")
    print(f"  templates    {len(prov['templates'])}")
    print(f"  projects     {len(projects)} "
          f"({human(sum(p['bytes'] or 0 for p in projects))} on disk)")
    print(f"  sources      {len(prov['sources'])} file(s) with checksums")

    dirty = []
    for label, g in [("gns3", prov["git"]["gns3"])] + \
                    [(r["path"], r["git"]) for r in prov["git"]["project_roots"]]:
        if not g:
            print(f"  git          {label}: not a work tree — commit NOT recorded")
            continue
        print(f"  git          {label}: {g['describe'] or g['commit'][:12]}"
              f" ({g['branch']})" + ("  DIRTY" if g["dirty"] else ""))
        if g["dirty"]:
            dirty.append(label)

    if args.release:
        print(f"  release      {args.release}")
        stamp_release(prov)
        if dirty:
            # Not fatal — you may be mid-fix and cutting a test OVA — but a release whose
            # tree is dirty cannot be pointed back at a tag, which is the whole point.
            print(f"\n  WARNING  releasing {args.release} from a DIRTY tree "
                  f"({', '.join(dirty)}). Commit and tag before cutting the OVA, or the "
                  f"recorded commit will not describe what shipped.")

    # A Qemu node that cannot start on a student's laptop is as much a broken appliance as a
    # missing disk, and rather harder to see, so it fails the phase the same way. `None` (no
    # config file to read) is not a failure — that is a provenance run off the VM.
    bad_accel = bool(accel) and accel["applied"] is False
    return 1 if (missing_imgs or missing_disks or bad_accel) else 0


# --------------------------------------------------------------------------- #
# Phase: build — run every phase in order
# --------------------------------------------------------------------------- #
# `quiesce` runs first, and not for tidiness: it is the phase that stops Ubuntu's own upgrade
# timers competing with the build for a single-core VM's CPU, so it has to land before the two
# long phases (docker, qemu) rather than after them.
BUILD_PHASES = ["quiesce", "templates", "docker", "qemu", "accel", "logos", "novnc", "labnic",
                "projects"]


def cmd_build(args):
    phases = list(BUILD_PHASES)
    if args.only:
        wanted = [p.strip() for p in args.only.split(",") if p.strip()]
        unknown = [p for p in wanted if p not in BUILD_PHASES]
        if unknown:
            sys.exit(f"--only: unknown phase(s) {', '.join(unknown)} "
                     f"(have: {', '.join(BUILD_PHASES)})")
        phases = [p for p in phases if p in wanted]
    if args.skip:
        skip = [p.strip() for p in args.skip.split(",") if p.strip()]
        unknown = [p for p in skip if p not in BUILD_PHASES]
        if unknown:
            sys.exit(f"--skip: unknown phase(s) {', '.join(unknown)} "
                     f"(have: {', '.join(BUILD_PHASES)})")
        phases = [p for p in phases if p not in skip]

    handlers = {"quiesce": cmd_quiesce, "templates": cmd_templates, "docker": cmd_docker,
                "qemu": cmd_qemu, "accel": cmd_accel, "logos": cmd_logos, "novnc": cmd_novnc,
                "labnic": cmd_labnic, "projects": cmd_projects}
    # Every phase reads its options off this one namespace, so it must carry a default
    # for every option any phase's sub-parser defines — a missing one is an AttributeError
    # at run time, not a parse error. Add new phase options here too.
    common = argparse.Namespace(
        manifest=args.manifest, profile=args.profile, server=args.server,
        dry_run=args.dry_run, force=args.force, only=None, skip=None, verify=False,
        images_dir=None, symbols_dir=None, dest=None, roots=args.roots,
        record=None, imports=None, out=None, projects_dir="/opt/gns3/projects",
        strict=False, interface=None, netplan_file=None)

    print(f"build profile {args.profile}: {' -> '.join(phases)}\n")
    results = []
    for phase in phases:
        print(f"\n{'=' * 70}\n== phase: {phase}\n{'=' * 70}")
        try:
            rc = handlers[phase](common) or 0
        except SystemExit as e:                       # a phase's sys.exit(msg)
            print(f"== phase {phase} aborted: {e}")
            rc = 1
        except Exception as e:                        # keep going; the summary still prints
            print(f"== phase {phase} crashed: {type(e).__name__}: {e}")
            rc = 1
        results.append((phase, rc))
        if rc:
            print(f"== phase {phase} reported failures")

    print(f"\n{'=' * 70}\nbuild summary ({args.profile})")
    for phase, rc in results:
        print(f"  {'OK  ' if rc == 0 else 'FAIL'}  {phase}")
    return 1 if any(rc for _, rc in results) else 0


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
    tp.add_argument("--force", action="store_true",
                    help="overwrite templates already registered (needed after editing a "
                         "templates/*.conf; without it an existing template_id is skipped)")
    tp.add_argument("--dry-run", action="store_true")

    dk = sub.add_parser("docker", help="build node images (run on the VM)")
    dk.add_argument("--profile", required=True)
    dk.add_argument("--only", help="comma-separated node keys, e.g. frrnode,netemnode")
    dk.add_argument("--force", action="store_true",
                    help="rebuild even if the image exists (needed after editing a Dockerfile)")
    dk.add_argument("--dry-run", action="store_true")

    fz = sub.add_parser("freeze",
                        help="docker save the built image set as a release artefact (on the VM)")
    fz.add_argument("--profile", required=True)
    fz.add_argument("--only",
                    help="comma-separated node keys (default: every image in the profile)")
    fz.add_argument("--out", required=True,
                    help="archive path; ending in .gz streams through gzip (recommended)")
    fz.add_argument("--dry-run", action="store_true")

    tw = sub.add_parser("thaw",
                        help="docker load a frozen archive, skipping the `docker` phase entirely")
    tw.add_argument("--in", dest="inp", required=True, help="archive written by `freeze`")
    tw.add_argument("--profile", default="",
                    help="only needed when the archive has no .json sidecar")
    tw.add_argument("--skip-verify", action="store_true",
                    help="don't re-hash the archive (it is several GB; verification is slow)")
    tw.add_argument("--dry-run", action="store_true")

    qm = sub.add_parser("qemu", help="download + unpack disk images (run on the VM)")
    qm.add_argument("--profile", required=True)
    qm.add_argument("--only", help="comma-separated node keys, e.g. openwrt")
    qm.add_argument("--force", action="store_true", help="re-download even if present")
    qm.add_argument("--verify", action="store_true",
                    help="re-hash images already present instead of trusting the .md5sum sidecar")
    qm.add_argument("--images-dir", help="override the manifest's qemu_images_dir")
    qm.add_argument("--dry-run", action="store_true")

    lg = sub.add_parser("logos", help="install the CQU node symbols (run on the VM)")
    lg.add_argument("--symbols-dir", help="override the manifest's symbols source dir")
    lg.add_argument("--dest", help="override the auto-detected gns3server symbols dir")
    lg.add_argument("--dry-run", action="store_true")

    ac = sub.add_parser("accel", help="set Qemu hardware acceleration in gns3_server.conf "
                                      "(run on the VM)")
    ac.add_argument("--dry-run", action="store_true")

    qs = sub.add_parser("quiesce", help="mask Ubuntu's unattended-upgrade timers "
                                        "(run on the VM)")
    qs.add_argument("--dry-run", action="store_true")

    nv = sub.add_parser("novnc",
                        help="install noVNC + the gns3-novnc service (run on the VM)")
    nv.add_argument("--dry-run", action="store_true")

    ln = sub.add_parser("labnic", help="bring up the Windows Host lab NIC (run on the VM)")
    ln.add_argument("--interface", help="override the manifest's lab_nic.interface")
    ln.add_argument("--netplan-file", help="override the manifest's lab_nic.netplan_file")
    ln.add_argument("--dry-run", action="store_true")

    pr = sub.add_parser("projects", help="import the .gns3project files in projects.txt")
    pr.add_argument("--profile", required=True)
    pr.add_argument("--server", default=os.environ.get("GNS3_SERVER", "http://localhost"))
    pr.add_argument("--roots", help="comma-separated dirs to search (overrides the manifest)")
    pr.add_argument("--record", help="write a JSON record of each source file's size and "
                                     "sha256 (feeds `provenance --imports`)")
    pr.add_argument("--dry-run", action="store_true")

    ec = sub.add_parser("export-check",
                        help="refuse to bless an OVA whose projects are not exactly "
                             "projects.txt")
    ec.add_argument("--profile", required=True)
    ec.add_argument("--server", default=os.environ.get("GNS3_SERVER", "http://localhost"))
    # No --images-dir: the installed-image check asks the controller what it has rather than
    # reading a directory, so there is no path left to override.
    ec.add_argument("--strict", action="store_true",
                    help="also fail on projects whose nodes cannot start here")

    pv = sub.add_parser("provenance", help="record what this appliance contains")
    pv.add_argument("--profile", required=True)
    pv.add_argument("--server", default=os.environ.get("GNS3_SERVER", "http://localhost"))
    pv.add_argument("--out", default="~/gns3-build-provenance.json")
    pv.add_argument("--release", help="release label for a build you are shipping to "
                                      "students, e.g. v030. Records it in the manifest, "
                                      f"stamps {RELEASE_FILE} and the motd, and warns if "
                                      "either work tree is dirty. Omit for a test build.")
    pv.add_argument("--imports", help="import record from `projects --record`")
    pv.add_argument("--images-dir", help="override the manifest's qemu_images_dir")
    pv.add_argument("--projects-dir", default="/opt/gns3/projects")
    pv.add_argument("--dry-run", action="store_true",
                    help="print the manifest instead of writing it")

    bd = sub.add_parser("build", help="run every phase in order")
    bd.add_argument("--profile", required=True)
    bd.add_argument("--server", default=os.environ.get("GNS3_SERVER", "http://localhost"))
    bd.add_argument("--only", help=f"comma-separated phases ({', '.join(BUILD_PHASES)})")
    bd.add_argument("--skip", help="comma-separated phases to leave out")
    bd.add_argument("--roots", help="project search dirs, passed to the projects phase")
    bd.add_argument("--force", action="store_true", help="passed to docker/qemu")
    bd.add_argument("--dry-run", action="store_true")

    args = ap.parse_args()
    # Line-buffer our own output so progress is visible live over ssh/ansible.
    try:
        sys.stdout.reconfigure(line_buffering=True)
    except AttributeError:                       # Python < 3.7
        pass
    return {"validate": cmd_validate, "plan": cmd_plan, "templates": cmd_templates,
            "docker": cmd_docker, "qemu": cmd_qemu, "accel": cmd_accel, "logos": cmd_logos,
            "novnc": cmd_novnc, "labnic": cmd_labnic, "quiesce": cmd_quiesce,
            "projects": cmd_projects, "build": cmd_build,
            "freeze": cmd_freeze, "thaw": cmd_thaw,
            "export-check": cmd_export_check,
            "provenance": cmd_provenance}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main() or 0)
