//+------------------------------------------------------------------+
//|                                                OrderFlowGoldV2.mq5 |
//|     ORDER FLOW GOLD v2  -  XAUUSD / M5  (research-hardened)       |
//|                                                                   |
//|  v2 upgrades over v1, each tied to a specific paper:              |
//|                                                                   |
//|  1. DIURNAL-NORMALISED FLOW                                        |
//|     Delta z-scores are computed per 5-min time-of-day bucket, not |
//|     pooled, because order-flow / impact is strongly U-shaped      |
//|     intraday (Cont-Kukanov-Stoikov 2014; Bacry et al. 2015 Hawkes |
//|     baseline intensity; Rambaldi et al.). Removes the time-of-day |
//|     bias that made a pooled z fire mostly at the London/NY open.  |
//|                                                                   |
//|  2. MULTI-HORIZON INTEGRATED OFI                                   |
//|     1/3/6-bar OFI combined (Cont, Cucuringu & Zhang 2021 cross-   |
//|     impact; Xu-Gould-Howison multi-level OFI; Kolm et al. deep    |
//|     OFI) + a horizon-agreement filter.                            |
//|                                                                   |
//|  3. VPIN TOXICITY GATE (volume clock)                             |
//|     Easley, Lopez de Prado & O'Hara (2012). High VPIN = toxic,    |
//|     one-sided flow -> do NOT fade it, prefer continuation; very   |
//|     high VPIN -> stand aside (flash-crash risk).  Tick-rule       |
//|     signing per Andersen & Bondarenko (2014).                     |
//|                                                                   |
//|  4. MICRO-PRICE FAIR VALUE (Stoikov 2018)                         |
//|     Rolling tick-imbalance micro-offset confirms entry direction  |
//|     against the current book lean.                                |
//|                                                                   |
//|  5. VOLATILITY REGIME SWITCH (HMM-style, ATR percentile)          |
//|     Zhang et al. 2020 regime-HAR; regime-switching vol lit.       |
//|     CALM -> mean-revert (fade); TREND -> continuation; STORM ->   |
//|     stand aside. Parameters adapt per regime.                     |
//|                                                                   |
//|  6. REVERSAL-AFTER-EXTREME + IBS                                   |
//|     Intraday overreaction reverts (Ledger 2021 BTC; Pacific-Basin |
//|     2024 commodity intraday reversal; Pagonidis IBS effect).      |
//|     Fade uses IBS extremes + new-extreme + absorption.            |
//|                                                                   |
//|  7. META-SCORE + EXPECTANCY-AWARE SIZING                           |
//|     Lopez de Prado meta-labeling / bet sizing: a secondary score  |
//|     (0..1) gates AND sizes each trade. Fractional-Kelly cap       |
//|     (MacLean-Thorp-Ziemba; quarter-Kelly) from the live win-rate/ |
//|     payoff, floored/capped so a bad estimate can't blow up.       |
//|                                                                   |
//|  8. R:R / TARGET MATH                                              |
//|     Profit-target between 1.5R and 3.5R is the robust band; >=4R  |
//|     hurts hit rate (IJACSA transformer day-trading study). Tiered |
//|     TP1 small + runner keeps a high hit rate while still catching |
//|     the extended move. Costs modelled (spread cap vs ATR).        |
//|                                                                   |
//|  Plus everything from v1: broker TZ/DST detection, MT5 calendar   |
//|  news filter (off 30m before / on 30m after), full dashboard.     |
//+------------------------------------------------------------------+
#property copyright "Order Flow Gold EA v2"
#property link      "https://papers.ssrn.com/sol3/papers.cfm?abstract_id=1712822"
#property version   "2.00"
#property description "Order-flow gold scalper v2: diurnal flow, VPIN, micro-price, regime switch, meta-score sizing, news filter, dashboard."

#include <Trade/Trade.mqh>

#include "../DoubleBreakoutGold/DBG_Utils.mqh"
#include "../DoubleBreakoutGold/DBG_TimeZone.mqh"
#include "../DoubleBreakoutGold/DBG_News.mqh"
#include "OFG2_Flow.mqh"
#include "OFG2_Panel.mqh"

//+------------------------------------------------------------------+
enum ENUM_OFG2_ENGINE
  {
   OFG2_ENG_AUTO = 0, // Auto per regime (fade in CALM, flow in TREND)
   OFG2_ENG_BOTH = 1, // Both always
   OFG2_ENG_FADE = 2, // Absorption / reversal fade only
   OFG2_ENG_FLOW = 3  // Flow continuation only
  };
enum ENUM_OFG2_SL { OFG2_SL_STRUCT=0, OFG2_SL_ATR=1 };
enum ENUM_OFG2_SIZING
  {
   OFG2_SZ_FIXEDPCT = 0, // Fixed % risk
   OFG2_SZ_META     = 1, // Meta-score scaled % risk
   OFG2_SZ_KELLY    = 2  // Fractional-Kelly (live win/payoff) x meta-score
  };

input group "=== 1. GENERAL ==="
input long             InpMagic            = 20260931;   // Magic number
input string           InpComment          = "OFGv2";    // Order comment
input ENUM_TIMEFRAMES  InpTF               = PERIOD_M5;  // Signal timeframe
input double           InpMaxSpreadAtrPct  = 9.0;        // Max spread as % of ATR (0=off)
input double           InpMaxSpreadPoints  = 0;          // Max spread in points (0=off)
input ulong            InpSlippage         = 30;         // Max deviation (points)
input bool             InpVerboseLog       = true;       // Verbose journal logging

input group "=== 2. TRADING WINDOW (broker TZ auto-detected) ==="
input ENUM_DBG_TIMEBASE InpTimeBase        = DBG_TB_GMT; // Times below are given in
input bool             InpManualOffset     = false;      // Override broker GMT offset?
input int              InpManualOffsetHours= 0;          // ...manual offset (hours vs GMT)
input string           InpTradeStart       = "06:00";    // Start trading (hh:mm)
input string           InpTradeEnd         = "20:00";    // Stop opening trades (hh:mm)
input string           InpFlattenTime      = "20:45";    // Close everything (hh:mm)
input bool             InpTradeMon         = true;       // Monday
input bool             InpTradeTue         = true;       // Tuesday
input bool             InpTradeWed         = true;       // Wednesday
input bool             InpTradeThu         = true;       // Thursday
input bool             InpTradeFri         = true;       // Friday
input int              InpFridayCloseHour  = 20;         // Friday force-flat hour GMT (0=off)

input group "=== 3. FLOW ENGINE (v2) ==="
input ENUM_OFG2_SOURCE InpFlowSource       = OFG2_SRC_AUTO; // Flow data source
input ENUM_OFG2_CLASS  InpFlowClass        = OFG2_CLS_TICKRULE; // Tick classification
input int              InpFlowBars         = 400;        // Flow history (bars)
input int              InpZLookback        = 96;         // Pooled z-score lookback (bars)
input bool             InpUseDiurnalZ       = true;       // Diurnal (time-of-day) z-score
input int              InpTickBatch         = 3000;      // Max ticks processed per update
input int              InpCvdSlopeBars     = 6;          // CVD slope window (bars)
input int              InpVpinWindow       = 50;         // VPIN window (volume buckets)
input double           InpVpinBucketTicks  = 400;        // VPIN bucket size (volume units)

