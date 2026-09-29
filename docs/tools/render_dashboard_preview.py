#!/usr/bin/env python3
"""Renders a pixel-accurate mock-up of the Double Breakout Gold EA dashboard.

The geometry mirrors CDbgDashboard::Create() in DBG_Dashboard.mqh so the picture
in the docs stays in sync with the real panel.  Usage:  python3 render_dashboard_preview.py
"""
from PIL import Image, ImageDraw, ImageFont

S = 2                      # supersampling factor
X, Y, W = 12, 18, 430
FS = 8                     # MT5 font size 8  ->  ~11 px
MONO = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
SANS = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"

C_BG      = (18, 21, 27)
C_PANEL   = (26, 31, 40)
C_HEAD    = (212, 175, 55)
C_LABEL   = (140, 150, 165)
C_VALUE   = (225, 230, 238)
C_SECTION = (90, 170, 255)
C_BORDER  = (55, 63, 78)
C_GREEN   = (120, 230, 150)
C_RED     = (250, 110, 110)
C_ORANGE  = (240, 160, 70)
C_CYAN    = (110, 220, 255)
C_CHART   = (12, 14, 18)

rows = [
    ("S", "CLOCK  &  TIMEZONE", None, None),
    ("R", "Server time",  "2026.09.29 16:42:07", C_VALUE),
    ("R", "Broker zone",  "GMT+3  (history-detected) | DST: ON", C_VALUE),
    ("R", "GMT / UTC",    "2026.09.29 13:42:07", C_VALUE),
    ("R", "Local (PC)",   "2026.09.29 19:12:07", C_VALUE),
    ("R", "World clock",  "NY 09:42 | LON 14:42 | TOK 22:42 | SYD 23:42", C_VALUE),
    ("R", "Session",      "LON NY  <OVERLAP> | range 00:00-07:00 GMT", C_VALUE),
    ("S", "MARKET", None, None),
    ("R", "Symbol / TF",  "XAUUSD  M15", C_VALUE),
    ("R", "Bid/Ask/Spr",  "3861.25 / 3861.55   spread 30 pts", C_VALUE),
    ("R", "Volatility",   "ATR(M15) 4.85 | ATR(D1) 38.40 | RVOL 1.14", C_VALUE),
    ("S", "STRATEGY : DOUBLE BREAKOUT", None, None),
    ("R", "Phase",        "PULLBACK OK - waiting RE-BREAK (LONG)", C_ORANGE),
    ("R", "Range",        "H 3865.40  L 3852.10  (13.30 = 35% D-ATR)", C_VALUE),
    ("R", "Trigger",      "3869.15  exp 16:05   setups 1/2", C_CYAN),
    ("R", "Position",     "pending trigger order live", (170, 180, 195)),
    ("R", "SL / TP",      "SL structure | TP1 1.5R (50%) | TP2 3.0R", C_VALUE),
    ("S", "NEWS  FILTER  (MT5 CALENDAR)", None, None),
    ("R", "Status",       "LOCKED - USD HIGH | resume in 47:12", C_RED),
    ("R", "Next event",   "14:30 USD HIGH  Core PCE Price Index (in 17:12)", C_VALUE),
    ("R", "Window",       "-30 min / +30 min | USD | high impact | 18 events", C_VALUE),
    ("S", "RISK  &  STATISTICS", None, None),
    ("R", "Account",      "Bal 10000.00 | Eq 10142.30 | Mgn free 9840.10", C_VALUE),
    ("R", "Today",        "142.30 (1.42%) | 2 trades  2W/0L", C_GREEN),
    ("R", "Risk / trade", "0.75%  ~ 75.00 per trade", C_VALUE),
    ("R", "Guards",       "trades 2/2 | streak 0/3 | DD limit 3.0%", C_VALUE),
]


def main():
    img_w, img_h = (W + 2 * X + 250), 640
    im = Image.new("RGB", (img_w * S, img_h * S), C_CHART)
    d = ImageDraw.Draw(im)
    f = ImageFont.truetype(MONO, int(FS * 1.45 * S))
    fb = ImageFont.truetype(SANS, int((FS + 1) * 1.45 * S))

    def rect(x, y, w, h, fill, outline=None):
        d.rectangle([x * S, y * S, (x + w) * S, (y + h) * S], fill=fill, outline=outline, width=S)

    def text(x, y, s, clr, font=None):
        d.text((x * S, y * S), s, fill=clr, font=font or f)

    # faint candles in the background
    import random
    random.seed(7)
    px = W + 2 * X + 20
    price = 300
    while px < img_w - 10:
        o = price
        c = o + random.randint(-14, 14)
        hi = max(o, c) + random.randint(2, 10)
        lo = min(o, c) - random.randint(2, 10)
        col = (60, 130, 90) if c >= o else (140, 70, 70)
        d.line([(px * S, hi * S), (px * S, lo * S)], fill=col, width=S)
        d.rectangle([(px - 3) * S, min(o, c) * S, (px + 3) * S, max(o, c) * S], fill=col)
        price = c
        px += 10

    # ---- panel -------------------------------------------------------
    total_h = 0
    row_y = Y + 28
    for kind, *_ in rows:
        row_y += 25 if kind == "S" else 15
    row_y += 6 + 6 + 30
    total_h = row_y - Y

    rect(X, Y, W, total_h, C_BG, C_BORDER)
    rect(X, Y, W, 24, C_PANEL, C_BORDER)
    text(X + 10, Y + 5, "DOUBLE BREAKOUT GOLD  v1.00", C_HEAD, fb)
    rect(X + W - 26, Y + 4, 18, 16, C_PANEL, C_BORDER)
    text(X + W - 22, Y + 5, "_", C_VALUE)

    row_y = Y + 28
    for kind, a, b, clr in rows:
        if kind == "S":
            row_y += 6
            text(X + 10, row_y, a, C_SECTION)
            rect(X + 8, row_y + 14, W - 16, 1, C_BORDER)
            row_y += 19
        else:
            text(X + 12, row_y, a, C_LABEL)
            text(X + 112, row_y, b, clr)
            row_y += 15

    row_y += 6
    rect(X + 8, row_y, W - 16, 1, C_BORDER)
    row_y += 6
    text(X + 12, row_y + 5, "STANDBY: news lock", C_ORANGE)
    rect(X + W - 166, row_y + 2, 78, 20, (40, 48, 60), C_BORDER)
    text(X + W - 155, row_y + 7, "PAUSE", C_VALUE)
    rect(X + W - 84, row_y + 2, 76, 20, (70, 35, 40), C_BORDER)
    text(X + W - 78, row_y + 7, "CLOSE ALL", (255, 190, 190))

    im = im.resize((img_w, img_h), Image.LANCZOS)
    im.save("dashboard-preview.png")
    print("written dashboard-preview.png")


if __name__ == "__main__":
    main()
