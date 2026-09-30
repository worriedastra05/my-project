# Order Flow Gold v2 — research-hardened specification

Version 2.00 · XAU/USD · signal TF **M5** · target ~5–8 trades/day · low RR, high hit-rate, cost- and overfit-aware

This is a ground-up rebuild of v1 after reading 50+ market-microstructure and quant papers.
Every new component below is tied to a specific source.

---

## 1. Research base (what changed and why)

| # | Upgrade in v2 | Source(s) |
|---|---|---|
| 1 | **Diurnal (time-of-day) delta z-score** — flow is standardised per 5-min bucket, not pooled | Cont, Kukanov & Stoikov 2014 (OFI intraday seasonality); Bacry et al. 2015 & Rambaldi et al. (Hawkes exogenous baseline is U-shaped); Wu et al. Hawkes factor (U-shaped baseline) |
| 2 | **Multi-horizon Integrated OFI** (1/3/6-bar) + horizon-agreement filter | Cont, Cucuringu & Zhang 2021 (cross-impact, integrated OFI via PCA); Xu, Gould & Howison (multi-level OFI, Ridge); Kolm, Turiel & Westray (deep OFI, multi-horizon) |
| 3 | **VPIN toxicity gate on a volume clock** (tick-rule signed) | Easley, López de Prado & O'Hara 2012 (VPIN, flow toxicity, flash-crash early warning); Andersen & Bondarenko 2014 (**tick rule beats bulk-volume classification** → we sign by tick rule, keep BVC only as an option) |
| 4 | **Micro-price fair-value lean** from rolling tick imbalance | Stoikov 2018 (micro-price = martingale fair value, out-predicts mid/weighted-mid) |
| 5 | **Volatility regime switch** (ATR-percentile, HMM-style states) | Zhang et al. 2020 (regime-switching HAR); S&P500 regime-switching RV 2025; HMM regime-detection literature |
| 6 | **Reversal-after-extreme + IBS** in the fade engine | Ledger 2021 (BTC intraday overreaction reversal, bigger move → bigger reversal); Pacific-Basin Finance 2024 (commodity intraday reversal under high liquidity); Pagonidis (IBS mean-reversion effect) |
| 7 | **Meta-score gate + expectancy-aware sizing (fractional Kelly)** | López de Prado — meta-labeling / bet sizing, *Advances in Financial ML*; MacLean, Thorp & Ziemba (fractional Kelly reduces drawdown more than growth); quarter-Kelly practice |
| 8 | **TP band 1.5R–3.5R, tiered** (small TP1 + runner), realistic cost model | IJACSA transformer day-trading study (targets 1.5R–3.5R robust, ≥4R hurts hit rate); Vezeris et al. 2018 (ATR trailing stop); Kethan S E 2026 SSRN 7053198 (OFI edge dies on costs at high frequency → M5, TP≫spread, spread cap vs ATR) |
| — | Foundations carried from v1 | Cont-Kukanov-Stoikov 2014 (linear OFI→price impact, absorption = deep book); Cartea-Donnelly-Jaimungal (volume imbalance predicts next MO); Lee & Ready 1991 (quote rule) |
| — | Anti-overfitting discipline (how to validate, not a runtime feature) | López de Prado — deflated/probabilistic Sharpe, purging & embargo, CPCV, PBO; Bailey & López de Prado 2014 |

## 2. Data & flow engine (`OFG2_Flow.mqh`)

Same tick reconstruction as v1 (broker BUY/SELL flag → Lee-Ready quote rule → mid tick rule),
plus, per bar and per session:

* **Diurnal stats** — mean/σ of delta for each of 288 five-minute buckets → `DeltaZSeason`. Falls back to the pooled z when a bucket has <8 samples (`DeltaZBest`).
* **Integrated OFI** — `0.5·z(1) + 0.3·z(3) + 0.2·z(6)`, standardised, with a horizon-agreement score (0/0.5/1).
* **VPIN** — equal-volume buckets on a volume clock; rolling average of |buy−sell|/total over `InpVpinWindow` buckets. Tick-rule signing (BVC available via `InpFlowClass`).
* **Micro-price offset** — EWMA tick imbalance × spread (Stoikov-style lean) → confirms direction.
* **Hawkes-style intensity** — fast/slow EWMA of tick-arrival rate → activity ratio on the panel.
* **VWAP ± σ, IBS, efficiency** — as v1.

## 3. Regime switch (ATR percentile)

`InpRegimeLookback` (120) bars of ATR → percentile of the current ATR:

| Regime | ATR pct | Behaviour |
|---|---|---|
| **CALM** | ≤ `InpCalmPct` (40) | mean-revert → **fade** engine preferred |
| **NORMAL** | 40–75 | both engines |
| **TREND** | ≥ `InpTrendPct` (75) | **flow** continuation preferred |
| **STORM** | ≥ `InpStormPct` (95) | **stand aside** (no new trades) |

With `InpEngine = AUTO` the EA picks the engine that matches the regime; the fade engine is additionally blocked when **VPIN ≥ `InpFadeMaxVpin`** (0.75) because toxic one-sided flow should be joined, not faded, and everything is blocked at **VPIN ≥ `InpStandAsideVpin`** (0.90).

## 4. Meta-score (gate + size)

Each candidate gets a 0..1 score blending: flow strength (z), absorption depth (fade) / efficiency (flow), VWAP stretch, candle shape (IBS), multi-horizon agreement, VPIN context, micro-price lean, and a regime bonus/penalty.

* **Gate** — trade only if score ≥ `InpMinScore` (0.45).
* **Size** — `InpSizing = META` scales risk 0.5×→1.0× of base between `InpMinScore` and `InpScoreFullSize`; `KELLY` additionally multiplies by a fractional-Kelly factor computed from the **live** win-rate/payoff (only after `InpKellyMinTrades`), clamped 0.25×–2.0× and hard-capped at `InpMaxRiskPercent`.

## 5. Exits (unchanged, research-backed)

TP1 0.6R → close 70%; breakeven +0.05R; ATR trail 1.2× after 0.9R; TP2 2.2R (inside the 1.5–3.5R robust band); time stop 12 bars below 0.15R; session/Friday flat; news flat 3 min pre-event.

## 6. The maths you must accept (same as v1)

TP1 0.6R ⇒ pre-cost breakeven win rate 62.5%; with the runner the realised breakeven sits ~53–57%. The dashboard shows `Win / payoff … need X%` live — if your win rate stays below "need" for two weeks the edge isn't there.

## 7. How to validate honestly (López de Prado)

Do **not** tune inputs on one backtest and trust the number:

1. Split data; keep a true out-of-sample block untouched.
2. Count every parameter combination you try, then apply the **deflated Sharpe ratio** — a single "great" backtest out of hundreds is expected by chance.
3. Prefer combinatorial purged CV / multiple paths over a single walk-forward line.
4. Forward-test on demo before any live risk.

The EA cannot do this for you; it only keeps costs realistic and reports live expectancy so you can compare against the backtest.

## 8. Tuning

| Want | Change |
|---|---|
| More trades | `InpMinScore` 0.45→0.35, `InpFadeZ`/`InpFlowZ` →1.5, `InpFadeLookback` →8, `InpCooldownMin` →4 |
| Fewer, higher-quality | `InpMinScore` →0.55, `InpEngine=FADE`, window 12:00–17:00 GMT |
| Higher win rate | `InpTp1R` →0.45, `InpTp1ClosePct` →85 |
| Bigger winners | `InpTp1ClosePct` →50, `InpTp2R` →3.4, `InpTrailAtrMult` →1.8 |
| Let sizing compound the edge | `InpSizing=KELLY` (needs ≥20 closed trades first) |

## 9. Troubleshooting: "no trades in backtest"

The dashboard's **WHY / DIAGNOSTICS** section tells you exactly what is blocking, refreshed every closed M5 bar:

* **Engine state** — LIVE/PAUSED and which engines the current regime enables.
* **Gate** — `OPEN` or `BLOCKED - <reason>` (window, day, news, spread, streak, cooldown, STORM, VPIN...).
* **Fade check / Flow check** — the nearest-miss for each engine with the actual numbers, e.g. `|z| 1.20 < 1.80` or `eff 0.71 > 0.50 (no absorption)` or `READY BUY score 0.52 >= 0.45`.
* **Bars evaluated** — total bars checked plus how many reached the score gate (`fade-ready`, `flow-ready`). If these stay 0, the thresholds are too strict for your data.

**Most common cause on M5 = the spread cap.** M5 ATR for gold is small (~$1.5–3), so a $0.24 spread is ~10–20% of ATR. v2's default is now `InpMaxSpreadAtrPct = 25` for this reason. If the gate shows `spread NN% ATR`, raise `InpMaxSpreadAtrPct` further or use `InpMaxSpreadPoints` instead. In the Strategy Tester also check *Ticks/spread modelling*: use "Every tick based on real ticks" and a realistic (not huge) spread, otherwise the tester's modelled spread alone blocks everything.

Other quick checks if `fade-ready`/`flow-ready` stay 0: lower `InpMinScore` (0.45→0.35), lower `InpFadeZ`/`InpFlowZ` (→1.5), and confirm the **Data source** row shows `real ticks` or `candle proxy` (not `no flow data`).