input group "=== 4. VOLATILITY REGIME (ATR percentile) ==="
input bool             InpUseRegime        = true;       // Adapt engine to regime
input int              InpRegimeLookback   = 120;        // ATR percentile lookback (bars)
input double           InpCalmPct          = 40.0;       // <= this ATR pct = CALM (mean-revert)
input double           InpTrendPct         = 75.0;       // >= this ATR pct = TREND (continuation)
input double           InpStormPct         = 95.0;       // >= this ATR pct = STORM (stand aside)

input group "=== 5. SIGNAL THRESHOLDS ==="
input ENUM_OFG2_ENGINE InpEngine           = OFG2_ENG_AUTO; // Engine selection
input double           InpFlowZ            = 1.70;       // FLOW: min |diurnal z|
input double           InpFlowMinBodyAtr   = 0.22;       // FLOW: min body (x ATR)
input double           InpFlowMinEff       = 0.55;       // FLOW: min efficiency
input double           InpFadeZ            = 1.80;       // FADE: min |z| against move
input int              InpFadeLookback     = 12;         // FADE: new-extreme lookback (bars)
input double           InpFadeClosePos     = 0.60;       // FADE: min reject/close position
input double           InpFadeMaxEff       = 0.50;       // FADE: max efficiency (absorption)
input double           InpFadeVwapSigma    = 0.80;       // FADE: min VWAP distance (sigma)
input double           InpFadeMaxVpin      = 0.75;       // FADE blocked if VPIN above this
input double           InpStandAsideVpin   = 0.90;       // Both blocked if VPIN above this

input group "=== 6. META-SCORE (gate + size) ==="
input double           InpMinScore         = 0.45;       // Min meta-score to take a trade (0..1)
input double           InpScoreFullSize    = 0.75;       // Score at/above = full size

input group "=== 7. RISK / SL / TP ==="
input ENUM_OFG2_SIZING InpSizing           = OFG2_SZ_META; // Position sizing method
input double           InpRiskPercent      = 0.35;       // Base risk per trade (% balance)
input double           InpFixedLots        = 0.01;       // Fixed lot if risk % = 0
input double           InpKellyFraction    = 0.25;       // Fractional Kelly (0.25 = quarter)
input double           InpMaxRiskPercent   = 0.60;       // Hard cap on risk per trade (%)
input int              InpKellyMinTrades   = 20;         // Min closed trades before Kelly acts
input ENUM_OFG2_SL     InpSlMode           = OFG2_SL_STRUCT; // Stop-loss placement
input double           InpSlBufferAtr      = 0.20;       // Structure buffer (x ATR)
input double           InpAtrSlMult        = 1.10;       // ATR stop multiplier
input double           InpMinStopAtr       = 0.55;       // Min stop distance (x ATR)
input double           InpMaxStopAtr       = 1.80;       // Max stop distance (x ATR)
input double           InpTp1R             = 0.60;       // TP1 (R) - high-probability target
input double           InpTp1ClosePct      = 70.0;       // % closed at TP1
input double           InpTp2R             = 2.20;       // TP2 / runner target (R) [1.5-3.5 band]
input bool             InpUseBreakeven     = true;       // SL to breakeven after TP1
input double           InpBeLockR          = 0.05;       // Locked profit at BE (R)
input bool             InpUseTrailing      = true;       // ATR trailing for the runner
input double           InpTrailStartR      = 0.90;       // Trail starts after (R)
input double           InpTrailAtrMult     = 1.20;       // Trail distance (x ATR)
input int              InpTimeStopBars     = 12;         // Time stop (bars, 0=off)
input double           InpTimeStopMinR     = 0.15;       // ...only if below this R

input group "=== 8. DAILY GUARDS ==="
input int              InpMaxTradesPerDay  = 8;          // Max trades per day
input int              InpCooldownMin      = 8;          // Cooldown after a trade (minutes)
input int              InpMaxConsecLosses  = 4;          // Stop after N losses in a row (0=off)
input double           InpDailyLossPct     = 2.5;        // Daily loss limit (%, 0=off)
input double           InpDailyProfitPct   = 0.0;        // Daily profit target (%, 0=off)
input double           InpMinAtrPoints     = 0;          // Min ATR in points (0=off)

input group "=== 9. NEWS FILTER (MT5 ECONOMIC CALENDAR) ==="
input bool             InpNewsEnabled      = true;       // Enable news filter
input string           InpNewsCurrencies   = "AUTO";     // Currencies (AUTO / ALL / "USD,EUR")
input ENUM_DBG_NEWSIMP InpNewsImportance   = DBG_IMP_HIGH; // Which events block trading
input int              InpNewsMinsBefore   = 30;         // OFF x minutes BEFORE news
input int              InpNewsMinsAfter    = 30;         // ON again x minutes AFTER news
input bool             InpNewsClosePos     = true;       // Close open trades before news
input int              InpNewsCloseBefore  = 3;          // ...how many minutes before
input int              InpNewsShiftMinutes = 0;          // Calendar time correction (min)
input int              InpNewsReloadMin    = 30;         // Calendar refresh (min)
input bool             InpNewsUseCsv       = true;       // CSV fallback (backtest)
input string           InpNewsCsvFile      = "DBG_News.csv"; // CSV file
input bool             InpNewsCsvCommon    = true;       // CSV in COMMON folder

input group "=== 10. DASHBOARD ==="
input bool             InpShowPanel        = true;       // Show dashboard
input ENUM_BASE_CORNER InpPanelCorner      = CORNER_LEFT_UPPER; // Corner
input int              InpPanelX           = 12;         // Panel X
input int              InpPanelY           = 100;        // Panel Y
input int              InpPanelWidth       = 500;        // Panel width
input int              InpPanelFontSize    = 8;          // Font size
input string           InpPanelFont        = "Consolas"; // Font
input bool             InpShowVwap         = true;       // Draw session VWAP line

//+------------------------------------------------------------------+
enum ENUM_REGIME { REG_CALM=0, REG_NORMAL=1, REG_TREND=2, REG_STORM=3 };

CTrade        trade;
CDbgTimeZone  TZ;
CDbgNews      News;
COfgFlow2     Flow;
COfgPanel2    Panel;

int      hAtr=INVALID_HANDLE;
double   g_atr=0.0;
double   g_atrPct=50.0;
ENUM_REGIME g_regime=REG_NORMAL;

datetime g_lastBar=0,g_tradeStartSrv=0,g_tradeEndSrv=0,g_flattenSrv=0,g_sessionAnchor=0,g_lastTradeTime=0;

ulong    g_posTicket=0;
int      g_posDir=0;
double   g_posEntry=0.0,g_posRisk=0.0;
datetime g_posOpened=0;
bool     g_beDone=false,g_tp1Done=false;
string   g_posEngine="";
double   g_lastScore=0.0;

datetime g_statDay=0;
int      g_tradesToday=0,g_wins=0,g_losses=0,g_consecLoss=0;
double   g_dayPnl=0.0,g_dayStartBal=0.0,g_sumWin=0.0,g_sumLoss=0.0;
bool     g_halted=false;
string   g_haltReason="";

bool     g_paused=false;
string   g_lastSignal="-",g_lastBlock="-";

#define OFG2_VWAP_LINE  OFG2_PREFIX+"vwap"

