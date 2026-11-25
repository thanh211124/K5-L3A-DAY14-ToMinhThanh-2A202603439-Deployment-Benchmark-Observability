#!/usr/bin/env bash
# Chạy trong Codespaces (Linux + Docker), từ bất kỳ thư mục nào:
#   bash scripts/part2_part5.sh
# Ghi toàn bộ output thật vào evidence/part2_part5.log để viết MISSION_ANSWERS.md.
# Script không cần secret. Nó tự dọn container/stack khi xong.

set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
mkdir -p evidence
OUT="$ROOT/evidence/part2_part5.log"
: > "$OUT"

log() { printf '\n### %s\n' "$*" | tee -a "$OUT"; }
run() { printf '$ %s\n' "$*" >> "$OUT"; printf '$ %s\n' "$*"; "$@" 2>&1 | tee -a "$OUT"; }
sh_run() { printf '$ %s\n' "$1" >> "$OUT"; printf '$ %s\n' "$1"; bash -c "$1" 2>&1 | tee -a "$OUT"; }
wait_http() { # url, max seconds
  local i
  for ((i = 0; i < ${2:-60}; i++)); do
    curl -s -o /dev/null -m 2 "$1" && return 0
    sleep 1
  done
  echo "TIMEOUT waiting for $1" | tee -a "$OUT"
  return 1
}

cleanup() {
  docker rm -f k5-p2-dev k5-p2-adv >/dev/null 2>&1
  (cd "$ROOT/02-docker/production" && docker compose -p k5-day14-stack down -v >/dev/null 2>&1)
  (cd "$ROOT/05-scaling-reliability/production" && docker compose -p k5-day14-scaling down -v >/dev/null 2>&1)
  [ -n "${DEV_PID:-}" ] && kill "$DEV_PID" 2>/dev/null
}
trap cleanup EXIT

log "Môi trường"
run uname -a
run docker --version
run docker compose version
run python --version

# ============================================================
# PART 2 — DOCKER
# ============================================================
log "PART 2 / Exercise 2.2 — build bản develop (single-stage)"
run docker build -f 02-docker/develop/Dockerfile -t my-agent:develop .

log "PART 2 / Exercise 2.3 — build bản production (multi-stage)"
run docker build -f 02-docker/production/Dockerfile -t my-agent:advanced .

log "PART 2 / Kích thước image (đo bằng docker images)"
run docker images my-agent --format 'table {{.Repository}}:{{.Tag}}\t{{.Size}}'
DEV_B=$(docker image inspect -f '{{.Size}}' my-agent:develop)
ADV_B=$(docker image inspect -f '{{.Size}}' my-agent:advanced)
python - "$DEV_B" "$ADV_B" <<'PY' | tee -a "$OUT"
import sys
d, a = int(sys.argv[1]), int(sys.argv[2])
print(f"develop  = {d} bytes = {d/1e6:.1f} MB")
print(f"advanced = {a} bytes = {a/1e6:.1f} MB")
print(f"giảm {(d-a)/d*100:.1f}% so với develop (advanced = {a/d*100:.1f}% kích thước develop)")
PY

log "PART 2 / Exercise 2.2 — chạy container develop và gọi API"
run docker run -d --name k5-p2-dev -p 8000:8000 my-agent:develop
wait_http http://localhost:8000/ 40
sh_run 'curl -s -i -X POST "http://localhost:8000/ask?question=What%20is%20Docker"'
echo | tee -a "$OUT"
run docker logs k5-p2-dev
run docker rm -f k5-p2-dev

log "PART 2 / Exercise 2.3 — chạy container advanced, kiểm tra non-root"
run docker run -d --name k5-p2-adv -p 8001:8000 my-agent:advanced
wait_http http://localhost:8001/health 40
sh_run 'curl -s -i http://localhost:8001/health'
echo | tee -a "$OUT"
sh_run 'curl -s -i -X POST http://localhost:8001/ask -H "Content-Type: application/json" -d "{\"question\":\"What is Docker?\"}"'
echo | tee -a "$OUT"
run docker exec k5-p2-adv whoami
run docker rm -f k5-p2-adv

log "PART 2 / Exercise 2.4 — Docker Compose stack (agent + redis + qdrant + nginx)"
touch 02-docker/production/.env.local
sh_run 'cd 02-docker/production && docker compose -p k5-day14-stack up -d --build'
wait_http http://localhost/health 90
sh_run 'cd 02-docker/production && docker compose -p k5-day14-stack ps'
sh_run 'curl -s -i http://localhost/health'
echo | tee -a "$OUT"
sh_run 'curl -s -i -X POST http://localhost/ask -H "Content-Type: application/json" -d "{\"question\":\"Explain microservices\"}"'
echo | tee -a "$OUT"
sh_run 'cd 02-docker/production && docker compose -p k5-day14-stack logs --no-color --tail=15 agent'
sh_run 'cd 02-docker/production && docker compose -p k5-day14-stack down -v'

