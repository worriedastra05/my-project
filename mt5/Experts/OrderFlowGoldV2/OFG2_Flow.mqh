//+------------------------------------------------------------------+
//|                                                     OFG2_Flow.mqh |
//|   Order-flow engine v2                                            |
//|                                                                   |
//|   Adds to v1:                                                     |
//|    * diurnal (time-of-day) normalisation of delta                 |
//|        - Hawkes literature: the exogenous baseline intensity is   |
//|          U-shaped intraday (Bacry et al. 2015; Rambaldi et al.)   |
//|        - Cont et al. (2014) show OFI/impact has strong intraday   |
//|          seasonality -> a pooled z-score is biased by time of day |
//|    * VPIN on a volume clock (Easley, Lopez de Prado & O'Hara 2012)|
//|      built from tick-rule signed volume, because Andersen &       |
//|      Bondarenko (2014) show the tick rule beats bulk volume       |
//|      classification. Optional BVC mode kept for comparison.       |
//|    * micro-price style fair value (Stoikov 2018) approximated     |
//|      from the rolling tick imbalance when no depth is available   |
//|    * self-excitation / flow intensity ratio (Hawkes proxy)        |
//|    * multi-horizon integrated OFI (Cont, Cucuringu & Zhang 2021;  |
//|      Xu, Gould & Howison multi-level OFI; Kolm et al. deep OFI)   |
//+------------------------------------------------------------------+
#ifndef __OFG2_FLOW_MQH__
#define __OFG2_FLOW_MQH__

#define OFG2_BUCKETS 288   // 5-minute buckets in a day

enum ENUM_OFG2_SOURCE
  {
   OFG2_SRC_AUTO   = 0, // Auto (real ticks, candle proxy fallback)
   OFG2_SRC_TICKS  = 1, // Real ticks only
   OFG2_SRC_PROXY  = 2  // Candle proxy only (tester)
  };

enum ENUM_OFG2_CLASS
  {
   OFG2_CLS_TICKRULE = 0, // Tick rule / Lee-Ready  (recommended)
   OFG2_CLS_BVC      = 1  // Bulk volume classification (Easley et al.)
  };

struct Ofg2Bar
  {
   datetime          time;
   double            buyVol;
   double            sellVol;
   double            delta;
   double            open,high,low,close;
   double            pvSum,vSum,pv2Sum;
   int               ticks;
  };

struct Ofg2Season
  {
   double            sum;
   double            sum2;
   int               n;
  };

