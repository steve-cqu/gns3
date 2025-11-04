#!/bin/bash
# Install nodes manually (rather than through GNS3 GUI)
# This normally wil lbe run on a fresh GNS3 VM that has not had any nodes/projects created yet
# Usage: ./vm-install-nodes.sh <ostype> <filename>
# <ostype> can be "mac" (Apple Mac) or "pc" (Windows/Linux)
# <filename> is a text file with one node name per line, e.g.:
#   docker-alpine
#   docker-ubuntu
#   qemu-netem

OSTYPE="$1"
# Set platform:
#  - Apple Mac: linux/arm64/v8
#  - Windows/Linux: linux/amd64
if [ "$OSTYPE" == "mac" ]; then
  echo "Apple Mac detected"
  PLATFORM="linux/arm64/v8" 
else
  echo "Windows/Linux detected"
  PLATFORM="linux/amd64"
fi

# Check if filename is provided
if [ $# -lt 2 ]; then
    echo "Usage: $0 <ostype> <filename>"
    exit 1
fi

NODEFILE="$2"

# Check if file exists
if [ ! -f "$NODEFILE" ]; then
    echo "Error: File '$NODEFILE' not found"
    exit 1
fi

# Prepare
sudo apt -y update
sudo apt -y install zip unzip
mkdir -p /home/gns3/docker
CURDIR=`pwd`
TMPTEMPLATE=`mktemp`
cat template_gns3_controller-head.conf > $TMPTEMPLATE

# Read file line by line
while IFS= read -r line || [ -n "$line" ]; do
    # Skip empty lines and lines starting with #
    if [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]]; then
        continue
    fi
    
    # Trim leading/trailing whitespace
    value=$(echo "$line" | xargs)
    
    # Process each value based on its name
    echo "Processing: $value"
    
    case "$value" in
        docker-gns3-endhost)
            USERNAME="gns3"
            DOCKERNAME="endhost"
            mkdir -p /home/gns3/docker/$DOCKERNAME
            cd /home/gns3/docker/$DOCKERNAME
            wget -q https://raw.githubusercontent.com/GNS3/gns3-registry/refs/heads/master/docker/endhost/Dockerfile
            wget -q https://raw.githubusercontent.com/GNS3/gns3-registry/refs/heads/master/docker/endhost/start-ssh.sh
            docker build --no-cache --platform $PLATFORM -t $USERNAME/$DOCKERNAME  .
            cd $CURDIR
            cat templates/docker-gns3-endhost.conf >> $TMPTEMPLATE
            echo "," >> $TMPTEMPLATE 
            ;;
        docker-gns3-openvswitch)
            USERNAME="gns3"
            DOCKERNAME="openvswitch"
            mkdir -p /home/gns3/docker/$DOCKERNAME
            cd /home/gns3/docker/$DOCKERNAME
            wget -q https://raw.githubusercontent.com/GNS3/gns3-registry/refs/heads/master/docker/openvswitch/Dockerfile
            wget -q https://raw.githubusercontent.com/GNS3/gns3-registry/refs/heads/master/docker/openvswitch/init.sh
            docker build --no-cache --platform $PLATFORM -t $USERNAME/$DOCKERNAME  .
            cd $CURDIR
            cat templates/docker-openvswitch.conf >> $TMPTEMPLATE
            echo "," >> $TMPTEMPLATE 
            ;;
        docker-gns3-ipterm-base)
            USERNAME="gns3"
            DOCKERNAME="ipterm-base"
            mkdir -p /home/gns3/docker/$DOCKERNAME
            cd /home/gns3/docker/$DOCKERNAME
            wget -q https://raw.githubusercontent.com/GNS3/gns3-registry/refs/heads/master/docker/ipterm/base/Dockerfile
            docker build --no-cache --platform $PLATFORM -t $USERNAME/$DOCKERNAME  .
            cd $CURDIR
            ;;
        docker-gns3-ipterm)
            USERNAME="gns3"
            DOCKERNAME="ipterm"
            mkdir -p /home/gns3/docker/$DOCKERNAME
            cd /home/gns3/docker/$DOCKERNAME
            wget -q https://raw.githubusercontent.com/GNS3/gns3-registry/refs/heads/master/docker/ipterm/cli/Dockerfile
            docker build --no-cache --platform $PLATFORM --build-arg DOCKER_REPOSITORY=$USERNAME -t $USERNAME/$DOCKERNAME  .
            cd $CURDIR
            ;;
        docker-gns3-webterm)
            USERNAME="gns3"
            DOCKERNAME="webterm"
            mkdir -p /home/gns3/docker/$DOCKERNAME
            cd /home/gns3/docker/$DOCKERNAME
            wget -q https://raw.githubusercontent.com/GNS3/gns3-registry/refs/heads/master/docker/ipterm/web/Dockerfile
            docker build --no-cache --platform $PLATFORM --build-arg DOCKER_REPOSITORY=$USERNAME -t $USERNAME/$DOCKERNAME  .
            cd $CURDIR
            cat templates/docker-firefoxhost.conf >> $TMPTEMPLATE
            echo "," >> $TMPTEMPLATE
            ;;
        docker-cqugns3-alpinenode)
            USERNAME="cqugns3" # User name 
            DOCKERNAME="alpinenode"
            mkdir -p /home/gns3/docker/$DOCKERNAME
            cd /home/gns3/docker/$DOCKERNAME
            cp /home/gns3/git/gns3/server/docker/alpinenode/* .
            docker build --no-cache --platform $PLATFORM -t $USERNAME/$DOCKERNAME  .
            cd $CURDIR
            cat templates/docker-linuxhost.conf >> $TMPTEMPLATE
            echo "," >> $TMPTEMPLATE
            cat templates/docker-linuxrouter.conf >> $TMPTEMPLATE
            echo "," >> $TMPTEMPLATE
            cat templates/docker-vpnrouter.conf >> $TMPTEMPLATE
            echo "," >> $TMPTEMPLATE
            cat templates/docker-ansiblehost.conf >> $TMPTEMPLATE
            echo "," >> $TMPTEMPLATE
            ;;
        docker-adosztal-net_toolbox)
            USERNAME="adosztal" # User name 
            DOCKERNAME="net_toolbox"
            mkdir -p /home/gns3/docker/$DOCKERNAME
            cd /home/gns3/docker/$DOCKERNAME
            cp /home/gns3/git/gns3/server/docker/net_toolbox/* . 
            docker build --no-cache --platform $PLATFORM -t $USERNAME/$DOCKERNAME  .
            cd $CURDIR
            cat templates/docker-linuxserver.conf >> $TMPTEMPLATE
            echo "," >> $TMPTEMPLATE
            ;;
        docker-cqugns3-auth-kerberos)
            USERNAME="cqugns3" # User name 
            DOCKERNAME="auth-kerberos"
            mkdir -p /home/gns3/docker/$DOCKERNAME
            cd /home/gns3/docker/$DOCKERNAME
            cp /home/gns3/git/gns3/server/docker/auth-kerberos/* .
            docker build --no-cache --platform $PLATFORM -t $USERNAME/$DOCKERNAME  .
            cd $CURDIR
            cat templates/docker-kerberos.conf >> $TMPTEMPLATE
            echo "," >> $TMPTEMPLATE
            ;;
        docker-cqugns3-ipv6node)
            USERNAME="cqugns3" # User name 
            DOCKERNAME="ipv6node"
            mkdir -p /home/gns3/docker/$DOCKERNAME
            cd /home/gns3/docker/$DOCKERNAME
            cp /home/gns3/git/gns3/server/docker/ipv6node/* .
            docker build --no-cache --platform $PLATFORM -t $USERNAME/$DOCKERNAME  .
            cd $CURDIR
            cat templates/docker-ipv6node.conf >> $TMPTEMPLATE
            echo "," >> $TMPTEMPLATE
            ;;
        docker-gns3-kali)
            USERNAME="gns3"
            DOCKERNAME="kalilinux"
            mkdir -p /home/gns3/docker/$DOCKERNAME
            cd /home/gns3/docker/$DOCKERNAME
            wget -q https://github.com/GNS3/gns3-registry/raw/refs/heads/master/docker/kalilinux/Dockerfile 
            wget -q https://github.com/GNS3/gns3-registry/raw/refs/heads/master/docker/kalilinux/index-1.html
            docker build --no-cache --platform $PLATFORM -t $USERNAME/$DOCKERNAME  .
            cd $CURDIR
            cat templates/docker-kali.conf >> $TMPTEMPLATE
            echo "," >> $TMPTEMPLATE 
            ;;
        qemu-netem)
            cd /opt/gns3/images/QEMU
            fn="NETem-v4.qcow2"
            wget -q https://sourceforge.net/projects/gns-3/files/Qemu%20Appliances/NETem-v4.qcow2/download -O ${fn}
            echo -n "e678698c97804901c7a53f6b68c8b861" > ${fn}.md5sum
            md5sum -c <(echo $(<${fn}.md5sum) ${fn})
            cd $CURDIR
            cat templates/qemu-netem.conf >> $TMPTEMPLATE
            echo "," >> $TMPTEMPLATE
            ;;
        qemu-alpine)
            cd /opt/gns3/images/QEMU
            fn="alpine-virt-3.18.4.qcow2"
            wget -q https://sourceforge.net/projects/gns-3/files/Qemu%20Appliances/alpine-virt-3.18.4.qcow2/download -O ${fn}
            echo -n "99d393c16c870e12c4215aadd82ca998" > ${fn}.md5sum
            md5sum -c <(echo $(<${fn}.md5sum) ${fn})
            cd $CURDIR
            cat templates/qemu-alpine.conf >> $TMPTEMPLATE
            echo "," >> $TMPTEMPLATE
            ;;
        qemu-ubuntu)
            cd /opt/gns3/images/QEMU
            fn="ubuntu-24.04-server-cloudimg-amd64.img"
            wget -q https://cloud-images.ubuntu.com/releases/noble/release-20241004/ubuntu-24.04-server-cloudimg-amd64.img -O ${fn}
            echo -n "a1c8a01953578ad432cbef03db2f3161" > ${fn}.md5sum
            md5sum -c <(echo $(<${fn}.md5sum) ${fn})
            # Cloud init data
            wget -q https://github.com/GNS3/gns3-registry/raw/master/cloud-init/ubuntu-cloud/ubuntu-cloud-init-data.iso -O ubuntu-cloud-init-data.iso
            echo -n "9a90ee8f88736204c756015b3cd86500" > ubuntu-cloud-init-data.iso.md5sum
            md5sum -c <(echo $(<ubuntu-cloud-init-data.iso.md5sum) ubuntu-cloud-init-data.iso)
            # Expand
            qemu-img resize ${fn} +2G
            cd $CURDIR
            cat templates/qemu-ubuntu.conf >> $TMPTEMPLATE
            echo "," >> $TMPTEMPLATE
            ;;
        qemu-openwrt)
            cd /opt/gns3/images/QEMU
            fn="openwrt-23.05.0-x86-64-generic-ext4-combined.img"
            wget -q https://downloads.openwrt.org/releases/23.05.0/targets/x86/64/openwrt-23.05.0-x86-64-generic-ext4-combined.img.gz -O ${fn}.gz
            gzip -d ${fn}.gz
            rm -f ${fn}.gz
            echo -n "8d53c7aa2605a8848b0b2ca759fc924f" > ${fn}.md5sum
            md5sum -c <(echo $(<${fn}.md5sum) ${fn})
            cd $CURDIR
            cat templates/qemu-openwrt.conf >> $TMPTEMPLATE
            echo "," >> $TMPTEMPLATE
            ;;
        qemu-opnsense)
            cd /opt/gns3/images/QEMU
            fn="OPNsense-24.1-nano-amd64.img"
            wget -q https://opnsense.c0urier.net/releases/24.1/OPNsense-24.1-nano-amd64.img.bz2 -O ${fn}.bz2
            bzip2 -d ${fn}.bz2
            rm -f ${fn}.bz2
            echo -n "ea8472df2c272419b7834cddaf68048d" > ${fn}.md5sum
            md5sum -c <(echo $(<${fn}.md5sum) ${fn})
            cd $CURDIR
            cat templates/qemu-opnsense.conf >> $TMPTEMPLATE
            echo "," >> $TMPTEMPLATE
            ;;
        qemu-frr)
            cd /opt/gns3/images/QEMU
            fn="frr-8.2.2.qcow2"
            wget -q http://downloads.sourceforge.net/project/gns-3/Qemu%20Appliances/frr-8.2.2.qcow2 -O ${fn}
            echo -n "45cda6b991a1b9e8205a3a0ecc953640" > ${fn}.md5sum
            md5sum -c <(echo $(<${fn}.md5sum) ${fn})
            cd $CURDIR
            cat templates/qemu-frr.conf >> $TMPTEMPLATE
            echo "," >> $TMPTEMPLATE
            ;;
        qemu-reactos)
            cd /opt/gns3/images/QEMU
            fn="ReactOS-0.4.14-release-21-g1302c1b-Live.iso"
            wget -q https://sourceforge.net/projects/reactos/files/ReactOS/0.4.14/ReactOS-0.4.14-release-21-g1302c1b-live.zip/download -O ${fn}.zip
            unzip -o ${fn}.zip
            rm -f ${fn}.zip
            echo -n "fc362820069adeea088b3a48dcfa3f9e" > ${fn}.md5sum
            md5sum -c <(echo $(<${fn}.md5sum) ${fn})
            # Empty disk
            fn="empty30G.qcow2"
            wget -q https://sourceforge.net/projects/gns-3/files/Empty%20Qemu%20disk/empty30G.qcow2/download -O ${fn}
            echo -n "3411a599e822f2ac6be560a26405821a" > ${fn}.md5sum
            md5sum -c <(echo $(<${fn}.md5sum) ${fn})
            cd $CURDIR
            cat templates/qemu-reactos.conf >> $TMPTEMPLATE
            echo "," >> $TMPTEMPLATE
            ;;
        qemu-ubuntu-mac)
            cd /opt/gns3/images/QEMU
            fn="ubuntu-24.04-server-cloudimg-arm64.img"
            wget -q http://cloud-images-archive.ubuntu.com/releases/noble/release-20241004/ubuntu-24.04-server-cloudimg-arm64.img -O ${fn}
            # Cloud init data
            wget -q https://github.com/GNS3/gns3-registry/raw/master/cloud-init/ubuntu-cloud/ubuntu-cloud-init-data.iso -O ubuntu-cloud-init-data.iso
            echo -n "9a90ee8f88736204c756015b3cd86500" > ubuntu-cloud-init-data.iso.md5sum
            md5sum -c <(echo $(<ubuntu-cloud-init-data.iso.md5sum) ubuntu-cloud-init-data.iso)
            # Expand
            qemu-img resize ${fn} +2G
            cd $CURDIR
            cat templates/qemu-ubuntu-mac.conf >> $TMPTEMPLATE
            echo "," >> $TMPTEMPLATE
            ;;
        qemu-opnsense-mac)
            cd /opt/gns3/images/QEMU
            fn="OPNsense-24.1-ufs-efi-vm-aarch64.qcow2"
            wget -q https://github.com/maurice-w/opnsense-vm-images/releases/download/24.1/OPNsense-24.1-ufs-efi-vm-aarch64.qcow2.bz2 -O ${fn}.bz2
            bzip2 -d ${fn}.bz2
            cd $CURDIR
            cat templates/qemu-opnsense-mac.conf >> $TMPTEMPLATE
            echo "," >> $TMPTEMPLATE
            ;; 
        qemu-openwrt-mac)
            cd /opt/gns3/images/QEMU
            fn="openwrt-23.05.0-armsr-armv8-generic-ext4-combined.img"
            wget -q https://archive.openwrt.org/releases/23.05.0/targets/armsr/armv8/openwrt-23.05.0-armsr-armv8-generic-ext4-combined.img.gz -O ${fn}.gz
            gzip -d ${fn}.gz
            cd $CURDIR
            cat templates/qemu-openwrt-mac.conf >> $TMPTEMPLATE
            echo "," >> $TMPTEMPLATE
            ;;
        *)
            echo "Warning: No commands defined for '$value'"
            ;;
    esac
    
done < "$NODEFILE"

echo "Done processing all nodes."

# Stop GNS3 server
sudo systemctl stop gns3
# Remove the last line which is a comma
cp $TMPTEMPLATE /home/gns3/tmptemplate1.conf
TMPTEMPLATE2=`mktemp`
# TODO: currently assumes .conf have empty last line - this should be improved
# Remove last line that has a comma
head -n -1 $TMPTEMPLATE > $TMPTEMPLATE2

# Add tail
cat template_gns3_controller-tail.conf >> $TMPTEMPLATE2
rm -f $TMPTEMPLATE
# Copy the config
cp $TMPTEMPLATE2 /home/gns3/.config/GNS3/2.2/gns3_controller.conf
cp $TMPTEMPLATE2 /home/gns3/tmptemplate2.conf
rm -f $TMPTEMPLATE2
# Start the GNS3 server
sudo systemctl start gns3

# Cleanup
sudo apt -y clean

# Show results
echo "Installed Docker images:" 
docker image ls
echo "Installed QEMU images:"
ls -l /opt/gns3/images/QEMU/*.{img,qcow2,iso} 
