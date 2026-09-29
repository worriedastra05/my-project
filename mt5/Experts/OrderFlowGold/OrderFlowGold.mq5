//+------------------------------------------------------------------+
//|                                                  OrderFlowGold.mq5 |
//|        ORDER FLOW SCALPER  -  XAUUSD / M5  (high hit-rate mode)   |
//|                                                                   |
//|  Two order-flow engines on the M5 chart:                          |
//|                                                                   |
//|  A) FLOW CONTINUATION  ("bada move")                              |
//|     Aggressive one-sided flow (delta z-score) + an efficient      |
//|     candle + micro structure break  ->  join the flow, TP1 small, |
//|     runner trails so the big extension is still captured.         |
//|                                                                   |
//|  B) ABSORPTION FADE    ("chhota move", high win rate)             |
//|     New N-bar extreme, extreme one-sided delta, but the price     |
//|     does NOT follow (low efficiency) and the bar closes back      |
//|     inside -> the aggressive side is being absorbed by passive    |
//|     limit orders -> fade it back towards VWAP with a tight TP.    |
//|                                                                   |
//|  Research base:                                                   |
//|   - Cont, Kukanov & Stoikov (2014), "The Price Impact of Order    |
//|     Book Events", SSRN 1712822: short-horizon price changes are   |
//|     ~linear in Order Flow Imbalance, slope ~ 1/depth. Absorption  |
//|     = large OFI with small price change = unusually deep book.    |
//|   - Cartea, Donnelly & Jaimungal, SSRN 2668277: volume imbalance  |
//|     predicts the next market-order side and the post-trade move.  |
//|   - Vafin (2026), SSRN 6938742: OFI short-horizon return          |
//|     predictability framework with realistic cost modelling.       |
//|   - Kethan S E (2026), SSRN 7053198: OFI has real IC but a raw    |
//|     10-second implementation dies on costs (net Sharpe -1.7).     |
//|     => trade M5 bars, demand TP >> spread, cap spread vs ATR.     |
//|   - Lee & Ready (1991) quote rule for trade-side classification.  |
//|                                                                   |
//|  Plus: broker timezone/DST detection, MT5 calendar news filter    |
//|  (off X min before / on X min after) and a full order-flow panel. |
//+------------------------------------------------------------------+
#property copyright "Order Flow Gold EA"
#property link      "https://papers.ssrn.com/sol3/papers.cfm?abstract_id=1712822"
#property version   "1.00"
#property description "Order-flow scalper for gold: delta/CVD/absorption on M5, tight TP, news filter, full dashboard."

#include <Trade/Trade.mqh>

#include "../DoubleBreakoutGold/DBG_Utils.mqh"
#include "../DoubleBreakoutGold/DBG_TimeZone.mqh"
#include "../DoubleBreakoutGold/DBG_News.mqh"
#include "OFG_Flow.mqh"
#include "OFG_Panel.mqh"

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+
enum ENUM_OFG_ENGINE
  {
   OFG_ENG_BOTH = 0, // Both engines (fade + continuation)
   OFG_ENG_FADE = 1, // Absorption fade only (highest win rate)
   OFG_ENG_FLOW = 2  // Flow continuation only
  };

enum ENUM_OFG_SL
  {
   OFG_SL_STRUCT = 0, // Signal bar structure + buffer
   OFG_SL_ATR    = 1  // Pure ATR multiple
  };

input group "=== 1. GENERAL ==="
input long             InpMagic            = 20260930;   // Magic number
input string           InpComment          = "OrderFlowGold"; // Order comment
input ENUM_TIMEFRAMES  InpTF               = PERIOD_M5;  // Signal timeframe
input double           InpMaxSpreadAtrPct  = 10.0;       // Max spread as % of ATR (0=off)
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

input group "=== 3. ORDER FLOW ENGINE ==="
input ENUM_OFG_SOURCE  InpFlowSource       = OFG_SRC_AUTO; // Flow data source
input int              InpFlowBars         = 300;        // Flow history (bars)
input int              InpZLookback        = 96;         // Delta z-score lookback (bars)
input int              InpTickBatch        = 3000;       // Max ticks processed per update
input int              InpCvdSlopeBars     = 6;          // CVD slope window (bars)

input group "=== 4. ENGINE A : FLOW CONTINUATION ==="
input ENUM_OFG_ENGINE  InpEngine           = OFG_ENG_BOTH; // Which engines are active
input double           InpFlowZ            = 1.80;       // Min |delta z-score|
input double           InpFlowMinBodyAtr   = 0.25;       // Min candle body (x ATR)
input double           InpFlowMinEff       = 0.55;       // Min price efficiency (flow really moves price)
input bool             InpFlowNeedCvd      = true;       // CVD slope must agree
input bool             InpFlowNeedBreak    = true;       // Must break the previous bar high/low

input group "=== 5. ENGINE B : ABSORPTION FADE ==="
input int              InpFadeLookback     = 12;         // New extreme lookback (bars)
input double           InpFadeZ            = 1.80;       // Min |delta z-score| against the move
input double           InpFadeClosePos     = 0.60;       // Min close position inside the bar (0..1)
input double           InpFadeMaxEff       = 0.50;       // Max efficiency (= absorption)
input double           InpFadeVwapSigma    = 0.80;       // Min distance from VWAP (x sigma, 0=off)

