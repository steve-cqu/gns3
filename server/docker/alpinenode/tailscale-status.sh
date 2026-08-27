#!/bin/bash
# Show what this node's Tailscale connection is actually doing, and what is stopping it.
# Usage: tailscale-status.sh [--netcheck]
#
#   --netcheck   also run tailscale netcheck (which relay is nearest, and how far). Behind a flag
#                because it takes several seconds.
#
# The section that matters most is 3. A route this node advertises does nothing until the tailnet
# owner approves it, and an unapproved route fails in the worst possible way: the VPN Routers can
# ping each other, the hosts behind them cannot, and nothing anywhere reports an error. This script
# says so in one line instead.

NETCHECK=0
[ "$1" = "--netcheck" ] && NETCHECK=1
[ -n "$1" ] && [ "$1" != "--netcheck" ] && { echo "unknown option: $1"; exit 2; }

LOG=/var/log/tailscaled.log
SOCK=/var/run/tailscale/tailscaled.sock

# A backgrounded daemon whose parent has gone leaves a zombie behind: GNS3 runs each node with
# /bin/sh as PID 1, and that shell does not reap orphans. A zombie still matches `pgrep -x`, so the
# naive check reports a daemon that has actually exited as still running - and then this script
# would skip starting it and nothing would work. Measured on the appliance, 27 August 2026.
daemon_alive() {
    for p in $(pgrep -x tailscaled 2>/dev/null); do
        grep -q "^State:.*Z" "/proc/$p/status" 2>/dev/null && continue
        return 0
    done
    return 1
}

echo "=== 1. The Tailscale server on this node ==================================="
if ! daemon_alive; then
    echo "  tailscaled is NOT running, so this node is not on any mesh."
    echo
    echo "  Join with:  start-tailscale.sh --key -"
    [ -f "$LOG" ] && { echo; echo "  Last lines of $LOG:"; tail -5 "$LOG" | sed 's/^/    /'; }
    exit 0
fi
echo "  tailscaled is running (log: $LOG)"
[ -S "$SOCK" ] || echo "  WARNING: $SOCK is missing - the daemon is starting or has wedged."

# One JSON read, parsed once. The text output of `tailscale status` is friendlier but does not
# carry the route fields, and this is the only node script in the image set that parses JSON -
# everything else here stays shell.
JSON=$(tailscale status --json 2>/dev/null)
# What this node ASKED to advertise. `tailscale status --json` does not always carry it, and
# `debug prefs` is not guaranteed across client versions, so this is best-effort: an empty value
# just means section 3 reports only what was approved.
PREFS=$(tailscale debug prefs 2>/dev/null)
if [ -z "$JSON" ]; then
    echo "  Could not read the status. The daemon may still be starting; try again in a moment."
    exit 1
fi

echo "$JSON" | TS_PREFS="$PREFS" python3 -c '
import json, os, sys

try:
    s = json.load(sys.stdin)
except Exception as e:
    print("  Could not parse the status output: %s" % e)
    sys.exit(1)

def get(d, *names, default=None):
    """Field names have moved between client versions; take the first one that is present."""
    for n in names:
        if isinstance(d, dict) and d.get(n) is not None:
            return d[n]
    return default

self_ = get(s, "Self", default={}) or {}
state = get(s, "BackendState", default="unknown")
ips = get(self_, "TailscaleIPs", "TailAddrs", default=[]) or []
ip4 = next((i for i in ips if ":" not in i), "none")
name = (get(self_, "DNSName", "HostName", default="") or "").rstrip(".")

print("")
print("=== 2. This machine =======================================================")
print("  State:        %s" % state)
if state == "NeedsLogin":
    print("                It is running but not joined. Run: start-tailscale.sh --key -")
elif state == "Stopped":
    print("                Joined but switched off. Run: tailscale up   (or start-tailscale.sh)")
print("  Name:         %s" % (name or "unknown"))
print("                (this is what your tailnet owner sees in their admin console)")
print("  Address:      %s" % ip4)
url = get(s, "ControlURL", default=None) or get(s, "MagicDNSSuffix", default=None)
if url:
    print("  Tailnet:      %s" % url)

