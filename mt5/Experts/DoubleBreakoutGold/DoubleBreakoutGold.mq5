//+------------------------------------------------------------------+
//|                                            DoubleBreakoutGold.mq5 |
//|                    DOUBLE BREAKOUT GOLD EA  -  XAUUSD / M5-M15    |
//|                                                                   |
//|  Strategy logic (see docs/STRATEGY.md for the full write-up):     |
//|    1st breakout : price closes beyond the session (Asian) range   |
//|                   -> the range boundary is "cleared"              |
//|    pullback     : price retraces 20-70% of the breakout leg       |
//|                   (>70% = failed break, setup is discarded)       |
//|    2nd breakout : price takes out the high/low of the breakout    |
//|                   leg -> THIS is the trade trigger                |
//|    optional     : the 2nd level must also clear PDH / PDL         |
//|                                                                   |
//|  Research base:                                                   |
//|    - Zarattini & Aziz (2023), "Can Day Trading Really Be          |
//|      Profitable?" SSRN 4416622  -> opening-range breakout, stop   |
//|      at the opposite side of the range, R-multiple target, EoD    |
//|      exit, 1% risk per trade.                                     |
//|    - Zarattini, Barbon & Aziz (2024), SSRN 4729284 -> the edge    |
//|      concentrates in high relative-volume sessions (RVOL filter). |
//|    - Replication note (MQL5 blog 776235, 2026): the raw ORB edge  |
//|      is roughly the size of the spread -> hence the 2nd breakout  |
//|      confirmation, spread cap, ATR range filter and news filter.  |
//|                                                                   |
//|  Extras: broker timezone/DST auto-detection, world clock,         |
//|          MT5 economic-calendar news lock (30 min before / after), |
//|          full on-chart dashboard with control buttons.            |
//+------------------------------------------------------------------+
#property copyright "Double Breakout Gold EA"
#property link      "https://www.mql5.com/en/articles/21235"
#property version   "1.00"
#property description "Double Breakout (range break -> pullback -> re-break) EA for Gold with SL/TP, news filter and dashboard."

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include <Trade/OrderInfo.mqh>

#include "DBG_Utils.mqh"
#include "DBG_TimeZone.mqh"
#include "DBG_News.mqh"
#include "DBG_Dashboard.mqh"

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+
input group "=== 1. GENERAL ==="
input long              InpMagic              = 20260929;   // Magic number
input string            InpComment            = "DoubleBreakoutGold"; // Order comment
input ENUM_TIMEFRAMES   InpSignalTF           = PERIOD_M15; // Signal timeframe
input double            InpMaxSpreadPoints    = 60;         // Max allowed spread (points, 0=off)
input ulong             InpSlippage           = 30;         // Max deviation (points)
input bool              InpVerboseLog         = true;       // Verbose journal logging

input group "=== 2. SESSION / TIME WINDOW (broker TZ auto-detected) ==="
input ENUM_DBG_TIMEBASE InpTimeBase           = DBG_TB_GMT; // Times below are given in
input bool              InpManualOffset       = false;      // Override broker GMT offset?
input int               InpManualOffsetHours  = 3;          // ...manual offset (hours vs GMT)
input string            InpRangeStart         = "00:00";    // Range window START (hh:mm)
input string            InpRangeEnd           = "07:00";    // Range window END   (hh:mm)
input string            InpTradeEnd           = "18:00";    // Stop opening new trades at
input string            InpFlattenTime        = "20:30";    // Close everything (EoD exit) at
input bool              InpTradeMon           = true;       // Trade Monday
input bool              InpTradeTue           = true;       // Trade Tuesday
input bool              InpTradeWed           = true;       // Trade Wednesday
input bool              InpTradeThu           = true;       // Trade Thursday
input bool              InpTradeFri           = true;       // Trade Friday
input int               InpFridayCloseHour    = 20;         // Friday force-flat hour (GMT, 0=off)

input group "=== 3. DOUBLE BREAKOUT LOGIC ==="
input ENUM_DBG_MODE     InpMode               = DBG_MODE_REBREAK; // Double breakout mode
input ENUM_DBG_ENTRY    InpEntryType          = DBG_ENTRY_STOP;   // Entry execution
input double            InpBreakBufferAtr     = 0.10;       // Breakout buffer (x ATR)
input double            InpMinBodyRatio       = 0.55;       // Min body/range of break candle (0=off)
input double            InpMinPullbackPct     = 20.0;       // Min pullback of break leg (%)
input double            InpMaxPullbackPct     = 70.0;       // Max pullback (>this = failed break) (%)
input int               InpTriggerExpiryMin   = 120;        // Stop order lifetime (minutes)
input int               InpMaxSetupsPerDay    = 2;          // Max setups (attempts) per session
input double            InpMinRangeAtrPct     = 12.0;       // Min range size (% of daily ATR)
input double            InpMaxRangeAtrPct     = 70.0;       // Max range size (% of daily ATR)
input double            InpMinRvol            = 0.0;        // Min relative volume of range (0=off)
input bool              InpUseTrendFilter     = false;      // Use higher-TF trend filter
input ENUM_TIMEFRAMES   InpTrendTF            = PERIOD_H4;  // Trend timeframe
input int               InpTrendMaPeriod      = 50;         // Trend EMA period

input group "=== 4. RISK, SL & TP ==="
input double            InpRiskPercent        = 0.75;       // Risk per trade (% of balance, 0=fixed lot)
input double            InpFixedLots          = 0.01;       // Fixed lot (used when risk % = 0)
input ENUM_DBG_SLMODE   InpSlMode             = DBG_SL_STRUCTURE; // Stop-loss placement
input double            InpAtrSlMult          = 1.20;       // ATR stop multiplier (ATR mode)
input double            InpMinStopAtr         = 0.60;       // Min stop distance (x ATR)
input double            InpMaxStopAtr         = 2.50;       // Max stop distance (x ATR)
input double            InpTp1R               = 1.50;       // TP1 (R multiple, 0=off)
input double            InpTp1ClosePct        = 50.0;       // % of position closed at TP1
input double            InpTp2R               = 3.00;       // TP2 / final target (R multiple)
input bool              InpUseBreakeven       = true;       // Move SL to breakeven
input double            InpBeTriggerR         = 1.00;       // ...trigger (R)
input double            InpBeLockR            = 0.10;       // ...locked profit (R)
input bool              InpUseTrailing        = true;       // ATR trailing stop
input double            InpTrailStartR        = 1.20;       // ...start after (R)
input double            InpTrailAtrMult       = 1.60;       // ...distance (x ATR)
input bool              InpUseEodExit         = true;       // Close at session end (paper rule)

input group "=== 5. DAILY GUARDS ==="
input int               InpMaxTradesPerDay    = 2;          // Max filled trades per day
input int               InpMaxConsecLosses    = 3;          // Stop after N consecutive losses (0=off)
input double            InpDailyLossPct       = 3.0;        // Daily loss limit (% of start balance, 0=off)
input double            InpDailyProfitPct     = 0.0;        // Daily profit target (% , 0=off)