input group "=== 6. RISK / SL / TP  (low RR, high hit rate) ==="
input double           InpRiskPercent      = 0.35;       // Risk per trade (% balance, 0=fixed lot)
input double           InpFixedLots        = 0.01;       // Fixed lot when risk % = 0
input ENUM_OFG_SL      InpSlMode           = OFG_SL_STRUCT; // Stop-loss placement
input double           InpSlBufferAtr      = 0.20;       // Structure buffer (x ATR)
input double           InpAtrSlMult        = 1.10;       // ATR stop multiplier
input double           InpMinStopAtr       = 0.55;       // Min stop distance (x ATR)
input double           InpMaxStopAtr       = 1.80;       // Max stop distance (x ATR)
input double           InpTp1R             = 0.60;       // TP1 (R) - the high-probability target
input double           InpTp1ClosePct      = 70.0;       // % closed at TP1
input double           InpTp2R             = 2.20;       // TP2 / runner target (R)
input bool             InpUseBreakeven     = true;       // SL to breakeven after TP1
input double           InpBeLockR          = 0.05;       // Locked profit at BE (R)
input bool             InpUseTrailing      = true;       // ATR trailing for the runner
input double           InpTrailStartR      = 0.90;       // Trail starts after (R)
input double           InpTrailAtrMult     = 1.20;       // Trail distance (x ATR)
input int              InpTimeStopBars     = 12;         // Time stop (bars, 0=off)
input double           InpTimeStopMinR     = 0.15;       // ...only if trade is below this R

input group "=== 7. DAILY GUARDS ==="
input int              InpMaxTradesPerDay  = 8;          // Max trades per day
input int              InpCooldownMin      = 8;          // Cooldown after a trade (minutes)
input int              InpMaxConsecLosses  = 4;          // Stop after N losses in a row (0=off)
input double           InpDailyLossPct     = 2.5;        // Daily loss limit (%, 0=off)
input double           InpDailyProfitPct   = 0.0;        // Daily profit target (%, 0=off)
input double           InpMinAtrPoints     = 0;          // Min ATR in points (0=off, skip dead market)

input group "=== 8. NEWS FILTER (MT5 ECONOMIC CALENDAR) ==="
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

input group "=== 9. DASHBOARD ==="
input bool             InpShowPanel        = true;       // Show dashboard
input ENUM_BASE_CORNER InpPanelCorner      = CORNER_LEFT_UPPER; // Corner
input int              InpPanelX           = 12;         // Panel X
input int              InpPanelY           = 100;        // Panel Y
input int              InpPanelWidth       = 480;        // Panel width
input int              InpPanelFontSize    = 8;          // Font size
input string           InpPanelFont        = "Consolas"; // Font
input bool             InpShowVwap         = true;       // Draw session VWAP line

//+------------------------------------------------------------------+
//| GLOBALS                                                          |
//+------------------------------------------------------------------+
CTrade        trade;
CDbgTimeZone  TZ;
CDbgNews      News;
COfgFlow      Flow;
COfgPanel     Panel;

int      hAtr = INVALID_HANDLE;
double   g_atr = 0.0;

datetime g_lastBar      = 0;
datetime g_tradeStartSrv= 0;
datetime g_tradeEndSrv  = 0;
datetime g_flattenSrv   = 0;
datetime g_sessionAnchor= 0;
datetime g_lastTradeTime= 0;

ulong    g_posTicket  = 0;
int      g_posDir     = 0;
double   g_posEntry   = 0.0;
double   g_posRisk    = 0.0;
datetime g_posOpened  = 0;
bool     g_beDone     = false;
bool     g_tp1Done    = false;
string   g_posEngine  = "";

datetime g_statDay      = 0;
int      g_tradesToday  = 0;
int      g_wins         = 0;
int      g_losses       = 0;
int      g_consecLoss   = 0;
double   g_dayPnl       = 0.0;
double   g_dayStartBal  = 0.0;
double   g_sumWin       = 0.0;
double   g_sumLoss      = 0.0;
bool     g_halted       = false;
string   g_haltReason   = "";

bool     g_paused       = false;
string   g_lastSignal   = "-";
string   g_lastBlock    = "-";

#define OFG_VWAP_LINE  OFG_PREFIX+"vwap"

//--- forward declarations
void   OfgLog(const string msg);
bool   FindPosition(void);
void   CloseAll(const string why);
bool   TradingAllowed(string &reason);
void   UpdateStats(void);
void   ManagePosition(void);
void   BuildPanel(void);
void   UpdatePanel(void);
double CalcLots(const double stopDist);
double NormalizeLots(double lots);
bool   OpenTrade(const int dir,const double sl,const string engine,const string why);
void   CheckSignals(void);
void   ComputeWindow(void);

//+------------------------------------------------------------------+
void OfgLog(const string msg)
  {
   if(InpVerboseLog) Print("[OFG] ",msg);
  }

//+------------------------------------------------------------------+
int ParseHM2(const string hm,const int fallback)
  {
   string p[];
   if(StringSplit(hm,StringGetCharacter(":",0),p)<2) return(fallback);
   int h=(int)StringToInteger(p[0]), m=(int)StringToInteger(p[1]);
   if(h<0||h>23||m<0||m>59) return(fallback);
   return(h*3600+m*60);
  }

datetime CfgToSrv(const datetime t) { return(InpTimeBase==DBG_TB_SERVER ? t : TZ.ToServer(t)); }
datetime SrvToCfg(const datetime t) { return(InpTimeBase==DBG_TB_SERVER ? t : TZ.ToGmt(t)); }

