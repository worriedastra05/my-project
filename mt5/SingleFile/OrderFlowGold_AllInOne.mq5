//+------------------------------------------------------------------+
//|                                         OrderFlowGold_AllInOne.mq5 |
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

//==================================================================
//   MODULE: DBG_Utils.mqh
//==================================================================
//+------------------------------------------------------------------+
//|                                                     DBG_Utils.mqh |
//|                  Double Breakout Gold EA - shared types & helpers |
//|                                      https://github.com/ (c) 2026 |
//+------------------------------------------------------------------+
#ifndef __DBG_UTILS_MQH__
#define __DBG_UTILS_MQH__

#define DBG_VERSION "1.00"
#define DBG_PREFIX  "DBG_"

//+------------------------------------------------------------------+
//| Enumerations                                                     |
//+------------------------------------------------------------------+
enum ENUM_DBG_TIMEBASE
  {
   DBG_TB_GMT    = 0,  // Session times are GMT/UTC
   DBG_TB_SERVER = 1   // Session times are Broker/Server time
  };

enum ENUM_DBG_MODE
  {
   DBG_MODE_REBREAK  = 0, // Range break -> pullback -> RE-BREAK (classic double breakout)
   DBG_MODE_TWOLEVEL = 1, // Two levels: Session range + Previous Day H/L
   DBG_MODE_BOTH     = 2  // Both filters required (strictest)
  };

enum ENUM_DBG_SLMODE
  {
   DBG_SL_STRUCTURE = 0, // Pullback structure (swing) + buffer
   DBG_SL_RANGE     = 1, // Opposite side of the session range
   DBG_SL_ATR       = 2  // ATR multiple from entry
  };

enum ENUM_DBG_ENTRY
  {
   DBG_ENTRY_STOP  = 0, // Pending STOP order at the 2nd breakout level
   DBG_ENTRY_CLOSE = 1  // Market entry on bar CLOSE beyond the level
  };

enum ENUM_DBG_NEWSIMP
  {
   DBG_IMP_HIGH     = 0, // High impact only
   DBG_IMP_HIGH_MED = 1, // High + Medium
   DBG_IMP_ALL      = 2  // All events
  };

enum ENUM_DBG_PHASE
  {
   DBG_PH_PRERANGE = 0,
   DBG_PH_BUILDING = 1,
   DBG_PH_ARMED    = 2,
   DBG_PH_BREAK1   = 3,
   DBG_PH_PULLBACK = 4,
   DBG_PH_TRIGGER  = 5,
   DBG_PH_INTRADE  = 6,
   DBG_PH_DONE     = 7,
   DBG_PH_BLOCKED  = 8
  };

//+------------------------------------------------------------------+
//| Panel data container (filled by the EA, rendered by dashboard)   |
//+------------------------------------------------------------------+
struct DbgPanelData
  {
   //--- clock / timezone block
   string            srvTime;
   string            tzLabel;
   string            gmtTime;
   string            localTime;
   string            cityTimes;
   string            sessionLine;
   //--- market block
   string            symTf;
   string            quoteLine;
   color             quoteColor;
   string            atrLine;
   //--- strategy block
   string            phaseText;
   color             phaseColor;
   string            rangeLine;
   string            triggerLine;
   string            posLine;
   color             posColor;
   string            slTpLine;
   //--- news block
   string            newsStatus;
   color             newsColor;
   string            nextNews;
   string            newsWindow;
   //--- risk block
   string            balLine;
   string            dayLine;
   color             dayColor;
   string            riskLine;
   string            guardLine;
   //--- footer
   string            statusText;
   color             statusColor;
  };

//+------------------------------------------------------------------+
//| Small helpers                                                    |
//+------------------------------------------------------------------+
double DbgAsk(const string sym) { return(SymbolInfoDouble(sym,SYMBOL_ASK)); }
double DbgBid(const string sym) { return(SymbolInfoDouble(sym,SYMBOL_BID)); }

double DbgPoint(const string sym) { return(SymbolInfoDouble(sym,SYMBOL_POINT)); }

int DbgDigits(const string sym) { return((int)SymbolInfoInteger(sym,SYMBOL_DIGITS)); }

double DbgSpreadPoints(const string sym)
  {
   double p = DbgPoint(sym);
   if(p<=0.0) return(0.0);
   return((DbgAsk(sym)-DbgBid(sym))/p);
  }

double DbgNormPrice(const string sym,const double price)
  {
   double ts = SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_SIZE);
   if(ts<=0.0) ts = DbgPoint(sym);
   if(ts<=0.0) return(price);
   return(NormalizeDouble(MathRound(price/ts)*ts,DbgDigits(sym)));
  }

//--- broker minimum distance for SL/TP (in price units)
double DbgStopsLevelPrice(const string sym)
  {
   long lvl = SymbolInfoInteger(sym,SYMBOL_TRADE_STOPS_LEVEL);
   long frz = SymbolInfoInteger(sym,SYMBOL_TRADE_FREEZE_LEVEL);
   long use = (lvl>frz ? lvl : frz);
   return((double)use*DbgPoint(sym));
  }

string DbgPriceStr(const string sym,const double price)
  {
   if(price<=0.0) return("-");
   return(DoubleToString(price,DbgDigits(sym)));
  }

string DbgMoney(const double v)
  {
   string s = DoubleToString(MathAbs(v),2);
   return((v<0 ? "-" : "")+s);
  }

string DbgHM(const datetime t)   { return(TimeToString(t,TIME_MINUTES)); }
string DbgHMS(const datetime t)  { return(TimeToString(t,TIME_SECONDS)); }
string DbgFull(const datetime t) { return(TimeToString(t,TIME_DATE|TIME_SECONDS)); }

//--- "01:23:45" / "23:45" style duration
string DbgDuration(const int seconds)
  {
   int s = (int)MathAbs(seconds);
   int h = s/3600;
   int m = (s%3600)/60;
   int ss= s%60;
   if(h>0) return(StringFormat("%02d:%02d:%02d",h,m,ss));
   return(StringFormat("%02d:%02d",m,ss));
  }

//--- trims and uppercases a comma separated list into an array
int DbgSplitList(const string src,string &out[])
  {
   ArrayFree(out);
   string tmp = src;
   StringTrimLeft(tmp); StringTrimRight(tmp);
   if(StringLen(tmp)==0) return(0);
   string parts[];
   int n = StringSplit(tmp,StringGetCharacter(",",0),parts);
   if(n<=0) return(0);
   ArrayResize(out,n);
   int k=0;
   for(int i=0;i<n;i++)
     {
      string p = parts[i];
      StringTrimLeft(p); StringTrimRight(p);
      StringToUpper(p);
      if(StringLen(p)>0) { out[k]=p; k++; }
     }
   ArrayResize(out,k);
   return(k);
  }

bool DbgInList(const string &list[],const string value)
  {
   for(int i=0;i<ArraySize(list);i++)
      if(list[i]==value) return(true);
   return(false);
  }

//+------------------------------------------------------------------+
//| Daylight saving helpers (rule based, no terminal dependency)     |
//+------------------------------------------------------------------+
//--- returns the datetime of the n-th weekday of a month (UTC based)
datetime DbgNthWeekday(const int year,const int month,const int weekday,const int nth,const int hour)
  {
   MqlDateTime dt;
   ZeroMemory(dt);
   dt.year=year; dt.mon=month; dt.day=1; dt.hour=hour; dt.min=0; dt.sec=0;
   datetime first = StructToTime(dt);
   MqlDateTime f; TimeToStruct(first,f);
   int delta = (weekday - f.day_of_week + 7)%7;
   datetime res = (datetime)((long)first + (long)delta*86400);
   if(nth>1) res = (datetime)((long)res + (long)(nth-1)*7*86400);
   return(res);
  }

