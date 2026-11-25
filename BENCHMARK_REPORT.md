# Benchmark & Observability Report — Day 14

**Họ tên:** To Minh Thanh — 2A202603439
**Ngày chạy:** 2026-11-25
**Môi trường:**
- Mục 2 và 3 (benchmark local): Windows 11 Home, Python 3.14, agent và load generator chạy cùng một máy, không Docker.
- Mục 4 và 5 (observability stack): GitHub Codespaces (Linux, khoảng 2 vCPU, ~8 GB RAM theo `free -m` và log Prometheus `GOMAXPROCS=2`), Docker Compose, stack `production/` với 2 instance agent (mỗi instance giới hạn 0,5 CPU / 256 MB). Mock LLM, không gọi API thật.

> Số liệu mục 2 và 3 lấy từ các file trong `reports/`. Mục 4 và 5 lấy từ `evidence/part7.log`, `benchmark-results/scale_1_stats.csv`, `benchmark-results/scale_3_stats.csv` và các ảnh trong `screenshots/`. Mỗi thí nghiệm chỉ chạy **một lần**.

---

## 1. SLO của agent

| SLI | SLO | Lý do chọn ngưỡng này |
|---|---|---|
| p95 latency `/ask` | < 500 ms | Mock LLM mất ~200 ms ở trạng thái bình thường, nên 500 ms cho dư địa 2,5 lần mà vẫn đủ nhanh với người dùng. Dùng p95 vì average che mất tail latency |
| Error rate `/ask` | < 2 % | Mock LLM chủ động lỗi ~1 % (`MOCK_ERROR_RATE`), nên SLO phải cao hơn mức lỗi nền đó |
| Accuracy trên golden dataset | ≥ 100 % (23/23) | Dataset nhỏ và cố định; không chấp nhận câu nào sai hoặc regression trước khi merge |

Đây là ngưỡng mặc định của `load_test.py` (`--slo-p95-ms 500`, `--slo-error-rate 0.02`).

---

## 2. Benchmark hiệu năng (develop, `load_test.py`)

Mỗi lần chạy: 300 request tới agent v2 (`http://localhost:8002`).

### 2.1 Concurrency vs latency (agent v2)

| Concurrency | RPS | p50 (ms) | p95 (ms) | p99 (ms) | Error rate | SLO |
|---|---|---|---|---|---|---|
| 1 | 3.97 | 204.5 | 247.0 | 1695.1 | 0.33 % | ✅ PASS |
| 10 | 38.44 | 201.4 | 434.3 | 1706.6 | 1.00 % | ✅ PASS |
| 50 | 77.94 | 275.4 | 1432.8 | 2206.7 | 1.00 % | ❌ FAIL (p95) |
| 100 | 57.40 | 690.1 | 3651.7 | 4003.3 | 2.67 % | ❌ FAIL (p95, error rate) |

(File: `reports/load_v2_c1.json`, `load_v2_c10.json`, `load_v2_c50.json`, `load_v2_c100.json`.)

**Nhận xét:**
- RPS **không tăng tuyến tính**. Từ 1 lên 10 thì RPS tăng gần 10 lần (3.97 → 38.44), vì mỗi request chủ yếu chờ I/O (mock LLM `sleep`). Từ 10 lên 50 chỉ tăng gấp đôi (→ 77.94). Lên 100 thì RPS **giảm** (57.40) và p50 tăng gấp 2,5 lần so với mức 50.
- Khi vượt khả năng xử lý, request xếp hàng chờ: p50, p95 và p99 đều tăng mạnh, trong khi RPS không tăng thêm. Từ concurrency 50 trở lên, p95 vượt SLO 500 ms. Ở 100, error rate cũng vượt 2 %.
- Lưu ý khi đọc số: agent (một process uvicorn) và load generator cùng chạy trên một máy, nên hai bên tranh CPU. Số tuyệt đối ở mức 50 và 100 bị ảnh hưởng bởi điều này. Tôi chỉ chạy mỗi mức một lần nên chưa đo được độ dao động giữa các lần chạy.
- Ở mọi mức, p99 luôn cao hơn nhiều so với p50 (khoảng 1,7 s so với 0,2 s ở mức 1 và 10): đây là các request "chậm" do `MOCK_SLOW_RATE`.

