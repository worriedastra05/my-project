# Order Flow Gold — strategy specification

Version 1.00 · XAU/USD · signal TF **M5** · target ~5–8 trades/day · low RR, high hit-rate

---

## 1. Research base

| Source | Contribution |
|---|---|
| Cont, Kukanov & Stoikov (2014), *The Price Impact of Order Book Events*, **SSRN 1712822** | Short-horizon price changes are ~**linear in Order Flow Imbalance**, with slope inversely proportional to depth. Large OFI + tiny price change ⇒ unusually deep/passive book ⇒ **absorption**. |
| Cartea, Donnelly & Jaimungal, **SSRN 2668277** | Volume imbalance predicts the side of the next market order and the post-trade price revision ⇒ basis of the continuation engine. |
| Vafin (2026), **SSRN 6938742** | Framework for evaluating OFI return predictability out-of-sample with realistic cost modelling. |
| Kethan S E (2026), **SSRN 7053198** | OFI has genuine IC (+0.0044, t=3.26) but a 10-second implementation dies on costs (gross Sharpe +0.98 → net −1.73). ⇒ **trade M5, not seconds; demand TP ≫ spread; cap spread against ATR.** |
| Lee & Ready (1991) | Quote rule for classifying trades as buyer/seller initiated. |

## 2. How order flow is measured on a gold CFD

Retail gold CFDs have no exchange volume and no depth, so the EA reconstructs the aggressor side tick by tick:

1. `TICK_FLAG_BUY` / `TICK_FLAG_SELL` if the broker supplies them;
2. otherwise `last` vs `bid`/`ask` (Lee–Ready quote rule);
3. otherwise the **mid-price tick rule** (uptick = buy, downtick = sell, unchanged = repeat) — this is the branch a CFD feed normally uses.

Each tick adds `volume_real` (or 1) to the buy or sell bucket of its M5 bar. From that:

* **Delta** = buy − sell of a bar; **CVD** = cumulative delta since the session anchor
* **z-score** of the bar delta vs the last `InpZLookback` (96) bars
* **Efficiency** = (body/range) ÷ (|delta| / average |delta|) → how much price the flow actually bought
* **VWAP + σ** built from the same buckets
* Tick rate (ticks/min) as an activity proxy

Tester / missing ticks fallback: `delta ≈ tickvol · ((C−L)−(H−C))/(H−L)`.

## 3. Engine B — ABSORPTION FADE (the high win-rate core)

On a closed M5 bar, for a **long**:

```
low[1] < lowest low of the previous InpFadeLookback (12) bars   -> new extreme
delta z-score      <= -InpFadeZ (1.8)                           -> heavy selling
(close-low)/range  >= InpFadeClosePos (0.60)                    -> price rejected the low
efficiency         <= InpFadeMaxEff (0.50)                      -> sellers absorbed
VWAP - close       >= InpFadeVwapSigma (0.8) x sigma            -> stretched from value
```
→ buy. Short is the mirror image. Stop below the signal bar low − 0.2 ATR, TP1 0.6 R.

Logic: heavy one-sided flow that cannot move price = passive limit orders on the other side. Cont et al.'s linear impact law says a large OFI with no price response implies unusual depth, and that depth is where the reversal starts.

## 4. Engine A — FLOW CONTINUATION (catches the big move)

```
|delta z|       >= InpFlowZ (1.8)      and candle closes in the flow direction
body            >= InpFlowMinBodyAtr (0.25) x ATR
efficiency      >= InpFlowMinEff (0.55)      -> flow really moves price
close breaks the previous bar high/low       (InpFlowNeedBreak)
CVD slope over InpCvdSlopeBars agrees        (InpFlowNeedCvd)
```
→ trade with the flow. Stop under the last two bars, TP1 0.6 R (70% off), the remaining 30% trails by 1.2 ATR up to TP2 2.2 R — that is the part that captures the extended move.

## 5. Exits (same for both engines)

| Stage | Rule |
|---|---|
| TP1 | 0.6 R → close 70% (this is what produces the high hit rate) |
| Breakeven | right after TP1, +0.05 R locked |
| Trail | after 0.9 R, 1.2 × ATR |
| TP2 | 2.2 R hard target for the runner |
| Time stop | after 12 bars (60 min) below 0.15 R → flat |
| Session | everything flat at `InpFlattenTime`, Friday cut-off |
| News | flat 3 min before a high-impact event, no entries −30/+30 min |

## 6. The maths you must accept

With TP1 = 0.6 R the **breakeven win rate is 1/(1+0.6) = 62.5%** before costs. The runner lifts the realised payoff to roughly 0.75–0.9, so the real breakeven sits near **53–57%**.

The dashboard shows this live: `Win rate  64% (9W/5L) | payoff 0.82 | need 55%`.
If "need" stays above your actual win rate for two weeks, the edge is not there — raise `InpFadeZ`/`InpFlowZ`, tighten `InpMaxSpreadAtrPct`, or shrink the trading window to London+NY only.

## 7. Guards

* max 8 trades/day, 8-minute cooldown after each entry
* max 4 losses in a row, −2.5% daily loss limit
* spread cap in % of ATR (broker independent), optional points cap
* optional minimum ATR (skips a dead market)
* one position at a time

## 8. Tuning for more / fewer trades

| Want | Change |
|---|---|
| More trades | `InpFadeZ`/`InpFlowZ` 1.8 → 1.5, `InpFadeLookback` 12 → 8, `InpCooldownMin` 8 → 4 |
| Fewer, better trades | z → 2.2, `InpEngine = FADE only`, window 12:00–17:00 GMT (London/NY overlap) |
| Higher win rate | `InpTp1R` 0.6 → 0.45, `InpTp1ClosePct` 70 → 85 |
| Bigger winners | `InpTp1ClosePct` 70 → 50, `InpTp2R` 2.2 → 3.5, `InpTrailAtrMult` 1.2 → 1.8 |
