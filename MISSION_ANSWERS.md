# Day 14 Lab — Mission Answers

> **Trạng thái:** Part 1, Part 4 đã làm và đo thật (chạy trên Windows, Python 3.14, không Docker). Part 2, Part 3, Part 5 và phần output `check_production_ready.py` đầy đủ **chưa làm**, vì máy chưa chạy được Docker/WSL2. Các mục đó được đánh dấu `TODO` bên dưới.

---

## Part 1: Localhost vs Production

### Exercise 1.1: Anti-patterns found (`01-localhost-vs-production/develop/app.py`)

1. **API key hardcode trong code** (dòng 17): `OPENAI_API_KEY = "sk-hardcoded-fake-key-never-do-this"`. Push lên GitHub là lộ key.
2. **Connection string kèm mật khẩu hardcode** (dòng 18): `postgresql://admin:password123@localhost:5432/mydb`.
3. **Log ra secret** (dòng 34): `print(f"[DEBUG] Using key: {OPENAI_API_KEY}")`. Khi chạy thật, log thực sự in key ra (xem bên dưới). Log thường được đẩy sang hệ thống tập trung nên key bị lộ rộng hơn.
4. **Config cố định, không đọc từ môi trường** (dòng 21–22): `DEBUG = True`, `MAX_TOKENS = 500`. Muốn đổi giữa dev/staging/production phải sửa code.
5. **Dùng `print()` thay vì logging có cấu trúc** (dòng 33, 36, 38): không có level, không có timestamp, không parse được bằng log aggregator.
6. **Không có health check** (dòng 42–43): platform không biết agent còn sống hay không để restart. Bằng chứng: `GET /health` trả **404**.
7. **Port cố định** (dòng 52): `port=8000`. Railway/Render cấp port qua biến `PORT`.
8. **Bind vào `localhost`** (dòng 51): từ ngoài container không truy cập được. Cần `0.0.0.0`.
9. **`reload=True`** (dòng 53): chế độ reload dành cho dev, không nên bật ở production.
10. **Không xử lý shutdown** và **không validate input**: `question` là query parameter không giới hạn độ dài.

### Exercise 1.2: Chạy bản develop

Chạy `python app.py` rồi gọi (bản develop nhận `question` qua query, không nhận JSON):

```text
$ curl -s -i http://localhost:8000/
HTTP/1.1 200 OK
{"message":"Hello! Agent is running on my machine :)"}

$ curl -s -i -X POST "http://localhost:8000/ask?question=Hello"
HTTP/1.1 200 OK
{"answer":"Agent đang hoạt động tốt! (mock response) Hỏi thêm câu hỏi đi nhé."}

$ curl -s -i -X POST http://localhost:8000/ask -H "Content-Type: application/json" -d '{"question":"Hello"}'
HTTP/1.1 422 Unprocessable Content
{"detail":[{"type":"missing","loc":["query","question"],"msg":"Field required","input":null}]}

$ curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/health
404
```

Log của server khi gọi `/ask` (đây là bằng chứng của anti-pattern số 3):

```text
[DEBUG] Got question: Hello
[DEBUG] Using key: sk-hardcoded-fake-key-never-do-this
[DEBUG] Response: Agent đang hoạt động tốt! (mock response) Hỏi thêm câu hỏi đi nhé.
```

Nó chạy được, nhưng chưa production-ready: lộ key, không có health check, không đọc port từ môi trường.

### Exercise 1.3: Comparison table (`develop/app.py` so với `production/app.py`)

| Feature | Develop | Production | Why Important? |
|---|---|---|---|
| Config | Hardcode trong code (dòng 17–22) | Đọc từ biến môi trường qua `config.py` (`os.getenv`) | Cùng một image chạy được ở dev, staging, production; secret không nằm trong git |
| Secrets | Key và mật khẩu DB nằm trong code, bị in ra log | Không có secret trong code; log không in key | Tránh lộ khi push repo hoặc khi log được thu thập tập trung |
| Health check | Không có (`/health` → 404) | `GET /health` (liveness, trả 200 kèm uptime) và `GET /ready` (readiness, 503 khi chưa sẵn sàng) | Platform dựa vào đây để restart container hoặc ngừng route traffic |
| Logging | `print()` | `logging` kèm `json.dumps` cho các event (ý định là log JSON) | Có level, parse được bằng Datadog/Loki. Xem lưu ý ngay bên dưới về chỗ nó chưa hoạt động đúng |
| Shutdown | Đột ngột, không có xử lý | `lifespan` + handler SIGTERM, đánh dấu `is_ready = False` rồi mới tắt | Request đang chạy không bị cắt giữa chừng khi platform tắt container |
| Host / port | `localhost`, cổng 8000 cố định | `0.0.0.0`, cổng lấy từ `PORT` | Chạy được trong container và trên Railway/Render |
| Reload | `reload=True` luôn bật | `reload=settings.debug` (mặc định tắt) | Reload tốn tài nguyên và không an toàn ở production |
| Input validation | Không có | Trả 422 khi `question` rỗng (đã thử: `{"detail":"question field is required"}`) | Từ chối input sai rõ ràng, thay vì để lỗi sâu bên trong |
| CORS | Không cấu hình | Giới hạn `allow_origins` theo cấu hình | Chỉ cho các origin được phép gọi |

