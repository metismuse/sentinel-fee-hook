# SentinelFeeHook

A Uniswap v4 dynamic-fee hook that prices **token risk into every swap**. Built as the
prototype for a Uniswap Hook Incubator (Atrium) grant application — it exists to prove
the mechanism is real, tested, and honestly scoped.

## Mechanism

An off-chain keeper pushes a signed **0–100 risk score** on-chain once per hour
(EIP-712, secp256k1, nonce-chained, keeper address immutable in the hook).
`beforeSwap` — a state-reading (view) callback, no state writes — reads the latest
score and returns a fee override for that swap only:

```
fee = 3000 + score × 50        # hundredths of a basis point
    = 0.30% at score 0  …  0.80% at score 100
capped at 10_000 (1.00%)
returned as fee | OVERRIDE_FEE_FLAG (0x400000)
```

If the keeper feed is **stale** (> 6 h without a push), the hook does not revert —
swaps never brick. Instead it charges `0.30% + min(EWMA-volatility premium, 0.25%)`,
where the premium is derived from an on-chain EWMA price observation that `afterSwap`
updates with a single packed SSTORE per swap.

Hook permissions: `beforeInitialize` (reverts unless the pool uses the dynamic-fee
flag `0x800000`), `beforeSwap`, `afterSwap`. Everything else: false.

## The risk score, honestly described

**Inputs** (per the Metis Token Risk Snapshot service this hook is designed to consume):
contract verification status, proxy/upgradeability patterns, holder concentration and
activity anomalies, plus a realized-volatility regime component.

**Cadence:** hourly keeper push. **Failure modes:**
- *Stale feed* → on-chain EWMA-volatility fallback (bounded at +0.25%), swaps never revert.
- *Wrong score* → damage is bounded by design: at most +50 bps over base, hard-capped at 1.00%.
- *Keeper key compromise* → an attacker can rewrite the fee schedule for every pool
  using this hook. Mitigated by the immutable keeper address, strict nonce chaining,
  and the staleness fallback — **not eliminated**. Production would use a keeper
  quorum or multisig.

## Risks, stated plainly

1. **Single-keeper centralization.** One key controls the fee input for all pools.
   See failure modes above.
2. **The score's predictive power is unvalidated.** The backtest measures the *fee
   mechanism* assuming the score tracks volatility; it does **not** prove the score
   predicts LP losses. That validation happens live on a mainnet fork during the
   capstone.
3. **Solo builder.** One person wrote this; review it accordingly.
4. **Not production-deployed.** The hook has not been deployed at a CREATE2-mined
   address matching the permission bits in `Hooks.sol` — required before any mainnet
   use. `getHookPermissions()` documents the intended flags.

## Backtest

`backtest/simulate.py` — 90 days of real ETH-USD hourly candles (Coinbase,
2026-06-30 → 2026-09-28, cached in `backtest/eth_hourly.csv`), ~75k modeled swaps.
Full writeup in [`backtest/results.md`](backtest/results.md), including the
correlation sensitivity sweep:

| score–vol correlation (ρ) | revenue edge vs static 0.30% |
|---|---|
| 0.0 (pure timing noise) | +42.8% |
| 0.5 | ≈ +49% |
| 1.0 (true volatility timing) | +53.5% |

The ρ=1.0 − ρ=0.0 gap (~11pp) is the honest timing premium: fees land where volume
and volatility coincide. The rest of the edge is the level effect of charging above
0.30% on average — and if the score were uncorrelated *and* the schedule re-centered
to the same mean as static, the edge would vanish. The mechanism's value is entirely
downstream of score quality.

## Run it

```bash
# install foundry: https://getfoundry.sh
forge test                    # 21 unit tests: fee math, caps, staleness fallback,
                              # EIP-712 auth, nonce-chain replay protection, permissions
python3 backtest/simulate.py   # uses cached candles; re-fetches from Coinbase if deleted
```

## Status

Prototype for a grant application. Not audited, not deployed, not financial advice.
