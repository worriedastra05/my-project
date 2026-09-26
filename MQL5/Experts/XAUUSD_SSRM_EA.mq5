//+------------------------------------------------------------------+
//|                                            XAUUSD_SSRM_EA.mq5     |
//|            Multi-Timeframe Gold EA (SSRM Combo Strategy)          |
//|   HTF Trend Bias  +  Support/Resistance  +  Liquidity Sweep      |
//|                                                                  |
//|   Enforces minimum 1:2 Risk-Reward.  On-chart Dashboard.         |
//|   Built for XAU/USD.  Keep it SIMPLE.                             |
//+------------------------------------------------------------------+
#property copyright "Arena.ai Agent"
#property version   "1.00"
#property strict
#property description "Gold multi-timeframe EA: HTF trend + S/R + liquidity sweep. Min 1:2 RR, daily trade limit, dashboard."

#include <Trade\Trade.mqh>
CTrade trade;

//====================================================================
//  INPUTS  (kept minimal & simple)
//====================================================================
input group    "=== General ==="
input long     InpMagic          = 20260926;   // Magic number
input string   InpComment        = "SSRM_EA";  // Order comment

input group    "=== Risk / Lot ==="
enum ENUM_LOT_MODE { LOT_AUTO_RISK=0, LOT_FIXED=1 };
input ENUM_LOT_MODE InpLotMode   = LOT_AUTO_RISK; // Lot mode
input double   InpRiskPercent    = 1.0;        // Risk % per trade (Auto mode)
input double   InpFixedLot       = 0.01;       // Fixed lot (Fixed mode)
input double   InpRiskReward     = 2.0;        // Risk:Reward (min 2 = 1:2)

input group    "=== Strategy ==="
input ENUM_TIMEFRAMES InpTrendTF = PERIOD_H1;  // Higher timeframe (trend bias)
input int      InpEmaFast        = 21;         // HTF EMA fast
input int      InpEmaSlow        = 50;         // HTF EMA slow
input int      InpLookback       = 20;         // S/R & liquidity lookback (bars)
input double   InpSLBufferPoints = 150;        // Extra SL buffer (points)

input group    "=== Trade Control ==="
input int      InpMaxTradesDay   = 4;          // Max trades per day (3-4)
input int      InpStartHour      = 7;          // Session start hour (server)
input int      InpEndHour        = 21;         // Session end hour (server)

//====================================================================
//  GLOBALS
//====================================================================
int      hEmaFast = INVALID_HANDLE;
int      hEmaSlow = INVALID_HANDLE;
datetime lastBarTime = 0;

// daily stats
int      tradesToday   = 0;
int      curDay        = -1;

// running stats (for dashboard win-rate estimate)
int      totalWins     = 0;
int      totalLosses   = 0;
int      lastDealsTotal= 0;

// dashboard prefix
string   PFX = "SSRM_";

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(50);
   trade.SetTypeFillingBySymbol(_Symbol);

   hEmaFast = iMA(_Symbol, InpTrendTF, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   hEmaSlow = iMA(_Symbol, InpTrendTF, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   if(hEmaFast==INVALID_HANDLE || hEmaSlow==INVALID_HANDLE)
   {
      Print("Failed to create EMA handles");
      return(INIT_FAILED);
   }

   // gentle warning if not gold
   if(StringFind(_Symbol,"XAU")<0)
      Print("WARNING: This EA is designed for XAU/USD (Gold). Current symbol: ", _Symbol);

   curDay = DayOfYearNow();
   CreateDashboard();
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hEmaFast!=INVALID_HANDLE) IndicatorRelease(hEmaFast);
   if(hEmaSlow!=INVALID_HANDLE) IndicatorRelease(hEmaSlow);
   ObjectsDeleteAll(0, PFX);
   Comment("");
}

