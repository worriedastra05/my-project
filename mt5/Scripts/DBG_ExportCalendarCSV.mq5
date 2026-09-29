//+------------------------------------------------------------------+
//|                                        DBG_ExportCalendarCSV.mq5 |
//|   Exports the MT5 economic calendar to a CSV file so that the    |
//|   news filter of "Double Breakout Gold EA" also works inside     |
//|   the Strategy Tester.                                           |
//|                                                                   |
//|   Run it ONCE on a live/demo connection, then backtest.          |
//|   Output (COMMON\Files\DBG_News.csv by default):                 |
//|      event_time,currency,importance,event_name                   |
//|      2026.09.29 14:30:00,USD,3,Core PCE Price Index              |
//|   Times are SERVER times (same base the EA compares against).    |
//+------------------------------------------------------------------+
#property copyright "Double Breakout Gold EA"
#property version   "1.00"
#property script_show_inputs

input datetime InpFrom      = D'2020.01.01 00:00';  // Export from
input datetime InpTo        = D'2030.01.01 00:00';  // Export to
input string   InpFile      = "DBG_News.csv";       // Output file
input bool     InpCommon    = true;                 // Write to COMMON folder
input int      InpMinImportance = 2;                // Min importance (1=low 2=med 3=high)
input string   InpCurrencies= "USD,EUR,GBP,JPY,CHF,CAD,AUD,NZD,CNY"; // Currencies (empty = all)

//+------------------------------------------------------------------+
bool CurrencyWanted(const string cur,const string list)
  {
   if(StringLen(list)==0) return(true);
   return(StringFind(list,cur)>=0);
  }

//+------------------------------------------------------------------+
void OnStart(void)
  {
   MqlCalendarValue values[];
   int total = CalendarValueHistory(values,InpFrom,InpTo,NULL,NULL);
   if(total<=0)
     {
      PrintFormat("No calendar data (%d). Make sure the terminal is connected and the calendar is enabled.",GetLastError());
      return;
     }

   int flags = FILE_WRITE|FILE_TXT|FILE_ANSI|(InpCommon ? FILE_COMMON : 0);
   int h = FileOpen(InpFile,flags);
   if(h==INVALID_HANDLE)
     {
      PrintFormat("Cannot create %s, error %d",InpFile,GetLastError());
      return;
     }

   FileWrite(h,"event_time,currency,importance,event_name");

   string list = InpCurrencies;
   StringToUpper(list);

   int written=0;
   for(int i=0;i<total;i++)
     {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id,ev)) continue;
      if(ev.time_mode!=CALENDAR_TIMEMODE_DATETIME) continue;

      MqlCalendarCountry ct;
      if(!CalendarCountryById(ev.country_id,ct)) continue;

      int imp = 1;
      if(ev.importance==CALENDAR_IMPORTANCE_HIGH)          imp=3;
      else if(ev.importance==CALENDAR_IMPORTANCE_MODERATE) imp=2;
      if(imp<InpMinImportance) continue;

      string cur = ct.currency;
      StringToUpper(cur);
      if(!CurrencyWanted(cur,list)) continue;

      string name = ev.name;
      StringReplace(name,","," ");
      StringReplace(name,"\"","");

      FileWrite(h,StringFormat("%s,%s,%d,%s",
                               TimeToString(values[i].time,TIME_DATE|TIME_SECONDS),
                               cur,imp,name));
      written++;
     }

   FileClose(h);
   PrintFormat("Exported %d of %d calendar events to %s%s",written,total,
               (InpCommon ? "COMMON\\Files\\" : "MQL5\\Files\\"),InpFile);
  }
//+------------------------------------------------------------------+
