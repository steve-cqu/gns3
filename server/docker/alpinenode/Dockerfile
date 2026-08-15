# Create a lightweight Alpine Linux-based Docker image with various networking tools and a pre-configured user.
#
# The base is pinned. On `alpine:latest` a rebuild months later silently moves the whole
# userland — that is how OpenSSH 10 arrived and removed DSA, breaking a key-generation step
# that three activities then had to apologise for. A pinned base makes the release tags in
# RELEASES.md mean something: the same tag builds the same userland.
FROM alpine:3.24

# Add community repository to access more packages
RUN echo "https://dl-cdn.alpinelinux.org/alpine/$(grep VERSION_ID /etc/os-release | cut -d '=' -f2 | cut -d "." -f 1,2 | tr -d \")/community" \
    >> /etc/apk/repositories

# Add packages.
#
# Two of these are here for the monitoring and performance activities rather than for the
# general host role:
#   iperf3                    - `iperf` is Alpine's iperf *2*, and the activities call for
#                               iperf3. Both are kept: some older material still uses v2.
#   prometheus-node-exporter  - so ANY Linux Host is monitorable without swapping it for a
#                               special node. 16.5 MB, and it is what removes the need for a
#                               separate "monitoring host" image. Started with
#                               `node_exporter &` on the host being monitored; the Monitor
#                               node (cqugns3/monitornode) scrapes it on :9100.
#   chrony                    - the NTP CLIENT side, on every host: `chronyd -Q 'server <ip>
#                               iburst'` measures the offset and delay to a time server without
#                               touching any clock (it cannot: container nodes share the GNS3
#                               VM's clock). 390 KB. The NTP Server template is the same
#                               package on cqugns3/servicenode with a server config.
#   libfaketime               - runs ONE command with a different idea of the time. 200 KB.
#                               NOTE, measured on the built appliance 14 Aug 2026: this fakes
#                               `date` correctly but does NOT affect `kinit` or `chronyd` --
#                               both read the clock through the vDSO, which LD_PRELOAD cannot
#                               intercept. `faketime -f '+2h' kinit` returns 0 and issues a
#                               ticket at the REAL time; `chronyd -Q` under faketime hangs.
#                               So it does NOT demonstrate Kerberos clock skew, which was the
#                               original reason for adding it. Kept because it is small and
#                               does work for simple commands; do not build teaching on it
#                               without testing the specific program first.
RUN apk add --no-cache \
openssh \
mtr \
nmap \
iperf \
iperf3 \
prometheus-node-exporter \
chrony \
libfaketime \
socat \
vim \
nano \
curl \
links \
iputils \
bind-tools \
rsync \
bash \
python3 \
ansible \
tailscale \
git \
ca-certificates \
openssl \
nginx \
fail2ban \
wireguard-tools \
whois \
 && update-ca-certificates

# wg-quick, again, in /usr/local/bin — where PATH finds it first.
#
# MEASURED 15 August 2026 on the T3 appliance (GNS3 2.2.61, Docker 29.6.2), and it is as odd as
# it reads: inside a GNS3 Docker node, running the packaged `/usr/bin/wg-quick` fails at its very
# first line with
#
#     /usr/bin/wg-quick: line 11: /usr/bin/readlink: Permission denied
#
# so `wg-quick up wg0` — a documented student step in wireguard-basics — does nothing. A
# byte-identical COPY of that same file, in the same directory, runs perfectly; so does the
# original under `bash /usr/bin/wg-quick`; and so does the original under a plain
# `docker run cqugns3/alpinenode`. Only the image's own inode, executed via its shebang inside a
# GNS3 node, fails. The cause is not established — it is not permissions (0755, no xattrs, no
# capabilities), not seccomp (none), not noexec (the root overlay is mounted rw,relatime), and not
# Docker (plain docker run works).
#
# What IS established is the shape of the workaround: a script that GNS3 has copied into one of its
# ext4 volumes always works, which is why every other helper script in this image set — the
# start-*.sh family in /usr/local/bin — has never hit this. /usr/local/bin is a GNS3 volume, so the
# copy below is re-copied onto a real filesystem when a node first starts, and PATH puts
# /usr/local/bin ahead of /usr/bin. wg-quick is the only #!/bin/bash script in the image that
# students execute directly, so this is the only place the problem can bite.
#
# Do not "simplify" this to a symlink: a symlink resolves back to the failing inode. And do not
# move it to /usr/sbin: a build-time copy anywhere outside a volume is still an image-layer file
# at runtime, which is the failing case. Full write-up in
# gns3-dev/notes/tier1-service-nodes-plan.md.
RUN cp /usr/bin/wg-quick /usr/local/bin/wg-quick

# Helper scripts. COPY, not ADD: these are plain local files, and ADD additionally
# unpacks archives and fetches URLs, which is not wanted here.
COPY setup-github.sh /bin/setup-github.sh
COPY reset-github.sh /bin/reset-github.sh
COPY start-sshd      /bin/start-sshd
RUN chmod +x /bin/setup-github.sh /bin/reset-github.sh /bin/start-sshd

# A class group and a student user. The account is what ssh-hardening restricts logins to
# with AllowUsers. It ships with NO SSH keys: a single private key copied into every node
# of every image is the exact practice the SSH activities teach against, and students
# create their own with ssh-keygen and ssh-copy-id. /home/student/.ssh is deliberately not
# created here either — ssh-copy-id creates it with the right ownership and mode, and
# watching that happen is part of the lesson.
RUN addgroup --gid "20001" "class" \
 && adduser \
    --disabled-password \
    --gecos "" \
    --home "/home/student" \
    --ingroup "class" \
    --uid "10001" \
    student \
 && echo 'student:gns3' | chpasswd

# Persistent volumes
VOLUME /root/.ssh /etc/ssh /data /home/student