//+------------------------------------------------------------------+
void OnTick()
{
   UpdateDailyCounter();
   UpdateStatsFromHistory();

   // manage dashboard every tick (cheap)
   UpdateDashboard();

   // work only on a new bar of the current (entry) timeframe
   datetime t = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(t==lastBarTime) return;
   lastBarTime = t;

   // one position at a time
   if(PositionOpen()) return;

   // session filter
   if(!InSession()) return;

   // daily limit
   if(tradesToday >= InpMaxTradesDay) return;

   int bias = TrendBias();          // +1 bull, -1 bear, 0 none
   if(bias==0) return;

   int signal = CheckSignal(bias);  // +1 buy, -1 sell, 0 none
   if(signal>0) ExecuteTrade(true);
   else if(signal<0) ExecuteTrade(false);
}

//====================================================================
//  STRATEGY
//====================================================================

//--- Higher-timeframe trend bias from EMA cross state
int TrendBias()
{
   double f[2], s[2];
   if(CopyBuffer(hEmaFast, 0, 0, 2, f)<2) return 0;
   if(CopyBuffer(hEmaSlow, 0, 0, 2, s)<2) return 0;
   if(f[0] > s[0]) return  1;   // bullish
   if(f[0] < s[0]) return -1;   // bearish
   return 0;
}

//--- Liquidity sweep + S/R rejection on entry timeframe.
//    Uses last CLOSED bar (index 1) against recent S/R (from lookback).
int CheckSignal(int bias)
{
   int    lb   = InpLookback;
   // recent support/resistance excluding the last 2 forming/closed bars
   int    hiIdx = iHighest(_Symbol, PERIOD_CURRENT, MODE_HIGH, lb, 2);
   int    loIdx = iLowest (_Symbol, PERIOD_CURRENT, MODE_LOW,  lb, 2);
   if(hiIdx<0 || loIdx<0) return 0;

   double resistance = iHigh(_Symbol, PERIOD_CURRENT, hiIdx);
   double support    = iLow (_Symbol, PERIOD_CURRENT, loIdx);

   double c1  = iClose(_Symbol, PERIOD_CURRENT, 1);
   double o1  = iOpen (_Symbol, PERIOD_CURRENT, 1);
   double h1  = iHigh (_Symbol, PERIOD_CURRENT, 1);
   double l1  = iLow  (_Symbol, PERIOD_CURRENT, 1);

   // BUY: HTF bullish + sweep BELOW support (grab sell-side liquidity)
   //      then CLOSE back above support (bullish rejection)
   if(bias>0)
   {
      bool swept    = (l1 < support);
      bool closedIn = (c1 > support);
      bool bullish  = (c1 > o1);
      if(swept && closedIn && bullish)
         return 1;
   }

   // SELL: HTF bearish + sweep ABOVE resistance (grab buy-side liquidity)
   //       then CLOSE back below resistance (bearish rejection)
   if(bias<0)
   {
      bool swept    = (h1 > resistance);
      bool closedIn = (c1 < resistance);
      bool bearish  = (c1 < o1);
      if(swept && closedIn && bearish)
         return -1;
   }

   return 0;
}

//====================================================================
//  EXECUTION
//====================================================================
void ExecuteTrade(bool isBuy)
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double buf   = InpSLBufferPoints * point;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double entry, sl, tp, riskDist;

   if(isBuy)
   {
      entry = ask;
      // SL below the sweep low of last closed bar
      double swLow = iLow(_Symbol, PERIOD_CURRENT, 1);
      sl = swLow - buf;
      riskDist = entry - sl;
      if(riskDist<=0) return;
      tp = entry + riskDist * MathMax(InpRiskReward, 2.0);
   }
   else
   {
      entry = bid;
      double swHigh = iHigh(_Symbol, PERIOD_CURRENT, 1);
      sl = swHigh + buf;
      riskDist = sl - entry;
      if(riskDist<=0) return;
      tp = entry - riskDist * MathMax(InpRiskReward, 2.0);
   }

   // normalize
   int dg = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   sl = NormalizeDouble(sl, dg);
   tp = NormalizeDouble(tp, dg);

   double lot = CalcLot(riskDist);
   if(lot<=0) return;

   bool ok;
   if(isBuy) ok = trade.Buy(lot, _Symbol, 0.0, sl, tp, InpComment);
   else      ok = trade.Sell(lot, _Symbol, 0.0, sl, tp, InpComment);

   if(ok)
   {
      tradesToday++;
      PrintFormat("%s trade opened. Lot=%.2f SL=%.2f TP=%.2f RR=%.1f",
                  (isBuy?"BUY":"SELL"), lot, sl, tp, MathMax(InpRiskReward,2.0));
   }
   else
      PrintFormat("Order failed: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
}