//--- last given weekday of a month
datetime DbgLastWeekday(const int year,const int month,const int weekday,const int hour)
  {
   int nm = month+1, ny = year;
   if(nm>12) { nm=1; ny++; }
   MqlDateTime dt;
   ZeroMemory(dt);
   dt.year=ny; dt.mon=nm; dt.day=1; dt.hour=hour; dt.min=0; dt.sec=0;
   datetime firstNext = StructToTime(dt);
   datetime cur = firstNext - 86400;      // last day of the requested month
   MqlDateTime c; TimeToStruct(cur,c);
   int back = (c.day_of_week - weekday + 7)%7;
   return((datetime)((long)cur - (long)back*86400));
  }

//--- US DST: 2nd Sunday of March 07:00 UTC -> 1st Sunday of November 06:00 UTC
bool DbgIsUsDst(const datetime gmt)
  {
   MqlDateTime d; TimeToStruct(gmt,d);
   datetime start = DbgNthWeekday(d.year,3,0,2,7);
   datetime end   = DbgNthWeekday(d.year,11,0,1,6);
   return(gmt>=start && gmt<end);
  }

//--- EU DST: last Sunday of March 01:00 UTC -> last Sunday of October 01:00 UTC
bool DbgIsEuDst(const datetime gmt)
  {
   MqlDateTime d; TimeToStruct(gmt,d);
   datetime start = DbgLastWeekday(d.year,3,0,1);
   datetime end   = DbgLastWeekday(d.year,10,0,1);
   return(gmt>=start && gmt<end);
  }

//--- AU (Sydney) DST: 1st Sunday of October 16:00 UTC -> 1st Sunday of April 16:00 UTC
bool DbgIsAuDst(const datetime gmt)
  {
   MqlDateTime d; TimeToStruct(gmt,d);
   datetime start = DbgNthWeekday(d.year,10,0,1,16);
   datetime end   = DbgNthWeekday(d.year,4,0,1,16);
   return(gmt>=start || gmt<end);
  }

#endif // __DBG_UTILS_MQH__
//+------------------------------------------------------------------+

//==================================================================
//   MODULE: DBG_TimeZone.mqh
//==================================================================
//+------------------------------------------------------------------+
//|                                                  DBG_TimeZone.mqh |
//|   Broker timezone / DST auto-detection + world clock + sessions   |
//|                                                                   |
//|   Two independent detectors are used:                             |
//|     1) Live   : TimeTradeServer() - TimeGMT()  (needs correct PC) |
//|     2) History: week-opening hour of H1 quotes vs. known FX open  |
//|                 (Sunday 22:00 UTC in US-summer, 23:00 in winter)  |
//|   The history method also works inside the Strategy Tester where  |
//|   TimeGMT() is unreliable.                                        |
//+------------------------------------------------------------------+
#ifndef __DBG_TIMEZONE_MQH__
#define __DBG_TIMEZONE_MQH__


class CDbgTimeZone
  {
private:
   string            m_symbol;
   int               m_offsetLive;      // seconds, server - GMT (live method)
   int               m_offsetHist;      // seconds, server - GMT (history method)
   int               m_offset;          // seconds, the one actually used
   bool              m_histValid;
   bool              m_manual;
   datetime          m_lastEstimate;
   int               m_histWinterOff;   // detected standard (winter) offset
   int               m_histSummerOff;   // detected DST (summer) offset
   bool              m_supportsDst;

   int               EstimateFromHistory(void);

public:
                     CDbgTimeZone(void);
   void              Init(const string symbol,const int manualOffsetHours,const bool useManual);
   void              Refresh(const bool force=false);

   //--- conversions
   int               OffsetSec(void) const { return(m_offset); }
   double            OffsetHours(void) const { return(m_offset/3600.0); }
   datetime          ServerNow(void) const { return(TimeTradeServer()); }
   datetime          ToGmt(const datetime serverTime) const { return((datetime)((long)serverTime-(long)m_offset)); }
   datetime          ToServer(const datetime gmtTime) const { return((datetime)((long)gmtTime+(long)m_offset)); }
   datetime          GmtNow(void) const { return(ToGmt(TimeTradeServer())); }

   //--- world clocks (returned as datetime carrying local wall time)
   datetime          NewYork(void)  const;
   datetime          London(void)   const;
   datetime          Tokyo(void)    const;
   datetime          Sydney(void)   const;

   //--- descriptions
   string            ZoneLabel(void) const;
   string            ZoneGuess(void) const;
   bool              SupportsDst(void) const { return(m_supportsDst); }
   bool              HistoryValid(void) const { return(m_histValid); }
   string            CityLine(void) const;
   string            SessionLine(void) const;
   bool              IsSessionOpen(const string name) const;
  };

//+------------------------------------------------------------------+
CDbgTimeZone::CDbgTimeZone(void)
  {
   m_symbol       = _Symbol;
   m_offsetLive   = 0;
   m_offsetHist   = 0;
   m_offset       = 0;
   m_histValid    = false;
   m_manual       = false;
   m_lastEstimate = 0;
   m_histWinterOff= 0;
   m_histSummerOff= 0;
   m_supportsDst  = false;
  }

//+------------------------------------------------------------------+
void CDbgTimeZone::Init(const string symbol,const int manualOffsetHours,const bool useManual)
  {
   m_symbol = symbol;
   m_manual = useManual;
   if(useManual)
     {
      m_offset     = manualOffsetHours*3600;
      m_offsetLive = m_offset;
      m_offsetHist = m_offset;
      m_histValid  = true;
      return;
     }
   Refresh(true);
  }

//+------------------------------------------------------------------+
void CDbgTimeZone::Refresh(const bool force)
  {
   if(m_manual) return;

   //--- live method (rounded to full 30 minutes to remove quote latency)
   long diff = (long)TimeTradeServer()-(long)TimeGMT();
   m_offsetLive = (int)(MathRound(diff/1800.0)*1800);

   //--- history method (expensive -> refresh once per hour)
   if(force || (TimeTradeServer()-m_lastEstimate)>3600)
     {
      int est = EstimateFromHistory();
      if(est!=INT_MIN) { m_offsetHist = est; m_histValid = true; }
      m_lastEstimate = TimeTradeServer();
     }

   //--- decide which one to trust
   bool tester = (bool)MQLInfoInteger(MQL_TESTER);
   if(m_histValid && (tester || MathAbs(m_offsetHist-m_offsetLive)>1800))
      m_offset = m_offsetHist;       // history wins (tester / wrong PC clock)
   else
      m_offset = m_offsetLive;
  }

//+------------------------------------------------------------------+
//| Vote for the GMT offset using the weekly opening bar             |
//+------------------------------------------------------------------+
int CDbgTimeZone::EstimateFromHistory(void)
  {
   MqlRates r[];
   ArraySetAsSeries(r,false);
   int need   = 24*7*14;                       // ~14 weeks of H1
   int copied = CopyRates(m_symbol,PERIOD_H1,0,need,r);
   if(copied<300) return(INT_MIN);

   int votesW[27]; // winter (standard) offsets  -12..+14
   int votesS[27]; // summer (DST) offsets
   ArrayInitialize(votesW,0);
   ArrayInitialize(votesS,0);

   for(int i=1;i<copied;i++)
     {
      if((long)r[i].time-(long)r[i-1].time < 24*3600) continue;   // not a weekend gap
      datetime t = r[i].time;                                     // first bar of the week (server)
      for(int o=-12;o<=14;o++)
        {
         datetime gmt = (datetime)((long)t-(long)o*3600);
         MqlDateTime g; TimeToStruct(gmt,g);
         if(g.day_of_week!=0) continue;                           // must be Sunday in GMT
         bool usDst = DbgIsUsDst(gmt);
         int  wanted= (usDst ? 22 : 23);                          // FX/Gold week open = NY Sun 18:00
         if(g.hour!=wanted) continue;
         if(usDst) votesS[o+12]++; else votesW[o+12]++;
        }
     }

   int bestW=-1,bw=0,bestS=-1,bs=0;
   for(int k=0;k<27;k++)
     {
      if(votesW[k]>bw) { bw=votesW[k]; bestW=k-12; }
      if(votesS[k]>bs) { bs=votesS[k]; bestS=k-12; }
     }
   if(bw==0 && bs==0) return(INT_MIN);

   m_histWinterOff = (bestW!=-1 && bw>0 ? bestW*3600 : (bestS-1)*3600);
   m_histSummerOff = (bestS!=-1 && bs>0 ? bestS*3600 : (bestW+1)*3600);
   m_supportsDst   = (bw>0 && bs>0 && m_histWinterOff!=m_histSummerOff);

   //--- which regime are we in right now?
   long     curOff      = (m_supportsDst ? m_histSummerOff : m_histWinterOff);
   datetime nowGmtGuess = (datetime)((long)TimeTradeServer()-curOff);
   bool nowUsDst = DbgIsUsDst(nowGmtGuess);
   if(!m_supportsDst) return(bw>=bs ? m_histWinterOff : m_histSummerOff);
   return(nowUsDst ? m_histSummerOff : m_histWinterOff);
  }