# --- 3. what this site offers -------------------------------------------------
# PrimaryRoutes is what the coordination server has APPROVED and is handing to peers.
approved = get(self_, "PrimaryRoutes", default=[]) or []
# What this node ASKED to advertise. Take it from the daemon preferences first: that is literally
# the question being asked, and it is right whether or not the route was ever approved.
#
# Do NOT read Self.AllowedIPs for this. It looks like the same thing and is not: when a route IS
# approved it contains it, but when the route is NOT approved it holds only this node own /32
# addresses. Reading it first therefore blocked the fallback below, filtered down to nothing, and
# dropped the "Asked for" line in exactly the case it is needed - an unapproved route - which also
# silently disabled the collision check in section 4. Measured on two live appliances, 27 Aug 2026.
asked = None
try:
    prefs = json.loads(os.environ.get("TS_PREFS") or "{}")
    asked = prefs.get("AdvertiseRoutes") or None
except Exception:
    asked = None
if not asked:
    asked = get(self_, "AdvertisedRoutes", default=None)
if asked:
    asked = [a for a in asked if not str(a).endswith("/32") and not str(a).endswith("/128")] or None

# Peers are examined before section 3 is printed, because section 3 cannot explain itself without
# them. Tailscale hands a subnet to exactly ONE machine - two machines advertising the same range
# are treated as HA failover - and the loser is given nothing at all: no PrimaryRoutes, and the
# range absent even from its AllowedIPs. On the machine that lost, that is byte-for-byte
# indistinguishable from "nobody approved my route", which is what this script used to say. It sent
# the student to ask the owner to approve a route that was already approved, while the real fix was
# to renumber. Measured on two live appliances, 27 August 2026.
peers = get(s, "Peer", default={}) or {}
held_by = {}
for _, _p in peers.items():
    if not get(_p, "Online", default=False):
        continue
    for r in (get(_p, "PrimaryRoutes", default=[]) or []):
        if asked and r in asked:
            held_by[r] = (get(_p, "DNSName", "HostName", default="?") or "?").split(".")[0]

print("")
print("=== 3. What this site offers the group ====================================")
lab = [r for r in approved if not r.endswith("/32") and not r.endswith("/128")]
if lab:
    print("  Approved:     %s" % ", ".join(lab))
    print("                Hosts behind this router can be reached from the other sites.")
elif state != "Running":
    # Not joined, so there is nothing to approve yet. Saying otherwise sends a student to the
    # admin console to fix a problem they do not have.
    print("  Approved:     nothing yet - this node has not joined a tailnet.")
elif held_by:
    print("  Approved:     nothing - and this is NOT an approval problem.")
    print("")
    for r in sorted(held_by):
        print("  %s is already being advertised by %s, which is online." % (r, held_by[r]))
    print("")
    print("  A range can only be served by one machine, so yours is being ignored. Asking the")
    print("  tailnet owner to approve it will not help - it may well be approved already. Renumber")
    print("  your site to a range nobody else is using (Step 1 of the guide), then run")
    print("  start-tailscale.sh again.")
else:
    print("  Approved:     nothing")
    print("")
    print("  If you joined with --no-advertise, that is expected.")
    print("  Otherwise your route is advertised but NOT YET APPROVED. Your VPN Router will")
    print("  answer pings; the hosts behind it will not. Two ways to fix it:")
    print("")
    print("    Once, permanently - the tailnet owner opens Access controls, Policies, the")
    print("    Auto approvers tab, and adds this range with Add route. Then re-run")
    print("    start-tailscale.sh.")
    print("")
    print("    Just this once - the owner opens Machines, finds this machine, and uses")
    print("    ... -> Edit route settings, ticks the range, and saves.")
if asked:
    print("  Asked for:    %s" % ", ".join(str(a) for a in asked))

# --- 4. peers -----------------------------------------------------------------
print("")
print("=== 4. The other sites ====================================================")
if not peers:
    print("  No peers. Nobody else has joined this tailnet yet.")
