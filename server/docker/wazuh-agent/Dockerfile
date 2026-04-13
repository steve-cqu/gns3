FROM debian:bookworm-slim

# Install prerequisites
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    gnupg \
    ca-certificates \
    bash \
    nano \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

# Add Wazuh apt repository and install agent
RUN curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --dearmor -o /usr/share/keyrings/wazuh.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" \
       > /etc/apt/sources.list.d/wazuh.list \
    && apt-get update \
    && apt-get install -y wazuh-agent \
    && rm -rf /var/lib/apt/lists/*

# Copy template ossec.conf (MANAGER_IP is a placeholder students replace)
ADD ossec.conf /var/ossec/etc/ossec.conf

# Startup helper script
ADD start-wazuh-agent.sh /bin/start-wazuh-agent.sh
RUN chmod +x /bin/start-wazuh-agent.sh

VOLUME /var/ossec/logs /var/ossec/etc