input group "=== 6. NEWS FILTER (MT5 ECONOMIC CALENDAR) ==="
input bool              InpNewsEnabled        = true;       // Enable news filter
input string            InpNewsCurrencies     = "AUTO";     // Currencies (AUTO / ALL / "USD,EUR")
input ENUM_DBG_NEWSIMP  InpNewsImportance     = DBG_IMP_HIGH; // Which events block trading
input int               InpNewsMinsBefore     = 30;         // Stop trading X min BEFORE news
input int               InpNewsMinsAfter      = 30;         // Resume X min AFTER news
input bool              InpNewsClosePositions = true;       // Close open trades before news
input int               InpNewsCloseBeforeMin = 5;          // ...how many min before
input bool              InpNewsDeletePending  = true;       // Delete pending triggers during lock
input int               InpNewsShiftMinutes   = 0;          // Calendar time correction (min)
input int               InpNewsReloadMinutes  = 30;         // Calendar refresh interval (min)
input bool              InpNewsUseCsv         = true;       // Use CSV fallback (backtest)
input string            InpNewsCsvFile        = "DBG_News.csv"; // CSV file name
input bool              InpNewsCsvCommon      = true;       // CSV in COMMON folder

input group "=== 7. DASHBOARD ==="
input bool              InpShowPanel          = true;       // Show dashboard
input ENUM_BASE_CORNER  InpPanelCorner        = CORNER_LEFT_UPPER; // Panel corner
input int               InpPanelX             = 12;         // Panel X
input int               InpPanelY             = 18;         // Panel Y
input int               InpPanelWidth         = 430;        // Panel width
input int               InpPanelFontSize      = 8;          // Font size
input string            InpPanelFont          = "Consolas"; // Font
input bool              InpShowLevels         = true;       // Draw range / trigger levels on chart

//+------------------------------------------------------------------+
//| GLOBALS                                                          |
//+------------------------------------------------------------------+
CTrade          trade;
CPositionInfo   posInfo;
COrderInfo      ordInfo;
CDbgTimeZone    TZ;
CDbgNews        News;
CDbgDashboard   Panel;

int      hAtrSig   = INVALID_HANDLE;
int      hAtrD1    = INVALID_HANDLE;
int      hTrendMa  = INVALID_HANDLE;

double   g_atr      = 0.0;      // ATR on signal TF
double   g_atrD1    = 0.0;      // ATR on D1
double   g_trendMa  = 0.0;

//--- session
datetime g_sessionId       = 0;   // = range end (server) -> unique per session
datetime g_rangeStartSrv   = 0;
datetime g_rangeEndSrv     = 0;
datetime g_tradeEndSrv     = 0;
datetime g_flattenSrv      = 0;

bool     g_rangeReady      = false;
bool     g_rangeValid      = false;
string   g_rangeReject     = "";
double   g_rangeHigh       = 0.0;
double   g_rangeLow        = 0.0;
double   g_rangeSize       = 0.0;
double   g_rvol            = 0.0;
double   g_pdh             = 0.0;
double   g_pdl             = 0.0;

//--- setup state
ENUM_DBG_PHASE g_phase     = DBG_PH_PRERANGE;
int      g_dir             = 0;
int      g_setups          = 0;
double   g_b1Level         = 0.0;   // range level that was broken
double   g_b1Peak          = 0.0;   // extreme of the 1st breakout leg
double   g_pullExtreme     = 0.0;   // pullback extreme
bool     g_pullbackOk      = false;
datetime g_b1Time          = 0;
double   g_trigger         = 0.0;   // 2nd breakout price
ulong    g_pendingTicket   = 0;
datetime g_pendingExpiry   = 0;

//--- position state
ulong    g_posTicket       = 0;
double   g_posEntry        = 0.0;
double   g_posRisk         = 0.0;   // 1R in price
int      g_posDir          = 0;
bool     g_beDone          = false;
bool     g_tp1Done         = false;

//--- daily stats
datetime g_statDay         = 0;
int      g_tradesToday     = 0;
int      g_winsToday       = 0;
int      g_lossesToday     = 0;
int      g_consecLoss      = 0;
double   g_dayPnl          = 0.0;
double   g_dayStartBalance = 0.0;
bool     g_halted          = false;
string   g_haltReason      = "";

bool     g_paused          = false;
datetime g_lastBarTime     = 0;
string   g_lastMsg         = "";

#define LVL_PREFIX DBG_PREFIX+"lvl_"

//--- forward declarations
void   Log(const string msg);
void   ResetSetup(void);
bool   FindPosition(void);
int    CountPending(void);
void   DeletePending(const string why);
void   CloseAllPositions(const string why);
bool   TradingAllowed(string &reason);
void   UpdatePanel(void);
void   DrawLevels(void);
void   ComputeSessionWindow(void);
bool   BuildRange(void);
bool   PlaceTrigger(const int dir,const double triggerPrice);
double CalcStopLoss(const int dir,const double entry);
double CalcLots(const double stopDistance);
double NormalizeLots(double lots);
void   ProcessBar(void);
void   HandleExits(void);
void   ManagePosition(void);
void   UpdateDailyStats(void);
bool   UpdateIndicators(void);
double BreakBuffer(void);
string SlModeText(void);
string NewsImpText(void);

//+------------------------------------------------------------------+
//| Logging                                                          |
//+------------------------------------------------------------------+
void Log(const string msg)
  {
   g_lastMsg = msg;
   if(InpVerboseLog) Print("[DBG] ",msg);
  }

//+------------------------------------------------------------------+
//| hh:mm -> seconds                                                 |
//+------------------------------------------------------------------+
int ParseHM(const string hm,const int fallbackSec)
  {
   string p[];
   if(StringSplit(hm,StringGetCharacter(":",0),p)<2) return(fallbackSec);
   int h = (int)StringToInteger(p[0]);
   int m = (int)StringToInteger(p[1]);
   if(h<0 || h>23 || m<0 || m>59) return(fallbackSec);
   return(h*3600+m*60);
  }

//+------------------------------------------------------------------+
//| Convert a "configured" time to server time                       |
//+------------------------------------------------------------------+
datetime CfgToServer(const datetime cfgTime)
  {
   if(InpTimeBase==DBG_TB_SERVER) return(cfgTime);
   return(TZ.ToServer(cfgTime));
  }
datetime ServerToCfg(const datetime srvTime)
  {
   if(InpTimeBase==DBG_TB_SERVER) return(srvTime);
   return(TZ.ToGmt(srvTime));
  }

//+------------------------------------------------------------------+
//| Compute the session windows for "now"                            |
//+------------------------------------------------------------------+
void ComputeSessionWindow(void)
  {
   int s  = ParseHM(InpRangeStart,0);
   int e  = ParseHM(InpRangeEnd,7*3600);
   int te = ParseHM(InpTradeEnd,18*3600);
   int fl = ParseHM(InpFlattenTime,20*3600+1800);

   datetime nowCfg = ServerToCfg(TimeTradeServer());
   datetime day    = nowCfg-(datetime)(nowCfg%86400);

   int L = (e-s+86400)%86400;                 // range length (handles overnight)
   if(L==0) L = 3600;

   datetime rEnd   = day+(datetime)e;
   datetime rStart = rEnd-(datetime)L;

   //--- roll forward when the next session's range has already started
   if(nowCfg>=rEnd && nowCfg>=(rEnd+86400-(datetime)L))
     { rEnd += 86400; rStart += 86400; }
   //--- roll back when we are still before this session's range start
   if(nowCfg<rStart)
     { rEnd -= 86400; rStart -= 86400; }

   datetime rEndDay = rEnd-(datetime)(rEnd%86400);
   datetime tEnd    = rEndDay+(datetime)te;   if(te<=e) tEnd += 86400;
   datetime flat    = rEndDay+(datetime)fl;   if(fl<=e) flat += 86400;
   if(flat<tEnd) flat = tEnd;

   datetime newId = CfgToServer(rEnd);
   if(newId!=g_sessionId)
     {
      g_sessionId     = newId;
      g_rangeReady    = false;
      g_rangeValid    = false;
      g_rangeReject   = "";
      g_rangeHigh     = 0.0;
      g_rangeLow      = 0.0;
      g_rangeSize     = 0.0;
      g_rvol          = 0.0;
      g_setups        = 0;
      ResetSetup();
      g_phase         = DBG_PH_PRERANGE;
      ObjectsDeleteAll(0,LVL_PREFIX);
     }

   g_rangeStartSrv = CfgToServer(rStart);
   g_rangeEndSrv   = CfgToServer(rEnd);
   g_tradeEndSrv   = CfgToServer(tEnd);
   g_flattenSrv    = CfgToServer(flat);
  }

