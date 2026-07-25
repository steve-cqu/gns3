#!/usr/bin/env python3
"""
gns3build.py — data-driven, idempotent GNS3 VM build.

Reads build/manifest.yml and drives node/template installation, replacing the
vm-install-*.sh scripts' 400-line case statement. Templates are registered through the
GNS3 REST API (POST /v2/templates), which is additive and idempotent — existing
template_ids are skipped — so there is no gns3_controller.conf text-assembly and no
`systemctl stop/start gns3`.

Subcommands
  validate                  parse the manifest + every referenced template .conf; report issues
  plan      --profile P     show what a full build of profile P would install (no changes)
  templates --profile P     register profile P's templates via the controller API
  docker    --profile P     build the profile's docker node images        [run on the VM]
  qemu      --profile P     download + unpack the profile's Qemu images   [run on the VM]
  logos                     install the CQU node symbols                  [run on the VM]
  novnc                     install noVNC + start-vnc.sh                  [run on the VM]
  projects  --profile P     import the audience's .gns3project files
  build     --profile P     every phase above, in order

`validate`/`plan`/`templates`/`projects` work from anywhere (they take --server URL,
default $GNS3_SERVER or http://localhost). `docker`, `qemu`, `logos` and `novnc` touch the
local docker daemon and filesystem, so they run **on the GNS3 VM** — the Ansible wrapper
syncs this tree there and invokes them over SSH.

Profiles are {pc,mac}-{student,staff}: the platform picks the arch (pc -> amd64 images and
amd64 Qemu disks, mac -> arm64), the audience picks the project set.

Every phase is idempotent: an image that already exists (docker) or a verified disk image
already in place (qemu) is skipped, so re-running is cheap. --force rebuilds/re-downloads,
--dry-run previews without writing.
"""
import argparse
import bz2
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.error
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


