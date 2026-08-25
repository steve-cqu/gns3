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
#
# sssd / realmd / adcli / krb5-user / ldap-utils back the "Domain Client" template, which joins
# the Samba AD Domain Controller (cqugns3/sambadc). They are here for the same reason as the
# three above: Alpine packages NONE of sssd, realmd or adcli on any branch, so a domain-joined
# Linux client can only be an Ubuntu node. Same image, second template — the docker-trafficgen
# precedent: no new image for a node that is packages and a label.
#
# All of them are installed HERE rather than left to `realm join` because realmd's answer to a
# missing package is to call PackageKit, which wants a working apt inside the topology. Nothing
# in the lab has that, and an activity that silently depends on Internet access inside GNS3 is
# the anti-pattern candidate-node-types.md exists to stop.
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
    sssd sssd-tools realmd adcli krb5-user ldap-utils \
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

# Deliberately vulnerable teaching apps for the web-attack activities, shipped so students read
# and run a file rather than pasting ~40 lines into a console (which is where those activities
# failed in a tutorial). vulnsite.py has a SQL-injectable login (web-app-attacks-basics);
# xsssite.py reflects and stores unescaped HTML (xss-basics). vulnsite.py also issues a plain-HTTP
# session cookie (username + a hash of it with a server secret, the scheme the book's MyUni site
# uses) so the same activity can steal a session off the wire. Both are inert until run, serve on
# :8080, and are edited in place for each activity's fix task. Placed last so the expensive apt
# and rockyou layers above stay cached on a rebuild.
COPY vulnsite.py /root/vulnsite.py
COPY xsssite.py  /root/xsssite.py

# Persistent volumes
VOLUME /root/.ssh /etc/ssh /data /home/student
