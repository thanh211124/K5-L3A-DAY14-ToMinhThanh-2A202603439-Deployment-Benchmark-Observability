# Benchmark & Observability Report — Day 14

**Họ tên:** To Minh Thanh — 2A202603439
**Ngày chạy:** 2026-11-25
**Môi trường:** Windows 11 Home, Python 3.14, agent và load generator chạy cùng một máy (local, không Docker). Mock LLM, không gọi API thật.

> Số liệu mục 2 và 3 lấy từ các file trong `reports/`. Mục 4 và 5 (Docker stack) **chưa làm**, xem ghi chú ở cuối mỗi mục.

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

**Chưa thực hiện.** Phần này cần Docker (Prometheus, Grafana, Jaeger, Locust), mà máy hiện chưa chạy được Docker/WSL2. Cần làm sau: ảnh Grafana, trace chậm và trace lỗi trong Jaeger, ít nhất 2 alert firing cùng thời gian, và các thí nghiệm A–E.

## 5. Benchmark scaling (production, Locust)

**Chưa thực hiện.** Cùng lý do với mục 4. Cần `benchmark-results/scale_1_stats.csv` và `scale_3_stats.csv`.

---

## 6. Kết luận (tạm thời, mới dựa trên phần chạy local)

- Những điều rút ra:
  1. Average che mất tail latency: ở `MOCK_SLOW_RATE=0.03`, avg chỉ 268 ms nhưng p99 là 1714 ms. SLO nên đặt theo p95/p99.
  2. Eval v1 so với v2 cho thấy chất lượng tăng nhưng token tăng theo. Dùng "cost / câu đúng" để so sánh hai phiên bản công bằng hơn "cost / câu".
  3. Một agent một process có điểm bão hòa: tăng concurrency quá điểm đó chỉ làm latency tăng, RPS không tăng (thậm chí giảm).
- Phần "metric và alert cần thêm khi lên production thật" sẽ viết sau khi làm xong mục 4.
