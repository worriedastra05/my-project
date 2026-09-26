# Backtest Guide — step by step (Hinglish)

Agar EA koi trade nahi le raha, is guide ko **line by line** follow karo.
Har step pe ek check hai. Jahan check fail ho, wahi problem hai.

---

## Step 0 — Recompile (sabse zaroori)

Purana `.ex5` file MT5 use karta rahega. Fix kaam nahi karega jab tak recompile
na karo.

1. MT5 → `File` → **Open Data Folder**
2. `MQL5` → `Experts` → yahan `CrossSectionalMomentum` folder hona chahiye
3. MT5 me **F4** (MetaEditor khulega)
4. Left panel → `Experts` → `CrossSectionalMomentum` → `CrossSectionalMomentumEA.mq5` **double click**
5. **F7** dabao

✅ **CHECK:** Neeche "Errors" tab me likha aana chahiye:
```
0 error(s), 0 warning(s)
```
❌ Agar errors aayein → mujhe exact error text bhejo.

---

## Step 1 — Apne broker ke symbol names pata karo

Ye sabse common problem hai. Bahut brokers `EURUSD` nahi, **`EURUSDm`** ya
**`EURUSD.a`** ya **`EURUSD_ecn`** use karte hain.

1. MT5 me **Ctrl+M** (Market Watch)
2. Market Watch me right-click → **Show All** / **Symbols**
3. Dekho EURUSD ka exact naam kya hai

✅ **CHECK:** Agar naam exactly `EURUSD` hai → kuch nahi karna.
⚠️ Agar `EURUSDm` jaisa hai → EA ab **khud detect** kar leta hai (v1.10 se),
bashart aap chart bhi usi suffix wale symbol ka use karo. Nahi to manually
`InpSymbolSuffix` = `m` set kar do.

---

## Step 2 — Strategy Tester settings (exact)

**Ctrl+R** → Strategy Tester. Ye settings **bilkul aise** rakho:

| Field | Value | Kyun |
|---|---|---|
| **Expert** | `CrossSectionalMomentum\CrossSectionalMomentumEA` | — |
| **Symbol** | `EURUSD` (ya jo bhi aapke broker pe hai) | EA khud saare symbols handle karta hai |
| **Period** | `M5` (ya `H1`) | Sirf tick frequency, strategy pe asar nahi |
| **Modelling** | `1 minute OHLC` | Multi-symbol ke liye tez aur kaafi hai |
| **Deposit** | **`10000`** | ⚠️ 1000 se kam mat rakhna — lots minimum se neeche chale jayenge |
| **Leverage** | `1:100` ya zyada | 4-6 legs ek saath khulti hain |
| **Date range** | **Neeche dekho** ⬇ | Sabse badi galti yahi hoti hai |
| **Forward** | `No` | abhi ke liye |

### Date range — ye sabse important hai

| Preset | Minimum test period | Kyun |
|---|---|---|
| `CSMOM_FX_M5_Intraday.set` | **1 mahina** kaafi | Har ghante rebalance |
| `CSMOM_FX_G10_Weekly.set` | **1 saal** | Haftawari rebalance |
| `CSMOM_FX_G10_Monthly.set` | **3+ saal** | Mahine me sirf 1 baar rebalance! |

> Monthly preset pe 1 mahine ka test = **0 ya 1 trade batch**. Ye bug nahi,
> design hai. Strategy hi mahine me ek baar portfolio banati hai.

---

## Step 3 — Settings tab pe "Algo Trading"

Strategy Tester ke **Settings** tab me neeche ek checkbox hota hai.
Wo **ticked** honi chahiye.

> v1.10 se EA terminal ka AutoTrading button check nahi karta jab tester me
> chal raha ho — pehle wo ek silent blocker tha.

---

## Step 4 — Preset load karo

Strategy Tester → **Inputs** tab → neeche **Load** button → preset choose karo:

- Pehli baar test karne ke liye: **`CSMOM_FX_M5_Intraday.set`**
  (1 mahine ke test me bhi trades dikhenge)
- Asli strategy ke liye: **`CSMOM_FX_G10_Monthly.set`** (3+ saal ka range)

Presets yahan hain: Data Folder → `MQL5` → `Presets`

---

## Step 5 — Start karo aur Journal padho

**Start** dabao, phir **Journal** tab kholo (Results tab nahi — **Journal**).

### 5a. Pehle ye banner dhoondo

