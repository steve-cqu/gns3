#!/usr/bin/env python3
"""A small IOS-style command line over FRR, for introductory router labs.

Students meet a router through a few IOS commands (enable, configure terminal, interface,
ip address <addr> <mask>, no shutdown, show interfaces, show ip route, ping). FRR's vtysh is close
but not the same: it wants /24 rather than a dotted mask, has no plural `show interfaces`, and names
ports eth0... This front end accepts the IOS forms, abbreviations included (`conf t`, `int gi4`,
`sh ip int br`), applies them through vtysh, and prints IOS-style output. FRR does the routing.

Ports: GigabitEthernetN is the Linux interface ethN (eth4 on the GNS3 canvas is GigabitEthernet4).
Like IOS, configuration is lost at a restart unless saved (`copy running-config startup-config` or
`write memory`), which calls FRR's `write memory`.

Output layouts other than `show interfaces` are written from knowledge of IOS 15, not copied from a
lab capture; see gns3-dev notes/powershell-pc-node.md.
"""
import ipaddress
import json
import os
import re
import readline
import socket
import subprocess
import sys
import time

MAX_PORTS = 6
GI = "GigabitEthernet"


# --- system access -------------------------------------------------------------------------------

def sh(args, timeout=30):
    p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout + p.stderr


def vtysh(*cmds):
    args = ["vtysh"]
    for c in cmds:
        args += ["-c", c]
    return sh(args)


def ipj(*args):
    rc, out = sh(["ip", "-json", *args])
    try:
        return json.loads(out) if rc == 0 and out.strip() else []
    except json.JSONDecodeError:
        return []


# The hostname is kept here, not in FRR: `vtysh -c 'hostname X'` only renames that one vtysh process
# (measured 8 Nov 2026). Running value in /run (gone at restart, like an unsaved IOS change); saved
# value in /etc/frr (persisted), written by copy running-config startup-config / write memory.
RUN_HOSTNAME = "/run/ios-hostname"
SAVED_HOSTNAME = "/etc/frr/ios-hostname"


def hostname():
    for f in (RUN_HOSTNAME, SAVED_HOSTNAME):
        try:
            h = open(f).read().strip()
            if h:
                return h
        except OSError:
            pass
    return socket.gethostname()


def set_hostname(name):
    with open(RUN_HOSTNAME, "w") as f:
        f.write(name + "\n")


def save_hostname():
    try:
        with open(SAVED_HOSTNAME, "w") as f:
            f.write(hostname() + "\n")
    except OSError:
        pass


def ports():
    """eth0..eth5 that exist, as (number, linux name)."""
    have = {l["ifname"] for l in ipj("link", "show")}
    return [(n, f"eth{n}") for n in range(MAX_PORTS) if f"eth{n}" in have]


def frr_config():
    rc, out = vtysh("show running-config")
    return out


def iface_state(dev):
    link = next((l for l in ipj("link", "show", "dev", dev)), None)
    if not link:
        return None
    flags = link.get("flags", [])
    admin_up = "UP" in flags
    lower = "LOWER_UP" in flags
    addrs = [a for a in next((i for i in ipj("addr", "show", "dev", dev)), {}).get("addr_info", [])
             if a.get("family") == "inet"]
    return {"admin_up": admin_up, "line_up": admin_up and lower, "mac": link.get("address", ""),
            "mtu": link.get("mtu", 1500), "addrs": addrs}


def stats(dev):
    base = f"/sys/class/net/{dev}/statistics/"
    out = {}
    for k in ("rx_packets", "rx_bytes", "tx_packets", "tx_bytes", "rx_errors", "tx_errors", "multicast",
              "rx_dropped", "tx_dropped", "collisions"):
        try:
            out[k] = int(open(base + k).read())
        except OSError:
            out[k] = 0
    return out


def cisco_mac(mac):
    h = mac.replace(":", "").lower()
    return ".".join(h[i:i + 4] for i in range(0, 12, 4)) if len(h) == 12 else mac


def mask_of(plen):
    return str(ipaddress.IPv4Network(f"0.0.0.0/{plen}").netmask)


# --- parsing helpers -----------------------------------------------------------------------------

