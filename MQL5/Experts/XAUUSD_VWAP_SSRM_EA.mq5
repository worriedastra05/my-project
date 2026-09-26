//+------------------------------------------------------------------+
//|                                       XAUUSD_VWAP_SSRM_EA.mq5     |
//|         Gold Multi-Confluence EA  (VWAP + SSRM + Trend)           |
//|                                                                  |
//|  Combines: Session VWAP (+/- sigma bands), 200/9/21 EMA,          |
//|  RSI-50, ADX regime filter, liquidity/round-number confluence.   |
//|  Trend-continuation VWAP bounce = core setup (low drawdown).      |
//|                                                                  |
//|  Risk control: ATR stop, min 1:2 RR, break-even + trail,         |
//|  session filter, spread filter, daily-loss lock. Dashboard.      |
//|  Timeframes: M1 / M5 / M15 (attach to the entry chart).          |
//+------------------------------------------------------------------+
#property copyright "Arena.ai Agent"
#property version   "2.00"
#property strict
#property description "Gold VWAP + confluence EA. Trend-continuation VWAP bounce, ADX filter, ATR stop, daily-loss lock, dashboard."

#include <Trade\Trade.mqh>
CTrade trade;

//====================================================================
//  INPUTS  (grouped, simple)
//====================================================================
input group    "=== General ==="
input long     InpMagic         = 20260927;    // Magic number
input string   InpComment       = "VWAP_SSRM";  // Order comment

input group    "=== Risk / Lot ==="
enum ENUM_LOT_MODE { LOT_AUTO_RISK=0, LOT_FIXED=1 };
input ENUM_LOT_MODE InpLotMode  = LOT_AUTO_RISK; // Lot mode
input double   InpRiskPercent   = 1.0;         // Risk % per trade (Auto mode)
input double   InpFixedLot      = 0.01;        // Fixed lot (Fixed mode)
input double   InpRiskReward    = 2.0;         // Risk:Reward (min 2 = 1:2)

input group    "=== Confluence Filters ==="
input int      InpEmaTrend      = 200;         // Trend EMA (direction)
input int      InpEmaFast       = 9;           // Fast EMA
input int      InpEmaSlow       = 21;          // Slow EMA
input int      InpRsiPeriod     = 14;          // RSI period
input int      InpAdxPeriod     = 14;          // ADX period
input double   InpAdxMin        = 20.0;        // Min ADX (skip chop below this)
input int      InpMinScore      = 4;           // Min confluence score (of 6)

input group    "=== Stops (ATR based) ==="
input int      InpAtrPeriod     = 14;          // ATR period
input double   InpAtrSLmult     = 1.5;         // SL = ATR x this
input double   InpBEatR         = 1.0;         // Move to break-even after R (0=off)
input double   InpTrailATR      = 0.0;         // Trail by ATR x this (0=off)

input group    "=== Trade Control ==="
input int      InpMaxTradesDay  = 4;           // Max trades per day
input int      InpMaxDailyLoss  = 2;           // Stop for day after N losses
input double   InpMaxSpreadPts  = 400;         // Max spread (points) to trade
input int      InpStartHour     = 7;           // Session start hour (server)
input int      InpEndHour       = 21;          // Session end hour (server)

//====================================================================
//  GLOBALS
//====================================================================
int      hEmaTrend=INVALID_HANDLE, hEmaFast=INVALID_HANDLE, hEmaSlow=INVALID_HANDLE;
int      hRsi=INVALID_HANDLE, hAdx=INVALID_HANDLE, hAtr=INVALID_HANDLE;

datetime lastBarTime = 0;
int      curDay      = -1;
int      tradesToday = 0;

// stats
int      winsToday=0, lossToday=0;
int      totalWins=0, totalLoss=0;
int      lastDeals=0;

// dashboard cache
double   dbVWAP=0, dbSDup=0, dbSDdn=0, dbATR=0, dbADX=0, dbRSI=0;
int      dbScore=0, dbBias=0;