### 2.2 Tail latency (concurrency 20, 300 request)

| `MOCK_SLOW_RATE` | avg (ms) | p95 (ms) | p99 (ms) |
|---|---|---|---|
| 0 | 220.4 | 471.3 | 518.3 |
| 0.03 (mặc định) | 267.7 | 490.7 | 1713.8 |
| 0.1 | 346.5 | 1699.6 | 1736.4 |

(File: `reports/load_v2_slow_0.json`, `load_v2_slow_0.03.json`, `load_v2_slow_0.1.json`.)

**Nhận xét:**
- Từ 0 lên 0.1, **p99 và p95 nhạy nhất**: p95 tăng từ 471 lên 1700 ms (khoảng 3,6 lần) trong khi avg chỉ tăng từ 220 lên 347 ms (khoảng 1,6 lần). Ở mức 0.03, avg tăng chưa tới 22 % (220 → 268 ms) nhưng p99 tăng từ 518 lên 1714 ms (3,3 lần).
- Vì vậy SLO không nên đặt theo average: avg 267.7 ms ở mức 0.03 trông ổn, nhưng cứ 100 request thì có khoảng 3 request mất gần 1,7 s.
- Lưu ý về độ nhiễu: mỗi lần chỉ 300 request và chạy một lần, nên p95 ở mức 0 (471 ms) và 0.03 (490 ms) khá gần nhau và đều sát ngưỡng 500 ms. Hai con số này không nên đọc như một sự khác biệt thật. Ở mức 0, p95 cao hơn p50 gấp 2,3 lần dù đã tắt request chậm, nên còn có nguồn latency khác (lỗi upstream và tranh CPU trên cùng máy).

---

## 3. Benchmark chất lượng (develop, `eval/run_eval.py`)

| Chỉ số | Agent v1 | Agent v2 | Agent v2 (sau khi sửa KB) |
|---|---|---|---|
| Accuracy | 4.3 % (1/23) | 91.3 % (21/23) | 100 % (23/23) |
| Avg tokens / câu | 57.4 | 108.8 | 115.5 |
| Tổng cost (USD) | 0.000409 | 0.000758 | 0.000807 |
| Cost / câu đúng (USD) | 0.00040875 | 0.00003607 | 0.00003507 |
| Quality gate | FAIL | PASS (gate ≥ 80 %) | PASS (gate ≥ 100 %, không regression) |

(File: `reports/eval_v1.json`, `eval_v2.json`, `eval_v2_fixed.json`.)

**Những câu v2 trả lời sai ban đầu và cách sửa:**

| ID | Keyword bị thiếu | Đã sửa gì |
|---|---|---|
| `scaling-03` (Kubernetes HPA scale dựa trên chỉ số nào?) | `cpu`, `memory`, `custom metrics` (knowledge base không có tài liệu nào về HPA) | Thêm entry vào `KNOWLEDGE_BASE` trong `develop/utils/mock_llm.py`, kích hoạt bởi `hpa`, `kubernetes`, `autoscal`; nội dung nêu CPU, memory và custom metrics |
| `security-02` (JWT khác gì API key?) | `token`, `hết hạn`, `chữ ký` (không có tài liệu nào về JWT) | Thêm entry kích hoạt bởi `jwt`, `api key`; nội dung nêu token có chữ ký và hết hạn |

Không sửa `golden_dataset.jsonl`. Sau khi sửa, tôi khởi động lại v2 rồi chạy eval với `--baseline reports/eval_v2.json`: 2 câu được cải thiện, 0 regression.

**Quality gate trong CI:** `run_eval.py` thoát với exit code khác 0 khi accuracy dưới ngưỡng `--min-accuracy` hoặc có regression so với `--baseline`. Một bước GitHub Actions chỉ cần chạy lệnh này, job fail thì PR không merge được:

```yaml
- name: Eval quality gate
  working-directory: 06-lab-complete/benchmark-observability/develop
  run: python eval/run_eval.py --url http://localhost:8002 --min-accuracy 1.0 --baseline reports/eval_v2_fixed.json
```