# ============================================================
# PART 5 — SCALING & RELIABILITY
# ============================================================
log "PART 5 / Exercise 5.1 — health và readiness (bản develop, chạy trực tiếp bằng Python)"
python -m pip install -q fastapi uvicorn psutil 2>&1 | tail -2 | tee -a "$OUT"
( cd 05-scaling-reliability/develop; python app.py > /tmp/p5dev.log 2>&1 & echo $! > /tmp/p5dev.pid )
DEV_PID=$(cat /tmp/p5dev.pid)
wait_http http://localhost:8000/health 40
sh_run 'curl -s -i http://localhost:8000/health'
echo | tee -a "$OUT"
sh_run 'curl -s -i http://localhost:8000/ready'
echo | tee -a "$OUT"

log "PART 5 / Exercise 5.2 — SIGTERM khi đang có request: request có hoàn thành không?"
( curl -s -i -m 20 -X POST "http://localhost:8000/ask?question=Long%20task" > /tmp/p5_inflight.txt 2>&1 ) &
CURL_PID=$!
sleep 0.03
echo '$ kill -TERM <pid của python app.py>' | tee -a "$OUT"
kill -TERM "$DEV_PID"
wait "$CURL_PID" 2>/dev/null
for _ in $(seq 1 40); do kill -0 "$DEV_PID" 2>/dev/null || break; sleep 0.5; done
if kill -0 "$DEV_PID" 2>/dev/null; then echo "process VẪN CÒN sau 20s" | tee -a "$OUT"; else echo "process đã thoát" | tee -a "$OUT"; fi
echo "--- response của request đang chạy lúc nhận SIGTERM:" | tee -a "$OUT"
cat /tmp/p5_inflight.txt | tee -a "$OUT"
echo | tee -a "$OUT"
echo "--- log của server:" | tee -a "$OUT"
cat /tmp/p5dev.log | tee -a "$OUT"
DEV_PID=""

log "PART 5 / Exercise 5.4 — Nginx load balancer, 3 instance"
touch 05-scaling-reliability/production/.env.local
sh_run 'cd 05-scaling-reliability/production && docker compose -p k5-day14-scaling up -d --build --scale agent=3'
wait_http http://localhost:8080/health 90
sleep 5
sh_run 'cd 05-scaling-reliability/production && docker compose -p k5-day14-scaling ps'

log "PART 5 / Exercise 5.4 — 10 request, xem instance nào phục vụ (served_by)"
for i in $(seq 1 10); do
  curl -s -X POST http://localhost:8080/chat -H "Content-Type: application/json" \
    -d "{\"question\":\"Request $i\"}" \
    | python -c "import sys,json; d=json.load(sys.stdin); print('request $i ->', d['served_by'])" 2>&1 | tee -a "$OUT"
done

log "PART 5 / Exercise 5.5 — test_stateless.py"
sh_run 'cd 05-scaling-reliability/production && python test_stateless.py'

log "PART 5 / Exercise 5.5 (mở rộng) — dừng 1 instance rồi gọi tiếp cùng session"
SID=$(curl -s -X POST http://localhost:8080/chat -H "Content-Type: application/json" \
  -d '{"question":"Hello, start a session"}' | python -c "import sys,json; print(json.load(sys.stdin)['session_id'])")
echo "session_id = $SID" | tee -a "$OUT"
VICTIM=$(cd 05-scaling-reliability/production && docker compose -p k5-day14-scaling ps -q agent | head -1)
echo "dừng container: $VICTIM" | tee -a "$OUT"
docker stop "$VICTIM" 2>&1 | tee -a "$OUT"
sleep 2
for i in 1 2 3; do
  curl -s -X POST http://localhost:8080/chat -H "Content-Type: application/json" \
    -d "{\"question\":\"After kill $i\",\"session_id\":\"$SID\"}" \
    | python -c "import sys,json; d=json.load(sys.stdin); print('after kill $i -> served_by', d['served_by'])" 2>&1 | tee -a "$OUT"
done
sh_run "curl -s http://localhost:8080/chat/$SID/history | python -c \"import sys,json; d=json.load(sys.stdin); print('messages in history:', d['count'])\""
sh_run 'cd 05-scaling-reliability/production && docker compose -p k5-day14-scaling logs --no-color --tail=6 agent'
sh_run 'cd 05-scaling-reliability/production && docker compose -p k5-day14-scaling down -v'

log "XONG"
echo "Log đã lưu tại evidence/part2_part5.log"
