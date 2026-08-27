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

echo "=== 1. The Tailscale server on this node ==================================="
if ! pgrep -x tailscaled >/dev/null 2>&1; then
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
if [ -z "$JSON" ]; then
    echo "  Could not read the status. The daemon may still be starting; try again in a moment."
    exit 1
fi

echo "$JSON" | python3 -c '
import json, sys

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
# AllowedIPs/AdvertisedRoutes is what this node ASKED for; the field name varies by version, and
# on some builds it is only visible through `tailscale debug prefs`, handled by the shell below.
asked = get(self_, "AdvertisedRoutes", "AllowedIPs", default=None)

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
else:
    print("  Approved:     nothing")
    print("")
    print("  If you joined with --no-advertise, that is expected.")
    print("  Otherwise your route is advertised but NOT YET APPROVED. Your VPN Router will")
    print("  answer pings; the hosts behind it will not. Two ways to fix it:")
    print("")
    print("    Once, permanently - the tailnet owner pastes the autoApprovers block from the")
    print("    Tailscale guide into Access controls in the admin console, and you re-run")
    print("    start-tailscale.sh.")
    print("")
    print("    Just this once - the owner opens Machines, finds this machine, and uses")
    print("    ... -> Edit route settings, ticks the range, and saves.")
if asked:
    print("  Asked for:    %s" % ", ".join(str(a) for a in asked))

# --- 4. peers -----------------------------------------------------------------
print("")
print("=== 4. The other sites ====================================================")
peers = get(s, "Peer", default={}) or {}
if not peers:
    print("  No peers. Nobody else has joined this tailnet yet.")
# Compare peers against what this node ASKED for as well as what was approved. Two sites using
# the same range is one of the reasons a route does not get approved, so checking only the
# approved list would stay silent in exactly the case that needs the warning.
mine = set(lab) | set(str(a) for a in (asked or []))
for _, p in sorted(peers.items(), key=lambda kv: (get(kv[1], "DNSName", "HostName", default="") or "")):
    pname = (get(p, "DNSName", "HostName", default="?") or "?").rstrip(".")
    pips = get(p, "TailscaleIPs", default=[]) or []
    pip4 = next((i for i in pips if ":" not in i), "?")
    online = "online" if get(p, "Online", default=False) else "OFFLINE"
    relay = get(p, "Relay", default="") or ""
    path = "direct" if get(p, "CurAddr", default="") else ("via relay %s" % relay if relay else "no path yet")
    proutes = [r for r in (get(p, "PrimaryRoutes", default=[]) or [])
               if not r.endswith("/32") and not r.endswith("/128")]
    print("  %-28s %-15s %-8s %s" % (pname, pip4, online, path))
    if proutes:
        print("      gives you: %s" % ", ".join(proutes))
        clash = mine.intersection(proutes)
        if clash:
            print("      WARNING: it advertises %s and so do you. Two sites cannot use the same"
                  % ", ".join(clash))
            print("               range - one of you must renumber. See Step 1 of the guide.")
    else:
        print("      gives you: nothing.")
        print("        If that is another student site, its routes are not approved yet. An")
        print("        unapproved route is never sent to peers, so this is as much as this node")
        print("        can tell you - ask them to run tailscale-status.sh at their end.")
' || echo "  (could not read the detail - the client build may differ from the one this expects)"

# What this node asked to advertise, when the JSON above did not carry it. `debug prefs` is not
# guaranteed across client versions, so a failure here is silent rather than alarming.
PREFS=$(tailscale debug prefs 2>/dev/null | tr -d ' "' | grep -i advertiseroutes)
[ -n "$PREFS" ] && echo "  Prefs:        $PREFS"

echo
echo "=== 5. Routes actually installed on this node =============================="
# What sections 3 and 4 describe is what is offered. This is what the kernel will really use.
INSTALLED=$(ip route show dev tailscale0 2>/dev/null)
if [ -n "$INSTALLED" ]; then
    echo "$INSTALLED" | sed 's/^/  /'
else
    echo "  None. Nothing from the other sites is routed through the tunnel yet."
    echo "  If a peer above does offer you a range, this node joined without --accept-routes:"
    echo "  re-run start-tailscale.sh, which always passes it."
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
