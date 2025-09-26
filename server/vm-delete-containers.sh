#!/bin/bash
# Delete Docker containers manually

docker rmi --force gns3/endhost:latest
docker rmi --force gns3/openvswitch:latest
docker rmi --force gns3/ipterm-base:latest
docker rmi --force gns3/ipterm:latest
docker rmi --force gns3/webterm:latest
docker rmi --force cqugns3/ansible:latest
docker rmi --force cqugns3/vpnrouter:latest
docker rmi --force adosztal/net_toolbox:latest