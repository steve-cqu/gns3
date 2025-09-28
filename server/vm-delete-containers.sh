#!/bin/bash
# Delete Docker containers manually

rm -f /home/gns3/docker/openvswitch/*
rm -f /home/gns3/docker/ipterm-base/*
rm -f /home/gns3/docker/ipterm/*
rm -f /home/gns3/docker/webterm/*
rm -f /home/gns3/docker/alpinenode/*
rm -f /home/gns3/docker/net_toolbox/*

docker rmi --force gns3/openvswitch:latest
docker rmi --force gns3/ipterm-base:latest
docker rmi --force gns3/ipterm:latest
docker rmi --force gns3/webterm:latest
docker rmi --force cqugns3/alpinenode:latest
docker rmi --force adosztal/net_toolbox:latest