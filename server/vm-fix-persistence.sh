#!/bin/sh
# vm-fix-persistence.sh - make configuration on GNS3 Docker nodes survive closing a project.
#
# Run this ON the GNS3 VM (drop to the shell from the VM menu), once.
#
# Why: a Docker node is rebuilt from its image every time a project is closed and reopened.
# Only directories GNS3 has been told to keep survive. Out of the box that is just a handful
# (/etc/ssh, /root/.ssh, /data, /home/student), so work such as a CA under /root, a WireGuard
# key in /etc/wireguard or a Kerberos database in /var/lib/krb5kdc is lost.
#
# What it does: sets the "Additional directories" (extra_volumes) property on the Docker node
# templates, through the GNS3 API. The web interface has no field for this, which is why a
# script is needed. Safe to run more than once.
#
# What it does NOT do: it does not touch projects you have already built. Templates only apply
# to nodes created after this runs. For an existing project, either add the directories by hand
# on each node (Configure > Advanced > Additional directories) or rebuild the project.
#
# Usage:
#   ./vm-fix-persistence.sh              apply the changes
#   ./vm-fix-persistence.sh --dry-run    show what would change, change nothing
#   ./vm-fix-persistence.sh --list       show the current setting on every Docker template
#
# Staff only: set GNS3_API to point at a server other than this machine, e.g.
#   GNS3_API=http://192.168.56.112 ./vm-fix-persistence.sh --dry-run

set -eu

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        --dry-run|--list) ;;
        *)
            echo "unknown option: $arg (try --help)" >&2
            exit 2
            ;;
    esac
done

command -v python3 >/dev/null 2>&1 || { echo "error: python3 not found" >&2; exit 1; }

exec python3 - "$@" <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request

DRY = "--dry-run" in sys.argv
LIST = "--list" in sys.argv

# Directories to keep, per template. Chosen to cover what the COIT12202 activities write:
#   /etc              sshd_config, wireguard, ssl, nginx, pam.d, security, shadow, hosts
#   /root             an openssl CA tree, ssh CA keys, scratch files
#   /var/www          pages served by the activity web servers
#   /home             extra user accounts created during password activities (Ubuntu)
#   /var/lib/krb5kdc  the Kerberos database created by kdb5_util
# Templates absent from this map are left exactly as they are.
WANTED = {
    "Linux Host":    ["/etc", "/root", "/var/www"],
    "Linux Router":  ["/etc", "/root", "/var/www"],
    "VPN Router":    ["/etc", "/root", "/var/www"],
    "Ansible Host":  ["/etc", "/root", "/var/www"],
    "Ubuntu Host":   ["/etc", "/root", "/var/www", "/home"],
    "Kerberos Host": ["/root", "/var/lib/krb5kdc"],
    "Suricata IDS":  ["/etc", "/root"],
    "NAT64Router":   ["/etc", "/root"],
}

# Port 80 on the CQU VM; 3080 is the GNS3 default, kept as a fallback for older builds.
CANDIDATES = ["http://127.0.0.1", "http://127.0.0.1:3080", "http://localhost", "http://localhost:3080"]


def req(method, url, body=None, timeout=20):
    data = None
    headers = {}
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    r = urllib.request.Request(url, data=data, method=method, headers=headers)
    with urllib.request.urlopen(r, timeout=timeout) as resp:
        raw = resp.read()
    return json.loads(raw) if raw else None


def find_api():
    override = os.environ.get("GNS3_API")
    for base in ([override] if override else CANDIDATES):
        try:
            v = req("GET", base + "/v2/version", timeout=5)
            return base, v.get("version", "?")
        except Exception:
            continue
    return None, None


base, version = find_api()
if not base:
    sys.stderr.write(
        "error: could not reach the GNS3 server on this machine.\n"
        "       Tried: " + ", ".join(CANDIDATES) + "\n"
        "       Are you running this on the GNS3 VM, and is GNS3 running?\n")
    sys.exit(1)

print("GNS3 server %s at %s" % (version, base))

try:
    templates = req("GET", base + "/v2/templates")
except urllib.error.URLError as e:
    sys.stderr.write("error: could not list templates: %s\n" % e)
    sys.exit(1)

docker = [t for t in templates if t.get("template_type") == "docker"]
if not docker:
    sys.stderr.write("error: no Docker templates found on this server\n")
    sys.exit(1)

if LIST:
    width = max(len(t["name"]) for t in docker)
    for t in sorted(docker, key=lambda t: t["name"]):
        print("  %-*s  %s" % (width, t["name"], t.get("extra_volumes") or []))
    sys.exit(0)

changed = skipped = unchanged = failed = 0
for t in sorted(docker, key=lambda t: t["name"]):
    name = t["name"]
    if name not in WANTED:
        skipped += 1
        continue
    want = WANTED[name]
    have = t.get("extra_volumes") or []
    if have == want:
        print("  ok       %-14s already %s" % (name, have))
        unchanged += 1
        continue
    if DRY:
        print("  would    %-14s %s -> %s" % (name, have, want))
        changed += 1
        continue
    try:
        res = req("PUT", "%s/v2/templates/%s" % (base, t["template_id"]),
                  body={"extra_volumes": want})
        got = (res or {}).get("extra_volumes")
        if got != want:
            print("  FAILED   %-14s server kept %s" % (name, got))
            failed += 1
        else:
            print("  updated  %-14s %s -> %s" % (name, have, want))
            changed += 1
    except urllib.error.HTTPError as e:
        print("  FAILED   %-14s HTTP %s %s" % (name, e.code, e.read().decode()[:120]))
        failed += 1
    except urllib.error.URLError as e:
        print("  FAILED   %-14s %s" % (name, e))
        failed += 1

print("")
if DRY:
    print("Dry run: %d template(s) would change, %d already correct, %d not managed."
          % (changed, unchanged, skipped))
else:
    print("%d template(s) updated, %d already correct, %d not managed, %d failed."
          % (changed, unchanged, skipped, failed))
    if failed:
        sys.exit(1)
    if changed:
        print("")
        print("Done. Nodes you add from now on will keep their configuration when you")
        print("close and reopen a project. Nodes in projects you have already built are")
        print("not changed - rebuild those projects, or set the directories by hand on")
        print("each node under Configure > Advanced > Additional directories.")
PY