class CliError(Exception):
    """An IOS-style error; pos is the index of the offending character in the typed line."""
    def __init__(self, kind, pos=0, text=""):
        super().__init__(kind)
        self.kind, self.pos, self.text = kind, pos, text


def match_kw(token, choices):
    """IOS prefix matching: exact match wins, else a unique prefix."""
    t = token.lower()
    if t in choices:
        return t
    hits = [c for c in choices if c.startswith(t)]
    if len(hits) == 1:
        return hits[0]
    if not hits:
        return None
    return hits  # ambiguous


PORT_RE = re.compile(r"^(g(?:i(?:g(?:a(?:b(?:i(?:t(?:e(?:t(?:h(?:e(?:r(?:n(?:e(?:t)?)?)?)?)?)?)?)?)?)?)?)?)?)?|eth)(\d+)?$", re.I)


def parse_port(tokens, i):
    """Read an interface name from tokens[i:] ('gi4', 'Gi 4', 'GigabitEthernet4', 'eth4').
    Returns (number, next index) or raises CliError."""
    if i >= len(tokens):
        raise CliError("incomplete")
    m = PORT_RE.match(tokens[i])
    if not m:
        raise CliError("invalid", i)
    num = m.group(2)
    nxt = i + 1
    if num is None:
        if nxt < len(tokens) and tokens[nxt].isdigit():
            num, nxt = tokens[nxt], nxt + 1
        else:
            raise CliError("incomplete")
    n = int(num)
    if n >= MAX_PORTS or not os.path.exists(f"/sys/class/net/eth{n}"):
        raise CliError("invalid", i)
    return n, nxt


def parse_ipv4(tok, i):
    try:
        return ipaddress.IPv4Address(tok)
    except ValueError:
        raise CliError("invalid", i)


def parse_mask(tok, i):
    try:
        return ipaddress.IPv4Network(f"0.0.0.0/{tok}").prefixlen
    except ValueError:
        raise CliError("invalid", i)


# --- show commands -------------------------------------------------------------------------------

def show_interfaces(only=None):
    out = []
    for n, dev in ports():
        if only is not None and n != only:
            continue
        st = iface_state(dev)
        s = stats(dev)
        name = f"{GI}{n}"
        if not st["admin_up"]:
            out.append(f"{name} is administratively down, line protocol is down")
        else:
            out.append(f"{name} is {'up' if st['line_up'] else 'down'}, line protocol is {'up' if st['line_up'] else 'down'}")
        mac = cisco_mac(st["mac"])
        out.append(f"  Hardware is iGbE, address is {mac} (bia {mac})")
        for a in st["addrs"][:1]:
            out.append(f"  Internet address is {a['local']}/{a['prefixlen']}")
        out += [
            f"  MTU {st['mtu']} bytes, BW 1000000 Kbit/sec, DLY 10 usec,",
            "     reliability 255/255, txload 1/255, rxload 1/255",
            "  Encapsulation ARPA, loopback not set",
            "  Keepalive set (10 sec)",
            "  Full Duplex, 1Gbps, media type is RJ45",
            "  output flow-control is unsupported, input flow-control is unsupported",
            "  ARP type: ARPA, ARP Timeout 04:00:00",
            "  Last input 00:00:00, output 00:00:00, output hang never",
            '  Last clearing of "show interface" counters never',
            "  Input queue: 0/75/0/0 (size/max/drops/flushes); Total output drops: 0",
            "  Queueing strategy: fifo",
            "  Output queue: 0/40 (size/max)",
            "  5 minute input rate 0 bits/sec, 0 packets/sec",
            "  5 minute output rate 0 bits/sec, 0 packets/sec",
            f"     {s['rx_packets']} packets input, {s['rx_bytes']} bytes, 0 no buffer",
            f"     Received {s['multicast']} broadcasts (0 IP multicasts)",
            "     0 runts, 0 giants, 0 throttles",
            f"     {s['rx_errors']} input errors, 0 CRC, 0 frame, 0 overrun, 0 ignored",
            "     0 watchdog, 0 multicast, 0 pause input",
            f"     {s['tx_packets']} packets output, {s['tx_bytes']} bytes, 0 underruns",
            f"     {s['tx_errors']} output errors, {s['collisions']} collisions, 0 interface resets",
            "     0 unknown protocol drops",
            "     0 babbles, 0 late collision, 0 deferred",
            "     0 lost carrier, 0 no carrier, 0 pause output",
            "     0 output buffer failures, 0 output buffers swapped out",
        ]
    return out