//--- Lot sizing: auto (risk %) or fixed
double CalcLot(double riskDistPrice)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(InpLotMode==LOT_FIXED)
      return NormalizeLot(InpFixedLot, minLot, maxLot, lotStep);

   // AUTO: risk % of balance
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * InpRiskPercent / 100.0;

   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize<=0 || tickVal<=0) return NormalizeLot(InpFixedLot, minLot, maxLot, lotStep);

   // money lost per 1.0 lot over the SL distance
   double lossPerLot = (riskDistPrice / tickSize) * tickVal;
   if(lossPerLot<=0) return minLot;

   double lot = riskMoney / lossPerLot;
   return NormalizeLot(lot, minLot, maxLot, lotStep);
}

double NormalizeLot(double lot, double minLot, double maxLot, double step)
{
   if(step<=0) step = 0.01;
   lot = MathFloor(lot/step)*step;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   return NormalizeDouble(lot, 2);
}

//====================================================================
//  HELPERS
//====================================================================
bool PositionOpen()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==InpMagic)
         return true;
   }
   return false;
}

int DayOfYearNow()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   return dt.day_of_year;
}

void UpdateDailyCounter()
{
   int d = DayOfYearNow();
   if(d!=curDay)
   {
      curDay = d;
      tradesToday = 0;
   }
}

bool InSession()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(InpStartHour <= InpEndHour)
      return (dt.hour>=InpStartHour && dt.hour<InpEndHour);
   // wrap around midnight
   return (dt.hour>=InpStartHour || dt.hour<InpEndHour);
}

//--- read closed deals of this EA to keep win/loss tally
void UpdateStatsFromHistory()
{
   if(!HistorySelect(0, TimeCurrent())) return;
   int total = HistoryDealsTotal();
   if(total==lastDealsTotal) return;

   totalWins=0; totalLosses=0;
   for(int i=0;i<total;i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket==0) continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC)!=InpMagic) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL)!=_Symbol) continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY)!=DEAL_ENTRY_OUT) continue;
      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT)
                    + HistoryDealGetDouble(ticket, DEAL_SWAP)
                    + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      if(profit>=0) totalWins++; else totalLosses++;
   }
   lastDealsTotal = total;
}

//====================================================================
//  DASHBOARD
//====================================================================
void Lbl(string name, string text, int x, int y, color clr, int size=9, string font="Consolas")
{
   string obj = PFX+name;
   if(ObjectFind(0,obj)<0)
   {
      ObjectCreate(0,obj,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,obj,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,obj,OBJPROP_XDISTANCE,x);
      ObjectSetInteger(0,obj,OBJPROP_YDISTANCE,y);
      ObjectSetInteger(0,obj,OBJPROP_FONTSIZE,size);
      ObjectSetString (0,obj,OBJPROP_FONT,font);
      ObjectSetInteger(0,obj,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,obj,OBJPROP_HIDDEN,true);
   }
   ObjectSetString (0,obj,OBJPROP_TEXT,text);
   ObjectSetInteger(0,obj,OBJPROP_COLOR,clr);
}