//+------------------------------------------------------------------+
void ComputeWindow(void)
  {
   int s  = ParseHM2(InpTradeStart,6*3600);
   int e  = ParseHM2(InpTradeEnd,20*3600);
   int f  = ParseHM2(InpFlattenTime,20*3600+2700);

   datetime nowCfg = SrvToCfg(TimeTradeServer());
   datetime day    = nowCfg-(datetime)(nowCfg%86400);

   datetime st = day+(datetime)s;
   datetime en = day+(datetime)e;   if(e<=s) en += 86400;
   datetime fl = day+(datetime)f;   if(f<=s) fl += 86400;
   if(fl<en) fl = en;

   g_tradeStartSrv = CfgToSrv(st);
   g_tradeEndSrv   = CfgToSrv(en);
   g_flattenSrv    = CfgToSrv(fl);

   //--- VWAP / CVD anchor = start of the trading window
   if(g_sessionAnchor!=g_tradeStartSrv)
     {
      g_sessionAnchor = g_tradeStartSrv;
      Flow.ResetSession(g_sessionAnchor);
     }
  }

//+------------------------------------------------------------------+
bool IsTradingDay2(void)
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
   g_posTicket = 0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      g_posTicket = tk;
      g_posDir    = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY ? 1 : -1);
      g_posEntry  = PositionGetDouble(POSITION_PRICE_OPEN);
      return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
void CloseAll(const string why)
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if(trade.PositionClose(tk,InpSlippage)) OfgLog("closed #"+IntegerToString((int)tk)+" ("+why+")");
     }
  }

//+------------------------------------------------------------------+
double NormalizeLots(double lots)
  {
   double mn = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double mx = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double st = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(st<=0.0) st=0.01;
   lots = MathFloor(lots/st+0.0000001)*st;
   if(lots<mn) lots=mn;
   if(lots>mx) lots=mx;
   return(NormalizeDouble(lots,2));
  }

//+------------------------------------------------------------------+
double CalcLots(const double stopDist)
  {
   if(InpRiskPercent<=0.0 || stopDist<=0.0) return(NormalizeLots(InpFixedLots));
   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE)*InpRiskPercent/100.0;
   double tv = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tv<=0.0 || ts<=0.0) return(NormalizeLots(InpFixedLots));
   double lossPerLot = stopDist/ts*tv;
   if(lossPerLot<=0.0) return(NormalizeLots(InpFixedLots));
   return(NormalizeLots(riskMoney/lossPerLot));
  }

//+------------------------------------------------------------------+
bool TradingAllowed(string &reason)
  {
   reason = "";
   if(g_paused)                                     { reason="paused (manual)";      return(false); }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))           { reason="algo trading off";     return(false); }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) { reason="terminal blocked";     return(false); }
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))    { reason="account blocks EA";    return(false); }
   if(g_halted)                                     { reason=g_haltReason;           return(false); }
   if(!IsTradingDay2())                             { reason="day disabled";         return(false); }

   datetime now = TimeTradeServer();
   if(now<g_tradeStartSrv)                          { reason="before window ("+DbgHM(SrvToCfg(g_tradeStartSrv))+")"; return(false); }
   if(now>=g_tradeEndSrv)                           { reason="window closed";        return(false); }

   if(InpMaxTradesPerDay>0 && g_tradesToday>=InpMaxTradesPerDay) { reason="max trades/day"; return(false); }
   if(InpMaxConsecLosses>0 && g_consecLoss>=InpMaxConsecLosses)  { reason="loss streak";    return(false); }
   if(InpCooldownMin>0 && g_lastTradeTime>0 && (now-g_lastTradeTime)<(datetime)(InpCooldownMin*60))
     { reason="cooldown "+DbgDuration((int)(InpCooldownMin*60-(now-g_lastTradeTime))); return(false); }

   double sprPts = DbgSpreadPoints(_Symbol);
   if(InpMaxSpreadPoints>0 && sprPts>InpMaxSpreadPoints)
     { reason=StringFormat("spread %.0f pts",sprPts); return(false); }
   if(InpMaxSpreadAtrPct>0.0 && g_atr>0.0)
     {
      double pct = (DbgAsk(_Symbol)-DbgBid(_Symbol))/g_atr*100.0;
      if(pct>InpMaxSpreadAtrPct) { reason=StringFormat("spread %.1f%% ATR",pct); return(false); }
     }
   if(InpMinAtrPoints>0 && g_atr>0.0 && (g_atr/DbgPoint(_Symbol))<InpMinAtrPoints)
     { reason="ATR too low"; return(false); }

   DbgNewsEvent ev; int resume=0;
   if(News.IsBlocked(now,ev,resume))
     { reason="NEWS lock "+ev.currency+" ("+DbgDuration(resume)+")"; return(false); }

   return(true);
  }

