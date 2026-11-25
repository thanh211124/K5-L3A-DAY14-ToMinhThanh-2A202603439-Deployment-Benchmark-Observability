# Day 14 Lab — Mission Answers

> **Trạng thái:** Part 1, Part 4 đã làm và đo thật (chạy trên Windows, Python 3.14, không Docker). Part 6 đạt `PASS 12/12` (chạy trong Codespaces). Part 3 đã deploy lên Render (có 3 ảnh). Part 2 và Part 5 đã chạy trong Codespaces và ghi số đo thật. Phần còn thiếu của cả bài là Part 7 Bước 2 (xem `BENCHMARK_REPORT.md`).

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

Số liệu lấy từ lần chạy trong GitHub Codespaces (Linux, Docker 29.9, Compose v5.6): `evidence/part2_part5.log` (build, kích thước, SIGTERM) và `evidence/part2_part5_rerun.log` (compose, scaling).

### Exercise 2.1: Dockerfile cơ bản (`02-docker/develop/Dockerfile`)

1. **Base image:** `python:3.11` (bản đầy đủ, không phải `-slim`).
2. **Working directory:** `/app` (`WORKDIR /app`).
3. **Vì sao `COPY requirements.txt` trước:** Docker cache theo từng layer. Nếu chỉ đổi code mà `requirements.txt` không đổi thì layer `pip install` được dùng lại, build nhanh hơn nhiều. Copy toàn bộ code trước sẽ làm cache của bước cài thư viện bị vô hiệu mỗi lần sửa code.
4. **`CMD` và `ENTRYPOINT`:** `CMD` là lệnh mặc định và bị thay thế hoàn toàn nếu truyền lệnh khác khi `docker run`; `ENTRYPOINT` là lệnh cố định của container, tham số truyền thêm khi `docker run` được nối vào làm đối số. (Đây là kiến thức chung, không đo trong lab; Dockerfile này chỉ dùng `CMD ["python", "app.py"]`.)

### Exercise 2.2: Build và run (bản develop)

```text
$ docker run -d --name k5-p2-dev -p 8000:8000 my-agent:develop
$ curl -s -i -X POST "http://localhost:8000/ask?question=What%20is%20Docker"
HTTP/1.1 200 OK
{"answer":"Container là cách đóng gói app để chạy ở mọi nơi. Build once, run anywhere!"}
```

(Bản develop nhận `question` qua query string, không nhận JSON.)

### Exercise 2.3: Multi-stage build (`02-docker/production/Dockerfile`)

- **Stage 1 (`builder`):** `python:3.11-slim`, cài `gcc` và `libpq-dev` (công cụ build), rồi `pip install --user` vào `/root/.local`. Image này chỉ để build, không dùng để chạy.
- **Stage 2 (`runtime`):** `python:3.11-slim` mới, tạo user `appuser` (non-root), chỉ copy `/root/.local` (thư viện đã cài) từ stage 1 cùng `main.py` và `utils/mock_llm.py`, thêm `HEALTHCHECK`, chạy `uvicorn ... --workers 2`.
- **Vì sao nhỏ hơn:** (1) base `-slim` thay vì bản đầy đủ; (2) `gcc`, `libpq-dev` và bộ nhớ đệm apt chỉ nằm ở stage builder và không được copy sang stage cuối; (3) `--no-cache-dir` nên không giữ cache pip. Ngoài kích thước, stage cuối còn chạy bằng user không phải root.

**Kích thước image (đo bằng `docker images` / `docker image inspect`):**

| Image | Kích thước |
|---|---|
| `my-agent:develop` (single-stage, `python:3.11`) | 1668.2 MB (1.67 GB) |
| `my-agent:advanced` (multi-stage, `-slim`) | 240.2 MB |
| **Chênh lệch** | **nhỏ hơn 85.6%** (advanced bằng 14.4% develop) |

Kiểm tra bảo mật: `docker exec k5-p2-adv whoami` trả `appuser`, tức container production không chạy bằng root. `GET /health` của bản advanced trả 200.

### Exercise 2.4: Docker Compose stack (`02-docker/production/docker-compose.yml`)

**Kiến trúc (4 service trong network `internal`):**

```text
 client --:80--> nginx (reverse proxy, rate limit 10 r/s)
                   |  proxy_pass http://agent:8000
                   v
                 agent (FastAPI, uvicorn --workers 2)
                   |  depends_on (condition: service_healthy)
          +--------+---------+
          v                  v
   redis:7-alpine      qdrant:v1.9.0
   (volume redis_data) (volume qdrant_data)

 Tất cả nằm trong network "internal"; chỉ nginx mở cổng 80/443 ra ngoài.
```

