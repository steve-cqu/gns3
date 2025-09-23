#!/bin/bash
# Install NoVNC in GNS3 VM

# Install packages
sudo apt -y update
sudo apt -y install novnc python3-websockify python3-numpy

# Create local script to start VNC
echo '#!/bin/bash' > start-vnc.sh
echo 'websockify --daemon --web=/usr/share/novnc/ $2 localhost:$1' >> start-vnc.sh
chmod +x start-vnc.sh