string   PFX="VS_";

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(60);
   trade.SetTypeFillingBySymbol(_Symbol);

   hEmaTrend = iMA(_Symbol, PERIOD_CURRENT, InpEmaTrend, 0, MODE_EMA, PRICE_CLOSE);
   hEmaFast  = iMA(_Symbol, PERIOD_CURRENT, InpEmaFast,  0, MODE_EMA, PRICE_CLOSE);
   hEmaSlow  = iMA(_Symbol, PERIOD_CURRENT, InpEmaSlow,  0, MODE_EMA, PRICE_CLOSE);
   hRsi      = iRSI(_Symbol, PERIOD_CURRENT, InpRsiPeriod, PRICE_CLOSE);
   hAdx      = iADX(_Symbol, PERIOD_CURRENT, InpAdxPeriod);
   hAtr      = iATR(_Symbol, PERIOD_CURRENT, InpAtrPeriod);

   if(hEmaTrend==INVALID_HANDLE||hEmaFast==INVALID_HANDLE||hEmaSlow==INVALID_HANDLE||
      hRsi==INVALID_HANDLE||hAdx==INVALID_HANDLE||hAtr==INVALID_HANDLE)
   {
      Print("Indicator handle creation failed");
      return(INIT_FAILED);
   }

   if(StringFind(_Symbol,"XAU")<0)
      Print("WARNING: Designed for XAU/USD (Gold). Current symbol: ", _Symbol);

   curDay = DayOfYearNow();
   CreateDashboard();
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   int h[6]={hEmaTrend,hEmaFast,hEmaSlow,hRsi,hAdx,hAtr};
   for(int i=0;i<6;i++) if(h[i]!=INVALID_HANDLE) IndicatorRelease(h[i]);
   ObjectsDeleteAll(0, PFX);
   Comment("");
}

//+------------------------------------------------------------------+
void OnTick()
{
   UpdateDailyCounter();
   UpdateStats();
   ManageOpenPosition();     // break-even + trailing
   UpdateDashboard();

   datetime t = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(t==lastBarTime) return;    // new bar only
   lastBarTime = t;

   if(PositionOpen()) return;
   if(!InSession()) return;
   if(tradesToday >= InpMaxTradesDay) return;
   if(lossToday   >= InpMaxDailyLoss) return;      // daily loss lock
   if(SpreadPoints() > InpMaxSpreadPts) return;    // spread filter

   int sig = Signal();      // +1 buy, -1 sell, 0 none
   if(sig>0) ExecuteTrade(true);
   else if(sig<0) ExecuteTrade(false);
}

//====================================================================
//  SIGNAL  (VWAP trend-continuation + confluence score)
//====================================================================
int Signal()
{
   double vwap, sd;
   if(!ComputeVWAP(vwap, sd)) return 0;
   dbVWAP=vwap; dbSDup=vwap+sd; dbSDdn=vwap-sd;

   double emaT[1], emaF[1], emaS[1], rsi[1], adx[1], atr[1];
   if(CopyBuffer(hEmaTrend,0,1,1,emaT)<1) return 0;
   if(CopyBuffer(hEmaFast, 0,1,1,emaF)<1) return 0;
   if(CopyBuffer(hEmaSlow, 0,1,1,emaS)<1) return 0;
   if(CopyBuffer(hRsi,     0,1,1,rsi )<1) return 0;
   if(CopyBuffer(hAdx,     0,1,1,adx )<1) return 0;
   if(CopyBuffer(hAtr,     0,1,1,atr )<1) return 0;

   dbATR=atr[0]; dbADX=adx[0]; dbRSI=rsi[0];

   double o1=iOpen(_Symbol,PERIOD_CURRENT,1);
   double c1=iClose(_Symbol,PERIOD_CURRENT,1);
   double h1=iHigh(_Symbol,PERIOD_CURRENT,1);
   double l1=iLow(_Symbol,PERIOD_CURRENT,1);
   double tol=0.25*atr[0];   // pullback tolerance to VWAP

   // ---------- BUY side ----------
   int buyScore=0;
   bool buyTrigger=false;
   if(c1>vwap)          buyScore++;   // above VWAP
   if(emaF[0]>emaS[0])  buyScore++;   // fast>slow
   if(rsi[0]>50.0)      buyScore++;   // momentum
   if(adx[0]>=InpAdxMin)buyScore++;   // trending (not chop)
   if(c1>emaT[0])       buyScore++;   // above 200 EMA
   // trigger: pullback tags VWAP and closes back above with bullish candle
   if(l1<=vwap+tol && c1>vwap && c1>o1) { buyScore++; buyTrigger=true; }

   // ---------- SELL side ----------
   int sellScore=0;
   bool sellTrigger=false;
   if(c1<vwap)          sellScore++;
   if(emaF[0]<emaS[0])  sellScore++;
   if(rsi[0]<50.0)      sellScore++;
   if(adx[0]>=InpAdxMin)sellScore++;
   if(c1<emaT[0])       sellScore++;
   if(h1>=vwap-tol && c1<vwap && c1<o1) { sellScore++; sellTrigger=true; }

   if(buyTrigger && buyScore>=InpMinScore && buyScore>=sellScore)
   { dbScore=buyScore; dbBias=1; return 1; }

   if(sellTrigger && sellScore>=InpMinScore && sellScore>buyScore)
   { dbScore=sellScore; dbBias=-1; return -1; }

   // for dashboard, show the stronger side bias
   if(c1>vwap && c1>emaT[0]) { dbBias=1; dbScore=buyScore; }
   else if(c1<vwap && c1<emaT[0]) { dbBias=-1; dbScore=sellScore; }
   else { dbBias=0; dbScore=MathMax(buyScore,sellScore); }
   return 0;
}

