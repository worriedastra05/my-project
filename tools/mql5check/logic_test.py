#!/usr/bin/env python3
"""
Numerical validation of the CrossSectionalMomentumEA maths.

A type-check cannot catch a sign error. This script re-implements the exact
formulas used in the EA and asserts they behave correctly on synthetic data
where the right answer is known by construction.

Run:  python3 tools/mql5check/logic_test.py
"""

import math

FAIL = []


def check(name, cond, detail=""):
    status = "PASS" if cond else "FAIL"
    print(f"  [{status}] {name}" + (f"  ({detail})" if detail else ""))
    if not cond:
        FAIL.append(name)


# ----------------------------------------------------------------------
# Mirrors of the EA helpers
# ----------------------------------------------------------------------
def formation_return(close_series, skip, formation, flip):
    """close_series[0] is the newest CLOSED bar (same indexing as the EA)."""
    p_end = close_series[skip]
    p_start = close_series[skip + formation]
    r = math.log(p_end / p_start)
    return -r if flip else r


def bar_returns(close_series, n, flip):
    out = []
    for k in range(n):
        x = math.log(close_series[k] / close_series[k + 1])
        out.append(-x if flip else x)
    return out


def stdev(xs):
    m = sum(xs) / len(xs)
    return math.sqrt(sum((x - m) ** 2 for x in xs) / max(1, len(xs) - 1))


def bars_per_year(tf):
    return {"D1": 252.0, "H1": 6048.0, "H4": 1512.0, "W1": 52.0, "MN1": 12.0}[tf]


def order_direction(target, flip):
    """+1 = BUY the pair, -1 = SELL the pair."""
    return -target if flip else target


def notional_per_lot(tick_value, tick_size, price):
    return (tick_value / tick_size) * price


def inverse_vol_weights(vols):
    inv = [1.0 / max(v, 1e-6) for v in vols]
    s = sum(inv)
    return [i / s for i in inv]


def portfolio_money_vol(exposures, cov):
    total = 0.0
    n = len(exposures)
    for a in range(n):
        for b in range(n):
            total += exposures[a] * exposures[b] * cov[a][b]
    return math.sqrt(max(total, 0.0))


# ----------------------------------------------------------------------
print("\n1. Quote-convention normalisation (the critical sign logic)")
print("   Synthetic month: EUR strengthens 5% vs USD, JPY weakens 5% vs USD.")

# EURUSD rises 5%  -> EUR is a winner
eurusd = [1.05 * (1 - 0.05 * k / 21) for k in range(40)]   # index 0 = newest
# USDJPY rises 5%  -> JPY is a LOSER (the dollar gained on the yen)
usdjpy = [157.5 * (1 - 0.05 * k / 21) for k in range(40)]

eur_ret = formation_return(eurusd, 0, 21, flip=False)
jpy_ret = formation_return(usdjpy, 0, 21, flip=True)

check("EUR ranks as a winner (positive return)", eur_ret > 0, f"{eur_ret:+.4f}")
check("JPY ranks as a loser (negative return)", jpy_ret < 0, f"{jpy_ret:+.4f}")
check("the two are symmetric", abs(eur_ret + jpy_ret) < 1e-9)

# Winner EUR -> target +1, no flip -> BUY EURUSD
check("long EUR  => BUY EURUSD", order_direction(+1, flip=False) == +1)
# Loser JPY -> target -1, flip -> BUY USDJPY (selling the yen means buying the pair)
check("short JPY => BUY USDJPY", order_direction(-1, flip=True) == +1)
# And the mirror cases
check("short EUR => SELL EURUSD", order_direction(-1, flip=False) == -1)
check("long JPY  => SELL USDJPY", order_direction(+1, flip=True) == -1)


# ----------------------------------------------------------------------
print("\n2. Volatility is flip-invariant, covariance sign is not")
noisy_up = [100.0 * math.exp(-0.001 * k + 0.004 * math.sin(k)) for k in range(80)]
v_plain = stdev(bar_returns(noisy_up, 60, flip=False))
v_flip = stdev(bar_returns(noisy_up, 60, flip=True))
check("stdev unchanged by the flip", abs(v_plain - v_flip) < 1e-15)

a = bar_returns(noisy_up, 60, flip=False)
b = bar_returns(noisy_up, 60, flip=True)
ma, mb = sum(a) / len(a), sum(b) / len(b)
cov_ab = sum((x - ma) * (y - mb) for x, y in zip(a, b)) / (len(a) - 1)
check("flipping one leg flips the covariance sign", cov_ab < 0, f"{cov_ab:.3e}")


# ----------------------------------------------------------------------
print("\n3. Annualisation")
sigma_bar = 0.006  # 0.6% per day
check("D1 -> sqrt(252)", abs(sigma_bar * math.sqrt(bars_per_year("D1")) - 0.0952) < 1e-3,
      f"{sigma_bar * math.sqrt(bars_per_year('D1')):.4f}")
check("H1 has more bars per year than D1", bars_per_year("H1") > bars_per_year("D1"))
check("W1 = 52", bars_per_year("W1") == 52.0)


