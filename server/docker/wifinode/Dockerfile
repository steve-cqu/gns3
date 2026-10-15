# Wireless node: a simulated 802.11 radio, plus hostapd (Access Point) and wpa_supplicant
# (Station) so two of these nodes complete a real WPA2-PSK association and pass data.
#
# Derived from cqugns3/alpinenode rather than alpine:3.24 so a wireless node behaves like every
# other node when a student opens a console on it — ip, dig, curl, vim, nano and the student
# account are already there. The base layers are shared, so the wireless stack costs ~8 MB.
#
# One image, two templates (Access Point, Station), differing only in the shipped config and the
# start script — the same one-image-many-templates pattern as servicenode.
# See gns3-dev/notes/tier5-and-spike-designs.md, Design 1.
FROM cqugns3/alpinenode

# The radio itself is NOT here: it is the mac80211_hwsim kernel module on the GNS3 VM host (listed
# under kernel_modules in build/manifest.yml, loaded by gns3build.py's `docker` phase). A GNS3 node
# is a container in its own network namespace and cannot see the host's simulated radios, so after
# the topology starts a per-radio phy is MOVED into each wireless node's namespace by the host-side
# helper `gns3-wifi-attach` (server/wifi/). Inside the node the moved radio appears as wlan0. This
# is the mininet-wifi model; the netlink create-in-netns alternative needs a bespoke helper and is
# deferred. See the note above.
#
#   iw               - the netlink 802.11 tool: create/inspect interfaces, add a monitor iface
#   hostapd          - the Access Point daemon (WPA2-PSK, a channel, an SSID)
#   wpa_supplicant   - the Station (client) supplicant that associates and does the 4-way handshake
#   wireless-tools   - iwconfig/iwlist, the classic view some students expect
#   iproute2         - `ip` for addressing the wlan interface (also in the base; explicit here)
#   tcpdump          - capture the 4-way handshake off a monitor interface (mon0) ON THE NODE. This
#                      is the ONE activity where an on-node capture is correct: wireless frames are
#                      not on a GNS3 link, so GUI link-capture cannot see them. Documented as the
#                      explicit exception to the capture-on-the-link rule.
RUN apk add --no-cache \
    iw \
    hostapd \
    wpa_supplicant \
    wireless-tools \
    iproute2 \
    tcpdump

# Runtime directory for hostapd/wpa_supplicant control sockets.
RUN mkdir -p /run/hostapd /run/wpa_supplicant /var/log/wifi

# Shipped configuration — valid as it stands and meant to be edited; the config IS the lesson, the
# same standard as the other CQU service nodes. hostapd.conf brings up SSID "cqu-lab" on channel 6
# with WPA2-PSK; wpa_supplicant.conf joins that SSID with the same passphrase. hostapd.conf also
# carries two commented alternatives: a WPA2-Enterprise block (wifi-enterprise) and a rogue-AP block
# that turns on hostapd's own EAP server (evil-twin-8021x).
COPY hostapd.conf         /etc/hostapd/hostapd.conf
COPY wpa_supplicant.conf  /etc/wpa_supplicant/wpa_supplicant.conf
COPY hostapd.eap_user     /etc/hostapd/hostapd.eap_user

# The rogue AP's self-signed certificate, generated at BUILD time (openssl is in the alpinenode
# base). It is NOT signed by the lab CA — that is the point: a station that validates the server
# (ca_cert=) rejects it, a station that does not validate hands over its credentials. The subject
# deliberately SPOOFS the real server's name (CN=radius.lab.example), so the lesson is sharp: even
# copying the name does not help the attacker, because the certificate still does not chain to the
# lab CA. Harmless on every other node, where nothing references it (eap_server stays off). These
# are throwaway lab credentials in a public repo by design; see gns3/CLAUDE.md.
RUN mkdir -p /etc/hostapd/rogue \
 && openssl req -x509 -newkey rsa:2048 -nodes -days 1825 \
      -keyout /etc/hostapd/rogue/rogue.key \
      -out    /etc/hostapd/rogue/rogue.pem \
      -subj '/C=AU/ST=Queensland/O=Free Coffee WiFi/CN=radius.lab.example' \
      -addext 'subjectAltName=DNS:radius.lab.example' \
 && chmod 600 /etc/hostapd/rogue/rogue.key

# Helper scripts in /usr/local/bin (persisted, and ahead of /bin in PATH) so a student's edits
# survive a project close — the lesson recorded in ipv6node's Dockerfile.
COPY start-ap.sh       /usr/local/bin/start-ap.sh
COPY start-sta.sh      /usr/local/bin/start-sta.sh
COPY start-monitor.sh  /usr/local/bin/start-monitor.sh
COPY wifi-status.sh    /usr/local/bin/wifi-status.sh
RUN chmod +x /usr/local/bin/start-ap.sh /usr/local/bin/start-sta.sh \
             /usr/local/bin/start-monitor.sh /usr/local/bin/wifi-status.sh