//+------------------------------------------------------------------+
void ResetSetup(void)
  {
   g_dir         = 0;
   g_b1Level     = 0.0;
   g_b1Peak      = 0.0;
   g_pullExtreme = 0.0;
   g_pullbackOk  = false;
   g_b1Time      = 0;
   g_trigger     = 0.0;
   g_pendingExpiry = 0;
  }

//+------------------------------------------------------------------+
bool IsTradingDay(void)
  {
   MqlDateTime d; TimeToStruct(TimeTradeServer(),d);
   switch(d.day_of_week)
     {
      case 1: return(InpTradeMon);
      case 2: return(InpTradeTue);
      case 3: return(InpTradeWed);
      case 4: return(InpTradeThu);
      case 5: return(InpTradeFri);
      default: return(false);
     }
  }

//+------------------------------------------------------------------+
//| Indicators                                                       |
//+------------------------------------------------------------------+
bool UpdateIndicators(void)
  {
   double buf[];
   if(CopyBuffer(hAtrSig,0,1,1,buf)<1) return(false);
   g_atr = buf[0];
   if(g_atr<=0.0) return(false);

   if(CopyBuffer(hAtrD1,0,1,1,buf)>=1)
      g_atrD1 = buf[0];
   if(g_atrD1<=0.0) g_atrD1 = g_atr*8.0;

   if(InpUseTrendFilter && hTrendMa!=INVALID_HANDLE)
     {
      if(CopyBuffer(hTrendMa,0,1,1,buf)>=1)
         g_trendMa = buf[0];
     }
   return(true);
  }

//+------------------------------------------------------------------+
string SlModeText(void)
  {
   if(InpSlMode==DBG_SL_RANGE) return("range-opposite");
   if(InpSlMode==DBG_SL_ATR)   return("ATR x"+DoubleToString(InpAtrSlMult,2));
   return("structure");
  }

string NewsImpText(void)
  {
   if(InpNewsImportance==DBG_IMP_ALL)      return("all");
   if(InpNewsImportance==DBG_IMP_HIGH_MED) return("high+med");
   return("high");
  }

//+------------------------------------------------------------------+
double BreakBuffer(void)
  {
   double b = InpBreakBufferAtr*g_atr;
   double minB = 2.0*DbgPoint(_Symbol);
   return(MathMax(b,minB));
  }

//+------------------------------------------------------------------+
//| Range construction                                               |
//+------------------------------------------------------------------+
double WindowVolume(const datetime from,const datetime to)
  {
   MqlRates r[];
   int n = CopyRates(_Symbol,InpSignalTF,from,to-1,r);
   if(n<=0) return(0.0);
   double v=0.0;
   for(int i=0;i<n;i++) v += (double)r[i].tick_volume;
   return(v);
  }

//+------------------------------------------------------------------+
bool BuildRange(void)
  {
   MqlRates r[];
   int n = CopyRates(_Symbol,InpSignalTF,g_rangeStartSrv,g_rangeEndSrv-1,r);
   if(n<=0) { g_rangeReject="no data in range window"; return(false); }

   double hi=-DBL_MAX, lo=DBL_MAX, vol=0.0;
   for(int i=0;i<n;i++)
     {
      hi = MathMax(hi,r[i].high);
      lo = MathMin(lo,r[i].low);
      vol += (double)r[i].tick_volume;
     }
   if(hi<=lo) { g_rangeReject="invalid range"; return(false); }

   g_rangeHigh = hi;
   g_rangeLow  = lo;
   g_rangeSize = hi-lo;

   //--- relative volume of the range window vs. the last 10 sessions
   if(InpMinRvol>0.0)
     {
      double sum=0.0; int cnt=0;
      for(int k=1;k<=10;k++)
        {
         datetime f = g_rangeStartSrv-(datetime)(k*86400);
         datetime t = g_rangeEndSrv-(datetime)(k*86400);
         double v = WindowVolume(f,t);
         if(v>0.0) { sum += v; cnt++; }
        }
      g_rvol = (cnt>0 && sum>0.0 ? vol/(sum/cnt) : 0.0);
     }

   //--- previous day high / low
   MqlRates d[];
   if(CopyRates(_Symbol,PERIOD_D1,0,3,d)>=2)
     {
      int last = ArraySize(d)-1;
      //--- d[last] is today's (forming) daily bar -> use the one before
      g_pdh = d[last-1].high;
      g_pdl = d[last-1].low;
     }

   //--- validity filters
   g_rangeReject = "";
   double pctAtr = (g_atrD1>0.0 ? g_rangeSize/g_atrD1*100.0 : 0.0);
   if(InpMinRangeAtrPct>0.0 && pctAtr<InpMinRangeAtrPct)
      g_rangeReject = StringFormat("range too small (%.0f%% of D-ATR)",pctAtr);
   else if(InpMaxRangeAtrPct>0.0 && pctAtr>InpMaxRangeAtrPct)
      g_rangeReject = StringFormat("range too wide (%.0f%% of D-ATR)",pctAtr);
   else if(InpMinRvol>0.0 && g_rvol>0.0 && g_rvol<InpMinRvol)
      g_rangeReject = StringFormat("low RVOL (%.2f)",g_rvol);

   g_rangeValid = (StringLen(g_rangeReject)==0);
   g_rangeReady = true;

   Log(StringFormat("Range built  H=%s L=%s size=%.2f (%.0f%% D-ATR) RVOL=%.2f -> %s",
                    DbgPriceStr(_Symbol,g_rangeHigh),DbgPriceStr(_Symbol,g_rangeLow),
                    g_rangeSize,pctAtr,g_rvol,(g_rangeValid ? "VALID" : g_rangeReject)));
   return(true);
  }

//+------------------------------------------------------------------+
//| Position / order helpers                                         |
//+------------------------------------------------------------------+
bool FindPosition(void)
  {
   g_posTicket = 0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      g_posTicket = tk;
      g_posEntry  = PositionGetDouble(POSITION_PRICE_OPEN);
      g_posDir    = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY ? 1 : -1);
      return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
int CountPending(void)
  {
   int c=0;
   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk==0) continue;
      if(OrderGetString(ORDER_SYMBOL)!=_Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC)!=InpMagic) continue;
      c++;
     }
   return(c);
  }

//+------------------------------------------------------------------+
void DeletePending(const string why)
  {
   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk==0) continue;
      if(OrderGetString(ORDER_SYMBOL)!=_Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC)!=InpMagic) continue;
      if(trade.OrderDelete(tk))
         Log("Pending #"+IntegerToString((int)tk)+" deleted ("+why+")");
     }
   g_pendingTicket = 0;
  }