//--- forward decls
void   Log(const string m);
int    ParseHM(const string hm,const int fb);
datetime CfgToSrv(const datetime t);
datetime SrvToCfg(const datetime t);
void   ComputeWindow(void);
bool   IsTradingDay(void);
bool   FindPosition(void);
void   CloseAll(const string why);
double NormalizeLots(double l);
double CalcLots(const double stopDist,const double score);
void   UpdateRegime(void);
double KellyFraction(void);
bool   TradingAllowed(string &reason);
void   UpdateStats(void);
void   CheckSignals(void);
void   ManagePosition(void);
void   HandleExits(void);
void   BuildPanel(void);
void   UpdatePanel(void);
void   DrawVwap(void);
string RegimeText(void);
color  RegimeColor(void);

//+------------------------------------------------------------------+
void Log(const string m){ if(InpVerboseLog) Print("[OFGv2] ",m); }

int ParseHM(const string hm,const int fb)
  {
   string p[];
   if(StringSplit(hm,StringGetCharacter(":",0),p)<2) return(fb);
   int h=(int)StringToInteger(p[0]),m=(int)StringToInteger(p[1]);
   if(h<0||h>23||m<0||m>59) return(fb);
   return(h*3600+m*60);
  }
datetime CfgToSrv(const datetime t){ return(InpTimeBase==DBG_TB_SERVER?t:TZ.ToServer(t)); }
datetime SrvToCfg(const datetime t){ return(InpTimeBase==DBG_TB_SERVER?t:TZ.ToGmt(t)); }

//+------------------------------------------------------------------+
void ComputeWindow(void)
  {
   int s=ParseHM(InpTradeStart,6*3600);
   int e=ParseHM(InpTradeEnd,20*3600);
   int f=ParseHM(InpFlattenTime,20*3600+2700);
   datetime nowCfg=SrvToCfg(TimeTradeServer());
   datetime day=nowCfg-(datetime)(nowCfg%86400);
   datetime st=day+(datetime)s;
   datetime en=day+(datetime)e; if(e<=s) en+=86400;
   datetime fl=day+(datetime)f; if(f<=s) fl+=86400;
   if(fl<en) fl=en;
   g_tradeStartSrv=CfgToSrv(st);
   g_tradeEndSrv=CfgToSrv(en);
   g_flattenSrv=CfgToSrv(fl);
   if(g_sessionAnchor!=g_tradeStartSrv)
     {
      g_sessionAnchor=g_tradeStartSrv;
      Flow.ResetSession(g_sessionAnchor);
     }
  }

//+------------------------------------------------------------------+
bool IsTradingDay(void)
  {
   MqlDateTime d; ZeroMemory(d); TimeToStruct(TimeTradeServer(),d);
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
bool FindPosition(void)
  {
   g_posTicket=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      g_posTicket=tk;
      g_posDir=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?1:-1);
      g_posEntry=PositionGetDouble(POSITION_PRICE_OPEN);
      return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
void CloseAll(const string why)
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if(trade.PositionClose(tk,InpSlippage)) Log("closed #"+IntegerToString((int)tk)+" ("+why+")");
     }
  }

//+------------------------------------------------------------------+
double NormalizeLots(double l)
  {
   double mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double mx=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double st=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(st<=0.0) st=0.01;
   l=MathFloor(l/st+0.0000001)*st;
   if(l<mn) l=mn;
   if(l>mx) l=mx;
   return(NormalizeDouble(l,2));
  }

//+------------------------------------------------------------------+
//| Fractional-Kelly fraction from the live win-rate/payoff          |
//+------------------------------------------------------------------+
double KellyFraction(void)
  {
   int closed=g_wins+g_losses;
   if(closed<InpKellyMinTrades) return(1.0);            // not enough data -> base size
   double wr=(double)g_wins/closed;
   double avgW=(g_wins>0?g_sumWin/g_wins:0.0);
   double avgL=(g_losses>0?g_sumLoss/g_losses:0.0);
   if(avgL<=0.0) return(1.0);
   double b=avgW/avgL;                                  // payoff
   if(b<=0.0) return(0.0);
   double f=(b*wr-(1.0-wr))/b;                          // full Kelly
   if(f<=0.0) return(0.0);
   f*=InpKellyFraction;                                 // fractional
   //--- express as a multiple of the base risk fraction
   double baseF=InpRiskPercent/100.0;
   if(baseF<=0.0) return(1.0);
   double mult=f/baseF;
   if(mult<0.25) mult=0.25;
   if(mult>2.0)  mult=2.0;
   return(mult);
  }

//+------------------------------------------------------------------+
double CalcLots(const double stopDist,const double score)
  {
   double riskPct=InpRiskPercent;
   if(InpSizing==OFG2_SZ_META || InpSizing==OFG2_SZ_KELLY)
     {
      double sc=(score-InpMinScore)/MathMax(0.0001,InpScoreFullSize-InpMinScore);
      if(sc<0.0) sc=0.0; if(sc>1.0) sc=1.0;
      double scaled=0.5+0.5*sc;                          // 0.5x..1.0x of base by conviction
      riskPct*=scaled;
     }
   if(InpSizing==OFG2_SZ_KELLY) riskPct*=KellyFraction();
   if(riskPct>InpMaxRiskPercent) riskPct=InpMaxRiskPercent;

   if(riskPct<=0.0 || stopDist<=0.0) return(NormalizeLots(InpFixedLots));
   double riskMoney=AccountInfoDouble(ACCOUNT_BALANCE)*riskPct/100.0;
   double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tv<=0.0||ts<=0.0) return(NormalizeLots(InpFixedLots));
   double lossPerLot=stopDist/ts*tv;
   if(lossPerLot<=0.0) return(NormalizeLots(InpFixedLots));
   return(NormalizeLots(riskMoney/lossPerLot));
  }

//+------------------------------------------------------------------+
//| Volatility regime from ATR percentile (HMM-style discretisation) |
//+------------------------------------------------------------------+
void UpdateRegime(void)
  {
   double atrBuf[];
   int need=InpRegimeLookback+2;
   if(CopyBuffer(hAtr,0,1,need,atrBuf)<need) { g_atrPct=50.0; g_regime=REG_NORMAL; return; }
   double cur=atrBuf[need-1];
   int below=0,valid=0;
   for(int i=0;i<need-1;i++)
     {
      if(atrBuf[i]<=0.0) continue;
      valid++;
      if(atrBuf[i]<cur) below++;
     }
   g_atrPct=(valid>0?(double)below/valid*100.0:50.0);
   if(!InpUseRegime) { g_regime=REG_NORMAL; return; }
   if(g_atrPct>=InpStormPct)      g_regime=REG_STORM;
   else if(g_atrPct>=InpTrendPct) g_regime=REG_TREND;
   else if(g_atrPct<=InpCalmPct)  g_regime=REG_CALM;
   else                           g_regime=REG_NORMAL;
  }

