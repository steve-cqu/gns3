#!/bin/bash
# Console menu for the NETem docker node.
# The node transparently bridges eth0 <-> eth1 (see start-netem.sh).
# Emulation is applied with tc/netem on the egress of each interface:
#   - the qdisc on eth1 shapes traffic in direction eth0 -> eth1
#   - the qdisc on eth0 shapes traffic in direction eth1 -> eth0

# Don't let Ctrl-C kill the menu (would stop the node)
trap '' INT

MODE="symmetric"

# Per-direction settings: index 0 = eth0->eth1, index 1 = eth1->eth0
DELAY=(0 0)   # ms
JITTER=(0 0)  # ms
LOSS=(0 0)    # percent (may be decimal)
RATE=(0 0)    # kbit/s, 0 = unlimited

EGRESS=(eth1 eth0)
DIRLABEL=("eth0 -> eth1" "eth1 -> eth0")

apply() {
    local i args
    for i in 0 1; do
        args=""
        # netem syntax: jitter must follow a delay value
        if [ "${DELAY[$i]}" != "0" ] || [ "${JITTER[$i]}" != "0" ]; then
            args="$args delay ${DELAY[$i]}ms"
            if [ "${JITTER[$i]}" != "0" ]; then
                args="$args ${JITTER[$i]}ms"
            fi
        fi
        if [ "${LOSS[$i]}" != "0" ]; then
            args="$args loss ${LOSS[$i]}%"
        fi
        if [ "${RATE[$i]}" != "0" ]; then
            args="$args rate ${RATE[$i]}kbit"
        fi
        if [ -n "$args" ]; then
            tc qdisc replace dev "${EGRESS[$i]}" root netem $args
        else
            tc qdisc del dev "${EGRESS[$i]}" root 2>/dev/null
        fi
    done
}

# Prompt for a numeric value; empty input keeps the current value
ask() {
    local prompt="$1" current="$2" input
    read -rp "$prompt [$current]: " input
    if [[ "$input" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        echo "$input"
    else
        echo "$current"
    fi
}

# Set one parameter (named array) for both directions or per direction
set_param() {
    local -n arr="$1"
    local label="$2"
    if [ "$MODE" == "symmetric" ]; then
        arr[0]=$(ask "$label (both directions)" "${arr[0]}")
        arr[1]="${arr[0]}"
    else
        arr[0]=$(ask "$label (${DIRLABEL[0]})" "${arr[0]}")
        arr[1]=$(ask "$label (${DIRLABEL[1]})" "${arr[1]}")
    fi
    apply
}

show_settings() {
    echo "Mode: $MODE"
    printf "%-14s %12s %12s\n" "" "${DIRLABEL[0]}" "${DIRLABEL[1]}"
    printf "%-14s %12s %12s\n" "Delay (ms)"    "${DELAY[0]}"  "${DELAY[1]}"
    printf "%-14s %12s %12s\n" "Jitter (ms)"   "${JITTER[0]}" "${JITTER[1]}"
    printf "%-14s %12s %12s\n" "Loss (%)"      "${LOSS[0]}"   "${LOSS[1]}"
    printf "%-14s %12s %12s\n" "Rate (kbit/s)" "${RATE[0]}"   "${RATE[1]}"
}

while true; do
    clear 2>/dev/null
    echo "===== NETem - Network Emulator ====="
    echo "Transparently bridging eth0 <-> eth1"
    echo ""
    show_settings
    echo ""
    echo " 1) Change mode (symmetric/asymmetric)"
    echo " 2) Set delay"
    echo " 3) Set jitter (requires delay)"
    echo " 4) Set loss"
    echo " 5) Set rate limit (0 = unlimited)"
    echo " 6) Clear all settings"
    echo " 7) Show tc status"
    echo " 8) Shell (type 'exit' to return to this menu)"
    echo ""
    read -rp "Select option: " choice
    case "$choice" in
        1)
            if [ "$MODE" == "symmetric" ]; then
                MODE="asymmetric"
            else
                MODE="symmetric"
                DELAY[1]="${DELAY[0]}"; JITTER[1]="${JITTER[0]}"
                LOSS[1]="${LOSS[0]}"; RATE[1]="${RATE[0]}"
                apply
            fi
            ;;
        2) set_param DELAY "Delay in ms" ;;
        3) set_param JITTER "Jitter in ms" ;;
        4) set_param LOSS "Loss in %" ;;
        5) set_param RATE "Rate in kbit/s" ;;
        6)
            DELAY=(0 0); JITTER=(0 0); LOSS=(0 0); RATE=(0 0)
            apply
            ;;
        7)
            echo ""
            tc qdisc show dev eth0
            tc qdisc show dev eth1
            read -rp "Press ENTER to continue" _
            ;;
        8) bash ;;
        *) ;;
    esac
done
