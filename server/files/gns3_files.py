#!/usr/bin/env python3
"""A read-only web page for getting files off this GNS3 VM: captures, and the nodes' saved files.

A link capture started from the GNS3 web UI is written to the VM's disk, and the student then
has to get it onto their own computer to open it in Wireshark: FileZilla, WinSCP or scp, plus
an SSH login, before any analysis starts. This service replaces that with a page. The student
opens http://<gns3-vm-ip>:4080/, picks the project, and clicks the capture.

What it shows, per project:
  - Captures: project-files/captures/*.pcap(ng), newest first. One still being written
    downloads as a snapshot of what has arrived so far, which Wireshark opens.
  - Nodes: for each Docker node, the directories its template persists on disk
    (project-files/docker/<node_id>/..., usually /etc, /root, /home). Only those exist outside
    the running container, so a path a node does not persist is simply not here.

Read-only by construction:
  - GET and HEAD only; every other method is refused.
  - Paths are resolved component by component with lstat. A symlink is listed but never
    followed (the persisted directories contain them), and no path can leave its project.
  - It runs as the gns3 user, so a file only root can read (/etc/shadow, the directories of a
    node that was hard-stopped) is listed as unreadable rather than served.
No login, like the GNS3 web UI on :80 and the noVNC gateway on :6080: the VM is reachable only
from the student's own host-only network.

Project names come from the GNS3 controller (for the same reason as the noVNC gateway: the API
cannot be called from a browser page on another port, because of gns3server's CORS list). Node
names come from each project's own .gns3 file, which is there whether the project is open or not.

Run as a systemd unit (gns3-files.service) installed by `gns3build.py files`, or by hand:

    python3 gns3_files.py --list                 # what it can see, then exit
    python3 gns3_files.py --port 4080
"""
import argparse
import configparser
import datetime
import glob
import html
import json
import mimetypes
import os
import re
import stat
import sys
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

API_TIMEOUT = 5
PROBE_TIMEOUT = 2
USER_CONF = "~/.config/GNS3/2.2/gns3_server.conf"
CANDIDATE_PORTS = (80, 3080)
UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
CAPTURE_SUFFIXES = (".pcap", ".pcapng")
HIDDEN = {".gns3_perms", "ubridge.log"}  # GNS3's own bookkeeping, not the node's files
VIEW_LIMIT = 1024 * 1024                 # text files up to this size open in the browser
CHUNK = 64 * 1024


# --------------------------------------------------------------------- controller ----
# The next three functions are the noVNC gateway's (server/novnc/gns3_vnc_console.py), copied
# rather than imported: that module needs python3-websockify at import time, and this service
# must not depend on it. Keep them in step: they find the controller's port the same way.

def running_config():
    """The `--config` path of the running gns3server, or None."""
    for cmdline in glob.glob("/proc/[0-9]*/cmdline"):
        try:
            with open(cmdline, "rb") as f:
                argv = f.read().decode("utf-8", "replace").split("\0")
        except OSError:
            continue
        if not any(a.endswith("gns3server") for a in argv):
            continue
        for i, a in enumerate(argv):
            if a.startswith("--config="):
                return a.split("=", 1)[1]
            if a == "--config" and i + 1 < len(argv):
                return argv[i + 1]
    return None


def config_port(path):
    path = os.path.expanduser(path or "")
    if not path or not os.path.exists(path):
        return None
    cp = configparser.ConfigParser(strict=False)
    try:
        cp.read(path)
        return cp.getint("Server", "port")
    except (configparser.Error, ValueError):
        return None


def answers(port):
    try:
        with urllib.request.urlopen("http://127.0.0.1:%d/v2/version" % port,
                                    timeout=PROBE_TIMEOUT) as r:
            return "version" in json.loads(r.read().decode())
    except (urllib.error.URLError, OSError, ValueError):
        return False


def default_api():
    env = os.environ.get("GNS3_SERVER")
    if env:
        return env.rstrip("/")
    for path in (running_config(), USER_CONF):
        port = config_port(path)
        if port:
            return "http://127.0.0.1:%d" % port
    for port in CANDIDATE_PORTS:
        if answers(port):
            return "http://127.0.0.1:%d" % port
    return "http://127.0.0.1:%d" % CANDIDATE_PORTS[0]