def show_ip_int_brief():
    out = [f"{'Interface':<23}{'IP-Address':<16}OK? Method Status                Protocol"]
    for n, dev in ports():
        st = iface_state(dev)
        ip = st["addrs"][0]["local"] if st["addrs"] else "unassigned"
        method = "manual" if st["addrs"] else "unset"
        status = "administratively down" if not st["admin_up"] else ("up" if st["line_up"] else "down")
        proto = "up" if st["line_up"] else "down"
        out.append(f"{GI + str(n):<23}{ip:<16}YES {method:<7}{status:<22}{proto}")
    return out


def classful(addr):
    first = int(str(addr).split(".")[0])
    plen = 8 if first < 128 else 16 if first < 192 else 24
    return ipaddress.IPv4Network(f"{addr}/{plen}", strict=False)


def static_routes():
    """[(network, nexthop or None, port or None)] from FRR's running config."""
    res = []
    for m in re.finditer(r"^ip route (\S+) (\S+)", frr_config(), re.M):
        net = ipaddress.IPv4Network(m.group(1))
        hop = m.group(2)
        if hop.startswith("eth"):
            res.append((net, None, int(hop[3:])))
        else:
            res.append((net, ipaddress.IPv4Address(hop), None))
    return res


def show_ip_route():
    out = [
        "Codes: L - local, C - connected, S - static, R - RIP, M - mobile, B - BGP",
        "       D - EIGRP, EX - EIGRP external, O - OSPF, IA - OSPF inter area ",
        "       N1 - OSPF NSSA external type 1, N2 - OSPF NSSA external type 2",
        "       E1 - OSPF external type 1, E2 - OSPF external type 2",
        "       i - IS-IS, su - IS-IS summary, L1 - IS-IS level-1, L2 - IS-IS level-2",
        "       ia - IS-IS inter area, * - candidate default, U - per-user static route",
        "       o - ODR, P - periodic downloaded static route, H - NHRP, l - LISP",
        "       + - replicated route, % - next hop override",
        "",
    ]
    entries = []  # (network, code, text-after-prefix)
    for n, dev in ports():
        st = iface_state(dev)
        if not st["line_up"]:
            continue
        for a in st["addrs"]:
            net = ipaddress.IPv4Network(f"{a['local']}/{a['prefixlen']}", strict=False)
            entries.append((net, "C", f"is directly connected, {GI}{n}"))
            entries.append((ipaddress.IPv4Network(f"{a['local']}/32"), "L", f"is directly connected, {GI}{n}"))
    default = None
    for net, hop, port in static_routes():
        via = f"via {hop}" if hop else f"is directly connected, {GI}{port}"
        text = f"[1/0] {via}" if hop else via
        if net.prefixlen == 0:
            default = (net, hop)
            entries.append((net, "S*", text))
        else:
            entries.append((net, "S", text))
    if default and default[1]:
        out.append(f"Gateway of last resort is {default[1]} to network 0.0.0.0")
    else:
        out.append("Gateway of last resort is not set")
    out.append("")
    groups = {}
    for net, code, text in entries:
        key = classful(net.network_address) if net.prefixlen else net
        groups.setdefault(key, []).append((net, code, text))
    for major in sorted(groups, key=lambda k: (k.network_address, k.prefixlen)):
        items = sorted(groups[major], key=lambda e: (e[0].network_address, e[0].prefixlen))
        if len(items) == 1 and items[0][0] == major:
            net, code, text = items[0]
            out.append(f"{code:<6}{net} {text}")
            continue
        masks = {e[0].prefixlen for e in items}
        if len(masks) == 1:
            out.append(f"      {major.network_address}/{items[0][0].prefixlen} is subnetted, {len(items)} subnets")
            for net, code, text in items:
                out.append(f"{code:<9}{net.network_address} {text}")
        else:
            out.append(f"      {major} is variably subnetted, {len(items)} subnets, {len(masks)} masks")
            for net, code, text in items:
                out.append(f"{code:<9}{net} {text}")
    return out


