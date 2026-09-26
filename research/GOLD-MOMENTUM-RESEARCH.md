# Deep Research → Strategy Design: Intraday Momentum on Gold (XAU/USD), M1 / M5

**Goal of this document:** collect the published evidence on *intraday momentum* (time‑series
momentum on minute data), figure out which parts of it actually survive on gold, and turn that into
one concrete, mechanical rule set that can be coded as an MT5 Expert Advisor with
**no fixed stop loss and no fixed take profit** — every exit driven by momentum / volatility.

---

## 0. Hinglish TL;DR (seedha matlab)

- Gold par short‑timeframe pe jo cheez **research me bar bar chali hai** wo hai *intraday time‑series
  momentum*: din ke andar jab price apne din‑ke‑open se **normal noise se zyada** door nikal jata hai,
  to wo move **din ke baaki hisse me continue hone ka tendency** rakhta hai.
- Randomly RSI/MACD crossover lena kaam nahi karta. Jo kaam karta hai: **"noise area" define karo,
  usse bahar nikalne par hi trade lo**, aur **trailing/momentum exit** use karo — fixed TP nahi.
- Fixed SL gold pe khaas kar ke bura hai kyunki gold ke **wicks** bade hote hain, fixed SL bar bar
  hit ho jata hai phir price wapas aapke direction me chala jata hai. Isliye **dynamic stop**
  (band + VWAP + ATR chandelier) use kiya gaya hai.
- Win rate low (~35‑45%) hoga, **payoff ratio ~2:1** — profit **bade winners** se aayega, har trade se
  nahi. Ye normal hai momentum systems me. Agar aapko 80% win rate chahiye to ye strategy aapke
  liye nahi hai (aur 80% win rate wale systems me RR 1:5 hota hai jo blow‑up karta hai).
- Session matter karta hai: **London open + London/NY overlap** me hi trade lo, Asian dead zone me nahi.
- EA me sab kuch input hai — optimize kar sakte ho, par **walk‑forward** karna (neeche section 8).

---

## 1. What the literature actually says

### 1.1 Intraday time‑series momentum is a real, repeatedly documented effect