//+------------------------------------------------------------------+
bool TradingAllowed(string &reason)
  {
   reason="";
   if(g_paused)                                     { reason="paused (manual)"; return(false); }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))           { reason="algo trading off"; return(false); }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) { reason="terminal blocked"; return(false); }
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))    { reason="account blocks EA"; return(false); }
   if(g_halted)                                     { reason=g_haltReason; return(false); }
   if(!IsTradingDay())                              { reason="day disabled"; return(false); }
   datetime now=TimeTradeServer();
   if(now<g_tradeStartSrv)  { reason="before window ("+DbgHM(SrvToCfg(g_tradeStartSrv))+")"; return(false); }
   if(now>=g_tradeEndSrv)   { reason="window closed"; return(false); }
   if(InpMaxTradesPerDay>0 && g_tradesToday>=InpMaxTradesPerDay) { reason="max trades/day"; return(false); }
   if(InpMaxConsecLosses>0 && g_consecLoss>=InpMaxConsecLosses)  { reason="loss streak"; return(false); }
   if(InpCooldownMin>0 && g_lastTradeTime>0 && (now-g_lastTradeTime)<(datetime)(InpCooldownMin*60))
     { reason="cooldown "+DbgDuration((int)(InpCooldownMin*60-(now-g_lastTradeTime))); return(false); }
   double sprPts=DbgSpreadPoints(_Symbol);
   if(InpMaxSpreadPoints>0 && sprPts>InpMaxSpreadPoints) { reason=StringFormat("spread %.0f pts",sprPts); return(false); }
   if(InpMaxSpreadAtrPct>0.0 && g_atr>0.0)
     {
      double pct=(DbgAsk(_Symbol)-DbgBid(_Symbol))/g_atr*100.0;
      if(pct>InpMaxSpreadAtrPct) { reason=StringFormat("spread %.1f%% ATR",pct); return(false); }
     }
   if(InpMinAtrPoints>0 && g_atr>0.0 && (g_atr/DbgPoint(_Symbol))<InpMinAtrPoints) { reason="ATR too low"; return(false); }
   if(g_regime==REG_STORM) { reason="STORM regime (vol too high)"; return(false); }
   if(Flow.Vpin()>=InpStandAsideVpin) { reason=StringFormat("VPIN %.2f toxic",Flow.Vpin()); return(false); }
   DbgNewsEvent ev; int resume=0;
   if(News.IsBlocked(now,ev,resume)) { reason="NEWS lock "+ev.currency+" ("+DbgDuration(resume)+")"; return(false); }
   return(true);
  }

//+------------------------------------------------------------------+
void UpdateStats(void)
  {
   datetime now=TimeTradeServer();
   datetime day=now-(datetime)(now%86400);
   if(g_statDay!=day)
     {
      g_statDay=day; g_dayStartBal=AccountInfoDouble(ACCOUNT_BALANCE);
      g_tradesToday=0; g_wins=0; g_losses=0; g_dayPnl=0.0; g_sumWin=0.0; g_sumLoss=0.0;
      g_halted=false; g_haltReason="";
     }
   //--- lifetime stats for Kelly (all history for this magic)
   if(!HistorySelect(0,now+60)) return;
   int wins=0,losses=0,streak=0; double sw=0.0,sl=0.0;
   int trToday=0; double pnlToday=0.0; datetime lastOut=0;
   int total=HistoryDealsTotal();
   for(int i=0;i<total;i++)
     {
      ulong dl=HistoryDealGetTicket(i);
      if(dl==0) continue;
      if(HistoryDealGetString(dl,DEAL_SYMBOL)!=_Symbol) continue;
      if(HistoryDealGetInteger(dl,DEAL_MAGIC)!=InpMagic) continue;
      long entry=HistoryDealGetInteger(dl,DEAL_ENTRY);
      datetime dt=(datetime)HistoryDealGetInteger(dl,DEAL_TIME);
      if(entry==DEAL_ENTRY_IN)
        {
         if(dt>=day) trToday++;
         if(dt>lastOut) lastOut=dt;
         continue;
        }
      if(entry!=DEAL_ENTRY_OUT && entry!=DEAL_ENTRY_OUT_BY) continue;
      double p=HistoryDealGetDouble(dl,DEAL_PROFIT)+HistoryDealGetDouble(dl,DEAL_SWAP)+HistoryDealGetDouble(dl,DEAL_COMMISSION);
      if(p>0)      { wins++; sw+=p; streak=0; }
      else if(p<0) { losses++; sl+=-p; streak++; }
      if(dt>=day)  pnlToday+=p;
     }
   g_wins=wins; g_losses=losses; g_consecLoss=streak; g_sumWin=sw; g_sumLoss=sl;
   g_tradesToday=trToday; g_dayPnl=pnlToday;
   if(lastOut>g_lastTradeTime) g_lastTradeTime=lastOut;

   if(g_dayStartBal>0.0)
     {
      double pct=g_dayPnl/g_dayStartBal*100.0;
      if(InpDailyLossPct>0.0 && pct<=-InpDailyLossPct && !g_halted)
        { g_halted=true; g_haltReason=StringFormat("daily loss %.2f%%",pct); Log("HALT "+g_haltReason); }
      if(InpDailyProfitPct>0.0 && pct>=InpDailyProfitPct && !g_halted)
        { g_halted=true; g_haltReason=StringFormat("daily target %.2f%%",pct); Log("HALT "+g_haltReason); }
     }
  }

//+------------------------------------------------------------------+
//| Meta-score 0..1 : blends the confirming evidence for a setup     |
//+------------------------------------------------------------------+
double ScoreFade(const int dir,const double z,const double eff,const double vwapDist,const double ibs)
  {
   double s=0.0;
   s += 0.30*MathMin(1.0,MathAbs(z)/2.5);                    // flow strength
   s += 0.20*MathMin(1.0,(InpFadeMaxEff-eff)/InpFadeMaxEff); // absorption depth
   s += 0.15*MathMin(1.0,MathAbs(vwapDist)/1.5);             // stretch from value
   s += 0.10*(dir>0 ? (1.0-ibs) : ibs);                      // reversal candle shape
   s += 0.10*Flow.HorizonAgreement();                        // multi-horizon accord
   s += 0.10*(1.0-MathMin(1.0,Flow.Vpin()/InpFadeMaxVpin));  // low toxicity better for fades
   double mo=Flow.MicroOffset(DbgAsk(_Symbol)-DbgBid(_Symbol));
   s += 0.05*((dir>0 && mo>=0.0)||(dir<0 && mo<=0.0) ? 1.0 : 0.0); // micro-price lean
   if(g_regime==REG_CALM)   s+=0.05;
   if(g_regime==REG_TREND)  s-=0.10;                          // fading a trend is worse
   return(MathMax(0.0,MathMin(1.0,s)));
  }
double ScoreFlow(const int dir,const double z,const double eff,const double body)
  {
   double s=0.0;
   s += 0.30*MathMin(1.0,MathAbs(z)/2.5);
   s += 0.20*MathMin(1.0,eff/0.9);
   s += 0.15*MathMin(1.0,body/(0.6*g_atr));
   s += 0.15*Flow.HorizonAgreement();
   double cvdS=Flow.CvdSlope(InpCvdSlopeBars);
   s += 0.10*(((dir>0&&cvdS>0)||(dir<0&&cvdS<0)) ? 1.0 : 0.0);
   s += 0.10*MathMin(1.0,Flow.Vpin()/0.6);                   // toxic one-sided flow helps continuation
   if(g_regime==REG_TREND)  s+=0.08;
   if(g_regime==REG_CALM)   s-=0.08;
   return(MathMax(0.0,MathMin(1.0,s)));
  }

