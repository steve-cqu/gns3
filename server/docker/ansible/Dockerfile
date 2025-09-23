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
VOLUME /root/.ssh /etc/ssh /data
ADD start-ssh.sh /bin/start-ssh.sh