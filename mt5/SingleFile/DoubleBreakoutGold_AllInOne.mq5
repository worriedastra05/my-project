//+------------------------------------------------------------------+
//|                                   DoubleBreakoutGold_AllInOne.mq5 |
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
//   MODULE: DBG_Dashboard.mqh
//==================================================================
//+------------------------------------------------------------------+
//|                                                 DBG_Dashboard.mqh |
//|       On-chart control panel: clock/timezone, market, strategy,   |
//|       news filter state, risk & statistics + control buttons      |
//+------------------------------------------------------------------+
#ifndef __DBG_DASHBOARD_MQH__
#define __DBG_DASHBOARD_MQH__


#define DBG_BTN_PAUSE  DBG_PREFIX+"btn_pause"
#define DBG_BTN_CLOSE  DBG_PREFIX+"btn_close"
#define DBG_BTN_MIN    DBG_PREFIX+"btn_min"

class CDbgDashboard
  {
private:
   long              m_chart;
   int               m_x;
   int               m_y;
   int               m_w;
   int               m_corner;
   int               m_fontSize;
   string            m_font;
   bool              m_minimized;
   bool              m_created;
   int               m_rowY;              // running Y while building
   color             m_cBg,m_cPanel,m_cHead,m_cLabel,m_cValue,m_cSection,m_cBorder;

   void              Rect(const string name,const int x,const int y,const int w,const int h,const color bg,const color border);
   void              Label(const string name,const int x,const int y,const string text,const color clr,const int size,const string font="");
   void              Button(const string name,const int x,const int y,const int w,const int h,const string text,const color bg,const color txt);
   void              SetText(const string name,const string text);
   void              SetColor(const string name,const color clr);
   string            N(const string tag) const { return(DBG_PREFIX+tag); }
   void              AddSection(const string tag,const string title);
   void              AddRow(const string tag,const string label);

public:
                     CDbgDashboard(void);
   void              Create(const long chart,const int corner,const int x,const int y,const int width,const int fontSize,const string font);
   void              Destroy(void);
   void              Update(const DbgPanelData &d);
   void              SetPaused(const bool paused);
   void              ToggleMinimize(void);
   bool              IsMinimized(void) const { return(m_minimized); }
   bool              Created(void) const { return(m_created); }
  };

//+------------------------------------------------------------------+
CDbgDashboard::CDbgDashboard(void)
  {
   m_chart     = 0;
   m_x         = 12;
   m_y         = 18;
   m_w         = 430;
   m_corner    = CORNER_LEFT_UPPER;
   m_fontSize  = 8;
   m_font      = "Consolas";
   m_minimized = false;
   m_created   = false;
   m_rowY      = 0;
   m_cBg       = C'18,21,27';
   m_cPanel    = C'26,31,40';
   m_cHead     = C'212,175,55';      // gold
   m_cLabel    = C'140,150,165';
   m_cValue    = C'225,230,238';
   m_cSection  = C'90,170,255';
   m_cBorder   = C'55,63,78';
  }

