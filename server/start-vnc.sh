#!/bin/bash
# Run on the GNS3 VM to start a NoVNC server
# Example:
#  - GNS3 node has vnc (instead of telnet) access, e.g. a Firefox Host with port 5901
#  - Enter the shell in GNS3 VM and run this script as:
#    ./start-vnc.sh 5901 6080
#  - Then open a browser and go to http://<GNS3_VM_IP>:6080/vnc.html
#  - You should see the Firefox GUI
# If there are multiple nodes with VNC access, use different ports for each NoVNC server
#  - e.g. ./start-vnc.sh 5901 6080
#  - e.g. ./start-vnc.sh 5902 6081
#  - Then open a browser and go to http://<GNS3_VM_IP>:6080/vnc.html and http://<GNS3_VM_IP>:6081/vnc.html

websockify --daemon --web=/usr/share/novnc/ $2 localhost:$1