# Offline peers get one summary line at the end, not a paragraph each. Nothing about a join is kept,
# so every session any member runs leaves a dead machine behind; after a fortnight the list is mostly
# history, and giving each old machine three lines about unapproved routes buries the one site that
# is actually online. Seen on a real tailnet that collected five machines in an afternoon,
# 27 August 2026.
offline_names = []
# Compare peers against what this node ASKED for as well as what was approved. Two sites using
# the same range is one of the reasons a route does not get approved, so checking only the
# approved list would stay silent in exactly the case that needs the warning.
mine = set(lab) | set(str(a) for a in (asked or []))
for _, p in sorted(peers.items(), key=lambda kv: (get(kv[1], "DNSName", "HostName", default="") or "")):
    pname = (get(p, "DNSName", "HostName", default="?") or "?").rstrip(".")
    pips = get(p, "TailscaleIPs", default=[]) or []
    pip4 = next((i for i in pips if ":" not in i), "?")
    if not get(p, "Online", default=False):
        offline_names.append(pname.split(".")[0])
        continue
    relay = get(p, "Relay", default="") or ""
    path = "direct" if get(p, "CurAddr", default="") else ("via relay %s" % relay if relay else "no path yet")
    proutes = [r for r in (get(p, "PrimaryRoutes", default=[]) or [])
               if not r.endswith("/32") and not r.endswith("/128")]
    print("  %-28s %-15s %-8s %s" % (pname, pip4, "online", path))
    if proutes:
        print("      gives you: %s" % ", ".join(proutes))
        clash = mine.intersection(proutes)
        # Online means a real second site claiming your range. Offline almost always means one of
        # your own earlier machines: nothing about a join is kept, so every session leaves one
        # behind holding the range it was approved for, and calling that a collision would send a
        # student off to renumber a network that is fine.
        # Only online peers reach this point, so a shared range is a genuine second site.
        if clash:
            print("      WARNING: it advertises %s and so do you. Two sites cannot use the same"
                  % ", ".join(clash))
            print("               range - one of you must renumber. See Step 1 of the guide.")
    else:
        print("      gives you: nothing.")
        print("        If that is another student site, its routes are not approved yet. An")
        print("        unapproved route is never sent to peers, so this is as much as this node")
        print("        can tell you - ask them to run tailscale-status.sh at their end.")

if offline_names:
    print("")
    print("  Also in this tailnet but offline: %s" % ", ".join(offline_names))
    print("  Being joined never survives closing a project, so every session leaves a machine")
    print("  behind. These are almost certainly old ones - ask the tailnet owner to delete them.")
' || echo "  (could not read the detail - the client build may differ from the one this expects)"

echo
echo "=== 5. Routes actually installed on this node =============================="
# What sections 3 and 4 describe is what is offered. This is what the kernel will really use.
#
# `table all`, not the main table. Tailscale does not put these routes in the main table: on Linux
# it uses policy routing, putting them in table 52 with an `ip rule` (5270) that sends traffic
# there. Plain `ip route show dev tailscale0` therefore finds nothing on a node that is working
# perfectly - which is exactly what the first version of this script did, on two live appliances on
# 27 August 2026: it printed "None" and told a correctly-joined node to re-run itself.
# `table local` holds this node's own address, which is not a route to anywhere and only adds noise.
INSTALLED=$(ip -4 route show table all dev tailscale0 2>/dev/null | grep -v "table local")
if [ -n "$INSTALLED" ]; then
    # Split them. A route to another site's network is the answer to "can I reach their hosts";
    # the rest are per-machine routes inside Tailscale's own 100.64.0.0/10 range - one for every
    # machine in the tailnet, plus MagicDNS. On a tailnet that has collected old machines those
    # outnumber the useful line several to one, which is how a working node came to look cluttered
    # enough to doubt. Measured 27 August 2026.
    CGNAT='^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.'
    SUBNETS=$(echo "$INSTALLED" | grep -Ev "$CGNAT")
    MACHINES=$(echo "$INSTALLED" | grep -Ec "$CGNAT")
    if [ -n "$SUBNETS" ]; then
        echo "$SUBNETS" | sed 's/^/  /'
    else
        echo "  No route to another site's network yet."
    fi
    [ "$MACHINES" -gt 0 ] && echo "  ...plus $MACHINES route(s) to machines in the tailnet itself, which is normal."
    echo
    echo "  Table 52 is Tailscale's own routing table, which is why plain 'ip route' does not"
    echo "  show these. A range from another site appearing here is what makes its hosts reachable."
else
    echo "  None. Nothing from the other sites is routed through the tunnel yet."
    echo "  If a peer above offers you a range and nothing appears here, re-run start-tailscale.sh,"
    echo "  which always passes --accept-routes."
fi

MTU=$(cat /sys/class/net/tailscale0/mtu 2>/dev/null)
if [ -n "$MTU" ]; then
    echo
    echo "  tailscale0 MTU is $MTU. If you build your own VPN on top of this one, set that inner"
    echo "  tunnel's MTU to about 1200, or large transfers will hang while ping still works."
fi

if [ "$NETCHECK" = 1 ]; then
    echo
    echo "=== 6. Relay check ========================================================"
    tailscale netcheck 2>&1 | sed 's/^/  /'
fi

echo
echo "Start or rejoin:  start-tailscale.sh --key -"
echo "Leave the mesh:   stop-tailscale.sh"
