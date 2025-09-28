FROM alpine
RUN sed -i 's/#http/http/' /etc/apk/repositories
RUN apk update
RUN apk add openssh
RUN apk add mtr
RUN apk add nmap
RUN apk add iperf
RUN apk add socat
RUN apk add vim
RUN apk add nano
RUN apk add curl
RUN apk add links
RUN apk add iputils
RUN apk add bind-tools
RUN apk add rsync
RUN apk add bash
RUN apk add python3
RUN apk add ansible
RUN apk add tailscale

RUN addgroup \
    --gid "20001" \
    "class"

RUN adduser \
    --disabled-password \
    --gecos "" \
    --home "/home/student" \
    --ingroup "class" \
    --uid "10001" \
    student

RUN mkdir -p /home/student/.ssh
RUN echo 'student:gns3' | chpasswd

VOLUME /root/.ssh /etc/ssh /data /home/student

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