Kết quả chạy bản production (`python app.py`):

```text
GET  /health  → 200 {"status":"ok","uptime_seconds":5.9,"version":"1.0.0","environment":"development",...}
GET  /ready   → 200 {"ready":true}
POST /ask {"question":"Hello"} → 200 {"question":"Hello","answer":"...","model":"gpt-4o-mini"}
POST /ask {"question":""}      → 422 {"detail":"question field is required"}
```

**Lưu ý — log JSON của bản production không hoạt động như mô tả.** Khi chạy, server chỉ in ra `WARNING:root:OPENAI_API_KEY not set — using mock LLM` (định dạng mặc định của root logger) và không có dòng JSON nào (tôi đếm được 0 dòng chứa `"event"` trong log). Suy luận của tôi: `config.py` gọi `logging.warning(...)` ngay lúc import (`settings = Settings().validate()`), trước khi `logging.basicConfig(...)` trong `app.py` chạy. Lệnh `logging.warning` ở mức root tự cấu hình logger, nên `basicConfig` sau đó không có tác dụng, và log mức INFO bị bỏ. Tôi chưa chạy thử bản sửa để xác nhận nguyên nhân này. Bài học là phải kiểm tra output thật của logging thay vì tin vào comment. Ở Part 6, tôi tự viết `JsonFormatter` gắn thẳng vào logger của app (`logger.propagate = False`).

### Checkpoint 1
- Hardcode secret nguy hiểm vì lộ qua git và log (xem anti-pattern 1–3).
- Config đọc từ env: đã thấy ở `config.py`.
- Health check cho platform biết khi nào restart (liveness) hoặc ngừng route traffic (readiness).
- Graceful shutdown: khi nhận SIGTERM, ngừng nhận request mới nhưng hoàn thành request đang chạy.

---

## Part 2: Docker

**TODO — chưa làm.** Cần Docker để đo kích thước image (`docker images`) và chạy stack Compose. Không điền số ước lượng.

## Part 3: Cloud Deployment

**TODO — chưa làm.** Cần deploy agent Part 6 lên Railway hoặc Render (cần đăng nhập tài khoản). Các mục cần có: URL public, so sánh `railway.toml` với `render.yaml`, 3–5 dòng về pipeline Cloud Run (đọc `cloudbuild.yaml` và `service.yaml`).

---

## Part 4: API Security

Chạy với cổng 8000 (bản develop) và cổng 8010 (bản production, vì cổng 8000 lúc đó bị một socket mồ côi giữ). Token được bỏ khỏi output.

### Exercise 4.1: API Key authentication (`04-api-gateway/develop/app.py`)

- **Key được check ở đâu?** Hàm `verify_api_key` (dòng 39–54), dùng `APIKeyHeader(name="X-API-Key")` và được gắn vào `/ask` bằng `Depends(verify_api_key)`. So sánh với biến môi trường `AGENT_API_KEY` (dòng 35).
- **Sai key thì sao?** Thiếu key → **401**. Sai key → **403** (code tách hai trường hợp). Lưu ý: tiêu chí Part 6 yêu cầu cả hai đều là 401.
- **Rotate key thế nào?** Đổi giá trị `AGENT_API_KEY` rồi restart, không cần sửa code. Nhược điểm: chỉ có một key, nên đổi key làm mọi client cũ ngừng chạy ngay lập tức. Muốn rotate êm cần hỗ trợ nhiều key cùng lúc.
- Lưu ý: nếu không đặt biến, code dùng key mặc định `demo-key-change-in-production`, và còn `print` key ra console khi khởi động (dòng 91).