//+------------------------------------------------------------------+
void CloseAllPositions(const string why)
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if(trade.PositionClose(tk,InpSlippage))
         Log("Position #"+IntegerToString((int)tk)+" closed ("+why+")");
     }
  }

//+------------------------------------------------------------------+
//| Lot sizing                                                       |
//+------------------------------------------------------------------+
double NormalizeLots(double lots)
  {
   double mn = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double mx = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double st = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(st<=0.0) st = 0.01;
   lots = MathFloor(lots/st+0.0000001)*st;
   if(lots<mn) lots = mn;
   if(lots>mx) lots = mx;
   return(NormalizeDouble(lots,2));
  }

//+------------------------------------------------------------------+
double CalcLots(const double stopDistance)
  {
   if(InpRiskPercent<=0.0) return(NormalizeLots(InpFixedLots));
   if(stopDistance<=0.0)   return(NormalizeLots(InpFixedLots));

   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE)*InpRiskPercent/100.0;
   double tickVal   = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tickVal<=0.0 || tickSize<=0.0) return(NormalizeLots(InpFixedLots));

   double lossPerLot = stopDistance/tickSize*tickVal;
   if(lossPerLot<=0.0) return(NormalizeLots(InpFixedLots));

   double lots = riskMoney/lossPerLot;
   lots = NormalizeLots(lots);

   //--- margin sanity check
   double margin=0.0;
   if(OrderCalcMargin(ORDER_TYPE_BUY,_Symbol,lots,DbgAsk(_Symbol),margin))
     {
      double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      while(lots>SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN) && margin>freeMargin*0.5)
        {
         lots = NormalizeLots(lots-SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP));
         if(!OrderCalcMargin(ORDER_TYPE_BUY,_Symbol,lots,DbgAsk(_Symbol),margin)) break;
        }
     }
   return(lots);
  }

//+------------------------------------------------------------------+
//| Stop loss calculation for a planned entry                        |
//+------------------------------------------------------------------+
double CalcStopLoss(const int dir,const double entry)
  {
   double buf   = BreakBuffer();
   double sl    = 0.0;

   if(InpSlMode==DBG_SL_RANGE)
      sl = (dir>0 ? g_rangeLow-buf : g_rangeHigh+buf);
   else if(InpSlMode==DBG_SL_ATR)
      sl = (dir>0 ? entry-InpAtrSlMult*g_atr : entry+InpAtrSlMult*g_atr);
   else
     {
      double anchor = g_pullExtreme;
      if(anchor<=0.0) anchor = (dir>0 ? g_rangeLow : g_rangeHigh);
      sl = (dir>0 ? anchor-buf : anchor+buf);
     }

   //--- clamp distance
   double dist    = MathAbs(entry-sl);
   double minDist = MathMax(InpMinStopAtr*g_atr,DbgStopsLevelPrice(_Symbol)+ (DbgAsk(_Symbol)-DbgBid(_Symbol)));
   double maxDist = InpMaxStopAtr*g_atr;
   if(maxDist>0.0 && dist>maxDist) dist = maxDist;
   if(dist<minDist) dist = minDist;

   sl = (dir>0 ? entry-dist : entry+dist);
   return(DbgNormPrice(_Symbol,sl));
  }

//+------------------------------------------------------------------+
//| Entry                                                            |
//+------------------------------------------------------------------+
bool PlaceTrigger(const int dir,const double triggerPrice)
  {
   double entry = DbgNormPrice(_Symbol,triggerPrice);
   double sl    = CalcStopLoss(dir,entry);
   double risk  = MathAbs(entry-sl);
   if(risk<=0.0) return(false);

   double tp = 0.0;
   if(InpTp2R>0.0) tp = DbgNormPrice(_Symbol,(dir>0 ? entry+InpTp2R*risk : entry-InpTp2R*risk));

   double lots = CalcLots(risk);
   if(lots<=0.0) { Log("Lot calculation failed"); return(false); }

   bool ok=false;
   if(InpEntryType==DBG_ENTRY_STOP)
     {
      double dist = MathAbs((dir>0 ? DbgAsk(_Symbol) : DbgBid(_Symbol))-entry);
      double need = DbgStopsLevelPrice(_Symbol);
      if(dist<=need)
        {
         //--- market already at/through the level -> take it at market
         ok = (dir>0 ? trade.Buy(lots,_Symbol,0.0,sl,tp,InpComment)
                     : trade.Sell(lots,_Symbol,0.0,sl,tp,InpComment));
        }
      else
        {
         ok = (dir>0 ? trade.BuyStop(lots,entry,_Symbol,sl,tp,ORDER_TIME_GTC,0,InpComment)
                     : trade.SellStop(lots,entry,_Symbol,sl,tp,ORDER_TIME_GTC,0,InpComment));
         if(ok)
           {
            g_pendingTicket = trade.ResultOrder();
            g_pendingExpiry = TimeTradeServer()+(datetime)(InpTriggerExpiryMin*60);
           }
        }
     }
   else
     {
      ok = (dir>0 ? trade.Buy(lots,_Symbol,0.0,sl,tp,InpComment)
                  : trade.Sell(lots,_Symbol,0.0,sl,tp,InpComment));
     }

   if(!ok)
     {
      Log(StringFormat("Order failed: %d %s",trade.ResultRetcode(),trade.ResultRetcodeDescription()));
      return(false);
     }

   g_posRisk = risk;
   g_beDone  = false;
   g_tp1Done = false;
   g_trigger = entry;
   g_phase   = DBG_PH_TRIGGER;
   Log(StringFormat("%s trigger armed @ %s  SL %s  TP %s  lots %.2f  (1R=%.2f)",
                    (dir>0 ? "LONG" : "SHORT"),DbgPriceStr(_Symbol,entry),
                    DbgPriceStr(_Symbol,sl),DbgPriceStr(_Symbol,tp),lots,risk));
   return(true);
  }

//+------------------------------------------------------------------+
//| Trade permission checks                                          |
//+------------------------------------------------------------------+
bool TradingAllowed(string &reason)
  {
   reason = "";
   if(g_paused)                                   { reason="manually paused";        return(false); }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))         { reason="algo trading disabled";  return(false); }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)){reason="terminal trade blocked"; return(false); }
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))  { reason="account: EA not allowed";return(false); }
   if(g_halted)                                   { reason=g_haltReason;             return(false); }
   if(!IsTradingDay())                            { reason="day disabled";           return(false); }
   if(g_tradesToday>=InpMaxTradesPerDay && InpMaxTradesPerDay>0) { reason="max trades/day"; return(false); }
   if(InpMaxConsecLosses>0 && g_consecLoss>=InpMaxConsecLosses)  { reason="loss streak";    return(false); }
   if(InpMaxSpreadPoints>0 && DbgSpreadPoints(_Symbol)>InpMaxSpreadPoints)
     { reason=StringFormat("spread %.0f > %.0f",DbgSpreadPoints(_Symbol),InpMaxSpreadPoints); return(false); }
   return(true);
  }

