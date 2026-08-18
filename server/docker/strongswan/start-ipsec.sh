#!/bin/sh
# start-ipsec.sh — start the strongSwan daemon, then load /etc/swanctl/swanctl.conf.
#
# Run this on an IPsec Gateway node after editing /etc/swanctl/swanctl.conf. Safe to run again
# after every edit: it starts charon only if it is not already running, then reloads the config,
# which is the loop a student is in while getting a tunnel up.
#
# Why the daemon is started by hand rather than by a service: this is a container, so there is no
# systemd and no OpenRC (Alpine's strongswan package ships no init script at all). charon runs in
# the foreground by default, hence the `&`.

CHARON=/usr/lib/strongswan/charon      # not /usr/libexec — Alpine puts it here
VICI=/var/run/charon.vici
LOG=/var/log/charon.log

if pgrep -f "$CHARON" >/dev/null 2>&1 && [ -S "$VICI" ]; then
    echo "charon is already running"
else
    echo "starting charon ..."
    "$CHARON" >"$LOG" 2>&1 &
    # Wait for the vici socket rather than sleeping a fixed amount: swanctl talks to charon over
    # it, and "connecting to unix:///var/run/charon.vici failed" is the error you get for being
    # half a second early.
    i=0
    while [ ! -S "$VICI" ] && [ "$i" -lt 15 ]; do sleep 1; i=$((i + 1)); done
fi

if [ ! -S "$VICI" ]; then
    echo "ERROR: charon did not create $VICI after 15s. Last lines of $LOG:"
    tail -20 "$LOG" 2>/dev/null
    exit 1
fi

echo "loading /etc/swanctl/swanctl.conf ..."
swanctl --load-all
