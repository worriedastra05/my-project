//+------------------------------------------------------------------+
//|                                               GoldMomentumEA.mq5 |
//|                    Intraday Noise-Area Momentum for XAUUSD (M1/M5)|
//|                                                                  |
//|  Pure momentum engine. NO fixed Stop Loss. NO fixed Take Profit.  |
//|  Every exit is momentum / volatility driven:                      |
//|     - Noise-Area band re-entry stop (Zarattini-Aziz-Barbon 2024)   |
//|     - Session VWAP stop                                           |
//|     - Chandelier ATR trail                                        |
//|     - EMA momentum-flip trail                                     |
//|     - Session / Friday flat-out                                   |
//|  A very wide "disaster" stop is kept on the broker side purely as  |
//|  gap / disconnect protection (it is NOT a strategy stop).          |
//+------------------------------------------------------------------+
#property copyright "Gold Momentum Research"
#property version   "1.00"
#property description "XAUUSD intraday momentum EA (M1/M5). Noise-Area breakout entries, fully dynamic momentum exits, no fixed SL/TP."

#include <Trade\Trade.mqh>

//==================================================================
//  ENUMS
//==================================================================
enum ENUM_LOT_MODE
  {
   LOT_FIXED        = 0,  // Fixed lot
   LOT_RISK_PERCENT = 1   // Risk % of equity per trade (ATR/stop based)
  };

enum ENUM_TIME_MODE
  {
   TM_GMT    = 0,  // Session inputs are in GMT (uses broker offset below)
   TM_SERVER = 1   // Session inputs are in broker server time
  };

//==================================================================
//  INPUTS
//==================================================================
input group "=== 1. Identity ==="
input long            InpMagic              = 20260926;   // Magic number
input string          InpComment            = "GoldMom";  // Order comment

input group "=== 2. Noise-Area momentum core ==="
input int             InpLookbackDays       = 20;         // Volatility-profile lookback (days)
input double          InpBandMultiplier     = 1.20;       // Noise-band multiplier (N x sigma)
input double          InpBreakoutBufferATR  = 0.05;       // Extra push beyond band required (x ATR)
input double          InpMinBandWidthATR    = 0.60;       // Skip if band width < this x ATR (anti-chop)
input int             InpMinValidDays       = 8;          // Min valid history days needed to trade

input group "=== 3. Momentum confirmation filters ==="
input bool            InpUseVwapFilter      = true;       // Price must be on correct side of session VWAP
input bool            InpUseEmaFilter       = true;       // EMA fast/slow must agree with direction
input int             InpEmaFastPeriod      = 21;         // EMA fast
input int             InpEmaSlowPeriod      = 55;         // EMA slow
input bool            InpUseAdxFilter       = true;       // Require trend strength
input int             InpAdxPeriod          = 14;         // ADX period
input double          InpAdxMin             = 18.0;       // Minimum ADX
input bool            InpUseBodyFilter      = true;       // Breakout candle must have real body
input double          InpMinBodyATR         = 0.35;       // Min body size (x ATR)

input group "=== 4. Volatility regime ==="
input int             InpAtrPeriod          = 14;         // ATR period (entry timeframe)
input double          InpMinAtrUsd          = 0.40;       // Min ATR in $ (0 = off)  e.g. M5 gold ~0.8-2.0
input double          InpMaxAtrUsd          = 0.0;        // Max ATR in $ (0 = off) - blocks news chaos

input group "=== 5. Dynamic exits (NO fixed SL/TP) ==="
input bool            InpUseBandStop        = true;       // Exit when price falls back into noise area
input bool            InpUseVwapStop        = true;       // Exit on VWAP cross against position
input bool            InpUseChandelier      = true;       // Chandelier ATR trail from trade extreme
input double          InpChandelierATR      = 2.20;       // Chandelier distance (x ATR)
input bool            InpUseEmaStop         = true;       // EMA momentum-flip trail
input int             InpEmaStopPeriod      = 20;         // EMA used for the flip trail
input double          InpEmaStopATR         = 0.30;       // Offset below/above that EMA (x ATR)
input double          InpMinStopATR         = 1.00;       // Stop may never sit closer than this x ATR
input double          InpDisasterATR        = 7.00;       // Broker-side catastrophe stop (x ATR)
input bool            InpSyncStopToBroker   = true;       // Push the dynamic trail to the broker as SL
input int             InpMaxBarsInTrade     = 0;          // Time stop in bars (0 = off)