def show_running_config():
    cfg = frr_config()
    body = ["!", f"hostname {hostname()}", "!"]
    desc = dict(re.findall(r"^interface (eth\d+)\n(?: .*\n)*? description (.*)$", cfg, re.M))
    for n, dev in ports():
        st = iface_state(dev)
        body.append(f"interface {GI}{n}")
        if dev in desc:
            body.append(f" description {desc[dev]}")
        if st["addrs"]:
            for i, a in enumerate(st["addrs"]):
                body.append(f" ip address {a['local']} {mask_of(a['prefixlen'])}{' secondary' if i else ''}")
        else:
            body.append(" no ip address")
        if not st["admin_up"]:
            body.append(" shutdown")
        body.append("!")
    for net, hop, port in static_routes():
        body.append(f"ip route {net.network_address} {net.netmask} {hop if hop else GI + str(port)}")
    body += ["!", "end"]
    text = "\n".join(body)
    return ["Building configuration...", "", f"Current configuration : {len(text)} bytes"] + body


def show_arp():
    out = [f"{'Protocol':<10}{'Address':<17}{'Age (min)':<11}{'Hardware Addr':<16}{'Type':<7}Interface"]
    rows = []
    for n, dev in ports():
        st = iface_state(dev)
        for a in st["addrs"]:
            rows.append((ipaddress.IPv4Address(a["local"]), "-", cisco_mac(st["mac"]), f"{GI}{n}"))
    for e in ipj("-4", "neigh", "show"):
        m = re.match(r"eth(\d+)$", e.get("dev", ""))
        if not m or "lladdr" not in e:
            continue
        rows.append((ipaddress.IPv4Address(e["dst"]), "0", cisco_mac(e["lladdr"]), f"{GI}{m.group(1)}"))
    for ip, age, mac, port in sorted(rows):
        out.append(f"{'Internet':<10}{str(ip):<17}{age:>9}   {mac:<16}{'ARPA':<7}{port}")
    return out


# --- ping / traceroute ---------------------------------------------------------------------------

def ping(target, count=5, size=100):
    out_lines = ["Type escape sequence to abort.",
                 f"Sending {count}, {size}-byte ICMP Echos to {target}, timeout is 2 seconds:"]
    print("\n".join(out_lines))
    marks, rtts = "", []
    for _ in range(count):
        rc, out = sh(["ping", "-n", "-c", "1", "-W", "2", "-s", str(max(size - 28, 0)), target], timeout=5)
        m = re.search(r"time=([\d.]+) ms", out)
        if m:
            marks += "!"
            rtts.append(float(m.group(1)))
        elif "Unreachable" in out:
            marks += "U"
        else:
            marks += "."
        sys.stdout.write(marks[-1])
        sys.stdout.flush()
    print()
    ok = marks.count("!")
    line = f"Success rate is {ok * 100 // count} percent ({ok}/{count})"
    if rtts:
        line += f", round-trip min/avg/max = {int(min(rtts))}/{int(sum(rtts) / len(rtts))}/{int(max(rtts))} ms"
    print(line)


def traceroute(target):
    print("Type escape sequence to abort.")
    print(f"Tracing the route to {target}")
    print("VRF info: (vrf in name/id, vrf out name/id)")
    for ttl in range(1, 31):
        hop, times, done = None, [], False
        for _ in range(3):
            start = time.monotonic()
            rc, out = sh(["ping", "-n", "-c", "1", "-W", "2", "-t", str(ttl), target], timeout=5)
            el = int((time.monotonic() - start) * 1000)
            m = re.search(r"from (\S+?):? icmp_seq=\d+ ttl=\d+ time=([\d.]+) ms", out)
            m2 = re.search(r"From (\S+) icmp_seq=\d+ Time to live exceeded", out)
            if m:
                hop, done = hop or m.group(1), True
                times.append(f"{int(float(m.group(2)))} msec")
            elif m2:
                hop = hop or m2.group(1)
                times.append(f"{min(el, 1)} msec" if el < 2 else f"{el} msec")
            else:
                times.append("*")
        print(f"{ttl:>3} {hop + ' ' if hop else ''}{' '.join(times)}")
        if done:
            break