//+------------------------------------------------------------------+
datetime CDbgTimeZone::NewYork(void) const
  {
   datetime g = GmtNow();
   return((datetime)((long)g+(long)(DbgIsUsDst(g) ? -4 : -5)*3600));
  }
datetime CDbgTimeZone::London(void) const
  {
   datetime g = GmtNow();
   return((datetime)((long)g+(long)(DbgIsEuDst(g) ? 1 : 0)*3600));
  }
datetime CDbgTimeZone::Tokyo(void) const  { return((datetime)((long)GmtNow()+9*3600)); }
datetime CDbgTimeZone::Sydney(void) const
  {
   datetime g = GmtNow();
   return((datetime)((long)g+(long)(DbgIsAuDst(g) ? 11 : 10)*3600));
  }

//+------------------------------------------------------------------+
string CDbgTimeZone::ZoneLabel(void) const
  {
   double h = OffsetHours();
   string sign = (h<0 ? "-" : "+");
   double a = MathAbs(h);
   int hh = (int)a;
   int mm = (int)MathRound((a-hh)*60.0);
   string off = StringFormat("GMT%s%d",sign,hh);
   if(mm!=0) off += StringFormat(":%02d",mm);
   string src = m_manual ? "manual" : (m_histValid && m_offset==m_offsetHist ? "history-detected" : "live-detected");
   string dst = "";
   if(m_supportsDst) dst = (MathAbs(m_offset-m_histSummerOff)<60 ? " | DST: ON" : " | DST: OFF");
   else if(m_histValid)        dst = " | DST: broker fixed";
   return(off+"  ("+src+")"+dst);
  }

//+------------------------------------------------------------------+
string CDbgTimeZone::ZoneGuess(void) const
  {
   int h = (int)MathRound(OffsetHours());
   switch(h)
     {
      case  0: return("UTC / London (winter)");
      case  1: return("Europe/London (BST) or Central Europe (winter)");
      case  2: return("Europe/Berlin-Athens (typical FX broker, winter)");
      case  3: return("Europe/Athens-Moscow (typical FX broker, summer)");
      case -5: return("America/New_York (EST)");
      case -4: return("America/New_York (EDT)");
      case  8: return("Asia/Singapore-Hong_Kong");
      case  9: return("Asia/Tokyo");
      case 10: return("Australia/Sydney (AEST)");
      case 11: return("Australia/Sydney (AEDT)");
      default: return(StringFormat("UTC%+d region",h));
     }
  }

//+------------------------------------------------------------------+
string CDbgTimeZone::CityLine(void) const
  {
   return(StringFormat("NY %s | LON %s | TOK %s | SYD %s",
                       DbgHM(NewYork()),DbgHM(London()),DbgHM(Tokyo()),DbgHM(Sydney())));
  }

//+------------------------------------------------------------------+
//| Session state in GMT: Sydney 21-06, Tokyo 00-09, London 07-16,   |
//| New York 12-21                                                   |
//+------------------------------------------------------------------+
bool CDbgTimeZone::IsSessionOpen(const string name) const
  {
   datetime g = GmtNow();
   MqlDateTime d; TimeToStruct(g,d);
   if(d.day_of_week==6) return(false);
   int h = d.hour;
   if(name=="SYDNEY") return(h>=21 || h<6);
   if(name=="TOKYO")  return(h>=0 && h<9);
   if(name=="LONDON") return(h>=7 && h<16);
   if(name=="NEWYORK")return(h>=12 && h<21);
   return(false);
  }

//+------------------------------------------------------------------+
string CDbgTimeZone::SessionLine(void) const
  {
   string open = "";
   if(IsSessionOpen("SYDNEY"))  open += "SYD ";
   if(IsSessionOpen("TOKYO"))   open += "TOK ";
   if(IsSessionOpen("LONDON"))  open += "LON ";
   if(IsSessionOpen("NEWYORK")) open += "NY ";
   StringTrimRight(open);
   if(StringLen(open)==0) open = "CLOSED / quiet";
   if(IsSessionOpen("LONDON") && IsSessionOpen("NEWYORK")) open += "  <OVERLAP>";
   return(open);
  }

#endif // __DBG_TIMEZONE_MQH__
//+------------------------------------------------------------------+

//==================================================================
//   MODULE: DBG_News.mqh
//==================================================================
//+------------------------------------------------------------------+
//|                                                      DBG_News.mqh |
//|        MT5 Economic-Calendar news filter (pre/post news windows)  |
//|                                                                   |
//|  - Reads the built-in MT5 calendar (CalendarValueHistory)         |
//|  - Filters by currency + importance                               |
//|  - Blocks trading X minutes BEFORE and Y minutes AFTER an event   |
//|  - Optional CSV fallback so the filter also works in the tester   |
//|    CSV format (comma separated, no quotes needed):                |
//|        2026.09.29 14:30:00,USD,3,Core PCE Price Index             |
//|    importance: 3 = high, 2 = medium, 1 = low   (times = SERVER)   |
//+------------------------------------------------------------------+
#ifndef __DBG_NEWS_MQH__
#define __DBG_NEWS_MQH__


struct DbgNewsEvent
  {
   datetime          time;        // event time in SERVER time
   string            currency;
   string            name;
   int               importance;  // 1=low 2=medium 3=high
  };

class CDbgNews
  {
private:
   bool              m_enabled;
   int               m_minsBefore;
   int               m_minsAfter;
   int               m_shiftMin;          // manual correction of calendar time
   ENUM_DBG_NEWSIMP  m_impMode;
   string            m_currencies[];
   bool              m_allCurrencies;
   bool              m_useCsv;
   string            m_csvFile;
   bool              m_csvCommon;
   datetime          m_lastLoad;
   int               m_reloadMin;
   DbgNewsEvent      m_events[];
   bool              m_apiOk;
   string            m_lastError;

   bool              ImportanceOk(const int imp) const;
   bool              CurrencyOk(const string cur) const;
   int               LoadFromApi(void);
   int               LoadFromCsv(void);
   void              SortEvents(void);

public:
                     CDbgNews(void);
   void              Configure(const bool enabled,const string currencyList,const string symbol,
                               const ENUM_DBG_NEWSIMP imp,const int minsBefore,const int minsAfter,
                               const bool useCsv,const string csvFile,const bool csvCommon,
                               const int reloadMinutes,const int shiftMinutes);
   bool              Refresh(const bool force=false);
   int               Total(void) const { return(ArraySize(m_events)); }
   bool              Enabled(void) const { return(m_enabled); }
   bool              ApiOk(void) const { return(m_apiOk); }
   string            LastError(void) const { return(m_lastError); }
   string            CurrencyText(void) const;

   //--- blocking window
   bool              IsBlocked(const datetime nowServer,DbgNewsEvent &ev,int &secondsToResume);
   //--- next upcoming event (any direction)
   bool              NextEvent(const datetime nowServer,DbgNewsEvent &ev,int &secondsToEvent);
   //--- is an event about to start within n seconds (used for pre-news position close)
   bool              EventWithin(const datetime nowServer,const int seconds,DbgNewsEvent &ev);
   static string     ImpText(const int imp);
  };

