#!/usr/bin/env python3
"""Build the CQU lab apt repository — run ONCE, at image build time.

Produces a three-suite Debian repository under /opt/cqu-repo:

    cqu-base       the versions the estate was installed with
    cqu-security   security updates          <- short SLA, Essential Eight's "critical"
    cqu-updates    ordinary feature updates  <- normal maintenance window

The three suites are the whole point. Real Ubuntu separates `noble`, `noble-security` and
`noble-updates`, and that separation is what lets an administrator answer "which of these
updates actually has to go on tonight?" mechanically instead of by reading release notes. A
flat (`./`) repository cannot express it — every package comes back as `<name>/unknown` — so
this builds a proper `dists/` tree with a `Release` file per suite, and `apt list --upgradable`
then names the suite each update came from:

    cqu-payroll/cqu-security 1.1.0 all [upgradable from: 1.0.0]
    cqu-webapp/cqu-updates   2.4.0 all [upgradable from: 2.3.1]

WHY THIS RUNS AT IMAGE BUILD TIME AND NOT ON THE NODE. `cqugns3/ubuntunode` ships `dpkg-deb`
but NOT `dpkg-scanpackages`, `apt-ftparchive`, `dpkg-dev` or `gpg` (measured 6 September 2026),
and the topology has no Internet. Baking the repository means the node needs none of them: the
packages and their indices are already there, identical on every student's appliance and on
every rerun. That determinism is the reason the activity exists in this form at all — see
gns3-dev/notes/patch-management-activity.md, decision D1.

NO SIGNING, DELIBERATELY. There is no `gpg` in the image and a lab repository has nothing to
gain from a key students cannot verify anyway. Clients add the repository with `[trusted=yes]`,
which skips the signature check. Hashes in `Release` are still generated and still checked by
apt, so a truncated or edited index fails loudly.

Every package is `Architecture: all` (they contain one text file each), but apt fetches
`binary-<host arch>`, so the same index is written for both amd64 and arm64. One image
definition therefore serves both appliances with no per-architecture logic.
"""
import email.utils, gzip, hashlib, os, shutil, subprocess, time

REPO = "/opt/cqu-repo"
POOL = os.path.join(REPO, "pool", "main")
ARCHES = ["amd64", "arm64"]
# Fixed, so two builds of this image produce byte-identical indices. No Valid-Until field is
# written, so apt never treats the repository as expired however old the appliance is.
DATE = email.utils.formatdate(time.mktime((2026, 9, 1, 9, 0, 0, 0, 0, 0)), usegmt=True)

# (package, version, suite, description, changelog entry)
#
# THE SET IS CHOSEN SO THAT "UPGRADE EVERYTHING" IS THE WRONG ANSWER. One update must go on
# quickly, one can wait for a window, and one must not go on at all -- so the student has to
# triage and justify rather than run `apt-get upgrade -y` and call it patching.
PACKAGES = [
    ("cqu-payroll", "1.0.0", "cqu-base",
     "Payroll application\n Processes the fortnightly payroll run.",
     "Initial packaged release."),
    ("cqu-payroll", "1.1.0", "cqu-security",
     "Payroll application (security update)\n"
     " Processes the fortnightly payroll run.\n"
     " .\n"
     " SECURITY: fixes CVE-2026-4417, an authentication bypass in the session handler that\n"
     " allows an unauthenticated user to read payroll records. Rated high. Apply promptly.",
     "SECURITY: fix CVE-2026-4417, authentication bypass in the session handler."),

    ("cqu-webapp", "2.3.1", "cqu-base",
     "Customer web application\n Public-facing customer portal.",
     "Initial packaged release."),
    ("cqu-webapp", "2.4.0", "cqu-updates",
     "Customer web application\n"
     " Public-facing customer portal.\n"
     " .\n"
     " Adds a customer self-service password reset page and refreshes the site theme.\n"
     " No security content.",
     "Add self-service password reset. Refresh theme."),

    ("cqu-legacy-agent", "0.9.0", "cqu-base",
     "Vendor monitoring agent\n Collects host metrics for the monitoring platform.",
     "Initial packaged release."),
    ("cqu-legacy-agent", "1.0.0", "cqu-updates",
     "Vendor monitoring agent\n"
     " Collects host metrics for the monitoring platform.\n"
     " .\n"
     " BREAKING: the v1 collector API replaces the v0 API. Agents running 1.0.0 report only\n"
     " to a v1 monitoring server; the site's server is v0 and has no upgrade path until the\n"
     " vendor ships one. Installing this stops metrics reaching the server.\n"
     " No security content.",
     "BREAKING: replace v0 collector API with v1. Requires a v1 monitoring server."),
]