(Bước này giả định agent đã được khởi động trước đó trong job. Tôi chưa chạy nó trên GitHub Actions; các lệnh `run_eval.py` ở trên thì đã chạy local. Tôi cũng chưa chạy thử exit code của v1 so với baseline v2 như bài tập 4 yêu cầu.)

**Nhận xét về trade-off v1 / v2:**
- v2 dùng retrieval nên prompt dài hơn: số token trung bình mỗi câu tăng 1,9 lần (57.4 → 108.8), tổng cost tăng khoảng 1,85 lần.
- Đổi lại accuracy từ 4.3 % lên 91.3 %, nên **cost / câu đúng giảm khoảng 11 lần** (0.00040875 → 0.00003607). So theo "cost / câu" thì v2 đắt hơn, so theo "cost / câu đúng" thì v2 rẻ hơn nhiều.
- Về latency, eval chỉ có 23 mẫu nên p95 của eval **không đủ tin cậy** (v1: 1682.5 ms, v2: 232.6 ms, v2 sau khi sửa: 1572.4 ms; mỗi lần chỉ cần một request chậm là p95 nhảy vọt). Latency phải đo bằng load test ở mục 2.

---

## 4. Observability stack (production)

Stack: Nginx → 2 agent (v2) + Prometheus + Grafana + Jaeger + Locust, bật bằng `docker compose -p k5-day14-observability`. Alert rules qua `promtool test rules`: **SUCCESS**.

### 4.1 Screenshot

- [x] Dashboard Grafana khi đang có tải: `screenshots/grafana-dashboard.png` (Traffic 61.8 req/s, Error rate 0.82%, p95 293.60 ms, Saturation 13, Instances 2, LLM cost $0.4423; biểu đồ Requests/s có hai đỉnh khoảng 62 req/s ứng với hai lần chạy scale 1 và scale 3; đường p99 khoảng 1.8 s vượt vạch SLO 1 s)
- [x] Trace chậm trong Jaeger: `screenshots/jaeger-slow-trace.png`
- [x] Trace lỗi trong Jaeger (có event `exception`): `screenshots/jaeger-error-trace.png`
- [x] Trang Alerts của Prometheus có 2 alert đang firing cùng lúc: `screenshots/prometheus-alert-firing.png` (`AgentHighErrorRate` và `AgentHighLatencyP95`)

**Trả lời Exercise 7.4** (số lấy từ Prometheus ở trạng thái nền, 30 user Locust, 2 instance, `evidence/part7.log`):

1. **p95 và avg:** p95 = **0.2938 s**, avg = **0.2362 s** (cửa sổ 1 phút). Ở trạng thái nền hai số này gần nhau vì 1 phút ít request chậm. Khoảng cách chỉ lộ rõ ở đuôi: trên dashboard lúc 100 user, p95 chỉ 293.60 ms trong khi p99 khoảng 1.8 s. Nghĩa là phần lớn request nhanh nhưng một số ít (cỡ 3% do `MOCK_SLOW_RATE`) chậm hơn 1.5 s, và trung bình không phản ánh điều đó.
2. **Chia tải giữa 2 instance:** `172.18.0.3` = **9.436 req/s**, `172.18.0.4` = **9.218 req/s** (lệch khoảng 2.3%), nên Nginx chia khá đều.
3. **Input tokens/s lớn hơn output:** input **1358/s** so với output **720.7/s** (gấp khoảng 1.9 lần). Prompt gồm system prompt, đoạn tài liệu lấy từ retrieval (agent v2) và câu hỏi, còn câu trả lời mock thì ngắn, nên số token vào luôn nhiều hơn số token ra.
4. **`curl http://localhost:8080/metrics`:** trả **HTTP 404** (`log`: `HTTP/1.1 404 Not Found`). Nginx cấu hình `location = /metrics { return 404; }` để không công khai metric ra ngoài (lộ route, lưu lượng, thông tin hệ thống). Prometheus vẫn scrape được vì nó gọi thẳng vào từng agent trong mạng nội bộ Docker.