input group "=== 6. Sessions & time ==="
input ENUM_TIME_MODE  InpTimeMode           = TM_GMT;     // Session time reference
input int             InpBrokerGMTOffset    = 3;          // Broker server offset from GMT (+2 winter / +3 summer)
input int             InpSessionStartHour   = 7;          // Trading window start hour
input int             InpSessionStartMin    = 0;          // Trading window start minute
input int             InpSessionEndHour     = 20;         // Trading window end hour (no NEW trades after)
input int             InpSessionEndMin      = 0;          // Trading window end minute
input bool            InpFlatAtSessionEnd   = true;       // Force flat at window end
input int             InpFlatHour           = 20;         // Force-flat hour
input int             InpFlatMin            = 30;         // Force-flat minute
input bool            InpTradeMonday        = true;       // Trade Monday
input bool            InpTradeFriday        = true;       // Trade Friday
input int             InpFridayStopHour     = 18;         // Friday: no new trades after this hour
input bool            InpFridayFlat         = true;       // Friday: close everything before weekend
input int             InpFridayFlatHour     = 20;         // Friday flat hour

input group "=== 7. Risk & money management ==="
input ENUM_LOT_MODE   InpLotMode            = LOT_RISK_PERCENT; // Sizing mode
input double          InpFixedLot           = 0.01;       // Fixed lot (if fixed mode)
input double          InpRiskPercent        = 0.50;       // Risk % of equity per trade
input double          InpMaxLot             = 5.00;       // Hard lot cap
input double          InpMaxDailyLossPct    = 3.00;       // Daily loss circuit breaker % (0 = off)
input double          InpDailyProfitLockPct = 0.0;        // Stop trading after +X% day (0 = off)
input int             InpMaxTradesPerDay    = 6;          // Max entries per day (0 = unlimited)
input int             InpMaxConsecLosses    = 4;          // Pause day after N losses in a row (0 = off)
input int             InpCooldownBars       = 2;          // Bars to wait after an exit

input group "=== 8. Execution ==="
input bool            InpAllowLong          = true;       // Allow buys
input bool            InpAllowShort         = true;       // Allow sells
input int             InpMaxSpreadPoints    = 400;        // Max spread in points (0 = off)
input double          InpMaxSpreadATRfrac   = 0.15;       // Max spread as fraction of ATR (0 = off)
input int             InpSlippagePoints     = 60;         // Deviation in points
input bool            InpShowPanel          = true;       // Show on-chart dashboard

//==================================================================
//  GLOBALS
//==================================================================
CTrade   Trade;

int      hATR      = INVALID_HANDLE;
int      hEmaFast  = INVALID_HANDLE;
int      hEmaSlow  = INVALID_HANDLE;
int      hEmaStop  = INVALID_HANDLE;
int      hADX      = INVALID_HANDLE;

datetime g_lastBarTime   = 0;
datetime g_curDayStart   = 0;

double   g_dayStartEquity = 0.0;
int      g_tradesToday    = 0;
int      g_consecLosses   = 0;
bool     g_dayBlocked     = false;

// live position state
bool     g_hasPos     = false;
ulong    g_posTicket  = 0;
bool     g_posIsLong  = false;
double   g_posEntry   = 0.0;
double   g_posLots    = 0.0;
double   g_trail      = 0.0;
double   g_extreme    = 0.0;
int      g_barsInPos  = 0;
datetime g_lastExitBar = 0;

// last computed context (for the panel)
double   g_upper = 0.0, g_lower = 0.0, g_vwap = 0.0, g_sigma = 0.0, g_atr = 0.0;
int      g_validDays = 0;
string   g_state = "init";

//==================================================================
//  HELPERS
//==================================================================
double PriceNorm(double p)
  {
   return NormalizeDouble(p, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
  }

double NormLot(double lots)
  {
   double mn   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      step = 0.01;
   if(InpMaxLot > 0.0 && mx > InpMaxLot)
      mx = InpMaxLot;
   lots = MathFloor(NormalizeDouble(lots / step, 8)) * step;
   if(lots < mn)
      lots = mn;
   if(lots > mx)
      lots = mx;
   return NormalizeDouble(lots, 2);
  }

void SetupFilling()
  {
   long fill = (long)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fill & SYMBOL_FILLING_IOC) != 0)
      Trade.SetTypeFilling(ORDER_FILLING_IOC);
   else
      if((fill & SYMBOL_FILLING_FOK) != 0)
         Trade.SetTypeFilling(ORDER_FILLING_FOK);
      else
         Trade.SetTypeFilling(ORDER_FILLING_RETURN);
  }

//--- convert a user hour/min (GMT or server) into server minutes-of-day
int ToServerMinutes(int hour, int minute)
  {
   int m = hour * 60 + minute;
   if(InpTimeMode == TM_GMT)
      m += InpBrokerGMTOffset * 60;
   m %= 1440;
   if(m < 0)
      m += 1440;
   return m;
  }

int ServerMinutesNow()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return dt.hour * 60 + dt.min;
  }