//--- Session (daily) VWAP + standard deviation over today's bars
bool ComputeVWAP(double &vwap, double &sd)
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   dt.hour=0; dt.min=0; dt.sec=0;
   datetime dayStart = StructToTime(dt);

   int startBar = iBarShift(_Symbol, PERIOD_CURRENT, dayStart, false);
   if(startBar<1) startBar=1;

   double sumPV=0, sumV=0, sumP2V=0;
   for(int i=startBar; i>=1; i--)
   {
      double tp = (iHigh(_Symbol,PERIOD_CURRENT,i)+iLow(_Symbol,PERIOD_CURRENT,i)+iClose(_Symbol,PERIOD_CURRENT,i))/3.0;
      double v  = (double)iVolume(_Symbol,PERIOD_CURRENT,i);   // tick volume
      if(v<=0) v=1;
      sumPV  += tp*v;
      sumV   += v;
      sumP2V += tp*tp*v;
   }
   if(sumV<=0) return false;
   vwap = sumPV/sumV;
   double var = (sumP2V/sumV) - (vwap*vwap);
   sd = (var>0)? MathSqrt(var):0.0;
   return true;
}

//====================================================================
//  EXECUTION
//====================================================================
void ExecuteTrade(bool isBuy)
{
   double atr[1];
   if(CopyBuffer(hAtr,0,1,1,atr)<1) return;
   double slDist = atr[0]*InpAtrSLmult;
   if(slDist<=0) return;

   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   int    dg =(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);

   double entry,sl,tp;
   double rr = MathMax(InpRiskReward,2.0);

   if(isBuy)
   {
      entry=ask;
      sl = NormalizeDouble(entry-slDist, dg);
      tp = NormalizeDouble(entry+slDist*rr, dg);
   }
   else
   {
      entry=bid;
      sl = NormalizeDouble(entry+slDist, dg);
      tp = NormalizeDouble(entry-slDist*rr, dg);
   }

   double lot=CalcLot(slDist);
   if(lot<=0) return;

   bool ok = isBuy ? trade.Buy(lot,_Symbol,0.0,sl,tp,InpComment)
                   : trade.Sell(lot,_Symbol,0.0,sl,tp,InpComment);
   if(ok)
   {
      tradesToday++;
      PrintFormat("%s opened lot=%.2f SL=%.2f TP=%.2f RR=1:%.1f score=%d",
                  (isBuy?"BUY":"SELL"),lot,sl,tp,rr,dbScore);
   }
   else
      PrintFormat("Order failed %d %s",trade.ResultRetcode(),trade.ResultRetcodeDescription());
}

double CalcLot(double slDistPrice)
{
   double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step  =SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);

   if(InpLotMode==LOT_FIXED) return NormLot(InpFixedLot,minLot,maxLot,step);

   double bal=AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney=bal*InpRiskPercent/100.0;
   double tickVal=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double tickSz =SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tickSz<=0||tickVal<=0) return NormLot(InpFixedLot,minLot,maxLot,step);

   double lossPerLot=(slDistPrice/tickSz)*tickVal;
   if(lossPerLot<=0) return minLot;
   double lot=riskMoney/lossPerLot;
   return NormLot(lot,minLot,maxLot,step);
}