def md5_of(path, chunk=1 << 20):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(chunk), b""):
            h.update(block)
    return h.hexdigest()


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

    def projects(self):
        return self._req("GET", "/projects")

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
# Phase: docker — build the node images (runs on the VM)
# --------------------------------------------------------------------------- #
def image_exists(image):
    return subprocess.run(["docker", "image", "inspect", image],
                          stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode == 0


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
        for fname in src["files"]:
            download(f"{base}/{fname}", ctx / fname)
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
# Phase: novnc — browser access to VNC nodes (runs on the VM)
# --------------------------------------------------------------------------- #
def apt_installed(pkg):
    r = subprocess.run(["dpkg-query", "-W", "-f=${Status}", pkg],
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                       universal_newlines=True)
    return r.returncode == 0 and "install ok installed" in (r.stdout or "")


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
    return 0


# --------------------------------------------------------------------------- #
# Phase: projects — import the audience's .gns3project files via the API
# --------------------------------------------------------------------------- #
def read_project_list(m, audience):
    """Names from projects-<audience>.txt (the file has no trailing newline)."""
    f = (m["_dir"] / m["paths"].get("lists_dir", "..") / f"projects-{audience}.txt").resolve()
    if not f.exists():
        sys.exit(f"project list not found: {f}")
    names = []
    for line in f.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            names.append(line)
    return f, names


def find_project_files(name, roots):
    """Every <name>.gns3project under roots, in root order — the first one is used.

    All matches are returned, not just the winner, because copies of one project can
    disagree while sharing a project_id (an exported byproduct left in outfiles/ next to
    a rebuilt project in activities/). Identical ids make the skip-if-exists check blind
    to the difference, so importing the stale copy silently shadows the good one. Put the
    authoritative root first, and heed the warning when this returns more than one.
    """
    hits = []
    for root in roots:
        root = Path(os.path.expanduser(str(root)))
        if not root.is_dir():
            continue
        direct = root / f"{name}.gns3project"
        if direct.is_file():
            hits.append(direct)
            continue
        hits.extend(sorted(root.rglob(f"{name}.gns3project")))
    return hits


def project_id_of(path):
    """Read project_id out of the project.gns3 inside the .gns3project zip."""
    with zipfile.ZipFile(str(path)) as z:
        with z.open("project.gns3") as f:
            return json.load(f).get("project_id")


def cmd_projects(args):
    m = load_manifest(args.manifest)
    if args.profile not in m["profiles"]:
        sys.exit(f"unknown profile '{args.profile}' (have: {', '.join(m['profiles'])})")
    audience = m["profiles"][args.profile]["audience"]
    list_file, names = read_project_list(m, audience)
    roots = ([r.strip() for r in args.roots.split(",") if r.strip()] if args.roots
             else m.get("project_roots", ["/home/gns3/projects"]))

    ctrl = Controller(args.server)
    try:
        ver = ctrl.version()
    except urllib.error.URLError as e:
        sys.exit(f"cannot reach controller at {args.server}: {e}")
    print(f"controller {args.server} — GNS3 {ver}")
    print(f"profile {args.profile}  (audience: {audience}) — {list_file.name}, "
          f"{len(names)} project(s)")
    print(f"roots: {', '.join(str(r) for r in roots)}\n")

    existing = {p["project_id"] for p in ctrl.projects()}
    imported = skipped = 0
    notfound, failures, shadowed = [], [], []
    for name in names:
        hits = find_project_files(name, roots)
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
            print(f"  ERROR  {name}: HTTP {e.code} {e.read().decode(errors='replace')[:200]}")
            failures.append(name)
        except Exception as e:
            print(f"  ERROR  {name}: {e}")
            failures.append(name)

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
# Phase: build — run every phase in order
# --------------------------------------------------------------------------- #
BUILD_PHASES = ["templates", "docker", "qemu", "logos", "novnc", "projects"]


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

    handlers = {"templates": cmd_templates, "docker": cmd_docker, "qemu": cmd_qemu,
                "logos": cmd_logos, "novnc": cmd_novnc, "projects": cmd_projects}
    # Every phase reads its options off one namespace; unused ones are simply ignored.
    common = argparse.Namespace(
        manifest=args.manifest, profile=args.profile, server=args.server,
        dry_run=args.dry_run, force=args.force, only=None, skip=None, verify=False,
        images_dir=None, symbols_dir=None, dest=None, roots=args.roots)

    print(f"build profile {args.profile}: {' -> '.join(phases)}\n")
    results = []
    for phase in phases:
        print(f"\n{'=' * 70}\n== phase: {phase}\n{'=' * 70}")
        try:
            rc = handlers[phase](common) or 0
        except SystemExit as e:                       # a phase's sys.exit(msg)
            print(f"== phase {phase} aborted: {e}")
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
    tp.add_argument("--dry-run", action="store_true")

    dk = sub.add_parser("docker", help="build node images (run on the VM)")
    dk.add_argument("--profile", required=True)
    dk.add_argument("--only", help="comma-separated node keys, e.g. frrnode,netemnode")
    dk.add_argument("--force", action="store_true",
                    help="rebuild even if the image exists (needed after editing a Dockerfile)")
    dk.add_argument("--dry-run", action="store_true")

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

    nv = sub.add_parser("novnc", help="install noVNC + start-vnc.sh (run on the VM)")
    nv.add_argument("--dry-run", action="store_true")

    pr = sub.add_parser("projects", help="import the audience's .gns3project files")
    pr.add_argument("--profile", required=True)
    pr.add_argument("--server", default=os.environ.get("GNS3_SERVER", "http://localhost"))
    pr.add_argument("--roots", help="comma-separated dirs to search (overrides the manifest)")
    pr.add_argument("--dry-run", action="store_true")

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
            "docker": cmd_docker, "qemu": cmd_qemu, "logos": cmd_logos,
            "novnc": cmd_novnc, "projects": cmd_projects, "build": cmd_build}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main() or 0)