void Panel(int x,int y,int w,int h,color bg)
{
   string obj = PFX+"panel";
   if(ObjectFind(0,obj)<0)
   {
      ObjectCreate(0,obj,OBJ_RECTANGLE_LABEL,0,0,0);
      ObjectSetInteger(0,obj,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,obj,OBJPROP_XDISTANCE,x);
      ObjectSetInteger(0,obj,OBJPROP_YDISTANCE,y);
      ObjectSetInteger(0,obj,OBJPROP_XSIZE,w);
      ObjectSetInteger(0,obj,OBJPROP_YSIZE,h);
      ObjectSetInteger(0,obj,OBJPROP_BGCOLOR,bg);
      ObjectSetInteger(0,obj,OBJPROP_BORDER_TYPE,BORDER_FLAT);
      ObjectSetInteger(0,obj,OBJPROP_COLOR,clrDimGray);
      ObjectSetInteger(0,obj,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,obj,OBJPROP_HIDDEN,true);
   }
}

void CreateDashboard()
{
   Panel(10,20,270,300, C'20,24,33');
   Lbl("title","  SSRM GOLD EA  -  XAU/USD", 22, 28, clrGold, 11, "Consolas Bold");
   UpdateDashboard();
}

void UpdateDashboard()
{
   int bias   = TrendBias();
   string biasTxt = (bias>0? "BULLISH":(bias<0? "BEARISH":"NEUTRAL"));
   color  biasClr = (bias>0? clrLime:(bias<0? clrTomato:clrSilver));

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);

   int totalClosed = totalWins+totalLosses;
   double wr = (totalClosed>0)? (100.0*totalWins/totalClosed):0.0;

   bool pos = PositionOpen();

   int x=22, y=55, dy=20;
   Lbl("l0", "-----------------------------------", x, y-6, clrDimGray); 
   Lbl("l1", StringFormat("Symbol : %s", _Symbol), x, y+=dy, clrWhite);
   Lbl("l2", StringFormat("HTF    : %s   Entry: %s",
             EnumToString(InpTrendTF), EnumToString((ENUM_TIMEFRAMES)Period())), x, y+=dy, clrWhite);
   Lbl("l3", StringFormat("Trend  : %s", biasTxt), x, y+=dy, biasClr);
   Lbl("l4", StringFormat("Position: %s", (pos?"OPEN":"none")), x, y+=dy, (pos?clrYellow:clrSilver));
   Lbl("l5", StringFormat("Trades today: %d / %d", tradesToday, InpMaxTradesDay), x, y+=dy,
             (tradesToday>=InpMaxTradesDay?clrTomato:clrWhite));
   Lbl("l6", StringFormat("RR target : 1:%.1f", MathMax(InpRiskReward,2.0)), x, y+=dy, clrAqua);
   Lbl("l7", StringFormat("Lot mode  : %s", (InpLotMode==LOT_FIXED?"FIXED":"AUTO %")), x, y+=dy, clrWhite);
   if(InpLotMode==LOT_FIXED)
      Lbl("l8", StringFormat("Fixed lot : %.2f", InpFixedLot), x, y+=dy, clrWhite);
   else
      Lbl("l8", StringFormat("Risk/trade: %.2f %%", InpRiskPercent), x, y+=dy, clrWhite);
   Lbl("l9", StringFormat("Balance   : %.2f", bal), x, y+=dy, clrWhite);
   Lbl("l10",StringFormat("Equity    : %.2f", eq),  x, y+=dy, clrWhite);
   Lbl("l11",StringFormat("W/L       : %d / %d", totalWins, totalLosses), x, y+=dy, clrWhite);
   Lbl("l12",StringFormat("Win rate  : %.1f %%", wr), x, y+=dy, (wr>=70?clrLime:clrOrange));
   Lbl("l13",StringFormat("Session   : %s", (InSession()?"ACTIVE":"closed")), x, y+=dy,
             (InSession()?clrLime:clrSilver));
}
//+------------------------------------------------------------------+