class COfgFlow2
  {
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_tf;
   int               m_maxBars;
   ENUM_OFG2_SOURCE  m_source;
   ENUM_OFG2_CLASS   m_class;
   int               m_tickBatch;

   Ofg2Bar           m_bars[];
   double            m_cvdHist[];
   double            m_cvd;
   long              m_lastMsc;
   int               m_lastSign;
   double            m_lastMid;
   bool              m_ticksOk;
   datetime          m_lastProxy;
   datetime          m_sessionStart;
   string            m_status;

   //--- diurnal statistics of the bar delta
   Ofg2Season        m_season[OFG2_BUCKETS];
   datetime          m_seasonLastBar;

   //--- VPIN (volume clock)
   double            m_bucketSize;
   double            m_bucketBuy;
   double            m_bucketSell;
   double            m_vpinBuf[];
   int               m_vpinWin;
   double            m_vpin;

   //--- Hawkes-style intensity
   double            m_intFast;
   double            m_intSlow;
   datetime          m_intLast;

   //--- micro-price proxy (rolling tick imbalance)
   double            m_impBuy;
   double            m_impSell;
   double            m_impAlpha;

   int               FindBar(const datetime barTime);
   int               NewBar(const datetime barTime,const double price);
   void              Trim(void);
   void              BuildFromCandles(void);
   void              PushVolume(const double vol,const int sign);
   void              SeasonUpdate(void);
   int               BucketOf(const datetime t) const;

public:
                     COfgFlow2(void);
   void              Init(const string symbol,const ENUM_TIMEFRAMES tf,const int maxBars,
                          const ENUM_OFG2_SOURCE src,const ENUM_OFG2_CLASS cls,
                          const int tickBatch,const int vpinWindow,const double vpinBucketTicks);
   void              ResetSession(const datetime startServer);
   void              Update(void);

   //--- basic accessors (shift 0 = forming bar)
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

   //--- normalised flow measures
   double            DeltaZ(const int shift,const int lookback) const;      // pooled
   double            DeltaZSeason(const int shift) const;                   // diurnal
   double            DeltaZBest(const int shift,const int lookback) const;  // season if available
   double            IntegratedOFI(const int lookback) const;               // multi-horizon 1/3/6
   double            HorizonAgreement(void) const;                          // 0..1
   double            DeltaAbsAvg(const int lookback) const;
   double            Efficiency(const int shift) const;

   //--- microstructure extras
   double            Vpin(void) const { return(m_vpin); }
   double            Intensity(void) const;              // fast/slow tick arrival ratio
   double            Imbalance(void) const;              // 0..1 rolling tick imbalance
   double            MicroOffset(const double spread) const;  // micro-price - mid
   double            TickRate(void) const;
   double            AvgTicks(const int lookback) const;
   double            Vwap(void) const;
   double            VwapSigma(void) const;
   double            Ibs(const int shift) const;         // internal bar strength 0..1

   bool              TicksOk(void) const { return(m_ticksOk); }
   string            Status(void) const { return(m_status); }
   string            SourceText(void) const;
   int               SeasonSamples(const int shift) const;
  };

//+------------------------------------------------------------------+
COfgFlow2::COfgFlow2(void)
  {
   m_symbol=_Symbol; m_tf=PERIOD_M5; m_maxBars=400;
   m_source=OFG2_SRC_AUTO; m_class=OFG2_CLS_TICKRULE; m_tickBatch=3000;
   m_cvd=0.0; m_lastMsc=0; m_lastSign=1; m_lastMid=0.0;
   m_ticksOk=false; m_lastProxy=0; m_sessionStart=0; m_status="init";
   m_seasonLastBar=0;
   m_bucketSize=0.0; m_bucketBuy=0.0; m_bucketSell=0.0; m_vpinWin=50; m_vpin=0.0;
   m_intFast=0.0; m_intSlow=0.0; m_intLast=0;
   m_impBuy=0.0; m_impSell=0.0; m_impAlpha=0.02;
   for(int i=0;i<OFG2_BUCKETS;i++) { m_season[i].sum=0.0; m_season[i].sum2=0.0; m_season[i].n=0; }
  }

//+------------------------------------------------------------------+
void COfgFlow2::Init(const string symbol,const ENUM_TIMEFRAMES tf,const int maxBars,
                     const ENUM_OFG2_SOURCE src,const ENUM_OFG2_CLASS cls,
                     const int tickBatch,const int vpinWindow,const double vpinBucketTicks)
  {
   m_symbol   = symbol;
   m_tf       = tf;
   m_maxBars  = (maxBars<120 ? 120 : maxBars);
   m_source   = src;
   m_class    = cls;
   m_tickBatch= (tickBatch<200 ? 200 : tickBatch);
   m_vpinWin  = (vpinWindow<5 ? 5 : vpinWindow);
   m_bucketSize = (vpinBucketTicks<50.0 ? 50.0 : vpinBucketTicks);

   ArrayFree(m_bars); ArrayFree(m_cvdHist); ArrayFree(m_vpinBuf);
   m_cvd=0.0; m_lastMsc=0; m_ticksOk=false;

   BuildFromCandles();     // seed history (z-scores + diurnal stats need a sample)
   SeasonUpdate();

   if(m_source!=OFG2_SRC_PROXY)
     {
      int n=ArraySize(m_bars);
      if(n>1)
        {
         datetime lastT=m_bars[n-1].time;
         ArrayResize(m_bars,n-1);
         ArrayResize(m_cvdHist,n-1);
         m_cvd=m_cvdHist[n-2];
         m_lastMsc=(long)lastT*1000-1;
        }
     }
  }

