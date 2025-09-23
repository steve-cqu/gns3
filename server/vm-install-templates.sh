#!/bin/bash
# Copy the templates for nodes installed manually (rather than through GNS3 GUI)
# Requires that the GNS3 server is stopped before copying
# Usage: ./vm-install-templates.sh <template-set>
# <template-set> can be "all" (default), "docker" or "qemu"

TEMPLATESET="all"
if [ "$1" == "docker" ]; then
  TEMPLATESET="docker"
elif [ "$1" == "qemu" ]; then
  TEMPLATESET="qemu"
fi

# Working dir
#cd /home/gns3

# Stop the GNS3 server
#sudo systemctl stop gns3

TMPCONFIG=`mktemp`
cp template_gns3_controller.conf $TMPCONFIG

# Docker templates
if [ "$TEMPLATESET" == "all" ] || [ "$TEMPLATESET" == "docker" ]; then
    PLACEHOLDER="DOCKERTEMPLATES"
    INSERT_FILE="templates_containers.conf"
    awk -v insert="$(<"$INSERT_FILE")" -v keyword="$PLACEHOLDER" '
    {
    gsub(keyword, insert)
    print
    }
    ' "$TMPCONFIG"
fi

# Insert comma if both templates used
if [ "$TEMPLATESET" == "all" ]; then
    sed -i 's/INSERTCOMMAIFBOTH/,/' $TMPCONFIG
else
    sed -i 's/INSERTCOMMAIFBOTH//' $TMPCONFIG
fi

# Qemu templates
if [ "$TEMPLATESET" == "all" ] || [ "$TEMPLATESET" == "qemu" ]; then
    PLACEHOLDER="QEMUTEMPLATES"
    INSERT_FILE="templates_qemuvms.conf"
    awk -v insert="$(<"$INSERT_FILE")" -v keyword="$PLACEHOLDER" '
    {
    gsub(keyword, insert)
    print
    }
    ' "$TMPCONFIG"
fi


cat $TMPCONFIG
rm -f $TMPCONFIG

# Start the GNS3 server
#sudo systemctl start gns3