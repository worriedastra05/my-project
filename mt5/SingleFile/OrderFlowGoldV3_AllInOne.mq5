//+------------------------------------------------------------------+
//|                                   OrderFlowGoldV3_AllInOne.mq5    |
//|              Order Flow Gold v3  -  self-contained single file    |
//|                                                                  |
//|  XAUUSD M5 order-flow EA.  Candle-proxy order flow so it works   |
//|  in the Strategy Tester on OHLC data (no real tick feed needed). |
//|  Two engines: FADE (absorption reversal) + FLOW (continuation).  |
//|  Full dashboard incl. WHY / DIAGNOSTICS, timezone, news filter,  |
//|  tiered SL/TP.  Only dependency: <Trade/Trade.mqh>.              |
//+------------------------------------------------------------------+
#property copyright "Order Flow Gold v3"
#property version   "3.00"
#property strict

#include <Trade/Trade.mqh>

//==================================================================
//  INPUTS
//==================================================================
input string  s_gen        = "======== GENERAL ========";
input long    InpMagic      = 20260932;     // Magic number
input string  InpComment    = "OFG3";       // Order comment
input bool    InpUseChartTF = true;         // Use current chart timeframe
input ENUM_TIMEFRAMES InpTF = PERIOD_M5;    // Timeframe (if not chart TF)

input string  s_flow       = "======== ORDER FLOW ========";
input int     InpDeltaLen   = 20;           // Delta z-score lookback (bars)
input int     InpVwapMode   = 1;            // VWAP reset: 0=off 1=daily 2=session
input int     InpAtrLen     = 14;           // ATR length
input int     InpRegimeLen  = 100;          // Regime ATR-percentile lookback

input string  s_fade       = "======== FADE ENGINE (reversal) ========";
input bool    InpUseFade    = true;         // Enable fade engine
input int     InpFadeLook   = 10;           // New high/low lookback
input double  InpFadeZ      = 1.5;          // Min |delta z| to fade
input double  InpFadeClose  = 0.55;         // Min rejection close-position (0..1)
input double  InpFadeMaxEff = 0.55;         // Max move efficiency (absorption)
input double  InpFadeVwapSg = 0.5;          // Min VWAP distance (sigma) to fade

input string  s_flowe      = "======== FLOW ENGINE (continuation) ========";
input bool    InpUseFlow    = true;         // Enable flow engine
input double  InpFlowZ      = 1.4;          // Min delta z for continuation
input double  InpFlowBody   = 0.55;         // Min body/range for continuation

input string  s_score      = "======== SIGNAL GATE ========";
input double  InpMinScore   = 0.35;         // Min composite score to trade
input int     InpMaxSpreadPt= 60;           // Max spread (points), 0=off
input int     InpCooldownMin= 4;            // Cooldown after a trade (minutes)
input int     InpMaxTrades  = 8;            // Max trades per day

input string  s_risk       = "======== RISK / MONEY ========";
input double  InpRiskPercent= 0.35;         // Risk per trade (% of balance)
input double  InpFixedLots  = 0.0;          // Fixed lots (0 = use risk %)
input double  InpSlAtr      = 1.2;          // SL = ATR x this
input double  InpTp1R       = 0.6;          // TP1 in R
input double  InpTp1Close   = 70.0;         // % closed at TP1
input double  InpTp2R       = 2.2;          // TP2 in R
input double  InpBeAtR      = 0.9;          // Move SL to BE after this R
input double  InpTrailAtr   = 1.2;          // Trailing stop = ATR x this
input int     InpTimeStopBar= 12;           // Close after N bars if flat P/L

input string  s_time       = "======== TIME / TIMEZONE ========";
input bool    InpUseWindow  = true;         // Restrict trading to a window
input int     InpStartHour  = 7;            // Start hour (GMT)
input int     InpEndHour    = 20;           // End hour (GMT)
input int     InpManualGmtOff = 999;        // Manual server-GMT offset (hrs), 999=auto

input string  s_news       = "======== NEWS FILTER ========";
input bool    InpUseNews    = true;         // Enable news filter
input int     InpNewsBefore = 30;           // Block minutes BEFORE event
input int     InpNewsAfter  = 30;           // Block minutes AFTER event
input string  InpNewsCurr   = "USD,XAU";    // Currencies to watch
input bool    InpNewsHighOnly = true;       // Only high-impact events