```text
$ AGENT_API_KEY=secret-key-123 python app.py

# Không có key
HTTP/1.1 401 Unauthorized
{"detail":"Missing API key. Include header: X-API-Key: <your-key>"}

# Sai key
HTTP/1.1 403 Forbidden
{"detail":"Invalid API key."}

# Đúng key
HTTP/1.1 200 OK
{"question":"Hello","answer":"Đây là câu trả lời từ AI agent (mock). Trong production, ..."}

# /health không cần key
HTTP/1.1 200 OK
{"status":"ok"}
```

### Exercise 4.2: JWT authentication (`04-api-gateway/production/auth.py`)

**Luồng JWT:** client gửi `POST /auth/token` với username/password → server kiểm tra (`authenticate_user`) và tạo token HS256 chứa `sub`, `role`, `iat`, `exp` (hết hạn sau 60 phút) → client gửi `Authorization: Bearer <token>` → server kiểm tra chữ ký và hạn (`verify_token`), không cần tra database.

Khác với `CODE_LAB.md`: endpoint là `/auth/token` (không phải `/token`) và tài khoản là `student` / `demo123`.

```text
POST /ask (không có token)             → 401 {"detail":"Authentication required. Include: Authorization: Bearer <token>"}
POST /token  admin/secret (đường dẫn trong CODE_LAB) → 404 {"detail":"Not Found"}
POST /auth/token student/x (sai mật khẩu)  → 401 {"detail":"Invalid credentials"}
POST /auth/token student/demo123           → 200, token dài 168 ký tự
POST /ask với token giả "abc.def.ghi"      → 403 {"detail":"Invalid token."}
POST /ask với token hợp lệ                 → 200 {"question":"Explain JWT","answer":"...","usage":{"requests_remaining":9,"budget_remaining_usd":1.9e-05}}
GET  /admin/stats (student)                → 403 {"detail":"Admin only"}
GET  /admin/stats (teacher)                → 200 {"total_users":"N/A (in-memory demo)","global_cost_usd":0.000472...,"global_budget_usd":10.0}
```

Nhận xét: token hết hạn trả 401, token sai trả 403. Khóa ký có giá trị mặc định hardcode (`super-secret-change-in-production-please`) nếu không đặt `JWT_SECRET`, nên phải đặt biến này khi deploy. Trường `budget_remaining_usd` trong response của `/ask` thực chất là chi phí **đã dùng** (`usage.total_cost_usd`), tên trường gây hiểu lầm.

### Exercise 4.3: Rate limiting (`04-api-gateway/production/rate_limiter.py`)

- **Algorithm:** sliding window theo timestamp: mỗi user có một `deque` ghi thời điểm các request; mỗi lần gọi, bỏ các timestamp cũ hơn 60 giây rồi đếm số còn lại.
- **Limit:** user 10 request/phút (`rate_limiter_user`), admin 100 request/phút (`rate_limiter_admin`).
- **Bypass cho admin:** không bypass hẳn. Role `admin` (tài khoản `teacher`) dùng limiter có giới hạn cao hơn (100/phút). Chọn limiter ở `app.py` dòng 141.
- **Hạn chế:** state nằm trong RAM của process, nên không dùng chung giữa nhiều instance và mất khi restart. Đây là lý do Part 6 lưu state trong Redis.

Vòng lặp 15 request với token của `student` (trước đó đã có 1 request hợp lệ, nên 10 request đầu của giới hạn đã được dùng ở lần gọi thứ 9 của vòng lặp):

```text
req  1: 200   req  2: 200   req  3: 200   req  4: 200   req  5: 200
req  6: 200   req  7: 200   req  8: 200   req  9: 200
req 10: 429   req 11: 429   req 12: 429   req 13: 429   req 14: 429   req 15: 429
```

Response khi chạm giới hạn:

```text
HTTP/1.1 429 Too Many Requests
x-ratelimit-limit: 10
x-ratelimit-remaining: 0
x-ratelimit-reset: 1795597240
retry-after: 55

{"detail":{"error":"Rate limit exceeded","limit":10,"window_seconds":60,"retry_after_seconds":55}}
```

Với token của `teacher`, 15 request liên tiếp đều trả 200 (giới hạn 100/phút).

### Exercise 4.4: Cost guard

**Cách làm trong `04-api-gateway/production/cost_guard.py` (bản có sẵn):** lớp `CostGuard` lưu usage theo user trong RAM (`UsageRecord`), tính chi phí từ token (`$0.00015/1K input`, `$0.0006/1K output`). `check_budget` chạy **trước** khi gọi LLM: vượt budget ngày của user ($1) → **402**, vượt budget toàn hệ thống ($10/ngày) → **503**; từ 80% thì ghi cảnh báo. `record_usage` chạy **sau** khi gọi LLM để cộng dồn chi phí. Đã thử: `GET /me/usage` trả `cost_usd: 0.000191` sau 10 request.

