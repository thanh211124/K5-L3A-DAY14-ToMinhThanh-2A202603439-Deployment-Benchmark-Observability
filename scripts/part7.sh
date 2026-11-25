#!/usr/bin/env bash
# Part 7 Bước 2 (Observability stack) — chạy trong GitHub Codespaces (Linux + Docker).
#
#   bash scripts/part7.sh up       # 1. bật stack + unit test alert (promtool)
#   bash scripts/part7.sh scale    # 2. Locust headless scale 1 vs 3 -> CSV (mất ~6 phút)
#   bash scripts/part7.sh trace    # 3. tạo tải ngắn, tìm trace chậm + trace lỗi trong Jaeger
#   bash scripts/part7.sh chaos    # 4. thí nghiệm A-E + 2 alert cùng firing (mất ~25 phút, CÓ DỪNG ĐỂ CHỤP ẢNH)
#   bash scripts/part7.sh down     # 5. dọn stack (chỉ chạy SAU KHI đã chụp đủ ảnh)
#
# Mọi output ghi nối vào evidence/part7.log. Số liệu lấy từ API của Prometheus/Jaeger
# và từ file CSV của Locust, không có số ước lượng.

set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
PROD="$ROOT/06-lab-complete/benchmark-observability/production"
PROJECT="k5-day14-observability"
OUT="$ROOT/evidence/part7.log"
mkdir -p "$ROOT/evidence" "$ROOT/benchmark-results" "$PROD/benchmark-results"
touch "$OUT"

dc() { (cd "$PROD" && docker compose --progress quiet -p "$PROJECT" "$@"); }
log() { printf '\n### %s\n' "$*" | tee -a "$OUT"; }
note() { printf '%s\n' "$*" | tee -a "$OUT"; }
cmd() { printf '$ %s\n' "$*" | tee -a "$OUT"; }

