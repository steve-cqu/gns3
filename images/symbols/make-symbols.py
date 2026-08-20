#!/usr/bin/env python3
"""Generate the CQU node symbols: one of four bases, plus a band naming the role.

Run it from anywhere; it writes .svg files beside itself and is idempotent.

    ./make-symbols.py            # write every symbol in SYMBOLS
    ./make-symbols.py --check    # exit 1 if any file on disk differs (for CI)
    ./make-symbols.py --list     # print the plan without writing

Why a generator rather than an Inkscape file per symbol
-------------------------------------------------------
Every CQU symbol used to be hand-drawn by copying the previous one and retyping the
label. They drifted, exactly as you would expect: `krb5` ended up lowercase and
left-anchored where every other label was centred uppercase, `Wazuh Agent` wrapped onto
two lines inside the monitor, and `computer-suricata.svg` was drawn and then never wired
to a template. A string in a table cannot drift.

The design, and the measurement behind it
-----------------------------------------
A label sits in a dark band flush with the bottom of the artwork, not on the artwork.
White text sampled against each base measures:

    router teal    #3c8c8c   3.95:1     PC screen  #588ab6   3.40:1
    ids box        #8fa8c4   2.45:1     server     #d8d8d8   1.43:1
    the band       #1f4040  11.26:1  <- CQU Dark Green, an approved brand pairing, AAA

Nothing in GNS3's classic artwork is dark enough to carry white text at the size these
render (18.67 px regular is not "large text"), so the band is not decoration — it is the
only part of the symbol a label can legibly sit on. It also retires the -w/-b pairs the
old symbols came in: white on its own dark band works on any canvas colour.

A Qemu-backed node also gets a corner tag ("Q"), because how a node runs is not something
the band can say and it is the difference between a node that starts in seconds and one
that takes minutes on a machine without nested virtualisation.

An UNLABELLED base is the generic member of its class — Linux Host, Linux Router, Linux
Server — so those three keep GNS3's built-in symbol and are not generated here.

Label budget, from BAND_W_FRAC and MAX_FS below: nine characters on a host or router,
seven on a server or sensor. Past that the label still fits, it just shrinks, which is
the one thing the band exists to prevent. `--check` fails if a label overflows.

Bases live in bases/ and are GNS3's own `classic` symbols, copied unmodified from
gns3server/symbols/classic/. They are not installed on the appliance: the `logos` phase
globs *.svg in this directory and does not recurse.
"""
import argparse
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
BASES = HERE / "bases"

BAND_FILL = "#1f4040"          # CQU Dark Green
BAND_INK = "#ffffff"
BAND_H = 12.0                  # symbol units; fixed so a label reads the same on every base
BAND_W_FRAC = 0.90
MAX_FS = 9.5
CHAR_W = 0.60                  # Arial bold advance, em, measured on uppercase
FONT = "Arial, Helvetica, sans-serif"

# Wireless marks. The station gets radiating arcs, the access point gets antennas — both
# in the band colour so the three marks read as one system.
ARC_N, ARC_R0, ARC_STEP, ARC_SW = 3, 2.6, 2.6, 1.15
AP_LIFT = 13.0                 # headroom added above the router base for the antennas
AP_ANTENNAS = [(26, 20, 20.5, 2.5), (40, 20, 45.5, 2.5)]     # splayed, x1 y1 -> x2 y2

# Qemu tag. A Qemu-backed node costs things a Docker one does not — it boots in minutes
# rather than seconds wherever there is no nested virtualisation, and a project containing
# one is locked to the architecture it was exported on — so which nodes are Qemu is worth
# seeing on the canvas rather than looking up. It is the same dark green and the same white
# ink as the band, so the two marks read as one system: the band says WHICH node this is,
# the corner tag says HOW IT RUNS. Top-left, because the band owns the bottom and the
# wireless arcs own the top-right.
QEMU_TAG = "Q"
QEMU_W, QEMU_H, QEMU_FS, QEMU_PAD = 13.0, 11.0, 8.0, 0.9