def api_get(api, path):
    with urllib.request.urlopen(api + "/v2" + path, timeout=API_TIMEOUT) as r:
        return json.loads(r.read().decode())


# ----------------------------------------------------------------------- the disk ----

class Project:
    def __init__(self, info):
        self.id = info["project_id"]
        self.name = info.get("name") or self.id
        self.path = info.get("path") or ""
        self.opened = info.get("status") == "opened"

    def gns3_file(self):
        """This project's own .gns3 file: the topology, whether or not the project is open."""
        try:
            names = [n for n in os.listdir(self.path) if n.endswith(".gns3")]
        except OSError:
            return None
        for n in sorted(names):
            if n == self.name + ".gns3":
                return os.path.join(self.path, n)
        return os.path.join(self.path, names[0]) if names else None

    def docker_nodes(self):
        """[(node_id, name)] of this project's Docker nodes, by name."""
        f = self.gns3_file()
        try:
            with open(f) as fh:
                doc = json.load(fh)
        except (OSError, TypeError, ValueError):
            return []
        nodes = (doc.get("topology") or {}).get("nodes") or []
        out = [(n.get("node_id"), n.get("name") or n.get("node_id")) for n in nodes
               if n.get("node_type") == "docker" and UUID.match(n.get("node_id") or "")]
        return sorted(out, key=lambda t: t[1].lower())

    def captures(self):
        d = os.path.join(self.path, "project-files", "captures")
        out = []
        try:
            entries = os.listdir(d)
        except OSError:
            return out
        for n in entries:
            if not n.lower().endswith(CAPTURE_SUFFIXES):
                continue
            try:
                st = os.lstat(os.path.join(d, n))
            except OSError:
                continue
            if stat.S_ISREG(st.st_mode):
                out.append((n, st))
        return sorted(out, key=lambda t: -t[1].st_mtime)


def projects(api):
    """(list of Project, error or None). Open projects first, then by name."""
    try:
        infos = api_get(api, "/projects")
    except (urllib.error.URLError, OSError, ValueError) as e:
        return [], "the GNS3 server at %s did not answer (%s)" % (api, e)
    ps = [Project(i) for i in infos if UUID.match(i.get("project_id") or "")]
    return sorted(ps, key=lambda p: (not p.opened, p.name.lower())), None


def capturing(api, project):
    """{capture file name: True} for links capturing now. Only an open project has live links."""
    if not project.opened:
        return set()
    try:
        links = api_get(api, "/projects/%s/links" % project.id)
    except (urllib.error.URLError, OSError, ValueError):
        return set()
    return {l.get("capture_file_name") for l in links if l.get("capturing")}


def safe_walk(root, parts):
    """Resolve `parts` under `root` without following symlinks.

    Returns (path, lstat result, problem). `problem` is None for a normal file or directory,
    'symlink' if the last component is one, or a reason the path cannot be served. A symlink in
    the middle of the path is a reason: following it is how a path would leave the project.
    """
    path = root
    for i, p in enumerate(parts):
        if p in ("", ".", "..") or "/" in p or "\0" in p or p in HIDDEN:
            return None, None, "bad path"
        path = os.path.join(path, p)
        try:
            st = os.lstat(path)
        except FileNotFoundError:
            return None, None, "not found"
        except OSError:
            return None, None, "unreadable"
        if stat.S_ISLNK(st.st_mode):
            return path, st, "symlink" if i == len(parts) - 1 else "path goes through a symlink"
    try:
        return path, os.lstat(path), None
    except OSError:
        return None, None, "unreadable"


# ----------------------------------------------------------------------- the page ----