# --- the command line ----------------------------------------------------------------------------

class Cli:
    def __init__(self):
        self.mode = "user"          # user | priv | config | if
        self.port = None            # interface number in 'if' mode

    def prompt(self):
        h = hostname()
        return {"user": f"{h}>", "priv": f"{h}#", "config": f"{h}(config)#", "if": f"{h}(config-if)#"}[self.mode]

    # -- command tables. Each maps a keyword to a handler(tokens, i) -----------------------------
    def exec_cmds(self):
        c = {"enable": self.c_enable, "exit": self.c_exit, "logout": self.c_exit, "ping": self.c_ping,
             "show": self.c_show, "traceroute": self.c_trace}
        if self.mode == "priv":
            c.update({"configure": self.c_configure, "disable": self.c_disable, "copy": self.c_copy,
                      "write": self.c_write})
        return c

    def config_cmds(self):
        c = {"interface": self.c_interface, "hostname": self.c_hostname, "ip": self.c_ip_route,
             "no": self.c_no_global, "exit": self.c_cfg_exit, "end": self.c_end, "do": self.c_do}
        if self.mode == "if":
            c = {"ip": self.c_if_ip, "no": self.c_if_no, "shutdown": self.c_shutdown,
                 "description": self.c_description, "exit": self.c_cfg_exit, "end": self.c_end,
                 "do": self.c_do, "interface": self.c_interface}
        return c

    def table(self):
        return self.exec_cmds() if self.mode in ("user", "priv") else self.config_cmds()

    # -- dispatch -------------------------------------------------------------------------------
    def run(self, line):
        tokens = line.split()
        if not tokens:
            return
        if tokens[-1].endswith("?"):
            return self.help(tokens)
        table = self.table()
        kw = match_kw(tokens[0], list(table))
        if isinstance(kw, list):
            raise CliError("ambiguous", 0, tokens[0])
        if kw is None:
            if self.mode in ("user", "priv") and len(tokens) == 1:
                raise CliError("unknown")
            raise CliError("invalid", 0)
        table[kw](tokens, 1)

    def help(self, tokens):
        word = tokens[-1][:-1]
        if len(tokens) == 1:
            names = sorted(k for k in self.table() if k.startswith(word.lower()))
            for k in names:
                print(f"  {k}")
            return
        print("  (help is available for the first word only on this simulated router)")

    # -- exec mode ------------------------------------------------------------------------------
    def c_enable(self, t, i):
        self.mode = "priv"

    def c_disable(self, t, i):
        self.mode = "user"

    def c_exit(self, t, i):
        raise EOFError

    def c_configure(self, t, i):
        if i < len(t):
            if match_kw(t[i], ["terminal"]) != "terminal":
                raise CliError("invalid", i)
        print("Enter configuration commands, one per line.  End with CNTL/Z.")
        self.mode = "config"

    def c_copy(self, t, i):
        a = match_kw(t[i], ["running-config"]) if i < len(t) else None
        b = match_kw(t[i + 1], ["startup-config"]) if i + 1 < len(t) else None
        if a != "running-config" or b != "startup-config":
            if i + 1 >= len(t):
                raise CliError("incomplete")
            raise CliError("invalid", i if a != "running-config" else i + 1)
        input("Destination filename [startup-config]? ")
        self.save()

    def c_write(self, t, i):
        if i < len(t) and match_kw(t[i], ["memory"]) != "memory":
            raise CliError("invalid", i)
        self.save()

    def save(self):
        print("Building configuration...")
        rc, out = vtysh("write memory")
        save_hostname()
        print("[OK]" if rc == 0 else f"% Save failed: {out.strip()}")

    def c_ping(self, t, i):
        if i >= len(t):
            raise CliError("incomplete")
        ping(str(parse_ipv4(t[i], i)))

    def c_trace(self, t, i):
        if i >= len(t):
            raise CliError("incomplete")
        traceroute(str(parse_ipv4(t[i], i)))

    def c_show(self, t, i):
        if i >= len(t):
            raise CliError("incomplete")
        opts = ["interfaces", "ip", "arp"] + (["running-config"] if self.mode == "priv" else [])
        kw = match_kw(t[i], opts)
        if isinstance(kw, list):
            raise CliError("ambiguous", i, t[i])
        if kw is None:
            raise CliError("invalid", i)
        if kw == "interfaces":
            only = None
            if i + 1 < len(t):
                only, _ = parse_port(t, i + 1)
            lines = show_interfaces(only)
        elif kw == "arp":
            lines = show_arp()
        elif kw == "running-config":
            lines = show_running_config()
        else:
            if i + 1 >= len(t):
                raise CliError("incomplete")
            sub = match_kw(t[i + 1], ["route", "interface", "arp"])
            if isinstance(sub, list):
                raise CliError("ambiguous", i + 1, t[i + 1])
            if sub == "route":
                lines = show_ip_route()
            elif sub == "arp":
                lines = show_arp()
            elif sub == "interface":
                if i + 2 < len(t) and match_kw(t[i + 2], ["brief"]) == "brief":
                    lines = show_ip_int_brief()
                elif i + 2 >= len(t):
                    raise CliError("incomplete")
                else:
                    raise CliError("invalid", i + 2)
            else:
                raise CliError("invalid", i + 1)
        print("\n".join(lines))

    # -- config mode ----------------------------------------------------------------------------
    def c_cfg_exit(self, t, i):
        self.mode = "config" if self.mode == "if" else "priv"
        self.port = None

    def c_end(self, t, i):
        self.mode, self.port = "priv", None
        print(f"%SYS-5-CONFIG_I: Configured from console by console")

    def c_do(self, t, i):
        saved = self.mode
        self.mode = "priv"
        try:
            self.run(" ".join(t[i:]))
        finally:
            if self.mode == "priv":
                self.mode = saved

    def c_interface(self, t, i):
        n, _ = parse_port(t, i)
        self.mode, self.port = "if", n

    def c_hostname(self, t, i):
        if i >= len(t):
            raise CliError("incomplete")
        if not re.match(r"^[A-Za-z][A-Za-z0-9-]{0,62}$", t[i]):
            raise CliError("invalid", i)
        set_hostname(t[i])

    def c_ip_route(self, t, i, remove=False):
        if i >= len(t) or match_kw(t[i], ["route"]) != "route":
            raise CliError("incomplete" if i >= len(t) else "invalid", i)
        if i + 3 > len(t):
            raise CliError("incomplete")
        net = parse_ipv4(t[i + 1], i + 1)
        plen = parse_mask(t[i + 2], i + 2)
        prefix = ipaddress.IPv4Network(f"{net}/{plen}", strict=False)
        if prefix.network_address != net:
            print("%Inconsistent address and mask")
            return
        if i + 3 >= len(t):
            raise CliError("incomplete")
        if PORT_RE.match(t[i + 3]):
            n, _ = parse_port(t, i + 3)
            hop = f"eth{n}"
        else:
            hop = str(parse_ipv4(t[i + 3], i + 3))
        rc, out = vtysh("configure terminal", f"{'no ' if remove else ''}ip route {prefix} {hop}")
        if rc != 0 and out.strip():
            print(f"% {out.strip()}")

    def c_no_global(self, t, i):
        if i >= len(t):
            raise CliError("incomplete")
        kw = match_kw(t[i], ["ip", "hostname"])
        if kw == "ip":
            return self.c_ip_route(t, i + 1, remove=True)
        if kw == "hostname":
            set_hostname("Router")
            return
        raise CliError("invalid", i)

    # -- interface mode -------------------------------------------------------------------------
    def dev(self):
        return f"eth{self.port}"

    def c_if_ip(self, t, i):
        if i >= len(t) or match_kw(t[i], ["address"]) != "address":
            raise CliError("incomplete" if i >= len(t) else "invalid", i)
        if i + 1 >= len(t):
            raise CliError("incomplete")
        addr = parse_ipv4(t[i + 1], i + 1)
        if i + 2 >= len(t):
            raise CliError("incomplete")
        plen = parse_mask(t[i + 2], i + 2)
        net = ipaddress.IPv4Network(f"{addr}/{plen}", strict=False)
        if addr in (net.network_address, net.broadcast_address) and plen < 31:
            print("Bad mask /%d for address %s" % (plen, addr))
            return
        for n, dev in ports():
            if dev == self.dev():
                continue
            for a in iface_state(dev)["addrs"]:
                other = ipaddress.IPv4Network(f"{a['local']}/{a['prefixlen']}", strict=False)
                if other.overlaps(net):
                    print(f"% {net.network_address} overlaps with {GI}{n}")
                    return
        cmds = ["configure terminal", f"interface {self.dev()}"]
        for a in iface_state(self.dev())["addrs"]:
            cmds.append(f"no ip address {a['local']}/{a['prefixlen']}")
        cmds.append(f"ip address {addr}/{plen}")
        vtysh(*cmds)

    def c_if_no(self, t, i):
        if i >= len(t):
            raise CliError("incomplete")
        kw = match_kw(t[i], ["shutdown", "ip", "description"])
        if kw == "shutdown":
            st = iface_state(self.dev())
            vtysh("configure terminal", f"interface {self.dev()}", "no shutdown")
            if not st["admin_up"]:
                time.sleep(0.3)
                print(f"%LINK-3-UPDOWN: Interface {GI}{self.port}, changed state to up")
                print(f"%LINEPROTO-5-UPDOWN: Line protocol on Interface {GI}{self.port}, changed state to up")
        elif kw == "ip":
            if i + 1 >= len(t) or match_kw(t[i + 1], ["address"]) != "address":
                raise CliError("incomplete" if i + 1 >= len(t) else "invalid", i + 1)
            cmds = ["configure terminal", f"interface {self.dev()}"]
            cmds += [f"no ip address {a['local']}/{a['prefixlen']}" for a in iface_state(self.dev())["addrs"]]
            vtysh(*cmds)
        elif kw == "description":
            vtysh("configure terminal", f"interface {self.dev()}", "no description")
        else:
            raise CliError("invalid", i)

    def c_shutdown(self, t, i):
        st = iface_state(self.dev())
        vtysh("configure terminal", f"interface {self.dev()}", "shutdown")
        if st["admin_up"]:
            print(f"%LINK-5-CHANGED: Interface {GI}{self.port}, changed state to administratively down")
            print(f"%LINEPROTO-5-UPDOWN: Line protocol on Interface {GI}{self.port}, changed state to down")

    def c_description(self, t, i):
        if i >= len(t):
            raise CliError("incomplete")
        vtysh("configure terminal", f"interface {self.dev()}", f"description {' '.join(t[i:])}")