# (file stem, base, label, extra mark).  A stem of "" means "not generated".
SYMBOLS = [
    # --- services, on the server tower -----------------------------------
    ("server-dns",       "server", "DNS",     None),
    ("server-ntp",       "server", "NTP",     None),
    ("server-dhcp",      "server", "DHCP",    None),
    ("server-db",        "server", "DB",      None),
    ("server-cache",     "server", "CACHE",   None),
    ("server-file",      "server", "FILE",    None),
    ("server-git",       "server", "GIT",     None),
    ("server-mon",       "server", "MON",     None),
    ("server-kdc",       "server", "KDC",     None),
    ("server-sdn",       "server", "SDN",     None),
    # not wired to a template yet — the candidates in gns3-dev/notes/candidate-node-types.md
    ("server-web",       "server", "WEB",     None),
    ("server-proxy",     "server", "PROXY",   None),
    ("server-radius",    "server", "RADIUS",  None),
    ("server-mqtt",      "server", "MQTT",    None),
    ("server-lb",        "server", "LB",      None),
    ("server-ca",        "server", "CA",      None),

    # --- hosts, on the PC ------------------------------------------------
    # Kali, Firefox, Ansible and ReactOS are NOT here: they carry drawn logos on the
    # screen, which beat a word and are kept as they are.
    ("computer-ubuntu",     "computer", "UBUNTU",  None),
    ("computer-windows",    "computer", "WIN11",   None),
    ("computer-trafficgen", "computer", "TRAFGEN", None),
    ("computer-wazuhagent", "computer", "WAZUH",   None),
    ("computer-wifi",       "computer", "WIFI",    "arcs"),

    # --- forwarding, on the router ---------------------------------------
    ("router-frr",      "router", "FRR",      None),
    ("router-vpn",      "router", "VPN",      None),
    # The IPsec Gateway (cqugns3/strongswan) had been borrowing router-vpn.svg from the
    # WireGuard VPN Router. Two templates on one symbol is the thing the corner tag was added
    # to stop: a tunnel lab puts both kinds of gateway on one canvas, and which is which is
    # the whole subject of the lab.
    ("router-ipsec",    "router", "IPSEC",    None),
    ("router-nat64",    "router", "NAT64",    None),
    ("router-openwrt",  "router", "OPENWRT",  None),
    ("router-opnsense", "router", "OPNSENSE", None),
    ("router-ap",       "router", "AP",       "antennas"),

    # --- Qemu-backed nodes: the same artwork, plus the corner tag ---------
    # Every Qemu node the manifest still defines. Two of the three are `optional:` — nothing
    # installs them unless a build asks — and the tag is why they are drawn at all: an
    # OpenWRT node and an OpenWRT Router node were the same router wearing the same band,
    # with nothing on the canvas to say one of them boots for minutes on a Mac.
    ("router-openwrt-qemu",  "router",   "OPENWRT",  "qemu"),
    ("router-opnsense-qemu", "router",   "OPNSENSE", "qemu"),
    ("computer-ubuntu-qemu", "computer", "UBUNTU",   "qemu"),
    ("router-frr-qemu",      "router",   "FRR",      "qemu"),

    # --- observers, on the IDS box ---------------------------------------
    ("sensor-ids",   "ids", "IDS",   None),
    ("sensor-flow",  "ids", "FLOW",  None),
    ("sensor-zeek",  "ids", "ZEEK",  None),      # planned
    ("sensor-honey", "ids", "HONEY", None),      # planned
]


def dims(svg):
    """(width, height) from the root <svg> tag. These files carry no viewBox."""
    head = svg[:svg.find(">", svg.find("<svg"))]
    w = re.search(r'\bwidth="([\d.]+)', head)
    h = re.search(r'\bheight="([\d.]+)', head)
    if not (w and h):
        raise ValueError("base SVG has no width/height on its root element")
    return float(w.group(1)), float(h.group(1))


