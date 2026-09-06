# Patch Server node — the estate's package source, for the patch-management activity
# (COIT13146 Week 4). See gns3-dev/notes/patch-management-activity.md.
#
# WHY THIS NODE EXISTS. Patching is the one operations topic the major does not teach anywhere,
# and it cannot be taught against the real Ubuntu archive: that needs Internet inside the
# topology, downloads tens of MB per student, and gives a different answer every week, so no
# activity written against it stays correct. A repository the appliance owns is deterministic,
# offline and instant — the same three updates, in the same three suites, on every student's
# machine, this term and next.
#
# Derived from cqugns3/ubuntunode so a console on it behaves like every other Ubuntu node, and
# because it already ships the two things this needs: nginx to serve the repository and
# dpkg-deb to build it. Nothing is added to the image but the repository itself.
FROM cqugns3/ubuntunode

# Build the repository INTO the image. Three suites (cqu-base, cqu-security, cqu-updates), six
# packages, proper dists/ indices — the generator's docstring explains the shape and why.
#
# /opt is deliberately NOT one of ubuntunode's GNS3 volumes (/etc, /root, /home, /var/www,
# /usr/local/bin). That is the point: the repository is part of the image, so a student cannot
# leave it in a broken state and every project starts from the same bytes. Serving it out of
# /var/www would have put it in a volume, where a half-finished experiment persists.
COPY build-repo.py /usr/local/sbin/build-repo.py
RUN python3 /usr/local/sbin/build-repo.py

# The start script lives in /usr/local/bin, which IS a volume and is ahead of /bin in PATH, so
# a staff edit on a live node survives a project close — the convention ipv6node's Dockerfile
# records.
COPY start-patchrepo.sh /usr/local/bin/start-patchrepo.sh
RUN chmod +x /usr/local/bin/start-patchrepo.sh

# Fail the build rather than ship a repository that is missing a suite. A patch activity whose
# package source is silently empty wastes a tutorial before anyone works out why.
RUN test -f /opt/cqu-repo/dists/cqu-base/Release \
 && test -f /opt/cqu-repo/dists/cqu-security/Release \
 && test -f /opt/cqu-repo/dists/cqu-updates/Release \
 && test "$(ls /opt/cqu-repo/pool/main/*.deb | wc -l)" = "6"