//+------------------------------------------------------------------+
CDbgNews::CDbgNews(void)
  {
   m_enabled       = false;
   m_minsBefore    = 30;
   m_minsAfter     = 30;
   m_shiftMin      = 0;
   m_impMode       = DBG_IMP_HIGH;
   m_allCurrencies = false;
   m_useCsv        = true;
   m_csvFile       = "DBG_News.csv";
   m_csvCommon     = true;
   m_lastLoad      = 0;
   m_reloadMin     = 30;
   m_apiOk         = false;
   m_lastError     = "";
  }

//+------------------------------------------------------------------+
void CDbgNews::Configure(const bool enabled,const string currencyList,const string symbol,
                         const ENUM_DBG_NEWSIMP imp,const int minsBefore,const int minsAfter,
                         const bool useCsv,const string csvFile,const bool csvCommon,
                         const int reloadMinutes,const int shiftMinutes)
  {
   m_enabled    = enabled;
   m_impMode    = imp;
   m_minsBefore = minsBefore;
   m_minsAfter  = minsAfter;
   m_useCsv     = useCsv;
   m_csvFile    = csvFile;
   m_csvCommon  = csvCommon;
   m_reloadMin  = (reloadMinutes<1 ? 1 : reloadMinutes);
   m_shiftMin   = shiftMinutes;

   string list = currencyList;
   StringTrimLeft(list); StringTrimRight(list);
   StringToUpper(list);
   m_allCurrencies = false;
   ArrayFree(m_currencies);

   if(list=="ALL")
     {
      m_allCurrencies = true;
     }
   else
      if(StringLen(list)==0 || list=="AUTO")
        {
         string base  = SymbolInfoString(symbol,SYMBOL_CURRENCY_BASE);
         string prof  = SymbolInfoString(symbol,SYMBOL_CURRENCY_PROFIT);
         string marg  = SymbolInfoString(symbol,SYMBOL_CURRENCY_MARGIN);
         string tmp[];
         ArrayResize(tmp,0);
         string cand[3];
         cand[0]=base; cand[1]=prof; cand[2]=marg;
         for(int i=0;i<3;i++)
           {
            string c = cand[i];
            StringToUpper(c);
            if(StringLen(c)!=3) continue;
            if(c=="XAU" || c=="XAG") continue;          // metals have no calendar of their own
            if(DbgInList(tmp,c)) continue;
            ArrayResize(tmp,ArraySize(tmp)+1);
            tmp[ArraySize(tmp)-1]=c;
           }
         if(ArraySize(tmp)==0) { ArrayResize(tmp,1); tmp[0]="USD"; }
         ArrayResize(m_currencies,ArraySize(tmp));
         for(int i=0;i<ArraySize(tmp);i++) m_currencies[i]=tmp[i];
        }
      else
         DbgSplitList(list,m_currencies);
  }

//+------------------------------------------------------------------+
string CDbgNews::CurrencyText(void) const
  {
   if(m_allCurrencies) return("ALL");
   string s="";
   for(int i=0;i<ArraySize(m_currencies);i++)
      s += (i>0 ? "," : "")+m_currencies[i];
   return(StringLen(s)>0 ? s : "-");
  }

//+------------------------------------------------------------------+
string CDbgNews::ImpText(const int imp)
  {
   if(imp>=3) return("HIGH");
   if(imp==2) return("MED");
   return("LOW");
  }

//+------------------------------------------------------------------+
bool CDbgNews::ImportanceOk(const int imp) const
  {
   if(m_impMode==DBG_IMP_ALL) return(imp>=1);
   if(m_impMode==DBG_IMP_HIGH_MED) return(imp>=2);
   return(imp>=3);
  }

//+------------------------------------------------------------------+
bool CDbgNews::CurrencyOk(const string cur) const
  {
   if(m_allCurrencies) return(true);
   for(int i=0;i<ArraySize(m_currencies);i++)
      if(m_currencies[i]==cur) return(true);
   return(false);
  }

//+------------------------------------------------------------------+
void CDbgNews::SortEvents(void)
  {
   int n = ArraySize(m_events);
   for(int i=1;i<n;i++)
     {
      DbgNewsEvent key = m_events[i];
      int j=i-1;
      while(j>=0 && m_events[j].time>key.time) { m_events[j+1]=m_events[j]; j--; }
      m_events[j+1]=key;
     }
  }

//+------------------------------------------------------------------+
int CDbgNews::LoadFromApi(void)
  {
   MqlCalendarValue values[];
   datetime now  = TimeTradeServer();
   datetime from = now-(datetime)(2*86400);
   datetime to   = now+(datetime)(4*86400);

   int total = CalendarValueHistory(values,from,to,NULL,NULL);
   if(total<=0)
     {
      m_lastError = "CalendarValueHistory returned "+IntegerToString(total)+" (err "+IntegerToString(GetLastError())+")";
      ResetLastError();
      return(0);
     }

   ArrayFree(m_events);
   int added=0;
   for(int i=0;i<total;i++)
     {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id,ev)) continue;
      if(ev.time_mode!=CALENDAR_TIMEMODE_DATETIME) continue;    // skip "tentative"/"all day"

      MqlCalendarCountry ct;
      if(!CalendarCountryById(ev.country_id,ct)) continue;

      int imp = 1;
      if(ev.importance==CALENDAR_IMPORTANCE_HIGH)      imp=3;
      else if(ev.importance==CALENDAR_IMPORTANCE_MODERATE) imp=2;

      string cur = ct.currency;
      StringToUpper(cur);
      if(!CurrencyOk(cur))   continue;
      if(!ImportanceOk(imp)) continue;

      ArrayResize(m_events,added+1);
      m_events[added].time       = values[i].time+(datetime)(m_shiftMin*60);
      m_events[added].currency   = cur;
      m_events[added].name       = ev.name;
      m_events[added].importance = imp;
      added++;
     }
   SortEvents();
   return(added);
  }

//+------------------------------------------------------------------+
int CDbgNews::LoadFromCsv(void)
  {
   int flags = FILE_READ|FILE_TXT|FILE_ANSI|(m_csvCommon ? FILE_COMMON : 0);
   int h = FileOpen(m_csvFile,flags);
   if(h==INVALID_HANDLE)
     {
      m_lastError = "CSV '"+m_csvFile+"' not found (err "+IntegerToString(GetLastError())+")";
      ResetLastError();
      return(0);
     }

   ArrayFree(m_events);
   int added=0;
   while(!FileIsEnding(h))
     {
      string line = FileReadString(h);
      StringTrimLeft(line); StringTrimRight(line);
      if(StringLen(line)<10) continue;
      if(StringFind(line,"event_time")>=0) continue;             // header
      string f[];
      int n = StringSplit(line,StringGetCharacter(",",0),f);
      if(n<4) continue;
      for(int i=0;i<n;i++) { StringTrimLeft(f[i]); StringTrimRight(f[i]); }

      datetime t = StringToTime(f[0]);
      if(t<=0) continue;
      string cur = f[1]; StringToUpper(cur);
      int imp = (int)StringToInteger(f[2]);
      string nm = f[3];
      for(int i=4;i<n;i++) nm += ","+f[i];                       // names may contain commas
      StringReplace(nm,"\"","");

      if(!CurrencyOk(cur))   continue;
      if(!ImportanceOk(imp)) continue;

      ArrayResize(m_events,added+1);
      m_events[added].time       = t+(datetime)(m_shiftMin*60);
      m_events[added].currency   = cur;
      m_events[added].name       = nm;
      m_events[added].importance = imp;
      added++;
     }
   FileClose(h);
   SortEvents();
   return(added);
  }