def font_size(text, band_w):
    """Largest size that keeps the label inside the band, capped at MAX_FS."""
    return min(MAX_FS, (band_w - 4.5) / (max(len(text), 1) * CHAR_W))


def capacity(band_w):
    """How many characters fit at full size — the label budget for this base."""
    return int((band_w - 4.5) / (MAX_FS * CHAR_W))


def grow_top(svg, dy):
    """Add headroom above the artwork by translating everything down.

    A nested <svg> would be tidier but Qt's SVG renderer — which the GNS3 desktop GUI
    uses — does not handle it reliably, so this stays a plain group transform.
    """
    w, h = dims(svg)
    cut = svg.find(">", svg.find("<svg")) + 1
    head, body = svg[:cut], svg[cut:]
    head = re.sub(r'(\bwidth=")[\d.]+(")', lambda m: f"{m.group(1)}{w}{m.group(2)}", head, count=1)
    head = re.sub(r'(\bheight=")[\d.]+(")', lambda m: f"{m.group(1)}{h + dy:.6f}{m.group(2)}",
                  head, count=1)
    return head + f'<g transform="translate(0,{dy})">' + body.replace("</svg>", "</g></svg>")


def add_band(svg, text):
    w, h = dims(svg)
    bw = w * BAND_W_FRAC
    cx, cy = w / 2.0, h - BAND_H / 2.0
    fs = font_size(text, bw)
    return svg.replace("</svg>",
        '<g id="cqu-label">'
        f'<rect x="{cx - bw / 2:.2f}" y="{cy - BAND_H / 2:.2f}" width="{bw:.2f}" '
        f'height="{BAND_H}" rx="2.5" fill="{BAND_FILL}" stroke="#ffffff" stroke-width="0.9"/>'
        f'<text x="{cx:.2f}" y="{cy + fs * 0.35:.2f}" font-family="{FONT}" '
        f'font-size="{fs:.2f}" font-weight="bold" text-anchor="middle" '
        f'fill="{BAND_INK}">{text}</text>'
        '</g></svg>')


def add_arcs(svg, cx, cy):
    """Concentric arcs opening upward — this node has a radio. Haloed so it reads on
    the artwork as well as off it."""
    parts = []
    for i in range(ARC_N):
        r = ARC_R0 + i * ARC_STEP
        d = (f"M {cx - 0.866 * r:.2f} {cy - 0.5 * r:.2f} A {r:.2f} {r:.2f} 0 0 1 "
             f"{cx + 0.866 * r:.2f} {cy - 0.5 * r:.2f}")
        parts.append(f'<path d="{d}" fill="none" stroke="#ffffff" '
                     f'stroke-width="{ARC_SW + 1.1:.2f}" stroke-linecap="round"/>')
        parts.append(f'<path d="{d}" fill="none" stroke="{BAND_FILL}" '
                     f'stroke-width="{ARC_SW:.2f}" stroke-linecap="round"/>')
    parts.append(f'<circle cx="{cx:.2f}" cy="{cy:.2f}" r="{ARC_SW * 1.6:.2f}" fill="#ffffff"/>')
    parts.append(f'<circle cx="{cx:.2f}" cy="{cy:.2f}" r="{ARC_SW * 0.95:.2f}" fill="{BAND_FILL}"/>')
    return svg.replace("</svg>", '<g id="cqu-wifi">' + "".join(parts) + "</g></svg>")