input string  s_ui         = "======== DASHBOARD ========";
input bool    InpShowPanel  = true;         // Show dashboard
input int     InpPanelX     = 12;           // Panel X
input int     InpPanelY     = 24;           // Panel Y
input color   InpColBg      = C'22,26,34';  // Panel background
input color   InpColText    = C'200,205,215';// Text
input color   InpColHead    = C'120,180,255';// Headers
input color   InpColGood    = C'120,230,150';// Good
input color   InpColWarn    = C'240,160,90'; // Warn

//==================================================================
//  GLOBALS
//==================================================================
CTrade         trade;
string         g_sym;
ENUM_TIMEFRAMES g_tf;
double         g_point;
int            g_digits;
datetime       g_lastBar     = 0;
datetime       g_lastTrade   = 0;
int            g_tradesToday = 0;
int            g_dayStamp    = -1;
ulong          g_tp1Ticket   = 0;   // ticket that already did its TP1 partial

// order-flow state
double         g_delta       = 0.0;   // last bar delta
double         g_deltaZ      = 0.0;   // last bar delta z-score
double         g_cvd         = 0.0;   // cumulative volume delta (session)
double         g_vwap        = 0.0;   // session VWAP
double         g_vwapSigma   = 0.0;   // dispersion around VWAP
double         g_atr         = 0.0;
double         g_eff         = 0.0;   // efficiency of last swing
double         g_regimePct   = 0.0;   // ATR percentile 0..100
string         g_regime      = "-";

// diagnostics
string         g_diagEngine  = "-";
string         g_diagGate    = "-";
string         g_diagFade    = "-";
string         g_diagFlow    = "-";
int            g_barsEval    = 0;
int            g_fadeReady   = 0;
int            g_flowReady   = 0;
string         g_lastSignal  = "none yet";

// news
struct NewsEvt { datetime t; string title; };
NewsEvt        g_news[];
datetime       g_newsLoad    = 0;

// timezone
int            g_gmtOff      = 0;

// panel
string         g_pfx         = "OFG3_";

//==================================================================
//  UTILITY
//==================================================================
double Nz(double v){ if(v!=v) return 0.0; return v; }

int GmtOffsetHours()
  {
   if(InpManualGmtOff!=999) return InpManualGmtOff;
   // auto: server time minus GMT
   datetime srv = TimeCurrent();
   datetime gmt = TimeGMT();
   if(gmt==0) return 0;
   int diff = (int)MathRound((double)(srv-gmt)/3600.0);
   return diff;
  }

datetime ServerToGmt(datetime srv){ return srv - g_gmtOff*3600; }

string ZoneLabel()
  {
   int o = g_gmtOff;
   string sign = (o>=0 ? "+" : "-");
   return StringFormat("Server GMT%s%d", sign, (int)MathAbs(o));
  }

//==================================================================
//  INDICATOR MATH (manual, no handles)
//==================================================================
// Compute ATR from rates array (index 0 = current forming bar).
double CalcAtr(const MqlRates &r[], int len, int startShift)
  {
   int n = ArraySize(r);
   double sum = 0.0; int cnt = 0;
   for(int i=startShift; i<startShift+len && i+1<n; i++)
     {
      double tr = MathMax(r[i].high, r[i+1].close) - MathMin(r[i].low, r[i+1].close);
      sum += tr; cnt++;
     }
   if(cnt==0) return 0.0;
   return sum/cnt;
  }