# ----------------------------------------------------------------------
print("\n4. Notional per lot in the ACCOUNT currency (USD account)")
# EURUSD: 100k contract, tick 0.00001 => USD 1.00 per tick per lot
n_eur = notional_per_lot(tick_value=1.00, tick_size=0.00001, price=1.08)
# USDJPY: 100k USD contract, tick 0.001, price 150 => 100000*0.001/150 = 0.6667 USD/tick
n_jpy = notional_per_lot(tick_value=100000 * 0.001 / 150.0, tick_size=0.001, price=150.0)
check("EURUSD notional ~ 108,000 USD", abs(n_eur - 108000) < 1, f"{n_eur:,.0f}")
check("USDJPY notional ~ 100,000 USD", abs(n_jpy - 100000) < 1, f"{n_jpy:,.0f}")
check("the old contract*price formula would have been wrong for USDJPY",
      abs(100000 * 150.0 - n_jpy) > 1e6, "15,000,000 JPY != 100,000 USD")


# ----------------------------------------------------------------------
print("\n5. Inverse-volatility weights")
vols = [0.05, 0.10, 0.20]
w = inverse_vol_weights(vols)
check("weights sum to 1", abs(sum(w) - 1.0) < 1e-12)
check("the low-vol leg gets the biggest weight", w[0] > w[1] > w[2],
      " > ".join(f"{x:.3f}" for x in w))
check("weight is proportional to 1/vol", abs(w[0] / w[2] - vols[2] / vols[0]) < 1e-12)


# ----------------------------------------------------------------------
print("\n6. Portfolio volatility targeting")
# Two perfectly correlated legs, 10% vol each, held in OPPOSITE directions
# => the portfolio must be (near) risk free.
cov_corr = [[0.01, 0.01], [0.01, 0.01]]          # 10% vol, rho = 1
equity = 100_000.0
long_short = portfolio_money_vol([+100_000, -100_000], cov_corr)
same_way = portfolio_money_vol([+100_000, +100_000], cov_corr)
check("opposite legs in a correlated pair hedge out", long_short < 1.0, f"{long_short:.6f}")
check("same-way legs add up to 20,000 (20% of equity)", abs(same_way - 20_000) < 1.0,
      f"{same_way:,.1f}")

# scale factor drives the book to the target
cov_ind = [[0.01, 0.0], [0.0, 0.01]]             # independent, 10% vol each
exposures = [+100_000, -100_000]
pv = portfolio_money_vol(exposures, cov_ind)
target_money = equity * 0.10                      # 10% target
scale = max(0.25, min(2.50, target_money / pv))
scaled = portfolio_money_vol([e * scale for e in exposures], cov_ind)
check("after scaling the book hits the 10% target",
      abs(scaled / equity * 100.0 - 10.0) < 1e-6, f"{scaled / equity * 100:.4f}%")
check("the scale factor is clamped into [0.25, 2.50]", 0.25 <= scale <= 2.50, f"x{scale:.3f}")


# ----------------------------------------------------------------------
print("\n7. Risk-based lot sizing")
# Risk 1% of a 100k account with a 250 point stop worth $1/point per lot
risk_money = 100_000 * 0.01
sl_points, money_per_point = 250.0, 1.0
lots = risk_money / (sl_points * money_per_point)
check("lots = risk / (stop_points * value_per_point)", abs(lots - 4.0) < 1e-12, f"{lots:.2f}")
check("hitting the stop loses exactly the budgeted risk",
      abs(lots * sl_points * money_per_point - risk_money) < 1e-9)


# ----------------------------------------------------------------------
print("\n8. Ranking and selection")
scores = {"AUD": 1.8, "EUR": 0.9, "GBP": 0.2, "CAD": -0.4, "CHF": -1.1, "JPY": -2.0}
ranked = sorted(scores, key=lambda k: scores[k], reverse=True)
longs, shorts = ranked[:3], ranked[-3:]
check("ranked descending", ranked == ["AUD", "EUR", "GBP", "CAD", "CHF", "JPY"])
check("buys the top 3", longs == ["AUD", "EUR", "GBP"])
check("sells the bottom 3", shorts == ["CAD", "CHF", "JPY"])
check("no symbol is on both sides", not set(longs) & set(shorts))

# dual-momentum overlay drops legs whose own momentum disagrees
dual_longs = [s for s in longs if scores[s] > 0]
check("dual momentum keeps only positive-momentum winners", dual_longs == longs)
scores2 = dict(scores, GBP=-0.05)
ranked2 = sorted(scores2, key=lambda k: scores2[k], reverse=True)
dual2 = [s for s in ranked2[:3] if scores2[s] > 0]
check("dual momentum drops a 'winner' with negative absolute momentum",
      dual2 == ["AUD", "EUR"], f"{dual2}")


# ----------------------------------------------------------------------
print("\n9. Lot normalisation onto the broker grid")
def normalize_lots(raw, step, vmin, vmax):
    v = math.floor(raw / step + 1e-7) * step
    if v < vmin:
        return 0.0
    return min(v, vmax)

check("1.237 with a 0.01 step -> 1.23", abs(normalize_lots(1.237, 0.01, 0.01, 100) - 1.23) < 1e-9)
check("below the minimum -> 0 (no trade)", normalize_lots(0.004, 0.01, 0.01, 100) == 0.0)
check("clamped to the maximum", normalize_lots(500, 0.01, 0.01, 100) == 100)
check("an exact multiple survives rounding", abs(normalize_lots(0.03, 0.01, 0.01, 100) - 0.03) < 1e-9)


# ----------------------------------------------------------------------
print("\n" + "=" * 62)
if FAIL:
    print(f"{len(FAIL)} CHECK(S) FAILED: {FAIL}")
    raise SystemExit(1)
print("All logic checks passed.")