| Study | Market | Finding relevant to us |
|---|---|---|
| Gao, Han, Li, Zhou — *Market Intraday Momentum* | SPY / index futures | The first half‑hour return predicts the last half‑hour return; effect is economically and statistically significant. |
| Jin, Kearney, Li, Yang (2020), *Intraday time‑series momentum: evidence from China*, **Journal of Futures Markets** 40:632–650 | Chinese commodity futures **incl. gold** | ITSM present in commodity futures, not just equities. |
| Reading/Centaur working paper, *Intraday time series momentum: global evidence* ([pdf](https://centaur.reading.ac.uk/95566/1/Accepted-Version.pdf)) | 16 developed markets | ITSM is "economically and statistically significant around the world"; strongly linked to liquidity provision and information absorption. |
| Caporale & Plastun (2021), *Gold and oil prices: abnormal returns, momentum and contrarian effects* ([pdf](https://d-nb.info/1234222981/34)) | **Gold, hourly + daily** | On days with abnormal returns, **gold keeps moving in the direction of the abnormal return until the end of that day** (momentum). Next‑day behaviour on gold flips to *contrarian*. Trading simulations: ~70% success on the same‑day momentum leg. |
| Holmberg, Lönnbark, Lundström — ORB + GARCH on **gold futures** (2009‑2014) | Gold futures | Opening Range Breakout is profitable on gold and outperforms buy‑and‑hold; volatility‑adjusted (GARCH) breakout thresholds improve it. |

**Take‑away #1 — the exploitable gold edge is *same‑day* momentum, not multi‑day.**
Caporale & Plastun explicitly find that gold's next‑day reaction is *contrarian*. So the EA must be
**intraday, flat by end of day**. Holding a gold momentum position overnight is trading against a
documented effect.

**Take‑away #2 — the trigger must be volatility‑normalised.** Both the gold ORB/GARCH paper and the
ITSM literature find that a *fixed* breakout distance is worse than one scaled by current volatility,
because gold's intraday volatility profile is extremely non‑uniform (Asian session $5–10 range vs
London/NY overlap $15–25+ range).

### 1.2 The best modern implementation blueprint: the "Noise Area" model

Zarattini, Aziz & Barbon (2024), **"Beat the Market: An Effective Intraday Momentum Strategy for
S&P500 ETF (SPY)"**, SSRN 4824172 / Swiss Finance Institute WP 24‑97
([SSRN](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4824172),
[SFI](https://www.sfi.ch/en/publications/n-24-97-beat-the-market-an-effective-intraday-momentum-strategy-for-s-p500-etf-spy)).

This is the paper the whole EA is built on, because it is the only well‑documented intraday momentum
system that is **explicitly designed with no fixed profit target**. Reported results (2007 → early
2024, net of costs): **+1,985% total, 19.6% annualised, Sharpe 1.33**, from a system with a **hit rate
in the low 40s** and a **~2:1 payoff ratio**.

Its mechanics:

1. **Volatility profile / "Noise Area".** For each minute‑of‑day `t`, estimate

   ```
   σ(t) = (1/N) · Σ_{d=1..N}  | P_d(t) / P_d(open) − 1 |
   ```

   i.e. *the average absolute distance from the day's open that price has travelled by this exact
   time of day over the last N days.* This automatically encodes intraday volatility seasonality —
   the band is narrow at the open and widens through the session (the "noise cone").

2. **Bands.**

   ```
   Upper(t) = max(Open_today, Close_yesterday) · (1 + M·σ(t))
   Lower(t) = min(Open_today, Close_yesterday) · (1 − M·σ(t))
   ```

   Inside the cone = ordinary oscillation → stay flat. Outside = abnormal demand/supply imbalance.

3. **Entry:** bar closes above `Upper` → long; below `Lower` → short.

4. **Exit — and this is the important part — there is no take profit.** The position is trailed by
   **`max(session VWAP, current band)`** for a long and **`min(session VWAP, current band)`** for a
   short, and force‑closed at the session end. Because σ(t) grows through the day, the band itself
   is a *rising* line for a long, so it works as a natural trailing stop.

5. **Sizing:** volatility targeting (target a constant daily portfolio volatility), not fixed lots.

The exit study inside the paper is what justifies our design:

| Exit variant | Annualised | Sharpe |
|---|---|---|
| Simple stop policy | 6.2% | 0.61 |
| **Band + VWAP dynamic trailing stop** | 9.7% | **1.24** |
| + dynamic volatility‑targeted sizing | 19.6% | 1.33 |

Independent replication by *Quantitativo* on ES/NQ futures
([link](https://www.quantitativo.com/p/intraday-momentum-for-es-and-nq)) confirmed the edge is
statistically real (p‑value of event vs non‑event days well below 0.05), reported **+4 bps expected
return per trade after costs, 39% win rate, ~2:1 payoff**, and found that **lengthening the σ
lookback from 14 to 90 days improved Sharpe from 0.91 → 1.25**. That is a directly transferable
parameter insight, and it is why `InpLookbackDays` in the EA is an optimisable input (default 20,
worth testing up to 60–90 on gold).

### 1.3 Gold‑specific evidence for dynamic (non‑fixed) stops

Bhatti (2026), *A Regime‑Filtered Intraday Trading Framework for Gold: Integrating VWAP
Microstructure and EMA‑Based Dynamic Exit Mechanisms*, SSRN 6650958
([link](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=6650958)) attacks exactly the problem the
user described. Its stated motivation:

> "(i) the propensity of gold prices to produce aggressive intrabar wicks that prematurely trigger
> conventional fixed‑distance stop‑loss orders, and (ii) the difficulty of managing open profit as
> price approaches known institutional reference levels."

Its answer is VWAP as the structural reference + EMAs as dynamic trailing stops. Reported on XAU/USD
15‑minute, 247 trades in 2024: **win rate 45.3%, +0.414R expectancy, profit factor 1.76, max DD 5.1%**
at 1% risk/trade, beating a plain EMA crossover benchmark.

**Take‑away #3 — for gold specifically, the published evidence supports: VWAP anchor + EMA/ATR dynamic
trail + no fixed SL. That is exactly what the user asked for, and it is not a compromise — on gold it
is the *better* design.**

### 1.4 Session / time‑of‑day

Consistent across broker research and Batten et al.'s work on gold intraday periodicity: gold's
intraday volatility is bimodal and tied to market opens.

| GMT window | Regime | Use |
|---|---|---|
| 00:00 – 06:00 | Asian, $5–10 range, wide spreads | **No trading.** Builds the range that London breaks. |
| 07:00 – 10:00 | London open — single most volatile 2‑hour window | **Trade.** Asian‑range breakouts, momentum initiation. |
| 10:00 – 12:00 | London mid | Trade (continuation only). |
| 12:00/13:00 – 17:00 | **London/NY overlap — 60‑70% of the daily range forms here**, tightest spreads | **Prime window.** |
| 17:00 – 20:00 | NY afternoon | Trade with reduced expectation. |
| 20:00 – 00:00 | Dead zone, widest spreads | **Flat.** |

Default EA session is therefore **07:00–20:00 GMT** with a **force‑flat at 20:30 GMT**, and a
conservative preset restricted to **12:00–17:00 GMT** (overlap only).

---

## 2. What was rejected, and why

| Rejected idea | Reason |
|---|---|
| Fixed SL / fixed TP in points or pips | Directly contradicts the user requirement, *and* the gold literature (§1.3): fixed distances get wicked out, and a fixed TP truncates the right tail that the entire positive expectancy depends on (39% win rate × 2:1 payoff only works if the winners are allowed to run). |
| Multi‑day / swing momentum on gold | Caporale & Plastun find **next‑day gold behaviour is contrarian**. Holding overnight trades against the documented effect. |
| Grid / martingale / averaging down | No academic support; catastrophic on a $3,000+ instrument with $20 intraday swings. Explicitly not implemented. |
| Pure RSI/MACD/Stochastic crossovers | No volatility normalisation → the same signal means totally different things at 03:00 and 14:00 GMT. Used here only as *secondary filters*, never as the primary trigger. |
| Martingale‑free but fixed‑lot sizing | The paper's biggest single improvement (Sharpe 1.24 → 1.33, return 9.7% → 19.6%) came from **volatility‑scaled sizing**. The EA implements ATR/stop‑distance‑based % risk sizing, which is the MT5‑practical equivalent. |
| Trading all 24h | ~65% of the daily range forms in 3–4 hours; the rest is spread‑bleed for a breakout system. |
| Cherry‑picking one "magic" parameter set | Quantitativo's own attempt to extend the model to a large basket failed — that is selection bias in action. Hence the walk‑forward protocol in §8. |

---

## 3. Final strategy specification (what the EA implements)

**Instrument:** XAUUSD (any broker suffix). **Timeframe:** M5 primary, M1 supported.

### 3.1 Context, recomputed on every closed bar

```
dayStart    = open time of the current D1 bar (broker day)
todayOpen   = D1 open,   prevClose = previous D1 close
σ(t)        = mean over last N valid weekdays of | Close_d(t) / Open_d − 1 |
              where t = seconds-into-day of the just-closed bar
Upper(t)    = max(todayOpen, prevClose) · (1 + M·σ(t))
Lower(t)    = min(todayOpen, prevClose) · (1 − M·σ(t))
VWAP        = Σ(typical price · tick volume) / Σ(tick volume), from dayStart
ATR         = ATR(14) on the entry timeframe, in USD
```

### 3.2 Entry (all conditions, on bar close)

1. `Close[1] > Upper + 0.05·ATR` → long candidate; `Close[1] < Lower − 0.05·ATR` → short candidate.
2. **Anti‑chop:** band width `Upper − Lower ≥ 0.60·ATR`.
3. **Body filter:** breakout candle body `≥ 0.35·ATR` (rejects doji breakouts — the same rule
   Zarattini uses in his ORB screener: *"if the first candle is a doji: no trade"*).
4. **ADX(14) ≥ 18** — trend strength present.
5. **VWAP agreement:** long only if `Close[1] > VWAP`; short only if `Close[1] < VWAP`.
6. **EMA agreement:** long only if `EMA21 > EMA55` **and** `Close[1] > EMA20`; mirrored for shorts.
7. **Volatility regime:** `ATR ≥ 0.40` USD (skips the dead Asian tape even if the clock filter is
   loosened); optional upper ATR cap to skip NFP/CPI chaos.
8. **Session:** inside the trading window, not Friday late, spread inside limits.
9. **Risk gates:** trades‑today, consecutive‑loss, daily‑loss and daily‑profit‑lock all clear,
   cooldown after last exit elapsed.

### 3.3 Exit — 100% dynamic, no fixed SL, no fixed TP

The stop level is recomputed every closed bar as the **tightest** of the enabled trails
(`max(...)` for longs, `min(...)` for shorts), then **ratcheted** (it can only ever move in the
profit direction, never back):

| Trail component | Long level | Rationale |
|---|---|---|
| Noise‑area band | `Upper(t)` | Price re‑entering the noise area = momentum gone (paper's core exit). Rises through the day as σ(t) grows. |
| Session VWAP | `VWAP` | Institutional reference level; the paper's second trailing stop; Bhatti's primary gold reference. |
| Chandelier | `highestHigh_since_entry − 2.2·ATR` | Locks in the right tail of big trend days. |
| EMA flip | `EMA20 − 0.30·ATR` | Momentum‑reversal exit. |

Two clamps applied afterwards:

- **Breathing room:** the stop is never closer than `1.0·ATR` to the last close — this is the explicit
  answer to gold's wick problem.
- **Disaster boundary:** the stop is never further than `7.0·ATR` from price.

Additional exits: force‑flat at session end, Friday flat before the weekend, optional bar‑count time
stop, and an immediate flat if a daily risk guard trips.

**Broker‑side stop:** the dynamic level is *pushed to the broker as the position's SL* and updated
every bar. This is **not** a fixed stop — it moves with the strategy — but it means a disconnect, a
VPS reboot or a violent spike still gets handled by the broker's server rather than by the EA. On a
gold EA this is not optional in practice. It can be switched off with `InpSyncStopToBroker=false`,
in which case exits happen on bar close only.

### 3.4 Sizing

`lots = (equity · risk%) / (stopDistance_in_USD / tickSize · tickValue)`, where `stopDistance` is the
distance to the **initial dynamic stop** (≈1 ATR). This is the MT5‑practical form of the paper's
volatility targeting: when gold's ATR expands, position size automatically shrinks.

---

## 4. Honest expectations

Anyone promising a high win rate on a momentum system is selling something. Based on the source
papers and their replications, the realistic profile of this design is:

| Metric | Realistic range |
|---|---|
| Win rate | 35 – 45 % |
| Payoff ratio (avg win / avg loss) | 1.8 – 2.5 : 1 |
| Profit factor | 1.2 – 1.8 |
| Trades | ~1 – 4 per day on M5 with the default filters |
| Worst losing streak | 6 – 10 trades — **plan for it** |
| Killer of the edge | Spread + slippage. Gold spreads of 30–50 points on a raw account are fine; 200+ points on a standard account will eat most of it. |

The strategy makes money on a **minority of strongly trending days** and bleeds slightly on the rest.
That is the whole point of removing the take profit.

---

## 5. Why "no fixed TP" is mathematically necessary here

With a 39% win rate, breakeven payoff is `(1−0.39)/0.39 = 1.56`. A fixed TP caps the payoff
distribution; the losers are *not* capped by an equivalent amount because the trailing stop still
lets adverse moves run to ~1 ATR. Empirically (Zarattini et al.'s exit table, §1.2) the unbounded‑
upside version roughly **doubles the Sharpe ratio** relative to the constrained one. Removing the TP
is not a stylistic choice — it is what makes the expectancy positive.

---

## 6. Known weaknesses / where this will hurt

1. **Choppy range days** — repeated band pokes, several small losses. Mitigated by ADX, body, band‑width
   and cooldown filters, and capped by `InpMaxTradesPerDay` / `InpMaxConsecLosses`.
2. **News spikes (NFP, CPI, FOMC)** — a 30‑second $20 spike can trigger an entry that instantly reverses.
   Mitigations: spread filter, optional `InpMaxAtrUsd` cap, and you should still add a news blackout
   at the VPS/manual level around 13:30 GMT on first Friday / CPI days.
3. **Broker dependence** — tick volume quality affects VWAP; spread and swap models differ. Always
   backtest on *your own broker's* data.
4. **Parameter sensitivity** — `InpBandMultiplier` and `InpLookbackDays` are the two most sensitive
   inputs. Do not over‑optimise them (see §8).
5. **σ(t) needs history** — the EA refuses to trade until `InpMinValidDays` of clean history exist.

---

## 7. Parameters worth optimising (in priority order)

| Rank | Input | Sensible grid |
|---|---|---|
| 1 | `InpBandMultiplier` | 0.8 → 1.8 step 0.1 |
| 2 | `InpLookbackDays` | 14, 20, 30, 45, 60, 90 |
| 3 | `InpChandelierATR` | 1.5 → 3.5 step 0.25 |
| 4 | `InpMinStopATR` | 0.6 → 1.6 step 0.2 |
| 5 | `InpAdxMin` | 0 (off), 15, 18, 22, 25 |
| 6 | Session window | 07–20, 08–18, 12–17 GMT |
| 7 | `InpMinBandWidthATR` | 0.3 → 1.0 step 0.1 |

Leave `InpRiskPercent` **out** of optimisation — it does not change the edge, only the leverage.

---

## 8. Validation protocol (do not skip this)

1. **Data.** Download full M1 history for your broker's gold symbol (History Centre → M1), minimum
   3 years. Strategy Tester → *Every tick based on real ticks*.
2. **Costs.** Set a realistic spread (do **not** use "current spread" in the tester — use a fixed
   value equal to your broker's typical gold spread, e.g. 25–40 points ECN / 150–250 points standard)
   and enter commission in the symbol settings.
3. **In‑sample / out‑of‑sample split.** Optimise on 2019‑01 → 2022‑12. Then run the *single best*
   parameter set, unchanged, on 2023‑01 → today. If OOS profit factor < 1.1, discard and start over.
4. **Walk‑forward.** 6‑month optimisation windows, 3‑month forward windows, rolled through the whole
   history. Look at the *aggregated forward* equity curve only.
5. **Robustness checks.** ±20% on each optimised parameter should not flip the result to a loss. Run
   M1 and M5 and check both are at least breakeven — a strategy that only works on one exact
   timeframe is curve‑fitted.
6. **Monte Carlo** on the trade sequence to estimate the realistic worst drawdown; size `InpRiskPercent`
   so that the 95th‑percentile drawdown is inside your tolerance.
7. **Forward test on demo for at least one month** before any real money. Spread and slippage
   behaviour in live gold is materially worse than in the tester.

---

## 9. Sources

- Zarattini, C., Aziz, A., Barbon, A. (2024). *Beat the Market: An Effective Intraday Momentum
  Strategy for S&P500 ETF (SPY)*. SSRN 4824172 / SFI WP 24‑97 —
  https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4824172
- Maróy, Á. (2025). *Improvements to intraday momentum strategies using parameter optimization and
  different exit strategies*. SSRN 5095349 — https://ssrn.com/abstract=5095349
- Bhatti, A. (2026). *A Regime‑Filtered Intraday Trading Framework for Gold: Integrating VWAP
  Microstructure and EMA‑Based Dynamic Exit Mechanisms*. SSRN 6650958 —
  https://papers.ssrn.com/sol3/papers.cfm?abstract_id=6650958
- Caporale, G. M., Plastun, A. (2021). *Gold and oil prices: abnormal returns, momentum and
  contrarian effects*. Financial Markets and Portfolio Management — https://d-nb.info/1234222981/34
- Jin, M., Kearney, F., Li, Y., Yang, Y. C. (2020). *Intraday time‑series momentum: Evidence from
  China*. Journal of Futures Markets 40, 632–650.
- *Intraday time series momentum: global evidence and links to market characteristics* —
  https://centaur.reading.ac.uk/95566/1/Accepted-Version.pdf
- Holmberg, Lönnbark, Lundström. *Day trading on the gold futures market using Opening Range
  Breakouts and GARCH.*
- Zarattini, C., Aziz, A. (2023). *Can Day Trading Really Be Profitable? Evidence of Sustainable
  Long‑term Profits from Opening Range Breakout (ORB) Day Trading Strategy.*
- Quantitativo (2025). *Intraday Momentum for ES and NQ* (independent replication) —
  https://www.quantitativo.com/p/intraday-momentum-for-es-and-nq
- Concretum Research. *Beat the Market with Intraday Momentum* —
  https://concretumgroup.substack.com/p/beat-the-market-with-intraday-momentum
- Session/volatility statistics for XAUUSD: NordFX trader guide, Ultima Markets academy,
  StarTrader gold day‑trading guide (all consistent on the 13:00–17:00 GMT overlap concentration).

---

## 10. Disclaimer

This is research and engineering work, not investment advice. Backtested and published results are
not a promise of future returns. No strategy is "mostly profitable" by construction — this one has a
documented edge in the literature and a sane risk framework, and it will still have losing weeks and
losing months. Test it yourself on your own broker's data before risking money.
