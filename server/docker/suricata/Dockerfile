FROM alpine:latest

# Add community repository
RUN echo "https://dl-cdn.alpinelinux.org/alpine/$(grep VERSION_ID /etc/os-release | cut -d '=' -f2 | cut -d "." -f 1,2 | tr -d \")/community" \
    >> /etc/apk/repositories

RUN apk add --no-cache \
    suricata \
    python3 \
    bash \
    nano \
    curl \
    ca-certificates

# Create rules directory
RUN mkdir -p /var/lib/suricata/rules /var/log/suricata /var/run/suricata

# Ship an empty custom.rules so suricata.yaml validates out of the box (suricata -T
# passes). Students append their own rules here during the activity.
RUN printf '%s\n' \
    '# Custom Suricata rules. Add one rule per line, for example:' \
    '# alert http any any -> any any (msg:"BadBot UA"; http.user_agent; content:"BadBot"; sid:1000001; rev:1;)' \
    > /var/lib/suricata/rules/custom.rules

# Pre-configured suricata.yaml (HOME_NET and interface can be adjusted by students)
ADD suricata.yaml /etc/suricata/suricata.yaml

# Startup helper script
ADD start-suricata.sh /bin/start-suricata.sh
RUN chmod +x /bin/start-suricata.sh

VOLUME /var/lib/suricata/rules /var/log/suricata /etc/suricata
