#!/bin/bash
# Configure and start Wazuh agent
# Usage: start-wazuh-agent.sh <manager_ip>
# Or set MANAGER_IP environment variable

MANAGER="${1:-$MANAGER_IP}"

if [ -z "$MANAGER" ]; then
    echo "Usage: start-wazuh-agent.sh <manager_ip>"
    echo "Or set MANAGER_IP environment variable"
    exit 1
fi

# Replace the placeholder in ossec.conf
sed -i "s/MANAGER_IP/$MANAGER/" /var/ossec/etc/ossec.conf

echo "Configured Wazuh agent to connect to manager: $MANAGER"
echo "Starting Wazuh agent..."

/var/ossec/bin/wazuh-control start

echo "Wazuh agent started."
echo "Check status with: /var/ossec/bin/wazuh-control status"
echo "Check logs with: tail -f /var/ossec/logs/ossec.log"