//+------------------------------------------------------------------+
void UpdateStats(void)
  {
   datetime now = TimeTradeServer();
   datetime day = now-(datetime)(now%86400);
   if(g_statDay!=day)
     {
      g_statDay      = day;
      g_dayStartBal  = AccountInfoDouble(ACCOUNT_BALANCE);
      g_tradesToday  = 0; g_wins=0; g_losses=0; g_dayPnl=0.0;
      g_sumWin=0.0; g_sumLoss=0.0;
      g_halted=false; g_haltReason="";
     }
   if(!HistorySelect(day,now+60)) return;

   int trades=0,wins=0,losses=0,streak=0;
   double pnl=0.0,sw=0.0,sl=0.0;
   datetime lastOut=0;
   int total = HistoryDealsTotal();
   for(int i=0;i<total;i++)
     {
      ulong dl = HistoryDealGetTicket(i);
      if(dl==0) continue;
      if(HistoryDealGetString(dl,DEAL_SYMBOL)!=_Symbol) continue;
      if(HistoryDealGetInteger(dl,DEAL_MAGIC)!=InpMagic) continue;
      long entry = HistoryDealGetInteger(dl,DEAL_ENTRY);
      if(entry==DEAL_ENTRY_IN)
        {
         datetime dt = (datetime)HistoryDealGetInteger(dl,DEAL_TIME);
         if(dt>lastOut) lastOut = dt;
         trades++;
         continue;
        }
      if(entry!=DEAL_ENTRY_OUT && entry!=DEAL_ENTRY_OUT_BY) continue;
      double p = HistoryDealGetDouble(dl,DEAL_PROFIT)+HistoryDealGetDouble(dl,DEAL_SWAP)
                 +HistoryDealGetDouble(dl,DEAL_COMMISSION);
      pnl += p;
      if(p>0)      { wins++;   sw += p; streak=0; }
      else if(p<0) { losses++; sl += -p; streak++; }
     }
   g_tradesToday = trades;
   g_wins=wins; g_losses=losses; g_consecLoss=streak;
   g_dayPnl=pnl; g_sumWin=sw; g_sumLoss=sl;
   if(lastOut>g_lastTradeTime) g_lastTradeTime = lastOut;

   if(g_dayStartBal>0.0)
     {
      double pct = g_dayPnl/g_dayStartBal*100.0;
      if(InpDailyLossPct>0.0 && pct<=-InpDailyLossPct && !g_halted)
        { g_halted=true; g_haltReason=StringFormat("daily loss %.2f%%",pct); OfgLog("HALT "+g_haltReason); }
      if(InpDailyProfitPct>0.0 && pct>=InpDailyProfitPct && !g_halted)
        { g_halted=true; g_haltReason=StringFormat("daily target %.2f%%",pct); OfgLog("HALT "+g_haltReason); }
     }
  }

//+------------------------------------------------------------------+
bool OpenTrade(const int dir,const double slRaw,const string engine,const string why)
  {
   double price = (dir>0 ? DbgAsk(_Symbol) : DbgBid(_Symbol));
   double sl    = slRaw;

   //--- clamp the stop
   double dist    = MathAbs(price-sl);
   double minDist = MathMax(InpMinStopAtr*g_atr,DbgStopsLevelPrice(_Symbol)+(DbgAsk(_Symbol)-DbgBid(_Symbol)));
   double maxDist = InpMaxStopAtr*g_atr;
   if(maxDist>0.0 && dist>maxDist) dist = maxDist;
   if(dist<minDist)                dist = minDist;
   sl = DbgNormPrice(_Symbol,(dir>0 ? price-dist : price+dist));

   double tp = 0.0;
   if(InpTp2R>0.0) tp = DbgNormPrice(_Symbol,(dir>0 ? price+InpTp2R*dist : price-InpTp2R*dist));

   double lots = CalcLots(dist);
   if(lots<=0.0) { OfgLog("lot calc failed"); return(false); }

   bool ok = (dir>0 ? trade.Buy(lots,_Symbol,0.0,sl,tp,InpComment+" "+engine)
                    : trade.Sell(lots,_Symbol,0.0,sl,tp,InpComment+" "+engine));
   if(!ok)
     {
      OfgLog(StringFormat("order failed %d %s",trade.ResultRetcode(),trade.ResultRetcodeDescription()));
      return(false);
     }

   g_posRisk   = dist;
   g_posDir    = dir;
   g_posEntry  = price;
   g_posOpened = TimeTradeServer();
   g_beDone    = false;
   g_tp1Done   = false;
   g_posEngine = engine;
   g_lastTradeTime = TimeTradeServer();
   g_lastSignal = StringFormat("%s %s @ %s (%s)",engine,(dir>0?"BUY":"SELL"),DbgPriceStr(_Symbol,price),why);
   OfgLog(StringFormat("%s | lots %.2f | SL %s | TP %s | 1R=%.2f",g_lastSignal,lots,
                       DbgPriceStr(_Symbol,sl),DbgPriceStr(_Symbol,tp),dist));
   return(true);
  }