//==================================================================
//  ORDER FLOW  (candle proxy)
//==================================================================
// Update all order-flow state from the last N closed bars.
void UpdateFlow()
  {
   MqlRates r[];
   ArraySetAsSeries(r, true);
   int need = MathMax(InpRegimeLen+InpAtrLen+5, InpDeltaLen+InpFadeLook+5);
   int got  = CopyRates(g_sym, g_tf, 0, need, r);
   if(got < InpDeltaLen+5) return;

   // ---- per-bar delta (proxy): vol * (2*closePos - 1)
   // build delta series over the copied bars (skip index 0 = forming)
   double deltas[]; ArrayResize(deltas, got);
   for(int i=1; i<got; i++)
     {
      double rng = r[i].high - r[i].low;
      double closePos = (rng>0.0 ? (r[i].close - r[i].low)/rng : 0.5);
      double vol = (double)r[i].tick_volume;
      if(vol<=0.0) vol = 1.0;
      deltas[i] = vol * (2.0*closePos - 1.0);
     }
   deltas[0] = 0.0;
   g_delta = deltas[1];

   // ---- delta z-score over lookback (bars 1..InpDeltaLen)
   double mean=0.0; int c=0;
   for(int i=1; i<=InpDeltaLen && i<got; i++){ mean += deltas[i]; c++; }
   if(c>0) mean/=c;
   double var=0.0;
   for(int i=1; i<=InpDeltaLen && i<got; i++){ double d=deltas[i]-mean; var+=d*d; }
   double sd = (c>1 ? MathSqrt(var/(c-1)) : 0.0);
   g_deltaZ = (sd>0.0 ? (deltas[1]-mean)/sd : 0.0);

   // ---- session VWAP + dispersion + CVD
   int today = -1;
   MqlDateTime dt;
   TimeToStruct(r[1].time, dt);
   today = dt.day_of_year;
   double pv=0.0, vv=0.0, cvd=0.0;
   double sq=0.0; int vc=0;
   for(int i=got-1; i>=1; i--)
     {
      MqlDateTime d2; TimeToStruct(r[i].time, d2);
      bool sameDay = (d2.day_of_year==today);
      if(InpVwapMode==0) sameDay = true;
      if(!sameDay) continue;
      double typ = (r[i].high + r[i].low + r[i].close)/3.0;
      double vol = (double)r[i].tick_volume; if(vol<=0.0) vol=1.0;
      pv += typ*vol; vv += vol;
      cvd += deltas[i];
     }
   g_vwap = (vv>0.0 ? pv/vv : r[1].close);
   g_cvd  = cvd;
   // dispersion (sigma of close around vwap for the session)
   for(int i=got-1; i>=1; i--)
     {
      MqlDateTime d2; TimeToStruct(r[i].time, d2);
      bool sameDay = (d2.day_of_year==today);
      if(InpVwapMode==0) sameDay = true;
      if(!sameDay) continue;
      double dd = r[i].close - g_vwap; sq += dd*dd; vc++;
     }
   g_vwapSigma = (vc>1 ? MathSqrt(sq/(vc-1)) : 0.0);

   // ---- ATR
   g_atr = CalcAtr(r, InpAtrLen, 1);

   // ---- efficiency of last swing (net move / gross path over FadeLook bars)
   double net = MathAbs(r[1].close - r[InpFadeLook].close);
   double gross = 0.0;
   for(int i=1; i<InpFadeLook && i+1<got; i++) gross += MathAbs(r[i].close - r[i+1].close);
   g_eff = (gross>0.0 ? net/gross : 0.0);

   // ---- regime by ATR percentile
   double curAtr = g_atr;
   int below=0, total=0;
   for(int i=1; i+InpAtrLen+1<got && i<=InpRegimeLen; i++)
     {
      double a = CalcAtr(r, InpAtrLen, i);
      if(a>0.0){ total++; if(a<=curAtr) below++; }
     }
   g_regimePct = (total>0 ? 100.0*below/total : 50.0);
   if(g_regimePct<=40.0)      g_regime = "CALM";
   else if(g_regimePct>=95.0) g_regime = "STORM";
   else if(g_regimePct>=75.0) g_regime = "TREND";
   else                       g_regime = "NORMAL";
  }

//==================================================================
//  SCORING
//==================================================================
double Clamp01(double v){ if(v<0.0) return 0.0; if(v>1.0) return 1.0; return v; }

double ScoreFade(int dir, double z, double eff, double vwapDistSig, double closePos)
  {
   double sz   = Clamp01((MathAbs(z)-InpFadeZ)/2.0 + 0.4);
   double sEff = Clamp01((InpFadeMaxEff-eff)/InpFadeMaxEff);
   double sVw  = Clamp01(vwapDistSig/2.0);
   double sCl  = Clamp01((closePos-InpFadeClose)/(1.0-InpFadeClose));
   return 0.35*sz + 0.25*sEff + 0.20*sVw + 0.20*sCl;
  }

double ScoreFlow(int dir, double z, double body, double vwapSideOk)
  {
   double sz   = Clamp01((MathAbs(z)-InpFlowZ)/2.0 + 0.4);
   double sB   = Clamp01((body-InpFlowBody)/(1.0-InpFlowBody));
   double sVw  = (vwapSideOk>0.0 ? 1.0 : 0.4);
   return 0.45*sz + 0.30*sB + 0.25*sVw;
  }

