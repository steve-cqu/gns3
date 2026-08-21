FROM alpine:3.24

# NO repository line here, deliberately — the same removal alpinenode/Dockerfile documents.
#
# There used to be one, appending a community repository computed from VERSION_ID. It built a
# URL without the "v" that Alpine's layout uses — .../alpine/3.24/community instead of
# .../alpine/v3.24/community — so it 404'd, and every `apk` command on this image printed
#
#     WARNING: ... /alpine/3.24/community/aarch64/APKINDEX.tar.gz: HTTP 404: Not Found
#
# including the ones students run in the shell during the Suricata activity. Nothing was ever
# broken by it, which is why it survived: the official alpine:3.24 image already ships BOTH
# main and community in /etc/apk/repositories, so suricata — a community package — always
# resolved from the base image's own line. The 21 August 2026 arm64 build installed all 49
# packages with this block still present and 404ing, which is the proof.

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