//+------------------------------------------------------------------+
//| Signal engines - one call per closed M5 bar                      |
//+------------------------------------------------------------------+
void CheckSignals(void)
  {
   if(FindPosition()) return;

   string reason="";
   if(!TradingAllowed(reason)) { g_lastBlock = reason; return; }
   g_lastBlock = "-";

   MqlRates r[];
   ArraySetAsSeries(r,true);
   int need = (InpFadeLookback+4>8 ? InpFadeLookback+4 : 8);
   if(CopyRates(_Symbol,InpTF,0,need,r)<need) return;
   if(!Flow.Valid(1)) return;

   double o1=r[1].open, h1=r[1].high, l1=r[1].low, c1=r[1].close;
   double rng = h1-l1;
   if(rng<=0.0) return;

   double z    = Flow.DeltaZ(1,InpZLookback);
   double eff  = Flow.Efficiency(1);
   double cvdS = Flow.CvdSlope(InpCvdSlopeBars);
   double vwap = Flow.Vwap();
   double sig  = Flow.VwapSigma();
   double buf  = MathMax(InpSlBufferAtr*g_atr,2.0*DbgPoint(_Symbol));

   //================================================================
   // ENGINE B : ABSORPTION FADE   (tight TP, high hit rate)
   //================================================================
   if(InpEngine==OFG_ENG_BOTH || InpEngine==OFG_ENG_FADE)
     {
      //--- lowest low / highest high of the N bars BEFORE the signal bar
      double lowestPrev=DBL_MAX, highestPrev=-DBL_MAX;
      for(int i=2;i<=InpFadeLookback+1 && i<ArraySize(r);i++)
        {
         lowestPrev  = MathMin(lowestPrev,r[i].low);
         highestPrev = MathMax(highestPrev,r[i].high);
        }

      double closePos = (c1-l1)/rng;          // 1 = closed on the high

      //--- BUY fade: new low, heavy selling, price refuses to follow
      bool newLow   = (l1<lowestPrev);
      bool sellFlow = (z<=-InpFadeZ);
      bool rejected = (closePos>=InpFadeClosePos);
      bool absorbed = (eff<=InpFadeMaxEff);
      bool farVwap  = (InpFadeVwapSigma<=0.0 || sig<=0.0 || (vwap-c1)>=InpFadeVwapSigma*sig);
      if(newLow && sellFlow && rejected && absorbed && farVwap)
        {
         double sl = (InpSlMode==OFG_SL_ATR ? DbgBid(_Symbol)-InpAtrSlMult*g_atr : l1-buf);
         if(OpenTrade(1,sl,"FADE",StringFormat("z%.1f eff%.2f",z,eff))) return;
        }

      //--- SELL fade
      bool newHigh  = (h1>highestPrev);
      bool buyFlow  = (z>=InpFadeZ);
      bool rejected2= ((h1-c1)/rng>=InpFadeClosePos);
      bool farVwap2 = (InpFadeVwapSigma<=0.0 || sig<=0.0 || (c1-vwap)>=InpFadeVwapSigma*sig);
      if(newHigh && buyFlow && rejected2 && absorbed && farVwap2)
        {
         double sl = (InpSlMode==OFG_SL_ATR ? DbgAsk(_Symbol)+InpAtrSlMult*g_atr : h1+buf);
         if(OpenTrade(-1,sl,"FADE",StringFormat("z%.1f eff%.2f",z,eff))) return;
        }
     }

   //================================================================
   // ENGINE A : FLOW CONTINUATION  (runner catches the big move)
   //================================================================
   if(InpEngine==OFG_ENG_BOTH || InpEngine==OFG_ENG_FLOW)
     {
      double body = MathAbs(c1-o1);
      bool bigBody= (body>=InpFlowMinBodyAtr*g_atr);
      bool efficient = (eff>=InpFlowMinEff);

      //--- BUY continuation
      bool upFlow  = (z>=InpFlowZ && c1>o1);
      bool upBreak = (!InpFlowNeedBreak || c1>r[2].high);
      bool upCvd   = (!InpFlowNeedCvd || cvdS>0.0);
      if(upFlow && bigBody && efficient && upBreak && upCvd)
        {
         double sl = (InpSlMode==OFG_SL_ATR ? DbgBid(_Symbol)-InpAtrSlMult*g_atr
                                            : MathMin(l1,r[2].low)-buf);
         if(OpenTrade(1,sl,"FLOW",StringFormat("z%.1f eff%.2f",z,eff))) return;
        }

      //--- SELL continuation
      bool dnFlow  = (z<=-InpFlowZ && c1<o1);
      bool dnBreak = (!InpFlowNeedBreak || c1<r[2].low);
      bool dnCvd   = (!InpFlowNeedCvd || cvdS<0.0);
      if(dnFlow && bigBody && efficient && dnBreak && dnCvd)
        {
         double sl = (InpSlMode==OFG_SL_ATR ? DbgAsk(_Symbol)+InpAtrSlMult*g_atr
                                            : MathMax(h1,r[2].high)+buf);
         if(OpenTrade(-1,sl,"FLOW",StringFormat("z%.1f eff%.2f",z,eff))) return;
        }
     }
  }

//+------------------------------------------------------------------+
//| Position management: TP1 partial, BE, trail, time stop           |
//+------------------------------------------------------------------+
void ManagePosition(void)
  {
   if(!FindPosition()) { g_tp1Done=false; g_beDone=false; g_posRisk=0.0; return; }
   if(!PositionSelectByTicket(g_posTicket)) return;

   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl    = PositionGetDouble(POSITION_SL);
   double tp    = PositionGetDouble(POSITION_TP);
   double vol   = PositionGetDouble(POSITION_VOLUME);
   int    dir   = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY ? 1 : -1);
   double price = (dir>0 ? DbgBid(_Symbol) : DbgAsk(_Symbol));
   if(g_posRisk<=0.0 && sl>0.0) g_posRisk = MathAbs(entry-sl);
   if(g_posRisk<=0.0) return;
   if(g_posOpened==0) g_posOpened = (datetime)PositionGetInteger(POSITION_TIME);

   double rNow = (dir>0 ? price-entry : entry-price)/g_posRisk;
   double minD = DbgStopsLevelPrice(_Symbol);

   //--- 1) TP1 partial
   if(InpTp1R>0.0 && !g_tp1Done && rNow>=InpTp1R && InpTp1ClosePct>0.0 && InpTp1ClosePct<100.0)
     {
      double cv = NormalizeLots(vol*InpTp1ClosePct/100.0);
      double mn = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
      if(cv>=mn && (vol-cv)>=mn)
        {
         if(trade.PositionClosePartial(g_posTicket,cv,InpSlippage))
           { g_tp1Done=true; OfgLog(StringFormat("TP1 %.2fR - closed %.2f lots",rNow,cv)); }
        }
      else
        {
         //--- volume too small to split: take the whole trade at TP1
         if(trade.PositionClose(g_posTicket,InpSlippage))
           { OfgLog(StringFormat("TP1 %.2fR - full close (min lot)",rNow)); return; }
        }
     }

   //--- 2) breakeven right after TP1
   if(InpUseBreakeven && !g_beDone && g_tp1Done)
     {
      double nsl = DbgNormPrice(_Symbol,(dir>0 ? entry+InpBeLockR*g_posRisk : entry-InpBeLockR*g_posRisk));
      bool better = (dir>0 ? (sl<=0.0 || nsl>sl) : (sl<=0.0 || nsl<sl));
      bool valid  = (dir>0 ? (price-nsl)>minD : (nsl-price)>minD);
      if(better && valid && trade.PositionModify(g_posTicket,nsl,tp))
        { g_beDone=true; sl=nsl; OfgLog("breakeven set"); }
     }

   //--- 3) ATR trailing for the runner
   if(InpUseTrailing && rNow>=InpTrailStartR && g_atr>0.0)
     {
      double nsl = DbgNormPrice(_Symbol,(dir>0 ? price-InpTrailAtrMult*g_atr : price+InpTrailAtrMult*g_atr));
      bool better = (dir>0 ? (sl<=0.0 || nsl>sl+DbgPoint(_Symbol)) : (sl<=0.0 || nsl<sl-DbgPoint(_Symbol)));
      bool valid  = (dir>0 ? (price-nsl)>minD : (nsl-price)>minD);
      if(better && valid) trade.PositionModify(g_posTicket,nsl,tp);
     }

   //--- 4) time stop: flow did not deliver
   if(InpTimeStopBars>0 && g_posOpened>0)
     {
      int barsHeld = (int)((TimeTradeServer()-g_posOpened)/PeriodSeconds(InpTF));
      if(barsHeld>=InpTimeStopBars && rNow<InpTimeStopMinR && !g_tp1Done)
        {
         if(trade.PositionClose(g_posTicket,InpSlippage))
            OfgLog(StringFormat("time stop after %d bars (%.2fR)",barsHeld,rNow));
        }
     }
  }

