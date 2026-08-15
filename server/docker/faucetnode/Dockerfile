# SDN controller node: Faucet.
#
# WHY THIS EXISTS. sdn-basics' controller was an Ubuntu cloud image in a Qemu VM, which cost
# three separate things: the ubuntu-cloud Qemu disk in both OVAs (~600 MB each), a 729 MB
# SDN-Basics-Template.gns3project that could not be committed or put on Moodle and had to be
# hosted beside the OVA, and — because a .gns3project bakes in each Qemu node's emulator and
# disk — a project permanently bound to the architecture it was exported on. An all-Docker
# topology removes all three. See gns3-dev/notes/arm64-project-rebuilds.md §3.
#
# Faucet does not need a VM. It is a userland OpenFlow controller: a Python process that reads
# a YAML file, listens on TCP 6653 and exports Prometheus metrics on 9302. It has no dataplane,
# needs no privileges and touches no kernel networking — all the switching happens on the Open
# vSwitch node, which reaches the controller over TCP. That is a softer case than frrnode and
# netemnode, which really do drive the kernel and moved to Docker successfully.
FROM cqugns3/alpinenode

# Pinned deliberately. Faucet is not packaged by Alpine or by Ubuntu at any version, so every
# route to it is third-party: PyPI, the vendor's packagecloud apt repository, or the vendor's
# own Docker image. PyPI was chosen because it is the one that keeps this node on the same
# Alpine base as every other CQU service node (servicenode, monitornode, ipv6node), and because
# it adds no third-party apt repository and GPG key to the image — the objection that decided
# D1 against a Grafana-on-Ubuntu node in tier1-service-nodes-plan.md.
#
# packagecloud remains the documented fallback and is known to work: faucetsdn/faucet publishes
# 1.10.12 for noble as Architecture: all, and it is listed in the arm64 index (checked
# 15 August 2026). If PyPI ever becomes the harder path, that is the route to switch to.
ARG FAUCET_VERSION=1.10.12

# Installed into a venv, NOT into the system python. alpinenode ships ansible, which uses the
# system site-packages, and Alpine 3.24's python3 is marked EXTERNALLY-MANAGED (PEP 668) so a
# plain `pip install` would need --break-system-packages and could move ansible's dependencies
# underneath it. /opt/faucet keeps the two apart completely.
#
# pytricia is a C extension and publishes no musl wheel, so a compiler is needed to install it
# and is not needed afterwards. The toolchain goes in as a virtual package and comes back out in
# the same layer; libstdc++ stays, because the compiled extension links against it. The import
# check at the end of the layer is what proves the purge did not take a runtime dependency with
# it — it fails the build here rather than at the first console a student opens.
RUN apk add --no-cache libstdc++ \
 && apk add --no-cache --virtual .faucet-build build-base python3-dev py3-pip linux-headers \
 && python3 -m venv /opt/faucet \
 && /opt/faucet/bin/pip install --no-cache-dir --quiet "faucet==${FAUCET_VERSION}" \
 && apk del .faucet-build \
 && /opt/faucet/bin/python -c "import faucet, pytricia, os_ken; print('faucet', faucet.__file__)"

# Faucet's own defaults, made explicit so the node behaves the same however it is started and so
# the paths in the activity are the paths in the image. FAUCET_PROMETHEUS_PORT is what the
# Monitor node scrapes.
#
# PATH APPENDS the venv, it does not prepend it. /opt/faucet/bin contains `python`, `python3`
# and `pip`, so putting it first would shadow the system python for everything else on the node
# — including the ansible that alpinenode installs, which imports from the system
# site-packages the venv does not have. Appended, the unique names (faucet, gauge,
# check_faucet_config) still resolve by bare name and nothing else moves.
ENV FAUCET_CONFIG=/etc/faucet/faucet.yaml \
    FAUCET_LOG=/var/log/faucet/faucet.log \
    FAUCET_EXCEPTION_LOG=/var/log/faucet/faucet_exception.log \
    FAUCET_PROMETHEUS_PORT=9302 \
    FAUCET_PROMETHEUS_ADDR=0.0.0.0 \
    PATH=$PATH:/opt/faucet/bin

# Shipped configuration. faucet.yaml is valid as it stands and puts all four access ports in one
# VLAN, so the controller answers a switch with no student edits at all — the same standard as
# servicenode's named.conf and the empty custom.rules that makes `suricata -T` pass. The two
# example configurations are the ones the activity has students deploy; they are IN THE IMAGE
# rather than fetched with wget from raw.githubusercontent.com, which is what the activity does
# today and which needs working internet in a lab that otherwise does not.
RUN mkdir -p /etc/faucet/examples /var/log/faucet
COPY faucet.yaml                 /etc/faucet/faucet.yaml
COPY faucet-2hosts-1vlan.yaml    /etc/faucet/examples/faucet-2hosts-1vlan.yaml
COPY faucet-4hosts-2vlan.yaml    /etc/faucet/examples/faucet-4hosts-2vlan.yaml

# Helper scripts live in /usr/local/bin, not /bin, so a student's edit survives the project being
# closed: /usr/local/bin can be persisted, /bin cannot without pinning the whole userland, and it
# precedes /bin in PATH so they still run by bare name. The ipv6node lesson.
COPY start-faucet.sh    /usr/local/bin/start-faucet.sh
COPY faucet-status.sh   /usr/local/bin/faucet-status.sh

# check_faucet_config, deliberately shadowing the venv's own copy of that name — /usr/local/bin
# comes before /opt/faucet/bin in PATH above, and this is the reason the venv is appended rather
# than prepended.
#
# It exists for one reason: os_ken imports eventlet, and eventlet 0.40 prints a nine-line
# deprecation banner to stderr on every import. `check_faucet_config` is the command students
# are told to run after every edit, so without this they read that banner more often than they
# read their own error, and every solution transcript has to carry it. The wrapper passes all
# arguments and the exit code straight through and changes nothing else.
COPY check_faucet_config /usr/local/bin/check_faucet_config
RUN chmod +x /usr/local/bin/start-faucet.sh /usr/local/bin/faucet-status.sh \
             /usr/local/bin/check_faucet_config

# Declared here as well as in the template's extra_volumes, so a node keeps the student's
# controller configuration and its logs even under a template someone registered by hand.
VOLUME /etc/faucet /var/log/faucet
