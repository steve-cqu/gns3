#!/bin/bash
# Join this node to a Tailscale mesh, so your lab can reach another student's lab over the Internet.
# Usage: start-tailscale.sh [--key -|<tskey-...>] [--route <cidr>] [--no-advertise]
#                          [--login-server <url>] [--check] [--explain]
#
#   --key -             prompt for the tailnet owner's auth key; nothing is echoed. This is the
#                       normal way in - the node joins with no browser, no login URL to read off
#                       this console, and nobody else has to be online.
#   --key <tskey-...>   the same, with the key on the command line. It prints a warning: the
#                       command line is saved in /root/.ash_history, which this node keeps.
#   (no --key)          print a login URL for the tailnet owner to approve in a browser. Slower,
#                       and both of you have to be online at once.
#   --route <cidr>      advertise this range instead of the one worked out from eth0.
#   --no-advertise      join as a plain client and offer no route at all.
#   --login-server URL  use a coordination server other than Tailscale's (e.g. a Headscale).
#   --check             run the checks and stop. Nothing is started and no account is needed.
#   --explain           print the exact tailscale commands this would run, and stop.
#
# The checks come first on purpose. Almost every "Tailscale is broken" report is really a missing
# NAT node, a missing DHCP lease on eth1 or a nameserver that never arrived, and each of those has
# a different fix - so they are reported by name here rather than as a login that hangs.
#
# This node never joins by itself, and nothing about the join survives a project being closed:
# tailscaled keeps its state in /var/lib/tailscale, which is deliberately NOT one of the
# directories GNS3 keeps for this template. Joining is something you do on purpose at the start of
# a session, and stop-tailscale.sh ends it. Full reasoning in
# gns3-dev/notes/tailscale-easy-join.md.

KEY=""
KEY_ON_ARGV=0
KEY_FROM_ENV=0
ROUTE=""
ADVERTISE=1
CHECK_ONLY=0
EXPLAIN_ONLY=0
LOG=/var/log/tailscaled.log
SOCK=/var/run/tailscale/tailscaled.sock

# Every vendor-specific string is a variable with a default, never a literal in the checks below.
# That is what makes moving to a self-hosted coordination server (Headscale) one flag rather than a
# rewrite: the DNS and reachability checks derive their host from whatever this is set to.
LOGIN_SERVER="${TS_LOGIN_SERVER:-}"
CGNAT_FIRST=100          # 100.64.0.0/10, the range a coordination server hands to machines
CGNAT_LO=64
CGNAT_HI=127

while [ $# -gt 0 ]; do
    case "$1" in
        --key)
            [ $# -ge 2 ] || { echo "FAILED: --key needs a value (use '-' to be prompted)"; exit 2; }
            if [ "$2" = "-" ]; then KEY="prompt"; else KEY="$2"; KEY_ON_ARGV=1; fi
            shift 2 ;;
        --route)
            [ $# -ge 2 ] || { echo "FAILED: --route needs a CIDR, e.g. --route 10.11.0.0/16"; exit 2; }
            ROUTE="$2"; shift 2 ;;
        --no-advertise) ADVERTISE=0; shift ;;
        --login-server)
            [ $# -ge 2 ] || { echo "FAILED: --login-server needs a URL"; exit 2; }
            LOGIN_SERVER="$2"; shift 2 ;;
        --check) CHECK_ONLY=1; shift ;;
        --explain) EXPLAIN_ONLY=1; shift ;;
        -h|--help)
            # Every comment line after the shebang, up to the first line of code - so editing the
            # header above cannot silently truncate the help text, which a fixed line range did.
            awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
            exit 0 ;;
        *)
            echo "unknown option: $1 (try --help)"; exit 2 ;;
    esac
done

# TS_AUTHKEY in the environment is the third way in, and it exists for the test harness. Students
# should not use it: a GNS3 node's environment is stored in project.gns3, which IS inside an
# exported project, so a key put there is a reusable credential inside a submission.
if [ -z "$KEY" ] && [ -n "$TS_AUTHKEY" ]; then
    KEY="$TS_AUTHKEY"; KEY_FROM_ENV=1
fi

fail() {
    echo "FAILED: $1"
    [ -n "$2" ] && { echo; echo "$2"; }
    exit 1
}

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


CONTROL_URL="${LOGIN_SERVER:-https://controlplane.tailscale.com/}"
CONTROL_HOST=$(printf '%s' "$CONTROL_URL" | sed -e 's#^[a-z]*://##' -e 's#[:/].*$##')

# ------------------------------------------------------- what to advertise ----
# Worked out before the network checks so that --explain needs no Internet at all.

