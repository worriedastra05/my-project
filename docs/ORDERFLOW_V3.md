# Order Flow Gold v3 — spec

v3 ek **clean rewrite** hai. v2 ne do problems di thi:

1. **Compile fragility** — v2 ka main file bahut bada aur modular tha; ek diagnostics edit ne use tod diya.
2. **Zero trades in backtest** — v2 real tick-volume / VPIN pe depend karta tha. Strategy Tester me (jab tak "Every tick based on real ticks" na ho) wo data reliable nahi milta, isliye engine kabhi "ready" hi nahi hota → 0 trades.

v3 in dono ko fix karta hai:

- **Ek hi self-contained `.mq5` file**, sirf `#include <Trade/Trade.mqh>`. Koi cross-module include/merge nahi → compile risk minimal.
- **Candle-proxy order flow** — delta, CVD, VWAP sab OHLC + tick_volume se banta hai, jo har backtest model me milta hai. Isliye v3 tester me **actually trades leta hai**.

## Order flow (candle proxy)

| Metric | Formula (per bar) | Use |
|---|---|---|
| Delta | `tick_volume * (2*closePos - 1)`, `closePos=(close-low)/range` | buy vs sell pressure ka proxy |
| Delta z-score | rolling mean/std of delta over `InpDeltaLen` bars | flow ka spike detect |
| CVD | session ka cumulative delta | net pressure trend |
| VWAP | `sum(typical*vol)/sum(vol)`, daily/session reset | fair-value anchor |
| VWAP sigma | close ka dispersion around VWAP | distance ko normalize |
| Efficiency | `|net move| / gross path` over `InpFadeLook` bars | low = absorption (choppy), high = clean trend |
| Regime | ATR percentile over `InpRegimeLen` | CALM / NORMAL / TREND / STORM |

## Do engines

**FADE (reversal / absorption)** — SSRN 1712822 (Cont–Kukanov–Stoikov: bada order-flow bina price move = deep passive book = absorption). Conditions:
- Naya `InpFadeLook`-bar high/low bana
- `|delta z| >= InpFadeZ` (heavy flow)
- `efficiency <= InpFadeMaxEff` (move soak ho gaya, no follow-through)
- Rejection close (`closePos`) `>= InpFadeClose`
- VWAP se distance `>= InpFadeVwapSg` sigma
→ ulti direction me fade karo.

**FLOW (continuation)** — SSRN 2668277 (Cartea et al.: volume imbalance next move predict karta hai). Conditions:
- Candle body `>= InpFlowBody` (strong bar)
- `|delta z| >= InpFlowZ` aur delta candle ke saath aligned
- Price VWAP ke correct side pe
→ candle ki direction me continuation.

Dono engines ka **composite score** (0..1) nikalta hai; jiska zyada wahi trade hota hai, agar `>= InpMinScore`.

## SL / TP (tiered)

- SL = `ATR * InpSlAtr`
- TP1 = `InpTp1R` R pe `InpTp1Close`% band (default 0.6R @ 70%)
- BE: `InpBeAtR` R ke baad SL breakeven pe
- Trailing: `ATR * InpTrailAtr` after BE trigger
- Final TP = `InpTp2R` R (default 2.2R)
- Time stop: `InpTimeStopBar` bars ke baad agar P/L flat

TP1 0.6R @ 70% low-RR high-win profile deta hai (IJACSA / expectancy math: breakeven ~62.5% pre-cost, TP1 fill kaafi jaldi hit hota hai).

## Gate (kyu trade nahi hua — dashboard "WHY / DIAGNOSTICS" me dikhta hai)

Order: position open? → spread cap → daily trade cap → cooldown → trade window (GMT) → news blackout → score. Har rejection ka exact reason panel pe likha aata hai.

## News filter

MT5 economic calendar se `InpNewsCurr` (default USD,XAU) high-impact events. Blackout **`InpNewsBefore` min pehle se `InpNewsAfter` min baad tak** (default −30/+30), phir auto re-enable. (Note: Strategy Tester me calendar aksar khaali hota hai → live/forward pe hi news block dikhega.)

## Dashboard sections

CLOCK & TIMEZONE · MARKET & REGIME · ORDER FLOW (delta+z, CVD, VWAP, price-vs-VWAP sigma, efficiency) · SIGNAL ENGINE (last signal, position, trades today) · NEWS FILTER · **WHY / DIAGNOSTICS** (engine, gate reason, fade check, flow check, bars evaluated + ready counts). Chart pe session VWAP dotted line bhi.

## Install

1. `mt5/SingleFile/OrderFlowGoldV3_AllInOne.mq5` ko MetaEditor me kholo → **Compile** (0 errors aana chahiye).
2. `XAUUSD M5` chart → EA drag → **Algo Trading ON**.
3. Preset: `mt5/Presets/XAUUSD_M5_OrderFlowV3.set`. Magic `20260932` (v1/v2 ke saath alag, isliye saath chal sakta hai).

## Zyada entries chahiye (~7-8/day)?

`InpMinScore` → 0.30, `InpFadeZ`/`InpFlowZ` → 1.2, `InpFadeLook` → 8, `InpFadeMaxEff` → 0.65, `InpCooldownMin` → 2. Kam entries + high quality chahiye to ulta karo.

## Key inputs (defaults)

| Input | Default | Meaning |
|---|---|---|
| `InpTF` | M5 | timeframe (ya chart TF) |
| `InpDeltaLen` | 20 | delta z-score lookback |
| `InpFadeZ` / `InpFlowZ` | 1.5 / 1.4 | flow spike threshold |
| `InpFadeMaxEff` | 0.55 | absorption ceiling |
| `InpMinScore` | 0.35 | trade gate |
| `InpRiskPercent` | 0.35 | % balance per trade |
| `InpSlAtr` | 1.2 | SL = ATR × this |
| `InpTp1R / InpTp2R` | 0.6 / 2.2 | targets in R |
| `InpMaxTrades` | 8 | daily cap |
| `InpNewsBefore/After` | 30 / 30 | blackout window |