//+------------------------------------------------------------------+
void COfgFlow2::ResetSession(const datetime startServer)
  {
   m_sessionStart=startServer;
   m_cvd=0.0;
  }

//+------------------------------------------------------------------+
int COfgFlow2::BucketOf(const datetime t) const
  {
   int secs = (int)((long)t%86400);
   int b    = secs/300;
   if(b<0) b=0;
   if(b>=OFG2_BUCKETS) b=OFG2_BUCKETS-1;
   return(b);
  }

//+------------------------------------------------------------------+
int COfgFlow2::FindBar(const datetime barTime)
  {
   int n=ArraySize(m_bars);
   for(int i=n-1;i>=0 && i>=n-5;i--)
      if(m_bars[i].time==barTime) return(i);
   return(-1);
  }

//+------------------------------------------------------------------+
int COfgFlow2::NewBar(const datetime barTime,const double price)
  {
   int n=ArraySize(m_bars);
   ArrayResize(m_bars,n+1);
   ArrayResize(m_cvdHist,n+1);
   m_bars[n].time=barTime;
   m_bars[n].buyVol=0.0; m_bars[n].sellVol=0.0; m_bars[n].delta=0.0;
   m_bars[n].open=price; m_bars[n].high=price; m_bars[n].low=price; m_bars[n].close=price;
   m_bars[n].pvSum=0.0; m_bars[n].vSum=0.0; m_bars[n].pv2Sum=0.0; m_bars[n].ticks=0;
   m_cvdHist[n]=m_cvd;
   return(n);
  }

//+------------------------------------------------------------------+
void COfgFlow2::Trim(void)
  {
   int n=ArraySize(m_bars);
   if(n<=m_maxBars) return;
   int cut=n-m_maxBars;
   for(int i=0;i<m_maxBars;i++)
     {
      m_bars[i]=m_bars[i+cut];
      m_cvdHist[i]=m_cvdHist[i+cut];
     }
   ArrayResize(m_bars,m_maxBars);
   ArrayResize(m_cvdHist,m_maxBars);
  }

//+------------------------------------------------------------------+
//| Candle proxy: BVC-style if requested, geometric otherwise        |
//+------------------------------------------------------------------+
void COfgFlow2::BuildFromCandles(void)
  {
   MqlRates r[];
   ArraySetAsSeries(r,false);
   int copied=CopyRates(m_symbol,m_tf,0,m_maxBars,r);
   if(copied<20) { m_status="no rates"; return; }

   ArrayFree(m_bars); ArrayFree(m_cvdHist);
   ArrayResize(m_bars,copied);
   ArrayResize(m_cvdHist,copied);

   //--- sigma of bar returns for the BVC normal CDF
   double sum=0.0,sum2=0.0; int cnt=0;
   for(int i=1;i<copied;i++)
     {
      double d=r[i].close-r[i-1].close;
      sum+=d; sum2+=d*d; cnt++;
     }
   double mean=(cnt>0?sum/cnt:0.0);
   double var =(cnt>0?sum2/cnt-mean*mean:0.0);
   double sd  =(var>0.0?MathSqrt(var):0.0);

   double cvd=0.0;
   for(int i=0;i<copied;i++)
     {
      double v=(double)r[i].tick_volume;
      double d=0.0;
      if(m_class==OFG2_CLS_BVC && sd>0.0 && i>0)
        {
         //--- Easley/Lopez de Prado/O'Hara bulk classification:
         //    buyVol = V * CDF(dP/sigma), logistic approximation of the normal CDF
         double x   = (r[i].close-r[i-1].close)/sd;
         double cdf = 1.0/(1.0+MathExp(-1.702*x));
         double buy = v*cdf;
         d = 2.0*buy-v;
        }
      else
        {
         double rng=r[i].high-r[i].low;
         if(rng>0.0) d=v*(((r[i].close-r[i].low)-(r[i].high-r[i].close))/rng);
        }
      double buyV=(v+d)/2.0, selV=(v-d)/2.0;
      double tp=(r[i].high+r[i].low+r[i].close)/3.0;

      m_bars[i].time=r[i].time;
      m_bars[i].buyVol=buyV; m_bars[i].sellVol=selV; m_bars[i].delta=d;
      m_bars[i].open=r[i].open; m_bars[i].high=r[i].high;
      m_bars[i].low=r[i].low;   m_bars[i].close=r[i].close;
      m_bars[i].pvSum=tp*v; m_bars[i].vSum=v; m_bars[i].pv2Sum=tp*tp*v;
      m_bars[i].ticks=(int)r[i].tick_volume;
      cvd+=d;
      m_cvdHist[i]=cvd;
     }
   m_cvd=cvd;
   m_status=(m_class==OFG2_CLS_BVC ? "candle BVC" : "candle proxy");
  }

