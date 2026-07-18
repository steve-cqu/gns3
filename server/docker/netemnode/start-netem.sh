#!/bin/bash
# Bridge eth0 <-> eth1 so the node is transparent, then run the settings menu
# on the GNS3 console.

ip link add name br0 type bridge 2>/dev/null
ip link set eth0 master br0
ip link set eth1 master br0
ip link set eth0 up
ip link set eth1 up
ip link set br0 up

# Restart the menu if it ever exits, so the container keeps running
while true; do
    /bin/netem-menu.sh
done