//--- window test that tolerates midnight wrap
bool InWindow(int nowMin, int startMin, int endMin)
  {
   if(startMin == endMin)
      return true;                       // 24h
   if(startMin < endMin)
      return (nowMin >= startMin && nowMin < endMin);
   return (nowMin >= startMin || nowMin < endMin);     // wraps midnight
  }

double SpreadPoints()
  {
   return (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
  }

double SpreadPrice()
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   return MathMax(0.0, ask - bid);
  }

double BufVal(int handle, int buffer, int shift)
  {
   double tmp[];
   if(CopyBuffer(handle, buffer, shift, 1, tmp) != 1)
      return 0.0;
   return tmp[0];
  }

//==================================================================
//  INTRADAY VOLATILITY PROFILE  (the "noise area")
//
//  sigma(t) = mean over the last N valid days of
//             | Close_d(t) / Open_d(day)  - 1 |
//
//  i.e. the typical absolute % distance from the day open that gold
//  travels by this exact time of day.  Bands are then anchored on
//  max/min(today open, yesterday close) and widen through the day.
//==================================================================
double ComputeSigma(int secondsIntoDay, int &validDays)
  {
   validDays = 0;
   double sum = 0.0;
   int tol = 3 * PeriodSeconds(_Period);
   if(tol < 900)
      tol = 900;

   for(int d = 1; d <= InpLookbackDays; d++)
     {
      datetime dayStart = iTime(_Symbol, PERIOD_D1, d);
      if(dayStart == 0)
         break;

      MqlDateTime dts;
      TimeToStruct(dayStart, dts);
      if(dts.day_of_week == 0 || dts.day_of_week == 6)
         continue;                               // skip weekend stubs

      double dayOpen = iOpen(_Symbol, PERIOD_D1, d);
      if(dayOpen <= 0.0)
         continue;

      datetime target = (datetime)((long)dayStart + (long)secondsIntoDay);
      int sh = iBarShift(_Symbol, _Period, target, false);
      if(sh < 0)
         continue;

      datetime bt = iTime(_Symbol, _Period, sh);
      if(bt < dayStart)
         continue;                               // bar is before that day
      if(MathAbs((long)bt - (long)target) > tol)
         continue;                               // market was closed then

      double c = iClose(_Symbol, _Period, sh);
      if(c <= 0.0)
         continue;

      sum += MathAbs(c / dayOpen - 1.0);
      validDays++;
     }

   if(validDays <= 0)
      return 0.0;
   return sum / (double)validDays;
  }

//==================================================================
//  SESSION VWAP  (anchored at the broker day open)
//==================================================================
double ComputeVWAP(datetime dayStart)
  {
   int sh = iBarShift(_Symbol, _Period, dayStart, false);
   if(sh < 1)
      sh = 1;
   if(sh > 3000)
      sh = 3000;

   double pv = 0.0, vv = 0.0;
   for(int i = sh; i >= 1; i--)
     {
      datetime bt = iTime(_Symbol, _Period, i);
      if(bt < dayStart)
         continue;
      double h = iHigh(_Symbol, _Period, i);
      double l = iLow(_Symbol, _Period, i);
      double c = iClose(_Symbol, _Period, i);
      double v = (double)iTickVolume(_Symbol, _Period, i);
      if(v <= 0.0)
         v = 1.0;
      pv += ((h + l + c) / 3.0) * v;
      vv += v;
     }
   if(vv <= 0.0)
      return 0.0;
   return pv / vv;
  }

//==================================================================
//  POSITION STATE
//==================================================================
bool FindMyPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0)
         continue;
      if(!PositionSelectByTicket(tk))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      g_posTicket = tk;
      return true;
     }
   return false;
  }

void RegisterExit()
  {
   // look at the last closed deal of this EA to update the loss streak
   if(HistorySelect(TimeCurrent() - 7 * 24 * 3600, TimeCurrent() + 60))
     {
      double lastProfit = 0.0;
      datetime lastTime = 0;
      int total = HistoryDealsTotal();
      for(int i = total - 1; i >= 0 && i >= total - 60; i--)
        {
         ulong dt = HistoryDealGetTicket(i);
         if(dt == 0)
            continue;
         if(HistoryDealGetString(dt, DEAL_SYMBOL) != _Symbol)
            continue;
         if((long)HistoryDealGetInteger(dt, DEAL_MAGIC) != InpMagic)
            continue;
         if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(dt, DEAL_ENTRY) != DEAL_ENTRY_OUT)
            continue;
         datetime t = (datetime)HistoryDealGetInteger(dt, DEAL_TIME);
         if(t >= lastTime)
           {
            lastTime = t;
            lastProfit = HistoryDealGetDouble(dt, DEAL_PROFIT)
                         + HistoryDealGetDouble(dt, DEAL_SWAP)
                         + HistoryDealGetDouble(dt, DEAL_COMMISSION);
           }
        }
      if(lastTime > 0)
        {
         if(lastProfit < 0.0)
            g_consecLosses++;
         else
            g_consecLosses = 0;
        }
     }
   g_lastExitBar = iTime(_Symbol, _Period, 0);
  }

