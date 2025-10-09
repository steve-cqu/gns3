#!/bin/bash
# Install logos

# Copy Firefox logo
wget -q https://raw.githubusercontent.com/GNS3/gns3-registry/refs/heads/master/symbols/firefox.svg -O /home/gns3/firefox.svg
cp /home/gns3/firefox.svg ~/.venv/gns3server-venv/lib/python3.9/site-packages/gns3server/symbols/classic/

# Other logos
cp ../images/symbols/*.svg ~/.venv/gns3server-venv/lib/python3.9/site-packages/gns3server/symbols/classic/
