# GoldMomentumEA — Install, Inputs, Backtest & Optimisation Guide

> **Har cheez ka matlab neeche Hinglish me bhi diya hai.** Technical reference English me hai taaki
> MT5 ke input names se exactly match kare.

---

## 1. Install (5 minutes)

1. Open **MetaTrader 5** → `File` → **Open Data Folder**.
2. Copy `mql5/Experts/GoldMomentumEA.mq5` → into `MQL5/Experts/`.
3. Copy the three files from `mql5/Presets/` → into `MQL5/Presets/`.
4. In MT5 press **F4** (MetaEditor) → open `GoldMomentumEA.mq5` → **Compile** (F7).
   You should get `0 errors`.
5. Back in MT5: open an **XAUUSD M5** chart → drag `GoldMomentumEA` from the Navigator onto it.
6. In the dialog → **Common** tab → tick **Allow Algo Trading**.
   → **Inputs** tab → **Load** → pick `XAUUSD_M5_Balanced.set`.
7. Make sure the **Algo Trading** button in the toolbar is green.

**Hinglish:** MT5 ka data folder kholo, `.mq5` file `MQL5/Experts` me daalo, MetaEditor me F7 se
compile karo, phir XAUUSD ke M5 chart pe EA drag karo aur preset load kar lo. Algo Trading button
green hona chahiye.

### ⚠️ The one setting you MUST fix first: `InpBrokerGMTOffset`

The EA's session times are entered in **GMT** and converted to your broker's server time using this
offset. If it is wrong, the EA will trade the wrong hours.

To find it: look at the clock in MT5's **Market Watch** and compare it to GMT/UTC right now.

| Your broker's server time vs GMT | Set `InpBrokerGMTOffset` to |
|---|---|
| GMT+2 (most brokers, winter) | `2` |
| GMT+3 (most brokers, summer / many ECN all year) | `3` |
| GMT+0 | `0` |

Alternatively set `InpTimeMode = TM_SERVER` and enter the hours directly in your broker's server time.

**Hinglish:** Sabse pehle ye theek karo. Market Watch ki clock GMT se compare karo. Zyadatar brokers
GMT+2 (winter) ya GMT+3 (summer) hote hain. Galat offset = galat session = galat trades.

---

## 2. What the EA does (one paragraph)

Every closed M5 bar it rebuilds a **"noise area"** around the day's open — a volatility cone whose
width is the average absolute distance gold has travelled from its day open *at this exact time of
day* over the last N days. Inside the cone = noise, stay flat. A bar closing **outside** the cone,
confirmed by VWAP + EMA + ADX + candle body, is treated as a genuine demand/supply imbalance and the
EA enters **in the direction of the break**. There is **no take profit** and **no fixed stop**:
the position is trailed by the tightest of (rising band | session VWAP | Chandelier ATR | EMA flip),
ratcheted one way only, and force‑closed at the end of the session. Full reasoning and sources:
[`research/GOLD-MOMENTUM-RESEARCH.md`](../research/GOLD-MOMENTUM-RESEARCH.md).

---

## 3. Input reference

### 1. Identity
| Input | Default | Meaning |
|---|---|---|
| `InpMagic` | 20260926 | Unique ID. Change it if you run the EA on two charts. |
| `InpComment` | GoldMom | Order comment. |

### 2. Noise‑Area momentum core *(the actual signal)*
| Input | Default | Meaning |
|---|---|---|
| `InpLookbackDays` | 20 | Days used to build the intraday volatility profile σ(t). Bigger = smoother, slower bands. Research suggests testing up to 60–90. |
| `InpBandMultiplier` | 1.20 | Cone width in σ units. **Most sensitive input.** Higher = fewer, stronger signals. |
| `InpBreakoutBufferATR` | 0.05 | Extra push beyond the band required, in ATR. Filters borderline pokes. |
| `InpMinBandWidthATR` | 0.60 | If the cone is narrower than this × ATR, no trade (kills early‑morning micro‑noise). |
| `InpMinValidDays` | 8 | Refuse to trade until this many clean history days exist. |

### 3. Momentum confirmation filters
| Input | Default | Meaning |
|---|---|---|
| `InpUseVwapFilter` | true | Longs only above session VWAP, shorts only below. |
| `InpUseEmaFilter` | true | Needs EMA21 > EMA55 (long) and close above EMA20. |
| `InpEmaFastPeriod` / `InpEmaSlowPeriod` | 21 / 55 | Trend EMAs. |
| `InpUseAdxFilter` / `InpAdxPeriod` / `InpAdxMin` | true / 14 / 18 | Trend‑strength gate. Raise to 22–25 for fewer, cleaner trades. |
| `InpUseBodyFilter` / `InpMinBodyATR` | true / 0.35 | Rejects doji / wick‑only breakouts. |