void SyncPositionState(bool countBar)
  {
   bool found = FindMyPosition();

   if(found && !g_hasPos)
     {
      // position appeared (opened by us, state re-built after restart)
      g_hasPos    = true;
      g_posIsLong = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      g_posEntry  = PositionGetDouble(POSITION_PRICE_OPEN);
      g_posLots   = PositionGetDouble(POSITION_VOLUME);
      g_extreme   = g_posEntry;
      g_trail     = PositionGetDouble(POSITION_SL);
      g_barsInPos = 0;
     }
   else
      if(!found && g_hasPos)
        {
         g_hasPos   = false;
         g_posTicket = 0;
         g_trail    = 0.0;
         g_extreme  = 0.0;
         g_barsInPos = 0;
         RegisterExit();
        }
      else
         if(found && g_hasPos)
           {
            g_posIsLong = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
            g_posEntry  = PositionGetDouble(POSITION_PRICE_OPEN);
            g_posLots   = PositionGetDouble(POSITION_VOLUME);
            if(countBar)
               g_barsInPos++;
           }
  }

//==================================================================
//  LOT SIZING
//==================================================================
double CalcLots(double stopDistance)
  {
   if(InpLotMode == LOT_FIXED)
      return NormLot(InpFixedLot);

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * InpRiskPercent / 100.0;
   if(riskMoney <= 0.0 || stopDistance <= 0.0)
      return NormLot(InpFixedLot);

   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || tickValue <= 0.0)
      return NormLot(InpFixedLot);

   double lossPerLot = (stopDistance / tickSize) * tickValue;
   if(lossPerLot <= 0.0)
      return NormLot(InpFixedLot);

   return NormLot(riskMoney / lossPerLot);
  }

//==================================================================
//  DYNAMIC TRAIL  (the whole exit logic - no fixed SL/TP anywhere)
//==================================================================
double ComputeTrail(bool isLong, double refPrice, double upper, double lower,
                    double vwap, double atr, double emaStop)
  {
   double s = isLong ? -DBL_MAX : DBL_MAX;

   if(InpUseBandStop && upper > 0.0 && lower > 0.0)
     {
      double v = isLong ? upper : lower;
      s = isLong ? MathMax(s, v) : MathMin(s, v);
     }
   if(InpUseVwapStop && vwap > 0.0)
     {
      s = isLong ? MathMax(s, vwap) : MathMin(s, vwap);
     }
   if(InpUseChandelier && atr > 0.0 && g_extreme > 0.0)
     {
      double v = isLong ? g_extreme - InpChandelierATR * atr
                 : g_extreme + InpChandelierATR * atr;
      s = isLong ? MathMax(s, v) : MathMin(s, v);
     }
   if(InpUseEmaStop && emaStop > 0.0 && atr > 0.0)
     {
      double v = isLong ? emaStop - InpEmaStopATR * atr
                 : emaStop + InpEmaStopATR * atr;
      s = isLong ? MathMax(s, v) : MathMin(s, v);
     }

   if(s == -DBL_MAX || s == DBL_MAX)
     {
      // nothing enabled -> fall back to the disaster distance
      s = isLong ? refPrice - InpDisasterATR * atr : refPrice + InpDisasterATR * atr;
     }

   // never tighter than MinStopATR from the reference price (gold wick protection)
   if(atr > 0.0 && InpMinStopATR > 0.0)
     {
      double lim = isLong ? refPrice - InpMinStopATR * atr : refPrice + InpMinStopATR * atr;
      s = isLong ? MathMin(s, lim) : MathMax(s, lim);
     }
   // never wider than the disaster distance
   if(atr > 0.0 && InpDisasterATR > 0.0)
     {
      double lim = isLong ? refPrice - InpDisasterATR * atr : refPrice + InpDisasterATR * atr;
      s = isLong ? MathMax(s, lim) : MathMin(s, lim);
     }

   return s;
  }

void PushStopToBroker(double stop)
  {
   if(!InpSyncStopToBroker || !g_hasPos)
      return;
   if(!PositionSelectByTicket(g_posTicket))
      return;

   double cur = PositionGetDouble(POSITION_SL);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double pt  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double minDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * pt;
   double frz     = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL) * pt;
   if(minDist < frz)
      minDist = frz;
   if(minDist <= 0.0)
      minDist = 10 * pt;

   if(g_posIsLong)
     {
      if(stop > bid - minDist)
         stop = bid - minDist;
      if(cur > 0.0 && stop <= cur + pt)
         return;                    // only ever ratchet up
     }
   else
     {
      if(stop < ask + minDist)
         stop = ask + minDist;
      if(cur > 0.0 && stop >= cur - pt)
         return;                    // only ever ratchet down
     }

   stop = PriceNorm(stop);
   if(stop <= 0.0)
      return;
   Trade.PositionModify(g_posTicket, stop, 0.0);
  }

