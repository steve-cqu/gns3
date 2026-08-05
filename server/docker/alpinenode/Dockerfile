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

# Add packages
RUN apk add --no-cache \
openssh \
mtr \
nmap \
iperf \
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
