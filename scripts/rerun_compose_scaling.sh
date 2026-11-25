#!/usr/bin/env bash
# Chạy lại Exercise 2.4 (compose stack) và Exercise 5.4/5.5 (scaling) trong Codespaces.
#   bash scripts/rerun_compose_scaling.sh
# Khác bản trước: chờ tới khi nhận HTTP 200 THẬT (không coi 502 là sẵn sàng),
# in log nginx/agent nếu còn lỗi, và giữ log gọn (không có tiến trình pull/build).
# Output: evidence/part2_part5_rerun.log

set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
mkdir -p evidence
OUT="$ROOT/evidence/part2_part5_rerun.log"
: > "$OUT"

log() { printf '\n### %s\n' "$*" | tee -a "$OUT"; }
sh_run() { printf '$ %s\n' "$1" >> "$OUT"; printf '$ %s\n' "$1"; bash -c "$1" 2>&1 | tee -a "$OUT"; }
# chờ HTTP 2xx thật; in mã cuối cùng nếu hết giờ
wait_ok() {
  local url="$1" max="${2:-120}" code i
  for ((i = 0; i < max; i++)); do
    code=$(curl -s -o /dev/null -m 3 -w '%{http_code}' "$url")
    [ "$code" = "200" ] && { echo "OK $url sau ~${i}s" | tee -a "$OUT"; return 0; }
    sleep 1
  done
  echo "HẾT GIỜ: $url vẫn trả $code sau ${max}s" | tee -a "$OUT"
  return 1
}

cleanup() {
  (cd "$ROOT/02-docker/production" && docker compose -p k5-day14-stack down -v >/dev/null 2>&1)
  (cd "$ROOT/05-scaling-reliability/production" && docker compose -p k5-day14-scaling down -v >/dev/null 2>&1)
}
trap cleanup EXIT
cleanup

# ============================================================
log "PART 2 / Exercise 2.4 — Docker Compose stack"
touch 02-docker/production/.env.local
sh_run 'cd 02-docker/production && docker compose --progress quiet -p k5-day14-stack up -d --build 2>&1 | grep -v "attribute .version. is obsolete"'
if wait_ok http://localhost/health 120; then
  sh_run 'cd 02-docker/production && docker compose -p k5-day14-stack ps'
  sh_run 'curl -s -i http://localhost/health'
  echo | tee -a "$OUT"
  sh_run 'curl -s -i -X POST http://localhost/ask -H "Content-Type: application/json" -d "{\"question\":\"Explain microservices\"}"'
  echo | tee -a "$OUT"
else
  sh_run 'cd 02-docker/production && docker compose -p k5-day14-stack ps'
  sh_run 'cd 02-docker/production && docker compose -p k5-day14-stack logs --no-color --tail=30 agent nginx'
fi
sh_run 'cd 02-docker/production && docker compose -p k5-day14-stack logs --no-color --tail=10 agent'
sh_run 'cd 02-docker/production && docker compose -p k5-day14-stack down -v'

# ============================================================
log "PART 5 / Exercise 5.4 — Nginx load balancer, 3 instance"
touch 05-scaling-reliability/production/.env.local
sh_run 'cd 05-scaling-reliability/production && docker compose --progress quiet -p k5-day14-scaling up -d --build --scale agent=3 2>&1 | grep -v "attribute .version. is obsolete"'
if wait_ok http://localhost:8080/health 120; then
  sleep 3
  sh_run 'cd 05-scaling-reliability/production && docker compose -p k5-day14-scaling ps'
  # kiểm tra /chat có sống thật không trước khi chạy vòng lặp
  sh_run 'curl -s -i -X POST http://localhost:8080/chat -H "Content-Type: application/json" -d "{\"question\":\"probe\"}" | head -20'
  echo | tee -a "$OUT"

  log "PART 5 / Exercise 5.4 — 10 request, xem instance nào phục vụ (served_by)"
  for i in $(seq 1 10); do
    curl -s -X POST http://localhost:8080/chat -H "Content-Type: application/json" \
      -d "{\"question\":\"Request $i\"}" \
      | python -c "import sys,json; d=json.load(sys.stdin); print('request $i ->', d['served_by'])" 2>&1 | tail -1 | tee -a "$OUT"
  done

  log "PART 5 / Exercise 5.5 — test_stateless.py"
  sh_run 'cd 05-scaling-reliability/production && python test_stateless.py 2>&1 | tail -40'

  log "PART 5 / Exercise 5.5 (mở rộng) — dừng 1 instance rồi gọi tiếp cùng session"
  SID=$(curl -s -X POST http://localhost:8080/chat -H "Content-Type: application/json" \
    -d '{"question":"Hello, start a session"}' | python -c "import sys,json; print(json.load(sys.stdin)['session_id'])" 2>/dev/null)
  echo "session_id = $SID" | tee -a "$OUT"
  VICTIM=$(cd 05-scaling-reliability/production && docker compose -p k5-day14-scaling ps -q agent | head -1)
  echo "dừng container: $VICTIM" | tee -a "$OUT"
  docker stop "$VICTIM" 2>&1 | tee -a "$OUT"
  sleep 2
  for i in 1 2 3; do
    curl -s -X POST http://localhost:8080/chat -H "Content-Type: application/json" \
      -d "{\"question\":\"After kill $i\",\"session_id\":\"$SID\"}" \
      | python -c "import sys,json; d=json.load(sys.stdin); print('after kill $i -> served_by', d['served_by'])" 2>&1 | tail -1 | tee -a "$OUT"
  done
  sh_run "curl -s http://localhost:8080/chat/$SID/history | python -c \"import sys,json; d=json.load(sys.stdin); print('messages in history:', d['count'])\" 2>&1 | tail -1"
else
  sh_run 'cd 05-scaling-reliability/production && docker compose -p k5-day14-scaling ps'
  sh_run 'cd 05-scaling-reliability/production && docker compose -p k5-day14-scaling logs --no-color --tail=30 nginx'
  sh_run 'cd 05-scaling-reliability/production && docker compose -p k5-day14-scaling logs --no-color --tail=15 agent'
fi
sh_run 'cd 05-scaling-reliability/production && docker compose -p k5-day14-scaling logs --no-color --tail=40 agent | grep -E "POST|Starting instance|Shutting"'
sh_run 'cd 05-scaling-reliability/production && docker compose -p k5-day14-scaling logs --no-color --tail=15 nginx'
sh_run 'cd 05-scaling-reliability/production && docker compose -p k5-day14-scaling down -v'

log "XONG"
echo "Log đã lưu tại evidence/part2_part5_rerun.log"