```
[CSMOM] ===========================================================
[CSMOM]  Cross-Sectional Momentum EA v1.10 - starting up
[CSMOM]  chart=EURUSD PERIOD_M5 | tester=YES | visual=no
[CSMOM]  signalTF=PERIOD_M5 f=48 skip=0 | rebalance=REB_EVERY_N_BARS | legs=2L/2S
[CSMOM] ===========================================================
```

❌ **Ye banner nahi dikha?** → EA attach hi nahi hua ya recompile nahi hua.
Step 0 dobara karo.

### 5b. Phir universe line dhoondo

```
[CSMOM] Universe (7): EURUSD, GBPUSD, AUDUSD, NZDUSD, USDCAD(inv), USDCHF(inv), USDJPY(inv)
```

❌ **`Universe (0)` ya `(1)` dikha?** → Symbol names galat hain. Journal me
neeche EA aapke broker ke asli symbol names print karega:
```
[CSMOM] ---- symbols available at your broker containing "USD" ----
[CSMOM]   EURUSDm   GBPUSDm   AUDUSDm   USDJPYm   ...
```
Un names ko copy karke `InpSymbols` me paste kar do.

✅ `(inv)` tag `USDxxx` pairs pe hona chahiye — matlab quote-convention fix sahi lag raha hai.

### 5c. Ab DIAGNOSTICS table dhoondo

```
[CSMOM] SYMBOL          BARS   SPEC    ATR     SPREAD   SPR/ATR   MINLOT  CALCLOT  VERDICT
[CSMOM] EURUSD          5000     ok     ok    0.00012      1.7%     0.01   0.0240  READY
[CSMOM] USDNOK           800     ok     ok    0.00310     28.4%     0.01   0.0031  SPREAD TOO WIDE
[CSMOM] 6 of 7 symbols are ready to trade.
```

`VERDICT` column exact problem batata hai:

| VERDICT | Matlab | Fix |
|---|---|---|
| `READY` | Sab theek | — |
| `NOT ENOUGH HISTORY (n < m)` | Test start se pehle itna data nahi | Test start date peeche karo, ya `InpSignalTF` chhota karo (D1 → H1 → M5) |
| `NO CONTRACT SPEC` | Tester ne symbol abhi load nahi kiya | Kuch nahi — 2-3 bars me khud theek ho jayega |
| `LOT TOO SMALL` | Account chhota, ya SL bahut bada | Deposit badhao, ya `InpPortfolioRiskPct` badhao, ya `InpSL_ATR` kam karo, ya legs kam karo |
| `SPREAD TOO WIDE` | Spread ATR ke % limit se zyada | `InpMaxSpreadATRPct` badhao (intraday pe 30-50 rakho) |
| `ATR NOT READY` | ATR indicator warm-up | Kuch nahi — khud theek ho jayega |

### 5d. Aur ye lines bhi dekho

```
[CSMOM] Ranking: AUDUSD[1.842/L] EURUSD[0.913/L] ... USDJPY[-2.004/S]
[CSMOM] OPEN BUY AUDUSD 0.24 lots @ 0.65120  SL 0.64780  TP 0.65800  (score 1.842, w 0.187)
```

✅ `OPEN` lines aa rahi hain = **kaam ho gaya**.

---

## Agar ab bhi kuch nahi

Journal se ye teen cheezein copy karke bhejo:

1. `[CSMOM] ... starting up` wala banner (4 lines)
2. `[CSMOM] Universe (...)` wali line
3. Poora `DIAGNOSTICS` block (`VERDICT` column ke saath)

Aur ye bhi batao:
- Broker ka naam
- Account currency aur deposit
- `Trading blocked:` se shuru hone wali koi line dikhi?

---

## Quick settings cheat-sheet

**"Mujhe bas trades dekhne hain, abhi":**
```
Preset      : CSMOM_FX_M5_Intraday.set
Symbol      : EURUSD   Period: M5   Modelling: 1 minute OHLC
Deposit     : 10000    Leverage: 1:500
Date range  : pichhle 1 mahina
```

**"Mujhe asli strategy test karni hai":**
```
Preset      : CSMOM_FX_G10_Monthly.set
Symbol      : EURUSD   Period: H1   Modelling: 1 minute OHLC
Deposit     : 10000    Leverage: 1:100
Date range  : 2018.01.01 se aaj tak (minimum 3 saal)
```

⚠️ Yaad rakho: M5 preset sirf **mechanics check** karne ke liye hai. Jo research
is EA ke peeche hai (Menkhoff et al. 2012, Barroso–Santa-Clara 2015) wo saari
**monthly rebalance** pe based hai. Hourly rebalance pe spread cost hi kha
jayegi. Detail: [`STRATEGY.md`](STRATEGY.md) §4.
