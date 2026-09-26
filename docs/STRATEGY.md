# Classical Cross-Sectional Momentum — research notes

This document explains *why* the EA is built the way it is, and what you should
realistically expect from it. Read it before you risk money.

---

## 1. What "cross-sectional" means

There are two different things people call momentum:

| | Time-series (absolute) momentum | **Cross-sectional (relative) momentum** |
|---|---|---|
| Signal | An asset's own past return | An asset's return **relative to its peers** |
| Position | Long if its own return > 0 | Long the best, short the worst |
| Net exposure | Varies, can be net long or net short | **~Market neutral by construction** |
| Works when | Markets trend | **Dispersion between assets is high** |
| Struggles when | Markets chop sideways | Everything moves together |

This EA implements the **cross-sectional** version — the one Jegadeesh and
Titman introduced in 1993 and the one the whole factor-investing literature is
built on. At every rebalance it ranks the entire universe, buys the top N and
sells the bottom N. The book is long/short and roughly dollar-neutral, so a
broad dollar rally or selloff mostly cancels out; what is left is the *spread*
between winners and losers.

---

## 2. The algorithm, step by step

At each rebalance date the EA does exactly this:

1. **Pull aligned history.** Copy `InpFormationBars + InpSkipBars + InpVolLookback + 50`
   bars of the signal timeframe for every symbol, drop the still-forming bar,
   then keep only bar timestamps that exist for *every* symbol. Ranking symbols
   on misaligned bars is a classic and invisible source of garbage signals.

2. **Normalise the quote convention.** This is the step most retail
   implementations get wrong. `EURUSD` rising means the euro strengthened;
   `USDJPY` rising means the yen **weakened**. If you rank raw pair returns,
   you are comparing "EUR vs USD" against "USD vs JPY" — two different axes.
   The EA reads `SYMBOL_CURRENCY_BASE` / `SYMBOL_CURRENCY_PROFIT`, and for any
   pair quoted as `USDxxx` it negates the return so that everything is measured
   as *foreign currency versus the dollar*. When a signal then says "short the
   yen", the EA knows that means **buy** `USDJPY`.

3. **Compute the formation return**
   `r_i = log( P_i[skip] / P_i[skip + formation] )`, sign-corrected as above.

4. **Compute volatility and the covariance matrix** from the last
   `InpVolLookback` bar-to-bar log returns, annualised by the number of bars per
   year for that timeframe.

5. **Score and rank.**
   - `SIG_RAW_RETURN` → score is `r_i` (the literal Jegadeesh-Titman sort).
   - `SIG_VOL_ADJ_RETURN` (default) → score is `r_i / (σ_i · √f)`, a t-statistic-like
     standardisation so a 3% move in a quiet currency is not judged against a 3%
     move in a violent one.