//==================================================================
//  SIGNAL EVALUATION  (also fills diagnostics)
//==================================================================
// returns: 0 = none, 1 = buy, -1 = sell; fills outScore, outEngine
int EvalSignal(double &outScore, string &outEngine)
  {
   outScore = 0.0; outEngine = "-";
   g_diagFade = "-"; g_diagFlow = "-"; g_diagEngine = "scanning";

   MqlRates r[]; ArraySetAsSeries(r, true);
   int need = InpDeltaLen + InpFadeLook + 5;
   int got  = CopyRates(g_sym, g_tf, 0, need, r);
   if(got < InpFadeLook+3){ g_diagEngine="no data"; return 0; }

   double h1=r[1].high, l1=r[1].low, c1=r[1].close, o1=r[1].open;
   double rng = h1-l1; if(rng<=0.0) rng=g_point;
   double closePos = (c1-l1)/rng;
   double body = MathAbs(c1-o1)/rng;
   double z = g_deltaZ;

   int bestDir=0; double bestScore=0.0; string bestEng="-";

   //---------------- FADE ENGINE ----------------
   if(!InpUseFade) g_diagFade="off";
   else
     {
      double lowest=DBL_MAX, highest=-DBL_MAX;
      for(int i=2; i<=InpFadeLook+1 && i<got; i++)
        { lowest=MathMin(lowest,r[i].low); highest=MathMax(highest,r[i].high); }
      bool newLow  = (l1 < lowest);
      bool newHigh = (h1 > highest);
      double rejUp   = closePos;          // close near top after new low  -> buy
      double rejDown = 1.0 - closePos;    // close near bottom after new high -> sell

      if(!newLow && !newHigh)                 g_diagFade="no new "+IntegerToString(InpFadeLook)+"-bar hi/lo";
      else if(MathAbs(z)<InpFadeZ)            g_diagFade=StringFormat("|z| %.2f < %.2f", MathAbs(z), InpFadeZ);
      else if(g_eff>InpFadeMaxEff)            g_diagFade=StringFormat("eff %.2f > %.2f (no absorption)", g_eff, InpFadeMaxEff);
      else
        {
         int dir = 0; double rej = 0.0;
         if(newLow)  { dir = 1;  rej = rejUp; }
         else        { dir = -1; rej = rejDown; }
         double vwapDist = (g_vwapSigma>0.0 ? MathAbs(c1-g_vwap)/g_vwapSigma : 0.0);
         bool farOk = (InpFadeVwapSg<=0.0 || vwapDist>=InpFadeVwapSg);

         if(rej < InpFadeClose)               g_diagFade=StringFormat("reject %.2f < %.2f", rej, InpFadeClose);
         else if(!farOk)                      g_diagFade=StringFormat("VWAP dist %.2f < %.2f sig", vwapDist, InpFadeVwapSg);
         else
           {
            double sc = ScoreFade(dir, z, g_eff, vwapDist, rej);
            g_fadeReady++;
            g_diagFade = StringFormat("READY %s score %.2f", (dir>0?"BUY":"SELL"), sc);
            if(sc>bestScore){ bestScore=sc; bestDir=dir; bestEng="FADE"; }
           }
        }
     }

   //---------------- FLOW ENGINE ----------------
   if(!InpUseFlow) g_diagFlow="off";
   else
     {
      int dir = (c1>o1 ? 1 : -1);
      bool zOk   = (MathAbs(z)>=InpFlowZ);
      bool zSide = ((dir>0 && z>0) || (dir<0 && z<0));
      bool bodyOk= (body>=InpFlowBody);
      bool vwapSide = ((dir>0 && c1>=g_vwap) || (dir<0 && c1<=g_vwap));

      if(!zOk)            g_diagFlow=StringFormat("|z| %.2f < %.2f", MathAbs(z), InpFlowZ);
      else if(!zSide)     g_diagFlow="delta not aligned with candle";
      else if(!bodyOk)    g_diagFlow=StringFormat("body %.2f < %.2f", body, InpFlowBody);
      else
        {
         double sc = ScoreFlow(dir, z, body, (vwapSide?1.0:0.0));
         g_flowReady++;
         g_diagFlow = StringFormat("READY %s score %.2f", (dir>0?"BUY":"SELL"), sc);
         if(sc>bestScore){ bestScore=sc; bestDir=dir; bestEng="FLOW"; }
        }
     }

   outScore = bestScore; outEngine = bestEng;
   if(bestDir!=0) g_diagEngine = StringFormat("%s candidate %s (%.2f)", bestEng, (bestDir>0?"BUY":"SELL"), bestScore);
   else           g_diagEngine = "no candidate this bar";
   return bestDir;
  }