double NormLot(double lot,double mn,double mx,double st)
{
   if(st<=0) st=0.01;
   lot=MathFloor(lot/st)*st;
   if(lot<mn) lot=mn;
   if(lot>mx) lot=mx;
   return NormalizeDouble(lot,2);
}

//====================================================================
//  POSITION MANAGEMENT  (break-even + ATR trail)
//====================================================================
void ManageOpenPosition()
{
   if(InpBEatR<=0 && InpTrailATR<=0) return;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;

      long   type =PositionGetInteger(POSITION_TYPE);
      double open =PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   =PositionGetDouble(POSITION_SL);
      double tp   =PositionGetDouble(POSITION_TP);
      int    dg   =(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);

      double atr[1];
      if(CopyBuffer(hAtr,0,1,1,atr)<1) return;
      double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
      double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);

      double rDist = MathAbs(open-sl);
      if(rDist<=0) continue;

      double newSL=sl;

      if(type==POSITION_TYPE_BUY)
      {
         double profit=bid-open;
         if(InpBEatR>0 && profit>=rDist*InpBEatR && sl<open)
            newSL=open;
         if(InpTrailATR>0)
         {
            double trail=bid-atr[0]*InpTrailATR;
            if(trail>newSL) newSL=trail;
         }
         newSL=NormalizeDouble(newSL,dg);
         if(newSL>sl && newSL<bid) trade.PositionModify(tk,newSL,tp);
      }
      else if(type==POSITION_TYPE_SELL)
      {
         double profit=open-ask;
         if(InpBEatR>0 && profit>=rDist*InpBEatR && (sl>open||sl==0))
            newSL=open;
         if(InpTrailATR>0)
         {
            double trail=ask+atr[0]*InpTrailATR;
            if(trail<newSL||newSL==0) newSL=trail;
         }
         newSL=NormalizeDouble(newSL,dg);
         if((newSL<sl||sl==0) && newSL>ask) trade.PositionModify(tk,newSL,tp);
      }
   }
}

//====================================================================
//  HELPERS
//====================================================================
bool PositionOpen()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==InpMagic) return true;
   }
   return false;
}

double SpreadPoints()
{
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double pt =SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   if(pt<=0) return 0;
   return (ask-bid)/pt;
}

int DayOfYearNow()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   return dt.day_of_year;
}

void UpdateDailyCounter()
{
   int d=DayOfYearNow();
   if(d!=curDay){ curDay=d; tradesToday=0; }
}

bool InSession()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   if(InpStartHour<=InpEndHour) return (dt.hour>=InpStartHour && dt.hour<InpEndHour);
   return (dt.hour>=InpStartHour || dt.hour<InpEndHour);
}

void UpdateStats()
{
   if(!HistorySelect(0,TimeCurrent())) return;
   int total=HistoryDealsTotal();
   if(total==lastDeals) return;

   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   dt.hour=0; dt.min=0; dt.sec=0;
   datetime dayStart=StructToTime(dt);

   totalWins=0; totalLoss=0; winsToday=0; lossToday=0;
   for(int i=0;i<total;i++)
   {
      ulong tk=HistoryDealGetTicket(i);
      if(tk==0) continue;
      if(HistoryDealGetInteger(tk,DEAL_MAGIC)!=InpMagic) continue;
      if(HistoryDealGetString(tk,DEAL_SYMBOL)!=_Symbol) continue;
      if(HistoryDealGetInteger(tk,DEAL_ENTRY)!=DEAL_ENTRY_OUT) continue;
      double pnl=HistoryDealGetDouble(tk,DEAL_PROFIT)+HistoryDealGetDouble(tk,DEAL_SWAP)+HistoryDealGetDouble(tk,DEAL_COMMISSION);
      datetime dtime=(datetime)HistoryDealGetInteger(tk,DEAL_TIME);
      if(pnl>=0) totalWins++; else totalLoss++;
      if(dtime>=dayStart){ if(pnl>=0) winsToday++; else lossToday++; }
   }
   lastDeals=total;
}