//+------------------------------------------------------------------+
bool CDbgNews::Refresh(const bool force)
  {
   if(!m_enabled) return(false);
   datetime now = TimeTradeServer();
   if(!force && (now-m_lastLoad) < (datetime)(m_reloadMin*60)) return(true);
   m_lastLoad = now;
   m_lastError= "";

   int n = 0;
   if(!MQLInfoInteger(MQL_TESTER))
      n = LoadFromApi();
   else
     {
      //--- newer terminals expose the calendar in the tester as well: try the API first
      n = LoadFromApi();
      if(n<=0 && m_useCsv) n = LoadFromCsv();
     }
   if(n<=0 && m_useCsv && !MQLInfoInteger(MQL_TESTER) && ArraySize(m_events)==0)
      n = LoadFromCsv();

   m_apiOk = (n>0);
   return(m_apiOk);
  }

//+------------------------------------------------------------------+
bool CDbgNews::IsBlocked(const datetime nowServer,DbgNewsEvent &ev,int &secondsToResume)
  {
   secondsToResume = 0;
   if(!m_enabled) return(false);
   bool blocked=false;
   datetime resume=0;
   for(int i=0;i<ArraySize(m_events);i++)
     {
      datetime start = m_events[i].time-(datetime)(m_minsBefore*60);
      datetime end   = m_events[i].time+(datetime)(m_minsAfter*60);
      if(nowServer>=start && nowServer<=end)
        {
         if(!blocked || end>resume) { ev = m_events[i]; resume = end; }
         blocked = true;
        }
     }
   if(blocked) secondsToResume = (int)(resume-nowServer);
   return(blocked);
  }

//+------------------------------------------------------------------+
bool CDbgNews::NextEvent(const datetime nowServer,DbgNewsEvent &ev,int &secondsToEvent)
  {
   secondsToEvent = 0;
   for(int i=0;i<ArraySize(m_events);i++)
     {
      if(m_events[i].time>=nowServer)
        {
         ev = m_events[i];
         secondsToEvent = (int)(m_events[i].time-nowServer);
         return(true);
        }
     }
   return(false);
  }

//+------------------------------------------------------------------+
bool CDbgNews::EventWithin(const datetime nowServer,const int seconds,DbgNewsEvent &ev)
  {
   for(int i=0;i<ArraySize(m_events);i++)
     {
      long diff = (long)m_events[i].time-(long)nowServer;
      if(diff>=0 && diff<=seconds) { ev = m_events[i]; return(true); }
     }
   return(false);
  }

#endif // __DBG_NEWS_MQH__
//+------------------------------------------------------------------+

//==================================================================
//   MODULE: OFG_Flow.mqh
//==================================================================
//+------------------------------------------------------------------+
//|                                                      OFG_Flow.mqh |
//|        Order-flow engine: tick classification, delta, CVD, VWAP   |
//|                                                                   |
//|  Aggressor side per tick:                                         |
//|    1) TICK_FLAG_BUY / TICK_FLAG_SELL when the broker supplies it  |
//|    2) last vs bid/ask  (Lee & Ready 1991 quote rule)              |
//|    3) mid-price tick rule (uptick = buy, downtick = sell,         |
//|       unchanged = repeat previous sign)  <- CFD gold ends up here |
//|                                                                   |
//|  Fallback when ticks are unavailable (tester / thin history):     |
//|    candle proxy  delta = tickvol * ((C-L)-(H-C)) / (H-L)          |
//+------------------------------------------------------------------+
#ifndef __OFG_FLOW_MQH__
#define __OFG_FLOW_MQH__

enum ENUM_OFG_SOURCE
  {
   OFG_SRC_AUTO   = 0, // Auto (real ticks, candle proxy as fallback)
   OFG_SRC_TICKS  = 1, // Real ticks only
   OFG_SRC_PROXY  = 2  // Candle proxy only
  };

struct OfgBar
  {
   datetime          time;
   double            buyVol;
   double            sellVol;
   double            delta;
   double            open;
   double            high;
   double            low;
   double            close;
   double            pvSum;     // sum(typical price * volume) for VWAP
   double            vSum;
   double            pv2Sum;    // sum(price^2 * volume) for VWAP sigma
   int               ticks;
  };

class COfgFlow
  {
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_tf;
   int               m_maxBars;
   OfgBar            m_bars[];        // ascending, last element = forming bar
   long              m_lastMsc;
   int               m_lastSign;
   double            m_lastMid;
   ENUM_OFG_SOURCE   m_source;
   bool              m_ticksOk;
   int               m_tickBatch;
   datetime          m_sessionStart;  // CVD reset anchor (server time)
   double            m_cvd;
   double            m_cvdHist[];     // CVD value at the close of each stored bar
   string            m_status;
   datetime          m_lastProxy;

   int               FindBar(const datetime barTime);
   int               NewBar(const datetime barTime,const double price);
   void              Trim(void);
   void              BuildFromCandles(void);

public:
                     COfgFlow(void);
   void              Init(const string symbol,const ENUM_TIMEFRAMES tf,const int maxBars,
                          const ENUM_OFG_SOURCE source,const int tickBatch);
   void              ResetSession(const datetime sessionStartServer);
   void              Update(void);

   //--- shift 0 = forming bar, 1 = last closed bar ...
   int               Count(void) const { return(ArraySize(m_bars)); }
   bool              Valid(const int shift) const { return(shift>=0 && shift<ArraySize(m_bars)); }
   double            Delta(const int shift) const;
   double            BuyVol(const int shift) const;
   double            SellVol(const int shift) const;
   int               Ticks(const int shift) const;
   double            BuyPct(const int shift) const;
   double            Cvd(void) const { return(m_cvd); }
   double            CvdAt(const int shift) const;
   double            CvdSlope(const int bars) const;
   double            DeltaZ(const int shift,const int lookback) const;
   double            DeltaAbsAvg(const int lookback) const;
   double            Efficiency(const int shift) const;   // price move per unit of delta (normalised 0..1+)
   double            TickRate(void) const;                // ticks per minute of the forming bar
   double            AvgTicks(const int lookback) const;
   double            Vwap(void) const;
   double            VwapSigma(void) const;
   bool              TicksOk(void) const { return(m_ticksOk); }
   string            Status(void) const { return(m_status); }
   string            SourceText(void) const;
  };

//+------------------------------------------------------------------+
COfgFlow::COfgFlow(void)
  {
   m_symbol      = _Symbol;
   m_tf          = PERIOD_M5;
   m_maxBars     = 300;
   m_lastMsc     = 0;
   m_lastSign    = 1;
   m_lastMid     = 0.0;
   m_source      = OFG_SRC_AUTO;
   m_ticksOk     = false;
   m_tickBatch   = 2000;
   m_sessionStart= 0;
   m_cvd         = 0.0;
   m_status      = "init";
   m_lastProxy   = 0;
  }

//+------------------------------------------------------------------+
void COfgFlow::Init(const string symbol,const ENUM_TIMEFRAMES tf,const int maxBars,
                    const ENUM_OFG_SOURCE source,const int tickBatch)
  {
   m_symbol    = symbol;
   m_tf        = tf;
   m_maxBars   = (maxBars<60 ? 60 : maxBars);
   m_source    = source;
   m_tickBatch = (tickBatch<200 ? 200 : tickBatch);
   ArrayFree(m_bars);
   ArrayFree(m_cvdHist);
   m_lastMsc   = 0;
   m_cvd       = 0.0;
   //--- always seed the history from candles so the z-scores have a sample
   BuildFromCandles();
   if(m_source!=OFG_SRC_PROXY)
     {
      int n = ArraySize(m_bars);
      if(n>1)
        {
         datetime lastT = m_bars[n-1].time;      // forming bar
         ArrayResize(m_bars,n-1);
         ArrayResize(m_cvdHist,n-1);
         m_cvd     = m_cvdHist[n-2];
         m_lastMsc = (long)lastT*1000-1;         // ticks rebuild the forming bar
        }
     }
  }

//+------------------------------------------------------------------+
void COfgFlow::ResetSession(const datetime sessionStartServer)
  {
   m_sessionStart = sessionStartServer;
   m_cvd          = 0.0;
  }