//==================================================================
//  NEWS FILTER  (calendar first, manual fallback)
//==================================================================
bool CurrencyWatched(string cur)
  {
   string list = InpNewsCurr;
   StringToUpper(list); StringToUpper(cur);
   return (StringFind(list, cur) >= 0);
  }

void LoadNews()
  {
   ArrayResize(g_news, 0);
   g_newsLoad = TimeCurrent();
#ifdef __MQL5__
   MqlCalendarValue values[];
   datetime from = TimeGMT() - 6*3600;
   datetime to   = TimeGMT() + 24*3600;
   int total = CalendarValueHistory(values, from, to, NULL, NULL);
   for(int i=0; i<total; i++)
     {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id, ev)) continue;
      MqlCalendarCountry ct;
      if(!CalendarCountryById(ev.country_id, ct)) continue;
      if(!CurrencyWatched(ct.currency)) continue;
      if(InpNewsHighOnly && ev.importance!=CALENDAR_IMPORTANCE_HIGH) continue;
      int n = ArraySize(g_news);
      ArrayResize(g_news, n+1);
      g_news[n].t = values[i].time;   // GMT
      g_news[n].title = ct.currency + " " + ev.name;
     }
#endif
  }

// returns true if blocked; fills reason + minutes to next
bool NewsBlocked(string &reason, int &minsToNext)
  {
   reason = ""; minsToNext = -1;
   if(!InpUseNews) return false;
   datetime nowG = TimeGMT();
   if(nowG==0) nowG = ServerToGmt(TimeCurrent());
   datetime nearest = 0; string nearestTitle="";
   bool blocked=false;
   for(int i=0; i<ArraySize(g_news); i++)
     {
      long diff = (long)(g_news[i].t - nowG)/60; // minutes to event (neg if past)
      if(diff>=0 && (nearest==0 || g_news[i].t<nearest)){ nearest=g_news[i].t; nearestTitle=g_news[i].title; }
      if(diff<=InpNewsBefore && diff>=-InpNewsAfter)
        { blocked=true; reason="NEWS: "+g_news[i].title; }
     }
   if(nearest>0) minsToNext = (int)((nearest-nowG)/60);
   return blocked;
  }

//==================================================================
//  TRADE MANAGEMENT
//==================================================================
double CalcLots(double slDistPrice)
  {
   if(InpFixedLots>0.0) return NormalizeLots(InpFixedLots);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = bal * InpRiskPercent/100.0;
   double tickVal = SymbolInfoDouble(g_sym, SYMBOL_TRADE_TICK_VALUE);
   double tickSz  = SymbolInfoDouble(g_sym, SYMBOL_TRADE_TICK_SIZE);
   if(tickSz<=0.0 || tickVal<=0.0 || slDistPrice<=0.0) return NormalizeLots(0.01);
   double lossPerLot = (slDistPrice/tickSz)*tickVal;
   if(lossPerLot<=0.0) return NormalizeLots(0.01);
   double lots = riskMoney/lossPerLot;
   return NormalizeLots(lots);
  }

double NormalizeLots(double lots)
  {
   double mn = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_MIN);
   double mx = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_MAX);
   double st = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_STEP);
   if(st<=0.0) st=0.01;
   lots = MathFloor(lots/st)*st;
   if(lots<mn) lots=mn;
   if(lots>mx) lots=mx;
   return lots;
  }

bool HasPosition()
  {
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==g_sym &&
         PositionGetInteger(POSITION_MAGIC)==InpMagic) return true;
     }
   return false;
  }

