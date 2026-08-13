#!/bin/bash
# What is this Monitor node actually doing?
# Usage: monitor-status.sh

echo "================================================"
echo "Monitor Node Status"
echo "================================================"
echo ""

echo "1. Processes:"
for p in node_exporter blackbox_exporter prometheus grafana-server; do
    if pgrep -x "$p" >/dev/null 2>&1; then
        echo "   RUNNING  $p"
    else
        echo "   stopped  $p"
    fi
done
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
echo "Config:  /etc/prometheus/prometheus.yml"
echo "         /etc/prometheus/blackbox.yml"
echo "         /etc/grafana.ini"
echo "Logs:    /var/log/prometheus.log, /var/log/blackbox_exporter.log,"
echo "         /var/log/grafana/grafana.log"
echo "================================================"
