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
# while a stock GNS3 VM uses 3080. Read it rather than guessing.
GNS3_CONF = "~/.config/GNS3/2.2/gns3_server.conf"
DEFAULT_PORT = 3080
API_TIMEOUT = 5


def default_api():
    """Base URL of the controller on this VM: $GNS3_SERVER, else gns3_server.conf, else :3080."""
    env = os.environ.get("GNS3_SERVER")
    if env:
        return env.rstrip("/")
    port = DEFAULT_PORT
    path = os.path.expanduser(GNS3_CONF)
    if os.path.exists(path):
        cp = configparser.ConfigParser(strict=False)
        try:
            cp.read(path)
            port = cp.getint("Server", "port", fallback=DEFAULT_PORT)
        except (configparser.Error, ValueError):
            pass
    # Always localhost: the controller may listen on 0.0.0.0, but this service only ever
    # talks to the one on its own machine.
    return "http://127.0.0.1:%d" % port


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
        BasePlugin.__init__(self, src or default_api())
        self.base = self.source.rstrip("/")

    def _get(self, path):
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
                    help="GNS3 controller base URL (default: from gns3_server.conf)")
    ap.add_argument("--list", action="store_true",
                    help="print the VNC consoles this service can see, then exit")
    args = ap.parse_args(argv)

    plugin = Consoles(args.api or default_api())

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
