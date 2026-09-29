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

#include "DBG_Utils.mqh"

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