**Cách làm ở Part 6 (`06-lab-complete/app/cost_guard.py`, do tôi viết):**
- Chi phí cộng dồn trong **Redis** bằng `INCRBYFLOAT` vào hai key `cost:day:YYYY-MM-DD` và `cost:month:YYYY-MM`, có `EXPIRE` (2 ngày và 32 ngày), nên tự reset khi sang ngày/tháng mới và dùng chung giữa các instance.
- `check_budget()` chạy trước khi gọi LLM: nếu tổng ngày ≥ `DAILY_BUDGET_USD` hoặc tổng tháng ≥ `MONTHLY_BUDGET_USD` → **402**. `record_cost()` chạy sau khi gọi LLM.
- Redis lỗi khi kiểm tra → 503 (không cho đi tiếp mà không kiểm soát được chi phí); lỗi khi ghi chi phí thì bỏ qua để không làm hỏng response đã phục vụ.
- Khác bản mẫu: bản Part 6 tính budget **toàn cục** (theo yêu cầu của script chấm), chưa theo từng user.
- Hạn chế đã biết: "kiểm tra rồi mới ghi" không nguyên tử, nên nhiều request đồng thời có thể vượt budget một chút. Muốn chặt hơn thì phải giữ chỗ (reserve) chi phí ước tính trước khi gọi LLM.
- Đã test logic bằng fakeredis (không phải Redis thật): đặt budget rất nhỏ thì request 1 trả 200, các request sau trả 402.

**Vì sao cần cả rate limit lẫn cost guard:** rate limit bảo vệ tốc độ (chống spam, quá tải), cost guard bảo vệ tiền (một người gọi chậm nhưng prompt rất dài vẫn có thể đốt budget).

---

## Part 5: Scaling & Reliability

**TODO — chưa làm.** Cần Docker Compose (`--scale agent=3`) cho Exercise 5.4 và 5.5.

---

## Part 6: Final Project

- Code đã viết trong `06-lab-complete/` (xem git log).
- `python check_production_ready.py --static-only` cho kết quả `28/28 checks passed`; 3/12 tiêu chí đã xác nhận (Docker compose, `.dockerignore`, Public URL config), 9 tiêu chí còn ⚠️ vì cần chạy thật.
- **Output `check_production_ready.py` đầy đủ (`PASS 12/12`): TODO.** Phải chạy trên Linux/WSL2 có Docker. Không dán kết quả giả.

## Part 7

Xem `BENCHMARK_REPORT.md`. Bước 1 (local) đã làm; Bước 2 (Docker stack) chưa làm.

---

## AI log

| # | Hỏi / nhờ AI | AI trả lời / làm gì | Tôi tự kiểm tra thế nào |
|---|---|---|---|
| 1 | Đọc các file đề bài và liệt kê yêu cầu | Tóm tắt checkpoint, cấu trúc nộp bài, thang điểm | Đối chiếu với `README.md`, `CHECKPOINTS.md`, `RUBRIC.md` |
| 2 | Chẩn đoán lỗi Docker/WSL2 | Phát hiện `HypervisorPresent=False`, đề xuất bật Virtual Machine Platform | Cần tự chạy lệnh bằng quyền Admin và khởi động lại máy |
| 3 | Viết code Part 6 (`app/*.py`, Dockerfile, compose, railway.toml, render.yaml) | AI viết toàn bộ các file `TODO` | Chạy `check_production_ready.py --static-only` (28/28); test hành vi bằng fakeredis. **Chưa** build Docker, chưa test SIGTERM |
| 4 | Part 7 Bước 1: load test, eval, sửa `KNOWLEDGE_BASE` | AI chạy các lệnh và thêm 2 entry (HPA, JWT) | Số liệu lấy từ file JSON trong `reports/`; eval v2 sau khi sửa đạt 23/23, 0 regression |
| 5 | Part 1 và Part 4: chạy bài tập và viết câu trả lời | AI chạy các lệnh curl trên máy và ghi output | Output ở trên là kết quả chạy thật; phần nhận xét tôi cần đọc lại và tự giải thích được |

> Ghi chú: mục AI log cần được tôi xem lại và tự giải thích được từng đoạn code trước khi nộp (theo RULES.md).
