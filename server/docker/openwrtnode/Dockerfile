# OpenWRT as a Docker node — the GUI router.
#
# The Qemu OpenWRT and OPNsense nodes give students a real network appliance with a web
# interface, which is worth a lot in an introductory unit. They cost three things a container
# does not:
#
#   1. Boot time where there is no nested virtualisation. OPNsense boots in ~20 s with KVM and
#      takes MINUTES without (see server/README.md, "Qemu hardware acceleration"). Every Apple
#      Silicon Mac and every managed Windows laptop with Credential Guard is in the slow case.
#   2. Architecture-locked project files: a .gns3project bakes in each Qemu node's qemu_path and
#      disk, so any project containing one needs a maintained -arm64 variant.
#   3. Disk. This image is ~5 MB.
#
# This node has none of those. It starts instantly, one build serves both architectures, and a
# project containing it is portable between a PC and a Mac.
#
# NO PACKAGES ARE INSTALLED, AND THAT IS DELIBERATE.
#
# The stock OpenWRT rootfs already ships luci, luci-base, luci-mod-network/status/system,
# luci-app-firewall, luci-theme-bootstrap, uhttpd, rpcd, firewall4, nftables, dnsmasq, odhcpd
# and dropbear. Adding to it is actively dangerous: `opkg install luci` on 24.10.8 pulls LuCI
# 26.222 from the release feed while the image ships luci-base 26.205, and every LuCI page then
# fails with "left-hand side expression is null" in runtime.uc. Measured 16 August 2026. If a
# package is ever genuinely needed here, upgrade the whole luci* set together or pin it, and
# re-check that the login page still renders.
#
# The base tag is per-architecture — openwrt/rootfs publishes one architecture per tag rather
# than a multi-arch manifest — so the manifest carries two node entries (openwrtnode and
# openwrtnode-arm64) that differ only in this build arg and both produce this image name. That
# mirrors what the Qemu openwrt/openwrt-arm64 entries already do.
#
# The arm value MUST carry a `@sha256:…` digest: every arm tag of this image is labelled with
# OpenWRT's package architecture (`aarch64_generic`), which no Docker platform string matches, so
# a plain tag fails with "no match for platform in manifest". See the long note above
# openwrtnode-arm64 in server/build/manifest.yml.
ARG OPENWRT_TAG=x86-64-24.10.8
FROM openwrt/rootfs:${OPENWRT_TAG}

# ---------------------------------------------------------------------------------------------
# The console. This is the one thing that has to be fixed for OpenWRT to work as a GNS3 node.
#
# GNS3 attaches a Docker node's telnet console to PID 1's stdin/stdout
# (`containers/<id>/attach/ws`, with Tty and OpenStdin set), and Docker makes /dev/console the
# pty in that case. OpenWRT's stock inittab spawns its login shell on ttyS0, hvc0 and tty1 —
# none of which is that pty — so with procd as PID 1 the GNS3 console echoes what you type and
# executes nothing. It looks like a hung node; it is a device-name mismatch.
#
# `askconsole` is the action that works, and the choice is not obvious — measured 16 August 2026
# by building all five variants and counting the spawned shell:
#
#   ::askconsole:/bin/ash --login          shell on /dev/console          <- this one
#   console::askfirst:/bin/ash --login     shell on /dev/console          also works
#   ::askfirst:/bin/ash --login            nothing spawned
#   ::respawn:/bin/ash --login             nothing spawned
#   ::respawnlate:/bin/ash --login         nothing spawned
#
# `askconsole` with an empty tty field lets procd resolve the console itself, which lands on
# /dev/console — exactly where GNS3 is listening. The `respawn` actions look like the obvious
# choice and silently do nothing here.
#
# /bin/ash --login rather than /usr/libexec/login.sh: the console is a root shell on every other
# node in this appliance, and login.sh would prompt for the root password set below. The
# password still guards LuCI and SSH, which is where it matters.
RUN sed -i '/askfirst/d' /etc/inittab \
 && echo '::askconsole:/bin/ash --login' >> /etc/inittab

# The root password. LuCI needs one to log in at all, and dropbear uses it for SSH.
# A throwaway lab credential, in line with the rest of this appliance.
RUN printf 'gns3\ngns3\n' | passwd root >/dev/null 2>&1

# WAN on the second interface.
#
# This CANNOT be done with `uci` at build time: /etc/config/network does not exist in the image.
# OpenWRT generates it on first boot (/etc/init.d/boot runs /bin/config_generate), so a
# build-time `uci set network.wan=…` fails with "Entry not found" and, if it somehow succeeded,
# would be overwritten. The supported hook is a uci-defaults script, which runs immediately
# after config_generate and deletes itself once it succeeds.
COPY 99-gns3-network /etc/uci-defaults/99-gns3-network
RUN chmod +x /etc/uci-defaults/99-gns3-network

# Show the GNS3 node name in LuCI instead of the stock "OpenWrt".
#
# GNS3 sets the container hostname from the node name, but OpenWRT reads its hostname from UCI,
# so LuCI's header and every screenshot a student takes would otherwise say "OpenWrt" for every
# node in the topology. rc.local runs at the end of boot (via /etc/init.d/done) and its failures
# are ignored, so this cannot stop the node coming up.
COPY rc.local /etc/rc.local
RUN chmod +x /etc/rc.local

# NO `VOLUME /etc` HERE, DELIBERATELY.
#
# Persistence is the template's job: docker-openwrt.conf sets extra_volumes ["/etc", "/root"],
# which is what GNS3 acts on (UCI config lives in /etc/config, and a GNS3 Docker node is rebuilt
# from its image every time a project is closed). Declaring /etc as a VOLUME here as well would
# add nothing and break derived images: Docker DISCARDS anything a `RUN` writes into a path the
# base image declared as a volume, so `FROM cqugns3/openwrtnode` + `RUN … /etc/inittab …` would
# build green and change nothing. Measured 16 August 2026 while testing console variants, which
# all silently inherited the parent's inittab.