### 4.2 Thí nghiệm "phá hệ thống"

Cách đo: script giữ 30 user Locust chạy nền, đổi cấu hình bằng `docker compose up -d --force-recreate`, chờ 15 giây cho agent khởi động, rồi gọi API `/api/v1/alerts` của Prometheus mỗi 5 giây. Thời gian trong bảng tính từ **lúc agent mới đã khởi động xong** (cộng thêm khoảng 15 giây nếu tính từ lúc gõ lệnh). "pending" là lần đầu thấy alert ở trạng thái pending. Các thời gian khớp với `for:` trong `alert_rules.yml` (ví dụ lỗi: 10 s pending + 60 s `for` = 71 s).

| # | Thay đổi | Alert nào firing | Thời gian đến firing | Panel/chỉ số phản ánh rõ nhất |
|---|---|---|---|---|
| A | `MOCK_ERROR_RATE=0.2` | `AgentHighErrorRate` | pending sau 10 s, **firing sau 71 s** | Error rate đo được **0.2041** (20.4%) |
| B | `MOCK_SLOW_RATE=0.3` | `AgentHighLatencyP95` | pending sau 5 s, **firing sau 126 s** | p95 1 phút = **1.913 s** |
| C | `LLM_MODEL=mock-llm-large` | `LLMCostBurnRateHigh` | pending sau 10 s, **firing sau 126 s** | Cost USD/giờ lên **15.69** (xem lưu ý) |
| D | `docker pause` 1 instance | `AgentInstanceDown` | pending sau 10 s, **firing sau 41 s** | Số instance `up` giảm (alert theo `up == 0`) |
| E | `AGENT_VERSION=v1` | **không có alert nào** sau 150 s | — | Tokens/s: input giảm từ 1358 xuống **707.3**, output từ 720.7 xuống **384.5** |
| F | A + B cùng lúc | `AgentHighErrorRate` và `AgentHighLatencyP95` cùng firing | lỗi: 70 s; latency: 51 s tính từ lúc lỗi firing (khoảng 121 s tổng) | Trang Alerts: `FIRING (2)` |

Lưu ý khi đọc bảng:
- **Thí nghiệm C không tách riêng được tác động của model lớn.** Ngay trước khi đổi model, cost nền đo được là **2.028 USD/giờ**, đã chạm ngưỡng $2/giờ của alert (ở lần đo nền ban đầu là 1.237). Sau khi đổi sang `mock-llm-large`, cost lên 15.69 USD/giờ (gấp khoảng 7.7 lần so với 2.028), nên model lớn rõ ràng làm cost tăng mạnh, nhưng việc alert firing một phần có thể đến từ mức nền đã sát ngưỡng. Sau khi đổi lại model nhỏ, alert vẫn firing sau 300 s; tôi suy luận là do cửa sổ `rate(...[5m])` còn chứa dữ liệu cũ (chưa kiểm chứng riêng).
- **Thí nghiệm D:** tỉ lệ 5xx mà agent tự báo là **0.0119** (1.19%), tức chỉ bằng lỗi nền 1%, trong khi container bị pause. Request tới instance bị pause bị Nginx cắt sau `proxy_read_timeout` nên không được agent đếm. Script **không đo** số lỗi 504 ở tầng Nginx hay Locust trong thí nghiệm này, nên tôi không có con số 504 để báo cáo.
- **Thí nghiệm F:** thời gian 51 s của `AgentHighLatencyP95` được đo bắt đầu từ lúc `AgentHighErrorRate` đã firing (script chờ lần lượt), nên không so sánh trực tiếp với 126 s của thí nghiệm B (B đo từ lúc đổi cấu hình).
- Lần chạy `chaos` đầu tiên bị gián đoạn vì Prometheus, Grafana và Locust không chạy (các dòng `N/A` ở đầu mục chaos trong `evidence/part7.log`); số liệu trên là của lần chạy lại.

**Thí nghiệm E không làm alert nào firing. Bạn sẽ phát hiện loại sự cố này trong production bằng cách nào?**