derive_route() {
    [ "$ADVERTISE" = 0 ] && { ROUTE=""; return; }
    [ -n "$ROUTE" ] && { ROUTE_WHY="given with --route"; return; }

    INSIDE_IP=$(ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4; exit}')
    [ -n "$INSIDE_IP" ] || fail \
        "eth0 has no IPv4 address, so there is no inside network to advertise." \
"eth0 is the inside leg - the one facing your own hosts. Give it the .1 address of your
agreed range in /etc/network/interfaces:
         auto eth0
         iface eth0 inet static
             address 10.11.1.1
             netmask 255.255.255.0
             up sysctl net.ipv4.ip_forward=1
then:  ifup eth0
Or say what to advertise directly:  start-tailscale.sh --route 10.11.0.0/16
Or join without offering a route at all:  start-tailscale.sh --no-advertise"

    O1=$(echo "$INSIDE_IP" | cut -d. -f1)
    O2=$(echo "$INSIDE_IP" | cut -d. -f2)
    O3=$(echo "$INSIDE_IP" | cut -d. -f3)
    PFX=$(echo "$INSIDE_IP" | cut -d/ -f2)

    if [ "$O1" = "$CGNAT_FIRST" ] && [ "$O2" -ge "$CGNAT_LO" ] && [ "$O2" -le "$CGNAT_HI" ]; then
        fail "eth0 is $INSIDE_IP, inside $CGNAT_FIRST.$CGNAT_LO.0.0/10." \
"That range is what the coordination server hands out to the machines themselves, so a site
numbered in it collides with every peer's own address. Renumber your inside network - the
lab ranges are 10.11.x, 10.12.x and 10.13.x, one per group member."
    fi

    if [ "$O1" = "10" ]; then
        # A /16 leaves room for more subnets behind this router later (10.11.2.0/24 and so on)
        # without touching the tailnet again, which is the reason the activity uses one.
        ROUTE="$O1.$O2.0.0/16"
        ROUTE_WHY="worked out from eth0's $INSIDE_IP - a /16, so you can add 10.$O2.2.0/24 behind this router later without changing anything here"
    else
        # Deliberately NOT widened. Only 10.x sites get a /16: 192.168.0.0/16 would swallow
        # whichever 192.168.x.0/24 the GNS3 NAT node uses (192.168.122.0/24 on release v041,
        # 192.168.42.0/24 on some earlier builds -- do not hard-code it), so this router would
        # advertise a route to its own way out and lose the Internet. Widening anything outside the lab's own
        # 10.x ranges risks the same thing, so the interface's own prefix is offered instead.
        ROUTE="$O1.$O2.$O3.0/$PFX"
        if [ "$O1.$O2" = "192.168" ]; then
            ROUTE_WHY="worked out from eth0's $INSIDE_IP, and NOT widened to a /16 on purpose: 192.168.0.0/16 would cover the network the GNS3 NAT node uses, and this router would stop reaching the Internet"
        else
            ROUTE_WHY="worked out from eth0's $INSIDE_IP, and NOT widened to a /16 on purpose - only the lab's 10.x ranges are widened, because a wider range here could cover a network this router itself needs"
        fi
        ROUTE_WHY="$ROUTE_WHY. Renumber into 10.11.x, 10.12.x or 10.13.x if you want room to grow"
    fi
}

# Build the tailscale command in one place, as an array, so --explain and the real run can never
# differ and no argument is re-split on whitespace on its way to being run.
build_up_cmd() {
    UP_ARGS=(tailscale up)
    [ -n "$LOGIN_SERVER" ] && UP_ARGS+=(--login-server="$LOGIN_SERVER")
    UP_ARGS+=(--hostname="$(hostname)")
    [ -n "$ROUTE" ] && UP_ARGS+=(--advertise-routes="$ROUTE")
    UP_ARGS+=(--snat-subnet-routes=false --accept-routes)
    # Without this the daemon rewrites /etc/resolv.conf, and "my DNS stopped working after I
    # joined" is a symptom no student connects back to Tailscale.
    UP_ARGS+=(--accept-dns=false)
    # --reset clears any leftover setting that would otherwise make tailscale refuse with
    # "changing settings via 'tailscale up' requires mentioning all non-default flags". This
    # script is the authority on what this node advertises.
    UP_ARGS+=(--reset)
    UP_CMD="${UP_ARGS[*]}"
}

derive_route
build_up_cmd