- Chỉ `nginx` mở cổng ra ngoài (80 và 443); `agent`, `redis`, `qdrant` chỉ nói chuyện với nhau qua network `internal` bằng tên service (DNS của Docker). `agent` chỉ khởi động khi `redis` và `qdrant` đã `healthy`.
- **Lưu ý:** trong code `02-docker/production/main.py` tôi không tìm thấy chỗ nào dùng Redis hay Qdrant (`grep` không ra kết quả), nên với bài này hai service đó được dựng lên nhưng agent chưa gọi tới chúng.

```text
$ docker compose -p k5-day14-stack ps
agent-1   Up (health: starting)   8000/tcp
nginx-1   Up                      0.0.0.0:80->80/tcp, 0.0.0.0:443->443/tcp
qdrant-1  Up (healthy)            6333-6334/tcp
redis-1   Up (healthy)            6379/tcp

$ curl -s -i http://localhost/health        -> HTTP/1.1 200 OK  {"status":"ok","uptime_seconds":0.7,"version":"2.0.0",...}
$ curl -s -i -X POST http://localhost/ask -H "Content-Type: application/json" -d '{"question":"Explain microservices"}'
                                             -> HTTP/1.1 200 OK  {"answer":"Agent đang hoạt động tốt! (mock response) ..."}
```

Response đi qua Nginx có header `X-Frame-Options: DENY` và `X-Content-Type-Options: nosniff`. Log của agent cho thấy `--workers 2` (hai dòng `Agent ready`).

Ghi chú về lần chạy đầu: lần đầu `curl` qua Nginx trả **502** vì script của tôi gọi khi uvicorn chưa khởi động xong (script chờ sai điều kiện: coi mọi phản hồi HTTP là sẵn sàng). Chạy lại sau khi chờ `/health` trả 200 thật thì cả hai lệnh cho 200.

### Checkpoint 2
- Cấu trúc Dockerfile: base, workdir, copy requirements trước để cache, copy code, `CMD`.
- Multi-stage giảm 85.6% kích thước ở bài này.
- Docker Compose dựng 4 service, có healthcheck và `depends_on` theo trạng thái `healthy`.
- Debug container: đã dùng `docker logs`, `docker exec` (`whoami`), `docker compose logs`.

## Part 3: Cloud Deployment

### Exercise 3.2: Deploy lên Render (agent Part 6)

- **URL:** https://k5-l3a-day14-tominhthanh-2a202603439.onrender.com
- Tạo Web Service thủ công trên Render (runtime Docker, gói Free, region Oregon, Root Directory `06-lab-complete`) và một Key Value (Redis) Free cùng region. `REDIS_URL` trỏ tới Internal URL của Key Value; `AGENT_API_KEY` và các biến khác đặt trên dashboard, không ghi trong code. Chi tiết trong `DEPLOYMENT.md`.
- Kết quả 4 lệnh tự kiểm: `/health` 200, `/ready` 200, `/ask` không key 401, `/ask` có key 200.
- Ảnh: [dashboard](screenshots/dashboard.png), [running](screenshots/running.png), [test](screenshots/test.png).
- Tôi **không dùng `render.yaml`** để deploy (đã tạo từng dịch vụ thủ công trên dashboard). Nội dung `render.yaml` vẫn được script chấm kiểm tra tĩnh (tiêu chí 12), nhưng tôi chưa chạy Blueprint nên chưa xác nhận nó deploy được.
- **Sự cố trong lúc deploy:** lần đầu `REDIS_URL` bị đặt sai định dạng (thiếu `redis://`), nên `redis.from_url` ném `ValueError` lúc import và container sập. Tôi sửa `app/redis_client.py` (thêm `redis://` nếu thiếu; URL sai hẳn thì không làm app sập mà `/ready` trả 503), push commit `d10bdb9`, rồi redeploy. Sau đó `/ready` trả 200.

### Nền tảng còn lại: so sánh `railway.toml` với `render.yaml`

Tôi **không deploy lên Railway**; phần này lấy điểm bằng so sánh hai file cấu hình.