6. **Select.** Long the top `InpLongCount`, short the bottom `InpShortCount`.
   With `InpUseDualMomentum` on, a "winner" is only bought if its own absolute
   momentum is also positive, and a "loser" only sold if its own momentum is
   negative (Antonacci's dual momentum). This trims legs where the relative sort
   and the absolute trend disagree.

7. **Size.**
   - Risk weight per leg `w_i ∝ 1/σ_i`, normalised to sum to 1 (risk parity).
   - Money at risk per leg = `equity × InpPortfolioRiskPct% × w_i`.
   - Lots = `risk_money / (stop_distance_in_points × money_per_point)`, so
     hitting the stop loses exactly the budgeted amount.
   - **Portfolio volatility targeting**: signed notionals `e` are combined with
     the covariance matrix, `σ_portfolio = √(eᵀ Σ e)`, and every leg is scaled by
     `target_vol / σ_portfolio` (clamped). Correlated legs held in opposite
     directions correctly net down; a book of six legs that all point the same way
     correctly gets sized down.
   - Then a gross-leverage cap and a margin cap, then rounding to the broker's
     lot grid.

8. **Reconcile, don't churn.** The EA diffs the live book against the target
   book: legs that dropped out or flipped direction are closed, legs that
   survived are left alone (unless `InpResizeExisting` is on). It does not
   blindly flatten and re-open, which would pay the spread twice every month.

9. **Protect every leg** with an ATR stop-loss and take-profit, plus optional
   break-even and ATR trailing.

---

## 3. Why these defaults

### Formation period = 1 month, holding = 1 month

Equity people use "12-1" (rank on the last 12 months, skipping the most recent
month). **In FX that is the wrong answer.** Menkhoff, Sarno, Schmeling and
Schrimpf tested every combination of formation and holding period from 1 to 12
months on up to 48 currencies over 1976–2010 and found:

- **MOM(1,1)** — one-month formation, one-month holding — returned close to
  **10% p.a.** with an annualised **Sharpe of ~0.95**.
- **MOM(12,12)** returned only **1.89% p.a.** over the same sample.
- Results were strongest for a holding period of **h = 1 month** across the board.

So `InpFormationBars = 21` (≈1 month of D1 bars), `InpSkipBars = 0`, and monthly
rebalancing. If you point this EA at **equities or ETFs** instead, switch to the
equity convention: `InpFormationBars = 252`, `InpSkipBars = 21`.

### 3 long / 3 short

Matches how the industry actually builds these. Deutsche Bank's G10 currency
momentum index is long the three best and short the three worst performers, and
the standard currency-momentum factor in cross-asset studies is the top-3 /
bottom-3 of the G10. With a 9-currency universe, 3/3 is roughly the top and
bottom third — the same idea as Jegadeesh-Titman's top/bottom decile, scaled to
a small cross-section.

### Volatility scaling

Barroso and Santa-Clara ("Momentum has its moments", 2015) showed that scaling a
momentum portfolio by the inverse of its own realised volatility **virtually
eliminated momentum crashes and nearly doubled the Sharpe ratio**. Daniel and
Moskowitz ("Momentum crashes", 2016) reached the same conclusion with a dynamic
version. This is the single highest-value addition to a plain momentum sort, and
it costs nothing, so it is on by default.

### Skip period = 0 for FX, 21 for equities

The one-month skip in equity momentum exists to dodge short-term reversal and
bid-ask bounce in individual stocks. FX does not show that same one-month
reversal — in fact the one-month formation period is the *best* one — so the
default skip is 0.

---

## 4. Honest expectations (please read)

**This is a faithful implementation of a documented academic anomaly, not a
guaranteed money printer.** Specifically:

1. **The edge has decayed.** The headline ~10% p.a. comes from a 1976–2010
   sample. Public backtests of currency momentum run to the present show returns
   near **zero** over 1990–present. J.P. Morgan's cross-asset study found that
   relative-momentum strategies "significantly underperformed" over the two
   decades to 2015 and that performance "generally erodes as the time horizons
   for calculating [momentum] shorten".

2. **Turnover is brutal.** The paper measured turnover above **70% per month**
   for MOM(1,1), and the winner/loser currencies happen to be the ones with wider
   spreads. Transaction costs ate a large chunk of the gross return. On a retail
   spread this matters enormously — it is the main reason the defaults rebalance
   monthly rather than weekly or daily.

3. **The original study had no stops.** Adding a stop-loss changes the return
   distribution. It caps the tail, but it also converts some winning positions
   into losers when they whipsaw. The ATR stop here is a *risk control*, not an
   alpha source. If you want a pure replication of the paper, set
   `InpSL_ATR = 0`, `InpTP_ATR = 0`, `InpUseTrailing = false`,
   `InpUseBreakEven = false` — then rebalancing is the only exit.

4. **Cross-sectional momentum dies when correlation goes to 1.** In a dollar
   panic every currency moves the same way against USD, the winner/loser spread
   collapses, and the strategy just pays spread. Expect flat-to-negative stretches
   lasting quarters.

5. **Your broker's universe matters.** With fewer than ~6 symbols the ranking is
   statistically meaningless. `USDSEK` and `USDNOK` widen the cross-section
   (good) but carry wide spreads (bad). If your broker does not offer them the EA
   drops them automatically and logs it.

---

## 5. How to validate it yourself

Do this **before** going live, in this order:

1. **Backtest the mechanics.** Strategy Tester, `EURUSD`, `D1`, modelling
   "1 minute OHLC" or "Every tick based on real ticks", 5+ years. Because it is a
   multi-symbol EA, MT5 will download the other symbols' history on the first
   run — the first pass is slow and the first few weeks of the test may be
   skipped while history loads. Check the Journal for `[CSMOM]` lines.

2. **Check the sign logic on your broker.** In the Journal, confirm that the
   `Universe (...)` line marks your `USDxxx` symbols with `(inv)`. If it does
   not, your broker reports odd currency metadata — switch `InpUniverseMode` to
   `UNIV_RAW` and hand-build a universe that is all quoted the same way
   (e.g. only `xxxUSD` pairs).

3. **Sanity-check position sizes.** Run on demo with `InpVerboseLog = true`. The
   `OPEN ...` lines print the score, weight, lots, SL and TP. Multiply
   (entry − SL) in points by the point value by the lots; it should equal your
   configured risk.

4. **Walk-forward, don't optimise in-sample.** If you tune
   `InpFormationBars`, `InpLongCount` and `InpSL_ATR` on 2015–2025 and report
   that result, you have learned nothing. Optimise on 2010–2018, verify on
   2019–2025, and only accept parameters that are on a broad plateau rather than
   a lucky spike.

5. **Demo for at least one full rebalance cycle** (a month on the default
   preset) before funding it.

---

## 6. References

- Jegadeesh, N. & Titman, S. (1993). *Returns to Buying Winners and Selling
  Losers: Implications for Stock Market Efficiency.* Journal of Finance 48(1).
- Menkhoff, L., Sarno, L., Schmeling, M. & Schrimpf, A. (2012). *Currency
  momentum strategies.* Journal of Financial Economics 106(3), 660–684.
  <https://www.sciencedirect.com/science/article/abs/pii/S0304405X12001353> ·
  working paper: <https://www.bis.org/publ/work366.pdf>
- Barroso, P. & Santa-Clara, P. (2015). *Momentum has its moments.* Journal of
  Financial Economics 116(1).
- Daniel, K. & Moskowitz, T. (2016). *Momentum crashes.* Journal of Financial
  Economics 122(2). <https://business.columbia.edu/sites/default/files-efs/pubfiles/4607/mom11.pdf>
- Moskowitz, T., Ooi, Y. H. & Pedersen, L. H. (2012). *Time series momentum.*
  Journal of Financial Economics 104(2).
- Antonacci, G. (2014). *Dual Momentum Investing.* McGraw-Hill.
- J.P. Morgan (2015). *Momentum Strategies Across Asset Classes.*
  <https://www.cmegroup.com/education/files/jpm-momentum-strategies-2015-04-15-1681565.pdf>
- Poh, D., Lim, B., Zohren, S. & Roberts, S. (2021). *Building Cross-Sectional
  Systematic Strategies By Learning to Rank.* Journal of Financial Data Science.
  <https://papers.ssrn.com/sol3/papers.cfm?abstract_id=3751012>
  (a modern extension — replaces the ranking heuristic with a learning-to-rank
  model; out of scope for an MQL5 EA but the natural next step)