STYLE = """
  :root { --bg:#f6f7f9; --card:#fff; --ink:#1c2024; --dim:#5b6570; --line:#dfe3e8;
          --accent:#00693c; --accent-ink:#fff; --warn:#8a5a00; }
  @media (prefers-color-scheme: dark) {
    :root { --bg:#16191c; --card:#1f2429; --ink:#e8eaed; --dim:#a3adb8; --line:#333b43;
            --accent:#2f9c68; --accent-ink:#08120c; --warn:#e0b050; } }
  * { box-sizing: border-box; }
  body { margin:0; padding:2rem 1rem 3rem; background:var(--bg); color:var(--ink);
         font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Arial,sans-serif; }
  main { max-width:48rem; margin:0 auto; }
  h1 { font-size:1.5rem; margin:0 0 .25rem; } h2 { font-size:1.1rem; margin:1.75rem 0 .5rem; }
  p.lede { margin:0 0 1.25rem; color:var(--dim); }
  nav { margin:0 0 1rem; font-size:.9rem; } nav a { color:var(--accent); }
  ul { list-style:none; margin:0; padding:0; }
  li { display:flex; align-items:center; gap:1rem; flex-wrap:wrap; background:var(--card);
       border:1px solid var(--line); border-radius:8px; padding:.7rem 1rem; margin-bottom:.5rem; }
  .who { flex:1 1 14rem; min-width:0; overflow-wrap:anywhere; }
  .name { font-weight:600; } .name a { color:inherit; }
  .meta { color:var(--dim); font-size:.85rem; }
  a.btn { display:inline-block; padding:.4rem 1rem; border-radius:6px; font-weight:600;
          text-decoration:none; white-space:nowrap; background:var(--accent); color:var(--accent-ink); }
  a.btn:hover { filter:brightness(1.1); }
  .tag { color:var(--warn); font-size:.85rem; }
  .note { background:var(--card); border:1px solid var(--line); border-radius:8px; padding:1rem;
          color:var(--dim); }
  code { font-size:.9em; }
"""