//==================================================================
//  DAY STATE
//==================================================================
void UpdateDayState()
  {
   datetime ds = iTime(_Symbol, PERIOD_D1, 0);
   if(ds != g_curDayStart)
     {
      g_curDayStart    = ds;
      g_tradesToday    = 0;
      g_dayBlocked     = false;
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      g_consecLosses   = 0;
     }
   if(g_dayStartEquity <= 0.0)
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
  }

bool DailyGuardsBlock()
  {
   if(g_dayBlocked)
      return true;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);

   if(InpMaxDailyLossPct > 0.0 && g_dayStartEquity > 0.0)
     {
      double dd = (g_dayStartEquity - eq) / g_dayStartEquity * 100.0;
      if(dd >= InpMaxDailyLossPct)
        {
         g_dayBlocked = true;
         Print("[GoldMom] Daily loss limit hit (", DoubleToString(dd, 2), "%). Trading paused for today.");
         return true;
        }
     }
   if(InpDailyProfitLockPct > 0.0 && g_dayStartEquity > 0.0)
     {
      double up = (eq - g_dayStartEquity) / g_dayStartEquity * 100.0;
      if(up >= InpDailyProfitLockPct)
        {
         g_dayBlocked = true;
         Print("[GoldMom] Daily profit lock hit (+", DoubleToString(up, 2), "%). Trading paused for today.");
         return true;
        }
     }
   if(InpMaxConsecLosses > 0 && g_consecLosses >= InpMaxConsecLosses)
     {
      g_dayBlocked = true;
      Print("[GoldMom] ", g_consecLosses, " consecutive losses. Trading paused for today.");
      return true;
     }
   return false;
  }

//==================================================================
//  ENTRY / EXIT DECISIONS
//==================================================================
void CloseNow(string why)
  {
   if(!g_hasPos)
      return;
   if(Trade.PositionClose(g_posTicket, (ulong)InpSlippagePoints))
      Print("[GoldMom] EXIT (", why, ") ticket=", g_posTicket);
   else
      Print("[GoldMom] Close failed: ", Trade.ResultRetcode(), " ", Trade.ResultRetcodeDescription());
  }

void ManageOpenPosition(double upper, double lower, double vwap, double atr, double emaStop)
  {
   double h1 = iHigh(_Symbol, _Period, 1);
   double l1 = iLow(_Symbol, _Period, 1);
   double c1 = iClose(_Symbol, _Period, 1);

   // --- track trade extreme for the chandelier
   if(g_posIsLong)
      g_extreme = MathMax(g_extreme, h1);
   else
      g_extreme = (g_extreme <= 0.0 ? l1 : MathMin(g_extreme, l1));

   // --- recompute + ratchet the trail
   double t = ComputeTrail(g_posIsLong, c1, upper, lower, vwap, atr, emaStop);
   if(g_trail <= 0.0)
      g_trail = t;
   else
      g_trail = g_posIsLong ? MathMax(g_trail, t) : MathMin(g_trail, t);

   PushStopToBroker(g_trail);

   // --- time-of-day flat-out
   int nowMin = ServerMinutesNow();
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(InpFridayFlat && dt.day_of_week == 5 && nowMin >= ToServerMinutes(InpFridayFlatHour, 0))
     {
      CloseNow("friday-flat");
      return;
     }
   int flatStart = ToServerMinutes(InpFlatHour, InpFlatMin);
   int flatEnd   = (flatStart + 90) % 1440;
   if(InpFlatAtSessionEnd && InWindow(nowMin, flatStart, flatEnd))
     {
      CloseNow("session-flat");
      return;
     }
   if(InpMaxBarsInTrade > 0 && g_barsInPos >= InpMaxBarsInTrade)
     {
      CloseNow("time-stop");
      return;
     }
   if(DailyGuardsBlock())
     {
      CloseNow("daily-guard");
      return;
     }

   // --- bar-close trail breach (the broker SL usually fires first intrabar)
   if(g_posIsLong && c1 <= g_trail)
     {
      CloseNow("trail-break");
      return;
     }
   if(!g_posIsLong && c1 >= g_trail)
     {
      CloseNow("trail-break");
      return;
     }
  }