//+------------------------------------------------------------------+
bool DoOpen(const int dir,const double slRaw,const string engine,const double score,const string why)
  {
   double price=(dir>0?DbgAsk(_Symbol):DbgBid(_Symbol));
   double sl=slRaw;
   double dist=MathAbs(price-sl);
   double minDist=MathMax(InpMinStopAtr*g_atr,DbgStopsLevelPrice(_Symbol)+(DbgAsk(_Symbol)-DbgBid(_Symbol)));
   double maxDist=InpMaxStopAtr*g_atr;
   if(maxDist>0.0 && dist>maxDist) dist=maxDist;
   if(dist<minDist) dist=minDist;
   sl=DbgNormPrice(_Symbol,(dir>0?price-dist:price+dist));
   double tp=0.0;
   if(InpTp2R>0.0) tp=DbgNormPrice(_Symbol,(dir>0?price+InpTp2R*dist:price-InpTp2R*dist));
   double lots=CalcLots(dist,score);
   if(lots<=0.0) { Log("lot calc failed"); return(false); }
   bool ok=(dir>0?trade.Buy(lots,_Symbol,0.0,sl,tp,InpComment+" "+engine)
                 :trade.Sell(lots,_Symbol,0.0,sl,tp,InpComment+" "+engine));
   if(!ok) { Log(StringFormat("order failed %d %s",trade.ResultRetcode(),trade.ResultRetcodeDescription())); return(false); }
   g_posRisk=dist; g_posDir=dir; g_posEntry=price; g_posOpened=TimeTradeServer();
   g_beDone=false; g_tp1Done=false; g_posEngine=engine; g_lastScore=score;
   g_lastTradeTime=TimeTradeServer();
   g_lastSignal=StringFormat("%s %s @ %s sc%.2f (%s)",engine,(dir>0?"BUY":"SELL"),DbgPriceStr(_Symbol,price),score,why);
   Log(StringFormat("%s | lots %.2f | SL %s | TP %s | 1R=%.2f | regime %s",g_lastSignal,lots,
                    DbgPriceStr(_Symbol,sl),DbgPriceStr(_Symbol,tp),dist,RegimeText()));
   return(true);
  }

//+------------------------------------------------------------------+
void CheckSignals(void)
  {
   if(FindPosition()) return;
   string reason="";
   if(!TradingAllowed(reason)) { g_lastBlock=reason; return; }
   g_lastBlock="-";

   MqlRates r[];
   ArraySetAsSeries(r,true);
   int need=(InpFadeLookback+4>8?InpFadeLookback+4:8);
   if(CopyRates(_Symbol,InpTF,0,need,r)<need) return;
   if(!Flow.Valid(1)) return;

   double o1=r[1].open,h1=r[1].high,l1=r[1].low,c1=r[1].close;
   double rng=h1-l1;
   if(rng<=0.0) return;

   double z    = InpUseDiurnalZ ? Flow.DeltaZBest(1,InpZLookback) : Flow.DeltaZ(1,InpZLookback);
   double eff  = Flow.Efficiency(1);
   double vwap = Flow.Vwap();
   double sig  = Flow.VwapSigma();
   double ibs  = Flow.Ibs(1);
   double buf  = MathMax(InpSlBufferAtr*g_atr,2.0*DbgPoint(_Symbol));

   bool wantFade = (InpEngine==OFG2_ENG_BOTH || InpEngine==OFG2_ENG_FADE ||
                   (InpEngine==OFG2_ENG_AUTO && (g_regime==REG_CALM||g_regime==REG_NORMAL)));
   bool wantFlow = (InpEngine==OFG2_ENG_BOTH || InpEngine==OFG2_ENG_FLOW ||
                   (InpEngine==OFG2_ENG_AUTO && (g_regime==REG_TREND||g_regime==REG_NORMAL)));

   //=== ABSORPTION / REVERSAL FADE ===
   if(wantFade && Flow.Vpin()<InpFadeMaxVpin)
     {
      double lowestPrev=DBL_MAX,highestPrev=-DBL_MAX;
      for(int i=2;i<=InpFadeLookback+1 && i<ArraySize(r);i++)
        { lowestPrev=MathMin(lowestPrev,r[i].low); highestPrev=MathMax(highestPrev,r[i].high); }
      double closePos=(c1-l1)/rng;
      bool absorbed=(eff<=InpFadeMaxEff);

      //--- BUY fade
      if(l1<lowestPrev && z<=-InpFadeZ && closePos>=InpFadeClosePos && absorbed &&
         (InpFadeVwapSigma<=0.0||sig<=0.0||(vwap-c1)>=InpFadeVwapSigma*sig))
        {
         double vd=(sig>0.0?(c1-vwap)/sig:0.0);
         double sc=ScoreFade(1,z,eff,vd,ibs);
         if(sc>=InpMinScore)
           {
            double sl=(InpSlMode==OFG2_SL_ATR?DbgBid(_Symbol)-InpAtrSlMult*g_atr:l1-buf);
            if(DoOpen(1,sl,"FADE",sc,StringFormat("z%.1f eff%.2f",z,eff))) return;
           }
         else g_lastBlock=StringFormat("FADE score %.2f<%.2f",sc,InpMinScore);
        }
      //--- SELL fade
      if(h1>highestPrev && z>=InpFadeZ && (h1-c1)/rng>=InpFadeClosePos && absorbed &&
         (InpFadeVwapSigma<=0.0||sig<=0.0||(c1-vwap)>=InpFadeVwapSigma*sig))
        {
         double vd=(sig>0.0?(c1-vwap)/sig:0.0);
         double sc=ScoreFade(-1,z,eff,vd,ibs);
         if(sc>=InpMinScore)
           {
            double sl=(InpSlMode==OFG2_SL_ATR?DbgAsk(_Symbol)+InpAtrSlMult*g_atr:h1+buf);
            if(DoOpen(-1,sl,"FADE",sc,StringFormat("z%.1f eff%.2f",z,eff))) return;
           }
         else g_lastBlock=StringFormat("FADE score %.2f<%.2f",sc,InpMinScore);
        }
     }

   //=== FLOW CONTINUATION ===
   if(wantFlow)
     {
      double body=MathAbs(c1-o1);
      bool bigBody=(body>=InpFlowMinBodyAtr*g_atr);
      bool efficient=(eff>=InpFlowMinEff);
      //--- BUY
      if(z>=InpFlowZ && c1>o1 && bigBody && efficient && c1>r[2].high && Flow.CvdSlope(InpCvdSlopeBars)>0.0)
        {
         double sc=ScoreFlow(1,z,eff,body);
         if(sc>=InpMinScore)
           {
            double sl=(InpSlMode==OFG2_SL_ATR?DbgBid(_Symbol)-InpAtrSlMult*g_atr:MathMin(l1,r[2].low)-buf);
            if(DoOpen(1,sl,"FLOW",sc,StringFormat("z%.1f eff%.2f",z,eff))) return;
           }
         else g_lastBlock=StringFormat("FLOW score %.2f<%.2f",sc,InpMinScore);
        }
      //--- SELL
      if(z<=-InpFlowZ && c1<o1 && bigBody && efficient && c1<r[2].low && Flow.CvdSlope(InpCvdSlopeBars)<0.0)
        {
         double sc=ScoreFlow(-1,z,eff,body);
         if(sc>=InpMinScore)
           {
            double sl=(InpSlMode==OFG2_SL_ATR?DbgAsk(_Symbol)+InpAtrSlMult*g_atr:MathMax(h1,r[2].high)+buf);
            if(DoOpen(-1,sl,"FLOW",sc,StringFormat("z%.1f eff%.2f",z,eff))) return;
           }
         else g_lastBlock=StringFormat("FLOW score %.2f<%.2f",sc,InpMinScore);
        }
     }
  }