def build_deb(name, version, description, changelog):
    """Build one .deb into the pool with dpkg-deb, the one packaging tool the image has."""
    root = f"/tmp/build/{name}_{version}"
    shutil.rmtree(root, ignore_errors=True)
    os.makedirs(f"{root}/DEBIAN")
    os.makedirs(f"{root}/usr/share/{name}")
    os.makedirs(f"{root}/usr/share/doc/{name}")

    # Written line by line rather than from a dedented triple-quoted string. textwrap.dedent
    # computes the common leading whitespace across ALL lines, and `description` is multi-line
    # with the single leading space Debian requires on a continuation — so dedent took that one
    # space as the common prefix, stripped one space from every line, and produced a control
    # file both indented and with the continuation flattened to column 0. dpkg-deb rejected it
    # with "empty field name", which names neither the field nor the cause.
    with open(f"{root}/DEBIAN/control", "w") as f:
        f.write("\n".join([
            f"Package: {name}",
            f"Version: {version}",
            "Section: misc",
            "Priority: optional",
            "Architecture: all",
            "Maintainer: CQU Lab <lab@example.com>",
            f"Description: {description}",
        ]) + "\n")

    # Something for the student to look at, so "did the upgrade land?" has an answer that is
    # not just dpkg's opinion.
    with open(f"{root}/usr/share/{name}/VERSION", "w") as f:
        f.write(f"{name} {version}\n")

    # A changelog, because "read what changed before you deploy it" is the habit this week is
    # trying to build.
    #
    # The name and the gzip are both required, not stylistic. Ubuntu's Docker base ships
    # /etc/dpkg/dpkg.cfg.d/excludes with `path-exclude=/usr/share/doc/*` and, as its only
    # reprieve, `path-include=/usr/share/doc/*/changelog.*` — note the dot. A file called
    # plainly `changelog` does not match that pattern, so it is built into the .deb and then
    # silently DISCARDED at install time: `dpkg-deb -c` shows it, the installed system does
    # not have it. `changelog.Debian.gz` matches, and is the real Debian convention anyway, so
    # `zcat /usr/share/doc/<pkg>/changelog.Debian.gz` is both what works here and what an
    # administrator actually types.
    body = (f"{name} ({version}) stable; urgency=medium\n\n"
            f"  * {changelog}\n\n"
            f" -- CQU Lab <lab@example.com>  {DATE}\n").encode()
    with gzip.GzipFile(f"{root}/usr/share/doc/{name}/changelog.Debian.gz", "wb", mtime=0) as gz:
        gz.write(body)

    out = f"{POOL}/{name}_{version}_all.deb"
    subprocess.run(["dpkg-deb", "--build", "--root-owner-group", root, out],
                   check=True, stdout=subprocess.DEVNULL)
    return os.path.basename(out)


def control_stanza(deb_path, filename, description):
    """The package's own control fields, plus the four the index adds."""
    ctl = subprocess.run(["dpkg-deb", "-f", deb_path],
                         capture_output=True, text=True, check=True).stdout.strip()
    blob = open(deb_path, "rb").read()
    # Description-md5 is NOT optional here, and leaving it out cost a build to find.
    #
    # apt stores descriptions de-duplicated, keyed by this hash. With the field absent every
    # stanza keys to the SAME empty hash, so all versions of a package collapse onto whichever
    # description apt read first — `apt show cqu-payroll=1.1.0` printed the 1.0.0 text, with
    # the CVE paragraph missing, while the index on disk was perfectly correct. That is a
    # silent wrong answer in the exact place this activity asks students to look.
    #
    # apt hashes the raw field value plus a trailing newline (deblistparser.cc,
    # debListParser::Description_md5). Any per-description-unique value would in fact break
    # the collision, since nothing offline consults translated descriptions, but matching
    # apt's own definition costs one line and keeps the index honest.
    dmd5 = hashlib.md5((description + "\n").encode()).hexdigest()
    return (f"{ctl}\n"
            f"Description-md5: {dmd5}\n"
            f"Filename: pool/main/{filename}\n"
            f"Size: {len(blob)}\n"
            f"SHA256: {hashlib.sha256(blob).hexdigest()}\n")


def write_indices(suite, stanzas):
    """Write Packages + Packages.gz for every architecture, then the suite's Release."""
    hashed = []
    for arch in ARCHES:
        d = f"{REPO}/dists/{suite}/main/binary-{arch}"
        os.makedirs(d, exist_ok=True)
        body = ("\n".join(stanzas) + "\n").encode()
        # Both forms are written on purpose: apt asks for the compressed index FIRST, and a
        # repository with only a plain Packages answers 404 twice per update before falling
        # back. Harmless, but it looks like a fault to a student reading the output.
        open(f"{d}/Packages", "wb").write(body)
        with gzip.GzipFile(f"{d}/Packages.gz", "wb", mtime=0) as gz:
            gz.write(body)
        for rel in (f"main/binary-{arch}/Packages", f"main/binary-{arch}/Packages.gz"):
            raw = open(f"{REPO}/dists/{suite}/{rel}", "rb").read()
            hashed.append((rel, raw))

    lines = [
        "Origin: CQU Lab",
        "Label: CQU Lab",
        f"Suite: {suite}",
        f"Codename: {suite}",
        f"Architectures: {' '.join(ARCHES)}",
        "Components: main",
        f"Description: CQU teaching repository ({suite})",
        f"Date: {DATE}",
        "MD5Sum:",
    ]
    lines += [f" {hashlib.md5(b).hexdigest()} {len(b)} {rel}" for rel, b in hashed]
    lines.append("SHA256:")
    lines += [f" {hashlib.sha256(b).hexdigest()} {len(b)} {rel}" for rel, b in hashed]
    open(f"{REPO}/dists/{suite}/Release", "w").write("\n".join(lines) + "\n")


def main():
    shutil.rmtree(REPO, ignore_errors=True)
    os.makedirs(POOL)
    suites = {}
    for name, version, suite, desc, changelog in PACKAGES:
        filename = build_deb(name, version, desc, changelog)
        suites.setdefault(suite, []).append(
            control_stanza(f"{POOL}/{filename}", filename, desc))
    for suite, stanzas in sorted(suites.items()):
        write_indices(suite, stanzas)
        print(f"  {suite:14} {len(stanzas)} package(s)")
    shutil.rmtree("/tmp/build", ignore_errors=True)
    print(f"repository built at {REPO}")


if __name__ == "__main__":
    main()
