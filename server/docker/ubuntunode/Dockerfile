# Lightweight Ubuntu 24.04 host with networking + full-userland security tooling.
# Companion to cqugns3/alpinenode: a glibc/apt host (useradd, sudo, PAM, yescrypt).
FROM ubuntu:24.04
ARG DEBIAN_FRONTEND=noninteractive

# The 24.04 base enables universe by default; ensure it defensively (deb822 sources).
RUN sed -i 's/Components: main restricted/Components: main restricted universe multiverse/' \
        /etc/apt/sources.list.d/ubuntu.sources || true

# Add packages (apt-get equivalents of the alpinenode toolset, plus PAM/security tools).
#
# hping3 / mgen / tcpreplay back the "Traffic Generator" template. They are here rather than
# in alpinenode because Alpine has hping3 only in edge/testing and does not package mgen or
# nping at all — reaching into edge from a pinned base is what ipv6node had to do for tayga,
# and it is the thing most likely to break on a rebuild. Ubuntu carries all three in
# universe for both architectures. nping arrives with nmap, already installed above.
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
    libpam-google-authenticator \
    john \
    dsniff nftables rsyslog \
    hping3 mgen tcpreplay \
    tzdata \
 && dpkg-reconfigure --frontend noninteractive tzdata \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

# Update CA certificates
RUN update-ca-certificates

# Wordlist for password-cracking activities (John the Ripper), at the conventional Kali path
RUN mkdir -p /usr/share/wordlists \
 && wget -q -O /usr/share/wordlists/rockyou.txt \
      https://github.com/brannondorsey/naive-hashcat/releases/download/data/rockyou.txt \
 && test -s /usr/share/wordlists/rockyou.txt

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
RUN groupadd --gid 20001 class \
 && useradd --create-home --home-dir /home/student --shell /bin/bash \
            --gid class --uid 10001 --comment "" student \
 && echo 'student:gns3' | chpasswd

# Persistent volumes
VOLUME /root/.ssh /etc/ssh /data /home/student