### 4. Volatility regime
| Input | Default | Meaning |
|---|---|---|
| `InpAtrPeriod` | 14 | ATR on the entry timeframe. |
| `InpMinAtrUsd` | 0.40 | Minimum ATR in **US dollars**. On M5 gold typically runs 0.8–2.5. Blocks dead tape. Set 0 to disable. |
| `InpMaxAtrUsd` | 0.0 | Upper ATR cap (0 = off). Set e.g. 6.0 to skip post‑news chaos. |

### 5. Dynamic exits — **no fixed SL / no fixed TP**
| Input | Default | Meaning |
|---|---|---|
| `InpUseBandStop` | true | Exit when price falls back into the noise area (the paper's core exit). |
| `InpUseVwapStop` | true | Exit on a VWAP cross against the position. |
| `InpUseChandelier` / `InpChandelierATR` | true / 2.20 | Trail from the highest high (long) / lowest low (short) since entry. |
| `InpUseEmaStop` / `InpEmaStopPeriod` / `InpEmaStopATR` | true / 20 / 0.30 | EMA momentum‑flip trail. |
| `InpMinStopATR` | 1.00 | **Gold wick protection.** The stop can never sit closer than this × ATR to price. |
| `InpDisasterATR` | 7.00 | Catastrophe boundary. Not a strategy stop — gap/disconnect insurance only. |
| `InpSyncStopToBroker` | true | Pushes the moving trail to the broker as the position SL so it still works if your VPS dies. It **moves every bar** — it is not a fixed SL. Set false for pure bar‑close exits. |
| `InpMaxBarsInTrade` | 0 | Optional time stop in bars (0 = off). |

> **Hinglish:** SL/TP kahin bhi fix nahi hai. Stop har bar recompute hota hai aur sirf profit ki
> taraf move karta hai (ratchet). `InpSyncStopToBroker=true` ka matlab ye moving stop broker ke
> server pe bhi set hota hai — internet/VPS band ho jaye to bhi protection rahe. Chahe to false kar
> do, phir exit sirf candle close pe hoga.

### 6. Sessions & time
| Input | Default | Meaning |
|---|---|---|
| `InpTimeMode` | TM_GMT | Are the hours below GMT or server time? |
| `InpBrokerGMTOffset` | 3 | See §1. **Set this correctly.** |
| `InpSessionStartHour/Min` → `InpSessionEndHour/Min` | 07:00 → 20:00 GMT | Window for **new** entries. |
| `InpFlatAtSessionEnd` / `InpFlatHour` / `InpFlatMin` | true / 20:30 GMT | Force flat — never hold gold momentum overnight (see research §1.1). |
| `InpTradeMonday` / `InpTradeFriday` | true / true | Day filters. |
| `InpFridayStopHour` / `InpFridayFlat` / `InpFridayFlatHour` | 18 / true / 20 GMT | Weekend protection. |

### 7. Risk & money management
| Input | Default | Meaning |
|---|---|---|
| `InpLotMode` | LOT_RISK_PERCENT | `LOT_FIXED` or risk‑% sizing. |
| `InpFixedLot` | 0.01 | Used in fixed mode / as a fallback. |
| `InpRiskPercent` | 0.50 | % of **equity** risked to the initial dynamic stop (~1 ATR). Start at 0.25–0.5. |
| `InpMaxLot` | 5.0 | Hard cap. |
| `InpMaxDailyLossPct` | 3.0 | Daily circuit breaker — closes and stops for the day. |
| `InpDailyProfitLockPct` | 0.0 | Stop after +X% on the day (0 = off). Useful for prop‑firm rules. |
| `InpMaxTradesPerDay` | 6 | Over‑trading brake. |
| `InpMaxConsecLosses` | 4 | Pause the day after N losses in a row. |
| `InpCooldownBars` | 2 | Wait N bars after an exit before re‑entering. |

### 8. Execution
| Input | Default | Meaning |
|---|---|---|
| `InpAllowLong` / `InpAllowShort` | true / true | Direction switches. |
| `InpMaxSpreadPoints` | 400 | Skip entries when the spread is wider than this. On gold, 1 point = 0.01 USD for a 2‑digit symbol, so 400 pts = $4.00 — **lower this to ~40–80 on a raw/ECN account**. Check your symbol's digits first. |
| `InpMaxSpreadATRfrac` | 0.15 | Skip entries when spread > 15% of ATR. |
| `InpSlippagePoints` | 60 | Max deviation. |
| `InpShowPanel` | true | On‑chart dashboard (auto‑disabled during optimisation). |

---

## 4. Backtesting properly

```
Strategy Tester
  Expert      : GoldMomentumEA
  Symbol      : XAUUSD (your broker's exact symbol)
  Timeframe   : M5
  Modelling   : Every tick based on real ticks      <-- important
  Period      : at least 3 years
  Deposit     : realistic for your risk %
  Delays      : Random delay  (or 50-100 ms)
```

Before you run: `Tools → Options → Charts → Max bars in chart = Unlimited`, and download full M1
history for gold (`View → Symbols → your gold symbol → Bars/Ticks → Request`).

**Costs.** Do **not** trust the tester's default spread. Set a fixed spread equal to your broker's
typical gold spread and make sure commission is configured in the symbol spec. Momentum systems on
M1/M5 gold live or die on transaction costs — this is the number‑one reason a backtest looks great
and live trading doesn't.

**Hinglish:** "Every tick based on real ticks" mode zaroori hai. Spread apne broker ka realistic
daalo (tester ki default spread jhooth bolti hai). Commission bhi include karo. M1/M5 gold pe cost
hi sabse bada killer hai.

---

## 5. Optimisation without fooling yourself

Optimise in this order, one or two parameters at a time — never all 60 at once:

| Rank | Input | Grid |
|---|---|---|
| 1 | `InpBandMultiplier` | 0.8 → 1.8 step 0.1 |
| 2 | `InpLookbackDays` | 14, 20, 30, 45, 60, 90 |
| 3 | `InpChandelierATR` | 1.5 → 3.5 step 0.25 |
| 4 | `InpMinStopATR` | 0.6 → 1.6 step 0.2 |
| 5 | `InpAdxMin` | 0, 15, 18, 22, 25 |
| 6 | Session window | 07–20, 08–18, 12–17 GMT |
| 7 | `InpMinBandWidthATR` | 0.3 → 1.0 step 0.1 |

**Never optimise `InpRiskPercent`** — it changes leverage, not edge, and it will always pick the
maximum.

Optimisation criterion: use **Balance + max Sharpe Ratio** or a custom criterion, *not* "Maximum
balance". Then:

1. **In‑sample:** e.g. 2019‑01 → 2022‑12.
2. **Out‑of‑sample:** run the single best set, **unchanged**, on 2023‑01 → today.
   If OOS profit factor < 1.1 → throw it away, do not re‑optimise on the OOS window.
3. **Neighbourhood check:** the chosen values should sit on a *plateau* in the optimisation surface,
   not a lone spike. ±20% on each parameter must not turn profit into loss.
4. **Cross‑timeframe:** a set that works on M5 should be at least breakeven on M1 and M15.
5. **Demo forward test ≥ 1 month** before live money.

**Hinglish:** Ek saath sab optimize mat karo. Pehle in‑sample pe optimize, phir bina change kiye
out‑of‑sample pe chalao. Agar OOS me fail ho gaya to us set ko phenk do — OOS pe dobara optimize
karna cheating hai aur live me account udta hai. Aur best value hamesha ek "plateau" ke beech se
lo, akela spike mat lo.

---

## 6. Expected behaviour (so you don't panic)

| Metric | Realistic |
|---|---|
| Win rate | 35 – 45 % |
| Avg win / avg loss | ~2 : 1 |
| Profit factor | 1.2 – 1.8 |
| Trades | 1 – 4 / day on M5 |
| Worst losing streak | 6 – 10 trades |

This system earns on a **minority of strongly trending gold days** and pays small tolls on the rest.
If you see 60% of trades as small losses, that is the design working, not a bug.

**Hinglish:** Win rate 40% ke aas paas rahega — ye normal hai. Paisa 2-3 bade trending din se banega.
Lagatar 6-8 chhoti losses aana bilkul expected hai. Isiliye risk 0.25–0.5% rakho.

---

## 7. Troubleshooting

| Symptom | Fix |
|---|---|
| Panel says `not enough history (N days)` | Download more M1/M5 history for gold, or lower `InpMinValidDays`. |
| No trades ever | Check `InpBrokerGMTOffset`; check panel's "Session open"; lower `InpBandMultiplier`, `InpAdxMin`, `InpMinBandWidthATR`; check `InpMaxSpreadPoints` vs your real spread. |
| Panel says `spread too wide` constantly | Your `InpMaxSpreadPoints` is too low for your symbol's digit count, or your broker's gold spread is genuinely bad. |
| Entries fire but close instantly | Increase `InpMinStopATR` (more breathing room) and `InpCooldownBars`. |
| `Entry failed: 10030` | Filling mode issue — rare; the EA auto‑detects, but check the symbol allows IOC/FOK. |
| Many trades, all tiny losses | Chop. Raise `InpBandMultiplier` and `InpAdxMin`, or switch to the Conservative overlap preset. |

---

## 8. Risk warning

Backtests are not promises. Gold is one of the most violent retail instruments there is. Run this on
demo first, size small, and never disable `InpMaxDailyLossPct`. Nothing here is investment advice.
