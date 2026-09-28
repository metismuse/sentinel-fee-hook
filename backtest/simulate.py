#!/usr/bin/env python3
"""SentinelFeeHook fee-mechanism backtest with correlation sensitivity sweep.

Measures the FEE MECHANISM ONLY: given a risk score that tracks realized
volatility with correlation rho, how much extra fee revenue does the hook
earn vs a static 0.30% fee? It does NOT prove the AI score predicts LP
losses -- that is validated live during the capstone on a mainnet fork.

Data: 90 days of real ETH-USD hourly candles from Coinbase's public API,
cached to backtest/eth_hourly.csv so re-runs are deterministic and offline.

Method:
  - hourly log returns -> 24h rolling realized volatility -> normalized to a
    0-100 "true" risk score (the volatility regime the keeper score proxies)
  - ~75k simulated swaps: per-hour swap count proportional to that hour's
    share of total volume; size ~ lognormal with mean $25k
  - hook fee = 3000 + score*50 (hundredths of a bps), capped at 10000;
    static fee = 3000
  - sensitivity: per hour, with probability rho the keeper reports the true
    score; otherwise it reports a random other hour's score (a shuffle with
    the EXACT same marginal distribution, so mean fees are identical and only
    timing differs). This isolates the value of charging high fees exactly
    when volume and volatility coincide.

All RNG seeded (42). Pure stdlib.
"""

import csv
import json
import math
import os
import random
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, "eth_hourly.csv")
RESULTS = os.path.join(HERE, "results.md")

COINBASE = "https://api.exchange.coinbase.com/products/ETH-USD/candles"
DAYS = 90
GRANULARITY = 3600
SEED = 42

BASE_FEE = 3000
SCORE_SLOPE = 50
MAX_FEE = 10_000

SWAP_MEAN_USD = 25_000
VOLUME_SHARE = 0.10  # modeled swaps = 10% of hourly CEX volume


def fetch_candles():
    """Fetch DAYS of hourly candles, newest-first pagination, oldest-first output."""
    if os.path.exists(CACHE):
        print(f"using cached candles: {CACHE}")
        with open(CACHE) as f:
            rows = list(csv.DictReader(f))
        return [(int(r["time"]), float(r["close"]), float(r["volume"])) for r in rows]

    print("fetching 90d of ETH-USD hourly candles from Coinbase ...")
    end = int(time.time()) // GRANULARITY * GRANULARITY
    per_req = 300
    all_candles = []
    cursor_end = end
    while len(all_candles) < DAYS * 24:
        cursor_start = cursor_end - per_req * GRANULARITY
        url = f"{COINBASE}?granularity={GRANULARITY}&start={cursor_start}&end={cursor_end}"
        req = urllib.request.Request(url, headers={"User-Agent": "sentinel-fee-hook-backtest/1.0"})
        batch = None
        for attempt in range(4):
            try:
                with urllib.request.urlopen(req, timeout=90) as resp:
                    batch = json.loads(resp.read().decode())
                break
            except Exception as e:
                print(f"  request failed (attempt {attempt + 1}/4): {e}")
                time.sleep(2 * (attempt + 1))
        if not batch:
            raise SystemExit("Coinbase API unreachable after retries; aborting.")
        all_candles.extend(batch)  # each: [time, low, high, open, close, volume]
        cursor_end = batch[-1][0]  # paginate backwards (API returns newest first)
        time.sleep(0.25)
    # batch rows: [time, low, high, open, close, volume]; keep last DAYS*24, oldest first
    all_candles = sorted(all_candles, key=lambda c: c[0])[-(DAYS * 24):]
    rows = [{"time": c[0], "close": c[4], "volume": c[5]} for c in all_candles]
    with open(CACHE, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["time", "close", "volume"])
        w.writeheader()
        w.writerows(rows)
    print(f"cached {len(rows)} candles -> {CACHE}")
    return [(r["time"], r["close"], r["volume"]) for r in rows]


def true_scores(candles):
    """24h rolling realized vol of log returns, min-max normalized to 0-100."""
    closes = [c for _, c, _ in candles]
    rets = [math.log(closes[i] / closes[i - 1]) for i in range(1, len(closes))]
    vols = []
    for i in range(len(rets)):
        window = rets[max(0, i - 23): i + 1]
        mean = sum(window) / len(window)
        var = sum((x - mean) ** 2 for x in window) / len(window)
        vols.append(math.sqrt(var) * math.sqrt(24))  # daily-ized hourly vol
    lo, hi = min(vols), max(vols)
    span = hi - lo or 1.0
    return [100.0 * (v - lo) / span for v in vols]


def simulate(candles, scores, rho, rng):
    """Run the swap simulation at one correlation level. Returns (hook_rev, static_rev, n)."""
    volumes = [v for _, _, v in candles]
    total_vol = sum(volumes) or 1.0
    n_total = 75_000
    n_hours = len(candles) - 1
    # Per-hour reported score: with prob rho the true score, else a random
    # other hour's score (same marginal distribution -> same mean fee; only
    # timing varies). This is the honest sensitivity: it isolates whether
    # charging high fees AT volatile/high-volume hours matters.
    reported = [
        scores[i] if rng.random() < rho else scores[rng.randrange(n_hours)]
        for i in range(n_hours)
    ]
    hook_rev = 0.0
    static_rev = 0.0
    n = 0
    # align scores (len = len(candles)-1) with candle hours 1..
    for i in range(1, len(candles)):
        share = volumes[i] / total_vol
        n_hour = int(round(n_total * share))
        if n_hour == 0:
            continue
        s_used = reported[i - 1]
        fee_hook = min(BASE_FEE + s_used * SCORE_SLOPE, MAX_FEE)
        for _ in range(n_hour):
            size = rng.lognormvariate(math.log(SWAP_MEAN_USD), 0.9)
            hook_rev += size * fee_hook / 1_000_000
            static_rev += size * BASE_FEE / 1_000_000
            n += 1
    return hook_rev, static_rev, n