//+------------------------------------------------------------------+
//| VPIN volume clock                                                |
//+------------------------------------------------------------------+
void COfgFlow2::PushVolume(const double vol,const int sign)
  {
   if(sign>0) m_bucketBuy+=vol; else m_bucketSell+=vol;
   double tot=m_bucketBuy+m_bucketSell;
   if(tot<m_bucketSize) return;

   double imb=MathAbs(m_bucketBuy-m_bucketSell)/tot;
   int n=ArraySize(m_vpinBuf);
   if(n<m_vpinWin) { ArrayResize(m_vpinBuf,n+1); m_vpinBuf[n]=imb; }
   else
     {
      for(int i=0;i<m_vpinWin-1;i++) m_vpinBuf[i]=m_vpinBuf[i+1];
      m_vpinBuf[m_vpinWin-1]=imb;
     }
   double s=0.0; int k=ArraySize(m_vpinBuf);
   for(int i=0;i<k;i++) s+=m_vpinBuf[i];
   m_vpin=(k>0 ? s/k : 0.0);
   m_bucketBuy=0.0; m_bucketSell=0.0;
  }

//+------------------------------------------------------------------+
//| Diurnal statistics, refreshed once per closed bar                |
//+------------------------------------------------------------------+
void COfgFlow2::SeasonUpdate(void)
  {
   int n=ArraySize(m_bars);
   if(n<2) return;
   datetime lastClosed=m_bars[n-2].time;
   if(lastClosed==m_seasonLastBar) return;
   m_seasonLastBar=lastClosed;

   for(int i=0;i<OFG2_BUCKETS;i++) { m_season[i].sum=0.0; m_season[i].sum2=0.0; m_season[i].n=0; }
   for(int i=0;i<n-1;i++)
     {
      int b=BucketOf(m_bars[i].time);
      double d=m_bars[i].delta;
      m_season[b].sum+=d;
      m_season[b].sum2+=d*d;
      m_season[b].n++;
     }
  }

