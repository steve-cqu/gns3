#!/bin/bash
# Bridge one VNC port to one web port on the GNS3 VM — the manual fallback.
#
# Students do NOT need this any more. The appliance runs the gns3-novnc service from boot,
# which serves every VNC console on the VM from one port:
#
#     http://<GNS3_VM_IP>:6080/          pick the node, click Open console
#
# What is left for this script is the case the service deliberately will not resolve: a VNC
# server on this VM that is not the console of a started GNS3 node. Give it a web port other
# than 6080, or it cannot bind — the service already holds that one.
#
# Usage: ./start-vnc.sh <vnc-port> <web-port>
#   ./start-vnc.sh 5901 6081     then open http://<GNS3_VM_IP>:6081/vnc.html
#   ./start-vnc.sh 5902 6082     one more, for a second VNC server
#
# It daemonises, so it keeps running after you leave the shell and until the VM reboots.
# `pkill -f websockify` stops the lot.

websockify --daemon --web=/usr/share/novnc/ $2 localhost:$1