void OpenTrade(int dir, double score, string engine)
  {
   double ask = SymbolInfoDouble(g_sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(g_sym, SYMBOL_BID);
   double price = (dir>0 ? ask : bid);
   double slDist = g_atr*InpSlAtr;
   if(slDist<=0.0) slDist = 100*g_point;
   double sl = (dir>0 ? price-slDist : price+slDist);
   double tp = (dir>0 ? price+slDist*InpTp2R : price-slDist*InpTp2R);
   double lots = CalcLots(slDist);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(20);
   bool ok;
   string cmt = StringFormat("%s|%s|%.2f", InpComment, engine, score);
   if(dir>0) ok = trade.Buy(lots, g_sym, 0.0, sl, tp, cmt);
   else      ok = trade.Sell(lots, g_sym, 0.0, sl, tp, cmt);

   if(ok)
     {
      g_lastTrade = TimeCurrent();
      g_tradesToday++;
      g_lastSignal = StringFormat("%s %s @ %.5f  score %.2f", (dir>0?"BUY":"SELL"), engine, price, score);
     }
   else
      g_lastSignal = "OPEN FAILED: "+trade.ResultRetcodeDescription();
  }

void ManagePositions()
  {
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=g_sym) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;

      long type = PositionGetInteger(POSITION_TYPE);
      double open= PositionGetDouble(POSITION_PRICE_OPEN);
      double sl  = PositionGetDouble(POSITION_SL);
      double vol = PositionGetDouble(POSITION_VOLUME);
      double bid = SymbolInfoDouble(g_sym, SYMBOL_BID);
      double ask = SymbolInfoDouble(g_sym, SYMBOL_ASK);
      double cur = (type==POSITION_TYPE_BUY ? bid : ask);
      double slDist0 = MathAbs(open - sl);
      if(slDist0<=0.0) slDist0 = g_atr*InpSlAtr;
      double rNow = (type==POSITION_TYPE_BUY ? (cur-open) : (open-cur)) / (slDist0>0?slDist0:g_point);

      // TP1 partial close (once per ticket)
      bool tp1Done = (tk==g_tp1Ticket);
      if(!tp1Done && rNow>=InpTp1R && InpTp1Close>0.0)
        {
         double closeVol = NormalizeLots(vol*InpTp1Close/100.0);
         if(closeVol>0.0 && closeVol<vol)
           {
            if(trade.PositionClosePartial(tk, closeVol)) g_tp1Ticket = tk;
           }
        }
      // Breakeven
      if(rNow>=InpBeAtR)
        {
         double be = open;
         if((type==POSITION_TYPE_BUY && (sl<be)) || (type==POSITION_TYPE_SELL && (sl>be || sl==0.0)))
            trade.PositionModify(tk, be, PositionGetDouble(POSITION_TP));
        }
      // Trailing
      if(rNow>=InpBeAtR && InpTrailAtr>0.0 && g_atr>0.0)
        {
         double td = g_atr*InpTrailAtr;
         double newSl = (type==POSITION_TYPE_BUY ? cur-td : cur+td);
         if((type==POSITION_TYPE_BUY && newSl>sl) || (type==POSITION_TYPE_SELL && (newSl<sl || sl==0.0)))
            trade.PositionModify(tk, newSl, PositionGetDouble(POSITION_TP));
        }
      // Time stop
      if(InpTimeStopBar>0)
        {
         datetime openT = (datetime)PositionGetInteger(POSITION_TIME);
         int bars = iBarShift(g_sym, g_tf, openT);
         if(bars>=InpTimeStopBar && MathAbs(rNow)<0.3)
            trade.PositionClose(tk);
        }
     }
  }

//==================================================================
//  DASHBOARD
//==================================================================
void PLabel(string tag, int x, int y, string text, color clr, int size=9, string font="Consolas")
  {
   string nm = g_pfx+tag;
   if(ObjectFind(0,nm)<0)
     {
      ObjectCreate(0,nm,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,nm,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,nm,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,nm,OBJPROP_HIDDEN,true);
     }
   ObjectSetInteger(0,nm,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,nm,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,nm,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,nm,OBJPROP_FONTSIZE,size);
   ObjectSetString(0,nm,OBJPROP_FONT,font);
   ObjectSetString(0,nm,OBJPROP_TEXT,text);
  }

void PBg(int x, int y, int w, int h)
  {
   string nm = g_pfx+"bg";
   if(ObjectFind(0,nm)<0)
     {
      ObjectCreate(0,nm,OBJ_RECTANGLE_LABEL,0,0,0);
      ObjectSetInteger(0,nm,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,nm,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,nm,OBJPROP_BORDER_TYPE,BORDER_FLAT);
     }
   ObjectSetInteger(0,nm,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,nm,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,nm,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,nm,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,nm,OBJPROP_BGCOLOR,InpColBg);
   ObjectSetInteger(0,nm,OBJPROP_COLOR,C'60,70,85');
  }

int g_ry=0;
void Row(string tag, string label, string val, color vcol)
  {
   int x = InpPanelX+10;
   PLabel(tag+"_l", x, g_ry, label, InpColText);
   PLabel(tag+"_v", x+170, g_ry, val, vcol);
   g_ry += 17;
  }