Alert hạ tầng không bắt được vì v1 vẫn trả lời nhanh và không lỗi: chất lượng giảm nhưng latency và error rate không đổi. Chỉ có tín hiệu gián tiếp: tokens/s vào giảm từ 1358 xuống 707.3 (do mất đoạn tài liệu retrieval), nhưng không có alert nào đặt trên chỉ số đó. Cách phát hiện đúng là đo **chất lượng**: (1) chạy eval trên golden dataset theo lịch và trong CI (như `run_eval.py --min-accuracy` đã làm ở mục 3, v1 chỉ đạt 4.3% so với v2 91.3%); (2) probe tổng hợp (synthetic check) gửi câu hỏi có đáp án biết trước và alert khi đáp án sai; (3) phản hồi của người dùng (thumbs up/down) hoặc LLM-as-judge lấy mẫu. Có thể thêm alert trên tỉ lệ retrieval hit và tokens/s, nhưng chúng chỉ là chỉ báo gián tiếp.

### 4.3 Debug bằng trace

**Trace chậm** (`screenshots/jaeger-slow-trace.png`):

- `trace_id`: `a48b70fb2a502249439c663b3024c6ea`
- Tổng thời gian: **1.7 s** (4 span)
- Span chiếm nhiều thời gian nhất: `chat mock-llm-small`, **Duration 1.7 s** (gần như toàn bộ trace). Span `agent.retrieve_context` chỉ **28.3 ms**. Thuộc tính GenAI: provider `mock`, model `mock-llm-small`, tokens input 83, output 44.
- Kết luận: chỗ chậm nằm ở lệnh gọi LLM (do `MOCK_SLOW_RATE` cộng thêm 1.5 s cho một số request), không phải ở code của agent hay bước retrieval.
- Tôi **không thu** dòng log JSON ứng với trace chậm này (script chỉ grep `llm_error`), nên phần log bên dưới là của trace lỗi.

**Trace lỗi** (`screenshots/jaeger-error-trace.png`):

- `trace_id`: `4cbba6c4adbadef082febc11d8b342d8`
- Tổng thời gian: **93.3 ms**, `POST /ask` trả **503**; span `chat mock-llm-small` **68.4 ms**, `agent.retrieve_context` 22.2 ms.
- Event `exception` ở mốc 91.76 ms: `exception.message = Upstream LLM error: 503 Service Unavailable (mock)`, `exception.stacktrace` dài 417 ký tự, `error.type = upstream_unavailable`.
- Dòng log tương ứng (`docker compose logs agent | grep llm_error | head -1`, trích từ `evidence/part7.log`). `trace_id` trong log khớp với `trace_id` trong ảnh, và `service.instance.id` trong Jaeger (`c122ce34479b`) khớp với trường `instance` của log:

```json
{"ts": "2026-11-25T11:02:54.825308+00:00", "level": "INFO", "service": "observable-agent", "instance": "c122ce34479b", "event": "llm_error", "trace_id": "4cbba6c4adbadef082febc11d8b342d8", "span_id": "d20c41f079829c49", "request_id": "601a6c74e892", "error": "Upstream LLM error: 503 Service Unavailable (mock)"}
```

Script cũng kiểm tra bằng API: Jaeger tìm thấy trace này (HTTP 200). Phần phân tích trace tự động của script không in ra kết quả trong log, nên các số của hai trace ở trên tôi lấy từ ảnh chụp Jaeger.

---

## 5. Benchmark scaling (production, Locust headless, 100 users, ramp 10/s, 2 phút)

Số liệu của dòng `/ask` trong `benchmark-results/scale_1_stats.csv` và `scale_3_stats.csv`:

| Số instance | Request | RPS | p50 (ms) | p95 (ms) | p99 (ms) | Failures |
|---|---|---|---|---|---|---|
| 1 | 7177 | 60.23 | 190 | 260 | 1700 | 80 (1.11%) |
| 3 | 7099 | 59.58 | 190 | 240 | 1700 | 72 (1.01%) |

(Dòng `Aggregated` gồm cả `/health`: 65.93 và 65.72 req/s. Với 3 instance, Prometheus thấy đủ **3 target** trước khi chạy.)

**Giải thích kết quả:**

