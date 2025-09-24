# Install QEMU VMs in GNS3 VM

OSTYPE=$1

CURDIR=`pwd`

cd /opt/gns3/images/QEMU

# Set platform:
#  - Apple Mac: linux/arm64/v8
#  - Windows/Linux: linux/amd64
if [ "$OSTYPE" == "mac" ]; then
  echo "Apple Mac detected"
else
    echo "Windows/Linux detected"

    # NETem
    fn="NETem-v4.qcow2"
    wget -q https://sourceforge.net/projects/gns-3/files/Qemu%20Appliances/NETem-v4.qcow2/download -O ${fn}
    echo -n "e678698c97804901c7a53f6b68c8b861" > ${fn}.md5sum
    md5sum -c <(echo $(<${fn}.md5sum) ${fn})
 
    # Alpine
    #fn="alpine-virt-3.18.4.qcow2"
    #wget -q https://sourceforge.net/projects/gns-3/files/Qemu%20Appliances/alpine-virt-3.18.4.qcow2/download -O ${fn}
    #echo -n "99d393c16c870e12c4215aadd82ca998" > ${fn}$.md5sum
    #md5sum -c <(echo $(<${fn}.md5sum) ${fn})

    # Ubuntu
    fn="ubuntu-24.04-server-cloudimg-amd64.img"
    wget -q https://cloud-images.ubuntu.com/releases/noble/release-20241004/ubuntu-24.04-server-cloudimg-amd64.img -O ${fn}
    echo -n "a1c8a01953578ad432cbef03db2f3161" > ${fn}.md5sum
    md5sum -c <(echo $(<${fn}.md5sum) ${fn})
    # Expand
    qemu-img resize ${fn} +2G

    # OpenWRT
    fn="openwrt-23.05.0-x86-64-generic-ext4-combined.img"
    wget -q https://downloads.openwrt.org/releases/23.05.0/targets/x86/64/openwrt-23.05.0-x86-64-generic-ext4-combined.img.gz -O ${fn}.gz
    echo -n "8d53c7aa2605a8848b0b2ca759fc924f" > ${fn}.md5sum
    gzip -d ${fn}.gz
    md5sum -c <(echo $(<${fn}.md5sum) ${fn})

    # OPNSense
    fn="OPNsense-24.1-nano-amd64.img"
    wget -q https://opnsense.c0urier.net/releases/24.1/OPNsense-24.1-nano-amd64.img.bz2 -O ${fn}.bz2
    echo -n "ea8472df2c272419b7834cddaf68048d" > ${fn}.md5sum
    bzip2 -d ${fn}.bz2
    md5sum -c <(echo $(<${fn}.md5sum) ${fn})

fi

cd $CURDIR