| Điểm | `railway.toml` | `render.yaml` |
|---|---|---|
| Phạm vi | Chỉ cấu hình build và deploy của **một service**. Biến môi trường và Redis cấu hình ngoài file (dashboard hoặc CLI `railway variables set`) | Khai báo **cả hệ thống** (Infrastructure as Code): service web, Key Value (Redis), biến môi trường |
| Build | `builder = "DOCKERFILE"`, `dockerfilePath = "Dockerfile"` | `runtime: docker`, `dockerfilePath` và `dockerContext` (tính từ **gốc repo**, nên tôi dùng `./06-lab-complete/...`) |
| Health check | `healthcheckPath = "/health"`, `healthcheckTimeout = 30` | `healthCheckPath: /health` |
| Restart | `restartPolicyType = "ON_FAILURE"`, tối đa 3 lần | Không khai báo (Render có chính sách mặc định riêng) |
| Secret / env | Không có trong file | `AGENT_API_KEY` dùng `generateValue: true` để Render tự sinh, không ghi giá trị vào repo; `REDIS_URL` lấy từ service Key Value qua `fromService` |
| Redis | Phải tạo bằng tay trên dashboard rồi gán `REDIS_URL` | Khai báo luôn `type: keyvalue` trong cùng file, nối tự động |
| Khi nào dùng | Cấu hình tối thiểu, cho service đã tồn tại | Dựng cả stack bằng một Blueprint |

Khác biệt chính: `render.yaml` mô tả cả hệ thống nên kết nối Redis tự động; `railway.toml` chỉ mô tả cách build và kiểm tra sức khỏe cho một service.

### Exercise 3.3: Pipeline CI/CD của Cloud Run (chỉ đọc, không deploy)

Từ `03-cloud-deployment/production-cloud-run/`:
- `cloudbuild.yaml` chạy khi có commit mới trên `main`, gồm 4 bước nối nhau bằng `waitFor`: **(1) test**: cài `requirements.txt`, chạy `pytest tests/`; **(2) build** image Docker, gắn tag theo `$COMMIT_SHA` và `latest`, dùng `--cache-from` để tận dụng layer cache; **(3) push** image lên Container Registry (`gcr.io/$PROJECT_ID/ai-agent`); **(4) deploy** lên Cloud Run vùng `asia-southeast1` với `min-instances=1` (tránh cold start), `max-instances=10`, 512Mi RAM, 1 CPU, `ENVIRONMENT=production`, và lấy `OPENAI_API_KEY` từ Secret Manager thay vì ghi trong file. Test fail thì các bước sau không chạy.
- `service.yaml` là định nghĩa Cloud Run service kiểu Knative (IaC): giới hạn scale 1–10 instance, tối đa 80 request đồng thời mỗi instance, timeout 60 giây; secret `OPENAI_API_KEY` và `AGENT_API_KEY` lấy từ Secret Manager; `livenessProbe` gọi `/health`, `startupProbe` gọi `/ready`. Triển khai bằng `gcloud run services replace service.yaml`.
- Tôi chỉ đọc hai file này, không có tài khoản GCP nên chưa chạy. Tôi cũng không kiểm tra thư mục `tests/` mà bước 1 gọi có tồn tại hay không.

### Việc còn lại cho Part 3
- Thêm 3 ảnh vào `screenshots/` (`dashboard.png`, `running.png`, `test.png`). Thư mục này chưa có trong repo tại thời điểm viết.

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

Số liệu lấy từ GitHub Codespaces: `evidence/part2_part5.log` (5.1, 5.2) và `evidence/part2_part5_rerun.log` (5.4, 5.5).

### Exercise 5.1: Health checks (`05-scaling-reliability/develop/app.py`)

Bản develop đã có sẵn hai endpoint (tôi đọc code và chạy thật, không tự viết lại):

- `GET /health` (liveness): luôn trả 200 khi process còn sống, kèm uptime, version, và kiểm tra bộ nhớ qua `psutil`.
- `GET /ready` (readiness): trả **503** nếu `_is_ready` còn `False` (đang khởi động hoặc đang shutdown), ngược lại trả 200 kèm số request đang xử lý.

```text
GET /health -> 200 {"status":"ok","uptime_seconds":1.5,"version":"1.0.0",...,"checks":{"memory":{"status":"ok","used_percent":24.2}}}
GET /ready  -> 200 {"ready":true,"in_flight_requests":1}
```

`in_flight_requests: 1` là chính request `/ready` đang được đếm. Ở bản production (`05-scaling-reliability/production/app.py`), `/ready` còn kiểm tra Redis và trả 503 nếu Redis không phản hồi.

