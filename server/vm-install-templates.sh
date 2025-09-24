#!/bin/bash
# Copy the templates for nodes installed manually (rather than through GNS3 GUI)
# Requires that the GNS3 server is stopped before copying
# Usage: ./vm-install-templates.sh <os-type> <template-set>
# <os-type> can be "mac" (Apple Mac) or "pc" (Windows/Linux)
# <template-set> can be "all" (default), "docker" or "qemu"

OSTYPE=$1

TEMPLATESET="all"
if [ "$2" == "docker" ]; then
  TEMPLATESET="docker"
elif [ "$2" == "qemu" ]; then
  TEMPLATESET="qemu"
fi


# Stop the GNS3 server
sudo systemctl stop gns3

TMPCONFIG=`mktemp`
TMP2CONFIG=`mktemp`
cp template_gns3_controller.conf $TMPCONFIG

# Docker templates
if [ "$TEMPLATESET" == "all" ] || [ "$TEMPLATESET" == "docker" ]; then
    PLACEHOLDER="DOCKERTEMPLATES"
    INSERT_FILE="templates_containers.conf"
    sed -i 's/\r$//' ${INSERT_FILE}
    awk -v insert="$(<"$INSERT_FILE")" -v keyword="$PLACEHOLDER" '
    {
    gsub(keyword, insert)
    print
    }
    ' "$TMPCONFIG" > $TMP2CONFIG
fi
cp $TMP2CONFIG $TMPCONFIG

# Insert comma if both templates used
if [ "$TEMPLATESET" == "all" ]; then
    sed -i 's/INSERTCOMMAIFBOTH/,/' $TMPCONFIG
else
    sed -i 's/INSERTCOMMAIFBOTH//' $TMPCONFIG
fi

# Qemu templates
if [ "$TEMPLATESET" == "all" ] || [ "$TEMPLATESET" == "qemu" ]; then
    PLACEHOLDER="QEMUTEMPLATES"
    if [ "$OSTYPE" == "mac" ]; then
      INSERT_FILE="templates_qemuvms_mac.conf"
    else
      INSERT_FILE="templates_qemuvms.conf"
    fi
    sed -i 's/\r$//' ${INSERT_FILE}
    awk -v insert="$(<"$INSERT_FILE")" -v keyword="$PLACEHOLDER" '
    {
    gsub(keyword, insert)
    print
    }
    ' "$TMPCONFIG" > $TMP2CONFIG
fi
cp $TMP2CONFIG $TMPCONFIG

sed -i 's/DOCKERTEMPLATES//' ${TMPCONFIG}
sed -i 's/QEMUTEMPLATES//' ${TMPCONFIG}
sed -i 's/INSERTCOMMAIFBOTH//' $TMPCONFIG

cp $TMPCONFIG /home/gns3/.config/GNS3/2.2/gns3_controller.conf

rm -f $TMPCONFIG $TMP2CONFIG

# Start the GNS3 server
sudo systemctl start gns3