# PoC 3: Performance Benchmark Harness — PASSED ✅

**Goal:** establish baseline performance numbers for Crystal's stdlib `HTTP::Server` with a hand-rolled router — no external dependencies.

> **Revision note:** original PoC used Kemal. Dropped Kemal in favour of Crystal's native HTTP stack after deciding Pika will own its own router. Results are substantially better.

## Hardware & software

| Item | Value |
|---|---|
| Machine | MacBook Pro (Apple M-series) |
| OS | macOS Darwin 24.6.0 |
| Crystal | 1.20.1 |
| Router | Hand-rolled (stdlib `HTTP::Server` only) |
| Tool | bombardier, 128 connections, 15s per run |
| Build | `crystal build --release` |

## Results (3 runs each, avg req/s)

| Endpoint | Run 1 | Run 2 | Run 3 | Mean | PRD target |
|---|---|---|---|---|---|
| `/static` (routing only) | 165,057 | 157,103 | 161,919 | **161,360** | ≥ 80,000 |
| `/json` (serialization) | 139,903 | 150,324 | 154,729 | **148,319** | — |
| `/validated` (JSON body + coercion) | 116,145 | 128,558 | 124,652 | **123,118** | — |

**Comparison vs Kemal baseline:**

| Endpoint | Kemal | Native | Delta |
|---|---|---|---|
| `/static` | 103,936 | 161,360 | **+55%** |
| `/json` | 98,392 | 148,319 | **+51%** |
| `/validated` | 96,547 | 123,118 | **+27%** |

## Analysis

- **PRD threshold met with substantial headroom.** The `/static` endpoint averages ~161k req/s vs the 80k minimum — 2× target.
- **Kemal overhead was real.** Eliminating Kemal's middleware chain and handler allocation yields 27–55% throughput improvement across all endpoints.
- **Validation overhead remains negligible.** `/validated` runs at 76% of `/static` throughput — full JSON body parse + field coercion + error accumulation is not a bottleneck.
- **No external dependencies required.** Crystal's stdlib `HTTP::Server` alone exceeds all performance NFRs.

## What this does not test

- Multi-core throughput (single-process run)
- Sustained load / RSS stability
- Dynamic path parameter extraction (`:id` segment) — hand-rolled router supports it but not separately benchmarked

## Build & run

```sh
# Build
crystal build --release poc/bench/server.cr -o poc/bench/server

# Run server
./poc/bench/server &

# Benchmark
bombardier -c 128 -d 15s http://localhost:3000/static
bombardier -c 128 -d 15s http://localhost:3000/json
bombardier -c 128 -d 15s -m POST -H 'Content-Type: application/json' \
  -b '{"email":"a@b.com","name":"Alice","age":25}' \
  http://localhost:3000/validated

kill %1
```

## Recommendation

**Proceed — no external dependencies needed.** Crystal's stdlib HTTP stack comfortably exceeds the 80k req/s floor. Pika will own its router entirely; no dependency on Kemal or any HTTP framework.
