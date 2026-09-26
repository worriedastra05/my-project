# Cross-Sectional Momentum EA for MetaTrader 5

A production-ready MQL5 Expert Advisor implementing **classical cross-sectional
(relative-strength) momentum** — the Jegadeesh–Titman sort, applied to FX the
way Menkhoff, Sarno, Schmeling & Schrimpf (2012) did it, with Barroso–Santa-Clara
volatility scaling and ATR stop-loss / take-profit on every leg.

> At each rebalance the EA ranks your whole universe, **buys the top N**, **sells
> the bottom N**, sizes each leg by inverse volatility toward a portfolio
> volatility target, and attaches an ATR stop and target to each position.

📖 **Read [`docs/STRATEGY.md`](docs/STRATEGY.md) before using this** — it covers the
research, why each default was chosen, and an honest section on how much this
edge has decayed since the original studies.

---

## Quick start (Hinglish)

1. **File copy karo** → `MQL5/Experts/CrossSectionalMomentum/CrossSectionalMomentumEA.mq5`
   ko apne MT5 data folder me daalo:
   MT5 → `File` → `Open Data Folder` → `MQL5` → `Experts` → yahan paste karo.
2. **MetaEditor** kholo (MT5 me `F4`), file open karo, **`F7`** dabao → compile.
   `0 errors, 0 warnings` aana chahiye.
3. MT5 me `Ctrl+N` → Navigator → **Expert Advisors** → EA ko kisi bhi chart pe
   drag karo (koi bhi chart chalega — EA khud saare symbols handle karta hai).
4. `Common` tab me **Algo Trading allow** karo, aur toolbar ka **Algo Trading**
   button green hona chahiye.
5. `Inputs` tab → **Load** → `MQL5/Presets/CSMOM_FX_G10_Monthly.set`.
6. **Pehle DEMO account pe chalao.** Kam se kam ek pura rebalance cycle
   (default = 1 mahina) dekho, phir hi live socho.

⚠️ Ye ek long/short portfolio strategy hai — ek saath 6 positions tak khulengi.
Iske liye account me thoda margin chahiye. Default risk = total 2.5% equity.

---

## What's in here

```
MQL5/
  Experts/CrossSectionalMomentum/
    CrossSectionalMomentumEA.mq5     the EA (single file, no dependencies
                                     beyond the stock Trade\Trade.mqh)
  Presets/
    CSMOM_FX_G10_Monthly.set         paper-faithful MOM(1,1), monthly
    CSMOM_FX_G10_Weekly.set          faster variant, weekly
docs/
  STRATEGY.md                        research basis, defaults, caveats
tools/mql5check/                     dev-only static checker (see below)
```

---

## Installation

1. In MT5: `File → Open Data Folder`.
2. Copy `MQL5/Experts/CrossSectionalMomentum/` into `MQL5/Experts/`.
3. Copy the `.set` files into `MQL5/Presets/`.
4. Open MetaEditor (`F4`), open `CrossSectionalMomentumEA.mq5`, press `F7`.
5. Back in MT5, refresh the Navigator and drag the EA onto **any one chart**.

The EA is multi-symbol: it trades the whole universe from whatever chart it is
attached to. One instance only — do not run it on several charts at once with
the same magic number.

---

## Key inputs

| Input | Default | What it does |
|---|---|---|
| `InpSymbols` | 9 G10 pairs | The ranking universe. Needs ≥6 to be meaningful. |
| `InpSymbolSuffix` | `""` | Set to `.a`, `m`, `_ecn`… if your broker suffixes names. Auto-detected if left blank. |
| `InpUniverseMode` | `FX vs USD` | Normalises `USDJPY`-style quotes so every symbol is ranked on the same axis. Use `RAW` for indices/crypto/stocks. |
| `InpFormationBars` | `21` | Formation period *f*. 21 D1 bars ≈ 1 month (the FX optimum). Use `252` for equities. |
| `InpSkipBars` | `0` | Skip the most recent *k* bars. Use `21` with equities for the classic "12-1". |
| `InpSignalType` | vol-adjusted | Raw return (literal J-T) or return / volatility. |
| `InpLongCount` / `InpShortCount` | `3` / `3` | Legs per side. |
| `InpUseDualMomentum` | `true` | Only buy a winner if its own momentum is positive too. |
| `InpRebalanceMode` | Monthly | Holding period *h*. Monthly is what the literature supports. |
| `InpSizingMode` | Inverse vol | Fixed lot / equal risk % / inverse-volatility risk parity. |
| `InpPortfolioRiskPct` | `2.5` | Total equity at risk across all legs. |
| `InpTargetVolAnnual` | `10.0` | Portfolio volatility target (Barroso–Santa-Clara scaling). |
| `InpSL_ATR` / `InpTP_ATR` | `2.5` / `5.0` | **Stop loss and take profit**, in ATR multiples. `0` disables. |
| `InpUseTrailing` | `true` | ATR trailing stop after `InpTrailStart_ATR` of profit. |
| `InpMaxDrawdownPct` | `20.0` | Hard kill-switch: flattens the book and stops trading. |

Full list with tooltips is in the EA's Inputs tab.

### Risk controls

- **Per-leg ATR stop-loss and take-profit**, distances floored at the broker's
  `stops_level` and at 2× the current spread.
- **Break-even** move and **ATR trailing stop**.
- **Position sizing from the stop**: lots are derived so that hitting the stop
  loses exactly the budgeted risk.
- **Portfolio volatility target** using a live covariance matrix.
- **Gross leverage cap** and **margin cap**.
- **Daily loss pause** and a **hard drawdown kill-switch**.
- **Spread filter** that skips entries when the spread is wide relative to ATR.

---

## Backtesting

Strategy Tester settings:

- **Symbol / period**: any (e.g. `EURUSD`, `D1`) — the EA drives the universe itself.
- **Modelling**: `1 minute OHLC` is enough for a monthly rebalance and is much
  faster; use `Every tick based on real ticks` for a final check.
- **Deposit**: at least 10,000 of your account currency so six legs fit.
- **Period**: 5+ years.

Because it is multi-symbol, MT5 downloads history for the other symbols on the
first run. The first pass is slow, and early bars may be skipped while history
loads — that is expected and is logged as
`Not enough ... history for ... - excluded this cycle`.

Watch the Journal for `[CSMOM]` lines: the `Universe (...)` line should mark
every `USDxxx` symbol with `(inv)`, and each `Ranking:` line shows every score
with `/L` or `/S` on the selected legs.

---

## Developer tooling

`tools/mql5check/` contains a static checker that type-checks the EA with `g++`
against a shim of the MQL5 runtime, plus a test suite for the numerical logic.
Useful when editing the EA on a machine without MetaEditor. **MetaEditor remains
the authoritative compiler.**

```bash
bash tools/mql5check/check.sh       # syntax + type check the EA
python3 tools/mql5check/logic_test.py   # verify the maths (sign logic, sizing, vol targeting)
```

Both currently pass clean, including under `-Wall -Wextra -Wshadow -Wfloat-equal`.

---

## Disclaimer

This is educational software for systematic-trading research. Cross-sectional
momentum is a well-documented anomaly whose measured returns have **declined
substantially** since the original studies (see `docs/STRATEGY.md` §4). Past
performance does not predict future results. Trade a demo account first, and
never risk money you cannot afford to lose.
