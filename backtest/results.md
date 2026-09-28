# SentinelFeeHook backtest — fee-mechanism simulation

Data: 2160 real ETH-USD hourly candles (Coinbase), 2026-06-30 to 2026-09-28. ~74,989 simulated swaps, lognormal size (mean $25,000), volume = 10% of hourly CEX volume. Seed 42.

## Correlation sensitivity sweep

Per hour, with probability rho the keeper reports the true volatility
score; otherwise it reports a random other hour's score (identical
marginal distribution, so the mean fee is the same at every rho — only
the *timing* of high fees varies). The sweep therefore isolates the
value of charging high fees exactly when volume and volatility coincide.

| rho (score-vol correlation) | hook revenue | static 0.30% revenue | edge |
|-----------------------------|--------------|----------------------|------|
| 0.0 | $12,063,878 | $8,446,232 | +42.8% |
| 0.2 | $12,239,091 | $8,413,848 | +45.5% |
| 0.4 | $12,373,472 | $8,415,823 | +47.0% |
| 0.6 | $12,729,708 | $8,450,631 | +50.6% |
| 0.8 | $12,754,239 | $8,415,360 | +51.6% |
| 1.0 | $13,031,276 | $8,490,203 | +53.5% |

## Where the edge concentrates (rho = 1.0, by volatility decile)

| decile (1 = calmest) | revenue edge vs static |
|----------------------|------------------------|
| 1 | +15.8% |
| 2 | +24.8% |
| 3 | +28.6% |
| 4 | +32.9% |
| 5 | +37.2% |
| 6 | +40.7% |
| 7 | +45.8% |
| 8 | +52.2% |
| 9 | +60.8% |
| 10 | +100.8% |

## Honest limits

- This measures the **fee mechanism**, not the AI model. It assumes the
  keeper score tracks realized volatility with correlation rho.
- It does **not** prove the score predicts LP losses or impermanent loss;
  that is validated live during the capstone on a mainnet fork.
- Swap flow is modeled (lognormal sizes, volume-proportional counts),
  not replayed from a real mempool; informed-flow / JIT effects are absent.
- At rho = 0 the keeper's scores are pure timing noise: the remaining edge
  over static is just the effect of a higher *average* fee, not of risk
  timing. The rho = 1.0 minus rho = 0.0 gap is the honest timing premium
  of the mechanism: fees land where volume and volatility coincide.
- If the score is uncorrelated with volatility AND the fee schedule were
  re-centered to the same mean as static, the edge would vanish: the
  mechanism's value is entirely downstream of score quality.
