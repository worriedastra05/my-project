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

#include "DBG_Utils.mqh"

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