//+------------------------------------------------------------------+
int COfgFlow::FindBar(const datetime barTime)
  {
   int n = ArraySize(m_bars);
   for(int i=n-1;i>=0 && i>=n-5;i--)
      if(m_bars[i].time==barTime) return(i);
   return(-1);
  }

//+------------------------------------------------------------------+
int COfgFlow::NewBar(const datetime barTime,const double price)
  {
   int n = ArraySize(m_bars);
   ArrayResize(m_bars,n+1);
   ArrayResize(m_cvdHist,n+1);
   m_bars[n].time    = barTime;
   m_bars[n].buyVol  = 0.0;
   m_bars[n].sellVol = 0.0;
   m_bars[n].delta   = 0.0;
   m_bars[n].open    = price;
   m_bars[n].high    = price;
   m_bars[n].low     = price;
   m_bars[n].close   = price;
   m_bars[n].pvSum   = 0.0;
   m_bars[n].vSum    = 0.0;
   m_bars[n].pv2Sum  = 0.0;
   m_bars[n].ticks   = 0;
   m_cvdHist[n]      = m_cvd;
   return(n);
  }

//+------------------------------------------------------------------+
void COfgFlow::Trim(void)
  {
   int n = ArraySize(m_bars);
   if(n<=m_maxBars) return;
   int cut = n-m_maxBars;
   for(int i=0;i<m_maxBars;i++)
     {
      m_bars[i]    = m_bars[i+cut];
      m_cvdHist[i] = m_cvdHist[i+cut];
     }
   ArrayResize(m_bars,m_maxBars);
   ArrayResize(m_cvdHist,m_maxBars);
  }

//+------------------------------------------------------------------+
//| Candle based delta proxy (used in the tester / as a fallback)    |
//+------------------------------------------------------------------+
void COfgFlow::BuildFromCandles(void)
  {
   MqlRates r[];
   ArraySetAsSeries(r,false);
   int copied = CopyRates(m_symbol,m_tf,0,m_maxBars,r);
   if(copied<10) { m_status="no rates"; return; }

   ArrayFree(m_bars);
   ArrayFree(m_cvdHist);
   ArrayResize(m_bars,copied);
   ArrayResize(m_cvdHist,copied);
   double cvd = 0.0;
   for(int i=0;i<copied;i++)
     {
      double rng = r[i].high-r[i].low;
      double v   = (double)r[i].tick_volume;
      double d   = 0.0;
      if(rng>0.0) d = v*(((r[i].close-r[i].low)-(r[i].high-r[i].close))/rng);
      double buy = (v+d)/2.0;
      double sel = (v-d)/2.0;
      double tp  = (r[i].high+r[i].low+r[i].close)/3.0;

      m_bars[i].time    = r[i].time;
      m_bars[i].buyVol  = buy;
      m_bars[i].sellVol = sel;
      m_bars[i].delta   = d;
      m_bars[i].open    = r[i].open;
      m_bars[i].high    = r[i].high;
      m_bars[i].low     = r[i].low;
      m_bars[i].close   = r[i].close;
      m_bars[i].pvSum   = tp*v;
      m_bars[i].vSum    = v;
      m_bars[i].pv2Sum  = tp*tp*v;
      m_bars[i].ticks   = (int)r[i].tick_volume;
      cvd += d;
      m_cvdHist[i] = cvd;
     }
   m_cvd    = cvd;
   m_status = "candle proxy";
  }

//+------------------------------------------------------------------+
void COfgFlow::Update(void)
  {
   if(m_source==OFG_SRC_PROXY)
     {
      if(TimeCurrent()-m_lastProxy>=10) { BuildFromCandles(); m_lastProxy=TimeCurrent(); }
      return;
     }

   MqlTick t[];
   long now = (long)TimeCurrent()*1000;
   long from = m_lastMsc;
   if(from<=0)
     {
      //--- first call: start from the beginning of the visible window
      int secs = PeriodSeconds(m_tf)*30;
      from = now-(long)secs*1000;
     }

   int n = CopyTicksRange(m_symbol,t,COPY_TICKS_ALL,(ulong)(from+1),0);
   if(n<=0)
     {
      if(m_source==OFG_SRC_AUTO && !m_ticksOk && TimeCurrent()-m_lastProxy>=10)
        { BuildFromCandles(); m_lastProxy=TimeCurrent(); }
      if(!m_ticksOk) m_status = "ticks unavailable";
      return;
     }
   if(n>m_tickBatch)
     {
      //--- avoid huge first-load loops
      int skip = n-m_tickBatch;
      for(int i=0;i<m_tickBatch;i++) t[i] = t[i+skip];
      ArrayResize(t,m_tickBatch);
      n = m_tickBatch;
     }

   int period = PeriodSeconds(m_tf);
   for(int i=0;i<n;i++)
     {
      if(t[i].time_msc<=m_lastMsc) continue;
      m_lastMsc = t[i].time_msc;

      double bid = t[i].bid;
      double ask = t[i].ask;
      double mid = ((bid>0.0 && ask>0.0) ? (bid+ask)/2.0 : (t[i].last>0.0 ? t[i].last : 0.0));
      if(mid<=0.0) continue;
      double px  = (t[i].last>0.0 ? t[i].last : mid);

      //--- volume
      double vol = 1.0;
      if(t[i].volume_real>0.0)      vol = t[i].volume_real;
      else if(t[i].volume>0)        vol = (double)t[i].volume;

      //--- aggressor side
      int sign = 0;
      if((t[i].flags&TICK_FLAG_BUY)!=0)       sign = 1;
      else if((t[i].flags&TICK_FLAG_SELL)!=0) sign = -1;
      else if(t[i].last>0.0 && bid>0.0 && ask>0.0)
        {
         if(t[i].last>=ask)      sign = 1;
         else if(t[i].last<=bid) sign = -1;
        }
      if(sign==0)
        {
         if(m_lastMid>0.0)
           {
            if(mid>m_lastMid)      sign = 1;
            else if(mid<m_lastMid) sign = -1;
            else                   sign = m_lastSign;
           }
         else sign = m_lastSign;
        }
      m_lastMid  = mid;
      m_lastSign = sign;

      //--- bucket
      datetime bt = (datetime)(((long)t[i].time/period)*period);
      int idx = FindBar(bt);
      if(idx<0)
        {
         int last = ArraySize(m_bars)-1;
         if(last>=0 && bt<m_bars[last].time) continue;   // stale tick
         idx = NewBar(bt,px);
        }

      if(sign>0) m_bars[idx].buyVol  += vol;
      else       m_bars[idx].sellVol += vol;
      m_bars[idx].delta  = m_bars[idx].buyVol-m_bars[idx].sellVol;
      m_bars[idx].close  = px;
      if(px>m_bars[idx].high) m_bars[idx].high = px;
      if(px<m_bars[idx].low)  m_bars[idx].low  = px;
      m_bars[idx].pvSum  += px*vol;
      m_bars[idx].vSum   += vol;
      m_bars[idx].pv2Sum += px*px*vol;
      m_bars[idx].ticks++;

      m_cvd += (sign>0 ? vol : -vol);
      m_cvdHist[idx] = m_cvd;
     }

   Trim();
   m_ticksOk = true;
   m_status  = "live ticks";
  }

//+------------------------------------------------------------------+
//| Accessors (shift 0 = forming bar)                                |
//+------------------------------------------------------------------+
double COfgFlow::Delta(const int shift) const
  {
   int i = ArraySize(m_bars)-1-shift;
   if(i<0) return(0.0);
   return(m_bars[i].delta);
  }
double COfgFlow::BuyVol(const int shift) const
  {
   int i = ArraySize(m_bars)-1-shift;
   if(i<0) return(0.0);
   return(m_bars[i].buyVol);
  }
double COfgFlow::SellVol(const int shift) const
  {
   int i = ArraySize(m_bars)-1-shift;
   if(i<0) return(0.0);
   return(m_bars[i].sellVol);
  }
int COfgFlow::Ticks(const int shift) const
  {
   int i = ArraySize(m_bars)-1-shift;
   if(i<0) return(0);
   return(m_bars[i].ticks);
  }
