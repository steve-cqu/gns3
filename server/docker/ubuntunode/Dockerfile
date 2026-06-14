# Lightweight Ubuntu 24.04 host with networking + full-userland security tooling.
# Companion to cqugns3/alpinenode: a glibc/apt host (useradd, sudo, PAM, yescrypt).
FROM ubuntu:24.04
ARG DEBIAN_FRONTEND=noninteractive

# The 24.04 base enables universe by default; ensure it defensively (deb822 sources).
RUN sed -i 's/Components: main restricted/Components: main restricted universe multiverse/' \
        /etc/apt/sources.list.d/ubuntu.sources || true

# Add packages (apt-get equivalents of the alpinenode toolset, plus PAM/security tools)
RUN ln -fs /usr/share/zoneinfo/Etc/UTC /etc/localtime \
 && apt-get update && apt-get install -y --no-install-recommends \
    openssh-server openssh-client \
    iproute2 iputils-ping iputils-tracepath iputils-arping \
    net-tools dnsutils mtr-tiny nmap socat netcat-openbsd tcpdump \
    curl wget links rsync telnet whois \
    vim nano bash less \
    ca-certificates openssl git python3 \
    nginx wireguard-tools iperf3 iperf \
    sudo fail2ban libpam-pwquality libpwquality-tools \
    tzdata \
 && dpkg-reconfigure --frontend noninteractive tzdata \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

# Update CA certificates
RUN update-ca-certificates

# Copy GitHub helper scripts
ADD setup-github.sh /bin/setup-github.sh
ADD reset-github.sh /bin/reset-github.sh
RUN chmod +x /bin/setup-github.sh /bin/reset-github.sh

# Add a group for the class and a student user (groupadd/useradd replace busybox addgroup/adduser)
RUN groupadd --gid 20001 class \
 && useradd --create-home --home-dir /home/student --shell /bin/bash \
            --gid class --uid 10001 --comment "" student \
 && mkdir -p /home/student/.ssh \
 && echo 'student:gns3' | chpasswd

# Persistent volumes
VOLUME /root/.ssh /etc/ssh /data /home/student

# Add SSH starter script and SSH keys (same shared student keys as alpinenode)
ADD start-ssh.sh /bin/start-ssh.sh
ADD gns3_student_rsa_key.prv /home/student/.ssh/id_rsa
ADD gns3_student_rsa_key.pub /home/student/.ssh/id_rsa.pub
ADD gns3_student_ed25519_key.prv /home/student/.ssh/id_ed25519
ADD gns3_student_ed25519_key.pub /home/student/.ssh/id_ed25519.pub
ADD gns3_student_rsa_key.pub /home/student/.ssh/authorized_keys
RUN cat /home/student/.ssh/id_ed25519.pub >> /home/student/.ssh/authorized_keys \
 && chown -R student:class /home/student/.ssh \
 && chmod u=rwX,go= /home/student/.ssh \
 && chmod u=rw,go= /home/student/.ssh/id_rsa /home/student/.ssh/id_ed25519 \
 && chmod u=rw,go=r /home/student/.ssh/id_rsa.pub /home/student/.ssh/id_ed25519.pub \
 && chmod u=rwX,go= /home/student/.ssh/authorized_keys \
 && chmod +x /bin/start-ssh.sh