//+------------------------------------------------------------------+
void ManagePosition(void)
  {
   if(!FindPosition()) { g_tp1Done=false; g_beDone=false; g_posRisk=0.0; return; }
   if(!PositionSelectByTicket(g_posTicket)) return;
   double entry=PositionGetDouble(POSITION_PRICE_OPEN);
   double sl=PositionGetDouble(POSITION_SL);
   double tp=PositionGetDouble(POSITION_TP);
   double vol=PositionGetDouble(POSITION_VOLUME);
   int dir=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?1:-1);
   double price=(dir>0?DbgBid(_Symbol):DbgAsk(_Symbol));
   if(g_posRisk<=0.0 && sl>0.0) g_posRisk=MathAbs(entry-sl);
   if(g_posRisk<=0.0) return;
   if(g_posOpened==0) g_posOpened=(datetime)PositionGetInteger(POSITION_TIME);
   double rNow=(dir>0?price-entry:entry-price)/g_posRisk;
   double minD=DbgStopsLevelPrice(_Symbol);

   if(InpTp1R>0.0 && !g_tp1Done && rNow>=InpTp1R && InpTp1ClosePct>0.0 && InpTp1ClosePct<100.0)
     {
      double cv=NormalizeLots(vol*InpTp1ClosePct/100.0);
      double mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
      if(cv>=mn && (vol-cv)>=mn)
        { if(trade.PositionClosePartial(g_posTicket,cv,InpSlippage)) { g_tp1Done=true; Log(StringFormat("TP1 %.2fR -%.2f lots",rNow,cv)); } }
      else
        { if(trade.PositionClose(g_posTicket,InpSlippage)) { Log(StringFormat("TP1 %.2fR full (min lot)",rNow)); return; } }
     }
   if(InpUseBreakeven && !g_beDone && g_tp1Done)
     {
      double nsl=DbgNormPrice(_Symbol,(dir>0?entry+InpBeLockR*g_posRisk:entry-InpBeLockR*g_posRisk));
      bool better=(dir>0?(sl<=0.0||nsl>sl):(sl<=0.0||nsl<sl));
      bool valid=(dir>0?(price-nsl)>minD:(nsl-price)>minD);
      if(better&&valid&&trade.PositionModify(g_posTicket,nsl,tp)) { g_beDone=true; sl=nsl; Log("breakeven set"); }
     }
   if(InpUseTrailing && rNow>=InpTrailStartR && g_atr>0.0)
     {
      double nsl=DbgNormPrice(_Symbol,(dir>0?price-InpTrailAtrMult*g_atr:price+InpTrailAtrMult*g_atr));
      bool better=(dir>0?(sl<=0.0||nsl>sl+DbgPoint(_Symbol)):(sl<=0.0||nsl<sl-DbgPoint(_Symbol)));
      bool valid=(dir>0?(price-nsl)>minD:(nsl-price)>minD);
      if(better&&valid) trade.PositionModify(g_posTicket,nsl,tp);
     }
   if(InpTimeStopBars>0 && g_posOpened>0)
     {
      int barsHeld=(int)((TimeTradeServer()-g_posOpened)/PeriodSeconds(InpTF));
      if(barsHeld>=InpTimeStopBars && rNow<InpTimeStopMinR && !g_tp1Done)
        { if(trade.PositionClose(g_posTicket,InpSlippage)) Log(StringFormat("time stop %d bars (%.2fR)",barsHeld,rNow)); }
     }
  }

//+------------------------------------------------------------------+
void HandleExits(void)
  {
   datetime now=TimeTradeServer();
   if(now>=g_flattenSrv && FindPosition()) { CloseAll("session flat"); return; }
   if(InpFridayCloseHour>0)
     {
      MqlDateTime g; ZeroMemory(g); TimeToStruct(TZ.GmtNow(),g);
      if(g.day_of_week==5 && g.hour>=InpFridayCloseHour && FindPosition()) { CloseAll("friday flat"); return; }
     }
   if(InpNewsEnabled && InpNewsClosePos)
     {
      DbgNewsEvent ev;
      if(News.EventWithin(now,InpNewsCloseBefore*60,ev) && FindPosition())
         CloseAll("news "+ev.currency+" in "+IntegerToString(InpNewsCloseBefore)+"m");
     }
  }

//+------------------------------------------------------------------+
string RegimeText(void)
  {
   switch(g_regime)
     {
      case REG_CALM:  return("CALM (mean-revert)");
      case REG_TREND: return("TREND (continuation)");
      case REG_STORM: return("STORM (stand aside)");
      default:        return("NORMAL (both)");
     }
  }
color RegimeColor(void)
  {
   switch(g_regime)
     {
      case REG_CALM:  return(C'120,200,255');
      case REG_TREND: return(C'120,230,150');
      case REG_STORM: return(C'250,110,110');
      default:        return(C'225,230,238');
     }
  }

//+------------------------------------------------------------------+
void BuildPanel(void)
  {
   Panel.Create(0,(int)InpPanelCorner,InpPanelX,InpPanelY,InpPanelWidth,InpPanelFontSize,InpPanelFont,
                "ORDER FLOW GOLD  v2.00   (diurnal flow / VPIN / regime)");
   Panel.AddSection("CLOCK  &  TIMEZONE");
   Panel.AddRow("srv","Server time");   Panel.AddRow("tz","Broker zone");
   Panel.AddRow("gmt","GMT / UTC");     Panel.AddRow("world","World clock");
   Panel.AddRow("win","Trade window");
   Panel.AddSection("MARKET  &  REGIME");
   Panel.AddRow("sym","Symbol / TF");   Panel.AddRow("quote","Bid/Ask/Spr");
   Panel.AddRow("atr","ATR / spread");  Panel.AddRow("reg","Regime");
   Panel.AddRow("vwap","Session VWAP");
   Panel.AddSection("ORDER  FLOW  (v2)");
   Panel.AddRow("src","Data source");   Panel.AddRow("delta","Bar delta / z");
   Panel.AddRow("iofi","Integrated OFI");Panel.AddRow("cvd","CVD (session)");
   Panel.AddRow("vpin","VPIN toxicity");Panel.AddRow("micro","Micro-price / imb");
   Panel.AddRow("eff","Efficiency");    Panel.AddRow("rate","Tick rate / intensity");
   Panel.AddSection("SIGNAL  ENGINE");
   Panel.AddRow("eng","Engine / mode"); Panel.AddRow("score","Meta-score");
   Panel.AddRow("last","Last signal");  Panel.AddRow("block","Blocked by");
   Panel.AddRow("pos","Position");      Panel.AddRow("sltp","SL / TP");
   Panel.AddSection("NEWS  FILTER  (MT5 CALENDAR)");
   Panel.AddRow("nstat","Status");      Panel.AddRow("nnext","Next event");
   Panel.AddRow("nwin","Window");
   Panel.AddSection("RISK  &  STATISTICS");
   Panel.AddRow("acc","Account");       Panel.AddRow("day","Today");
   Panel.AddRow("wr","Win / payoff");   Panel.AddRow("kelly","Sizing");
   Panel.AddRow("guard","Guards");
   Panel.Finish();
  }

