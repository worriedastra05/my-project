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
   dt.year=year; dt.mon=month; dt.day=1; dt.hour=hour; dt.min=0; dt.sec=0;
   datetime first = StructToTime(dt);
   MqlDateTime f; TimeToStruct(first,f);
   int delta = (weekday - f.day_of_week + 7)%7;
   datetime res = first + (datetime)delta*86400;
   if(nth>1) res += (datetime)(nth-1)*7*86400;
   return(res);
  }

//--- last given weekday of a month
datetime DbgLastWeekday(const int year,const int month,const int weekday,const int hour)
  {
   int nm = month+1, ny = year;
   if(nm>12) { nm=1; ny++; }
   MqlDateTime dt;
   dt.year=ny; dt.mon=nm; dt.day=1; dt.hour=hour; dt.min=0; dt.sec=0;
   datetime firstNext = StructToTime(dt);
   datetime cur = firstNext - 86400;      // last day of the requested month
   MqlDateTime c; TimeToStruct(cur,c);
   int back = (c.day_of_week - weekday + 7)%7;
   return(cur - (datetime)back*86400);
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
