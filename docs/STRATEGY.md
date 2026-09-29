# Double Breakout Gold — strategy specification

Version 1.00 · instrument: XAU/USD (works on any liquid CFD/future) · signal TF: M5–M15

---

## 1. Where the idea comes from

| Source | What it contributes |
|---|---|
| Zarattini, C. & Aziz, A. (2023) — *Can Day Trading Really Be Profitable? Evidence of Sustainable Long-term Profits from Opening Range Breakout (ORB) Day Trading Strategy*, SSRN **4416622** | The skeleton: trade the direction of the opening range break, stop on the opposite side of the range, target expressed as an **R multiple**, liquidate at end of day, risk ~1 % per trade. Reported 24 % hit rate, +0.13 R per trade on QQQ 2016-2023. |
| Zarattini, C., Barbon, A. & Aziz, A. (2024) — *A Profitable Day Trading Strategy For The U.S. Equity Market*, SSRN **4729284** | The edge concentrates in sessions whose opening window has **high relative volume** vs. its own 14-day average → the `InpMinRvol` filter. |
| Wang, C. & Gangwar, S. (2025) — *Optimizing Intraday Breakout Strategies on the NSE: A Block-Based Performance Evaluation*, SSRN **5198458** | Bootstrap p-values of raw ORB vs. buy-and-hold land around 0.45–0.50 → a naked single breakout is **not** statistically convincing; extra confirmation and cost modelling are required. |
| Independent replication on 5 index CFDs, 2015-2026 (MQL5 blog post 776235, Sep 2026) | Gross the paper reproduces (+0.131 R on NQ), **net of spread and slippage it is ≈ zero**. Conclusion: the pattern is real, the naive trade is not. Hence the second breakout, the spread cap, the ATR range filter and the news lock in this EA. |
| Gold intraday playbook (session structure, Asian-range → London break, 60 % body rule, 10–70 % retracement band, PDH/PDL as the institutional reference) | The gold-specific parameterisation used below. |

**Design conclusion:** keep the paper's risk skeleton (R-multiples, EoD exit, 1 % risk),
but do not take the *first* poke through the level. Require the market to break, fail to
reverse, and break again — a **double breakout**.

---

## 2. Definitions

* **Range window** `[RangeStart, RangeEnd)` — default 00:00–07:00 GMT (Asian session).
  `RangeHigh` / `RangeLow` = highest high / lowest low of the closed bars in the window.
* **Buffer** `B = InpBreakBufferAtr × ATR(signal TF, 14)` (min 2 points).
* **Breakout leg** — from the broken range boundary to the extreme reached before the
  first meaningful pullback (`b1Peak`).
* **R** — the distance between entry and the initial stop loss. Every target and every
  management trigger is expressed in R.

---

## 3. Session validity filters (checked once, when the range closes)

The session is **skipped entirely** if any of these fail:

1. `MinRangeAtrPct ≤ RangeSize / ATR(D1,14) × 100 ≤ MaxRangeAtrPct` (default 12 %–70 %).
   * too small → no participation, the break will be noise;
   * too wide → the daily move already happened overnight (classic gold trap).
2. `RVOL = volume(range window) / mean volume(same window, last 10 sessions) ≥ InpMinRvol`
   (off by default; 0.8–1.0 is the research-backed setting).
3. Day of week enabled, spread ≤ `InpMaxSpreadPoints`, no daily guard triggered.

---

## 4. Entry — the two stages

### Stage 1 — first breakout (`BREAK-1`)

On a **closed** signal bar:

```
long : close > RangeHigh + B
short: close < RangeLow  - B
body/range of that candle ≥ InpMinBodyRatio (default 0.55)
optional: close on the correct side of EMA(InpTrendMaPeriod) on InpTrendTF
```

Record `b1Level` (the broken boundary) and start tracking `b1Peak`
(running extreme of the leg) and `pullExtreme` (extreme of the retracement).

### Stage 2 — pullback and re-break (`PULLBACK` → `TRIGGER`)

```
retracement % = |b1Peak - pullExtreme| / |b1Peak - b1Level| × 100

retr  > InpMaxPullbackPct (70 %)            -> setup CANCELLED (failed break)
close back inside the range beyond B        -> setup CANCELLED
retr >= InpMinPullbackPct (20 %)            -> setup ARMED
```

When armed, the trigger level is

```
long : trigger = b1Peak + B      (TWO-LEVEL / BOTH mode: max(trigger, PDH + B))
short: trigger = b1Peak - B      (TWO-LEVEL / BOTH mode: min(trigger, PDL - B))
```

and the EA either

* **STOP mode (default)** — places a Buy-Stop / Sell-Stop at that price with SL and TP
  attached, lifetime `InpTriggerExpiryMin` (120 min). Cancelled if price falls back
  inside the range or the entry window closes; or
* **CLOSE mode** — waits for a bar to *close* beyond the trigger and enters at market
  (slower, fewer false fills, worse price).

### Modes

| `InpMode` | Requirement |
|---|---|
| `REBREAK` (default) | range break → pullback → re-break of the leg extreme |
| `TWOLEVEL` | range break **and** previous-day high/low break (no pullback needed) |
| `BOTH` | strictest: pullback re-break **and** the trigger must clear PDH/PDL |

A maximum of `InpMaxSetupsPerDay` (2) attempts per session are allowed, and at most
`InpMaxTradesPerDay` (2) actually filled trades.

---

## 5. Stop loss, targets, management

**Stop loss** (`InpSlMode`)