def caret_message(prompt, line, tokens_pos):
    """IOS points at the offending word with '^' under the typed line."""
    col = 0
    idx = 0
    for m in re.finditer(r"\S+", line):
        if idx == tokens_pos:
            col = m.start()
            break
        idx += 1
    return " " * (len(prompt) + col) + "^\n% Invalid input detected at '^' marker.\n"


def report(e, prompt, line):
    if e.kind == "invalid":
        print(caret_message(prompt, line, e.pos), end="")
    elif e.kind == "incomplete":
        print("% Incomplete command.\n")
    elif e.kind == "ambiguous":
        print(f'% Ambiguous command:  "{line.strip()}"')
    elif e.kind == "unknown":
        word = line.strip()
        print(f'Translating "{word}"')
        print("% Unknown command or computer name, or unable to find computer address")


def main():
    readline.parse_and_bind("tab: complete")
    readline.set_completer_delims(" ")
    cli = Cli()

    def completer(text, state):
        buf = readline.get_line_buffer()
        if buf.strip() and " " in buf.lstrip():
            return None
        opts = sorted(k + " " for k in cli.table() if k.startswith(text.lower()))
        return opts[state] if state < len(opts) else None

    readline.set_completer(completer)
    print()
    while True:
        try:
            p = cli.prompt()
            line = input(p)
        except EOFError:
            print()
            if cli.mode in ("config", "if"):     # Ctrl+Z / Ctrl+D in config: back to exec
                cli.mode, cli.port = "priv", None
                continue
            return 0
        except KeyboardInterrupt:
            print()
            continue
        try:
            try:
                cli.run(line)
            except CliError as e:
                report(e, p, line)
        except EOFError:
            return 0
        except Exception as e:                  # never drop a student to a traceback
            print(f"% Error on this simulated router: {e}")


if __name__ == "__main__":
    sys.exit(main())
