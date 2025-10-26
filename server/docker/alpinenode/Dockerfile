# Create a lightweight Alpine Linux-based Docker image with various networking tools and a pre-configured user.
FROM alpine:latest

# Add community repository to access more packages
RUN echo "https://dl-cdn.alpinelinux.org/alpine/$(grep VERSION_ID /etc/os-release | cut -d '=' -f2 | tr -d \")/community" \
    >> /etc/apk/repositories && \
    apk add --no-cache neofetch

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
ca-certificates

# Update CA certificates
RUN update-ca-certificates

# Copy GitHub helper scripts
ADD setup-github.sh /bin/setup-github.sh
ADD reset-github.sh /bin/reset-github.sh
RUN chmod +x /bin/setup-github.sh
RUN chmod +x /bin/reset-github.sh

# Add a group for the class
RUN addgroup \
    --gid "20001" \
    "class"

# Add a student user to the class group
RUN adduser \
    --disabled-password \
    --gecos "" \
    --home "/home/student" \
    --ingroup "class" \
    --uid "10001" \
    student

# Set password for student user
RUN mkdir -p /home/student/.ssh
RUN echo 'student:gns3' | chpasswd

# Persistent volumes
VOLUME /root/.ssh /etc/ssh /data /home/student

# Add SSH starter script and SSH keys
ADD start-ssh.sh /bin/start-ssh.sh
ADD gns3_student_rsa_key.prv /home/student/.ssh/id_rsa
ADD gns3_student_rsa_key.pub /home/student/.ssh/id_rsa.pub
ADD gns3_student_ed25519_key.prv /home/student/.ssh/id_ed25519
ADD gns3_student_ed25519_key.pub /home/student/.ssh/id_ed25519.pub
ADD gns3_student_rsa_key.pub /home/student/.ssh/authorized_keys
RUN cat /home/student/.ssh/id_ed25519.pub >> /home/student/.ssh/authorized_keys
RUN chown -R student:class /home/student/.ssh
RUN chmod u=rwX,go= /home/student/.ssh  
RUN chmod u=rw,go= /home/student/.ssh/id_rsa
RUN chmod u=rw,go=r /home/student/.ssh/id_rsa.pub
RUN chmod u=rw,go= /home/student/.ssh/id_ed25519
RUN chmod u=rw,go=r /home/student/.ssh/id_ed25519.pub
RUN chmod u=rwX,go= /home/student/.ssh/authorized_keys
RUN chmod +x /bin/start-ssh.sh