//+------------------------------------------------------------------+
//| Daily statistics from deal history                               |
//+------------------------------------------------------------------+
void UpdateDailyStats(void)
  {
   datetime now = TimeTradeServer();
   datetime day = now-(datetime)(now%86400);
   if(g_statDay!=day)
     {
      g_statDay         = day;
      g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_tradesToday     = 0;
      g_winsToday       = 0;
      g_lossesToday     = 0;
      g_dayPnl          = 0.0;
      g_halted          = false;
      g_haltReason      = "";
     }

   if(!HistorySelect(day,now+60)) return;

   int trades=0,wins=0,losses=0,streak=0;
   double pnl=0.0;
   int total = HistoryDealsTotal();
   for(int i=0;i<total;i++)
     {
      ulong dl = HistoryDealGetTicket(i);
      if(dl==0) continue;
      if(HistoryDealGetString(dl,DEAL_SYMBOL)!=_Symbol) continue;
      if(HistoryDealGetInteger(dl,DEAL_MAGIC)!=InpMagic) continue;
      long entry = HistoryDealGetInteger(dl,DEAL_ENTRY);
      if(entry!=DEAL_ENTRY_OUT && entry!=DEAL_ENTRY_OUT_BY) continue;

      double p = HistoryDealGetDouble(dl,DEAL_PROFIT)
                 +HistoryDealGetDouble(dl,DEAL_SWAP)
                 +HistoryDealGetDouble(dl,DEAL_COMMISSION);
      pnl += p;
      trades++;
      if(p>0)      { wins++;   streak=0; }
      else if(p<0) { losses++; streak++; }
     }

   g_tradesToday = trades;
   g_winsToday   = wins;
   g_lossesToday = losses;
   g_consecLoss  = streak;
   g_dayPnl      = pnl;

   //--- guards
   if(g_dayStartBalance>0.0)
     {
      double pct = g_dayPnl/g_dayStartBalance*100.0;
      if(InpDailyLossPct>0.0 && pct<=-InpDailyLossPct && !g_halted)
        { g_halted=true; g_haltReason=StringFormat("daily loss limit %.2f%%",pct); Log("HALT: "+g_haltReason); }
      if(InpDailyProfitPct>0.0 && pct>=InpDailyProfitPct && !g_halted)
        { g_halted=true; g_haltReason=StringFormat("daily profit target %.2f%%",pct); Log("HALT: "+g_haltReason); }
     }
  }

//+------------------------------------------------------------------+
//| Open position management: partial, BE, trailing                  |
//+------------------------------------------------------------------+
void ManagePosition(void)
  {
   if(!FindPosition()) { g_tp1Done=false; g_beDone=false; return; }
   if(!PositionSelectByTicket(g_posTicket)) return;

   double entry  = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl     = PositionGetDouble(POSITION_SL);
   double tp     = PositionGetDouble(POSITION_TP);
   double vol    = PositionGetDouble(POSITION_VOLUME);
   int    dir    = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY ? 1 : -1);
   double price  = (dir>0 ? DbgBid(_Symbol) : DbgAsk(_Symbol));

   //--- reconstruct 1R if the EA was restarted
   if(g_posRisk<=0.0 && sl>0.0) g_posRisk = MathAbs(entry-sl);
   if(g_posRisk<=0.0) return;

   double rNow = (dir>0 ? (price-entry) : (entry-price))/g_posRisk;

   //--- 1) partial take profit
   if(InpTp1R>0.0 && !g_tp1Done && rNow>=InpTp1R && InpTp1ClosePct>0.0 && InpTp1ClosePct<100.0)
     {
      double closeVol = NormalizeLots(vol*InpTp1ClosePct/100.0);
      double minVol   = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
      if(closeVol>=minVol && (vol-closeVol)>=minVol)
        {
         if(trade.PositionClosePartial(g_posTicket,closeVol,InpSlippage))
           { g_tp1Done=true; Log(StringFormat("TP1 hit (%.2fR) - closed %.2f lots",rNow,closeVol)); }
        }
      else g_tp1Done = true;
     }

   //--- 2) breakeven
   if(InpUseBreakeven && !g_beDone && rNow>=InpBeTriggerR)
     {
      double newSl = DbgNormPrice(_Symbol,(dir>0 ? entry+InpBeLockR*g_posRisk : entry-InpBeLockR*g_posRisk));
      bool better  = (dir>0 ? (sl<=0.0 || newSl>sl) : (sl<=0.0 || newSl<sl));
      double minD  = DbgStopsLevelPrice(_Symbol);
      bool valid   = (dir>0 ? (price-newSl)>minD : (newSl-price)>minD);
      if(better && valid && trade.PositionModify(g_posTicket,newSl,tp))
        { g_beDone=true; sl=newSl; Log(StringFormat("Breakeven set @ %s (%.2fR)",DbgPriceStr(_Symbol,newSl),rNow)); }
     }

   //--- 3) ATR trailing
   if(InpUseTrailing && rNow>=InpTrailStartR && g_atr>0.0)
     {
      double newSl = DbgNormPrice(_Symbol,(dir>0 ? price-InpTrailAtrMult*g_atr : price+InpTrailAtrMult*g_atr));
      bool better  = (dir>0 ? (sl<=0.0 || newSl>sl+DbgPoint(_Symbol)) : (sl<=0.0 || newSl<sl-DbgPoint(_Symbol)));
      double minD  = DbgStopsLevelPrice(_Symbol);
      bool valid   = (dir>0 ? (price-newSl)>minD : (newSl-price)>minD);
      if(better && valid)
         trade.PositionModify(g_posTicket,newSl,tp);
     }
  }