//+------------------------------------------------------------------+
void HandleExits(void)
  {
   datetime now = TimeTradeServer();
   if(now>=g_flattenSrv && FindPosition()) { CloseAll("session flat"); return; }

   if(InpFridayCloseHour>0)
     {
      MqlDateTime g; ZeroMemory(g); TimeToStruct(TZ.GmtNow(),g);
      if(g.day_of_week==5 && g.hour>=InpFridayCloseHour && FindPosition())
        { CloseAll("friday flat"); return; }
     }

   if(InpNewsEnabled && InpNewsClosePos)
     {
      DbgNewsEvent ev;
      if(News.EventWithin(now,InpNewsCloseBefore*60,ev) && FindPosition())
         CloseAll("news "+ev.currency+" in "+IntegerToString(InpNewsCloseBefore)+"m");
     }
  }

//+------------------------------------------------------------------+
//| Dashboard                                                        |
//+------------------------------------------------------------------+
void BuildPanel(void)
  {
   Panel.Create(0,(int)InpPanelCorner,InpPanelX,InpPanelY,InpPanelWidth,InpPanelFontSize,InpPanelFont,
                "ORDER FLOW GOLD  v1.00   (M5 delta / absorption)");
   Panel.AddSection("CLOCK  &  TIMEZONE");
   Panel.AddRow("srv","Server time");
   Panel.AddRow("tz","Broker zone");
   Panel.AddRow("gmt","GMT / UTC");
   Panel.AddRow("world","World clock");
   Panel.AddRow("win","Trade window");

   Panel.AddSection("MARKET");
   Panel.AddRow("sym","Symbol / TF");
   Panel.AddRow("quote","Bid/Ask/Spr");
   Panel.AddRow("atr","ATR / spread");
   Panel.AddRow("vwap","Session VWAP");

   Panel.AddSection("ORDER  FLOW");
   Panel.AddRow("src","Data source");
   Panel.AddRow("delta","Bar delta");
   Panel.AddRow("cvd","CVD (session)");
   Panel.AddRow("ratio","Buy / Sell");
   Panel.AddRow("eff","Efficiency");
   Panel.AddRow("rate","Tick rate");

   Panel.AddSection("SIGNAL  ENGINE");
   Panel.AddRow("eng","Engines");
   Panel.AddRow("last","Last signal");
   Panel.AddRow("block","Blocked by");
   Panel.AddRow("pos","Position");
   Panel.AddRow("sltp","SL / TP");

   Panel.AddSection("NEWS  FILTER  (MT5 CALENDAR)");
   Panel.AddRow("nstat","Status");
   Panel.AddRow("nnext","Next event");
   Panel.AddRow("nwin","Window");

   Panel.AddSection("RISK  &  STATISTICS");
   Panel.AddRow("acc","Account");
   Panel.AddRow("day","Today");
   Panel.AddRow("wr","Win rate");
   Panel.AddRow("guard","Guards");
   Panel.Finish();
  }

