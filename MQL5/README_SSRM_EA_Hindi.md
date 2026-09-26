# 🥇 Gold EA — XAU/USD (MetaTrader 5)

Is folder me 2 EA hain:

| File | Version | Kab use karein |
|---|---|---|
| **`XAUUSD_VWAP_SSRM_EA.mq5`** | **v2 (RECOMMENDED)** ✅ | VWAP + multi-confluence. Kam drawdown, behtar filter. |
| `XAUUSD_SSRM_EA.mq5` | v1 (purana) | Sirf S/R + liquidity. |

> **Naya (v2) hi use karein** — isme drawdown control aur confluence filters lage hain.

---

## ⚠️ Imaandaar baat (zaroor padhein)
- Koi bhi EA **70% win rate / daily 3-4 trades ki GUARANTEE nahi de sakta**.
- v2 ka maqsad: **kam drawdown + acche quality trades** — isliye chop (bina trend) me trade nahi leta, aur 2 loss ke baad din band kar deta hai.
- **Pehle Strategy Tester (backtest) + Demo** par test karein, phir chhote lot se real.
- Broker ka **spread kam (1-2 pips gold)** hona zaroori hai, warna scalping me nuksaan hota hai.

---

## 📊 v2 Strategy — kya-kya combine kiya (bariki se)

Research ke baad in sab ka combo banaya (aur weak/counter-trend signals hata diye jo drawdown de rahe the):

1. **Session VWAP (+/- 1σ band)** — institutions ka reference. Core setup = **trend-continuation VWAP bounce** (sabse reliable ~65-70%).
2. **200 EMA** — overall direction (uske upar sirf BUY, neeche sirf SELL).
3. **9 / 21 EMA cross** — short-term momentum.
4. **RSI 50-level** — momentum guardrail (50 ke upar buy, neeche sell).
5. **ADX filter** — ADX kam (chop/range) ho to **trade nahi** (yahi drawdown ka bada ilaaj hai).
6. **Confluence score (0-6)** — upar wale factors count hote hain; **kam se kam 4/6** match hone par hi entry.

### Entry trigger (must)
- **BUY:** trend up + price VWAP ke upar, candle VWAP tak pullback karke **wapas VWAP ke upar bullish close** kare.
- **SELL:** trend down + price VWAP ke neeche, candle VWAP tak pullback karke **wapas VWAP ke neeche bearish close** kare.

### Stops / Target (drawdown control)
- **SL = ATR × 1.5** (last-bar wali tight SL nahi → noise se stop-out kam).
- **TP = risk × 2** (minimum **1:2 RR**, kabhi neeche nahi).
- **Break-even:** 1R profit par SL entry par shift (loss ka risk khatam).
- **Trailing:** optional (ATR se) — default off.

### Risk management
- Ek time par **1 hi trade**.
- **Max 4 trades/din**, **2 loss ke baad din LOCK** (aur nuksaan nahi).
- **Spread filter** (zyada spread par trade nahi).
- **Session filter** (London/NY time; Asian chop avoid).

---

## ⚙️ Settings (simple, grouped)

**Risk/Lot**
- Lot mode: `AUTO %` ya `FIXED` (dono option) | Risk % = 1.0 | Fixed lot = 0.01 | RR = 2.0

**Confluence Filters**
- Trend EMA 200 | Fast 9 | Slow 21 | RSI 14 | ADX 14 | ADX min 20 | Min score 4

**Stops (ATR)**
- ATR 14 | SL = ATR×1.5 | Break-even at 1R | Trail ATR (0 = off)

**Trade Control**
- Max trades/day 4 | Max daily loss 2 | Max spread 400 pts | Session 7–21 (server)

---

## 📥 Installation
1. MT5 → **File → Open Data Folder** → `MQL5\Experts\` me `XAUUSD_VWAP_SSRM_EA.mq5` copy karein.
2. MetaEditor (F4) → file kholein → **Compile (F7)** (error na aaye).
3. **XAU/USD** ka chart kholein — recommended **M5** (ya M15).
4. EA chart par drag → **Allow Algo Trading** ✅ → OK. Toolbar ka **Algo Trading** green ho.

---

## 🖥️ Dashboard (chart par)
Symbol + TF · Bias + Confluence score (X/6) · VWAP aur ±1σ · ADX/RSI/ATR · Spread · Position · Trades today · **Losses today (LOCKED?)** · RR · Lot mode + lot/risk% · Balance/Equity · W/L + Win rate % · Session status.

---

## ✅ Recommended shuruaat
1. Chart: **XAU/USD M5**, Lot = **AUTO**, Risk = **0.5%** (naye ho to).
2. **Strategy Tester** me 3-6 mahine "real ticks" par backtest.
3. **Demo** 2-4 hafte.
4. Result acha → chhote lot se real.

### Tuning tips
- **Zyada trades chahiye** → Min score 3, ADX min 15, session bada.
- **Aur kam drawdown / better quality** → Min score 5, ADX min 25, RR 2.5-3.
- **M1** par chalana ho to spread bahut kam wala broker chahiye (M1 noisy hota hai).