//+------------------------------------------------------------------+
//| Signal engine - executed once per closed bar                     |
//+------------------------------------------------------------------+
void ProcessBar(void)
  {
   MqlRates b[];
   ArraySetAsSeries(b,true);
   if(CopyRates(_Symbol,InpSignalTF,0,4,b)<3) return;

   double cl   = b[1].close;
   double hi   = b[1].high;
   double lo   = b[1].low;
   double op   = b[1].open;
   double rng  = hi-lo;
   double body = MathAbs(cl-op);
   double buf  = BreakBuffer();
   datetime bt = b[1].time;

   //--- still inside the range window
   if(TimeTradeServer()<g_rangeEndSrv) { g_phase = DBG_PH_BUILDING; return; }

   //--- build the range once
   if(!g_rangeReady)
     {
      if(!BuildRange()) return;
      g_phase = (g_rangeValid ? DBG_PH_ARMED : DBG_PH_BLOCKED);
     }
   if(!g_rangeValid) { g_phase = DBG_PH_BLOCKED; return; }

   //--- position open -> nothing to search for
   if(FindPosition()) { g_phase = DBG_PH_INTRADE; return; }

   //--- outside the entry window
   if(TimeTradeServer()>=g_tradeEndSrv)
     {
      if(g_phase!=DBG_PH_INTRADE) g_phase = DBG_PH_DONE;
      if(CountPending()>0) DeletePending("entry window closed");
      return;
     }

   string reason="";
   bool allowed = TradingAllowed(reason);

   //--- news lock
   DbgNewsEvent nev; int resume=0;
   bool newsLock = News.IsBlocked(TimeTradeServer(),nev,resume);
   if(newsLock)
     {
      if(InpNewsDeletePending && CountPending()>0) DeletePending("news lock");
      return;
     }
   if(!allowed) return;

   //--- if a trigger order is live: only validate it
   if(CountPending()>0)
     {
      //--- expiry
      if(g_pendingExpiry>0 && TimeTradeServer()>g_pendingExpiry)
        { DeletePending("trigger expired"); ResetSetup(); g_phase=DBG_PH_ARMED; return; }
      //--- invalidation: price fell back inside the range (skip if state was lost on restart)
      if(g_dir!=0)
        {
         bool dead = (g_dir>0 ? cl<g_rangeHigh-buf : cl>g_rangeLow+buf);
         if(dead)
           { DeletePending("setup invalidated (back inside range)"); ResetSetup(); g_phase=DBG_PH_ARMED; }
        }
      return;
     }

   //--- setup budget for this session exhausted
   if(InpMaxSetupsPerDay>0 && g_setups>=InpMaxSetupsPerDay &&
      (g_phase==DBG_PH_ARMED || g_phase==DBG_PH_DONE || g_phase==DBG_PH_TRIGGER)) return;

   //------------------------------------------------------------------
   // PHASE: ARMED -> look for the FIRST breakout
   //------------------------------------------------------------------
   if(g_phase==DBG_PH_ARMED || g_phase==DBG_PH_DONE)
     {
      int dir = 0;
      if(cl>g_rangeHigh+buf)      dir = 1;
      else if(cl<g_rangeLow-buf)  dir = -1;
      if(dir==0) return;

      //--- candle quality filter
      if(InpMinBodyRatio>0.0 && rng>0.0 && (body/rng)<InpMinBodyRatio) return;

      //--- trend filter
      if(InpUseTrendFilter && g_trendMa>0.0)
        {
         if(dir>0 && cl<g_trendMa) return;
         if(dir<0 && cl>g_trendMa) return;
        }

      g_dir         = dir;
      g_b1Level     = (dir>0 ? g_rangeHigh : g_rangeLow);
      g_b1Peak      = (dir>0 ? hi : lo);
      g_pullExtreme = (dir>0 ? lo : hi);
      g_pullbackOk  = false;
      g_b1Time      = bt;
      g_setups++;
      g_phase       = DBG_PH_BREAK1;
      Log(StringFormat("BREAK-1 %s  level %s  leg extreme %s  (setup %d/%d)",
                       (dir>0 ? "UP" : "DOWN"),DbgPriceStr(_Symbol,g_b1Level),
                       DbgPriceStr(_Symbol,g_b1Peak),g_setups,InpMaxSetupsPerDay));

      //--- TWO-LEVEL mode can trigger without a pullback
      if(InpMode==DBG_MODE_TWOLEVEL)
        {
         double lvl2 = (dir>0 ? g_pdh : g_pdl);
         if(lvl2>0.0)
           {
            double trig = (dir>0 ? MathMax(g_b1Peak,lvl2)+buf : MathMin(g_b1Peak,lvl2)-buf);
            PlaceTrigger(dir,trig);
           }
        }
      return;
     }

   //------------------------------------------------------------------
   // PHASE: BREAK1 -> wait for the pullback
   //------------------------------------------------------------------
   if(g_phase==DBG_PH_BREAK1 || g_phase==DBG_PH_PULLBACK)
     {
      if(g_dir>0)
        {
         if(hi>g_b1Peak) { g_b1Peak=hi; g_pullExtreme=lo; }
         else            { g_pullExtreme = MathMin(g_pullExtreme,lo); }
        }
      else
        {
         if(lo<g_b1Peak) { g_b1Peak=lo; g_pullExtreme=hi; }
         else            { g_pullExtreme = MathMax(g_pullExtreme,hi); }
        }

      double leg = MathAbs(g_b1Peak-g_b1Level);
      if(leg<=0.0) return;
      double retr = (g_dir>0 ? (g_b1Peak-g_pullExtreme) : (g_pullExtreme-g_b1Peak))/leg*100.0;

      //--- failed breakout
      bool failed = (retr>InpMaxPullbackPct) ||
                    (g_dir>0 ? cl<g_rangeHigh-buf : cl>g_rangeLow+buf);
      if(failed)
        {
         Log(StringFormat("Setup invalidated (pullback %.0f%% > %.0f%%)",retr,InpMaxPullbackPct));
         ResetSetup();
         g_phase = DBG_PH_ARMED;
         return;
        }

      if(retr>=InpMinPullbackPct)
        {
         g_pullbackOk = true;
         g_phase      = DBG_PH_PULLBACK;
         double trig  = (g_dir>0 ? g_b1Peak+buf : g_b1Peak-buf);

         //--- BOTH mode: the trigger must also clear PDH/PDL
         if(InpMode==DBG_MODE_BOTH)
           {
            double lvl2 = (g_dir>0 ? g_pdh : g_pdl);
            if(lvl2>0.0) trig = (g_dir>0 ? MathMax(trig,lvl2+buf) : MathMin(trig,lvl2-buf));
           }

         if(InpEntryType==DBG_ENTRY_STOP)
            PlaceTrigger(g_dir,trig);
         else
           {
            g_trigger = trig;
            //--- market entry on a close beyond the trigger
            if((g_dir>0 && cl>trig) || (g_dir<0 && cl<trig))
               PlaceTrigger(g_dir,(g_dir>0 ? DbgAsk(_Symbol) : DbgBid(_Symbol)));
           }
        }
      return;
     }
  }

//+------------------------------------------------------------------+
//| End-of-day / news exits                                          |
//+------------------------------------------------------------------+
void HandleExits(void)
  {
   datetime now = TimeTradeServer();

   //--- session flatten (paper rule: no overnight risk)
   if(InpUseEodExit && now>=g_flattenSrv)
     {
      if(FindPosition()) CloseAllPositions("session end (EoD exit)");
      if(CountPending()>0) DeletePending("session end");
      g_phase = DBG_PH_DONE;
      return;
     }

   //--- friday flatten
   if(InpFridayCloseHour>0)
     {
      MqlDateTime g; TimeToStruct(TZ.GmtNow(),g);
      if(g.day_of_week==5 && g.hour>=InpFridayCloseHour)
        {
         if(FindPosition()) CloseAllPositions("friday close");
         if(CountPending()>0) DeletePending("friday close");
         return;
        }
     }

   //--- pre-news protection
   if(InpNewsEnabled && InpNewsClosePositions)
     {
      DbgNewsEvent ev;
      if(News.EventWithin(now,InpNewsCloseBeforeMin*60,ev))
        {
         if(FindPosition())
            CloseAllPositions(StringFormat("news in %d min: %s %s",InpNewsCloseBeforeMin,ev.currency,ev.name));
         if(InpNewsDeletePending && CountPending()>0) DeletePending("pre-news");
        }
     }
  }

//+------------------------------------------------------------------+
//| Chart levels                                                     |
//+------------------------------------------------------------------+
void DrawLevel(const string tag,const double price,const color clr,const int style,const string text)
  {
   if(price<=0.0) { ObjectDelete(0,LVL_PREFIX+tag); return; }
   string nm = LVL_PREFIX+tag;
   if(ObjectFind(0,nm)<0) ObjectCreate(0,nm,OBJ_HLINE,0,0,price);
   ObjectSetDouble(0,nm,OBJPROP_PRICE,price);
   ObjectSetInteger(0,nm,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,nm,OBJPROP_STYLE,style);
   ObjectSetInteger(0,nm,OBJPROP_WIDTH,1);
   ObjectSetInteger(0,nm,OBJPROP_BACK,true);
   ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,nm,OBJPROP_HIDDEN,true);
   ObjectSetString(0,nm,OBJPROP_TOOLTIP,text);
   ObjectSetString(0,nm,OBJPROP_TEXT,text);
  }

