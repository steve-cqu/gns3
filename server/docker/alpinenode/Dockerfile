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
#   libfaketime               - runs ONE command with a different idea of the time, which is the
#                               only way to demonstrate clock skew on a container node. 200 KB,
#                               and it is inherited by auth-kerberos, where it earns its place:
#                               `faketime '+6 minutes' kinit student` produces the real
#                               "Clock skew too great" failure.
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
