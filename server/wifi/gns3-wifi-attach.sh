#!/bin/bash
# gns3-wifi-attach — give each running wireless node a simulated radio.
#
# Runs ON THE GNS3 VM HOST (not inside a node). A GNS3 wireless node (cqugns3/wifinode) is a
# container in its own network namespace and cannot see the host's mac80211_hwsim radios, so after
# you Start a wireless project this helper moves one radio (a "phy") into each wireless node. Inside
# the node the radio then appears as wlan0 and start-ap.sh / start-sta.sh can use it.
#
# Usage:
#   gns3-wifi-attach                 attach a radio to every running wireless node that lacks one
#   gns3-wifi-attach <project-name>  only nodes in that project (matched via the GNS3 API)
#   gns3-wifi-attach --status        show which node holds which radio, and free radios
#
# It is idempotent: a node that already has wlan0 is skipped, so it is safe to run again (e.g. after
# starting more nodes). When a project is closed its containers are destroyed and their radios
# return to the host pool automatically — nothing to clean up.
#
# EXIT STATUS — this matters more than it looks. The autotest harness runs this as a `host_setup:`
# step and only reports a diagnostic when it fails, so a 0 returned by a run that attached NOTHING
# is indistinguishable from a run that attached everything. That is exactly what happened in the
# arm64 pass of 18 August 2026: wireless-basics failed on both nodes, the transcript showed this
# helper invoked with no error, and the actual failure (no radio ever arrived) was invisible. See
# gns3-dev/notes/tier5-and-spike-designs.md.
#
#   0  every node that needed a radio has one — including "they all already had one", and
#      including "nothing is running" when no project was named
#   1  asked to do something and did not do it: a named project matched no wireless nodes, a
#      radio could not be moved, or nodes needed radios and none was attached
#
# "Nothing to do" is only success when nobody asked for anything specific. Being told to attach
# radios in a named project and finding no nodes there is a failure, not a no-op.