| Mode | Placement |
|---|---|
| `STRUCTURE` (default) | pullback swing extreme ∓ buffer — tightest, gives the best R |
| `RANGE` | opposite side of the session range (the original paper rule) |
| `ATR` | `InpAtrSlMult × ATR` from entry |

Every stop is clamped into `[InpMinStopAtr × ATR, InpMaxStopAtr × ATR]` and pushed
outside the broker `STOPS_LEVEL` + current spread.

**Position sizing** — `lots = (Balance × InpRiskPercent %) / (stopDistance / tickSize × tickValue)`,
normalised to the symbol volume step and sanity-checked against free margin.
Set `InpRiskPercent = 0` to trade `InpFixedLots` instead.

**Exits**

| Stage | Rule |
|---|---|
| TP1 | at `InpTp1R` (1.5 R) close `InpTp1ClosePct` (50 %) of the position |
| Breakeven | at `InpBeTriggerR` (1.0 R) move SL to entry + `InpBeLockR` (0.1 R) |
| Trailing | after `InpTrailStartR` (1.2 R) trail by `InpTrailAtrMult × ATR` (1.6) |
| TP2 | hard take profit at `InpTp2R` (3 R) |
| EoD | everything flat at `InpFlattenTime` (20:30 GMT) — the paper's no-overnight rule |
| Friday | optional force-flat at `InpFridayCloseHour` GMT |

---

## 6. Timezone / DST detection

Brokers run GMT+2/+3 (with or without DST), so hard-coded session hours silently break
twice a year. The EA determines the offset with **two independent methods**:

1. **Live** — `round((TimeTradeServer() − TimeGMT()) / 30 min)`.
2. **History** — the first H1 bar of each of the last ~14 trading weeks is compared with
   the known FX/gold weekly open (New York Sunday 18:00 = **22:00 UTC** in US summer time,
   **23:00 UTC** in winter). Each week votes for an offset; the winning offsets for the
   summer and winter regimes are stored, which also reveals **whether the broker observes
   DST at all**.

The history method is used inside the Strategy Tester and whenever the two disagree by
more than 30 minutes (typically a wrong PC clock). `InpManualOffset` overrides everything.

Session inputs can be given in GMT (`InpTimeBase = GMT`, recommended — DST-proof) or in
raw broker time. The dashboard shows server time, the detected offset + DST state, UTC,
local PC time, and New York / London / Tokyo / Sydney clocks with the active sessions.

---

## 7. News filter (MT5 Economic Calendar)

* Events are pulled with `CalendarValueHistory()` + `CalendarEventById()` +
  `CalendarCountryById()` for a −2 / +4 day window, refreshed every
  `InpNewsReloadMinutes` (30 min).
* Filters: currency (`AUTO` = the symbol's own currencies, or `ALL`, or `"USD,EUR"`)
  and importance (`HIGH` / `HIGH+MED` / `ALL`). Events with `time_mode != DATETIME`
  (floating / all-day entries) are ignored.
* **Lock window:** `[event − InpNewsMinsBefore, event + InpNewsMinsAfter]`
  (default **−30 min / +30 min**). While locked:
  * no new setups are triggered,
  * pending trigger orders are deleted (`InpNewsDeletePending`),
  * open positions are closed `InpNewsCloseBeforeMin` minutes before the release
    (`InpNewsClosePositions`).
* After the window expires the EA re-arms itself automatically and the dashboard turns
  green again; the panel always shows the next event, its impact and a live countdown.
* `InpNewsShiftMinutes` corrects brokers whose calendar feed is shifted.
* For backtests, `DBG_ExportCalendarCSV.mq5` dumps the calendar to
  `Common\Files\DBG_News.csv` and the filter reads it transparently.

---

## 8. Dashboard

Five live sections + footer:

1. **Clock & timezone** — server time, detected broker zone (+ DST state and a plain-language
   guess such as *Europe/Athens (typical FX broker, summer)*), UTC, local PC time,
   NY/LON/TOK/SYD clocks, active sessions, the configured range/entry windows.
2. **Market** — symbol/TF, bid/ask/spread (red when the spread cap is exceeded),
   ATR on the signal TF and D1, session RVOL.
3. **Strategy** — current phase (waiting → building → armed → break-1 → pullback →
   trigger live → in trade), the range with its % of daily ATR, the trigger level and
   its expiry, live position with R-multiple and P/L, SL/TP with `[BE]` / `[TP1 done]` flags.
4. **News filter** — CLEAR / LOCKED with resume countdown, next event (time, currency,
   impact, name, countdown), and the configured window.
5. **Risk & statistics** — balance/equity/free margin, today's P/L in money and %,
   trades W/L, risk per trade in money, and guard counters.

Buttons: **PAUSE/RESUME** (stops new setups, keeps managing open trades),
**CLOSE ALL** (flattens this EA's positions and orders), **_** (minimise the panel).

---

## 9. Suggested workflow

1. Compile, attach to XAUUSD M15, leave `InpTimeBase = GMT`.
2. Check the panel: does "Broker zone" match your broker's known offset? If your PC clock
   is wrong the history detector wins automatically; otherwise set `InpManualOffset`.
3. Export the calendar CSV, then backtest 2–3 years on real ticks **with real spread**.
4. Optimise in this order: `InpBreakBufferAtr` → pullback band → `InpTp2R` / trailing →
   range ATR filter. Do **not** optimise the risk inputs.
5. Forward-test on demo for at least 4 weeks before going live, then start at 0.25 % risk.
