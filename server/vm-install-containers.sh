#!/bin/bash
# Install Docker containers manually (rather than through GNS3 GUI)
# Useful for MacOS

mkdir -p /home/gns3/docker
cd /home/gns3/docker

# Set platform:
#  - Apple Mac: linux/arm64/v8
#  - Windows/Linux: linux/amd64
PLATFORM="linux/arm64/v8" 
#PLATFORM="linux/amd64"

# Set username, e.g. gns3
USERNAME="gns3"

DOCKERNAME="endhost"
mkdir $DOCKERNAME 
cd $DOCKERNAME 
wget https://raw.githubusercontent.com/GNS3/gns3-registry/refs/heads/master/docker/endhost/Dockerfile
wget https://raw.githubusercontent.com/GNS3/gns3-registry/refs/heads/master/docker/endhost/start-ssh.sh
docker build --platform $PLATFORM -t $USERNAME/$DOCKERNAME  .
cd ..

DOCKERNAME="openvswitch"
mkdir $DOCKERNAME 
cd $DOCKERNAME 
wget https://raw.githubusercontent.com/GNS3/gns3-registry/refs/heads/master/docker/openvswitch/Dockerfile
wget https://raw.githubusercontent.com/GNS3/gns3-registry/refs/heads/master/docker/openvswitch/init.sh
docker build --platform $PLATFORM -t $USERNAME/$DOCKERNAME  .
cd ..

DOCKERNAME="ipterm-base"
mkdir $DOCKERNAME 
cd $DOCKERNAME 
wget https://raw.githubusercontent.com/GNS3/gns3-registry/refs/heads/master/docker/ipterm/base/Dockerfile
docker build --platform $PLATFORM -t $USERNAME/$DOCKERNAME  .
cd ..

DOCKERNAME="ipterm"
mkdir $DOCKERNAME 
cd $DOCKERNAME 
wget https://raw.githubusercontent.com/GNS3/gns3-registry/refs/heads/master/docker/ipterm/cli/Dockerfile
docker build --platform $PLATFORM --build-arg DOCKER_REPOSITORY=$USERNAME -t $USERNAME/$DOCKERNAME  .
cd ..

DOCKERNAME="webterm"
mkdir $DOCKERNAME 
cd $DOCKERNAME 
wget https://raw.githubusercontent.com/GNS3/gns3-registry/refs/heads/master/docker/ipterm/web/Dockerfile
docker build --platform $PLATFORM --build-arg DOCKER_REPOSITORY=$USERNAME -t $USERNAME/$DOCKERNAME  .
cd ..

USERNAME="cqugns3" # User name 
DOCKERNAME="ansible"
mkdir $DOCKERNAME 
cd $DOCKERNAME 
wget https://raw.githubusercontent.com/steve-cqu/networking/refs/heads/main/data/docker/cqugns3/ansible/Dockerfile
wget https://raw.githubusercontent.com/GNS3/gns3-registry/refs/heads/master/docker/endhost/start-ssh.sh
docker build --platform $PLATFORM -t $USERNAME/$DOCKERNAME  .
cd ..

DOCKERNAME="vpnrouter"
mkdir $DOCKERNAME 
cd $DOCKERNAME 
wget https://raw.githubusercontent.com/steve-cqu/networking/refs/heads/main/data/docker/cqugns3/vpnrouter/Dockerfile
wget https://raw.githubusercontent.com/steve-cqu/networking/refs/heads/main/data/docker/cqugns3/vpnrouter/99-tailscale.conf
wget https://raw.githubusercontent.com/GNS3/gns3-registry/refs/heads/master/docker/endhost/start-ssh.sh
docker build --platform $PLATFORM -t $USERNAME/$DOCKERNAME  .
cd ..

USERNAME="adosztal" # User name 
DOCKERNAME="net_toolbox"
mkdir $DOCKERNAME 
cd $DOCKERNAME 
wget https://raw.githubusercontent.com/adosztal/gns3-containers/refs/heads/master/net_toolbox/Dockerfile
docker build --platform $PLATFORM -t $USERNAME/$DOCKERNAME  .
cd ..


# Copy templates
cd ..
#cp /home/gns3/.config/GNS3/2.2/gns3_controller.conf ./original_gns_controller.conf
#cp template_gns3_controller.conf /home/gns3/.config/GNS3/2.2/gns3_controller.conf

# Show summary
docker image ls