int CheckEntrySignal(double upper, double lower, double vwap, double atr,
                     double emaF, double emaS, double emaStop, double adx)
  {
   double c1 = iClose(_Symbol, _Period, 1);
   double o1 = iOpen(_Symbol, _Period, 1);
   double body = MathAbs(c1 - o1);

   // --- anti-chop: the noise area must be meaningfully wide
   if(InpMinBandWidthATR > 0.0 && atr > 0.0)
      if((upper - lower) < InpMinBandWidthATR * atr)
        {
         g_state = "band too narrow";
         return 0;
        }

   double buf = InpBreakoutBufferATR * atr;

   bool longRaw  = (c1 > upper + buf);
   bool shortRaw = (c1 < lower - buf);

   if(!longRaw && !shortRaw)
     {
      g_state = "inside noise area";
      return 0;
     }

   // --- momentum confirmations
   if(InpUseBodyFilter && atr > 0.0 && body < InpMinBodyATR * atr)
     {
      g_state = "weak breakout body";
      return 0;
     }
   if(InpUseAdxFilter && adx < InpAdxMin)
     {
      g_state = "ADX too low (" + DoubleToString(adx, 1) + ")";
      return 0;
     }
   if(longRaw)
     {
      if(InpUseVwapFilter && vwap > 0.0 && c1 <= vwap)
        {
         g_state = "long blocked by VWAP";
         return 0;
        }
      if(InpUseEmaFilter && !(emaF > emaS && c1 > emaStop))
        {
         g_state = "long blocked by EMA";
         return 0;
        }
      if(!InpAllowLong)
        {
         g_state = "longs disabled";
         return 0;
        }
      return 1;
     }

   if(shortRaw)
     {
      if(InpUseVwapFilter && vwap > 0.0 && c1 >= vwap)
        {
         g_state = "short blocked by VWAP";
         return 0;
        }
      if(InpUseEmaFilter && !(emaF < emaS && c1 < emaStop))
        {
         g_state = "short blocked by EMA";
         return 0;
        }
      if(!InpAllowShort)
        {
         g_state = "shorts disabled";
         return 0;
        }
      return -1;
     }

   return 0;
  }

bool TradingWindowOpen()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(dt.day_of_week == 0 || dt.day_of_week == 6)
      return false;
   if(!InpTradeMonday && dt.day_of_week == 1)
      return false;
   if(!InpTradeFriday && dt.day_of_week == 5)
      return false;

   int nowMin = ServerMinutesNow();

   if(dt.day_of_week == 5 && nowMin >= ToServerMinutes(InpFridayStopHour, 0))
      return false;

   int s = ToServerMinutes(InpSessionStartHour, InpSessionStartMin);
   int e = ToServerMinutes(InpSessionEndHour, InpSessionEndMin);
   return InWindow(nowMin, s, e);
  }

bool SpreadOK(double atr)
  {
   double spP = SpreadPoints();
   if(InpMaxSpreadPoints > 0 && spP > InpMaxSpreadPoints)
     {
      g_state = "spread too wide (" + DoubleToString(spP, 0) + "pts)";
      return false;
     }
   if(InpMaxSpreadATRfrac > 0.0 && atr > 0.0)
     {
      if(SpreadPrice() > InpMaxSpreadATRfrac * atr)
        {
         g_state = "spread too wide vs ATR";
         return false;
        }
     }
   return true;
  }