//+------------------------------------------------------------------+
void UpdatePanel(void)
  {
   if(!InpShowPanel || !Panel.Created() || Panel.Minimized()) return;

   //--- clock
   Panel.SetValue("srv",DbgFull(TimeTradeServer()));
   Panel.SetValue("tz",TZ.ZoneLabel()+" | "+TZ.ZoneGuess());
   Panel.SetValue("gmt",DbgFull(TZ.GmtNow()));
   Panel.SetValue("world",TZ.CityLine()+"  ["+TZ.SessionLine()+"]");
   Panel.SetValue("win",StringFormat("%s - %s %s | flat %s",
                  DbgHM(SrvToCfg(g_tradeStartSrv)),DbgHM(SrvToCfg(g_tradeEndSrv)),
                  (InpTimeBase==DBG_TB_GMT?"GMT":"srv"),DbgHM(SrvToCfg(g_flattenSrv))));

   //--- market
   double spr    = DbgSpreadPoints(_Symbol);
   double sprPct = (g_atr>0.0 ? (DbgAsk(_Symbol)-DbgBid(_Symbol))/g_atr*100.0 : 0.0);
   bool   sprBad = (InpMaxSpreadAtrPct>0.0 && sprPct>InpMaxSpreadAtrPct);
   Panel.SetValue("sym",_Symbol+"  "+StringSubstr(EnumToString(InpTF),7));
   Panel.SetValue("quote",StringFormat("%s / %s   %.0f pts",DbgPriceStr(_Symbol,DbgBid(_Symbol)),
                  DbgPriceStr(_Symbol,DbgAsk(_Symbol)),spr),(sprBad?C'240,120,120':C'225,230,238'));
   Panel.SetValue("atr",StringFormat("ATR %.2f | spread %.1f%% of ATR (max %.0f%%)",g_atr,sprPct,InpMaxSpreadAtrPct),
                  (sprBad?C'240,120,120':C'225,230,238'));
   double vwap = Flow.Vwap(), vsig = Flow.VwapSigma();
   double dist = (vwap>0.0 && vsig>0.0 ? (DbgBid(_Symbol)-vwap)/vsig : 0.0);
   Panel.SetValue("vwap",(vwap>0.0 ? StringFormat("%s   price %+.2f sigma",DbgPriceStr(_Symbol,vwap),dist) : "building..."));

   //--- order flow
   double d1 = Flow.Delta(1), d0 = Flow.Delta(0);
   double z1 = Flow.DeltaZ(1,InpZLookback);
   double cvd= Flow.Cvd(), cvdS = Flow.CvdSlope(InpCvdSlopeBars);
   double eff= Flow.Efficiency(1);
   color  dcol = (d1>0 ? C'120,230,150' : (d1<0 ? C'240,130,130' : C'225,230,238'));
   Panel.SetValue("src",Flow.SourceText()+" | "+Flow.Status()+" | bars "+IntegerToString(Flow.Count()));
   Panel.SetValue("delta",StringFormat("closed %+.0f (z %+.2f) | live %+.0f",d1,z1,d0),dcol);
   Panel.SetValue("cvd",StringFormat("%+.0f | slope(%d) %+.0f",cvd,InpCvdSlopeBars,cvdS),
                  (cvdS>0 ? C'120,230,150' : (cvdS<0 ? C'240,130,130' : C'225,230,238')));
   Panel.SetValue("ratio",StringFormat("%.0f%% / %.0f%%  (%.0f vs %.0f ticks)",Flow.BuyPct(1),100.0-Flow.BuyPct(1),
                  Flow.BuyVol(1),Flow.SellVol(1)));
   Panel.SetValue("eff",StringFormat("%.2f  %s",eff,(eff<=InpFadeMaxEff ? "<- ABSORPTION" : (eff>=InpFlowMinEff ? "<- flow moves price" : ""))),
                  (eff<=InpFadeMaxEff ? C'240,200,90' : C'225,230,238'));
   Panel.SetValue("rate",StringFormat("%.0f ticks/min | bar ticks %d (avg %.0f)",Flow.TickRate(),Flow.Ticks(0),Flow.AvgTicks(20)));

   //--- signal
   string engTxt = (InpEngine==OFG_ENG_BOTH ? "FADE + FLOW" : (InpEngine==OFG_ENG_FADE ? "FADE only" : "FLOW only"));
   Panel.SetValue("eng",StringFormat("%s | z>=%.1f | fade look %d",engTxt,InpFlowZ,InpFadeLookback));
   Panel.SetValue("last",StringSubstr(g_lastSignal,0,46));
   Panel.SetValue("block",g_lastBlock,(g_lastBlock=="-" ? C'120,230,150' : C'240,160,90'));

   if(FindPosition() && PositionSelectByTicket(g_posTicket))
     {
      double vol = PositionGetDouble(POSITION_VOLUME);
      double pnl = PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      double pe  = PositionGetDouble(POSITION_PRICE_OPEN);
      double px  = (g_posDir>0 ? DbgBid(_Symbol) : DbgAsk(_Symbol));
      double rr  = (g_posRisk>0.0 ? (g_posDir>0 ? px-pe : pe-px)/g_posRisk : 0.0);
      Panel.SetValue("pos",StringFormat("%s %s %.2f @ %s  %+.2fR (%s)",g_posEngine,(g_posDir>0?"LONG":"SHORT"),
                     vol,DbgPriceStr(_Symbol,pe),rr,DbgMoney(pnl)),
                     (pnl>=0 ? C'120,230,150' : C'240,130,130'));
      Panel.SetValue("sltp",StringFormat("%s / %s  %s%s",DbgPriceStr(_Symbol,PositionGetDouble(POSITION_SL)),
                     DbgPriceStr(_Symbol,PositionGetDouble(POSITION_TP)),
                     (g_tp1Done?"[TP1] ":""),(g_beDone?"[BE]":"")));
     }
   else
     {
      Panel.SetValue("pos","flat",C'170,180,195');
      Panel.SetValue("sltp",StringFormat("TP1 %.2fR (%.0f%%) | TP2 %.2fR | trail %.1fxATR",
                     InpTp1R,InpTp1ClosePct,InpTp2R,InpTrailAtrMult));
     }

   //--- news
   DbgNewsEvent ev; int resume=0,toEv=0;
   if(!InpNewsEnabled) Panel.SetValue("nstat","DISABLED",C'150,160,175');
   else if(News.IsBlocked(TimeTradeServer(),ev,resume))
      Panel.SetValue("nstat",StringFormat("LOCKED - %s %s | resume in %s",ev.currency,
                     CDbgNews::ImpText(ev.importance),DbgDuration(resume)),C'250,110,110');
   else Panel.SetValue("nstat","CLEAR - trading allowed",C'120,230,150');

   if(News.NextEvent(TimeTradeServer(),ev,toEv))
     {
      bool sameDay = ((long)ev.time/86400 == (long)TimeTradeServer()/86400);
      string when  = (sameDay ? DbgHM(ev.time) : TimeToString(ev.time,TIME_DATE|TIME_MINUTES));
      Panel.SetValue("nnext",StringFormat("%s %s %s %s (in %s)",when,ev.currency,
                     CDbgNews::ImpText(ev.importance),StringSubstr(ev.name,0,20),DbgDuration(toEv)));
     }
   else Panel.SetValue("nnext",News.Total()>0 ? "none left" : "no data ("+News.LastError()+")");
   Panel.SetValue("nwin",StringFormat("-%d / +%d min | %s | %d events",InpNewsMinsBefore,InpNewsMinsAfter,
                  News.CurrencyText(),News.Total()));

   //--- risk & stats
   Panel.SetValue("acc",StringFormat("Bal %s | Eq %s | risk %.2f%%",
                  DbgMoney(AccountInfoDouble(ACCOUNT_BALANCE)),
                  DbgMoney(AccountInfoDouble(ACCOUNT_EQUITY)),InpRiskPercent));
   double dayPct = (g_dayStartBal>0.0 ? g_dayPnl/g_dayStartBal*100.0 : 0.0);
   Panel.SetValue("day",StringFormat("%s (%.2f%%) | %d/%d trades",DbgMoney(g_dayPnl),dayPct,
                  g_tradesToday,InpMaxTradesPerDay),
                  (g_dayPnl>0 ? C'120,230,150' : (g_dayPnl<0 ? C'240,130,130' : C'225,230,238')));
   int closed = g_wins+g_losses;
   double wr  = (closed>0 ? (double)g_wins/closed*100.0 : 0.0);
   double avgW= (g_wins>0 ? g_sumWin/g_wins : 0.0);
   double avgL= (g_losses>0 ? g_sumLoss/g_losses : 0.0);
   double payoff = (avgL>0.0 ? avgW/avgL : 0.0);
   double needWr = (payoff>0.0 ? 100.0/(1.0+payoff) : 100.0/(1.0+InpTp1R));
   Panel.SetValue("wr",StringFormat("%.0f%% (%dW/%dL) | payoff %.2f | need %.0f%%",wr,g_wins,g_losses,payoff,needWr),
                  (closed>=3 && wr>=needWr ? C'120,230,150' : C'240,200,90'));
   Panel.SetValue("guard",StringFormat("streak %d/%d | cooldown %dm | DD limit %.1f%%",
                  g_consecLoss,InpMaxConsecLosses,InpCooldownMin,InpDailyLossPct));

   //--- footer
   string reason="";
   if(g_paused)                     Panel.SetStatus("PAUSED (manual)",C'240,200,90');
   else if(!TradingAllowed(reason)) Panel.SetStatus(StringSubstr("STANDBY: "+reason,0,44),C'240,160,90');
   else                             Panel.SetStatus("ACTIVE - scanning order flow",C'120,230,150');

   Panel.Redraw();
  }

