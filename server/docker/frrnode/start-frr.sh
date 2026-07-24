#!/bin/bash
# Start the FRR daemons then open the router CLI on the GNS3 console.
# This mirrors the FRR Qemu VM the activities were written against: the console
# boots straight into the vtysh 'frr#' prompt. Type 'exit' to drop to the
# underlying Linux shell, and 'vtysh' from there to return to the CLI.

# FRR is a router: enable packet forwarding
sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null

/usr/lib/frr/frrinit.sh start

# Boot into vtysh like the Qemu FRR VM. Exiting vtysh lands in an interactive
# shell (for editing /etc/network/interfaces, /etc/frr/daemons, etc.); running
# 'vtysh' there re-enters the CLI.
exec bash -c 'vtysh; exec bash'