//+------------------------------------------------------------------+
void COfgFlow2::Update(void)
  {
   if(m_source==OFG2_SRC_PROXY)
     {
      if(TimeCurrent()-m_lastProxy>=10) { BuildFromCandles(); SeasonUpdate(); m_lastProxy=TimeCurrent(); }
      return;
     }

   MqlTick t[];
   long now=(long)TimeCurrent()*1000;
   long from=m_lastMsc;
   if(from<=0) from=now-(long)PeriodSeconds(m_tf)*30*1000;

   int n=CopyTicksRange(m_symbol,t,COPY_TICKS_ALL,(ulong)(from+1),0);
   if(n<=0)
     {
      if(m_source==OFG2_SRC_AUTO && !m_ticksOk && TimeCurrent()-m_lastProxy>=10)
        { BuildFromCandles(); SeasonUpdate(); m_lastProxy=TimeCurrent(); }
      if(!m_ticksOk) m_status="ticks unavailable";
      return;
     }
   if(n>m_tickBatch)
     {
      int skip=n-m_tickBatch;
      for(int i=0;i<m_tickBatch;i++) t[i]=t[i+skip];
      ArrayResize(t,m_tickBatch);
      n=m_tickBatch;
     }

   int period=PeriodSeconds(m_tf);
   int newTicks=0;
   for(int i=0;i<n;i++)
     {
      if(t[i].time_msc<=m_lastMsc) continue;
      m_lastMsc=t[i].time_msc;
      newTicks++;

      double bid=t[i].bid, ask=t[i].ask;
      double mid=((bid>0.0&&ask>0.0)?(bid+ask)/2.0:(t[i].last>0.0?t[i].last:0.0));
      if(mid<=0.0) continue;
      double px=(t[i].last>0.0?t[i].last:mid);

      double vol=1.0;
      if(t[i].volume_real>0.0)  vol=t[i].volume_real;
      else if(t[i].volume>0)    vol=(double)t[i].volume;

      int sign=0;
      if((t[i].flags&TICK_FLAG_BUY)!=0)       sign=1;
      else if((t[i].flags&TICK_FLAG_SELL)!=0) sign=-1;
      else if(t[i].last>0.0 && bid>0.0 && ask>0.0)
        {
         if(t[i].last>=ask)      sign=1;
         else if(t[i].last<=bid) sign=-1;
        }
      if(sign==0)
        {
         if(m_lastMid>0.0)
           {
            if(mid>m_lastMid)      sign=1;
            else if(mid<m_lastMid) sign=-1;
            else                   sign=m_lastSign;
           }
         else sign=m_lastSign;
        }
      m_lastMid=mid;
      m_lastSign=sign;

      //--- rolling imbalance (micro-price proxy)
      m_impBuy  = (1.0-m_impAlpha)*m_impBuy  + (sign>0 ? m_impAlpha*vol : 0.0);
      m_impSell = (1.0-m_impAlpha)*m_impSell + (sign<0 ? m_impAlpha*vol : 0.0);

      PushVolume(vol,sign);

      datetime bt=(datetime)(((long)t[i].time/period)*period);
      int idx=FindBar(bt);
      if(idx<0)
        {
         int last=ArraySize(m_bars)-1;
         if(last>=0 && bt<m_bars[last].time) continue;
         idx=NewBar(bt,px);
        }

      if(sign>0) m_bars[idx].buyVol+=vol; else m_bars[idx].sellVol+=vol;
      m_bars[idx].delta=m_bars[idx].buyVol-m_bars[idx].sellVol;
      m_bars[idx].close=px;
      if(px>m_bars[idx].high) m_bars[idx].high=px;
      if(px<m_bars[idx].low)  m_bars[idx].low=px;
      m_bars[idx].pvSum+=px*vol;
      m_bars[idx].vSum+=vol;
      m_bars[idx].pv2Sum+=px*px*vol;
      m_bars[idx].ticks++;

      m_cvd+=(sign>0?vol:-vol);
      m_cvdHist[idx]=m_cvd;
     }

   //--- Hawkes-style arrival intensity (EWMA fast vs slow)
   datetime nowSrv=TimeCurrent();
   if(m_intLast>0 && nowSrv>m_intLast)
     {
      double dt=(double)(nowSrv-m_intLast);
      if(dt>0.0)
        {
         double rate=newTicks/dt;                 // ticks per second
         double af=1.0-MathExp(-dt/30.0);         // 30 s half-life-ish
         double as=1.0-MathExp(-dt/900.0);        // 15 min baseline
         m_intFast=(1.0-af)*m_intFast+af*rate;
         m_intSlow=(1.0-as)*m_intSlow+as*rate;
        }
     }
   m_intLast=nowSrv;

   Trim();
   SeasonUpdate();
   m_ticksOk=true;
   m_status="live ticks";
  }

//+------------------------------------------------------------------+
//| Accessors                                                        |
//+------------------------------------------------------------------+
double COfgFlow2::Delta(const int shift) const
  { int i=ArraySize(m_bars)-1-shift; if(i<0) return(0.0); return(m_bars[i].delta); }