void DrawLevels(void)
  {
   if(!InpShowLevels) return;
   if(g_rangeReady)
     {
      DrawLevel("rh",g_rangeHigh,C'220,180,60',STYLE_SOLID,"Range High");
      DrawLevel("rl",g_rangeLow, C'220,180,60',STYLE_SOLID,"Range Low");
     }
   DrawLevel("b1",((int)g_phase>=(int)DBG_PH_BREAK1 ? g_b1Peak : 0.0),C'90,170,255',STYLE_DOT,"Breakout leg extreme");
   DrawLevel("tg",((g_trigger>0.0 && (int)g_phase>=(int)DBG_PH_PULLBACK) ? g_trigger : 0.0),C'100,220,130',STYLE_DASH,"2nd breakout trigger");
  }

//+------------------------------------------------------------------+
//| Dashboard refresh                                                |
//+------------------------------------------------------------------+
string PhaseText(color &clr)
  {
   switch(g_phase)
     {
      case DBG_PH_PRERANGE: clr=C'150,160,175'; return("WAITING FOR RANGE WINDOW");
      case DBG_PH_BUILDING: clr=C'90,170,255';  return("BUILDING RANGE ("+DbgHM(ServerToCfg(g_rangeEndSrv))+" end)");
      case DBG_PH_ARMED:    clr=C'120,210,140'; return("ARMED - hunting 1st breakout");
      case DBG_PH_BREAK1:   clr=C'240,200,90';  return(StringFormat("BREAK-1 %s - waiting pullback",(g_dir>0?"LONG":"SHORT")));
      case DBG_PH_PULLBACK: clr=C'240,160,70';  return(StringFormat("PULLBACK OK - waiting RE-BREAK (%s)",(g_dir>0?"LONG":"SHORT")));
      case DBG_PH_TRIGGER:  clr=C'110,220,255'; return(StringFormat("TRIGGER LIVE %s",(g_dir>0?"BUY STOP":"SELL STOP")));
      case DBG_PH_INTRADE:  clr=C'120,230,150'; return("IN TRADE");
      case DBG_PH_DONE:     clr=C'150,160,175'; return("SESSION FINISHED");
      case DBG_PH_BLOCKED:  clr=C'230,120,120'; return("RANGE REJECTED - "+g_rangeReject);
     }
   clr=C'200,200,200';
   return("-");
  }

void UpdatePanel(void)
  {
   if(!InpShowPanel || !Panel.Created()) return;

   DbgPanelData d;

   //--- clock
   datetime srv = TimeTradeServer();
   d.srvTime   = DbgFull(srv);
   d.tzLabel   = TZ.ZoneLabel()+" | "+TZ.ZoneGuess();
   d.gmtTime   = DbgFull(TZ.GmtNow());
   d.localTime = DbgFull(TimeLocal());
   d.cityTimes = TZ.CityLine();
   d.sessionLine = TZ.SessionLine()+"   | range "+DbgHM(ServerToCfg(g_rangeStartSrv))+"-"+DbgHM(ServerToCfg(g_rangeEndSrv))
                   +" | entries till "+DbgHM(ServerToCfg(g_tradeEndSrv))
                   +(InpTimeBase==DBG_TB_GMT ? " GMT" : " srv");

   //--- market
   d.symTf      = _Symbol+"  "+StringSubstr(EnumToString(InpSignalTF),7);
   double spr   = DbgSpreadPoints(_Symbol);
   d.quoteLine  = StringFormat("%s / %s   spread %.0f pts",DbgPriceStr(_Symbol,DbgBid(_Symbol)),
                               DbgPriceStr(_Symbol,DbgAsk(_Symbol)),spr);
   d.quoteColor = (InpMaxSpreadPoints>0 && spr>InpMaxSpreadPoints ? C'240,120,120' : C'225,230,238');
   string tfTxt = StringSubstr(EnumToString(InpSignalTF),7);
   d.atrLine    = StringFormat("ATR(%s) %.2f | ATR(D1) %.2f | RVOL %.2f",tfTxt,g_atr,g_atrD1,g_rvol);

   //--- strategy
   color pc; d.phaseText = PhaseText(pc); d.phaseColor = pc;
   if(g_rangeReady)
      d.rangeLine = StringFormat("H %s  L %s  (%.2f = %.0f%% D-ATR)",DbgPriceStr(_Symbol,g_rangeHigh),
                                 DbgPriceStr(_Symbol,g_rangeLow),g_rangeSize,
                                 (g_atrD1>0 ? g_rangeSize/g_atrD1*100.0 : 0.0));
   else
      d.rangeLine = "building...";

   if(g_trigger>0.0 && (int)g_phase>=(int)DBG_PH_PULLBACK && (int)g_phase<=(int)DBG_PH_TRIGGER)
     {
      string exp = (g_pendingExpiry>0 ? "  exp "+DbgHM(ServerToCfg(g_pendingExpiry)) : "");
      d.triggerLine = DbgPriceStr(_Symbol,g_trigger)+exp+"   setups "+IntegerToString(g_setups)+"/"+IntegerToString(InpMaxSetupsPerDay);
     }
   else
      d.triggerLine = StringFormat("- (setups %d/%d, PDH %s / PDL %s)",g_setups,InpMaxSetupsPerDay,
                                   DbgPriceStr(_Symbol,g_pdh),DbgPriceStr(_Symbol,g_pdl));

   if(FindPosition() && PositionSelectByTicket(g_posTicket))
     {
      double vol   = PositionGetDouble(POSITION_VOLUME);
      double pnl   = PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double price = (g_posDir>0 ? DbgBid(_Symbol) : DbgAsk(_Symbol));
      double rNow  = (g_posRisk>0.0 ? (g_posDir>0 ? price-entry : entry-price)/g_posRisk : 0.0);
      d.posLine    = StringFormat("%s %.2f @ %s  %.2fR  (%s)",(g_posDir>0?"LONG":"SHORT"),vol,
                                  DbgPriceStr(_Symbol,entry),rNow,DbgMoney(pnl));
      d.posColor   = (pnl>=0 ? C'120,230,150' : C'240,130,130');
      d.slTpLine   = StringFormat("%s / %s   %s %s",
                                  DbgPriceStr(_Symbol,PositionGetDouble(POSITION_SL)),
                                  DbgPriceStr(_Symbol,PositionGetDouble(POSITION_TP)),
                                  (g_beDone ? "[BE]" : ""),(g_tp1Done ? "[TP1 done]" : ""));
     }
   else
     {
      d.posLine  = (CountPending()>0 ? "pending trigger order live" : "flat");
      d.posColor = C'170,180,195';
      d.slTpLine = StringFormat("SL %s | TP1 %.1fR (%.0f%%) | TP2 %.1fR",
                                SlModeText(),InpTp1R,InpTp1ClosePct,InpTp2R);
     }

   //--- news
   DbgNewsEvent ev; int resume=0, toEv=0;
   if(!InpNewsEnabled)
     { d.newsStatus="DISABLED"; d.newsColor=C'150,160,175'; }
   else if(News.IsBlocked(TimeTradeServer(),ev,resume))
     {
      d.newsStatus = StringFormat("LOCKED - %s %s | resume in %s",ev.currency,CDbgNews::ImpText(ev.importance),DbgDuration(resume));
      d.newsColor  = C'250,110,110';
     }
   else
     {
      d.newsStatus = "CLEAR - trading allowed";
      d.newsColor  = C'120,230,150';
     }

   if(News.NextEvent(TimeTradeServer(),ev,toEv))
      d.nextNews = StringFormat("%s %s %s  %s (in %s)",DbgHM(ev.time),ev.currency,
                                CDbgNews::ImpText(ev.importance),
                                StringSubstr(ev.name,0,26),DbgDuration(toEv));
   else
      d.nextNews = (News.Total()>0 ? "none left today" : "no data ("+News.LastError()+")");

   d.newsWindow = StringFormat("-%d min / +%d min | %s | %s impact | %d events",
                               InpNewsMinsBefore,InpNewsMinsAfter,News.CurrencyText(),
                               NewsImpText(),News.Total());

   //--- risk
   d.balLine = StringFormat("Bal %s | Eq %s | Mgn free %s",
                            DbgMoney(AccountInfoDouble(ACCOUNT_BALANCE)),
                            DbgMoney(AccountInfoDouble(ACCOUNT_EQUITY)),
                            DbgMoney(AccountInfoDouble(ACCOUNT_MARGIN_FREE)));
   double dayPct = (g_dayStartBalance>0.0 ? g_dayPnl/g_dayStartBalance*100.0 : 0.0);
   d.dayLine = StringFormat("%s (%.2f%%) | %d trades  %dW/%dL",DbgMoney(g_dayPnl),dayPct,
                            g_tradesToday,g_winsToday,g_lossesToday);
   d.dayColor = (g_dayPnl>0 ? C'120,230,150' : (g_dayPnl<0 ? C'240,130,130' : C'225,230,238'));

   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE)*InpRiskPercent/100.0;
   d.riskLine = (InpRiskPercent>0.0
                 ? StringFormat("%.2f%%  ~ %s per trade",InpRiskPercent,DbgMoney(riskMoney))
                 : StringFormat("fixed %.2f lots",InpFixedLots));
   d.guardLine = StringFormat("trades %d/%d | streak %d/%d | DD limit %.1f%%",
                              g_tradesToday,InpMaxTradesPerDay,g_consecLoss,InpMaxConsecLosses,InpDailyLossPct);

   //--- footer
   string reason="";
   if(g_paused)                       { d.statusText="PAUSED (manual)";       d.statusColor=C'240,200,90'; }
   else if(!TradingAllowed(reason))   { d.statusText="STANDBY: "+reason;      d.statusColor=C'240,160,90'; }
   else                               { d.statusText="ACTIVE - "+(StringLen(g_lastMsg)>0 ? g_lastMsg : "monitoring"); d.statusColor=C'120,230,150'; }

   Panel.Update(d);
  }

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit(void)
  {
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);
   trade.LogLevel(LOG_LEVEL_ERRORS);

   hAtrSig = iATR(_Symbol,InpSignalTF,14);
   hAtrD1  = iATR(_Symbol,PERIOD_D1,14);
   if(hAtrSig==INVALID_HANDLE || hAtrD1==INVALID_HANDLE)
     { Print("[DBG] ATR handle error"); return(INIT_FAILED); }
   if(InpUseTrendFilter)
     {
      hTrendMa = iMA(_Symbol,InpTrendTF,InpTrendMaPeriod,0,MODE_EMA,PRICE_CLOSE);
      if(hTrendMa==INVALID_HANDLE) return(INIT_FAILED);
     }

   TZ.Init(_Symbol,InpManualOffsetHours,InpManualOffset);

   News.Configure(InpNewsEnabled,InpNewsCurrencies,_Symbol,InpNewsImportance,
                  InpNewsMinsBefore,InpNewsMinsAfter,InpNewsUseCsv,InpNewsCsvFile,
                  InpNewsCsvCommon,InpNewsReloadMinutes,InpNewsShiftMinutes);
   News.Refresh(true);

   if(InpShowPanel)
     {
      Panel.Create(0,(int)InpPanelCorner,InpPanelX,InpPanelY,InpPanelWidth,InpPanelFontSize,InpPanelFont);
      Panel.SetPaused(g_paused);
     }

   g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   EventSetTimer(1);

   ComputeSessionWindow();
   UpdateIndicators();
   UpdateDailyStats();

   Log(StringFormat("Init OK | broker %s | range %s-%s %s | news %s (-%d/+%d min)",
                    TZ.ZoneLabel(),InpRangeStart,InpRangeEnd,
                    (InpTimeBase==DBG_TB_GMT ? "GMT" : "server"),
                    (InpNewsEnabled ? "ON" : "OFF"),InpNewsMinsBefore,InpNewsMinsAfter));
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(hAtrSig!=INVALID_HANDLE)  IndicatorRelease(hAtrSig);
   if(hAtrD1!=INVALID_HANDLE)   IndicatorRelease(hAtrD1);
   if(hTrendMa!=INVALID_HANDLE) IndicatorRelease(hTrendMa);
   Panel.Destroy();
   ObjectsDeleteAll(0,LVL_PREFIX);
   Comment("");
  }

