# 🥇 SSRM Gold EA — XAU/USD (MetaTrader 5)

Multi-timeframe Expert Advisor for **Gold (XAU/USD)**.
Strategy = **HTF Trend Bias + Support/Resistance + Liquidity Sweep (SSRM combo)**.
Har trade me **minimum 1:2 Risk-Reward** enforce hota hai. Chart par ek **Dashboard** dikhta hai jisme saari details + lot size hoti hai.

---

## ⚠️ Pehle imaandaar baat (zaroor padhein)
- Koi bhi EA **70% win rate ya daily 3-4 trades ki GUARANTEE nahi de sakta**. Market roz alag hota hai.
- Ye EA sirf **acche (A+) setups** par trade leta hai aur RR fix rakhta hai — isse aapka risk-reward hamesha aapke favour me rehta hai.
- Result **hamesha pehle Strategy Tester (backtest) aur Demo account** par verify karein — phir hi real paise lagayein.
- Gold volatile hai. Hamesha **stop loss** ke saath hi chalega (EA khud SL/TP lagata hai).

---

## 📥 Installation (steps)
1. MT5 kholein → menu **File → Open Data Folder**.
2. `MQL5\Experts\` folder me file **`XAUUSD_SSRM_EA.mq5`** copy karein.
3. MT5 me **MetaEditor** kholein (F4) → file par double click → **Compile** (F7). Koi error nahi aana chahiye.
4. MT5 me wapas aayein → **Navigator → Expert Advisors** me `XAUUSD_SSRM_EA` dikhega.
5. **XAU/USD** ka chart kholein. Recommended entry timeframe: **M5 ya M15**.
6. EA ko chart par drag karein → **Allow Algo Trading** ✅ tick karein → OK.
7. Upar-right corner me smiley 😊 hona chahiye aur toolbar ka **Algo Trading** button green hona chahiye.

---

## ⚙️ Settings (options kam aur simple)

| Setting | Matlab | Default |
|---|---|---|
| **Magic number** | EA ke trades ki pehchaan | 20260926 |
| **Lot mode** | `LOT_AUTO_RISK` (balance ke % se auto lot) ya `LOT_FIXED` | AUTO |
| **Risk % per trade** | Auto mode me har trade par kitna % risk | 1.0 |
| **Fixed lot** | Fixed mode me lot size | 0.01 |
| **Risk:Reward** | Minimum 2 (yani 1:2). Iske neeche nahi jaayega | 2.0 |
| **Higher timeframe** | Trend bias ke liye (H1 recommended) | H1 |
| **EMA fast / slow** | HTF trend EMA | 21 / 50 |
| **Lookback** | S/R aur liquidity ke liye kitne bars dekhe | 20 |
| **SL buffer (points)** | Sweep ke neeche/upar extra SL gap | 150 |
| **Max trades per day** | Din me max trades (3-4 rakhein) | 4 |
| **Session start/end hour** | Trading time window (server time) | 7 – 21 |

👉 **Lot size dono tarah**: Auto (risk %) ya Fixed — aap `Lot mode` se switch kar sakte ho. Dashboard me current lot logic dikhta hai.

---

## 📊 Strategy Logic (SSRM Combo) — simple bhasha me

1. **Trend Bias (Higher Timeframe)** — H1 par EMA21 vs EMA50. Fast upar = **Bullish**, neeche = **Bearish**. EA sirf trend ki direction me hi trade karta hai.
2. **Support / Resistance** — entry timeframe par pichhle `Lookback` bars ka recent high (resistance) aur low (support) nikalta hai.
3. **Liquidity Sweep + Rejection** —
   - **BUY**: Trend Bullish ho, price support ke **neeche wick maare (liquidity grab)** aur candle wapas support ke **upar close** ho (bullish rejection).
   - **SELL**: Trend Bearish ho, price resistance ke **upar wick maare** aur candle wapas resistance ke **neeche close** ho (bearish rejection).
4. **Entry / SL / TP** —
   - SL = sweep candle ke low/high se thoda beyond (buffer ke saath).
   - TP = risk distance ka **2x** (ya jo RR aap set karo, min 1:2).
5. **Control** — ek time par ek hi trade, din me max 3-4 trades, session time ke andar hi.

---

## 🖥️ Dashboard (chart par jo dikhega)
- Symbol, Higher TF + Entry TF
- Trend (Bullish / Bearish / Neutral)
- Position open hai ya nahi
- **Trades today: X / max**
- **RR target (1:2)**
- **Lot mode + lot size / risk %**
- Balance, Equity
- Wins / Losses aur **live Win rate %**
- Session ACTIVE hai ya closed

---

## ✅ Recommended shuruaat
1. Chart: **XAU/USD, M15**, HTF = **H1**.
2. Lot mode = **AUTO**, Risk = **0.5% – 1%** (naye ho to 0.5%).
3. Pehle **Strategy Tester** me 3-6 mahine ka backtest chalayein ("Every tick based on real ticks").
4. Phir **Demo** par 2-4 hafte chalayein.
5. Result acha lage tabhi chhote lot se real par shuru karein.

> Note: Values (EMA, lookback, RR, session hours) aap apne broker/backtest ke hisaab se tune kar sakte hain. Zyada trades chahiye = lookback kam ya session bada; behtar quality chahiye = RR/buffer badhayein.
