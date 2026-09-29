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