//+------------------------------------------------------------------+
void UpdatePanel(void)
  {
   if(!InpShowPanel || !Panel.Created() || Panel.Minimized()) return;

   Panel.SetValue("srv",DbgFull(TimeTradeServer()));
   Panel.SetValue("tz",TZ.ZoneLabel()+" | "+TZ.ZoneGuess());
   Panel.SetValue("gmt",DbgFull(TZ.GmtNow()));
   Panel.SetValue("world",TZ.CityLine()+"  ["+TZ.SessionLine()+"]");
   Panel.SetValue("win",StringFormat("%s - %s %s | flat %s",DbgHM(SrvToCfg(g_tradeStartSrv)),
                  DbgHM(SrvToCfg(g_tradeEndSrv)),(InpTimeBase==DBG_TB_GMT?"GMT":"srv"),DbgHM(SrvToCfg(g_flattenSrv))));

   double spr=DbgSpreadPoints(_Symbol);
   double sprPct=(g_atr>0.0?(DbgAsk(_Symbol)-DbgBid(_Symbol))/g_atr*100.0:0.0);
   bool sprBad=(InpMaxSpreadAtrPct>0.0 && sprPct>InpMaxSpreadAtrPct);
   Panel.SetValue("sym",_Symbol+"  "+StringSubstr(EnumToString(InpTF),7));
   Panel.SetValue("quote",StringFormat("%s / %s  %.0f pts",DbgPriceStr(_Symbol,DbgBid(_Symbol)),DbgPriceStr(_Symbol,DbgAsk(_Symbol)),spr),
                  (sprBad?C'240,120,120':C'225,230,238'));
   Panel.SetValue("atr",StringFormat("ATR %.2f (pct %.0f) | spr %.1f%%ATR",g_atr,g_atrPct,sprPct),(sprBad?C'240,120,120':C'225,230,238'));
   Panel.SetValue("reg",RegimeText(),RegimeColor());
   double vwap=Flow.Vwap(),vsig=Flow.VwapSigma();
   double vd=(vwap>0.0&&vsig>0.0?(DbgBid(_Symbol)-vwap)/vsig:0.0);
   Panel.SetValue("vwap",(vwap>0.0?StringFormat("%s  price %+.2f sigma",DbgPriceStr(_Symbol,vwap),vd):"building..."));

   double d1=Flow.Delta(1),d0=Flow.Delta(0);
   double z1=InpUseDiurnalZ?Flow.DeltaZBest(1,InpZLookback):Flow.DeltaZ(1,InpZLookback);
   double iofi=Flow.IntegratedOFI(InpZLookback);
   double cvd=Flow.Cvd(),cvdS=Flow.CvdSlope(InpCvdSlopeBars);
   double eff=Flow.Efficiency(1),vpin=Flow.Vpin();
   color dcol=(d1>0?C'120,230,150':(d1<0?C'240,130,130':C'225,230,238'));
   Panel.SetValue("src",Flow.SourceText()+" | "+Flow.Status()+" | bars "+IntegerToString(Flow.Count())+" | seas "+IntegerToString(Flow.SeasonSamples(1)));
   Panel.SetValue("delta",StringFormat("closed %+.0f (z %+.2f %s) | live %+.0f",d1,z1,(InpUseDiurnalZ?"diur":"pool"),d0),dcol);
   Panel.SetValue("iofi",StringFormat("%+.2f | horizon accord %.0f%%",iofi,Flow.HorizonAgreement()*100.0),
                  (iofi>0?C'120,230,150':(iofi<0?C'240,130,130':C'225,230,238')));
   Panel.SetValue("cvd",StringFormat("%+.0f | slope(%d) %+.0f",cvd,InpCvdSlopeBars,cvdS),
                  (cvdS>0?C'120,230,150':(cvdS<0?C'240,130,130':C'225,230,238')));
   color vcol=(vpin>=InpStandAsideVpin?C'250,110,110':(vpin>=InpFadeMaxVpin?C'240,200,90':C'120,230,150'));
   Panel.SetValue("vpin",StringFormat("%.2f  %s",vpin,(vpin>=InpStandAsideVpin?"<- STAND ASIDE":(vpin>=InpFadeMaxVpin?"<- no fades":"benign"))),vcol);
   double mo=Flow.MicroOffset(DbgAsk(_Symbol)-DbgBid(_Symbol));
   Panel.SetValue("micro",StringFormat("offset %+.3f | imb %.0f%%",mo,Flow.Imbalance()*100.0));
   Panel.SetValue("eff",StringFormat("%.2f  %s",eff,(eff<=InpFadeMaxEff?"<- ABSORPTION":(eff>=InpFlowMinEff?"<- flow moves price":""))),
                  (eff<=InpFadeMaxEff?C'240,200,90':C'225,230,238'));
   Panel.SetValue("rate",StringFormat("%.0f t/min | bar %d (avg %.0f) | intens %.2f",Flow.TickRate(),Flow.Ticks(0),Flow.AvgTicks(20),Flow.Intensity()));

   string engTxt=(InpEngine==OFG2_ENG_AUTO?"AUTO":(InpEngine==OFG2_ENG_BOTH?"BOTH":(InpEngine==OFG2_ENG_FADE?"FADE":"FLOW")));
   Panel.SetValue("eng",StringFormat("%s -> %s | z fade%.1f flow%.1f",engTxt,RegimeText(),InpFadeZ,InpFlowZ));
   Panel.SetValue("score",StringFormat("last %.2f | gate>=%.2f | full>=%.2f",g_lastScore,InpMinScore,InpScoreFullSize));
   Panel.SetValue("last",StringSubstr(g_lastSignal,0,48));
   Panel.SetValue("block",g_lastBlock,(g_lastBlock=="-"?C'120,230,150':C'240,160,90'));

   if(FindPosition() && PositionSelectByTicket(g_posTicket))
     {
      double vol=PositionGetDouble(POSITION_VOLUME);
      double pnl=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      double pe=PositionGetDouble(POSITION_PRICE_OPEN);
      double px=(g_posDir>0?DbgBid(_Symbol):DbgAsk(_Symbol));
      double rr=(g_posRisk>0.0?(g_posDir>0?px-pe:pe-px)/g_posRisk:0.0);
      Panel.SetValue("pos",StringFormat("%s %s %.2f @ %s %+.2fR (%s)",g_posEngine,(g_posDir>0?"LONG":"SHORT"),vol,DbgPriceStr(_Symbol,pe),rr,DbgMoney(pnl)),
                     (pnl>=0?C'120,230,150':C'240,130,130'));
      Panel.SetValue("sltp",StringFormat("%s / %s  %s%s",DbgPriceStr(_Symbol,PositionGetDouble(POSITION_SL)),DbgPriceStr(_Symbol,PositionGetDouble(POSITION_TP)),
                     (g_tp1Done?"[TP1] ":""),(g_beDone?"[BE]":"")));
     }
   else
     {
      Panel.SetValue("pos","flat",C'170,180,195');
      Panel.SetValue("sltp",StringFormat("TP1 %.2fR (%.0f%%) | TP2 %.2fR | trail %.1fxATR",InpTp1R,InpTp1ClosePct,InpTp2R,InpTrailAtrMult));
     }

   DbgNewsEvent ev; int resume=0,toEv=0;
   if(!InpNewsEnabled) Panel.SetValue("nstat","DISABLED",C'150,160,175');
   else if(News.IsBlocked(TimeTradeServer(),ev,resume))
      Panel.SetValue("nstat",StringFormat("LOCKED - %s %s | resume in %s",ev.currency,CDbgNews::ImpText(ev.importance),DbgDuration(resume)),C'250,110,110');
   else Panel.SetValue("nstat","CLEAR - trading allowed",C'120,230,150');
   if(News.NextEvent(TimeTradeServer(),ev,toEv))
     {
      bool sameDay=((long)ev.time/86400==(long)TimeTradeServer()/86400);
      string when=(sameDay?DbgHM(ev.time):TimeToString(ev.time,TIME_DATE|TIME_MINUTES));
      Panel.SetValue("nnext",StringFormat("%s %s %s %s (in %s)",when,ev.currency,CDbgNews::ImpText(ev.importance),StringSubstr(ev.name,0,20),DbgDuration(toEv)));
     }
   else Panel.SetValue("nnext",News.Total()>0?"none left":"no data ("+News.LastError()+")");
   Panel.SetValue("nwin",StringFormat("-%d / +%d min | %s | %d events",InpNewsMinsBefore,InpNewsMinsAfter,News.CurrencyText(),News.Total()));

   Panel.SetValue("acc",StringFormat("Bal %s | Eq %s",DbgMoney(AccountInfoDouble(ACCOUNT_BALANCE)),DbgMoney(AccountInfoDouble(ACCOUNT_EQUITY))));
   double dayPct=(g_dayStartBal>0.0?g_dayPnl/g_dayStartBal*100.0:0.0);
   Panel.SetValue("day",StringFormat("%s (%.2f%%) | %d/%d trades",DbgMoney(g_dayPnl),dayPct,g_tradesToday,InpMaxTradesPerDay),
                  (g_dayPnl>0?C'120,230,150':(g_dayPnl<0?C'240,130,130':C'225,230,238')));
   int closed=g_wins+g_losses;
   double wr=(closed>0?(double)g_wins/closed*100.0:0.0);
   double avgW=(g_wins>0?g_sumWin/g_wins:0.0),avgL=(g_losses>0?g_sumLoss/g_losses:0.0);
   double payoff=(avgL>0.0?avgW/avgL:0.0);
   double needWr=(payoff>0.0?100.0/(1.0+payoff):100.0/(1.0+InpTp1R));
   Panel.SetValue("wr",StringFormat("%.0f%% (%dW/%dL) | payoff %.2f | need %.0f%%",wr,g_wins,g_losses,payoff,needWr),
                  (closed>=5 && wr>=needWr?C'120,230,150':C'240,200,90'));
   string szTxt=(InpSizing==OFG2_SZ_FIXEDPCT?"fixed":(InpSizing==OFG2_SZ_META?"meta-scaled":"Kelly"));
   double kmult=(InpSizing==OFG2_SZ_KELLY?KellyFraction():1.0);
   Panel.SetValue("kelly",StringFormat("%s | base %.2f%% (cap %.2f%%) | Kx%.2f",szTxt,InpRiskPercent,InpMaxRiskPercent,kmult));
   Panel.SetValue("guard",StringFormat("streak %d/%d | cooldown %dm | DD %.1f%%",g_consecLoss,InpMaxConsecLosses,InpCooldownMin,InpDailyLossPct));

   string reason="";
   if(g_paused)                     Panel.SetStatus("PAUSED (manual)",C'240,200,90');
   else if(!TradingAllowed(reason)) Panel.SetStatus(StringSubstr("STANDBY: "+reason,0,46),C'240,160,90');
   else                             Panel.SetStatus("ACTIVE - "+RegimeText(),C'120,230,150');
   Panel.Redraw();
  }