**Liveness và readiness khác nhau:** liveness trả lời "process còn sống không?" (fail thì platform restart container). Readiness trả lời "có sẵn sàng nhận traffic chưa?" (fail thì load balancer ngừng gửi request tới instance đó, không restart).

### Exercise 5.2: Graceful shutdown

Tôi chạy `python app.py`, gửi một request `/ask`, rồi gửi `SIGTERM` ngay sau đó (lệnh `kill -TERM`). Kết quả:

```text
request đang chạy lúc nhận SIGTERM -> HTTP/1.1 200 OK (connection: close)
                                      {"answer":"Tôi là AI agent được deploy lên cloud. ..."}
process -> đã thoát
log server:
  INFO:  Shutting down
  INFO:  127.0.0.1 - "POST /ask?question=Long%20task HTTP/1.1" 200 OK
  INFO:  Waiting for application shutdown.
  INFO 🔄 Graceful shutdown initiated...
  INFO ✅ Shutdown complete
  INFO:  Finished server process
```

Request đang chạy vẫn hoàn thành với 200 rồi server mới tắt. Cơ chế: uvicorn bắt `SIGTERM`, ngừng nhận kết nối mới, chờ request đang xử lý xong, rồi chạy phần shutdown của `lifespan`. Ở đó app đặt `_is_ready = False` và chờ tối đa 30 giây cho `_in_flight_requests` về 0. Handler `signal.signal(SIGTERM, ...)` trong file chỉ ghi log, việc tắt thật do uvicorn lo.

Hạn chế của phép thử: request mock chỉ kéo dài khoảng 0,1 giây, nên đây là bằng chứng cho đường đi đúng, không phải thử tải với request dài.

### Exercise 5.3: Stateless design (`05-scaling-reliability/production/app.py`)

- Bản production lưu hội thoại trong **Redis** (`save_session` ghi `session:{id}` bằng `setex` với TTL 3600 giây, `load_session` đọc lại), không giữ state trong RAM của process.
- Nếu Redis không kết nối được, code fallback sang dict trong RAM (`_memory_store`) và in cảnh báo "not scalable". Trong chế độ đó, nhiều instance sẽ không chia sẻ được session.
- **Vì sao phải stateless:** khi scale ra nhiều instance, mỗi instance có bộ nhớ riêng; nếu session nằm trong RAM thì request kế tiếp rơi vào instance khác sẽ không thấy lịch sử. Đưa state ra Redis cho mọi instance dùng chung.

### Exercise 5.4: Load balancing với Nginx

Chạy `docker compose -p k5-day14-scaling up -d --build --scale agent=3`: có 3 agent + 1 Nginx (cổng 8080) + 1 Redis, cả 3 agent `healthy`. Nginx dùng `upstream agent_cluster { server agent:8000; }` và DNS của Docker trả về địa chỉ của cả 3 container, nên request được phân phối vòng tròn. Response có header `X-Served-By` (địa chỉ upstream) và trường `served_by` (ID instance).

10 request liên tiếp tới `POST /chat`:

```text
request 1 -> instance-5c40aa     request 6  -> instance-0ba4f3
request 2 -> instance-398a1d     request 7  -> instance-5c40aa
request 3 -> instance-0ba4f3     request 8  -> instance-398a1d
request 4 -> instance-5c40aa     request 9  -> instance-0ba4f3
request 5 -> instance-398a1d     request 10 -> instance-5c40aa
```

Phân phối: `5c40aa` 4 lần, `398a1d` 3 lần, `0ba4f3` 3 lần, tức vòng tròn đều. Log của từng container agent cũng ghi các dòng `POST /chat 200`, và log Nginx ghi `POST /chat 200` cho từng request.

**Khi một instance chết:** tôi dừng một container (`docker stop`, tương ứng `agent-1`/`instance-0ba4f3`) rồi gọi tiếp 3 request cùng session. Cả 3 trả 200 và được phục vụ bởi 2 instance còn lại (`5c40aa`, `398a1d`). Log Nginx có một dòng lỗi:

```text
[error] upstream timed out (110: Operation timed out) while connecting to upstream,
        request: "POST /chat HTTP/1.1", upstream: "http://172.18.0.4:8000/chat"
```

