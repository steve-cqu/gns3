# Lab Router: FRR with an IOS-style command line in front, for introductory labs that copy a bench
# with a small Cisco router such as the C921. FRR routes; ios-cli.py accepts the IOS commands
# students use (enable, configure terminal, interface GigabitEthernet 4, ip address <addr> <mask>,
# no shutdown, show interfaces, show ip route, ping) and prints IOS-style output.
# Design: gns3-dev notes/powershell-pc-node.md (Phase 2).
#
# Its own image, FROM frrnode, because the front end needs Python and frrnode has none.
# Template: ../../templates/docker-labrouter.conf ("Lab Router"). NOT YET in manifest.yml: built by
# hand as cqugns3/labrouter-spike. Tests (not shipped): tests/ios-cli.selftest.sh.
FROM cqugns3/frrnode

RUN apt-get update && apt-get install -y --no-install-recommends python3 \
 && rm -rf /var/lib/apt/lists/*

COPY ios-cli.py /usr/local/bin/ios-cli
COPY start-labrouter /usr/local/bin/start-labrouter
COPY devlog-sink /usr/local/bin/devlog-sink
RUN chmod +x /usr/local/bin/ios-cli /usr/local/bin/start-labrouter /usr/local/bin/devlog-sink

CMD ["/usr/local/bin/start-labrouter"]