//+------------------------------------------------------------------+
void DrawVwap(void)
  {
   if(!InpShowVwap) return;
   double v=Flow.Vwap();
   string nm=OFG2_VWAP_LINE;
   if(v<=0.0) { ObjectDelete(0,nm); return; }
   if(ObjectFind(0,nm)<0) ObjectCreate(0,nm,OBJ_HLINE,0,0,v);
   ObjectSetDouble(0,nm,OBJPROP_PRICE,v);
   ObjectSetInteger(0,nm,OBJPROP_COLOR,C'110,180,255');
   ObjectSetInteger(0,nm,OBJPROP_STYLE,STYLE_DOT);
   ObjectSetInteger(0,nm,OBJPROP_BACK,true);
   ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,nm,OBJPROP_HIDDEN,true);
   ObjectSetString(0,nm,OBJPROP_TOOLTIP,"Session VWAP");
  }

//+------------------------------------------------------------------+
int OnInit(void)
  {
   trade.SetExpertMagicNumber((ulong)InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   hAtr=iATR(_Symbol,InpTF,14);
   if(hAtr==INVALID_HANDLE) { Print("[OFGv2] ATR handle error"); return(INIT_FAILED); }

   TZ.Init(_Symbol,InpManualOffsetHours,InpManualOffset);
   News.Configure(InpNewsEnabled,InpNewsCurrencies,_Symbol,InpNewsImportance,
                  InpNewsMinsBefore,InpNewsMinsAfter,InpNewsUseCsv,InpNewsCsvFile,
                  InpNewsCsvCommon,InpNewsReloadMin,InpNewsShiftMinutes);
   News.Refresh(true);
   Flow.Init(_Symbol,InpTF,InpFlowBars,InpFlowSource,InpFlowClass,InpTickBatch,InpVpinWindow,InpVpinBucketTicks);

   ComputeWindow();
   if(InpShowPanel) { BuildPanel(); Panel.SetPaused(g_paused); }
   g_dayStartBal=AccountInfoDouble(ACCOUNT_BALANCE);
   EventSetTimer(1);

   Log(StringFormat("init v2 | %s | window %s-%s %s | engine %d | regime %s | news %s",
       TZ.ZoneLabel(),InpTradeStart,InpTradeEnd,(InpTimeBase==DBG_TB_GMT?"GMT":"srv"),
       (int)InpEngine,(InpUseRegime?"ON":"OFF"),(InpNewsEnabled?"ON":"OFF")));
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(hAtr!=INVALID_HANDLE) IndicatorRelease(hAtr);
   Panel.Destroy();
   ObjectDelete(0,OFG2_VWAP_LINE);
   Comment("");
  }

//+------------------------------------------------------------------+
void OnTick(void)
  {
   double buf[];
   if(CopyBuffer(hAtr,0,1,1,buf)<1) return;
   g_atr=buf[0];
   if(g_atr<=0.0) return;

   ComputeWindow();
   Flow.Update();
   News.Refresh(false);
   UpdateStats();

   ManagePosition();
   HandleExits();

   datetime bt=(datetime)SeriesInfoInteger(_Symbol,InpTF,SERIES_LASTBAR_DATE);
   if(bt!=g_lastBar)
     {
      g_lastBar=bt;
      UpdateRegime();
      if(!g_paused) CheckSignals();
      DrawVwap();
     }
   UpdatePanel();
  }

//+------------------------------------------------------------------+
void OnTimer(void)
  {
   TZ.Refresh(false);
   Flow.Update();
   UpdatePanel();
  }

//+------------------------------------------------------------------+
void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
  {
   if(id!=CHARTEVENT_OBJECT_CLICK) return;
   if(sparam==OFG2_BTN_PAUSE)
     { g_paused=!g_paused; Panel.SetPaused(g_paused); Log(g_paused?"PAUSED":"RESUMED"); UpdatePanel(); }
   else if(sparam==OFG2_BTN_CLOSE)
     { ObjectSetInteger(0,OFG2_BTN_CLOSE,OBJPROP_STATE,false); CloseAll("manual button"); UpdatePanel(); }
   else if(sparam==OFG2_BTN_MIN) Panel.ToggleMinimize();
  }
//+------------------------------------------------------------------+