if [ "$EXPLAIN_ONLY" = 1 ]; then
    echo "start-tailscale.sh would run these two commands, and nothing else:"
    echo
    echo "    tailscaled >$LOG 2>&1 &"
    echo "    $UP_CMD${KEY:+ --auth-key=tskey-***}"
    echo
    [ -n "$ROUTE" ] && { echo "The route it would advertise is $ROUTE,"; echo "  $ROUTE_WHY."; echo; }
    # Only the options this run would actually use are explained. Describing --advertise-routes
    # after --no-advertise removed it reads as though it were still in play.
    echo "What each option does:"
    if [ -n "$ROUTE" ]; then
        echo "  --advertise-routes  offers your inside range to the rest of the group, so their"
        echo "                      traffic for your site is sent to this router."
    fi
    echo "  --accept-routes     accepts the ranges the others advertise. Without it this node"
    echo "                      ignores them and cannot reach their sites."
    echo "  --snat-subnet-routes=false"
    echo "                      keeps the original source address on traffic arriving from the"
    echo "                      other sites, so captures and firewall rules show who really sent"
    echo "                      it. Your hosts need a route back, which they have when this"
    echo "                      router is their default gateway."
    echo "  --accept-dns=false  leaves /etc/resolv.conf alone."
    echo "  --hostname          names this machine in the owner's admin console."
    echo
    echo "Nothing was started (--explain)."
    exit 0
fi

# ---------------------------------------------------------------- checks ----

echo "Checking this node can reach a coordination server..."

# 1. The TUN device. tailscaled builds its own network interface through it; without it the
#    daemon falls back to userspace networking, which cannot do subnet routing - so the routers
#    would reach each other and the hosts behind them never would, with nothing naming the cause.
#    A container cannot load the module itself: this is a fault on the GNS3 VM.
[ -c /dev/net/tun ] || fail \
    "this node has no /dev/net/tun, so tailscaled cannot create its interface." \
"That is a setting on the GNS3 VM, not something you can fix from here. The tun module must
be loaded on the VM (kernel_modules in the appliance manifest). Tell your lecturer."
echo "  ok       /dev/net/tun is present"

# 2. A default route. Which interface it points at is also which leg faces the Internet, so it is
#    worth reading out rather than assuming eth1.
OUTSIDE=$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')
[ -n "$OUTSIDE" ] || fail \
    "this node has no default route, so it cannot reach anything outside your lab." \
"Your VPN Router needs a second leg to the Internet:
  1. Add a NAT node to the project and connect it to eth1.
  2. Put this in /etc/network/interfaces:
         auto eth1
         iface eth1 inet dhcp
  3. Apply it with:  ifup eth1
The NAT node hands out an address, a default route and a nameserver together."

OUTSIDE_IP=$(ip -4 -o addr show dev "$OUTSIDE" 2>/dev/null | awk '{print $4; exit}')
[ -n "$OUTSIDE_IP" ] || fail \
    "$OUTSIDE is the way out but has no IPv4 address." \
"Its DHCP lease never arrived. Check the NAT node is connected to $OUTSIDE and started,
then run:  ifup $OUTSIDE"
echo "  ok       Internet leg is $OUTSIDE ($OUTSIDE_IP), default via $(ip route show default | awk '{print $3; exit}')"

# 3. Name resolution, checked against the host we actually need. A node with an address but no
#    nameserver looks fine to `ip addr` and fails at the login step with an opaque error.
nslookup "$CONTROL_HOST" >/dev/null 2>&1 || fail \
    "cannot resolve $CONTROL_HOST - this node has no working nameserver." \
"Check /etc/resolv.conf. A NAT node supplies one over DHCP - the gateway of whatever
subnet it hands out - so the usual fix is:  ifup $OUTSIDE"
echo "  ok       $CONTROL_HOST resolves"

# 4. Reachability. curl exits 0 on any HTTP response, including a 404, which is all that is needed
#    here: it proves the TCP connection and the TLS handshake, which is what a filtered network
#    breaks. Separate from the DNS check so the two failures are not reported as one.
curl -sS -m 8 -o /dev/null "$CONTROL_URL" 2>/dev/null || fail \
    "cannot reach $CONTROL_URL." \
"The GNS3 VM itself may have no Internet, or the network you are on blocks it. Test the VM,
not just this node. From here:   curl -v $CONTROL_URL
A campus or hotel network that blocks UDP still works - Tailscale falls back to a relay -
but nothing works if this address is unreachable."
echo "  ok       $CONTROL_HOST is reachable"

if [ -n "$ROUTE" ]; then
    echo "  ok       advertising $ROUTE"
    echo "           ($ROUTE_WHY)"
    # Advertising a range that swallows your own way out is a slow, confusing failure: the node
    # announces a route to the network its own upstream lives on.
    if [ "$(echo "$ROUTE" | cut -d. -f1-2)" = "$(echo "$OUTSIDE_IP" | cut -d. -f1-2)" ]; then
        echo "  WARNING  $ROUTE also covers $OUTSIDE ($OUTSIDE_IP), your way to the Internet."
        echo "           Renumber the inside network, or use --route to advertise less."
    fi