void TryEntry(double upper, double lower, double vwap, double atr,
              double emaF, double emaS, double emaStop, double adx)
  {
   if(DailyGuardsBlock())
     {
      g_state = "day blocked";
      return;
     }
   if(InpMaxTradesPerDay > 0 && g_tradesToday >= InpMaxTradesPerDay)
     {
      g_state = "max trades/day";
      return;
     }
   if(!TradingWindowOpen())
     {
      g_state = "outside session";
      return;
     }
   if(InpCooldownBars > 0 && g_lastExitBar > 0)
     {
      int barsSince = iBarShift(_Symbol, _Period, g_lastExitBar, false);
      if(barsSince >= 0 && barsSince < InpCooldownBars)
        {
         g_state = "cooldown";
         return;
        }
     }
   if(atr <= 0.0)
     {
      g_state = "no ATR";
      return;
     }
   if(InpMinAtrUsd > 0.0 && atr < InpMinAtrUsd)
     {
      g_state = "ATR too low (" + DoubleToString(atr, 2) + ")";
      return;
     }
   if(InpMaxAtrUsd > 0.0 && atr > InpMaxAtrUsd)
     {
      g_state = "ATR too high (" + DoubleToString(atr, 2) + ")";
      return;
     }
   if(!SpreadOK(atr))
      return;

   int sig = CheckEntrySignal(upper, lower, vwap, atr, emaF, emaS, emaStop, adx);
   if(sig == 0)
      return;

   bool isLong = (sig > 0);
   double price = isLong ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                  : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(price <= 0.0)
      return;

   // initial dynamic stop (also used for sizing) - NOT a fixed SL
   g_extreme = price;
   double initStop = ComputeTrail(isLong, price, upper, lower, vwap, atr, emaStop);
   double stopDist = MathAbs(price - initStop);
   if(stopDist <= 0.0)
      stopDist = InpMinStopATR * atr;

   double lots = CalcLots(stopDist);
   if(lots <= 0.0)
     {
      g_state = "lot calc failed";
      return;
     }

   double brokerSL = 0.0;
   if(InpSyncStopToBroker)
     {
      brokerSL = isLong ? price - InpDisasterATR * atr : price + InpDisasterATR * atr;
      brokerSL = PriceNorm(brokerSL);
     }

   Trade.SetDeviationInPoints((ulong)InpSlippagePoints);
   bool ok = isLong
             ? Trade.Buy(lots, _Symbol, 0.0, brokerSL, 0.0, InpComment)
             : Trade.Sell(lots, _Symbol, 0.0, brokerSL, 0.0, InpComment);

   if(!ok)
     {
      Print("[GoldMom] Entry failed: ", Trade.ResultRetcode(), " ",
            Trade.ResultRetcodeDescription());
      g_state = "entry rejected";
      return;
     }

   g_tradesToday++;
   g_hasPos     = true;
   g_posIsLong  = isLong;
   g_posEntry   = price;
   g_posLots    = lots;
   g_trail      = initStop;
   g_barsInPos  = 0;
   FindMyPosition();

   PrintFormat("[GoldMom] ENTRY %s  lots=%.2f  px=%.2f  initTrail=%.2f  ATR=%.2f  sigma=%.5f  band=[%.2f / %.2f]  vwap=%.2f",
               (isLong ? "LONG" : "SHORT"), lots, price, initStop, atr, g_sigma, lower, upper, vwap);

   // immediately push the tighter strategy trail (never looser than disaster)
   PushStopToBroker(initStop);
   g_state = "in trade";
  }

//==================================================================
//  PANEL
//==================================================================
void DrawPanel()
  {
   if(!InpShowPanel)
      return;
   if(MQLInfoInteger(MQL_OPTIMIZATION))
      return;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   string s = "";
   s += "=========== GOLD MOMENTUM EA ===========\n";
   s += StringFormat("Symbol/TF      : %s  %s\n", _Symbol, EnumToString((ENUM_TIMEFRAMES)_Period));
   s += StringFormat("Server time    : %02d:%02d  (day %d)\n", dt.hour, dt.min, dt.day_of_week);
   s += StringFormat("Session open   : %s\n", (TradingWindowOpen() ? "YES" : "no"));
   s += StringFormat("ATR(%d)        : %.2f USD\n", InpAtrPeriod, g_atr);
   s += StringFormat("Sigma(t)       : %.4f %%   (%d valid days)\n", g_sigma * 100.0, g_validDays);
   s += StringFormat("Noise band     : %.2f  ...  %.2f   (w=%.2f)\n", g_lower, g_upper, g_upper - g_lower);
   s += StringFormat("Session VWAP   : %.2f\n", g_vwap);
   s += StringFormat("Spread         : %.0f pts\n", SpreadPoints());
   s += "----------------------------------------\n";
   if(g_hasPos)
     {
      double cur = g_posIsLong ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                   : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      s += StringFormat("POSITION       : %s  %.2f lots\n", (g_posIsLong ? "LONG" : "SHORT"), g_posLots);
      s += StringFormat("Entry / Now    : %.2f / %.2f\n", g_posEntry, cur);
      s += StringFormat("Dynamic trail  : %.2f  (%.2f away)\n", g_trail, MathAbs(cur - g_trail));
      s += StringFormat("Bars in trade  : %d\n", g_barsInPos);
     }
   else
      s += StringFormat("POSITION       : flat  |  %s\n", g_state);
   s += "----------------------------------------\n";
   s += StringFormat("Trades today   : %d / %d\n", g_tradesToday,
                     (InpMaxTradesPerDay > 0 ? InpMaxTradesPerDay : 999));
   s += StringFormat("Consec losses  : %d\n", g_consecLosses);
   s += StringFormat("Day equity     : %.2f -> %.2f\n", g_dayStartEquity,
                     AccountInfoDouble(ACCOUNT_EQUITY));
   s += StringFormat("Day blocked    : %s\n", (g_dayBlocked ? "YES" : "no"));
   s += "NO fixed SL / NO fixed TP - momentum exits only\n";
   Comment(s);
  }