void Head(string tag, string text)
  {
   g_ry += 4;
   PLabel(tag+"_h", InpPanelX+8, g_ry, text, InpColHead, 9, "Consolas Bold");
   g_ry += 18;
  }

void UpdatePanel()
  {
   if(!InpShowPanel) return;
   int w = 360, h = 560;
   PBg(InpPanelX, InpPanelY, w, h);
   g_ry = InpPanelY+8;

   PLabel("title", InpPanelX+8, g_ry, "ORDER FLOW GOLD  v3", InpColHead, 11, "Consolas Bold");
   g_ry += 22;

   // CLOCK & TIMEZONE
   Head("h_clk","CLOCK & TIMEZONE");
   datetime srv = TimeCurrent();
   datetime gmt = TimeGMT(); if(gmt==0) gmt=ServerToGmt(srv);
   Row("clk1","Server time", TimeToString(srv, TIME_DATE|TIME_MINUTES), InpColText);
   Row("clk2","GMT time",    TimeToString(gmt, TIME_DATE|TIME_MINUTES), InpColText);
   Row("clk3","Timezone",    ZoneLabel(), InpColText);

   // MARKET & REGIME
   Head("h_mkt","MARKET & REGIME");
   double spr = (SymbolInfoDouble(g_sym,SYMBOL_ASK)-SymbolInfoDouble(g_sym,SYMBOL_BID))/g_point;
   Row("mk1","Bid / Ask", StringFormat("%.*f / %.*f", g_digits, SymbolInfoDouble(g_sym,SYMBOL_BID), g_digits, SymbolInfoDouble(g_sym,SYMBOL_ASK)), InpColText);
   Row("mk2","Spread (pt)", StringFormat("%.0f", spr), (InpMaxSpreadPt>0 && spr>InpMaxSpreadPt?InpColWarn:InpColText));
   Row("mk3","ATR", StringFormat("%.*f", g_digits, g_atr), InpColText);
   color rcol = (g_regime=="STORM"?InpColWarn:(g_regime=="TREND"?InpColGood:InpColText));
   Row("mk4","Regime", StringFormat("%s (%.0f pct)", g_regime, g_regimePct), rcol);

   // ORDER FLOW
   Head("h_of","ORDER FLOW");
   Row("of1","Bar delta", StringFormat("%.0f  (z %.2f)", g_delta, g_deltaZ), (g_deltaZ>0?InpColGood:InpColWarn));
   Row("of2","CVD (session)", StringFormat("%.0f", g_cvd), (g_cvd>=0?InpColGood:InpColWarn));
   Row("of3","VWAP", StringFormat("%.*f", g_digits, g_vwap), InpColText);
   double vd = (g_vwapSigma>0?(SymbolInfoDouble(g_sym,SYMBOL_BID)-g_vwap)/g_vwapSigma:0.0);
   Row("of4","Price vs VWAP", StringFormat("%.2f sigma", vd), InpColText);
   Row("of5","Efficiency", StringFormat("%.2f", g_eff), InpColText);

   // SIGNAL ENGINE
   Head("h_sig","SIGNAL ENGINE");
   Row("sg1","Last signal", g_lastSignal, InpColText);
   Row("sg2","Position", (HasPosition()?"OPEN":"flat"), (HasPosition()?InpColGood:InpColText));
   Row("sg3","Trades today", StringFormat("%d / %d", g_tradesToday, InpMaxTrades), InpColText);

   // NEWS
   Head("h_news","NEWS FILTER");
   string nr; int nn;
   bool nb = NewsBlocked(nr, nn);
   Row("nw1","Status", (InpUseNews?(nb?"BLOCKED":"clear"):"disabled"), (nb?InpColWarn:InpColGood));
   Row("nw2","Events loaded", IntegerToString(ArraySize(g_news)), InpColText);
   Row("nw3","Next event", (nn>=0?StringFormat("in %d min", nn):"none"), InpColText);
   if(nb) Row("nw4","Reason", nr, InpColWarn);

   // WHY / DIAGNOSTICS
   Head("h_diag","WHY / DIAGNOSTICS");
   Row("dg1","Engine", g_diagEngine, InpColText);
   Row("dg2","Gate", g_diagGate, (StringFind(g_diagGate,"OPEN")==0?InpColGood:InpColWarn));
   Row("dg3","Fade check", g_diagFade, (StringFind(g_diagFade,"READY")==0?InpColGood:InpColText));
   Row("dg4","Flow check", g_diagFlow, (StringFind(g_diagFlow,"READY")==0?InpColGood:InpColText));
   Row("dg5","Bars eval", StringFormat("%d | fade-rdy %d | flow-rdy %d", g_barsEval, g_fadeReady, g_flowReady), InpColText);

   ChartRedraw(0);
  }