def human(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return ("%d %s" % (n, unit)) if unit == "B" else ("%.1f %s" % (n, unit))
        n /= 1024.0


def when(ts):
    return datetime.datetime.fromtimestamp(ts).strftime("%d %b %Y %H:%M")


def esc(s):
    return html.escape(str(s), quote=True)


def q(s):
    return urllib.parse.quote(s, safe="")


def page(title, body, crumbs=()):
    nav = ""
    if crumbs:
        nav = "<nav>" + " / ".join(
            '<a href="%s">%s</a>' % (esc(href), esc(label)) if href else esc(label)
            for href, label in crumbs) + "</nav>"
    return ("<!DOCTYPE html><html lang=\"en-AU\"><head><meta charset=\"utf-8\">"
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
            "<title>%s</title><style>%s</style></head><body><main>%s%s</main></body></html>"
            % (esc(title), STYLE, nav, body)).encode()


def item(name_html, meta, button=""):
    return ('<li><div class="who"><div class="name">%s</div><div class="meta">%s</div></div>%s</li>'
            % (name_html, meta, button))


# ---------------------------------------------------------------------- the server ----

class Handler(BaseHTTPRequestHandler):
    server_version = "gns3-files"
    api = None

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    # Read-only: anything but GET and HEAD is refused outright.
    def _refuse(self):
        self.send_error(405, "This page is read-only")
    do_POST = do_PUT = do_DELETE = do_PATCH = _refuse

    def do_HEAD(self):
        self.do_GET(head=True)

    def do_GET(self, head=False):
        self.head = head
        url = urllib.parse.urlsplit(self.path)
        parts = [urllib.parse.unquote(p) for p in url.path.split("/") if p]
        try:
            if not parts:
                return self.index()
            if parts[0] == "p" and len(parts) >= 2 and UUID.match(parts[1]):
                project = self.find(parts[1])
                if project is None:
                    return self.send_error(404, "No such project")
                if len(parts) == 2:
                    return self.project(project)
                if parts[2] == "captures" and len(parts) == 4:
                    return self.capture(project, parts[3])
                if parts[2] == "n" and len(parts) >= 4 and UUID.match(parts[3]):
                    return self.node(project, parts[3], parts[4:])
            return self.send_error(404)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def find(self, pid):
        ps, _ = projects(self.api)
        for p in ps:
            if p.id == pid:
                return p
        return None

    def send_page(self, body, code=200):
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if not self.head:
            self.wfile.write(body)

    # ------------------------------------------------------------------ pages ----
    def index(self):
        ps, err = projects(self.api)
        rows = []
        for p in ps:
            caps = p.captures()
            meta = ("open" if p.opened else "closed") + " · %d capture%s" % (
                len(caps), "" if len(caps) == 1 else "s")
            if caps:
                meta += ", latest %s" % when(caps[0][1].st_mtime)
            rows.append(item('<a href="/p/%s">%s</a>' % (p.id, esc(p.name)), esc(meta),
                             '<a class="btn" href="/p/%s">Open</a>' % p.id))
        if err:
            body = '<div class="note">%s</div>' % esc(err)
        elif not rows:
            body = '<div class="note">There are no projects on this GNS3 VM yet.</div>'
        else:
            body = "<ul>%s</ul>" % "".join(rows)
        self.send_page(page("GNS3 files", (
            "<h1>Files on this GNS3 VM</h1>"
            "<p class=\"lede\">Download packet captures to open in Wireshark, and the files your "
            "nodes have saved. Read-only: nothing here can change the VM.</p>" + body)))

    def project(self, p):
        live = capturing(self.api, p)
        caps = []
        for name, st in p.captures():
            tag = (' <span class="tag">capturing now: the download is what has arrived so '
                   'far</span>' if name in live else "")
            caps.append(item(esc(name) + tag, "%s · %s" % (human(st.st_size), when(st.st_mtime)),
                             '<a class="btn" href="/p/%s/captures/%s">Download</a>'
                             % (p.id, q(name))))
        nodes = []
        for nid, name in p.docker_nodes():
            base = os.path.join(p.path, "project-files", "docker", nid)
            try:
                dirs = sorted(d for d in os.listdir(base) if d not in HIDDEN)
            except OSError:
                dirs = None
            if dirs is None:
                meta = "no saved files yet (the node has not been started)"
            elif not dirs:
                meta = "this node saves nothing to disk"
            else:
                meta = "saves " + ", ".join("/" + d for d in dirs)
            link = ('<a href="/p/%s/n/%s/">%s</a>' % (p.id, nid, esc(name)) if dirs
                    else esc(name))
            nodes.append(item(link, esc(meta),
                              '<a class="btn" href="/p/%s/n/%s/">Browse</a>' % (p.id, nid)
                              if dirs else ""))
        body = ("<h1>%s</h1><p class=\"lede\">%s</p><h2>Captures</h2>%s<h2>Nodes</h2>%s" % (
            esc(p.name),
            "Open in GNS3." if p.opened else "Closed in GNS3: these are the files it saved.",
            "<ul>%s</ul>" % "".join(caps) if caps else
            '<div class="note">No captures yet. In GNS3, right-click a link and choose '
            '<b>Start capture</b>; the file appears here.</div>',
            "<ul>%s</ul>" % "".join(nodes) if nodes else
            '<div class="note">This project has no Docker nodes.</div>'))
        self.send_page(page(p.name, body, [("/", "All projects"), (None, p.name)]))

    # -------------------------------------------------------------- downloads ----
    def capture(self, p, name):
        if not name.lower().endswith(CAPTURE_SUFFIXES):
            return self.send_error(404)
        path, st, problem = safe_walk(os.path.join(p.path, "project-files", "captures"), [name])
        if problem or not stat.S_ISREG(st.st_mode):
            return self.send_error(404 if problem == "not found" else 403, problem or "not a file")
        self.send_file(path, st, name, "application/vnd.tcpdump.pcap", attachment=True)

    def node(self, p, nid, parts):
        names = dict(p.docker_nodes())
        if nid not in names:
            return self.send_error(404, "No such node")
        root = os.path.join(p.path, "project-files", "docker", nid)
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query,
                                      keep_blank_values=True)
        download = "download" in query
        if parts:
            path, st, problem = safe_walk(root, parts)
        else:
            path, st, problem = root, None, None
            try:
                st = os.lstat(root)
            except OSError:
                problem = "not found"
        if problem:
            return self.send_error(404 if problem == "not found" else 403, problem)
        if stat.S_ISDIR(st.st_mode):
            return self.listing(p, nid, names[nid], root, parts, path)
        if not stat.S_ISREG(st.st_mode):
            return self.send_error(403, "not a regular file")
        if not os.access(path, os.R_OK):
            return self.send_error(403, "unreadable")
        ctype, attach = self.kind(path, st)
        self.send_file(path, st, parts[-1], ctype, attachment=attach or download)

    def listing(self, p, nid, node_name, root, parts, path):
        base = "/p/%s/n/%s/" % (p.id, nid)
        here = "/" + "/".join(parts)
        try:
            entries = sorted(os.listdir(path), key=lambda n: n.lower())
        except OSError:
            return self.send_error(403, "unreadable")
        rows = []
        for n in entries:
            if n in HIDDEN:
                continue
            full = os.path.join(path, n)
            href = base + "/".join(q(x) for x in parts + [n])
            try:
                st = os.lstat(full)
            except OSError:
                continue
            if stat.S_ISLNK(st.st_mode):
                try:
                    target = os.readlink(full)
                except OSError:
                    target = "?"
                rows.append(item(esc(n), "link to " + esc(target) + " (not followed)"))
            elif stat.S_ISDIR(st.st_mode):
                ok = os.access(full, os.R_OK | os.X_OK)
                rows.append(item('<a href="%s/">%s/</a>' % (esc(href), esc(n)) if ok else esc(n + "/"),
                                 "folder" if ok else "folder · only root can read it"))
            elif stat.S_ISREG(st.st_mode):
                ok = os.access(full, os.R_OK)
                meta = "%s · %s" % (human(st.st_size), when(st.st_mtime))
                if not ok:
                    rows.append(item(esc(n), meta + " · only root can read it"))
                else:
                    rows.append(item('<a href="%s">%s</a>' % (esc(href), esc(n)), meta,
                                     '<a class="btn" href="%s?download">Download</a>' % esc(href)))
        crumbs = [("/", "All projects"), ("/p/%s" % p.id, p.name), (base, node_name)]
        for i, x in enumerate(parts):
            crumbs.append((base + "/".join(q(y) for y in parts[:i + 1]) + "/"
                           if i < len(parts) - 1 else None, x))
        body = ("<h1>%s <span class=\"meta\">%s</span></h1>"
                "<p class=\"lede\">The files this node has saved. Click a text file to read it, or "
                "<b>Download</b> to save it.</p>%s" % (
                    esc(node_name), esc(here),
                    "<ul>%s</ul>" % "".join(rows) if rows else
                    '<div class="note">This folder is empty.</div>'))
        self.send_page(page("%s %s" % (node_name, here), body, crumbs))

    @staticmethod
    def kind(path, st):
        """(content type, download?) — small UTF-8 text opens in the browser, the rest downloads."""
        if st.st_size <= VIEW_LIMIT:
            try:
                with open(path, "rb") as f:
                    data = f.read(VIEW_LIMIT)
                if b"\0" not in data:
                    data.decode("utf-8")
                    return "text/plain; charset=utf-8", False
            except (OSError, UnicodeDecodeError):
                pass
        return mimetypes.guess_type(path)[0] or "application/octet-stream", True

    def send_file(self, path, st, name, ctype, attachment):
        try:
            f = open(path, "rb")
        except OSError:
            return self.send_error(403, "unreadable")
        with f:
            size = os.fstat(f.fileno()).st_size       # a capture can grow between lstat and here
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(size))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            disp = "attachment" if attachment else "inline"
            self.send_header("Content-Disposition", "%s; filename*=UTF-8''%s" % (disp, q(name)))
            self.end_headers()
            if self.head:
                return
            left = size
            while left > 0:
                chunk = f.read(min(CHUNK, left))
                if not chunk:
                    break
                self.wfile.write(chunk)
                left -= len(chunk)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--port", type=int, default=4080)
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--api", default=None, help="GNS3 controller URL (default: found locally)")
    ap.add_argument("--list", action="store_true", help="print what is visible and exit")
    args = ap.parse_args(argv)
    api = args.api or default_api()

    if args.list:
        ps, err = projects(api)
        print("controller: %s%s" % (api, "  (" + err + ")" if err else ""))
        for p in ps:
            print("%-30s %-6s %d capture(s), %d docker node(s)" % (
                p.name, "open" if p.opened else "closed", len(p.captures()), len(p.docker_nodes())))
        return 0

    Handler.api = api
    srv = ThreadingHTTPServer((args.bind, args.port), Handler)
    srv.daemon_threads = True
    print("gns3-files on http://%s:%d/ (controller %s)" % (args.bind, args.port, api), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
