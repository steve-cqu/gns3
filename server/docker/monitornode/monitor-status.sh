#!/bin/bash
# What is this Monitor node actually doing?
# Usage: monitor-status.sh

echo "================================================"
echo "Monitor Node Status"
echo "================================================"
echo ""

echo "1. Processes:"
# blackbox_exporter and prometheus match on argv[0], so -x is right for them. Grafana does not:
# /usr/sbin/grafana-server execs /usr/bin/grafana server, so argv[0] is a full path and BusyBox
# `pgrep -x` never matches under either name while :3000 answers fine. Use -f for it.
for p in node_exporter blackbox_exporter prometheus; do
    if pgrep -x "$p" >/dev/null 2>&1; then
        echo "   RUNNING  $p"
    elif [ "$p" = "node_exporter" ]; then
        # Not a fault: node_exporter on THIS node is only needed if you want the Monitor to
        # appear in its own dashboards. start-monitoring.sh starts it; the piece-at-a-time
        # scripts do not, and no scrape target in the lab depends on it.
        echo "   stopped  $p   (optional on this node — see note below)"
    else
        echo "   stopped  $p"
    fi
done
if pgrep -f 'grafana server' >/dev/null 2>&1; then
    echo "   RUNNING  grafana"
else
    echo "   stopped  grafana"
fi
echo ""

echo "2. This node's addresses (what a browser should point at):"
ip -4 addr show | grep -E 'inet ' | grep -v '127.0.0.1' || echo "   no IPv4 address configured"
echo ""

echo "3. Endpoints:"
for spec in "node_exporter :9100 http://localhost:9100/metrics" \
            "blackbox     :9115 http://localhost:9115/" \
            "prometheus   :9090 http://localhost:9090/-/healthy" \
            "grafana      :3000 http://localhost:3000/login"; do
    set -- $spec
    code=$(curl -s -o /dev/null -m 3 -w '%{http_code}' "$3" 2>/dev/null)
    case "$code" in
        200) echo "   OK    $1 $2  (HTTP 200)" ;;
        000|"") echo "   DOWN  $1 $2  (no response)" ;;
        *)   echo "   ?     $1 $2  (HTTP $code)" ;;
    esac
done
echo ""

echo "4. Prometheus configuration check:"
promtool check config /etc/prometheus/prometheus.yml 2>&1 | sed 's/^/   /'
echo ""

echo "5. Scrape targets and their health:"
if curl -s -m 3 http://localhost:9090/api/v1/targets >/dev/null 2>&1; then
    up=$(curl -s -m 3 http://localhost:9090/api/v1/targets | grep -o '"health":"up"' | wc -l)
    down=$(curl -s -m 3 http://localhost:9090/api/v1/targets | grep -o '"health":"down"' | wc -l)
    echo "   up: $up   down: $down"
    echo "   (detail at http://<this-node-ip>:9090/targets)"
    if [ "$down" -gt 0 ]; then
        echo ""
        echo "   A target that is DOWN is usually one of:"
        echo "     - node_exporter not started on that host  (run: node_exporter &)"
        echo "     - the wrong address or port in prometheus.yml"
        echo "     - no route to that host                   (test: ping <host>)"
    fi
else
    echo "   Prometheus is not answering — start it with start-prometheus.sh"
fi
echo ""

echo "================================================"
echo "node_exporter on this node is optional: it publishes THIS node's own metrics, and"
echo "nothing in the lab scrapes it unless you add it to prometheus.yml yourself."
echo "start-monitoring.sh starts it; the three piece-at-a-time scripts do not."
echo ""
echo "Config:  /etc/prometheus/prometheus.yml"
echo "         /etc/prometheus/blackbox.yml"
echo "         /etc/grafana.ini"
echo "Logs:    /var/log/prometheus.log, /var/log/blackbox_exporter.log,"
echo "         /var/log/grafana/grafana.log"
echo "================================================"
