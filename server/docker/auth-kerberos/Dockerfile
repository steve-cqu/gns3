# Alpine node that can act as Kerberos KDC and SSH server/client
FROM cqugns3/alpinenode
# We need to replace the standard OpenSSH with the Kerberos-enabled version
RUN apk del openssh
RUN apk add --no-cache krb5 krb5-server openssh-server-krb5 openssh-client-krb5 openssh-sftp-server
VOLUME /etc
# Add Kerberos configuration and hosts file
# Configuration file is only needed on KDC and server
ADD krb5.conf /etc/krb5.conf
ADD hosts.txt /root/hosts.txt