else
    echo "  ok       joining as a plain client, advertising nothing (--no-advertise)"
fi

if [ "$CHECK_ONLY" = 1 ]; then
    echo
    echo "Checks passed. Nothing was started (--check)."
    echo "Run it without --check to join the mesh, or with --explain to see the commands."
    exit 0
fi

# ------------------------------------------------------------ the daemon ----

# Forwarding, or this router routes nothing between the tunnel and eth0. Set here so the script
# works on a node built by hand, but the durable place is the interfaces file - /etc/network
# survives a project being closed and its `up` lines run at boot.
if [ -n "$ROUTE" ] && [ "$(cat /proc/sys/net/ipv4/ip_forward)" != "1" ]; then
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    echo "  set      net.ipv4.ip_forward=1 - it was 0, and a router that does not forward"
    echo "           carries nothing. Make it stick with an 'up sysctl net.ipv4.ip_forward=1'"
    echo "           line under eth0 in /etc/network/interfaces."
fi

# IPv6 forwarding as well, even though the lab is IPv4. tailscale up checks it and prints
#   "Warning: IPv6 forwarding is disabled. Subnet routes and exit nodes may not work correctly."
# which is harmless here and reads like a fault - and a warning a student cannot act on is worse
# than no warning, because it makes the ones that matter easier to ignore. Measured 27 Aug 2026.
if [ -n "$ROUTE" ] && [ -w /proc/sys/net/ipv6/conf/all/forwarding ] &&
   [ "$(cat /proc/sys/net/ipv6/conf/all/forwarding)" != "1" ]; then
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1
fi

if daemon_alive && [ -S "$SOCK" ]; then
    echo "tailscaled is already running."
else
    echo "Starting tailscaled (log: $LOG) ..."
    tailscaled >"$LOG" 2>&1 &
    # Poll for the socket the CLI talks to rather than sleeping a flat 2s: a fixed wait is a race
    # with the slowest machine that will ever run this, and "failed to connect to local tailscaled"
    # is the error you get for being half a second early.
    i=0
    while [ ! -S "$SOCK" ] && [ "$i" -lt 20 ]; do sleep 1; i=$((i + 1)); done
    if [ ! -S "$SOCK" ]; then
        echo "FAILED: tailscaled did not create $SOCK after 20s. Last lines of $LOG:"
        tail -20 "$LOG" 2>/dev/null
        exit 1
    fi
    echo "  ok       tailscaled is up"
fi

# --------------------------------------------------------------- joining ----

if [ "$KEY" = "prompt" ]; then
    echo
    echo "Paste the auth key from your tailnet owner (it starts tskey- and will not be shown):"
    printf "  key: "
    stty -echo 2>/dev/null
    read -r KEY
    stty echo 2>/dev/null
    echo
    [ -n "$KEY" ] || fail "no key entered." \
        "Run it again, or leave --key off to use a login URL instead."
elif [ "$KEY_ON_ARGV" = 1 ]; then
    echo
    echo "  WARNING  an auth key on the command line is saved in /root/.ash_history, and this node"
    echo "           keeps /root. Next time use:  start-tailscale.sh --key -"
elif [ "$KEY_FROM_ENV" = 1 ]; then
    echo
    echo "  WARNING  using the auth key in \$TS_AUTHKEY. That variable is meant for the test"
    echo "           harness: a node's environment is saved inside an exported project, so a key"
    echo "           set there travels with anything you submit. Students should use --key -"
fi

echo
if [ -n "$KEY" ]; then
    echo "Running: $UP_CMD --auth-key=tskey-***"
    echo
    UP_ARGS+=(--auth-key="$KEY")
else
    echo "Running: $UP_CMD"
    echo
    echo "No key given, so this prints a login URL and then waits. Send the whole URL to your"
    echo "tailnet owner - they open it in a browser to approve this machine. Ask them for an"
    echo "auth key instead and neither of you has to do this again."
    echo
fi

if ! "${UP_ARGS[@]}"; then
    echo
    echo "FAILED: tailscale up did not complete. Last lines of $LOG:"
    tail -20 "$LOG" 2>/dev/null
    echo
    echo "Common causes: the key has expired or has already been used by as many machines as it"
    echo "allows (ask the owner for a fresh one), or the owner's tailnet requires each new machine"
    echo "to be approved by hand."
    exit 1
fi

MYIP=$(tailscale ip -4 2>/dev/null | head -1)
echo
echo "Joined. This node is $MYIP on the mesh${ROUTE:+, advertising $ROUTE}."
echo
echo "Check it - including whether the owner has approved your route, which is the step groups"
echo "most often miss:"
echo "    tailscale-status.sh"
echo "Leave the mesh when you have finished for the day:"
echo "    stop-tailscale.sh"