# ---------- helpers: Prometheus ----------
pq() { # pq '<promql>'  -> in "giá trị" đầu tiên hoặc N/A
  curl -s -G "http://localhost:9090/api/v1/query" --data-urlencode "query=$1" \
  | python -c "
import sys, json
try:
    r = json.load(sys.stdin)['data']['result']
    print(' | '.join(f\"{x['metric']} = {float(x['value'][1]):.4g}\" if x['metric'] else f\"{float(x['value'][1]):.4g}\" for x in r) or 'N/A (không có dữ liệu)')
except Exception as e:
    print('N/A', e)
"
}
alerts_state() { # in: alertname=state ...
  curl -s http://localhost:9090/api/v1/alerts | python -c "
import sys, json
try:
    a = json.load(sys.stdin)['data']['alerts']
    print(' '.join(sorted(f\"{x['labels']['alertname']}={x['state']}\" for x in a)) or '(không có alert nào pending/firing)')
except Exception as e:
    print('N/A', e)
"
}
# chờ 1 alert chuyển sang firing. In: pending sau Xs, firing sau Ys (tính từ lúc gọi hàm)
wait_firing() { # wait_firing <AlertName> <max_seconds>
  local name="$1" max="$2" t0 now st pend=""
  t0=$(date +%s)
  while :; do
    now=$(date +%s)
    st=$(curl -s http://localhost:9090/api/v1/alerts | python -c "
import sys, json
n = '$name'
try:
    a = [x for x in json.load(sys.stdin)['data']['alerts'] if x['labels']['alertname'] == n]
    print(a[0]['state'] if a else 'none')
except Exception:
    print('none')
")
    if [ "$st" = "pending" ] && [ -z "$pend" ]; then pend=$((now - t0)); fi
    if [ "$st" = "firing" ]; then
      note "  -> $name: pending sau ${pend:-?}s, FIRING sau $((now - t0))s (tính từ lúc áp dụng thay đổi)"
      return 0
    fi
    if [ $((now - t0)) -ge "$max" ]; then
      note "  -> $name: KHÔNG firing sau ${max}s (trạng thái cuối: $st)"
      return 1
    fi
    sleep 5
  done
}
wait_clear() { # chờ hết alert firing, tối đa 300s
  local t0 now
  t0=$(date +%s)
  while :; do
    now=$(date +%s)
    if ! alerts_state | grep -q firing; then note "  alert đã hết firing sau $((now - t0))s"; return 0; fi
    [ $((now - t0)) -ge 300 ] && { note "  alert vẫn firing sau 300s: $(alerts_state)"; return 1; }
    sleep 5
  done
}
wait_http() { # wait_http url [max]
  local i
  for ((i = 0; i < ${2:-120}; i++)); do
    [ "$(curl -s -o /dev/null -m 3 -w '%{http_code}' "$1")" = "200" ] && return 0
    sleep 1
  done
  note "HẾT GIỜ: $1"; return 1
}
agent_up() { # agent_up "ENV=val ENV2=val" -> recreate 2 agent với biến mới
  # shellcheck disable=SC2086
  (cd "$PROD" && env $1 docker compose --progress quiet -p "$PROJECT" up -d --force-recreate --scale agent=2 agent) 2>&1 | tail -3 | tee -a "$OUT"
  sleep 15   # chờ DNS (nginx/prometheus làm mới mỗi 10s) + agent khởi động
}
start_load() { # start_load <users>
  docker rm -f k5-locust-load >/dev/null 2>&1
  (cd "$PROD" && docker compose --progress quiet -p "$PROJECT" run -d --rm --name k5-locust-load locust \
    -f /mnt/locust/locustfile.py --host http://nginx --headless -u "$1" -r 5 -t 60m) >/dev/null 2>&1
}
stop_load() { docker rm -f k5-locust-load >/dev/null 2>&1; }
pause_for_screenshot() { # pause_for_screenshot "<hướng dẫn>"
  printf '\n>>> %s\n>>> Chụp xong thì nhấn Enter để tiếp tục... ' "$*" | tee -a "$OUT"
  read -r _ </dev/tty
}

stage_up() {
  log "UP — bật stack và unit test alert"
  cmd "docker compose -p $PROJECT up -d --build --scale agent=2"
  dc up -d --build --scale agent=2 2>&1 | tail -5 | tee -a "$OUT"
  wait_http http://localhost:8080/health 180
  sleep 10
  cmd "docker compose -p $PROJECT ps"
  dc ps 2>&1 | tee -a "$OUT"
  log "UP — promtool unit test cho alert rules"
  cmd 'docker run --rm -v "$PWD/prometheus:/p" --entrypoint promtool prom/prometheus:v3.16.0 test rules /p/alert_rules_test.yml'
  (cd "$PROD" && docker run --rm -v "$PWD/prometheus:/p" --entrypoint promtool prom/prometheus:v3.16.0 test rules /p/alert_rules_test.yml) 2>&1 | tee -a "$OUT"
  log "UP — /metrics không public qua Nginx (câu hỏi 7.4 số 4)"
  cmd 'curl -i http://localhost:8080/metrics'
  curl -s -i http://localhost:8080/metrics | head -8 | tee -a "$OUT"
  cmd 'curl -i -X POST http://localhost:8080/ask (có key)'
  curl -s -i -X POST http://localhost:8080/ask -H "X-API-Key: day14-lab-key" -H "Content-Type: application/json" \
    -d '{"question":"Trong distributed tracing, span là gì?"}' | head -14 | tee -a "$OUT"
  note ""
  note "Mở các UI qua tab PORTS của Codespaces: 3000 (Grafana), 9090 (Prometheus), 16686 (Jaeger), 8089 (Locust)."
  note "Grafana đăng nhập admin/admin (hoặc xem ẩn danh)."
}

summarize_csv() { # summarize_csv <prefix>
  python - "$PROD/benchmark-results/$1_stats.csv" <<'PY' | tee -a "$OUT"
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1], encoding="utf-8")))
for r in rows:
    if r["Name"] in ("/ask", "Aggregated"):
        print(f"  {r['Name']:<11} requests={r['Request Count']:>6} failures={r['Failure Count']:>5} "
              f"RPS={float(r['Requests/s']):.2f}  p50={r['50%']}ms p95={r['95%']}ms p99={r['99%']}ms avg={float(r['Average Response Time']):.0f}ms")
PY
}

stage_scale() {
  log "SCALE — Locust headless, 100 users, ramp 10/s, 2 phút, 1 instance"
  cmd "docker compose up -d --scale agent=1"
  dc up -d --scale agent=1 2>&1 | tail -2 | tee -a "$OUT"
  sleep 25
  cmd "docker compose run --rm locust ... --headless -u 100 -r 10 -t 2m --csv /mnt/results/scale_1"
  note ">>> Trong lúc này (2 phút) mở Grafana (cổng 3000) và CHỤP dashboard khi đang có tải -> screenshots/grafana-dashboard.png"
  dc run --rm locust -f /mnt/locust/locustfile.py --host http://nginx --headless -u 100 -r 10 -t 2m --csv /mnt/results/scale_1 2>&1 | tail -3 | tee -a "$OUT"
  note "Kết quả scale_1:"; summarize_csv scale_1

  log "SCALE — 3 instance"
  cmd "docker compose up -d --scale agent=3"
  dc up -d --scale agent=3 2>&1 | tail -2 | tee -a "$OUT"
  sleep 30
  cmd "kiểm tra Prometheus thấy 3 target:"
  pq 'count(up{job="agent"} == 1)' | tee -a "$OUT"
  cmd "docker compose run --rm locust ... --headless -u 100 -r 10 -t 2m --csv /mnt/results/scale_3"
  dc run --rm locust -f /mnt/locust/locustfile.py --host http://nginx --headless -u 100 -r 10 -t 2m --csv /mnt/results/scale_3 2>&1 | tail -3 | tee -a "$OUT"
  note "Kết quả scale_3:"; summarize_csv scale_3

  cp -f "$PROD"/benchmark-results/scale_1_stats.csv "$PROD"/benchmark-results/scale_3_stats.csv "$ROOT/benchmark-results/" 2>&1 | tee -a "$OUT"
  note "Đã copy CSV vào benchmark-results/ ở gốc repo."
  log "SCALE — đưa về 2 instance cho các bước sau"
  dc up -d --scale agent=2 2>&1 | tail -2 | tee -a "$OUT"
  sleep 20
}

stage_trace() {
  log "TRACE — tạo tải ngắn (20 user, 90 giây) để có trace chậm và trace lỗi"
  note "(tăng nhẹ tỉ lệ lỗi và chậm để chắc chắn có mẫu: MOCK_ERROR_RATE=0.1, MOCK_SLOW_RATE=0.1)"
  agent_up "MOCK_ERROR_RATE=0.1 MOCK_SLOW_RATE=0.1"
  dc run --rm locust -f /mnt/locust/locustfile.py --host http://nginx --headless -u 20 -r 5 -t 90s 2>&1 | tail -2 | tee -a "$OUT"

  log "TRACE — phân tích trace từ Jaeger API (service observable-agent)"
  curl -s "http://localhost:16686/api/traces?service=observable-agent&limit=500&lookback=1h" > /tmp/jaeger_traces.json
  python - <<'PY' | tee -a "$OUT"
import json
d = json.load(open("/tmp/jaeger_traces.json"))["data"]
print(f"Số trace lấy được: {len(d)}")
def info(t):
    spans = t["spans"]
    start = min(s["startTime"] for s in spans)
    end = max(s["startTime"] + s["duration"] for s in spans)
    err = any(tag["key"] == "error" and tag["value"] in (True, "true") for s in spans for tag in s["tags"])
    return (end - start) / 1000.0, err
infos = [(info(t), t) for t in d if t["spans"]]
if not infos:
    print("KHÔNG có trace nào"); raise SystemExit
slow = max(infos, key=lambda x: x[0][0])
print(f"\n== TRACE CHẬM NHẤT ==\ntrace_id = {slow[1]['traceID']}\ntổng thời gian = {slow[0][0]:.1f} ms")
tot = slow[0][0]
for s in sorted(slow[1]["spans"], key=lambda s: -s["duration"]):
    print(f"  span {s['operationName']:<28} {s['duration']/1000:8.1f} ms  ({s['duration']/1000/tot*100:5.1f}% của trace)")
errs = [x for x in infos if x[0][1]]
print(f"\nSố trace có error=true: {len(errs)}")
if errs:
    e = max(errs, key=lambda x: x[0][0])
    print(f"== TRACE LỖI ==\ntrace_id = {e[1]['traceID']}\ntổng thời gian = {e[0][0]:.1f} ms")
    for s in e[1]["spans"]:
        evs = [lg for lg in s.get("logs", []) for f in lg["fields"] if f["key"] == "event" and f["value"] == "exception"]
        flag = " [error]" if any(t["key"] == "error" for t in s["tags"]) else ""
        print(f"  span {s['operationName']:<28} {s['duration']/1000:8.1f} ms{flag}  exception_events={len(evs)}")
else:
    print("Không có trace lỗi — chạy lại stage trace hoặc tăng MOCK_ERROR_RATE")
PY
  log "TRACE — log JSON có cùng trace_id (grep llm_error)"
  cmd "docker compose logs agent | grep llm_error | head -1"
  LINE=$(dc logs --no-color agent 2>/dev/null | grep llm_error | head -1)
  echo "$LINE" | tee -a "$OUT"
  TID=$(echo "$LINE" | python -c "
import sys, re, json
t = sys.stdin.read()
m = re.search(r'\"trace_id\":\s*\"([0-9a-f]{32})\"', t)
print(m.group(1) if m else '')
")
  if [ -n "$TID" ]; then
    note "trace_id trong log = $TID"
    CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:16686/api/traces/$TID")
    note "Jaeger tìm thấy trace này? HTTP $CODE (200 = có)"
  else
    note "Không tách được trace_id từ log"
  fi
  note ""
  note ">>> MỞ JAEGER (cổng 16686) và CHỤP 2 ảnh:"
  note "    1) Trace chậm nhất (trace_id ở trên) -> screenshots/jaeger-slow-trace.png"
  note "    2) Trace lỗi (trace_id ở trên) thấy event exception -> screenshots/jaeger-error-trace.png"
  note "    Dán trace_id vào ô 'Lookup by Trace ID' hoặc mở http://localhost:16686/trace/<trace_id>"
  pause_for_screenshot "Chụp 2 ảnh Jaeger"
  log "TRACE — trả cấu hình về mặc định"
  agent_up "MOCK_ERROR_RATE=0.01 MOCK_SLOW_RATE=0.03"
}

stage_chaos() {
  log "CHAOS — thí nghiệm phá hệ thống (giữ ~30 user Locust chạy nền suốt thời gian này)"
  agent_up "AGENT_VERSION=v2"
  start_load 30
  note "Chờ 90s để có số liệu nền..."
  sleep 90
  note "Alert ở trạng thái nền: $(alerts_state)"
  note "p95 /ask (1m)      : $(pq 'histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{job="agent", route="/ask"}[1m])))')"
  note "avg /ask (1m)      : $(pq 'sum(rate(http_request_duration_seconds_sum{job="agent", route="/ask"}[1m])) / sum(rate(http_request_duration_seconds_count{job="agent", route="/ask"}[1m]))')"
  note "req/s theo instance: $(pq 'sum by (instance) (rate(http_requests_total{job="agent", route="/ask"}[1m]))')"
  note "tokens/s theo loại : $(pq 'sum by (type) (rate(llm_tokens_total[1m]))')"
  note "cost USD/giờ (5m)  : $(pq 'sum(rate(llm_cost_usd_total{job="agent"}[5m])) * 3600')"
  pause_for_screenshot "Nếu chưa chụp: chụp Grafana đang có tải -> screenshots/grafana-dashboard.png"

  log "THÍ NGHIỆM A — MOCK_ERROR_RATE=0.2 (mong đợi AgentHighErrorRate)"
  agent_up "MOCK_ERROR_RATE=0.2"
  wait_firing AgentHighErrorRate 300
  note "  error rate 1m: $(pq 'sum(rate(http_requests_total{job="agent", route="/ask", status=~"5.."}[1m])) / sum(rate(http_requests_total{job="agent", route="/ask"}[1m]))')"
  agent_up "MOCK_ERROR_RATE=0.01"; wait_clear

  log "THÍ NGHIỆM B — MOCK_SLOW_RATE=0.3 (mong đợi AgentHighLatencyP95)"
  agent_up "MOCK_SLOW_RATE=0.3"
  wait_firing AgentHighLatencyP95 360
  note "  p95 1m: $(pq 'histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{job="agent", route="/ask"}[1m])))')"
  agent_up "MOCK_SLOW_RATE=0.03"; wait_clear

  log "THÍ NGHIỆM C — LLM_MODEL=mock-llm-large (mong đợi LLMCostBurnRateHigh)"
  note "  (lưu ý: ở trạng thái nền, cost/giờ = $(pq 'sum(rate(llm_cost_usd_total{job="agent"}[5m])) * 3600'))"
  agent_up "LLM_MODEL=mock-llm-large"
  wait_firing LLMCostBurnRateHigh 480
  note "  cost USD/giờ (5m): $(pq 'sum(rate(llm_cost_usd_total{job="agent"}[5m])) * 3600')"
  agent_up "LLM_MODEL=mock-llm-small"; wait_clear

  log "THÍ NGHIỆM D — docker pause 1 instance (mong đợi AgentInstanceDown)"
  VICTIM=$(cd "$PROD" && docker compose -p "$PROJECT" ps -q agent | head -1)
  note "  pause container $VICTIM"
  docker pause "$VICTIM" >/dev/null
  wait_firing AgentInstanceDown 180
  note "  tỉ lệ 5xx mà agent tự thấy: $(pq 'sum(rate(http_requests_total{job="agent", route="/ask", status=~"5.."}[1m])) / sum(rate(http_requests_total{job="agent", route="/ask"}[1m]))')"
  note "  (504 do Nginx không nằm trong metric của agent — xem câu hỏi trong README mục 2.6)"
  docker unpause "$VICTIM" >/dev/null; note "  unpause xong"; wait_clear

  log "THÍ NGHIỆM E — AGENT_VERSION=v1 (mong đợi KHÔNG alert nào firing)"
  agent_up "AGENT_VERSION=v1"
  note "  chờ 150s rồi xem alert..."
  sleep 150
  note "  alert sau 150s: $(alerts_state)"
  note "  retrieval/tokens/s: $(pq 'sum by (type) (rate(llm_tokens_total[1m]))')"
  agent_up "AGENT_VERSION=v2"; sleep 30

  log "THÍ NGHIỆM F — 2 alert CÙNG firing để chụp ảnh (MOCK_ERROR_RATE=0.2 + MOCK_SLOW_RATE=0.3)"
  agent_up "MOCK_ERROR_RATE=0.2 MOCK_SLOW_RATE=0.3"
  wait_firing AgentHighErrorRate 300
  wait_firing AgentHighLatencyP95 420
  note "  trạng thái alert lúc này: $(alerts_state)"
  note ">>> MỞ PROMETHEUS (cổng 9090) -> tab Alerts, thấy >= 2 alert màu đỏ FIRING cùng lúc."
  note ">>> CHỤP ảnh -> screenshots/prometheus-alert-firing.png"
  pause_for_screenshot "Chụp trang Alerts của Prometheus khi đang có >= 2 alert FIRING"

  log "CHAOS — dọn và trả cấu hình mặc định"
  stop_load
  agent_up "MOCK_ERROR_RATE=0.01 MOCK_SLOW_RATE=0.03 LLM_MODEL=mock-llm-small AGENT_VERSION=v2"
  note "XONG chaos. Alert hiện tại: $(alerts_state)"
}

stage_down() {
  log "DOWN — dọn stack"
  stop_load
  dc down -v 2>&1 | tail -3 | tee -a "$OUT"
}

case "${1:-}" in
  up) stage_up ;;
  scale) stage_scale ;;
  trace) stage_trace ;;
  chaos) stage_chaos ;;
  down) stage_down ;;
  *) echo "Cách dùng: bash scripts/part7.sh {up|scale|trace|chaos|down}"; exit 1 ;;
esac
