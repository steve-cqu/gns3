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

# Pre-configured suricata.yaml (HOME_NET and interface can be adjusted by students)
ADD suricata.yaml /etc/suricata/suricata.yaml

# Startup helper script
ADD start-suricata.sh /bin/start-suricata.sh
RUN chmod +x /bin/start-suricata.sh

VOLUME /var/lib/suricata/rules /var/log/suricata /etc/suricata
