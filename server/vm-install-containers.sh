#!/bin/bash
# Install Docker containers manually (rather than through GNS3 GUI)
# This normally wil lbe run on a fresh GNS3 VM that has not had any nodes/projects created yet
# Usage: ./vm-install-containers.sh <ostype>

OSTYPE=$1

mkdir -p /home/gns3/docker
cd /home/gns3/docker

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
wget https://raw.githubusercontent.com/steve-cqu/gns3/refs/heads/main/server/docker/ansible/Dockerfile
wget https://raw.githubusercontent.com/GNS3/gns3-registry/refs/heads/master/docker/endhost/start-ssh.sh
docker build --platform $PLATFORM -t $USERNAME/$DOCKERNAME  .
cd ..

DOCKERNAME="vpnrouter"
mkdir $DOCKERNAME 
cd $DOCKERNAME 
wget https://raw.githubusercontent.com/steve-cqu/gns3/refs/heads/main/server/docker/vpnrouter/Dockerfile
wget https://raw.githubusercontent.com/steve-cqu/gns3/refs/heads/main/server/docker/vpnrouter/99-tailscale.conf
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

cd ..

# Show summary
docker image ls