double COfgFlow2::BuyVol(const int shift) const
  { int i=ArraySize(m_bars)-1-shift; if(i<0) return(0.0); return(m_bars[i].buyVol); }
double COfgFlow2::SellVol(const int shift) const
  { int i=ArraySize(m_bars)-1-shift; if(i<0) return(0.0); return(m_bars[i].sellVol); }
int COfgFlow2::Ticks(const int shift) const
  { int i=ArraySize(m_bars)-1-shift; if(i<0) return(0); return(m_bars[i].ticks); }
double COfgFlow2::BuyPct(const int shift) const
  {
   double b=BuyVol(shift),s=SellVol(shift),t=b+s;
   if(t<=0.0) return(50.0);
   return(b/t*100.0);
  }
double COfgFlow2::CvdAt(const int shift) const
  { int i=ArraySize(m_cvdHist)-1-shift; if(i<0) return(0.0); return(m_cvdHist[i]); }
double COfgFlow2::CvdSlope(const int bars) const
  {
   if(ArraySize(m_cvdHist)<bars+2) return(0.0);
   return(CvdAt(1)-CvdAt(1+bars));
  }
double COfgFlow2::DeltaAbsAvg(const int lookback) const
  {
   int n=ArraySize(m_bars),cnt=0; double sum=0.0;
   for(int s=1;s<=lookback;s++)
     {
      int i=n-1-s;
      if(i<0) break;
      sum+=MathAbs(m_bars[i].delta); cnt++;
     }
   if(cnt<5) return(0.0);
   return(sum/cnt);
  }
double COfgFlow2::DeltaZ(const int shift,const int lookback) const
  {
   int n=ArraySize(m_bars),cnt=0;
   double sum=0.0,sum2=0.0;
   for(int s=shift+1;s<=shift+lookback;s++)
     {
      int i=n-1-s;
      if(i<0) break;
      double d=m_bars[i].delta;
      sum+=d; sum2+=d*d; cnt++;
     }
   if(cnt<10) return(0.0);
   double mean=sum/cnt,var=sum2/cnt-mean*mean;
   if(var<=0.0) return(0.0);
   double sd=MathSqrt(var);
   if(sd<=0.0) return(0.0);
   return((Delta(shift)-mean)/sd);
  }
int COfgFlow2::SeasonSamples(const int shift) const
  {
   int i=ArraySize(m_bars)-1-shift;
   if(i<0) return(0);
   return(m_season[BucketOf(m_bars[i].time)].n);
  }
double COfgFlow2::DeltaZSeason(const int shift) const
  {
   int i=ArraySize(m_bars)-1-shift;
   if(i<0) return(0.0);
   int b=BucketOf(m_bars[i].time);
   if(m_season[b].n<8) return(0.0);
   double mean=m_season[b].sum/m_season[b].n;
   double var =m_season[b].sum2/m_season[b].n-mean*mean;
   if(var<=0.0) return(0.0);
   double sd=MathSqrt(var);
   if(sd<=0.0) return(0.0);
   return((m_bars[i].delta-mean)/sd);
  }
double COfgFlow2::DeltaZBest(const int shift,const int lookback) const
  {
   if(SeasonSamples(shift)>=8) return(DeltaZSeason(shift));
   return(DeltaZ(shift,lookback));
  }
//--- integrated OFI: standardised delta over 1, 3 and 6 bar horizons
double COfgFlow2::IntegratedOFI(const int lookback) const
  {
   double z1=DeltaZBest(1,lookback);
   double s3=0.0,s6=0.0;
   for(int k=1;k<=3;k++) s3+=Delta(k);
   for(int k=1;k<=6;k++) s6+=Delta(k);
   double avg=DeltaAbsAvg(lookback);
   if(avg<=0.0) return(z1);
   double z3=s3/(avg*MathSqrt(3.0));
   double z6=s6/(avg*MathSqrt(6.0));
   return(0.5*z1+0.3*z3+0.2*z6);
  }