void DrawVwapLine()
  {
   string nm = g_pfx+"vwapline";
   if(ObjectFind(0,nm)<0)
     {
      ObjectCreate(0,nm,OBJ_HLINE,0,0,g_vwap);
      ObjectSetInteger(0,nm,OBJPROP_COLOR,C'150,150,90');
      ObjectSetInteger(0,nm,OBJPROP_STYLE,STYLE_DOT);
      ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,nm,OBJPROP_HIDDEN,true);
     }
   ObjectSetDouble(0,nm,OBJPROP_PRICE,g_vwap);
  }

void CleanObjects()
  {
   ObjectsDeleteAll(0, g_pfx);
  }

//==================================================================
//  GATE
//==================================================================
bool GateOpen()
  {
   // day reset
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_year!=g_dayStamp){ g_dayStamp=dt.day_of_year; g_tradesToday=0; }

   if(HasPosition()){ g_diagGate="position open (managing)"; return false; }

   double spr = (SymbolInfoDouble(g_sym,SYMBOL_ASK)-SymbolInfoDouble(g_sym,SYMBOL_BID))/g_point;
   if(InpMaxSpreadPt>0 && spr>InpMaxSpreadPt){ g_diagGate=StringFormat("spread %.0f > %d pt", spr, InpMaxSpreadPt); return false; }

   if(g_tradesToday>=InpMaxTrades){ g_diagGate="daily trade cap reached"; return false; }

   if(g_lastTrade>0 && (TimeCurrent()-g_lastTrade) < InpCooldownMin*60){ g_diagGate="cooldown"; return false; }

   // window (GMT)
   if(InpUseWindow)
     {
      datetime gmt = TimeGMT(); if(gmt==0) gmt=ServerToGmt(TimeCurrent());
      MqlDateTime g; TimeToStruct(gmt, g);
      bool inWin = (InpStartHour<=InpEndHour ? (g.hour>=InpStartHour && g.hour<InpEndHour)
                                             : (g.hour>=InpStartHour || g.hour<InpEndHour));
      if(!inWin){ g_diagGate=StringFormat("outside window %02d-%02d GMT", InpStartHour, InpEndHour); return false; }
     }

   string nr; int nn;
   if(NewsBlocked(nr, nn)){ g_diagGate=nr; return false; }

   g_diagGate = "OPEN";
   return true;
  }

//==================================================================
//  LIFECYCLE
//==================================================================
int OnInit()
  {
   g_sym    = _Symbol;
   g_tf     = (InpUseChartTF ? (ENUM_TIMEFRAMES)Period() : InpTF);
   g_point  = SymbolInfoDouble(g_sym, SYMBOL_POINT);
   g_digits = (int)SymbolInfoInteger(g_sym, SYMBOL_DIGITS);
   g_gmtOff = GmtOffsetHours();
   trade.SetExpertMagicNumber(InpMagic);
   LoadNews();
   UpdateFlow();
   UpdatePanel();
   Print("OrderFlowGold v3 started on ", g_sym, " ", EnumToString(g_tf));
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   CleanObjects();
  }

void OnTick()
  {
   datetime curBar = iTime(g_sym, g_tf, 0);
   bool newBar = (curBar!=g_lastBar);

   // manage every tick
   if(g_atr>0.0) ManagePositions();

   if(newBar)
     {
      g_lastBar = curBar;
      g_barsEval++;

      // reload news roughly hourly
      if(TimeCurrent()-g_newsLoad > 3600) LoadNews();

      UpdateFlow();
      DrawVwapLine();

      double score; string engine;
      int dir = EvalSignal(score, engine);

      if(GateOpen())
        {
         if(dir!=0 && score>=InpMinScore)
            OpenTrade(dir, score, engine);
         else if(dir!=0)
            g_diagGate = StringFormat("OPEN but score %.2f < %.2f", score, InpMinScore);
        }
     }

   UpdatePanel();
  }
//+------------------------------------------------------------------+
