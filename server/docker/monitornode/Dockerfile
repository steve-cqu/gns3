# Observability node: Prometheus + Grafana + blackbox_exporter.
#
# WHY ALPINE. Grafana is packaged in Alpine community for both architectures and is not in
# Ubuntu's archive at any version — an Ubuntu build would mean adding Grafana's own apt
# repository and GPG key, a third-party source outside the distribution that can move under a
# rebuild. That is the opposite of the pinned-base rule alpinenode's Dockerfile exists to
# protect. See gns3-dev/notes/tier1-service-nodes-plan.md, decision D1.
#
# WHY ONE NODE FOR THREE SERVICES. In production you would separate them. In a topology they
# are one box — the Monitor — and splitting them into three nodes would add three addresses to
# configure and three consoles to juggle in exchange for no teaching: the lesson is the
# scrape -> probe -> visualise relationship, not deployment topology. They get their own image
# rather than joining servicenode because Grafana and Prometheus are ~330 MB and ~224 MB of Go
# binary and web assets, and the rule is that a runtime forces a split. Decision D2.
FROM cqugns3/alpinenode

# node_exporter is NOT installed here — it comes from the base image, which carries it so that
# every Linux Host in every topology is monitorable without being swapped for a special node.
# The Monitor scrapes itself with the same exporter as everything else.
RUN apk add --no-cache \
    prometheus \
    prometheus-blackbox-exporter \
    grafana

# Data and log directories. Prometheus and Grafana both create their own on first run, but
# creating them here means the template's extra_volumes have something to bind to on a node
# that has never been started.
RUN mkdir -p /var/lib/prometheus/data /var/lib/grafana/plugins /var/log/grafana

# Shipped configuration.
#
# prometheus.yml is VALID AS IT STANDS and scrapes exactly one target — Prometheus itself. That
# is deliberate: a student can start it and see a green target before writing any config, which
# separates "the stack works" from "my scrape job is wrong". The jobs for node_exporter and the
# blackbox probes are present as commented stubs, because writing them is the activity.
COPY prometheus.yml /etc/prometheus/prometheus.yml
COPY blackbox.yml   /etc/prometheus/blackbox.yml

# A MINIMAL grafana.ini. Grafana layers its configuration: /usr/share/grafana/conf/defaults.ini
# holds every default, and this file overrides only what a lab needs. Replacing the whole file
# would mean tracking Grafana's defaults at every version bump.
COPY grafana.ini    /etc/grafana.ini

# Helper scripts in /usr/local/bin so a student's edit survives the project being closed —
# /usr/local/bin can be persisted, /bin cannot. (The lesson recorded in ipv6node's Dockerfile.)
#
# Four start scripts rather than one, because the activity brings the stack up a piece at a
# time and watches targets come UP. start-monitoring.sh is the shortcut for a repeat run.
COPY start-prometheus.sh /usr/local/bin/start-prometheus.sh
COPY start-blackbox.sh   /usr/local/bin/start-blackbox.sh
COPY start-grafana.sh    /usr/local/bin/start-grafana.sh
COPY start-monitoring.sh /usr/local/bin/start-monitoring.sh
COPY monitor-status.sh   /usr/local/bin/monitor-status.sh
RUN chmod +x /usr/local/bin/start-prometheus.sh /usr/local/bin/start-blackbox.sh \
             /usr/local/bin/start-grafana.sh /usr/local/bin/start-monitoring.sh \
             /usr/local/bin/monitor-status.sh

# /var/lib/grafana is the one that matters most: Grafana keeps dashboards in a SQLite database
# there, and the dashboard IS the assessed output of the monitoring activity — four of its six
# required screenshots come from it. A student who loses it on a project close has to rebuild
# three panels. Declared here as well as in the template's extra_volumes so it holds even under
# a template registered by hand.
VOLUME /var/lib/grafana /var/lib/prometheus /etc/prometheus