double COfgFlow2::HorizonAgreement(void) const
  {
   double d1=Delta(1);
   double s3=0.0,s6=0.0;
   for(int k=1;k<=3;k++) s3+=Delta(k);
   for(int k=1;k<=6;k++) s6+=Delta(k);
   int agree=0;
   if(d1>0 && s3>0) agree++;
   if(d1<0 && s3<0) agree++;
   if(d1>0 && s6>0) agree++;
   if(d1<0 && s6<0) agree++;
   return(agree/2.0);
  }
double COfgFlow2::Efficiency(const int shift) const
  {
   int i=ArraySize(m_bars)-1-shift;
   if(i<0) return(0.0);
   double d=MathAbs(m_bars[i].delta);
   if(d<=0.0) return(0.0);
   double avg=DeltaAbsAvg(50);
   if(avg<=0.0) return(0.0);
   double move=MathAbs(m_bars[i].close-m_bars[i].open);
   double rng =m_bars[i].high-m_bars[i].low;
   if(rng<=0.0) return(0.0);
   return((move/rng)/(d/avg));
  }
double COfgFlow2::Ibs(const int shift) const
  {
   int i=ArraySize(m_bars)-1-shift;
   if(i<0) return(0.5);
   double rng=m_bars[i].high-m_bars[i].low;
   if(rng<=0.0) return(0.5);
   return((m_bars[i].close-m_bars[i].low)/rng);
  }
double COfgFlow2::Intensity(void) const
  {
   if(m_intSlow<=0.0000001) return(1.0);
   return(m_intFast/m_intSlow);
  }
double COfgFlow2::Imbalance(void) const
  {
   double t=m_impBuy+m_impSell;
   if(t<=0.0) return(0.5);
   return(m_impBuy/t);
  }
double COfgFlow2::MicroOffset(const double spread) const
  {
   //--- Stoikov-style: fair value leans towards the heavier side of the flow
   return((Imbalance()-0.5)*spread);
  }
double COfgFlow2::TickRate(void) const
  {
   int n=ArraySize(m_bars);
   if(n<1) return(0.0);
   double el=(double)(TimeCurrent()-m_bars[n-1].time);
   if(el<5.0) el=5.0;
   return(m_bars[n-1].ticks/(el/60.0));
  }
double COfgFlow2::AvgTicks(const int lookback) const
  {
   int n=ArraySize(m_bars),cnt=0; double sum=0.0;
   for(int s=1;s<=lookback;s++)
     {
      int i=n-1-s;
      if(i<0) break;
      sum+=m_bars[i].ticks; cnt++;
     }
   if(cnt<3) return(0.0);
   return(sum/cnt);
  }
double COfgFlow2::Vwap(void) const
  {
   double pv=0.0,v=0.0;
   for(int i=0;i<ArraySize(m_bars);i++)
     {
      if(m_sessionStart>0 && m_bars[i].time<m_sessionStart) continue;
      pv+=m_bars[i].pvSum; v+=m_bars[i].vSum;
     }
   if(v<=0.0) return(0.0);
   return(pv/v);
  }
double COfgFlow2::VwapSigma(void) const
  {
   double pv=0.0,v=0.0,pv2=0.0;
   for(int i=0;i<ArraySize(m_bars);i++)
     {
      if(m_sessionStart>0 && m_bars[i].time<m_sessionStart) continue;
      pv+=m_bars[i].pvSum; v+=m_bars[i].vSum; pv2+=m_bars[i].pv2Sum;
     }
   if(v<=0.0) return(0.0);
   double mean=pv/v,var=pv2/v-mean*mean;
   if(var<=0.0) return(0.0);
   return(MathSqrt(var));
  }
string COfgFlow2::SourceText(void) const
  {
   if(m_source==OFG2_SRC_PROXY) return(m_class==OFG2_CLS_BVC?"candle BVC":"candle proxy");
   if(m_source==OFG2_SRC_TICKS) return(m_ticksOk?"real ticks":"ticks (waiting)");
   return(m_ticksOk?"real ticks":"candle proxy");
  }

#endif // __OFG2_FLOW_MQH__
//+------------------------------------------------------------------+