def add_antennas(svg, rods, sw=2.0, tip=1.5):
    halo = "".join(
        f'<line x1="{a}" y1="{b}" x2="{c}" y2="{d}" stroke="#ffffff" '
        f'stroke-width="{sw + 1.6:.2f}" stroke-linecap="round"/>'
        f'<circle cx="{c}" cy="{d}" r="{tip + 0.8:.2f}" fill="#ffffff"/>' for a, b, c, d in rods)
    ink = "".join(
        f'<line x1="{a}" y1="{b}" x2="{c}" y2="{d}" stroke="{BAND_FILL}" '
        f'stroke-width="{sw:.2f}" stroke-linecap="round"/>'
        f'<circle cx="{c}" cy="{d}" r="{tip:.2f}" fill="{BAND_FILL}"/>' for a, b, c, d in rods)
    return svg.replace("</svg>", f'<g id="cqu-antenna">{halo}{ink}</g></svg>')


def add_qemu_tag(svg):
    """The corner tag marking a Qemu-backed node."""
    cx, cy = QEMU_PAD + QEMU_W / 2, QEMU_PAD + QEMU_H / 2
    return svg.replace("</svg>",
        '<g id="cqu-qemu">'
        f'<rect x="{QEMU_PAD}" y="{QEMU_PAD}" width="{QEMU_W}" height="{QEMU_H}" rx="2.5" '
        f'fill="{BAND_FILL}" stroke="{BAND_INK}" stroke-width="0.9"/>'
        f'<text x="{cx:.2f}" y="{cy + QEMU_FS * 0.35:.2f}" font-family="{FONT}" '
        f'font-size="{QEMU_FS:.2f}" font-weight="bold" text-anchor="middle" '
        f'fill="{BAND_INK}">{QEMU_TAG}</text>'
        '</g></svg>')


def build(base_name, label, mark):
    path = BASES / f"{base_name}.svg"
    if not path.exists():
        sys.exit(f"missing base artwork: {path}")
    svg = path.read_text()
    for mk in [x.strip() for x in (mark or "").split(",") if x.strip()]:
        if mk == "antennas":
            svg = add_antennas(grow_top(svg, AP_LIFT), AP_ANTENNAS)
        elif mk == "arcs":
            w, _ = dims(svg)
            svg = add_arcs(svg, w - 7.9, 13.0)
        elif mk == "qemu":
            svg = add_qemu_tag(svg)
        else:
            sys.exit(f"unknown mark {mk!r}")
    return add_band(svg, label)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--check", action="store_true",
                    help="verify the files on disk match, and exit 1 if not")
    ap.add_argument("--list", action="store_true", help="print the plan and stop")
    args = ap.parse_args(argv)

    budgets = {b: capacity(dims((BASES / f"{b}.svg").read_text())[0] * BAND_W_FRAC)
               for b in sorted({s[1] for s in SYMBOLS})}
    if args.list:
        print("label budget at full size: " +
              ", ".join(f"{b} {n}" for b, n in sorted(budgets.items())))
        for stem, base, label, mark in SYMBOLS:
            print(f"  {stem + '.svg':<26} {base:<9} {label:<8}{' + ' + mark if mark else ''}")
        return 0

    over = [(s, l, budgets[b]) for s, b, l, _ in SYMBOLS if len(l) > budgets[b]]
    for stem, label, n in over:
        print(f"  WARN   {stem}: {label!r} is {len(label)} characters, over this base's "
              f"budget of {n} — it will be shrunk to fit", file=sys.stderr)

    written = same = differ = 0
    for stem, base, label, mark in SYMBOLS:
        out = HERE / f"{stem}.svg"
        text = build(base, label, mark)
        if out.exists() and out.read_text() == text:
            same += 1
            continue
        if args.check:
            print(f"  DIFF   {out.name}")
            differ += 1
            continue
        out.write_text(text)
        print(f"  write  {out.name:<26} {base:<9} {label}")
        written += 1

    if args.check:
        print(f"\n{same} up to date, {differ} differ")
        return 1 if (differ or over) else 0
    print(f"\n{written} written, {same} already correct, {len(SYMBOLS)} total")
    return 1 if over else 0


if __name__ == "__main__":
    sys.exit(main())
