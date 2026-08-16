#!/usr/bin/env python3
"""One browser gateway to every VNC console on this GNS3 VM.

Some nodes have a VNC console instead of a terminal — the Firefox Host is the one students
meet, and ReactOS is another. The GNS3 web UI cannot show those: it draws consoles with
xterm.js and ships no VNC client at all, so a VNC node is the one thing a student cannot
reach from the browser they already have open.

The old answer was for the student to enter the GNS3 VM's shell and run

    ./start-vnc.sh 5900 6080          # one bridge, one node, gone after a reboot

which is four steps of setup before the activity starts, twice over when an activity has two
Firefox Hosts. This service replaces that with a page: the appliance runs one websockify on
one port from boot, and the student opens http://<gns3-vm-ip>:6080/ and clicks a node.

How one listener reaches every node
-----------------------------------
websockify normally proxies to a single fixed target. Its `--token-plugin` hook instead asks
a plugin, per connection, where to connect — so the token in the URL names the node and one
listener serves them all. `Consoles` below is that plugin, and it answers from the GNS3
controller API: the console port of a *started* VNC node in an *open* project, on localhost,
and nothing else. That is narrower than the script it replaces, which would bridge any port
it was given.

The picker page needs the same list, and cannot fetch it itself: gns3server's CORS whitelist
is six hardcoded origins (127.0.0.1/localhost on 3080 and 4200, gns3.github.io), so a page
served from :6080 is refused. `Handler` therefore serves /nodes.json from this process, which
is also why the proxy is built here rather than by running the stock websockify binary.

Run as a systemd unit (see gns3-novnc.service) installed by `gns3build.py novnc`. It can also
be run by hand, which is the quickest way to see what it can see:

    python3 gns3_vnc_console.py --list
    python3 gns3_vnc_console.py --port 6080 --web /usr/local/share/gns3-novnc
"""
import argparse
import configparser
import glob
import json
import os
import sys
import urllib.error
import urllib.request
from urllib.parse import urlparse

try:
    from websockify.token_plugins import BasePlugin
    from websockify.websocketproxy import ProxyRequestHandler, WebSocketProxy
except ImportError:
    sys.exit("python3-websockify is required: sudo apt-get install -y python3-websockify")

# Where gns3server keeps its config. The port matters and is not always the documented
# default: this appliance serves the web UI on 80 so students can browse to the bare IP,
# while a stock GNS3 VM uses 3080. Read it rather than guessing — and do not hardcode *which*
# file to read, which is how this broke once already. The GNS3 VM up to 2.2.54 left gns3server
# on the user path below; the 2.2.61 VM starts it with `--config /opt/gns3/server/
# gns3_server.conf`, and an explicit --config makes that the only file loaded. Reading the old
# path there yields no `port` at all, so the service fell back to 3080, nothing was listening,
# and every student saw "Connection refused" on a working appliance.
USER_CONF = "~/.config/GNS3/2.2/gns3_server.conf"
CANDIDATE_PORTS = (80, 3080)          # this appliance, then a stock GNS3 VM
API_TIMEOUT = 5
PROBE_TIMEOUT = 2


def running_config():
    """The `--config` path of the running gns3server, or None."""
    for cmdline in glob.glob("/proc/[0-9]*/cmdline"):
        try:
            with open(cmdline, "rb") as f:
                argv = f.read().decode("utf-8", "replace").split("\0")
        except OSError:
            continue                  # the process exited while we were walking /proc
        if not any(a.endswith("gns3server") for a in argv):
            continue
        for i, a in enumerate(argv):
            if a.startswith("--config="):
                return a.split("=", 1)[1]
            if a == "--config" and i + 1 < len(argv):
                return argv[i + 1]
    return None


def config_port(path):
    """`[Server] port` from an ini file, or None if the file or the key is absent."""
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
    """True if a GNS3 controller answers /v2/version on localhost:port."""
    try:
        with urllib.request.urlopen("http://127.0.0.1:%d/v2/version" % port,
                                    timeout=PROBE_TIMEOUT) as r:
            return "version" in json.loads(r.read().decode())
    except (urllib.error.URLError, OSError, ValueError):
        return False


def default_api():
    """Base URL of the controller on this VM.

    $GNS3_SERVER wins, then the port named by the config file the running server was actually
    given, then the historical user path, and finally the ports themselves — a live
    /v2/version is the only answer that cannot be stale, and it is what makes this survive the
    next time the VM's layout moves.

    Always localhost: the controller may listen on 0.0.0.0, but this service only ever talks
    to the one on its own machine.
    """
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