//+------------------------------------------------------------------+
void OnTick(void)
  {
   if(!UpdateIndicators()) return;

   ComputeSessionWindow();
   UpdateDailyStats();

   //--- refresh calendar in the background
   News.Refresh(false);

   //--- exits are always processed, even when paused
   ManagePosition();
   HandleExits();

   //--- new bar -> signal engine
   datetime bt = (datetime)SeriesInfoInteger(_Symbol,InpSignalTF,SERIES_LASTBAR_DATE);
   if(bt!=g_lastBarTime)
     {
      g_lastBarTime = bt;
      if(!g_paused) ProcessBar();
      DrawLevels();
     }

   //--- intrabar: fill detection
   if(FindPosition() && g_phase!=DBG_PH_INTRADE)
     {
      g_phase = DBG_PH_INTRADE;
      if(g_posRisk<=0.0 && PositionSelectByTicket(g_posTicket))
         g_posRisk = MathAbs(PositionGetDouble(POSITION_PRICE_OPEN)-PositionGetDouble(POSITION_SL));
      Log("Trigger filled -> position live");
     }
   else if(!FindPosition() && g_phase==DBG_PH_INTRADE && CountPending()==0)
     {
      //--- trade finished: allow a new setup if budget remains
      ResetSetup();
      g_phase = (InpMaxSetupsPerDay>0 && g_setups>=InpMaxSetupsPerDay ? DBG_PH_DONE : DBG_PH_ARMED);
      g_posRisk = 0.0;
     }

   UpdatePanel();
  }

//+------------------------------------------------------------------+
void OnTimer(void)
  {
   TZ.Refresh(false);
   UpdatePanel();
  }

//+------------------------------------------------------------------+
void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
  {
   if(id!=CHARTEVENT_OBJECT_CLICK) return;

   if(sparam==DBG_BTN_PAUSE)
     {
      g_paused = !g_paused;
      Panel.SetPaused(g_paused);
      Log(g_paused ? "EA PAUSED by user" : "EA RESUMED by user");
      if(g_paused && CountPending()>0) DeletePending("user pause");
      UpdatePanel();
     }
   else if(sparam==DBG_BTN_CLOSE)
     {
      ObjectSetInteger(0,DBG_BTN_CLOSE,OBJPROP_STATE,false);
      CloseAllPositions("manual button");
      DeletePending("manual button");
      UpdatePanel();
     }
   else if(sparam==DBG_BTN_MIN)
     {
      Panel.ToggleMinimize();
     }
  }
//+------------------------------------------------------------------+