double COfgFlow::BuyPct(const int shift) const
  {
   double b = BuyVol(shift), s = SellVol(shift);
   double t = b+s;
   if(t<=0.0) return(50.0);
   return(b/t*100.0);
  }
double COfgFlow::CvdAt(const int shift) const
  {
   int i = ArraySize(m_cvdHist)-1-shift;
   if(i<0) return(0.0);
   return(m_cvdHist[i]);
  }
double COfgFlow::CvdSlope(const int bars) const
  {
   if(ArraySize(m_cvdHist)<bars+2) return(0.0);
   return(CvdAt(1)-CvdAt(1+bars));
  }
double COfgFlow::DeltaAbsAvg(const int lookback) const
  {
   int n = ArraySize(m_bars);
   int cnt = 0; double sum = 0.0;
   for(int s=1;s<=lookback;s++)
     {
      int i = n-1-s;
      if(i<0) break;
      sum += MathAbs(m_bars[i].delta);
      cnt++;
     }
   if(cnt<5) return(0.0);
   return(sum/cnt);
  }
double COfgFlow::DeltaZ(const int shift,const int lookback) const
  {
   int n = ArraySize(m_bars);
   int cnt=0; double sum=0.0,sum2=0.0;
   for(int s=shift+1;s<=shift+lookback;s++)
     {
      int i = n-1-s;
      if(i<0) break;
      double d = m_bars[i].delta;
      sum += d; sum2 += d*d; cnt++;
     }
   if(cnt<10) return(0.0);
   double mean = sum/cnt;
   double var  = sum2/cnt-mean*mean;
   if(var<=0.0) return(0.0);
   double sd = MathSqrt(var);
   if(sd<=0.0) return(0.0);
   return((Delta(shift)-mean)/sd);
  }
//--- how much price actually moved per unit of delta (0 = full absorption)
double COfgFlow::Efficiency(const int shift) const
  {
   int i = ArraySize(m_bars)-1-shift;
   if(i<0) return(0.0);
   double d = MathAbs(m_bars[i].delta);
   if(d<=0.0) return(0.0);
   double avg = DeltaAbsAvg(50);
   if(avg<=0.0) return(0.0);
   double move = MathAbs(m_bars[i].close-m_bars[i].open);
   double rng  = m_bars[i].high-m_bars[i].low;
   if(rng<=0.0) return(0.0);
   //--- normalised: body share of the range scaled by relative delta size
   return((move/rng)/(d/avg));
  }
double COfgFlow::TickRate(void) const
  {
   int n = ArraySize(m_bars);
   if(n<1) return(0.0);
   datetime bt = m_bars[n-1].time;
   double elapsed = (double)(TimeCurrent()-bt);
   if(elapsed<5.0) elapsed = 5.0;
   return(m_bars[n-1].ticks/(elapsed/60.0));
  }
double COfgFlow::AvgTicks(const int lookback) const
  {
   int n = ArraySize(m_bars);
   int cnt=0; double sum=0.0;
   for(int s=1;s<=lookback;s++)
     {
      int i=n-1-s;
      if(i<0) break;
      sum += m_bars[i].ticks; cnt++;
     }
   if(cnt<3) return(0.0);
   return(sum/cnt);
  }
//--- session VWAP built from the stored bars (from the session anchor)
double COfgFlow::Vwap(void) const
  {
   double pv=0.0,v=0.0;
   for(int i=0;i<ArraySize(m_bars);i++)
     {
      if(m_sessionStart>0 && m_bars[i].time<m_sessionStart) continue;
      pv += m_bars[i].pvSum;
      v  += m_bars[i].vSum;
     }
   if(v<=0.0) return(0.0);
   return(pv/v);
  }
double COfgFlow::VwapSigma(void) const
  {
   double pv=0.0,v=0.0,pv2=0.0;
   for(int i=0;i<ArraySize(m_bars);i++)
     {
      if(m_sessionStart>0 && m_bars[i].time<m_sessionStart) continue;
      pv  += m_bars[i].pvSum;
      v   += m_bars[i].vSum;
      pv2 += m_bars[i].pv2Sum;
     }
   if(v<=0.0) return(0.0);
   double mean = pv/v;
   double var  = pv2/v-mean*mean;
   if(var<=0.0) return(0.0);
   return(MathSqrt(var));
  }
string COfgFlow::SourceText(void) const
  {
   if(m_source==OFG_SRC_PROXY) return("candle proxy");
   if(m_source==OFG_SRC_TICKS) return(m_ticksOk ? "real ticks" : "ticks (waiting)");
   return(m_ticksOk ? "real ticks" : "candle proxy");
  }

#endif // __OFG_FLOW_MQH__
//+------------------------------------------------------------------+

//==================================================================
//   MODULE: OFG_Panel.mqh
//==================================================================
//+------------------------------------------------------------------+
//|                                                     OFG_Panel.mqh |
//|     Generic on-chart dashboard: sections + label/value rows +     |
//|     footer status line and control buttons                        |
//+------------------------------------------------------------------+
#ifndef __OFG_PANEL_MQH__
#define __OFG_PANEL_MQH__

#define OFG_PREFIX   "OFG_"
#define OFG_BTN_PAUSE OFG_PREFIX+"btn_pause"
#define OFG_BTN_CLOSE OFG_PREFIX+"btn_close"
#define OFG_BTN_MIN   OFG_PREFIX+"btn_min"

class COfgPanel
  {
private:
   long              m_chart;
   int               m_x,m_y,m_w,m_corner,m_fs;
   string            m_font;
   int               m_rowY;
   int               m_height;
   bool              m_created;
   bool              m_minimized;
   color             m_cBg,m_cPanel,m_cHead,m_cLabel,m_cValue,m_cSection,m_cBorder;

   string            N(const string tag) const { return(OFG_PREFIX+tag); }
   void              Rect(const string name,const int x,const int y,const int w,const int h,const color bg,const color border);
   void              Text(const string name,const int x,const int y,const string txt,const color clr,const int size,const string font);
   void              Button(const string name,const int x,const int y,const int w,const int h,const string txt,const color bg,const color fg);

public:
                     COfgPanel(void);
   void              Create(const long chart,const int corner,const int x,const int y,
                            const int width,const int fontSize,const string font,const string title);
   void              AddSection(const string title);
   void              AddRow(const string tag,const string label);
   void              Finish(void);
   void              SetValue(const string tag,const string txt,const color clr=clrNONE);
   void              SetStatus(const string txt,const color clr);
   void              SetPaused(const bool paused);
   void              ToggleMinimize(void);
   void              Destroy(void);
   bool              Created(void) const { return(m_created); }
   bool              Minimized(void) const { return(m_minimized); }
   void              Redraw(void) { ChartRedraw(m_chart); }
  };

//+------------------------------------------------------------------+
COfgPanel::COfgPanel(void)
  {
   m_chart=0; m_x=12; m_y=100; m_w=470; m_corner=CORNER_LEFT_UPPER; m_fs=8;
   m_font="Consolas"; m_rowY=0; m_height=0; m_created=false; m_minimized=false;
   m_cBg      = C'18,21,27';
   m_cPanel   = C'26,31,40';
   m_cHead    = C'212,175,55';
   m_cLabel   = C'140,150,165';
   m_cValue   = C'225,230,238';
   m_cSection = C'90,170,255';
   m_cBorder  = C'55,63,78';
  }