class Consoles(BasePlugin):
    """websockify token plugin: token -> the VNC console of a node on this VM.

    A token is either a node name (`Host2`, or `Project/Host2` when two open projects both
    have one) or the console port itself (`5900`). The picker page uses the port, because it
    has just read the list and the port cannot be ambiguous; a hand-written URL in an
    activity's instructions is better off with the name, which survives the port changing.

    Anything that does not resolve to a started VNC node returns None, and websockify closes
    the connection with "Token not found".
    """

    def __init__(self, src=None):
        BasePlugin.__init__(self, src or "")
        # An explicit --api is a promise; anything else is a guess we are allowed to revise.
        self.pinned = (src or "").rstrip("/") or None
        self.base = self.pinned or default_api()

    def _get(self, path):
        try:
            return self._fetch(path)
        except (urllib.error.URLError, OSError):
            # The controller may not have been up when we resolved it — this service starts
            # alongside gns3.service, not after it, and `Restart=always` means a wrong guess
            # would otherwise stick for the life of the VM. Re-resolve once, then retry.
            if self.pinned:
                raise
            base = default_api()
            if base == self.base:
                raise
            print("gns3-novnc: controller re-resolved to %s" % base, file=sys.stderr)
            self.base = base
            return self._fetch(path)

    def _fetch(self, path):
        with urllib.request.urlopen(self.base + path, timeout=API_TIMEOUT) as r:
            return json.loads(r.read().decode())

    def nodes(self):
        """Every VNC node in every open project, started or not, sorted for display.

        Stopped nodes are kept deliberately: "Host2 — not started" on the page is a much
        better answer for a student than an empty list they cannot explain.
        """
        found = []
        for proj in self._get("/v2/projects"):
            if proj.get("status") != "opened":
                continue
            for n in self._get("/v2/projects/%s/nodes" % proj["project_id"]):
                if n.get("console_type") != "vnc" or not n.get("console"):
                    continue
                found.append({
                    "name": n.get("name") or "?",
                    "project": proj.get("name") or "?",
                    "port": int(n["console"]),
                    "status": n.get("status") or "unknown",
                })
        found.sort(key=lambda d: (d["project"], d["port"]))
        return found

    def lookup(self, token):
        token = (token or "").strip()
        try:
            live = [n for n in self.nodes() if n["status"] == "started"]
        except (urllib.error.URLError, OSError, ValueError) as e:
            print("gns3-novnc: cannot reach the GNS3 controller at %s: %s" % (self.base, e),
                  file=sys.stderr)
            return None

        if token.isdigit():
            port = int(token)
            for n in live:
                if n["port"] == port:
                    return ("127.0.0.1", port)
        low = token.lower()
        for n in live:
            if low in (n["name"].lower(), "%s/%s" % (n["project"].lower(), n["name"].lower())):
                return ("127.0.0.1", n["port"])

        print("gns3-novnc: no started VNC node matches token %r (have: %s)"
              % (token, ", ".join("%s:%d" % (n["name"], n["port"]) for n in live) or "none"),
              file=sys.stderr)
        return None


class Handler(ProxyRequestHandler):
    """The stock websockify handler plus one route: GET /nodes.json for the picker page."""

    def do_GET(self):
        if urlparse(self.path).path == "/nodes.json":
            return self.send_nodes()
        return ProxyRequestHandler.do_GET(self)

    def send_nodes(self):
        try:
            body = {"nodes": self.server.token_plugin.nodes()}
        except (urllib.error.URLError, OSError, ValueError) as e:
            # The controller being down is a normal state (a rebooting VM, a restarted
            # service), not a server error here — report it in the body so the page can say
            # something useful instead of showing a failed fetch.
            body = {"nodes": [], "error": "cannot reach the GNS3 server: %s" % e}
        raw = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(raw)


def main(argv=None):
    ap = argparse.ArgumentParser(description="noVNC gateway for GNS3 VNC consoles")
    ap.add_argument("--listen", default="0.0.0.0", help="address to serve on (default: all)")
    ap.add_argument("--port", type=int, default=6080, help="port to serve on (default: 6080)")
    ap.add_argument("--web", default="/usr/local/share/gns3-novnc",
                    help="web root holding index.html and the novnc symlink")
    ap.add_argument("--api", default=None,
                    help="GNS3 controller base URL, pinned (default: discover it)")
    ap.add_argument("--list", action="store_true",
                    help="print the VNC consoles this service can see, then exit")
    args = ap.parse_args(argv)

    plugin = Consoles(args.api)

    if args.list:
        print("controller: %s" % plugin.base)
        try:
            nodes = plugin.nodes()
        except (urllib.error.URLError, OSError, ValueError) as e:
            sys.exit("cannot reach the GNS3 controller: %s" % e)
        if not nodes:
            print("no VNC nodes in any open project")
            return 0
        for n in nodes:
            print("  %-20s %-24s port %d  %s"
                  % (n["name"], n["project"], n["port"], n["status"]))
        return 0

    if not os.path.isdir(args.web):
        sys.exit("web root not found: %s (run `gns3build.py novnc`)" % args.web)

    print("gns3-novnc: http://<this-vm>:%d/  controller %s  web %s"
          % (args.port, plugin.base, args.web))
    WebSocketProxy(
        RequestHandlerClass=Handler,
        listen_host=args.listen,
        listen_port=args.port,
        web=args.web,
        file_only=True,          # serve files, never a directory listing
        token_plugin=plugin,
        verbose=False,
        traffic=False,
    ).start_server()
    return 0


if __name__ == "__main__":
    sys.exit(main())
