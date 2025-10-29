#!/bin/bash

echo ""
echo "###############################################"
echo "#                                             #"
echo "#        NAT64 ROUTER SETUP SCRIPT            #"
echo "#                                             #"
echo "###############################################"
echo ""

# Run interface configuration
/usr/local/bin/configure-nat64-router.sh

echo ""

# Run NAT64 configuration
/usr/local/bin/start-nat64.sh

echo ""
echo "Setup complete! Router is ready for NAT64 translation."
echo ""
