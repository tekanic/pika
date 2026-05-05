# Pika v0.6 Benchmark Results

**Hardware:** Apple M-series (arm64)  
**Tool:** `bombardier -c 128 -d 15s`  
**Crystal:** 1.20.1  
**Date:** 2026-05-05

---

## Endpoints

| Route | Description |
|---|---|
| `GET /bench/static` | Returns `"ok"` — pure routing, no allocation |
| `GET /bench/json` | Returns `{"status":"ok","ts":<unix>}` — JSON + Time.utc |
| `POST /bench` body `{"name":"alice","count":42}` | Param validation (`requires name:String, count:Int32`) + JSON echo |

---

## Results

### Single-threaded (`--release`)

| Endpoint | req/s (avg) | Latency (avg) | Latency (stddev) |
|---|---|---|---|
| Static | 155,719 | 823 µs | 540 µs |
| JSON | 142,126 | 900 µs | 614 µs |
| Validated params | 123,121 | 1.04 ms | 795 µs |

### Multi-threaded (`--release -Dpreview_mt`, CRYSTAL_WORKERS=4)

| Endpoint | req/s (avg) | Latency (avg) | Latency (stddev) |
|---|---|---|---|
| Static | 190,098 | 672 µs | 265 µs |
| JSON | 166,117 | 769 µs | 153 µs |
| Validated params | 145,715 | 880 µs | 253 µs |

### 4× processes with `reuse_port: true` (`--release`)

| Endpoint | req/s (avg) | Latency (avg) | Latency (stddev) |
|---|---|---|---|
| Static | 153,300 | 834 µs | 226 µs |
| JSON | 145,029 | 880 µs | 57 µs |
| Validated params | 135,396 | 940 µs | 88 µs |

---

## Key observations

- **`--threads 4` is the clear winner** on this hardware: +22% static, +17% JSON, +18% validated vs single-threaded. Latency stddev halves.
- **4× `reuse_port` is roughly flat vs single-threaded** on loopback. The kernel SO_REUSEPORT load balancer shows its advantage in network-bound deployments, not loopback microbenchmarks.
- **Param validation overhead:** ~21% throughput cost vs JSON (single-threaded). Shrinks to ~12% under `--threads 4`, suggesting the struct-generation and parse work distributes well.
- **Zero non-2xx responses** across all runs (1.8–2.9M requests each). No correctness regressions.
- Numbers are consistent with the PoC 3 baseline (161k/148k/123k req/s) — the full DSL stack adds no measurable overhead over raw routing.

---

## Regression threshold

A >5% drop in any cell relative to these baselines requires justification before merging to `main`.