//+------------------------------------------------------------------+
void COfgPanel::Rect(const string name,const int x,const int y,const int w,const int h,const color bg,const color border)
  {
   if(ObjectFind(m_chart,name)<0) ObjectCreate(m_chart,name,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(m_chart,name,OBJPROP_CORNER,m_corner);
   ObjectSetInteger(m_chart,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(m_chart,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(m_chart,name,OBJPROP_XSIZE,w);
   ObjectSetInteger(m_chart,name,OBJPROP_YSIZE,h);
   ObjectSetInteger(m_chart,name,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(m_chart,name,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(m_chart,name,OBJPROP_COLOR,border);
   ObjectSetInteger(m_chart,name,OBJPROP_BACK,false);
   ObjectSetInteger(m_chart,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(m_chart,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(m_chart,name,OBJPROP_ZORDER,0);
  }

//+------------------------------------------------------------------+
void COfgPanel::Text(const string name,const int x,const int y,const string txt,const color clr,const int size,const string font)
  {
   if(ObjectFind(m_chart,name)<0) ObjectCreate(m_chart,name,OBJ_LABEL,0,0,0);
   ObjectSetInteger(m_chart,name,OBJPROP_CORNER,m_corner);
   ObjectSetInteger(m_chart,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(m_chart,name,OBJPROP_YDISTANCE,y);
   ObjectSetString(m_chart,name,OBJPROP_TEXT,txt);
   ObjectSetString(m_chart,name,OBJPROP_FONT,font);
   ObjectSetInteger(m_chart,name,OBJPROP_FONTSIZE,size);
   ObjectSetInteger(m_chart,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(m_chart,name,OBJPROP_BACK,false);
   ObjectSetInteger(m_chart,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(m_chart,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(m_chart,name,OBJPROP_ZORDER,1);
  }

//+------------------------------------------------------------------+
void COfgPanel::Button(const string name,const int x,const int y,const int w,const int h,const string txt,const color bg,const color fg)
  {
   if(ObjectFind(m_chart,name)<0) ObjectCreate(m_chart,name,OBJ_BUTTON,0,0,0);
   ObjectSetInteger(m_chart,name,OBJPROP_CORNER,m_corner);
   ObjectSetInteger(m_chart,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(m_chart,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(m_chart,name,OBJPROP_XSIZE,w);
   ObjectSetInteger(m_chart,name,OBJPROP_YSIZE,h);
   ObjectSetString(m_chart,name,OBJPROP_TEXT,txt);
   ObjectSetString(m_chart,name,OBJPROP_FONT,m_font);
   ObjectSetInteger(m_chart,name,OBJPROP_FONTSIZE,m_fs);
   ObjectSetInteger(m_chart,name,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(m_chart,name,OBJPROP_COLOR,fg);
   ObjectSetInteger(m_chart,name,OBJPROP_BORDER_COLOR,m_cBorder);
   ObjectSetInteger(m_chart,name,OBJPROP_STATE,false);
   ObjectSetInteger(m_chart,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(m_chart,name,OBJPROP_ZORDER,2);
  }

//+------------------------------------------------------------------+
void COfgPanel::Create(const long chart,const int corner,const int x,const int y,
                       const int width,const int fontSize,const string font,const string title)
  {
   m_chart  = chart;
   m_corner = corner;
   m_x      = x;
   m_y      = y;
   m_w      = (width<360 ? 360 : width);
   m_fs     = (fontSize<6 ? 6 : fontSize);
   m_font   = (font=="" ? "Consolas" : font);
   Destroy();

   Rect(N("bg"),m_x,m_y,m_w,600,m_cBg,m_cBorder);
   Rect(N("hdr"),m_x,m_y,m_w,24,m_cPanel,m_cBorder);
   Text(N("title"),m_x+10,m_y+5,title,m_cHead,m_fs+1,"Segoe UI Semibold");
   Button(OFG_BTN_MIN,m_x+m_w-26,m_y+4,18,16,"_",m_cPanel,m_cValue);
   m_rowY   = m_y+28;
   m_created= true;
  }

//+------------------------------------------------------------------+
void COfgPanel::AddSection(const string title)
  {
   m_rowY += 6;
   string tag = "sec"+IntegerToString(m_rowY);
   Text(N(tag),m_x+10,m_rowY,title,m_cSection,m_fs,m_font);
   Rect(N("ln"+tag),m_x+8,m_rowY+14,m_w-16,1,m_cBorder,m_cBorder);
   m_rowY += 19;
  }

//+------------------------------------------------------------------+
void COfgPanel::AddRow(const string tag,const string label)
  {
   Text(N("lb_"+tag),m_x+12,m_rowY,label,m_cLabel,m_fs,m_font);
   Text(N("vl_"+tag),m_x+118,m_rowY,"-",m_cValue,m_fs,m_font);
   m_rowY += 15;
  }

//+------------------------------------------------------------------+
void COfgPanel::Finish(void)
  {
   m_rowY += 6;
   Rect(N("ftln"),m_x+8,m_rowY,m_w-16,1,m_cBorder,m_cBorder);
   m_rowY += 6;
   Text(N("vl_status"),m_x+12,m_rowY+5,"INITIALISING",m_cValue,m_fs,m_font);
   Button(OFG_BTN_PAUSE,m_x+m_w-166,m_rowY+2,78,20,"PAUSE",C'40,48,60',m_cValue);
   Button(OFG_BTN_CLOSE,m_x+m_w-84,m_rowY+2,76,20,"CLOSE ALL",C'70,35,40',C'255,190,190');
   m_rowY  += 30;
   m_height = m_rowY-m_y;
   ObjectSetInteger(m_chart,N("bg"),OBJPROP_YSIZE,m_height);
   ChartRedraw(m_chart);
  }

//+------------------------------------------------------------------+
void COfgPanel::SetValue(const string tag,const string txt,const color clr)
  {
   string nm = N("vl_"+tag);
   if(ObjectFind(m_chart,nm)<0) return;
   ObjectSetString(m_chart,nm,OBJPROP_TEXT,txt);
   if(clr!=clrNONE) ObjectSetInteger(m_chart,nm,OBJPROP_COLOR,clr);
  }

//+------------------------------------------------------------------+
void COfgPanel::SetStatus(const string txt,const color clr)
  {
   string nm = N("vl_status");
   if(ObjectFind(m_chart,nm)<0) return;
   ObjectSetString(m_chart,nm,OBJPROP_TEXT,txt);
   ObjectSetInteger(m_chart,nm,OBJPROP_COLOR,clr);
  }

//+------------------------------------------------------------------+
void COfgPanel::SetPaused(const bool paused)
  {
   if(ObjectFind(m_chart,OFG_BTN_PAUSE)<0) return;
   ObjectSetString(m_chart,OFG_BTN_PAUSE,OBJPROP_TEXT,(paused ? "RESUME" : "PAUSE"));
   ObjectSetInteger(m_chart,OFG_BTN_PAUSE,OBJPROP_BGCOLOR,(paused ? C'80,60,20' : C'40,48,60'));
   ObjectSetInteger(m_chart,OFG_BTN_PAUSE,OBJPROP_STATE,false);
  }

//+------------------------------------------------------------------+
void COfgPanel::ToggleMinimize(void)
  {
   m_minimized = !m_minimized;
   for(int i=ObjectsTotal(m_chart)-1;i>=0;i--)
     {
      string nm = ObjectName(m_chart,i);
      if(StringFind(nm,OFG_PREFIX)!=0) continue;
      if(nm==N("bg") || nm==N("hdr") || nm==N("title") || nm==OFG_BTN_MIN) continue;
      ObjectSetInteger(m_chart,nm,OBJPROP_TIMEFRAMES,(m_minimized ? OBJ_NO_PERIODS : OBJ_ALL_PERIODS));
     }
   ObjectSetInteger(m_chart,N("bg"),OBJPROP_YSIZE,(m_minimized ? 24 : m_height));
   ObjectSetString(m_chart,OFG_BTN_MIN,OBJPROP_TEXT,(m_minimized ? "+" : "_"));
   ObjectSetInteger(m_chart,OFG_BTN_MIN,OBJPROP_STATE,false);
   ChartRedraw(m_chart);
  }

//+------------------------------------------------------------------+
void COfgPanel::Destroy(void)
  {
   ObjectsDeleteAll(m_chart,OFG_PREFIX);
   m_created = false;
   ChartRedraw(m_chart);
  }

#endif // __OFG_PANEL_MQH__
//+------------------------------------------------------------------+

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