//+------------------------------------------------------------------+
void CDbgDashboard::Rect(const string name,const int x,const int y,const int w,const int h,const color bg,const color border)
  {
   if(ObjectFind(m_chart,name)<0)
      ObjectCreate(m_chart,name,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(m_chart,name,OBJPROP_CORNER,m_corner);
   ObjectSetInteger(m_chart,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(m_chart,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(m_chart,name,OBJPROP_XSIZE,w);
   ObjectSetInteger(m_chart,name,OBJPROP_YSIZE,h);
   ObjectSetInteger(m_chart,name,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(m_chart,name,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(m_chart,name,OBJPROP_COLOR,border);
   ObjectSetInteger(m_chart,name,OBJPROP_WIDTH,1);
   ObjectSetInteger(m_chart,name,OBJPROP_BACK,false);
   ObjectSetInteger(m_chart,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(m_chart,name,OBJPROP_SELECTED,false);
   ObjectSetInteger(m_chart,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(m_chart,name,OBJPROP_ZORDER,0);
  }

//+------------------------------------------------------------------+
void CDbgDashboard::Label(const string name,const int x,const int y,const string text,const color clr,const int size,const string font)
  {
   if(ObjectFind(m_chart,name)<0)
      ObjectCreate(m_chart,name,OBJ_LABEL,0,0,0);
   ObjectSetInteger(m_chart,name,OBJPROP_CORNER,m_corner);
   ObjectSetInteger(m_chart,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(m_chart,name,OBJPROP_YDISTANCE,y);
   ObjectSetString(m_chart,name,OBJPROP_TEXT,text);
   ObjectSetString(m_chart,name,OBJPROP_FONT,(font=="" ? m_font : font));
   ObjectSetInteger(m_chart,name,OBJPROP_FONTSIZE,size);
   ObjectSetInteger(m_chart,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(m_chart,name,OBJPROP_BACK,false);
   ObjectSetInteger(m_chart,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(m_chart,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(m_chart,name,OBJPROP_ZORDER,1);
  }

//+------------------------------------------------------------------+
void CDbgDashboard::Button(const string name,const int x,const int y,const int w,const int h,const string text,const color bg,const color txt)
  {
   if(ObjectFind(m_chart,name)<0)
      ObjectCreate(m_chart,name,OBJ_BUTTON,0,0,0);
   ObjectSetInteger(m_chart,name,OBJPROP_CORNER,m_corner);
   ObjectSetInteger(m_chart,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(m_chart,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(m_chart,name,OBJPROP_XSIZE,w);
   ObjectSetInteger(m_chart,name,OBJPROP_YSIZE,h);
   ObjectSetString(m_chart,name,OBJPROP_TEXT,text);
   ObjectSetString(m_chart,name,OBJPROP_FONT,m_font);
   ObjectSetInteger(m_chart,name,OBJPROP_FONTSIZE,m_fontSize);
   ObjectSetInteger(m_chart,name,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(m_chart,name,OBJPROP_COLOR,txt);
   ObjectSetInteger(m_chart,name,OBJPROP_BORDER_COLOR,m_cBorder);
   ObjectSetInteger(m_chart,name,OBJPROP_STATE,false);
   ObjectSetInteger(m_chart,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(m_chart,name,OBJPROP_ZORDER,2);
  }

//+------------------------------------------------------------------+
void CDbgDashboard::SetText(const string name,const string text)
  {
   if(ObjectFind(m_chart,name)>=0)
      ObjectSetString(m_chart,name,OBJPROP_TEXT,text);
  }
void CDbgDashboard::SetColor(const string name,const color clr)
  {
   if(ObjectFind(m_chart,name)>=0)
      ObjectSetInteger(m_chart,name,OBJPROP_COLOR,clr);
  }

//+------------------------------------------------------------------+
void CDbgDashboard::AddSection(const string tag,const string title)
  {
   m_rowY += 6;
   Label(N("sec_"+tag),m_x+10,m_rowY,title,m_cSection,m_fontSize);
   Rect(N("secln_"+tag),m_x+8,m_rowY+14,m_w-16,1,m_cBorder,m_cBorder);
   m_rowY += 19;
  }

//+------------------------------------------------------------------+
void CDbgDashboard::AddRow(const string tag,const string label)
  {
   Label(N("lb_"+tag),m_x+12,m_rowY,label,m_cLabel,m_fontSize);
   Label(N("vl_"+tag),m_x+112,m_rowY,"-",m_cValue,m_fontSize);
   m_rowY += 15;
  }

//+------------------------------------------------------------------+
void CDbgDashboard::Create(const long chart,const int corner,const int x,const int y,
                           const int width,const int fontSize,const string font)
  {
   m_chart    = chart;
   m_corner   = corner;
   m_x        = x;
   m_y        = y;
   m_w        = (width<340 ? 340 : width);
   m_fontSize = (fontSize<6 ? 6 : fontSize);
   m_font     = (font=="" ? "Consolas" : font);

   Destroy();

   //--- background is created first with a provisional height, resized at the end
   Rect(N("bg"),m_x,m_y,m_w,520,m_cBg,m_cBorder);
   Rect(N("hdr"),m_x,m_y,m_w,24,m_cPanel,m_cBorder);
   Label(N("title"),m_x+10,m_y+5,"DOUBLE BREAKOUT GOLD  v"+DBG_VERSION,m_cHead,m_fontSize+1,"Segoe UI Semibold");
   Button(DBG_BTN_MIN,m_x+m_w-26,m_y+4,18,16,"_",m_cPanel,m_cValue);

   m_rowY = m_y+28;

   AddSection("clk","CLOCK  &  TIMEZONE");
   AddRow("srv","Server time");
   AddRow("tz","Broker zone");
   AddRow("gmt","GMT / UTC");
   AddRow("loc","Local (PC)");
   AddRow("cities","World clock");
   AddRow("sess","Session");

   AddSection("mkt","MARKET");
   AddRow("sym","Symbol / TF");
   AddRow("quote","Bid/Ask/Spr");
   AddRow("atr","Volatility");

   AddSection("str","STRATEGY : DOUBLE BREAKOUT");
   AddRow("phase","Phase");
   AddRow("range","Range");
   AddRow("trig","Trigger");
   AddRow("pos","Position");
   AddRow("sltp","SL / TP");

   AddSection("nws","NEWS  FILTER  (MT5 CALENDAR)");
   AddRow("nstat","Status");
   AddRow("nnext","Next event");
   AddRow("nwin","Window");

   AddSection("rsk","RISK  &  STATISTICS");
   AddRow("bal","Account");
   AddRow("day","Today");
   AddRow("risk","Risk / trade");
   AddRow("guard","Guards");

   m_rowY += 6;
   Rect(N("ftln"),m_x+8,m_rowY,m_w-16,1,m_cBorder,m_cBorder);
   m_rowY += 6;
   Label(N("vl_status"),m_x+12,m_rowY+5,"INITIALISING",m_cValue,m_fontSize);
   Button(DBG_BTN_PAUSE,m_x+m_w-166,m_rowY+2,78,20,"PAUSE",C'40,48,60',m_cValue);
   Button(DBG_BTN_CLOSE,m_x+m_w-84,m_rowY+2,76,20,"CLOSE ALL",C'70,35,40',C'255,190,190');
   m_rowY += 30;

   int total = m_rowY-m_y;
   ObjectSetInteger(m_chart,N("bg"),OBJPROP_YSIZE,total);

   m_created = true;
   ChartRedraw(m_chart);
  }

//+------------------------------------------------------------------+
void CDbgDashboard::Destroy(void)
  {
   ObjectsDeleteAll(m_chart,DBG_PREFIX);
   m_created = false;
   ChartRedraw(m_chart);
  }

//+------------------------------------------------------------------+
void CDbgDashboard::ToggleMinimize(void)
  {
   m_minimized = !m_minimized;
   //--- hide/show every object except header, title, and the minimise button
   string keep[3];
   keep[0]=N("bg"); keep[1]=N("hdr"); keep[2]=N("title");
   for(int i=ObjectsTotal(m_chart)-1;i>=0;i--)
     {
      string nm = ObjectName(m_chart,i);
      if(StringFind(nm,DBG_PREFIX)!=0) continue;
      if(nm==keep[0] || nm==keep[1] || nm==keep[2] || nm==DBG_BTN_MIN) continue;
      ObjectSetInteger(m_chart,nm,OBJPROP_TIMEFRAMES,(m_minimized ? OBJ_NO_PERIODS : OBJ_ALL_PERIODS));
     }
   ObjectSetInteger(m_chart,N("bg"),OBJPROP_YSIZE,(m_minimized ? 24 : m_rowY-m_y));
   ObjectSetString(m_chart,DBG_BTN_MIN,OBJPROP_TEXT,(m_minimized ? "+" : "_"));
   ObjectSetInteger(m_chart,DBG_BTN_MIN,OBJPROP_STATE,false);
   ChartRedraw(m_chart);
  }

//+------------------------------------------------------------------+
void CDbgDashboard::SetPaused(const bool paused)
  {
   if(ObjectFind(m_chart,DBG_BTN_PAUSE)<0) return;
   ObjectSetString(m_chart,DBG_BTN_PAUSE,OBJPROP_TEXT,(paused ? "RESUME" : "PAUSE"));
   ObjectSetInteger(m_chart,DBG_BTN_PAUSE,OBJPROP_BGCOLOR,(paused ? C'80,60,20' : C'40,48,60'));
   ObjectSetInteger(m_chart,DBG_BTN_PAUSE,OBJPROP_STATE,false);
  }

//+------------------------------------------------------------------+
void CDbgDashboard::Update(const DbgPanelData &d)
  {
   if(!m_created || m_minimized) return;

   SetText(N("vl_srv"),d.srvTime);
   SetText(N("vl_tz"),d.tzLabel);
   SetText(N("vl_gmt"),d.gmtTime);
   SetText(N("vl_loc"),d.localTime);
   SetText(N("vl_cities"),d.cityTimes);
   SetText(N("vl_sess"),d.sessionLine);

   SetText(N("vl_sym"),d.symTf);
   SetText(N("vl_quote"),d.quoteLine);
   SetColor(N("vl_quote"),d.quoteColor);
   SetText(N("vl_atr"),d.atrLine);

   SetText(N("vl_phase"),d.phaseText);
   SetColor(N("vl_phase"),d.phaseColor);
   SetText(N("vl_range"),d.rangeLine);
   SetText(N("vl_trig"),d.triggerLine);
   SetText(N("vl_pos"),d.posLine);
   SetColor(N("vl_pos"),d.posColor);
   SetText(N("vl_sltp"),d.slTpLine);

   SetText(N("vl_nstat"),d.newsStatus);
   SetColor(N("vl_nstat"),d.newsColor);
   SetText(N("vl_nnext"),d.nextNews);
   SetText(N("vl_nwin"),d.newsWindow);

   SetText(N("vl_bal"),d.balLine);
   SetText(N("vl_day"),d.dayLine);
   SetColor(N("vl_day"),d.dayColor);
   SetText(N("vl_risk"),d.riskLine);
   SetText(N("vl_guard"),d.guardLine);

   SetText(N("vl_status"),d.statusText);
   SetColor(N("vl_status"),d.statusColor);

   ChartRedraw(m_chart);
  }

#endif // __DBG_DASHBOARD_MQH__
//+------------------------------------------------------------------+

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
      MqlDateTime g; ZeroMemory(g); TimeToStruct(TZ.GmtNow(),g);
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
   trade.SetExpertMagicNumber((ulong)InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

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
