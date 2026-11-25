# Deployment Information

## Public URL
https://k5-l3a-day14-tominhthanh-2a202603439.onrender.com

## Platform
Render (Web Service, runtime Docker, gói Free, region Oregon). Redis dùng Render Key Value (gói Free, cùng region), nối qua Internal Connection URL.

Service được tạo **thủ công** trên dashboard (không dùng Blueprint): Branch `main`, Root Directory `06-lab-complete`, Health Check Path `/health`. Code deploy là commit `d10bdb9` trên `main`.

## Test Commands

```bash
BASE=https://k5-l3a-day14-tominhthanh-2a202603439.onrender.com
AGENT_API_KEY=<key đã đặt trên Render>   # không ghi key vào repo
```

### Health và readiness
```bash
curl -sS -o /dev/null -w '%{http_code}\n' "$BASE/health"   # 200
curl -sS -o /dev/null -w '%{http_code}\n' "$BASE/ready"    # 200 (503 nếu mất Redis)
```

### Không có API key → 401
```bash
curl -sS -o /dev/null -w '%{http_code}\n' -X POST "$BASE/ask" \
  -H 'Content-Type: application/json' -d '{"question":"Hello"}'   # 401
```

### Có API key → 200
```bash
curl -sS -o /dev/null -w '%{http_code}\n' -X POST "$BASE/ask" \
  -H 'Content-Type: application/json' -H "X-API-Key: $AGENT_API_KEY" \
  -d '{"question":"Hello"}'   # 200
```

Kết quả tôi chạy ngày 2026-11-25: `200`, `200`, `401`, `200` (khớp thứ tự 4 lệnh trên).

Lưu ý: gói Free của Render tự tắt service khi không có traffic, nên lần gọi đầu sau một thời gian có thể chậm khoảng một phút. Nên gọi `/health` trước.

## Environment Variables Set (trên Render, giá trị không ghi trong repo)
- `AGENT_API_KEY` (secret, tự đặt)
- `REDIS_URL` (Internal URL của Key Value)
- `ENVIRONMENT` (`production`)
- `RATE_LIMIT_PER_MINUTE`
- `DAILY_BUDGET_USD`
- `MONTHLY_BUDGET_USD`

`PORT` do Render cấp, Dockerfile đọc `${PORT:-8000}`.

## Screenshots
- [Deployment dashboard](screenshots/dashboard.png)
- [Service running](screenshots/running.png)
- [Test results](screenshots/test.png)

> Ba ảnh trên cần được thêm vào thư mục `screenshots/` trước khi nộp (xem mục "Việc còn lại" ở Part 3 trong `MISSION_ANSWERS.md`).