//+------------------------------------------------------------------+
void DrawVwap(void)
  {
   if(!InpShowVwap) return;
   double v = Flow.Vwap();
   string nm = OFG_VWAP_LINE;
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

   hAtr = iATR(_Symbol,InpTF,14);
   if(hAtr==INVALID_HANDLE) { Print("[OFG] ATR handle error"); return(INIT_FAILED); }

   TZ.Init(_Symbol,InpManualOffsetHours,InpManualOffset);
   News.Configure(InpNewsEnabled,InpNewsCurrencies,_Symbol,InpNewsImportance,
                  InpNewsMinsBefore,InpNewsMinsAfter,InpNewsUseCsv,InpNewsCsvFile,
                  InpNewsCsvCommon,InpNewsReloadMin,InpNewsShiftMinutes);
   News.Refresh(true);

   Flow.Init(_Symbol,InpTF,InpFlowBars,InpFlowSource,InpTickBatch);

   ComputeWindow();
   if(InpShowPanel) { BuildPanel(); Panel.SetPaused(g_paused); }

   g_dayStartBal = AccountInfoDouble(ACCOUNT_BALANCE);
   EventSetTimer(1);

   OfgLog(StringFormat("init | %s | window %s-%s %s | engines %d | news %s",
          TZ.ZoneLabel(),InpTradeStart,InpTradeEnd,(InpTimeBase==DBG_TB_GMT?"GMT":"srv"),
          (int)InpEngine,(InpNewsEnabled?"ON":"OFF")));
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(hAtr!=INVALID_HANDLE) IndicatorRelease(hAtr);
   Panel.Destroy();
   ObjectDelete(0,OFG_VWAP_LINE);
   Comment("");
  }

//+------------------------------------------------------------------+
void OnTick(void)
  {
   double buf[];
   if(CopyBuffer(hAtr,0,1,1,buf)<1) return;
   g_atr = buf[0];
   if(g_atr<=0.0) return;

   ComputeWindow();
   Flow.Update();
   News.Refresh(false);
   UpdateStats();

   ManagePosition();
   HandleExits();

   datetime bt = (datetime)SeriesInfoInteger(_Symbol,InpTF,SERIES_LASTBAR_DATE);
   if(bt!=g_lastBar)
     {
      g_lastBar = bt;
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
   if(sparam==OFG_BTN_PAUSE)
     {
      g_paused = !g_paused;
      Panel.SetPaused(g_paused);
      OfgLog(g_paused ? "PAUSED by user" : "RESUMED by user");
      UpdatePanel();
     }
   else if(sparam==OFG_BTN_CLOSE)
     {
      ObjectSetInteger(0,OFG_BTN_CLOSE,OBJPROP_STATE,false);
      CloseAll("manual button");
      UpdatePanel();
     }
   else if(sparam==OFG_BTN_MIN) Panel.ToggleMinimize();
  }
//+------------------------------------------------------------------+