ngay sau đó là `POST /chat 200`. Tức là Nginx thử container đã dừng, chờ hết timeout kết nối, rồi chuyển sang instance khác nhờ `proxy_next_upstream error timeout http_503`. Khoảng cách thời gian giữa dòng log trước đó (10:32:06) và dòng lỗi (10:33:08) là khoảng 62 giây, khớp với `proxy_connect_timeout` mặc định 60 giây (cấu hình Nginx của bài không đặt giá trị này); đây là suy luận của tôi từ log, không phải số đo thời gian chờ của từng request. Nghĩa là **failover hoạt động nhưng request đầu tiên rơi vào instance chết có thể bị chậm tới ~60 giây**; đặt `proxy_connect_timeout` ngắn hơn (vài giây) sẽ cải thiện.

### Exercise 5.5: Test stateless (`test_stateless.py`)

```text
Total requests: 5
Instances used: {'instance-5c40aa', 'instance-0ba4f3', 'instance-398a1d'}
All requests served despite different instances!
--- Conversation History ---
Total messages: 10
Session history preserved across all instances via Redis!
```

5 request trong cùng một session được 3 instance khác nhau phục vụ, nhưng lịch sử có đủ 10 tin nhắn (5 câu hỏi + 5 câu trả lời): vì state nằm trong Redis chứ không nằm trong instance nào. Lưu ý script `test_stateless.py` **không tự tắt instance nào**, nên tôi làm thêm phép thử riêng:

- Tạo session, dừng một instance, gọi tiếp 3 request với cùng `session_id`: cả 3 thành công và `GET /chat/{session_id}/history` trả `messages in history: 8` = 2 tin nhắn lúc tạo session + 3 x 2 tin nhắn sau khi dừng instance. Không mất tin nhắn nào.

### Checkpoint 5
- Health và readiness: đã đọc, chạy và phân biệt.
- Graceful shutdown: request đang chạy vẫn hoàn thành khi nhận SIGTERM (phép thử ngắn).
- Stateless: session lưu trong Redis, đã chứng minh qua 3 instance và qua việc dừng một instance.
- Load balancing: Nginx round-robin 4/3/3 trên 10 request, có failover nhưng chậm ở request đầu sau khi instance chết.

---

## Part 6: Final Project

- Code nằm trong `06-lab-complete/` (xem git log).
- Chạy `python check_production_ready.py` đầy đủ (có Docker) trên GitHub Codespaces (Linux), commit `f7e51bf` của nhánh `work/day14`:

```text
📋 Checklist Deliverable
     ✅ Dockerfile (multi-stage, < 500 MB)
     ✅ docker-compose.yml (agent + redis)
     ✅ .dockerignore
     ✅ Health check endpoint (GET /health)
     ✅ Readiness endpoint (GET /ready)
     ✅ API Key authentication
     ✅ Rate limiting
     ✅ Cost guard
     ✅ Config từ environment variables
     ✅ Structured logging
     ✅ Graceful shutdown
     ✅ Public URL ready (Railway / Render config)
----------------------------------------------------------------
  Result: 12/12 tiêu chí đạt · 43/43 checks passed
  🎉 PASS 12/12 — PRODUCTION READY! Deploy nào!
```

- Lần chạy đầu trong Codespaces bị lỗi cài đặt vì Python 3.14 không build được `pydantic==2.9.0` (không có wheel cp314), nên tôi nới các version ghim trong `requirements.txt` thành `>=`.
- Trên máy Windows của tôi script chỉ chạy được một phần (không có Docker, Redis, SIGTERM). Kết quả đầy đủ chỉ lấy từ Codespaces.

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
| 6 | Deploy lên Render, sửa lỗi `REDIS_URL` sai định dạng làm container sập | AI đọc stack trace, sửa `app/redis_client.py` (thêm scheme, không sập khi URL sai), viết `DEPLOYMENT.md` và mục Part 3 | Gọi `/health`, `/ready` từ ngoài (200/200); 4 lệnh tự kiểm cho kết quả 200 200 401 200; kiểm tra lại logic với nhiều dạng URL sai |
| 7 | Part 2 và Part 5 trong Codespaces (script thu thập log) | AI viết `scripts/part2_part5.sh` và `scripts/rerun_compose_scaling.sh`, phân tích log, sửa lỗi script chờ sai (coi 502 là sẵn sàng) và viết câu trả lời | Số liệu lấy từ `evidence/*.log` do tôi chạy; kích thước image, SIGTERM, round-robin 4/3/3 và phép thử dừng instance đều có trong log |

> Ghi chú: mục AI log cần được tôi xem lại và tự giải thích được từng đoạn code trước khi nộp (theo RULES.md).
