#!/bin/bash
# Delete Docker containers manually

docker rmi gns3/endhost:latest
docker rmi gns3/openvswitch:latest
docker rmi gns3/ipterm-base:latest
docker rmi gns3/ipterm:latest
docker rmi gns3/webterm:latest
docker rmi cqugns3/ansible:latest
docker rmi cqugns3/vpnrouter:latest
docker rmi adosztal/net_toolbox:latest