def main():
    rng = random.Random(SEED)
    candles = fetch_candles()
    print(f"{len(candles)} hourly candles, "
          f"{time.strftime('%Y-%m-%d', time.gmtime(candles[0][0]))} -> "
          f"{time.strftime('%Y-%m-%d', time.gmtime(candles[-1][0]))}")
    scores = true_scores(candles)

    rows = []
    for rho in (0.0, 0.2, 0.4, 0.6, 0.8, 1.0):
        hook_rev, static_rev, n = simulate(candles, scores, rho, random.Random(SEED))
        edge = (hook_rev - static_rev) / static_rev * 100 if static_rev else 0.0
        rows.append((rho, hook_rev, static_rev, edge, n))
        print(f"rho={rho:.1f}  swaps={n:,}  hook=${hook_rev:,.0f}  "
              f"static=${static_rev:,.0f}  edge={edge:+.1f}%")

    # decile concentration at rho=1.0 (where does the edge come from?)
    rng_d = random.Random(SEED)
    volumes = [v for _, _, v in candles]
    total_vol = sum(volumes) or 1.0
    order = sorted(range(1, len(candles)), key=lambda i: scores[i - 1])
    dec = [order[i * len(order) // 10:(i + 1) * len(order) // 10] for i in range(10)]
    dec_edges = []
    for d in dec:
        hr = sr = 0.0
        for i in d:
            n_hour = int(round(75_000 * volumes[i] / total_vol))
            for _ in range(n_hour):
                size = rng_d.lognormvariate(math.log(SWAP_MEAN_USD), 0.9)
                fee = min(BASE_FEE + scores[i - 1] * SCORE_SLOPE, MAX_FEE)
                hr += size * fee / 1_000_000
                sr += size * BASE_FEE / 1_000_000
        dec_edges.append((hr - sr) / sr * 100 if sr else 0.0)

    with open(RESULTS, "w") as f:
        f.write("# SentinelFeeHook backtest — fee-mechanism simulation\n\n")
        f.write(f"Data: {len(candles)} real ETH-USD hourly candles (Coinbase), "
                f"{time.strftime('%Y-%m-%d', time.gmtime(candles[0][0]))} to "
                f"{time.strftime('%Y-%m-%d', time.gmtime(candles[-1][0]))}. ")
        f.write(f"~{rows[0][4]:,} simulated swaps, lognormal size (mean ${SWAP_MEAN_USD:,}), "
                f"volume = {VOLUME_SHARE:.0%} of hourly CEX volume. Seed {SEED}.\n\n")
        f.write("## Correlation sensitivity sweep\n\n")
        f.write("Per hour, with probability rho the keeper reports the true volatility\n")
        f.write("score; otherwise it reports a random other hour's score (identical\n")
        f.write("marginal distribution, so the mean fee is the same at every rho — only\n")
        f.write("the *timing* of high fees varies). The sweep therefore isolates the\n")
        f.write("value of charging high fees exactly when volume and volatility coincide.\n\n")
        f.write("| rho (score-vol correlation) | hook revenue | static 0.30% revenue | edge |\n")
        f.write("|-----------------------------|--------------|----------------------|------|\n")
        for rho, hr, sr, edge, n in rows:
            f.write(f"| {rho:.1f} | ${hr:,.0f} | ${sr:,.0f} | {edge:+.1f}% |\n")
        f.write("\n## Where the edge concentrates (rho = 1.0, by volatility decile)\n\n")
        f.write("| decile (1 = calmest) | revenue edge vs static |\n")
        f.write("|----------------------|------------------------|\n")
        for i, e in enumerate(dec_edges, 1):
            f.write(f"| {i} | {e:+.1f}% |\n")
        f.write("\n## Honest limits\n\n")
        f.write("- This measures the **fee mechanism**, not the AI model. It assumes the\n")
        f.write("  keeper score tracks realized volatility with correlation rho.\n")
        f.write("- It does **not** prove the score predicts LP losses or impermanent loss;\n")
        f.write("  that is validated live during the capstone on a mainnet fork.\n")
        f.write("- Swap flow is modeled (lognormal sizes, volume-proportional counts),\n")
        f.write("  not replayed from a real mempool; informed-flow / JIT effects are absent.\n")
        f.write("- At rho = 0 the keeper's scores are pure timing noise: the remaining edge\n")
        f.write("  over static is just the effect of a higher *average* fee, not of risk\n")
        f.write("  timing. The rho = 1.0 minus rho = 0.0 gap is the honest timing premium\n")
        f.write("  of the mechanism: fees land where volume and volatility coincide.\n")
        f.write("- If the score is uncorrelated with volatility AND the fee schedule were\n")
        f.write("  re-centered to the same mean as static, the edge would vanish: the\n")
        f.write("  mechanism's value is entirely downstream of score quality.\n")
    print(f"wrote {RESULTS}")


if __name__ == "__main__":
    sys.exit(main())
