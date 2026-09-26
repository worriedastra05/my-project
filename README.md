# GoldMomentumEA — Intraday Momentum EA for XAU/USD (MetaTrader 5)

A research‑driven **momentum** Expert Advisor for gold on **M1 / M5**, with **no fixed stop loss and
no fixed take profit** — every exit is driven by momentum and volatility.

> Gold ke liye intraday momentum strategy, published research se banayi gayi.
> M1/M5 pe chalti hai. **Koi fixed SL/TP nahi** — sab kuch dynamic momentum exit.

---

## What's in here

| Path | What it is |
|---|---|
| [`research/GOLD-MOMENTUM-RESEARCH.md`](research/GOLD-MOMENTUM-RESEARCH.md) | The deep research: SSRN / journal papers on intraday momentum in gold, what was accepted, what was rejected, and the exact rule set derived from it. **Read this first.** |
| [`mql5/Experts/GoldMomentumEA.mq5`](mql5/Experts/GoldMomentumEA.mq5) | The MT5 Expert Advisor (single file, no external dependencies beyond the standard `Trade` library). |
| [`mql5/Presets/`](mql5/Presets/) | Three ready `.set` files: Balanced M5, Conservative overlap‑only M5, Aggressive M1. |
| [`docs/INSTALL-AND-BACKTEST.md`](docs/INSTALL-AND-BACKTEST.md) | Install steps, full input reference, backtest + walk‑forward optimisation protocol, troubleshooting. |

---

## The idea in 60 seconds

Published evidence (Zarattini–Aziz–Barbon SSRN 4824172; Caporale & Plastun on gold; Jin et al. on
commodity futures; Bhatti's VWAP/EMA gold framework) converges on one thing: **intraday time‑series
momentum is a real, exploitable effect, and on gold it is a *same‑day* effect.**

So the EA:

1. Builds a **"noise area"** around the day's open — a volatility cone whose width is the average
   absolute distance gold has travelled from its day open *at this exact time of day* over the last
   N days. This automatically handles gold's wildly uneven intraday volatility (Asian $5 range vs
   overlap $25 range).

   ```
   σ(t)     = mean_{last N days} | Close_d(t) / Open_d − 1 |
   Upper(t) = max(todayOpen, prevClose) · (1 + M·σ(t))
   Lower(t) = min(todayOpen, prevClose) · (1 − M·σ(t))
   ```

2. Enters **only** when a bar closes outside that cone — i.e. an abnormal demand/supply imbalance —
   and only if session VWAP, EMA 21/55, ADX, candle body, volatility regime, spread and session
   clock all agree.

3. Exits with **no target and no fixed stop**. The stop is recomputed every bar as the *tightest* of:

   | Trail | Long level |
   |---|---|
   | Noise‑area band | `Upper(t)` — rises through the day |
   | Session VWAP | `VWAP` |
   | Chandelier | `highestHigh_since_entry − 2.2·ATR` |
   | EMA flip | `EMA20 − 0.30·ATR` |

   …then clamped so it is **never closer than 1 ATR** (gold wick protection) and **never further
   than 7 ATR** (disaster boundary), and **ratcheted** so it only ever moves in the profit direction.
   Flat by the end of the session — gold's next‑day behaviour is documented as *contrarian*, so
   holding overnight trades against the edge.

4. Sizes positions by **% of equity risked to the initial dynamic stop**, so exposure shrinks
   automatically when gold's ATR expands.

---

## Quick start

1. Copy `mql5/Experts/GoldMomentumEA.mq5` → `MQL5/Experts/` in your MT5 data folder, compile (F7).
2. Copy `mql5/Presets/*.set` → `MQL5/Presets/`.
3. Attach to an **XAUUSD M5** chart, load `XAUUSD_M5_Balanced.set`.
4. **Set `InpBrokerGMTOffset` to match your broker** (GMT+2 winter / GMT+3 summer for most).
   Session inputs are in GMT; default window is 07:00–20:00 GMT, flat at 20:30 GMT.
5. Backtest with *Every tick based on real ticks* and a **realistic spread** before anything else.

Full detail: [`docs/INSTALL-AND-BACKTEST.md`](docs/INSTALL-AND-BACKTEST.md).

---

## Honest expectations

| Metric | Realistic range |
|---|---|
| Win rate | 35 – 45 % |
| Avg win / avg loss | ~2 : 1 |
| Profit factor | 1.2 – 1.8 |
| Trades | 1 – 4 per day (M5, default filters) |
| Worst losing streak | 6 – 10 trades |

This is a **convex** system: it makes its money on a minority of strongly trending gold days and pays
small tolls on the rest. That is exactly why the take profit was removed — capping the winners kills
the expectancy. If you want a high win rate, this is the wrong strategy.

Win rate ~40% rahega. Paisa 2-3 bade trending din se banega. Lagatar 6-8 chhoti losses normal hain.

---

## Built‑in risk controls

- % ‑of‑equity volatility‑scaled position sizing (`InpRiskPercent`, default 0.5%)
- Daily loss circuit breaker (`InpMaxDailyLossPct`, default 3%) and optional daily profit lock
- Max trades per day, max consecutive losses, post‑exit cooldown
- Spread filters (absolute points **and** as a fraction of ATR)
- Session + Friday flat‑out, never holds over the weekend
- Broker‑side moving stop so a VPS/internet failure still leaves you protected
- **No grid, no martingale, no averaging down** — anywhere in the code

---

## ⚠️ Disclaimer

Research and engineering work, **not investment advice**. Published and backtested results are not a
prediction of future performance. Trading leveraged gold can lose you more than you expect. Test on
demo first, on your own broker's data, with your own spread and commission.
