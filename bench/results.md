# Pika v0.9 Benchmark Results

**Hardware:** Apple M2 (arm64)  
**Tool:** `bombardier -c 128 -d 15s`  
**Crystal:** 1.20.1  
**Date:** 2026-06-19

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
| Static | 154,931 | 826 µs | 318 µs |
| JSON | 149,334 | 860 µs | 161 µs |
| Validated params | 139,052 | 920 µs | 272 µs |

### Multi-threaded (`--release -Dpreview_mt`, CRYSTAL_WORKERS=4)

| Endpoint | req/s (avg) | Latency (avg) | Latency (stddev) |
|---|---|---|---|
| Static | 194,084 | 658 µs | 345 µs |
| JSON | 177,238 | 721 µs | 289 µs |
| Validated params | 149,454 | 860 µs | 413 µs |

### 4× processes with `reuse_port: true` (`--release`)

| Endpoint | req/s (avg) | Latency (avg) | Latency (stddev) |
|---|---|---|---|
| Static | 152,421 | 838 µs | 294 µs |
| JSON | 152,014 | 841 µs | 266 µs |
| Validated params | 134,929 | 950 µs | 134 µs |

---

## Key observations

- **`--threads 4` is the clear winner** on this hardware: +25% static, +19% JSON, +7% validated vs single-threaded.
- **4× `reuse_port` is roughly flat vs single-threaded** on loopback. The kernel SO_REUSEPORT load balancer shows its advantage in network-bound deployments, not loopback microbenchmarks.
- **Param validation overhead:** ~7% throughput cost vs JSON (single-threaded) — the typed-struct generation and parse work is cheap.
- **Zero non-2xx responses** across all runs (2.0–2.9M requests each). No correctness regressions.
- **No regression from the v0.9 production-hardening work.** Despite the response lifecycle now carrying an in-flight request counter (for graceful shutdown) and nil-gated CORS/observability checks on every request, throughput is unchanged-to-better versus the v0.6 baseline (e.g. single-threaded validated rose from 123k to 139k req/s, well within run-to-run variance). The observability clock read and CORS/header work only execute when those features are enabled.

---

## Regression threshold

A >5% drop in any cell relative to these baselines requires justification before merging to `main`.