//==================================================================
//  EVENT HANDLERS
//==================================================================
int OnInit()
  {
   if(_Period != PERIOD_M1 && _Period != PERIOD_M5 && _Period != PERIOD_M15)
      Print("[GoldMom] WARNING: designed for M1 / M5 (M15 tolerable). Current TF: ",
            EnumToString((ENUM_TIMEFRAMES)_Period));

   hATR     = iATR(_Symbol, _Period, InpAtrPeriod);
   hEmaFast = iMA(_Symbol, _Period, InpEmaFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
   hEmaSlow = iMA(_Symbol, _Period, InpEmaSlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
   hEmaStop = iMA(_Symbol, _Period, InpEmaStopPeriod, 0, MODE_EMA, PRICE_CLOSE);
   hADX     = iADX(_Symbol, _Period, InpAdxPeriod);

   if(hATR == INVALID_HANDLE || hEmaFast == INVALID_HANDLE || hEmaSlow == INVALID_HANDLE
      || hEmaStop == INVALID_HANDLE || hADX == INVALID_HANDLE)
     {
      Print("[GoldMom] Indicator handle creation failed.");
      return INIT_FAILED;
     }

   Trade.SetExpertMagicNumber((ulong)InpMagic);
   Trade.SetDeviationInPoints((ulong)InpSlippagePoints);
   Trade.SetAsyncMode(false);
   SetupFilling();

   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_curDayStart    = iTime(_Symbol, PERIOD_D1, 0);

   PrintFormat("[GoldMom] initialised on %s %s | lookback=%d days | band=%.2f sigma | no fixed SL/TP",
               _Symbol, EnumToString((ENUM_TIMEFRAMES)_Period),
               InpLookbackDays, InpBandMultiplier);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(hATR     != INVALID_HANDLE) IndicatorRelease(hATR);
   if(hEmaFast != INVALID_HANDLE) IndicatorRelease(hEmaFast);
   if(hEmaSlow != INVALID_HANDLE) IndicatorRelease(hEmaSlow);
   if(hEmaStop != INVALID_HANDLE) IndicatorRelease(hEmaStop);
   if(hADX     != INVALID_HANDLE) IndicatorRelease(hADX);
   Comment("");
  }

void OnTick()
  {
   datetime bt = iTime(_Symbol, _Period, 0);
   if(bt == 0)
      return;

   if(bt == g_lastBarTime)
     {
      DrawPanel();
      return;                    // all logic is closed-bar based
     }
   g_lastBarTime = bt;

   int needBars = (InpEmaSlowPeriod > InpAtrPeriod ? InpEmaSlowPeriod : InpAtrPeriod) + 60;
   if(Bars(_Symbol, _Period) < needBars)
      return;
   if(Bars(_Symbol, PERIOD_D1) < InpLookbackDays + 2)
      return;

   UpdateDayState();
   SyncPositionState(true);

   //--- indicator snapshot on the last CLOSED bar
   g_atr        = BufVal(hATR, 0, 1);
   double emaF  = BufVal(hEmaFast, 0, 1);
   double emaS  = BufVal(hEmaSlow, 0, 1);
   double emaSt = BufVal(hEmaStop, 0, 1);
   double adx   = BufVal(hADX, 0, 1);

   //--- intraday context
   datetime dayStart = g_curDayStart;
   datetime bar1Time = iTime(_Symbol, _Period, 1);
   int secsIntoDay = (int)((long)bar1Time - (long)dayStart);
   if(secsIntoDay < 0)
      secsIntoDay = 0;
   if(secsIntoDay > 86400)
      secsIntoDay = 86400;

   g_sigma = ComputeSigma(secsIntoDay, g_validDays);
   g_vwap  = ComputeVWAP(dayStart);

   double todayOpen = iOpen(_Symbol, PERIOD_D1, 0);
   double prevClose = iClose(_Symbol, PERIOD_D1, 1);
   if(todayOpen <= 0.0)
     {
      int osh = iBarShift(_Symbol, _Period, dayStart, false);
      if(osh < 1)
         osh = 1;
      todayOpen = iOpen(_Symbol, _Period, osh);
     }
   if(prevClose <= 0.0)
      prevClose = todayOpen;

   double baseUp = MathMax(todayOpen, prevClose);
   double baseDn = MathMin(todayOpen, prevClose);
   g_upper = baseUp * (1.0 + InpBandMultiplier * g_sigma);
   g_lower = baseDn * (1.0 - InpBandMultiplier * g_sigma);

   //--- manage first, then look for a new entry
   if(g_hasPos)
     {
      ManageOpenPosition(g_upper, g_lower, g_vwap, g_atr, emaSt);
      SyncPositionState(false);
     }

   if(!g_hasPos)
     {
      if(g_validDays < InpMinValidDays)
         g_state = "not enough history (" + IntegerToString(g_validDays) + " days)";
      else
         TryEntry(g_upper, g_lower, g_vwap, g_atr, emaF, emaS, emaSt, adx);
     }

   DrawPanel();
  }
//+------------------------------------------------------------------+
