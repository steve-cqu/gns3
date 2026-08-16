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
# with WPA2-PSK; wpa_supplicant.conf joins that SSID with the same passphrase.
COPY hostapd.conf         /etc/hostapd/hostapd.conf
COPY wpa_supplicant.conf  /etc/wpa_supplicant/wpa_supplicant.conf

# Helper scripts in /usr/local/bin (persisted, and ahead of /bin in PATH) so a student's edits
# survive a project close — the lesson recorded in ipv6node's Dockerfile.
COPY start-ap.sh       /usr/local/bin/start-ap.sh
COPY start-sta.sh      /usr/local/bin/start-sta.sh
COPY start-monitor.sh  /usr/local/bin/start-monitor.sh
COPY wifi-status.sh    /usr/local/bin/wifi-status.sh
RUN chmod +x /usr/local/bin/start-ap.sh /usr/local/bin/start-sta.sh \
             /usr/local/bin/start-monitor.sh /usr/local/bin/wifi-status.sh
