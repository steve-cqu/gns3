#!/bin/bash
# Copy Firefox logo
wget https://raw.githubusercontent.com/GNS3/gns3-registry/refs/heads/master/symbols/firefox.svg
cp firefox.svg ~/.venv/gns3server-venv/lib/python3.9/site-packages/gns3server/symbols/classic/