IMAGE=cqugns3/wifinode:latest
RADIOS=${GNS3_WIFI_RADIOS:-4}          # how many radios to create if the module is not loaded yet
API=${GNS3_SERVER:-http://localhost}   # only needed to resolve a project NAME to its id

# Progress/diagnostics go to STDERR, so they never pollute a function's stdout when it is captured
# in a command substitution (wifi_containers below is read that way).
log(){ echo "gns3-wifi-attach: $*" >&2; }

# --- run iw in the HOST net+pid namespace, using the wifinode image's iw binary ---
hostiw(){ docker run --rm --net=host --pid=host --privileged "$IMAGE" iw "$@"; }

free_phys(){ ls /sys/class/ieee80211/ 2>/dev/null; }   # phys in the host netns = not yet attached
free_count(){ free_phys | grep -c . ; }

# Is any wireless node already holding a radio? If so a reload would be unsafe (it would destroy
# radios in use), so we never reload in that case.
any_attached(){
    docker ps --filter "ancestor=$IMAGE" -q | while read -r id; do
        docker exec "$id" ip link show wlan0 >/dev/null 2>&1 && { echo yes; break; }
    done | grep -q yes
}

# Make sure at least $1 radios are free in the host pool. Loads the module if absent; reloads it to
# a bigger radio count only when nothing is attached yet (safe). Falls back to whatever is free.
ensure_radios(){
    local need="$1" want
    want=$(( need > RADIOS ? need : RADIOS ))
    if ! [ -d /sys/class/ieee80211/phy0 ] && [ "$(free_count)" -eq 0 ]; then
        log "no radios present — loading mac80211_hwsim with radios=$want"
        sudo modprobe mac80211_hwsim radios="$want" 2>/dev/null \
            || { log "ERROR: could not load mac80211_hwsim (is the module available?)"; exit 1; }
        sleep 1
    elif [ "$(free_count)" -lt "$need" ] && ! any_attached; then
        log "only $(free_count) free radios for $need node(s), and none attached — reloading with radios=$want"
        sudo modprobe -r mac80211_hwsim 2>/dev/null
        sudo modprobe mac80211_hwsim radios="$want" 2>/dev/null \
            || { log "ERROR: could not reload mac80211_hwsim"; exit 1; }
        sleep 1
    fi
}

# containers of wireless nodes, optionally scoped to a project name
wifi_containers(){
    local ids
    ids=$(docker ps --filter "ancestor=$IMAGE" --format '{{.ID}} {{.Names}}')
    if [ -n "$1" ]; then
        # Resolve project NAME (or id) -> project id via the API, then keep only that project's
        # containers (their GNS3 name embeds the id: GNS3.<node>.<project_id>). python3 is on the
        # GNS3 VM; parsing the JSON with it is robust where a grep/tr pipeline is not.
        local pid
        pid=$(curl -s "$API/v2/projects" 2>/dev/null | python3 -c \
              "import json,sys
a='$1'
try: ps=json.load(sys.stdin)
except Exception: ps=[]
print(next((p['project_id'] for p in ps if a in (p.get('name'),p.get('project_id'))), ''))" 2>/dev/null)
        if [ -z "$pid" ]; then
            log "WARNING: project '$1' not found via $API — attaching to all wifi nodes"
            echo "$ids"; return
        fi
        echo "$ids" | grep "$pid"
    else
        echo "$ids"
    fi
}

if [ "$1" = "--status" ]; then
    echo "Free radios (in host pool): $(free_phys | tr '\n' ' ')"
    echo "Wireless nodes:"
    docker ps --filter "ancestor=$IMAGE" --format '{{.ID}} {{.Names}}' | while read -r id name _; do
        [ -z "$id" ] && continue
        w=$(docker exec "$id" ip -o link show wlan0 2>/dev/null | awk '{print "wlan0"}')
        echo "   ${name:-$id}: ${w:-no radio}"
    done
    exit 0
fi

mapfile -t CONTAINERS < <(wifi_containers "$1" | awk 'NF{print $1}')
if [ "${#CONTAINERS[@]}" -eq 0 ]; then
    log "no running wireless nodes found (image $IMAGE). Start the wireless project first."
    # With a project named, this is a failure: the caller told us what to work on and it is not
    # there. With no argument it is a legitimate nothing-to-do.
    [ -n "$1" ] && { log "ERROR: asked for project '$1' and found no wireless nodes in it."; exit 1; }
    exit 0
fi

# Size the radio pool to the number of nodes that still need one.
need=0
for id in "${CONTAINERS[@]}"; do
    docker exec "$id" ip link show wlan0 >/dev/null 2>&1 || need=$((need+1))
done
[ "$need" -gt 0 ] && ensure_radios "$need"

attached=0; skipped=0; failed=0
for id in "${CONTAINERS[@]}"; do
    name=$(docker inspect -f '{{.Name}}' "$id" 2>/dev/null | sed 's#^/##')
    # already has a radio? skip (idempotent)
    if docker exec "$id" ip link show wlan0 >/dev/null 2>&1; then
        log "$name already has wlan0 — skipping"; skipped=$((skipped+1)); continue
    fi
    phy=$(free_phys | head -1)
    if [ -z "$phy" ]; then
        log "ERROR: out of free radios. Load more with: sudo modprobe -r mac80211_hwsim; sudo modprobe mac80211_hwsim radios=<N>"
        exit 1
    fi
    pid=$(docker inspect -f '{{.State.Pid}}' "$id")
    if hostiw phy "$phy" set netns "$pid" 2>/tmp/.wifiattach; then
        # mac80211_hwsim names interfaces globally (wlan0, wlan1, ...) and the name travels with
        # the radio into the node's namespace — so the second node would get wlan1, not wlan0.
        # Rename whatever wlan* landed to wlan0 so every node's configs and scripts can assume it.
        docker exec "$id" sh -c '
            w=$(ls /sys/class/net 2>/dev/null | grep "^wlan" | head -1)
            if [ -n "$w" ] && [ "$w" != wlan0 ]; then
                ip link set "$w" down 2>/dev/null
                ip link set "$w" name wlan0 2>/dev/null
            fi' 2>/dev/null
        log "$name  <-  $phy  (pid $pid) -> wlan0"
        attached=$((attached+1))
    else
        log "ERROR moving $phy into $name:"; sed 's/^/   /' /tmp/.wifiattach
        failed=$((failed+1))
    fi
done

log "done: $attached attached, $skipped already had a radio, $failed failed."
[ "$attached" -gt 0 ] && log "Now, on each wireless node: start-ap.sh (access point) or start-sta.sh (station)."

if [ "$failed" -gt 0 ]; then
    log "ERROR: $failed node(s) could not be given a radio."
    exit 1
fi
# The case that hid the arm64 failure: nodes needed radios, the run reported no error, and not one
# radio was actually moved. `modprobe` succeeding does not prove the radios appeared — check with
# `ls /sys/class/ieee80211/` on the host.
if [ "$need" -gt 0 ] && [ "$attached" -eq 0 ]; then
    log "ERROR: $need node(s) needed a radio and none was attached — no free phys in the host pool?"
    log "       check: ls /sys/class/ieee80211/   and   lsmod | grep mac80211_hwsim"
    exit 1
fi
exit 0
