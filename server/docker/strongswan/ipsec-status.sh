#!/bin/sh
# ipsec-status.sh — one screen answering "is the tunnel up, and what did it negotiate?"
#
# The three things worth seeing, in the order you want them when something is wrong: is the
# daemon alive, what did it load from swanctl.conf, and what is actually established. The SA
# listing is where the negotiated proposal appears (e.g. ESP:AES_GCM_16-256), which is the line
# the material asks students to read.

echo "== daemon =="
if pgrep -f /usr/lib/strongswan/charon >/dev/null 2>&1; then
    echo "charon: running"
else
    echo "charon: NOT running — run start-ipsec.sh"
    exit 1
fi

echo
echo "== loaded connections =="
swanctl --list-conns

echo
echo "== security associations =="
swanctl --list-sas

echo
echo "== kernel state (XFRM) =="
ip xfrm state list 2>/dev/null | grep -E "^src|aead|enc |auth " | head -20