- Scale từ 1 lên 3 instance **không cải thiện** RPS (60.23 so với 59.58), p50 (cùng 190 ms) hay p99 (cùng 1700 ms). p95 giảm từ 260 xuống 240 ms nhưng chênh nhỏ và mỗi cấu hình chỉ chạy một lần, nên tôi không coi đó là cải thiện thật.
- **Nút thắt không nằm ở số instance agent.** Locust là mô hình vòng kín: mỗi user nghỉ 0.5 đến 2 giây giữa các request (trung bình 1.25 s). Với 100 user, mỗi vòng khoảng 1.25 s nghỉ + 0.2 s xử lý, RPS tối đa vào khoảng 100 / 1.47 ≈ 68 req/s, rất gần mức đo được (65.9 req/s tổng). Nói cách khác, tải được giới hạn bởi số user và thời gian nghỉ, một instance đã xử lý đủ (p50 190 ms, p95 260 ms) nên thêm instance không có gì để cải thiện. Đây là tính toán của tôi từ cấu hình `locustfile.py`, không phải một phép đo riêng.
- **p99 = 1700 ms** giống hệt ở cả hai cấu hình vì nó đến từ các request "chậm" do mock LLM cộng thêm 1.5 s (`MOCK_SLOW_RATE`), không phụ thuộc số instance. Muốn giảm tail latency phải sửa nguyên nhân ở LLM (timeout ngắn hơn, retry, hedging, model nhanh hơn), không phải scale ngang.
- **Failures khoảng 1%** (80 và 72 request) khớp với `MOCK_ERROR_RATE=0.01`: đây là lỗi 503 do mock chủ động tạo, không phải do quá tải.
- Hạn chế: Codespaces có khoảng 2 vCPU và Locust chạy cùng máy với stack, mỗi cấu hình chỉ chạy một lần, nên các con số tuyệt đối chỉ có giá trị cho môi trường này.

---

## 6. Kết luận

- 3 điều tôi học được về benchmark và observability:
  1. **Average che giấu tail latency.** Ở `MOCK_SLOW_RATE=0.03`, avg chỉ khoảng 0.24 s nhưng p99 khoảng 1.7 s (mục 2.2, mục 5). SLO nên đặt trên p95 hoặc p99.
  2. **Scale ngang chỉ giúp khi nút thắt nằm ở năng lực xử lý.** Ở bài này thêm instance không đổi p50, p99 hay RPS, vì tải bị giới hạn bởi số user và thời gian nghỉ của Locust, còn tail latency đến từ lệnh gọi LLM (mục 5). Cần đọc trace và metric trước khi quyết định scale.
  3. **Metric hạ tầng không phát hiện được suy giảm chất lượng.** Thí nghiệm E (v1) không làm alert nào firing dù accuracy giảm từ 91.3% xuống 4.3%; chỉ eval trên golden dataset bắt được (mục 3, mục 4.2). Cũng cần hiểu giới hạn của từng nguồn dữ liệu: ở thí nghiệm D, metric của agent không thấy lỗi 504 do Nginx cắt.
- Nếu đưa agent này lên production thật, tôi sẽ thêm:
  - Alert theo **tốc độ đốt error budget** (nhiều cửa sổ thời gian) thay cho ngưỡng cố định, và alert dựa trên metric **ở tầng load balancer** hoặc probe từ bên ngoài, để thấy lỗi 504 như ở thí nghiệm D.
  - Alert **chất lượng**: eval theo lịch, probe tổng hợp có đáp án biết trước, và theo dõi retrieval hit ratio, tokens/s vào.
  - Alert chi phí theo **từng người dùng hoặc từng tenant** (qua log, không dùng label `user_id` trên metric vì cardinality), cùng ngân sách cứng.
  - Alert **saturation** (số request đang xử lý, CPU/memory của container) và cảnh báo khi alert chi phí bị nhiễu do mức nền đã sát ngưỡng như ở thí nghiệm C.
  - Lấy mẫu trace (sampling) khi traffic lớn, và ghi `trace_id` vào mọi dòng log (đã có) để chuyển từ metric sang trace sang log.