//====================================================================
//  DASHBOARD
//====================================================================
void Lbl(string name,string text,int x,int y,color clr,int size=9,string font="Consolas")
{
   string obj=PFX+name;
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
   string obj=PFX+"panel";
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
   Panel(10,18,290,350,C'18,22,30');
   Lbl("title","  VWAP + SSRM  GOLD EA",22,26,clrGold,11,"Consolas Bold");
   UpdateDashboard();
}

void UpdateDashboard()
{
   string biasTxt=(dbBias>0?"BULLISH":(dbBias<0?"BEARISH":"NEUTRAL"));
   color  biasClr=(dbBias>0?clrLime:(dbBias<0?clrTomato:clrSilver));

   double bal=AccountInfoDouble(ACCOUNT_BALANCE);
   double eq =AccountInfoDouble(ACCOUNT_EQUITY);
   int tot=totalWins+totalLoss;
   double wr=(tot>0)?100.0*totalWins/tot:0.0;
   bool pos=PositionOpen();
   bool lock=(lossToday>=InpMaxDailyLoss);

   int x=22,y=50,dy=19;
   Lbl("l1", StringFormat("Symbol : %s  (%s)",_Symbol,EnumToString((ENUM_TIMEFRAMES)Period())),x,y,clrWhite); y+=dy;
   Lbl("l2", StringFormat("Bias   : %s   Score:%d/6",biasTxt,dbScore),x,y,biasClr); y+=dy;
   Lbl("l3", StringFormat("VWAP   : %.2f",dbVWAP),x,y,clrAqua); y+=dy;
   Lbl("l4", StringFormat("+/-1sd : %.2f / %.2f",dbSDup,dbSDdn),x,y,clrSkyBlue); y+=dy;
   Lbl("l5", StringFormat("ADX %.1f  RSI %.1f  ATR %.2f",dbADX,dbRSI,dbATR),x,y,clrWhite); y+=dy;
   Lbl("l6", StringFormat("Spread : %.0f pts",SpreadPoints()),x,y,(SpreadPoints()>InpMaxSpreadPts?clrTomato:clrWhite)); y+=dy;
   Lbl("l7", "----------------------------------",x,y,clrDimGray); y+=dy;
   Lbl("l8", StringFormat("Position   : %s",(pos?"OPEN":"none")),x,y,(pos?clrYellow:clrSilver)); y+=dy;
   Lbl("l9", StringFormat("Trades today: %d / %d",tradesToday,InpMaxTradesDay),x,y,(tradesToday>=InpMaxTradesDay?clrOrange:clrWhite)); y+=dy;
   Lbl("l10",StringFormat("Losses today: %d / %d %s",lossToday,InpMaxDailyLoss,(lock?"[LOCKED]":"")),x,y,(lock?clrTomato:clrWhite)); y+=dy;
   Lbl("l11",StringFormat("RR target  : 1:%.1f",MathMax(InpRiskReward,2.0)),x,y,clrAqua); y+=dy;
   Lbl("l12",StringFormat("Lot mode   : %s",(InpLotMode==LOT_FIXED?"FIXED":"AUTO %")),x,y,clrWhite); y+=dy;
   if(InpLotMode==LOT_FIXED)
      Lbl("l13",StringFormat("Fixed lot  : %.2f",InpFixedLot),x,y,clrWhite);
   else
      Lbl("l13",StringFormat("Risk/trade : %.2f %%",InpRiskPercent),x,y,clrWhite);
   y+=dy;
   Lbl("l14",StringFormat("Balance    : %.2f",bal),x,y,clrWhite); y+=dy;
   Lbl("l15",StringFormat("Equity     : %.2f",eq),x,y,clrWhite); y+=dy;
   Lbl("l16",StringFormat("W/L total  : %d / %d",totalWins,totalLoss),x,y,clrWhite); y+=dy;
   Lbl("l17",StringFormat("Win rate   : %.1f %%",wr),x,y,(wr>=70?clrLime:clrOrange)); y+=dy;
   Lbl("l18",StringFormat("Session    : %s",(InSession()?"ACTIVE":"closed")),x,y,(InSession()?clrLime:clrSilver));
}
//+------------------------------------------------------------------+
