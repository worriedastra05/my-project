//+------------------------------------------------------------------+
//|                                      CrossSectionalMomentumEA.mq5 |
//|                                                                   |
//|  CLASSICAL CROSS-SECTIONAL (RELATIVE-STRENGTH) MOMENTUM FOR MT5   |
//|                                                                   |
//|  Academic basis                                                   |
//|  --------------                                                   |
//|  1) Jegadeesh & Titman (1993, Journal of Finance) - the original  |
//|     cross-sectional momentum test: rank a universe by past        |
//|     return, buy the top fraction, sell the bottom fraction,       |
//|     rebalance periodically.                                       |
//|  2) Menkhoff, Sarno, Schmeling & Schrimpf (2012, JFE 106(3),      |
//|     660-684) "Currency momentum strategies": the same sort on FX  |
//|     against the USD produced up to ~10% p.a. with an annualised   |
//|     Sharpe of ~0.95 for MOM(1,1) - a ONE-month formation period   |
//|     and a ONE-month holding period. Longer formation windows      |
//|     were far weaker in FX (12m/12m gave ~1.89% p.a.). That is     |
//|     why the defaults below use f = 1 month, h = 1 month and NOT   |
//|     the "12-1" convention borrowed from equities.                 |
//|  3) Barroso & Santa-Clara (2015) "Momentum has its moments" and   |
//|     Daniel & Moskowitz (2016) "Momentum crashes": scaling the     |
//|     portfolio by the inverse of its own realised volatility       |
//|     roughly doubles the Sharpe ratio and removes momentum         |
//|     crashes. Implemented here as inverse-volatility weights plus  |
//|     a portfolio volatility target driven by a live covariance     |
//|     matrix estimated across the universe.                         |
//|  4) Antonacci (2014) "Dual Momentum": an absolute (time-series)   |
//|     momentum overlay on top of the relative sort. Optional.       |
//|                                                                   |
//|  The book is long/short and dollar-neutral by construction.       |
//|  Every leg carries an ATR stop-loss and take-profit, with         |
//|  optional break-even and ATR trailing.                            |
//+------------------------------------------------------------------+
#property copyright "Cross-Sectional Momentum EA"
#property version   "1.10"
#property description "Classical cross-sectional (relative-strength) momentum portfolio."
#property description "Ranks a universe, buys the top N and sells the bottom N,"
#property description "sizes by inverse volatility with a portfolio volatility target,"
#property description "and protects every leg with an ATR stop-loss / take-profit."

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Enumerations                                                      |
//+------------------------------------------------------------------+
enum ENUM_CSM_UNIVERSE
  {
   UNIV_FX_VS_USD = 0,  // FX vs USD (normalise the quote convention)
   UNIV_RAW       = 1   // Raw symbols (indices / crypto / stocks / CFDs)
  };

enum ENUM_CSM_SIGNAL
  {
   SIG_RAW_RETURN     = 0, // Raw formation return (Jegadeesh-Titman)
   SIG_VOL_ADJ_RETURN = 1  // Volatility-adjusted return (risk-adjusted score)
  };

enum ENUM_CSM_SIZING
  {
   SIZE_FIXED_LOT    = 0, // Fixed lot per leg
   SIZE_RISK_PERCENT = 1, // Equal risk % per leg (ATR stop)
   SIZE_INVERSE_VOL  = 2  // Inverse-volatility risk parity (recommended)
  };

enum ENUM_CSM_REBALANCE
  {
   REB_DAILY       = 0, // Daily
   REB_WEEKLY      = 1, // Weekly
   REB_MONTHLY     = 2, // Monthly (h = 1 month, as in the literature)
   REB_EVERY_N_BARS = 3 // Every N bars of the signal timeframe (intraday)
  };

//+------------------------------------------------------------------+
//| Inputs                                                            |
//+------------------------------------------------------------------+
input group "=== 1. Universe ===";
input string             InpSymbols          = "EURUSD,GBPUSD,AUDUSD,NZDUSD,USDCAD,USDCHF,USDJPY,USDSEK,USDNOK"; // Universe (comma separated)
input string             InpSymbolSuffix     = "";              // Broker suffix (".a", "m", "_ecn", "" = none)
input ENUM_CSM_UNIVERSE  InpUniverseMode     = UNIV_FX_VS_USD;  // Universe mode

input group "=== 2. Momentum signal ===";
input ENUM_TIMEFRAMES    InpSignalTF         = PERIOD_D1;       // Signal timeframe
input int                InpFormationBars    = 21;              // Formation period f (bars). 21 D1 bars ~ 1 month
input int                InpSkipBars         = 0;               // Skip the most recent k bars (equities: 21 -> "12-1")
input ENUM_CSM_SIGNAL    InpSignalType       = SIG_VOL_ADJ_RETURN; // Ranking score
input int                InpVolLookback      = 60;              // Volatility / covariance lookback (bars)
input int                InpLongCount        = 3;               // Number of winners to buy
input int                InpShortCount       = 3;               // Number of losers to sell
input bool               InpUseDualMomentum  = true;            // Dual-momentum filter (long only if own momentum > 0)
input double             InpMinAbsScore      = 0.0;             // Minimum |score| required to open a leg

input group "=== 3. Rebalancing (holding period h) ===";
input ENUM_CSM_REBALANCE InpRebalanceMode    = REB_MONTHLY;     // Rebalance frequency
input int                InpRebalanceEveryN  = 12;              // REB_EVERY_N_BARS: rebalance every N signal bars
input int                InpRebalanceHour    = 21;              // Rebalance hour (broker / server time)
input int                InpRebalanceMinute  = 0;               // Rebalance minute
input int                InpRebalanceDOW     = 1;               // Weekly: day of week (1=Mon .. 5=Fri)
input int                InpRebalanceDOM     = 1;               // Monthly: earliest day of month
input bool               InpRebalanceOnStart = true;            // Build the book immediately on attach
input bool               InpResizeExisting   = false;           // Re-size legs that survive a rebalance
input double             InpResizeTolPct     = 35.0;            // Re-size only if the lot deviation exceeds this %

input group "=== 4. Position sizing / risk ===";
input ENUM_CSM_SIZING    InpSizingMode       = SIZE_INVERSE_VOL; // Sizing mode
input double             InpFixedLot         = 0.10;            // Fixed lot (SIZE_FIXED_LOT)
input double             InpRiskPctPerLeg    = 0.35;            // Risk % of equity per leg (SIZE_RISK_PERCENT)
input double             InpPortfolioRiskPct = 2.50;            // Total risk % of equity (SIZE_INVERSE_VOL)
input bool               InpUseVolTarget     = true;            // Barroso/Santa-Clara volatility targeting
input double             InpTargetVolAnnual  = 10.0;            // Target annualised portfolio volatility (%)
input double             InpVolScaleMin      = 0.25;            // Minimum vol-target scale factor
input double             InpVolScaleMax      = 2.50;            // Maximum vol-target scale factor
input double             InpMaxGrossLeverage = 5.0;             // Max gross notional / equity (0 = off)
input double             InpMaxMarginPct     = 35.0;            // Max % of equity used as margin (0 = off)

input group "=== 5. Stop loss / take profit ===";
input ENUM_TIMEFRAMES    InpStopTF           = PERIOD_D1;       // Timeframe used for the ATR stop
input int                InpATRPeriod        = 14;              // ATR period
input double             InpSL_ATR           = 2.5;             // Stop loss   = N x ATR  (0 = disabled)
input double             InpTP_ATR           = 5.0;             // Take profit = N x ATR  (0 = disabled)
input bool               InpUseBreakEven     = true;            // Move the stop to break-even
input double             InpBE_Trigger_ATR   = 1.2;             // Break-even trigger (x ATR)
input double             InpBE_Offset_ATR    = 0.1;             // Break-even offset (x ATR)
input bool               InpUseTrailing      = true;            // ATR trailing stop
input double             InpTrailStart_ATR   = 1.8;             // Start trailing after this much profit (x ATR)
input double             InpTrail_ATR        = 2.0;             // Trailing distance (x ATR)

input group "=== 6. Safety / execution ===";
input double             InpMaxSpreadATRPct  = 6.0;             // Skip an entry if spread > this % of ATR (0 = off)
input double             InpMaxDailyLossPct  = 4.0;             // Pause for the day after this % equity loss (0 = off)
input double             InpMaxDrawdownPct   = 20.0;            // Hard stop above this % equity drawdown (0 = off)
input bool               InpCloseAllOnHalt   = true;            // Flatten the book when a risk guard fires
input ulong              InpMagic            = 20260926;        // Magic number
input ulong              InpSlippage         = 30;              // Max deviation (points)
input string             InpTradeComment     = "CSMOM";         // Order comment
input bool               InpVerboseLog       = true;            // Verbose journal logging
input bool               InpRunDiagnostics   = true;            // Print a readiness table (why am I not trading?)
input bool               InpShowPanel        = true;            // On-chart status panel

//+------------------------------------------------------------------+
//| Types                                                             |
//+------------------------------------------------------------------+
struct SymbolSlot
  {
   string            name;          // resolved broker symbol name
   bool              enabled;       // usable this cycle
   bool              flip;          // true => foreign-ccy return = -(pair return)
   int               atrHandle;     // ATR indicator handle
   int               digits;
   double            point;
   double            tickSize;
   double            tickValue;     // money per tick for 1.00 lot (loss side)
   double            volStep;
   double            volMin;
   double            volMax;
   double            contract;
   int               stopsLevel;    // minimum stop distance, in points
   double            price;         // reference mid price
   double            atr;           // ATR in price units
   double            ret;           // formation return, foreign-currency space
   double            sigmaBar;      // per-bar stdev of returns
   double            volAnn;        // annualised volatility
   double            score;         // ranking score
   int               target;        // +1 long foreign ccy, -1 short, 0 flat
   double            weight;        // risk weight, sums to 1 over the selected legs
   double            lots;          // target lot size
   bool              hasPosition;   // this leg is currently live
  };

//+------------------------------------------------------------------+
//| Globals                                                           |
//+------------------------------------------------------------------+
CTrade        g_trade;

SymbolSlot    g_slot[];
int           g_count         = 0;

double        g_close[];            // time-aligned close matrix, flattened
datetime      g_grid[];             // aligned bar times (index 0 = newest closed bar)
int           g_stride        = 0;  // row stride of g_close
int           g_bars          = 0;  // number of aligned bars actually built

double        g_cov[];              // annualised covariance matrix, flattened g_count x g_count

datetime      g_lastRebalance = 0;
int           g_keyDay        = -1;
int           g_keyWeek       = -1;
int           g_keyMonth      = -1;

double        g_equityPeak    = 0.0;
double        g_dayStartEquity = 0.0;
int           g_currentDay    = -1;
bool          g_haltedToday   = false;
bool          g_haltedHard    = false;

datetime      g_lastMaintain  = 0;
string        g_lastError     = "";
string        g_lastWarnShown = "";
string        g_lastAction    = "waiting for the first rebalance";
double        g_lastVolScale  = 1.0;
double        g_lastPortVol   = 0.0;

datetime      g_lastSeenBar   = 0;   // newest signal-TF bar we have observed
int           g_barCounter    = 0;   // signal bars elapsed since the last rebalance
datetime      g_lastDiag      = 0;   // last time the readiness report was printed
string        g_autoSuffix    = "";  // broker suffix inferred from the chart symbol
datetime      g_lastUniverseTry = 0; // last attempt to (re)build the universe

//+------------------------------------------------------------------+
//| Logging helpers                                                   |
//+------------------------------------------------------------------+
void LogInfo(const string msg)
  {
   if(InpVerboseLog)
      Print("[CSMOM] ", msg);
  }

//--- de-duplicated: the rebalance loop retries every second until it
//--- succeeds, and without this the journal would be unreadable.
void LogWarn(const string msg)
  {
   g_lastError = msg;
   if(msg == g_lastWarnShown)
      return;
   g_lastWarnShown = msg;
   Print("[CSMOM][WARN] ", msg);
  }

//+------------------------------------------------------------------+
//| Small numeric / symbol helpers                                    |
//+------------------------------------------------------------------+

//--- close of symbol j at aligned bar k (k = 0 is the newest CLOSED bar)
double C(const int j, const int k)
  {
   return g_close[j * g_stride + k];
  }

//--- trading bars per year for a timeframe
double BarsPerYear(const ENUM_TIMEFRAMES tf)
  {
   if(tf == PERIOD_MN1)
      return 12.0;
   if(tf == PERIOD_W1)
      return 52.0;
   int sec = PeriodSeconds(tf);
   if(sec <= 0)
      return 252.0;
   return (252.0 * 24.0 * 3600.0) / (double)sec;
  }

//--- descending binary search over a slice of a datetime array
int FindDescIdx(const datetime &arr[], const int off, const int len, const datetime t)
  {
   int lo = 0;
   int hi = len - 1;
   while(lo <= hi)
     {
      int mid = (lo + hi) / 2;
      datetime v = arr[off + mid];
      if(v == t)
         return mid;
      if(v > t)
         lo = mid + 1;            // the slice is newest-first
      else
         hi = mid - 1;
     }
   return -1;
  }

//--- a filling mode the symbol actually supports
ENUM_ORDER_TYPE_FILLING PickFilling(const string sym)
  {
   long modes = SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
   if((modes & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      return ORDER_FILLING_FOK;
   if((modes & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
  }

//--- round a volume onto the broker's lot grid
double NormalizeLots(const int j, const double raw)
  {
   double step = g_slot[j].volStep;
   if(step <= 0.0)
      step = 0.01;

   double v = MathFloor(raw / step + 0.0000001) * step;
   if(v < g_slot[j].volMin)
      return 0.0;                        // below the broker minimum -> do not trade
   if(v > g_slot[j].volMax)
      v = g_slot[j].volMax;

   int prec = 0;
   double s = step;
   while(s < 1.0 - 1e-12 && prec < 8)
     {
      s *= 10.0;
      prec++;
     }
   return NormalizeDouble(v, prec);
  }

//--- money value of a one-point move for 1.00 lot
double MoneyPerPoint(const int j)
  {
   if(g_slot[j].tickSize <= 0.0)
      return 0.0;
   return g_slot[j].tickValue * (g_slot[j].point / g_slot[j].tickSize);
  }

//--- notional of 1.00 lot expressed in the ACCOUNT currency.
//--- tickValue/tickSize is the money value of a 1.0 price move per lot, so
//--- multiplying by the price gives the money value of a 100% price move,
//--- i.e. the notional. This is correct for both EURUSD and USDJPY style
//--- quotes, unlike contract_size * price which lands in the quote currency.
double NotionalPerLot(const int j)
  {
   if(g_slot[j].tickSize <= 0.0)
      return 0.0;
   return (g_slot[j].tickValue / g_slot[j].tickSize) * g_slot[j].price;
  }

//--- ATR stop distance in price units, respecting the broker minimum
double StopDistance(const int j)
  {
   if(InpSL_ATR <= 0.0)
      return 0.0;
   double d       = InpSL_ATR * g_slot[j].atr;
   double minDist = (double)g_slot[j].stopsLevel * g_slot[j].point;
   double spread  = SymbolInfoDouble(g_slot[j].name, SYMBOL_ASK) -
                    SymbolInfoDouble(g_slot[j].name, SYMBOL_BID);
   minDist = MathMax(minDist, spread * 2.0);
   return MathMax(d, minDist);
  }

//--- +1 = BUY the pair, -1 = SELL the pair (after the quote-convention flip)
int OrderDirection(const int j)
  {
   if(g_slot[j].target == 0)
      return 0;
   int dir = g_slot[j].target;           // +1 = long the foreign currency
   if(g_slot[j].flip)
      dir = -dir;                        // long JPY == sell USDJPY
   return dir;
  }

int SlotIndexOf(const string sym)
  {
   for(int j = 0; j < g_count; j++)
      if(g_slot[j].name == sym)
         return j;
   return -1;
  }

//--- Create the ATR handle on demand. In the Strategy Tester iATR() on a
//--- non-chart symbol can fail on the very first calls, before the engine
//--- has synchronised that symbol's history. Creating it in OnInit and
//--- giving up would permanently drop the symbol from the universe.
bool EnsureAtrHandle(const int j)
  {
   if(g_slot[j].atrHandle != INVALID_HANDLE)
      return true;
   g_slot[j].atrHandle = iATR(g_slot[j].name, InpStopTF, InpATRPeriod);
   return (g_slot[j].atrHandle != INVALID_HANDLE);
  }

//--- Re-read the contract specification for one symbol.
//--- This MUST be done per cycle rather than once in OnInit: inside the
//--- Strategy Tester the non-chart symbols are not initialised yet when
//--- OnInit runs, so SYMBOL_TRADE_TICK_VALUE and friends still read 0.
//--- Validating there would reject the whole universe and the EA would
//--- never place a single trade.
bool RefreshSpecs(const int j)
  {
   string sym = g_slot[j].name;

   g_slot[j].digits     = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   g_slot[j].point      = SymbolInfoDouble(sym, SYMBOL_POINT);
   g_slot[j].tickSize   = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   g_slot[j].tickValue  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(g_slot[j].tickValue <= 0.0)
      g_slot[j].tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   g_slot[j].volStep    = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   g_slot[j].volMin     = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   g_slot[j].volMax     = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   g_slot[j].contract   = SymbolInfoDouble(sym, SYMBOL_TRADE_CONTRACT_SIZE);
   g_slot[j].stopsLevel = (int)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);

   //--- quote-convention normalisation (metadata, safe to re-evaluate)
   g_slot[j].flip = false;
   if(InpUniverseMode == UNIV_FX_VS_USD)
     {
      string baseCcy  = SymbolInfoString(sym, SYMBOL_CURRENCY_BASE);
      string quoteCcy = SymbolInfoString(sym, SYMBOL_CURRENCY_PROFIT);
      if(baseCcy == "USD" && quoteCcy != "USD")
         g_slot[j].flip = true;            // USDJPY up == JPY weaker
     }

   if(!EnsureAtrHandle(j))
      return false;
   if(g_slot[j].point <= 0.0 || g_slot[j].tickSize <= 0.0 || g_slot[j].tickValue <= 0.0)
      return false;
   if(g_slot[j].volStep <= 0.0 || g_slot[j].volMin <= 0.0)
      return false;
   return true;
  }

//--- Work out the broker's symbol suffix from the chart symbol.
//--- Many brokers quote EURUSDm, EURUSD.a, EURUSD_ecn, EURUSDpro ... and a
//--- plain "EURUSD" then resolves to nothing. Getting this wrong means the
//--- whole universe fails to resolve and the EA has nothing to rank.
void DetectAutoSuffix()
  {
   g_autoSuffix = "";
   if(StringLen(InpSymbolSuffix) > 0)
      return;                                  // the user told us explicitly

   string cs = _Symbol;
   if(StringLen(cs) <= 6)
      return;                                  // plain 6-letter name, no suffix

   string cand = StringSubstr(cs, 6);
   //--- only trust it if it actually produces a real symbol
   if(SymbolSelect("EURUSD" + cand, true) || SymbolSelect("USDJPY" + cand, true) ||
      SymbolSelect("GBPUSD" + cand, true))
     {
      g_autoSuffix = cand;
      LogInfo("Auto-detected broker symbol suffix from the chart symbol " + cs +
              " -> \"" + cand + "\"");
     }
  }

//--- resolve a user supplied name against what the broker actually offers
string ResolveSymbol(const string raw)
  {
   string s = raw;
   StringTrimLeft(s);
   StringTrimRight(s);
   if(StringLen(s) == 0)
      return "";

   //--- 1. explicit suffix from the inputs
   if(StringLen(InpSymbolSuffix) > 0 && SymbolSelect(s + InpSymbolSuffix, true))
      return s + InpSymbolSuffix;

   //--- 2. the name exactly as given
   if(SymbolSelect(s, true))
      return s;

   //--- 3. the suffix inferred from the chart symbol
   if(StringLen(g_autoSuffix) > 0 && SymbolSelect(s + g_autoSuffix, true))
      return s + g_autoSuffix;

   //--- 4. prefix scan over the full broker list, then over Market Watch
   for(int pass = 0; pass < 2; pass++)
     {
      bool selectedOnly = (pass == 1);
      int total = SymbolsTotal(selectedOnly);
      for(int i = 0; i < total; i++)
        {
         string n = SymbolName(i, selectedOnly);
         if(StringLen(n) > 0 && StringFind(n, s) == 0 && SymbolSelect(n, true))
            return n;
        }
     }
   return "";
  }

//--- When the universe cannot be built, show the user what their broker
//--- actually calls these instruments so they can fix InpSymbols.
void PrintBrokerSymbolSuggestions()
  {
   Print("[CSMOM] ---- symbols available at your broker containing \"USD\" ----");
   int shown = 0;
   string line = "";
   for(int pass = 0; pass < 2 && shown == 0; pass++)
     {
      bool selectedOnly = (pass == 1);
      int total = SymbolsTotal(selectedOnly);
      for(int i = 0; i < total && shown < 48; i++)
        {
         string n = SymbolName(i, selectedOnly);
         if(StringLen(n) == 0 || StringFind(n, "USD") < 0)
            continue;
         line += n + "   ";
         shown++;
         if(shown % 6 == 0)
           {
            Print("[CSMOM]   ", line);
            line = "";
           }
        }
     }
   if(StringLen(line) > 0)
      Print("[CSMOM]   ", line);
   if(shown == 0)
      Print("[CSMOM]   (none found - open Market Watch, right-click, 'Show All')");
   Print("[CSMOM] Copy the exact names above into InpSymbols, or set InpSymbolSuffix.");
  }

//+------------------------------------------------------------------+
//| Universe construction                                             |
//+------------------------------------------------------------------+
bool BuildUniverse()
  {
   string parts[];
   int n = StringSplit(InpSymbols, StringGetCharacter(",", 0), parts);
   if(n <= 0)
     {
      LogWarn("InpSymbols is empty - nothing to trade.");
      return false;
     }

   //--- release any handles from a previous attempt so repeated calls
   //--- cannot leak indicator handles
   for(int k = 0; k < g_count; k++)
      if(g_slot[k].atrHandle != INVALID_HANDLE)
         IndicatorRelease(g_slot[k].atrHandle);

   ArrayResize(g_slot, 0);
   g_count = 0;

   DetectAutoSuffix();

   for(int i = 0; i < n; i++)
     {
      string resolved = ResolveSymbol(parts[i]);
      if(StringLen(resolved) == 0)
        {
         LogWarn("Symbol not available at this broker, skipped: " + parts[i]);
         continue;
        }

      bool dup = false;
      for(int k = 0; k < g_count; k++)
         if(g_slot[k].name == resolved)
            dup = true;
      if(dup)
         continue;

      SymbolSlot sd;
      sd.name        = resolved;
      sd.enabled     = true;
      sd.flip        = false;
      sd.atrHandle   = INVALID_HANDLE;
      sd.digits      = 5;
      sd.point       = 0.0;
      sd.tickSize    = 0.0;
      sd.tickValue   = 0.0;
      sd.volStep     = 0.0;
      sd.volMin      = 0.0;
      sd.volMax      = 0.0;
      sd.contract    = 0.0;
      sd.stopsLevel  = 0;
      sd.price       = 0.0;
      sd.atr         = 0.0;
      sd.ret         = 0.0;
      sd.sigmaBar    = 0.0;
      sd.volAnn      = 0.0;
      sd.score       = 0.0;
      sd.target      = 0;
      sd.weight      = 0.0;
      sd.lots        = 0.0;
      sd.hasPosition = false;

      //--- the ATR handle is created lazily by EnsureAtrHandle(); failing
      //--- here would drop the symbol forever in the tester
      ArrayResize(g_slot, g_count + 1);
      g_slot[g_count] = sd;
      g_count++;

      //--- Specs are read lazily by RefreshSpecs() on every cycle. Do NOT
      //--- validate them here: in the Strategy Tester they are still zero
      //--- for non-chart symbols at OnInit time.
      RefreshSpecs(g_count - 1);

      if(InpUniverseMode == UNIV_FX_VS_USD)
        {
         string bc = SymbolInfoString(resolved, SYMBOL_CURRENCY_BASE);
         string qc = SymbolInfoString(resolved, SYMBOL_CURRENCY_PROFIT);
         if(bc != "USD" && qc != "USD" && StringLen(bc) > 0 && StringLen(qc) > 0)
            LogWarn(resolved + " is not quoted against the USD - it will be ranked on its raw return.");
        }
     }

   if(g_count < 2)
     {
      Print("[CSMOM][WARN] Only ", g_count, " of the symbols in InpSymbols could be resolved. "
            "A cross-sectional strategy needs at least 2.");
      PrintBrokerSymbolSuggestions();
      return false;
     }

   string list = "";
   for(int i = 0; i < g_count; i++)
      list += (i > 0 ? ", " : "") + g_slot[i].name + (g_slot[i].flip ? "(inv)" : "");
   LogInfo("Universe (" + IntegerToString(g_count) + "): " + list);
   return true;
  }

//+------------------------------------------------------------------+
//| Build a time-aligned close matrix across the whole universe       |
//+------------------------------------------------------------------+
bool BuildAlignedMatrix()
  {
   int minNeeded = (int)MathMax(InpFormationBars + InpSkipBars + 2, InpVolLookback + 2);
   int need      = (int)MathMin(minNeeded + 50, 20000);

   datetime tmpTimes[];
   double   tmpClose[];
   int      cnt[];
   ArrayResize(tmpTimes, g_count * need);
   ArrayResize(tmpClose, g_count * need);
   ArrayResize(cnt, g_count);

   int refIdx = -1;

   for(int j = 0; j < g_count; j++)
     {
      cnt[j] = 0;
      g_slot[j].enabled = false;

      //--- refresh the contract spec first; in the tester it only becomes
      //--- valid once the symbol has been touched by the engine
      if(!RefreshSpecs(j))
        {
         LogWarn("Contract specification not ready for " + g_slot[j].name +
                 " (tick value / lot step still 0) - excluded this cycle.");
         continue;
        }

      MqlRates rates[];
      //--- start_pos = 1 keeps the still-forming bar out of the sample
      int copied = CopyRates(g_slot[j].name, InpSignalTF, 1, need, rates);
      if(copied < minNeeded)
        {
         LogWarn("Not enough " + EnumToString(InpSignalTF) + " history for " + g_slot[j].name +
                 " (" + IntegerToString(copied) + "/" + IntegerToString(minNeeded) +
                 ") - excluded this cycle.");
         continue;
        }

      //--- normalise to newest-first regardless of how CopyRates filled the array
      bool ascending = (copied > 1 && rates[0].time < rates[copied - 1].time);
      for(int k = 0; k < copied; k++)
        {
         int src = ascending ? (copied - 1 - k) : k;
         tmpTimes[j * need + k] = rates[src].time;
         tmpClose[j * need + k] = rates[src].close;
        }

      cnt[j] = copied;
      g_slot[j].enabled = true;
      if(refIdx < 0)
         refIdx = j;
     }

   if(refIdx < 0)
     {
      LogWarn("No symbol delivered enough history - rebalance skipped.");
      return false;
     }

   g_stride = cnt[refIdx];
   ArrayResize(g_grid, g_stride);
   ArrayResize(g_close, g_count * g_stride);
   ArrayInitialize(g_close, 0.0);

   double row[];
   ArrayResize(row, g_count);

   int K = 0;
   for(int k = 0; k < cnt[refIdx]; k++)
     {
      datetime t = tmpTimes[refIdx * need + k];
      bool ok = true;

      for(int j = 0; j < g_count; j++)
        {
         if(!g_slot[j].enabled)
           {
            row[j] = 0.0;
            continue;
           }
         int p = FindDescIdx(tmpTimes, j * need, cnt[j], t);
         if(p < 0)
           {
            ok = false;
            break;
           }
         row[j] = tmpClose[j * need + p];
         if(row[j] <= 0.0)
           {
            ok = false;
            break;
           }
        }

      if(!ok)
         continue;

      g_grid[K] = t;
      for(int j = 0; j < g_count; j++)
         g_close[j * g_stride + K] = row[j];
      K++;
     }

   g_bars = K;
   if(g_bars < minNeeded)
     {
      LogWarn("Only " + IntegerToString(g_bars) + " time-aligned bars across the universe, " +
              IntegerToString(minNeeded) + " required - rebalance skipped.");
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Formation returns, volatilities and the covariance matrix         |
//+------------------------------------------------------------------+
bool ComputeSignals()
  {
   int iEnd   = InpSkipBars;
   int iStart = InpSkipBars + InpFormationBars;
   if(iStart >= g_bars)
     {
      LogWarn("The formation window exceeds the available history.");
      return false;
     }

   int m = (int)MathMin(InpVolLookback, g_bars - 1);
   if(m < 10)
     {
      LogWarn("Volatility lookback too short (" + IntegerToString(m) + " bars).");
      return false;
     }

   double ann = BarsPerYear(InpSignalTF);

   //--- per-symbol return series expressed in "foreign currency vs USD" space
   double rets[];
   ArrayResize(rets, g_count * m);
   ArrayInitialize(rets, 0.0);

   for(int j = 0; j < g_count; j++)
     {
      if(!g_slot[j].enabled)
         continue;

      double pEnd   = C(j, iEnd);
      double pStart = C(j, iStart);
      if(pEnd <= 0.0 || pStart <= 0.0)
        {
         g_slot[j].enabled = false;
         continue;
        }

      double r = MathLog(pEnd / pStart);
      if(g_slot[j].flip)
         r = -r;
      g_slot[j].ret = r;

      double sum = 0.0;
      for(int k = 0; k < m; k++)
        {
         double a = C(j, k);
         double b = C(j, k + 1);
         double x = (a > 0.0 && b > 0.0) ? MathLog(a / b) : 0.0;
         if(g_slot[j].flip)
            x = -x;
         rets[j * m + k] = x;
         sum += x;
        }

      double mean = sum / (double)m;
      double var  = 0.0;
      for(int k = 0; k < m; k++)
        {
         double d = rets[j * m + k] - mean;
         var += d * d;
        }
      var /= MathMax(1.0, (double)(m - 1));

      g_slot[j].sigmaBar = MathSqrt(MathMax(var, 0.0));
      g_slot[j].volAnn   = g_slot[j].sigmaBar * MathSqrt(ann);

      if(InpSignalType == SIG_VOL_ADJ_RETURN)
        {
         double denom = g_slot[j].sigmaBar * MathSqrt((double)InpFormationBars);
         g_slot[j].score = (denom > 1e-12) ? (r / denom) : 0.0;
        }
      else
         g_slot[j].score = r;
     }

   //--- annualised covariance matrix, used for volatility targeting
   ArrayResize(g_cov, g_count * g_count);
   ArrayInitialize(g_cov, 0.0);

   double means[];
   ArrayResize(means, g_count);
   for(int j = 0; j < g_count; j++)
     {
      double s = 0.0;
      for(int k = 0; k < m; k++)
         s += rets[j * m + k];
      means[j] = s / (double)m;
     }

   for(int a = 0; a < g_count; a++)
     {
      for(int b = a; b < g_count; b++)
        {
         double s = 0.0;
         for(int k = 0; k < m; k++)
            s += (rets[a * m + k] - means[a]) * (rets[b * m + k] - means[b]);
         double cv = (s / MathMax(1.0, (double)(m - 1))) * ann;
         g_cov[a * g_count + b] = cv;
         g_cov[b * g_count + a] = cv;
        }
     }

   //--- refresh ATR and the reference price
   for(int j = 0; j < g_count; j++)
     {
      if(!g_slot[j].enabled)
         continue;

      double buf[];
      if(CopyBuffer(g_slot[j].atrHandle, 0, 1, 1, buf) < 1 || buf[0] <= 0.0)
        {
         LogWarn("ATR not ready for " + g_slot[j].name + " - excluded this cycle.");
         g_slot[j].enabled = false;
         continue;
        }
      g_slot[j].atr = buf[0];

      MqlTick tick;
      if(!SymbolInfoTick(g_slot[j].name, tick) || tick.bid <= 0.0 || tick.ask <= 0.0)
        {
         LogWarn("No tick available for " + g_slot[j].name + " - excluded this cycle.");
         g_slot[j].enabled = false;
         continue;
        }
      g_slot[j].price = (tick.bid + tick.ask) * 0.5;
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Cross-sectional ranking: buy the winners, sell the losers         |
//+------------------------------------------------------------------+
//--- returns the number of symbols that were actually rankable
int RankAndSelect()
  {
   for(int j = 0; j < g_count; j++)
     {
      g_slot[j].target = 0;
      g_slot[j].weight = 0.0;
      g_slot[j].lots   = 0.0;
     }

   int idx[];
   ArrayResize(idx, g_count);
   int nv = 0;
   for(int j = 0; j < g_count; j++)
      if(g_slot[j].enabled)
        {
         idx[nv] = j;
         nv++;
        }
   ArrayResize(idx, nv);

   if(nv < 2)
     {
      LogWarn("Fewer than 2 rankable symbols this cycle - staying flat.");
      return nv;
     }

   //--- insertion sort, descending by score (the universe is tiny)
   for(int a = 1; a < nv; a++)
     {
      int key = idx[a];
      int b = a - 1;
      while(b >= 0 && g_slot[idx[b]].score < g_slot[key].score)
        {
         idx[b + 1] = idx[b];
         b--;
        }
      idx[b + 1] = key;
     }

   int wantLong  = (int)MathMax(0, InpLongCount);
   int wantShort = (int)MathMax(0, InpShortCount);
   if(wantLong + wantShort > nv)
     {
      double shrink = (double)nv / (double)(wantLong + wantShort);
      wantLong  = (int)MathFloor(wantLong * shrink);
      wantShort = (int)MathFloor(wantShort * shrink);
      LogWarn("Universe too small for the requested legs - reduced to " +
              IntegerToString(wantLong) + " long / " + IntegerToString(wantShort) + " short.");
     }

   //--- winners
   for(int a = 0; a < wantLong; a++)
     {
      int j = idx[a];
      if(MathAbs(g_slot[j].score) < InpMinAbsScore)
         continue;
      if(InpUseDualMomentum && g_slot[j].ret <= 0.0)
         continue;                                   // absolute-momentum overlay
      g_slot[j].target = 1;
     }

   //--- losers
   for(int a = 0; a < wantShort; a++)
     {
      int j = idx[nv - 1 - a];
      if(g_slot[j].target != 0)
         continue;                                   // never both legs on one symbol
      if(MathAbs(g_slot[j].score) < InpMinAbsScore)
         continue;
      if(InpUseDualMomentum && g_slot[j].ret >= 0.0)
         continue;
      g_slot[j].target = -1;
     }

   if(InpVerboseLog)
     {
      string s = "Ranking: ";
      for(int a = 0; a < nv; a++)
        {
         int j = idx[a];
         string tag = (g_slot[j].target > 0 ? "/L" : (g_slot[j].target < 0 ? "/S" : ""));
         s += StringFormat("%s[%.3f%s] ", g_slot[j].name, g_slot[j].score, tag);
        }
      LogInfo(s);
     }

   return nv;
  }

//+------------------------------------------------------------------+
//| Position sizing                                                   |
//+------------------------------------------------------------------+
void ComputeLots()
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0.0)
      return;

   //--- 1. risk weights over the selected legs
   int    sel[];
   ArrayResize(sel, g_count);
   int    ns = 0;
   double invSum = 0.0;

   for(int j = 0; j < g_count; j++)
     {
      if(g_slot[j].target == 0 || !g_slot[j].enabled)
         continue;
      sel[ns] = j;
      ns++;
      invSum += 1.0 / MathMax(g_slot[j].volAnn, 1e-6);
     }
   ArrayResize(sel, ns);
   if(ns == 0)
      return;

   for(int a = 0; a < ns; a++)
     {
      int j = sel[a];
      if(InpSizingMode == SIZE_INVERSE_VOL && invSum > 0.0)
         g_slot[j].weight = (1.0 / MathMax(g_slot[j].volAnn, 1e-6)) / invSum;
      else
         g_slot[j].weight = 1.0 / (double)ns;
     }

   //--- 2. turn the risk budget into lots using the ATR stop distance
   for(int a = 0; a < ns; a++)
     {
      int j = sel[a];

      if(InpSizingMode == SIZE_FIXED_LOT)
        {
         g_slot[j].lots = NormalizeLots(j, InpFixedLot);
         continue;
        }

      double riskMoney = 0.0;
      if(InpSizingMode == SIZE_RISK_PERCENT)
         riskMoney = equity * (InpRiskPctPerLeg / 100.0);
      else
         riskMoney = equity * (InpPortfolioRiskPct / 100.0) * g_slot[j].weight;

      double slDist = StopDistance(j);
      double mpp    = MoneyPerPoint(j);
      if(slDist <= 0.0 || mpp <= 0.0 || g_slot[j].point <= 0.0)
        {
         //--- no ATR stop configured: fall back to a volatility-implied distance
         slDist = MathMax(g_slot[j].atr, g_slot[j].point * 10.0) * 2.5;
         mpp    = MoneyPerPoint(j);
        }
      if(slDist <= 0.0 || mpp <= 0.0)
        {
         g_slot[j].lots = 0.0;
         continue;
        }

      double slPoints = slDist / g_slot[j].point;
      g_slot[j].lots   = riskMoney / MathMax(slPoints * mpp, 1e-9);
     }

   //--- 3. Barroso / Santa-Clara volatility targeting on the whole book
   g_lastVolScale = 1.0;
   g_lastPortVol  = 0.0;
   if(InpUseVolTarget && InpSizingMode != SIZE_FIXED_LOT && InpTargetVolAnnual > 0.0)
     {
      double e[];
      ArrayResize(e, g_count);
      ArrayInitialize(e, 0.0);

      for(int a = 0; a < ns; a++)
        {
         int j = sel[a];
         //--- signed money exposure per unit log-return (= signed notional)
         e[j] = (double)g_slot[j].target * g_slot[j].lots * NotionalPerLot(j);
        }

      double varMoney = 0.0;
      for(int a = 0; a < ns; a++)
         for(int b = 0; b < ns; b++)
           {
            int ja = sel[a];
            int jb = sel[b];
            varMoney += e[ja] * e[jb] * g_cov[ja * g_count + jb];
           }

      double portVol = MathSqrt(MathMax(varMoney, 0.0));
      g_lastPortVol = portVol / equity * 100.0;

      if(portVol > 0.0)
        {
         double targetMoney = equity * (InpTargetVolAnnual / 100.0);
         double scale = targetMoney / portVol;
         scale = MathMax(InpVolScaleMin, MathMin(InpVolScaleMax, scale));
         g_lastVolScale = scale;
         for(int a = 0; a < ns; a++)
            g_slot[sel[a]].lots *= scale;
         g_lastPortVol *= scale;
        }
     }

   //--- 4. gross leverage cap
   if(InpMaxGrossLeverage > 0.0)
     {
      double gross = 0.0;
      for(int a = 0; a < ns; a++)
        {
         int j = sel[a];
         gross += g_slot[j].lots * NotionalPerLot(j);   // account currency
        }
      double maxGross = equity * InpMaxGrossLeverage;
      if(gross > maxGross && gross > 0.0)
        {
         double k = maxGross / gross;
         for(int a = 0; a < ns; a++)
            g_slot[sel[a]].lots *= k;
         LogInfo(StringFormat("Gross leverage cap applied (x%.2f).", k));
        }
     }

   //--- 5. snap to the lot grid
   for(int a = 0; a < ns; a++)
     {
      int j = sel[a];
      g_slot[j].lots = NormalizeLots(j, g_slot[j].lots);
      if(g_slot[j].lots <= 0.0)
        {
         LogWarn(g_slot[j].name + ": computed lot is below the broker minimum of " +
                 DoubleToString(g_slot[j].volMin, 2) +
                 " - leg skipped. Raise InpPortfolioRiskPct, lower InpSL_ATR, " +
                 "reduce the number of legs, or increase the account size.");
         g_slot[j].target = 0;
        }
     }

   //--- 6. margin cap
   if(InpMaxMarginPct > 0.0)
     {
      double needed = 0.0;
      for(int a = 0; a < ns; a++)
        {
         int j = sel[a];
         if(g_slot[j].lots <= 0.0 || g_slot[j].target == 0)
            continue;
         double mg = 0.0;
         ENUM_ORDER_TYPE ot = (OrderDirection(j) > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
         double px = (ot == ORDER_TYPE_BUY) ? SymbolInfoDouble(g_slot[j].name, SYMBOL_ASK)
                     : SymbolInfoDouble(g_slot[j].name, SYMBOL_BID);
         if(OrderCalcMargin(ot, g_slot[j].name, g_slot[j].lots, px, mg))
            needed += mg;
        }

      double maxMargin = equity * (InpMaxMarginPct / 100.0);
      if(needed > maxMargin && needed > 0.0)
        {
         double k = maxMargin / needed;
         LogInfo(StringFormat("Margin cap applied (x%.2f): %.2f required vs %.2f allowed.",
                              k, needed, maxMargin));
         for(int a = 0; a < ns; a++)
           {
            int j = sel[a];
            g_slot[j].lots = NormalizeLots(j, g_slot[j].lots * k);
            if(g_slot[j].lots <= 0.0)
               g_slot[j].target = 0;
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Execution helpers                                                 |
//+------------------------------------------------------------------+
ulong FindOurTicket(const string sym)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == sym)
         return ticket;
     }
   return 0;
  }

bool CloseTicket(const ulong ticket, const string why)
  {
   if(!PositionSelectByTicket(ticket))
      return false;
   string sym = PositionGetString(POSITION_SYMBOL);
   g_trade.SetTypeFilling(PickFilling(sym));
   if(g_trade.PositionClose(ticket, InpSlippage))
     {
      LogInfo(StringFormat("Closed #%I64u %s (%s).", ticket, sym, why));
      return true;
     }
   LogWarn(StringFormat("Close failed #%I64u %s: %u %s", ticket, sym,
                        g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()));
   return false;
  }

void CloseAllOurPositions(const string why)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      CloseTicket(ticket, why);
     }
  }

//--- open one leg with its ATR stop-loss / take-profit
bool OpenLeg(const int j)
  {
   int dir = OrderDirection(j);
   if(dir == 0 || g_slot[j].lots <= 0.0)
      return false;

   string sym = g_slot[j].name;

   MqlTick tick;
   if(!SymbolInfoTick(sym, tick) || tick.ask <= 0.0 || tick.bid <= 0.0)
     {
      LogWarn("No tick for " + sym + " at entry.");
      return false;
     }

   //--- spread filter
   if(InpMaxSpreadATRPct > 0.0 && g_slot[j].atr > 0.0)
     {
      double spread = tick.ask - tick.bid;
      if(spread > g_slot[j].atr * (InpMaxSpreadATRPct / 100.0))
        {
         LogWarn(StringFormat("%s spread %s exceeds %.1f%% of ATR %s - entry skipped.",
                              sym, DoubleToString(spread, g_slot[j].digits),
                              InpMaxSpreadATRPct, DoubleToString(g_slot[j].atr, g_slot[j].digits)));
         return false;
        }
     }

   ENUM_ORDER_TYPE type = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double price = (dir > 0) ? tick.ask : tick.bid;

   double slDist = StopDistance(j);
   double tpDist = (InpTP_ATR > 0.0) ? InpTP_ATR * g_slot[j].atr : 0.0;
   if(tpDist > 0.0)
      tpDist = MathMax(tpDist, (double)g_slot[j].stopsLevel * g_slot[j].point);

   double sl = 0.0;
   double tp = 0.0;
   if(slDist > 0.0)
      sl = (dir > 0) ? price - slDist : price + slDist;
   if(tpDist > 0.0)
      tp = (dir > 0) ? price + tpDist : price - tpDist;

   sl = (sl > 0.0) ? NormalizeDouble(sl, g_slot[j].digits) : 0.0;
   tp = (tp > 0.0) ? NormalizeDouble(tp, g_slot[j].digits) : 0.0;

   g_trade.SetTypeFilling(PickFilling(sym));
   g_trade.SetDeviationInPoints(InpSlippage);

   string cmt = InpTradeComment + (g_slot[j].target > 0 ? "-W" : "-L");

   if(g_trade.PositionOpen(sym, type, g_slot[j].lots, price, sl, tp, cmt))
     {
      LogInfo(StringFormat("OPEN %s %s %.2f lots @ %s  SL %s  TP %s  (score %.3f, w %.3f)",
                           (dir > 0 ? "BUY" : "SELL"), sym, g_slot[j].lots,
                           DoubleToString(price, g_slot[j].digits),
                           DoubleToString(sl, g_slot[j].digits),
                           DoubleToString(tp, g_slot[j].digits),
                           g_slot[j].score, g_slot[j].weight));
      return true;
     }

   uint rc = g_trade.ResultRetcode();
   LogWarn(StringFormat("Open failed %s: %u %s", sym, rc, g_trade.ResultRetcodeDescription()));

   //--- some brokers reject stops attached to a market order: retry naked, then modify
   if(rc == TRADE_RETCODE_INVALID_STOPS && (sl > 0.0 || tp > 0.0))
     {
      if(g_trade.PositionOpen(sym, type, g_slot[j].lots, price, 0.0, 0.0, cmt))
        {
         LogInfo("Re-opened " + sym + " without stops, attaching them now.");
         ulong ticket = FindOurTicket(sym);
         if(ticket > 0 && !g_trade.PositionModify(ticket, sl, tp))
            LogWarn("Could not attach stops to " + sym + ": " + g_trade.ResultRetcodeDescription());
         return true;
        }
     }
   return false;
  }

//--- reconcile the live book with the freshly computed target book,
//--- returns the number of legs that ended up live
int ExecuteTargets()
  {
   for(int j = 0; j < g_count; j++)
      g_slot[j].hasPosition = false;

   //--- pass 1: close what no longer belongs, keep what still matches
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      int j = SlotIndexOf(sym);

      if(j < 0 || g_slot[j].target == 0 || !g_slot[j].enabled)
        {
         CloseTicket(ticket, "dropped out of the portfolio");
         continue;
        }

      long ptype   = PositionGetInteger(POSITION_TYPE);
      int  posDir  = (ptype == POSITION_TYPE_BUY) ? 1 : -1;
      int  wantDir = OrderDirection(j);

      if(posDir != wantDir)
        {
         CloseTicket(ticket, "signal flipped");
         continue;
        }

      if(g_slot[j].hasPosition)
        {
         CloseTicket(ticket, "duplicate leg");   // hedging accounts: keep one clean leg
         continue;
        }

      if(InpResizeExisting && g_slot[j].lots > 0.0)
        {
         double cur = PositionGetDouble(POSITION_VOLUME);
         double dev = MathAbs(cur - g_slot[j].lots) / MathMax(cur, 1e-9) * 100.0;
         if(dev > InpResizeTolPct)
           {
            CloseTicket(ticket, StringFormat("re-size %.2f -> %.2f", cur, g_slot[j].lots));
            continue;
           }
        }

      g_slot[j].hasPosition = true;
     }

   //--- pass 2: open the missing legs
   int opened = 0;
   for(int j = 0; j < g_count; j++)
     {
      if(g_slot[j].target == 0 || g_slot[j].hasPosition || !g_slot[j].enabled)
         continue;
      if(OpenLeg(j))
        {
         g_slot[j].hasPosition = true;
         opened++;
        }
     }

   int held = 0;
   for(int j = 0; j < g_count; j++)
      if(g_slot[j].hasPosition)
         held++;

   g_lastAction = StringFormat("%s - %d legs live (%d new)",
                               TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES), held, opened);
   LogInfo(g_lastAction);
   return held;
  }

//+------------------------------------------------------------------+
//| Break-even and trailing stop maintenance                          |
//+------------------------------------------------------------------+
void ManageOpenPositions()
  {
   if(!InpUseBreakEven && !InpUseTrailing)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      int j = SlotIndexOf(sym);
      if(j < 0)
         continue;

      double buf[];
      if(CopyBuffer(g_slot[j].atrHandle, 0, 1, 1, buf) < 1 || buf[0] <= 0.0)
         continue;
      double atr = buf[0];

      MqlTick tick;
      if(!SymbolInfoTick(sym, tick) || tick.ask <= 0.0 || tick.bid <= 0.0)
         continue;

      long   ptype  = PositionGetInteger(POSITION_TYPE);
      bool   isBuy  = (ptype == POSITION_TYPE_BUY);
      double openPx = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL  = PositionGetDouble(POSITION_SL);
      double curTP  = PositionGetDouble(POSITION_TP);
      double market = isBuy ? tick.bid : tick.ask;
      double profit = isBuy ? (market - openPx) : (openPx - market);

      //--- never park a stop inside the spread, even when stops_level is 0
      double spread  = tick.ask - tick.bid;
      double minDist = MathMax((double)g_slot[j].stopsLevel * g_slot[j].point, spread);
      double newSL   = curSL;

      //--- break-even
      if(InpUseBreakEven && InpBE_Trigger_ATR > 0.0 && profit >= InpBE_Trigger_ATR * atr)
        {
         double be = isBuy ? openPx + InpBE_Offset_ATR * atr
                     : openPx - InpBE_Offset_ATR * atr;
         if(isBuy && (newSL <= 0.0 || be > newSL))
            newSL = be;
         if(!isBuy && (newSL <= 0.0 || be < newSL))
            newSL = be;
        }

      //--- ATR trailing
      if(InpUseTrailing && InpTrail_ATR > 0.0 && profit >= InpTrailStart_ATR * atr)
        {
         double trail = isBuy ? market - InpTrail_ATR * atr
                        : market + InpTrail_ATR * atr;
         if(isBuy && (newSL <= 0.0 || trail > newSL))
            newSL = trail;
         if(!isBuy && (newSL <= 0.0 || trail < newSL))
            newSL = trail;
        }

      if(newSL <= 0.0 || MathAbs(newSL - curSL) < 1e-12)
         continue;

      //--- respect the broker's stop distance and never walk the stop backwards
      if(isBuy)
        {
         if(newSL > market - minDist)
            newSL = market - minDist;
         if(curSL > 0.0 && newSL <= curSL)
            continue;
         if(newSL <= 0.0)
            continue;
        }
      else
        {
         if(newSL < market + minDist)
            newSL = market + minDist;
         if(curSL > 0.0 && newSL >= curSL)
            continue;
        }

      newSL = NormalizeDouble(newSL, g_slot[j].digits);
      if(MathAbs(newSL - curSL) < g_slot[j].point * 0.5)
         continue;

      g_trade.SetTypeFilling(PickFilling(sym));
      if(!g_trade.PositionModify(ticket, newSL, curTP))
         LogWarn(StringFormat("Stop update failed %s: %u %s", sym,
                              g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()));
     }
  }

//+------------------------------------------------------------------+
//| Risk guards                                                       |
//+------------------------------------------------------------------+
void UpdateRiskGuards()
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0.0)
      return;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day != g_currentDay)
     {
      g_currentDay     = dt.day;
      g_dayStartEquity = equity;
      g_haltedToday    = false;
     }

   if(equity > g_equityPeak)
      g_equityPeak = equity;

   //--- hard drawdown stop
   if(InpMaxDrawdownPct > 0.0 && g_equityPeak > 0.0 && !g_haltedHard)
     {
      double dd = (g_equityPeak - equity) / g_equityPeak * 100.0;
      if(dd >= InpMaxDrawdownPct)
        {
         g_haltedHard = true;
         LogWarn(StringFormat("HARD STOP: equity drawdown %.2f%% >= %.2f%%. Trading disabled.",
                              dd, InpMaxDrawdownPct));
         if(InpCloseAllOnHalt)
            CloseAllOurPositions("max drawdown guard");
        }
     }

   //--- daily loss stop
   if(InpMaxDailyLossPct > 0.0 && g_dayStartEquity > 0.0 && !g_haltedToday)
     {
      double dayLoss = (g_dayStartEquity - equity) / g_dayStartEquity * 100.0;
      if(dayLoss >= InpMaxDailyLossPct)
        {
         g_haltedToday = true;
         LogWarn(StringFormat("Daily loss guard: -%.2f%% today. Paused until tomorrow.", dayLoss));
         if(InpCloseAllOnHalt)
            CloseAllOurPositions("daily loss guard");
        }
     }
  }

bool TradingAllowed()
  {
   if(g_haltedHard)
     {
      LogWarn("Trading blocked: the max-drawdown kill switch has fired. Restart the EA to clear it.");
      return false;
     }
   if(g_haltedToday)
     {
      LogWarn("Trading blocked: the daily-loss guard is active until tomorrow.");
      return false;
     }

   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
     {
      LogWarn("Trading blocked: 'Allow Algo Trading' is unticked in this EA's properties dialog "
              "(Common tab). In the Strategy Tester it is on the Settings tab.");
      return false;
     }

   //--- Terminal and account level switches are meaningless inside the
   //--- Strategy Tester, and checking them there is a classic silent
   //--- killer: with the terminal AutoTrading button off, a backtest
   //--- would run to completion without ever placing a single order.
   if(!(bool)MQLInfoInteger(MQL_TESTER))
     {
      if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
        {
         LogWarn("Trading blocked: the terminal AutoTrading button is OFF (toolbar, top of MT5).");
         return false;
        }
      if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
        {
         LogWarn("Trading blocked: the broker has disabled expert trading on this account.");
         return false;
        }
      if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
        {
         LogWarn("Trading blocked: trading is disabled on this account "
                 "(are you logged in with the investor password?).");
         return false;
        }
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Rebalance scheduling                                              |
//+------------------------------------------------------------------+
int KeyDay(const MqlDateTime &dt)
  {
   return dt.year * 1000 + dt.day_of_year;
  }

int KeyWeek(const MqlDateTime &dt)
  {
   //--- monotonic "week id"; day_of_year/7 always increments every 7 days
   return dt.year * 54 + (dt.day_of_year / 7);
  }

int KeyMonth(const MqlDateTime &dt)
  {
   return dt.year * 12 + dt.mon;
  }

//--- open time of the newest signal-timeframe bar, used by REB_EVERY_N_BARS
datetime SignalBarTime()
  {
   string ref = (g_count > 0) ? g_slot[0].name : _Symbol;
   datetime t[];
   if(CopyTime(ref, InpSignalTF, 0, 1, t) < 1)
      return 0;
   return t[0];
  }

bool ShouldRebalance(const datetime now)
  {
   MqlDateTime dt;
   TimeToStruct(now, dt);

   //--- bar-count mode is an intraday cadence: no hour or weekend gate
   if(InpRebalanceMode == REB_EVERY_N_BARS)
      return (g_lastRebalance == 0 || g_barCounter >= MathMax(1, InpRebalanceEveryN));

   //--- never rebalance over the weekend
   if(dt.day_of_week == 0 || dt.day_of_week == 6)
      return false;

   int minutesNow = dt.hour * 60 + dt.min;
   int minutesDue = InpRebalanceHour * 60 + InpRebalanceMinute;
   if(minutesNow < minutesDue)
      return false;

   if(InpRebalanceMode == REB_DAILY)
      return (g_keyDay != KeyDay(dt));

   if(InpRebalanceMode == REB_WEEKLY)
     {
      if(dt.day_of_week < InpRebalanceDOW)
         return false;
      return (g_keyWeek != KeyWeek(dt));
     }

   //--- monthly: the first session on/after the requested day of month
   if(dt.day < InpRebalanceDOM)
      return false;
   return (g_keyMonth != KeyMonth(dt));
  }

void StampRebalance(const datetime now)
  {
   MqlDateTime dt;
   TimeToStruct(now, dt);
   g_lastRebalance = now;
   g_keyDay        = KeyDay(dt);
   g_keyWeek       = KeyWeek(dt);
   g_keyMonth      = KeyMonth(dt);
   g_barCounter    = 0;
  }

//+------------------------------------------------------------------+
//| Diagnostics: a per-symbol readiness table                         |
//|                                                                   |
//| This is the first thing to look at when the EA takes no trades.   |
//| It prints, for every symbol, whether the contract spec, history,  |
//| ATR and quotes are actually available, and what lot size the      |
//| current settings would produce.                                   |
//+------------------------------------------------------------------+
void DiagnoseUniverse()
  {
   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   int    minNeeded = (int)MathMax(InpFormationBars + InpSkipBars + 2, InpVolLookback + 2);
   int    legs      = (int)MathMax(1, InpLongCount + InpShortCount);

   Print("[CSMOM] ===================== DIAGNOSTICS =====================");
   PrintFormat("[CSMOM] equity=%.2f %s | terminal algo=%s | account expert=%s | positions=%d",
               equity, AccountInfoString(ACCOUNT_CURRENCY),
               (TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ? "ON" : "OFF"),
               (AccountInfoInteger(ACCOUNT_TRADE_EXPERT) ? "ON" : "OFF"),
               PositionsTotal());
   PrintFormat("[CSMOM] signalTF=%s needs >= %d bars | stopTF=%s | rebalance=%s | universe=%d",
               EnumToString(InpSignalTF), minNeeded, EnumToString(InpStopTF),
               EnumToString(InpRebalanceMode), g_count);
   PrintFormat("[CSMOM] %-12s %7s %6s %6s %10s %9s %8s %8s  %s",
               "SYMBOL", "BARS", "SPEC", "ATR", "SPREAD", "SPR/ATR", "MINLOT", "CALCLOT", "VERDICT");

   int ready = 0;
   for(int j = 0; j < g_count; j++)
     {
      string sym   = g_slot[j].name;
      bool   spec  = RefreshSpecs(j);
      int    bars  = Bars(sym, InpSignalTF);

      double atr = 0.0;
      double buf[];
      if(CopyBuffer(g_slot[j].atrHandle, 0, 1, 1, buf) >= 1)
         atr = buf[0];

      MqlTick tick;
      bool   gotTick = SymbolInfoTick(sym, tick);
      double spread  = (gotTick ? (tick.ask - tick.bid) : 0.0);
      double sprPct  = (atr > 0.0 ? spread / atr * 100.0 : 0.0);

      //--- what lot would this leg get right now?
      double calcLot = 0.0;
      if(spec && atr > 0.0 && g_slot[j].point > 0.0)
        {
         double risk = equity * (InpPortfolioRiskPct / 100.0) / (double)legs;
         double mpp  = MoneyPerPoint(j);
         double slp  = (MathMax(InpSL_ATR, 0.1) * atr) / g_slot[j].point;
         if(mpp > 0.0 && slp > 0.0)
            calcLot = risk / (slp * mpp);
        }

      string verdict = "READY";
      if(!spec)
         verdict = "NO CONTRACT SPEC (tick value 0 - symbol not initialised yet)";
      else
         if(bars < minNeeded)
            verdict = StringFormat("NOT ENOUGH HISTORY (%d < %d)", bars, minNeeded);
         else
            if(atr <= 0.0)
               verdict = "ATR NOT READY";
            else
               if(!gotTick)
                  verdict = "NO QUOTES";
               else
                  if(InpMaxSpreadATRPct > 0.0 && sprPct > InpMaxSpreadATRPct)
                     verdict = StringFormat("SPREAD TOO WIDE (%.1f%% > %.1f%% of ATR)",
                                            sprPct, InpMaxSpreadATRPct);
                  else
                     if(calcLot < g_slot[j].volMin)
                        verdict = StringFormat("LOT TOO SMALL (%.4f < min %.2f)",
                                               calcLot, g_slot[j].volMin);
                     else
                        ready++;

      PrintFormat("[CSMOM] %-12s %7d %6s %6s %10s %8.1f%% %8.2f %8.4f  %s",
                  sym, bars, (spec ? "ok" : "--"), (atr > 0.0 ? "ok" : "--"),
                  DoubleToString(spread, (g_slot[j].digits > 0 ? g_slot[j].digits : 5)),
                  sprPct, g_slot[j].volMin, calcLot, verdict);
     }

   PrintFormat("[CSMOM] %d of %d symbols are ready to trade.", ready, g_count);
   if(ready < 2)
      Print("[CSMOM] A cross-sectional strategy cannot rank fewer than 2 symbols. "
            "Fix the VERDICT column above.");
   Print("[CSMOM] =======================================================");
  }

//+------------------------------------------------------------------+
//| Full rebalance cycle                                              |
//+------------------------------------------------------------------+
void Rebalance()
  {
   LogInfo("---- rebalance " + TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES) + " ----");

   //--- any of these failing means "not ready yet"; do NOT stamp the
   //--- rebalance, otherwise a whole month could be silently skipped
   //--- while the tester is still warming up its history.
   if(!BuildAlignedMatrix())
      return;
   if(!ComputeSignals())
      return;

   int rankable = RankAndSelect();
   if(rankable < 2)
      return;

   ComputeLots();
   int held = ExecuteTargets();

   //--- the cycle genuinely ran, so consume it even if it produced no legs
   StampRebalance(TimeCurrent());

   if(held == 0)
     {
      LogWarn("Rebalance completed but opened NO positions - see the diagnostics table below.");
      if(InpRunDiagnostics)
         DiagnoseUniverse();
     }
  }

//+------------------------------------------------------------------+
//| On-chart status panel                                             |
//+------------------------------------------------------------------+
void UpdatePanel()
  {
   if(!InpShowPanel)
      return;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dd = (g_equityPeak > 0.0) ? (g_equityPeak - equity) / g_equityPeak * 100.0 : 0.0;

   string s = "";
   s += "Cross-Sectional Momentum   (Jegadeesh-Titman 1993 / Menkhoff et al. 2012)\n";
   s += "-------------------------------------------------------------------------\n";
   s += StringFormat("Universe %d  |  f=%d skip=%d  |  %d long / %d short  |  %s\n",
                     g_count, InpFormationBars, InpSkipBars, InpLongCount, InpShortCount,
                     EnumToString(InpSignalTF));
   s += StringFormat("Equity %.2f   DD %.2f%%   vol-scale x%.2f   est. portfolio vol %.1f%% p.a.\n",
                     equity, dd, g_lastVolScale, g_lastPortVol);
   s += StringFormat("Last rebalance: %s   (%s)\n",
                     (g_lastRebalance == 0 ? "-" : TimeToString(g_lastRebalance, TIME_DATE | TIME_MINUTES)),
                     EnumToString(InpRebalanceMode));
   s += StringFormat("Status: %s%s\n", g_lastAction,
                     (g_haltedHard ? "   [HARD HALT]" : (g_haltedToday ? "   [PAUSED TODAY]" : "")));
   s += "-------------------------------------------------------------------------\n";

   for(int j = 0; j < g_count; j++)
     {
      string tag = (g_slot[j].target > 0 ? "LONG " : (g_slot[j].target < 0 ? "SHORT" : "  .  "));
      s += StringFormat("%-11s %s  score %+7.3f   ret %+6.2f%%   vol %5.1f%%   lots %5.2f%s\n",
                        g_slot[j].name, tag, g_slot[j].score, g_slot[j].ret * 100.0,
                        g_slot[j].volAnn * 100.0, g_slot[j].lots,
                        (g_slot[j].hasPosition ? "  <<" : ""));
     }

   if(StringLen(g_lastError) > 0)
      s += "\nlast warning: " + g_lastError;

   Comment(s);
  }

//+------------------------------------------------------------------+
//| Main loop                                                         |
//+------------------------------------------------------------------+
void Heartbeat()
  {
   datetime now = TimeCurrent();

   //--- throttle the housekeeping to once per second
   if(now == g_lastMaintain)
      return;
   g_lastMaintain = now;

   //--- keep retrying the universe until the broker/tester gives us enough
   //--- symbols; without this a cold start would wedge the EA forever
   if(g_count < 2)
     {
      if(now - g_lastUniverseTry >= 60)
        {
         g_lastUniverseTry = now;
         BuildUniverse();
        }
      if(g_count < 2)
        {
         UpdatePanel();
         return;
        }
      Print("[CSMOM] Universe is now ready with ", g_count, " symbols.");
     }

   //--- track elapsed signal-timeframe bars for REB_EVERY_N_BARS
   datetime bt = SignalBarTime();
   if(bt > 0 && bt != g_lastSeenBar)
     {
      if(g_lastSeenBar > 0)
         g_barCounter++;
      g_lastSeenBar = bt;
     }

   UpdateRiskGuards();
   ManageOpenPositions();

   if(TradingAllowed() && ShouldRebalance(now))
      Rebalance();

   //--- While nothing has traded yet, re-print the readiness report every
   //--- 4 hours of chart time so the journal always explains itself.
   if(InpRunDiagnostics && g_lastRebalance == 0 && g_barCounter >= 2 &&
      (g_lastDiag == 0 || now - g_lastDiag >= 4 * 3600))
     {
      g_lastDiag = now;
      Print("[CSMOM] No rebalance has completed yet. Readiness report:");
      DiagnoseUniverse();
     }

   UpdatePanel();
  }

//+------------------------------------------------------------------+
//| Lifecycle                                                         |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpFormationBars < 2)
     {
      Print("[CSMOM] InpFormationBars must be >= 2.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpSkipBars < 0)
     {
      Print("[CSMOM] InpSkipBars must be >= 0.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpLongCount < 0 || InpShortCount < 0 || (InpLongCount + InpShortCount) < 1)
     {
      Print("[CSMOM] At least one long or short leg is required.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpVolLookback < 20)
     {
      Print("[CSMOM] InpVolLookback should be at least 20 bars.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpATRPeriod < 2)
     {
      Print("[CSMOM] InpATRPeriod must be >= 2.");
      return INIT_PARAMETERS_INCORRECT;
     }

   Print("[CSMOM] ===========================================================");
   Print("[CSMOM]  Cross-Sectional Momentum EA v1.10 - starting up");
   PrintFormat("[CSMOM]  chart=%s %s | tester=%s | visual=%s",
               _Symbol, EnumToString((ENUM_TIMEFRAMES)_Period),
               (MQLInfoInteger(MQL_TESTER) ? "YES" : "no"),
               (MQLInfoInteger(MQL_VISUAL_MODE) ? "YES" : "no"));
   PrintFormat("[CSMOM]  signalTF=%s f=%d skip=%d | rebalance=%s | legs=%dL/%dS",
               EnumToString(InpSignalTF), InpFormationBars, InpSkipBars,
               EnumToString(InpRebalanceMode), InpLongCount, InpShortCount);
   Print("[CSMOM] ===========================================================");
   Print("[CSMOM]  If you do not see this line in the Journal, the EA is not "
         "attached or was not recompiled (press F7 in MetaEditor).");

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippage);
   g_trade.SetAsyncMode(false);

   //--- Never abort init just because the universe is not ready. Inside the
   //--- Strategy Tester the other symbols only come alive after the first
   //--- few bars; returning INIT_FAILED here makes the EA disappear and the
   //--- backtest silently produces zero trades. Heartbeat() keeps retrying.
   BuildUniverse();
   g_lastUniverseTry = TimeCurrent();
   if(g_count < 2)
      Print("[CSMOM] Universe not ready yet - will keep retrying every 60 seconds. "
            "The EA is still loaded.");

   g_equityPeak     = AccountInfoDouble(ACCOUNT_EQUITY);
   g_dayStartEquity = g_equityPeak;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   g_currentDay = dt.day;

   //--- a timer keeps the EA alive even on charts with sparse ticks
   EventSetTimer(30);

   if(InpRebalanceMode == REB_EVERY_N_BARS)
      LogInfo(StringFormat("Initialised. Rebalancing every %d %s bars.",
                           InpRebalanceEveryN, EnumToString(InpSignalTF)));
   else
      LogInfo("Initialised. Rebalance mode " + EnumToString(InpRebalanceMode) +
              StringFormat(" at %02d:%02d server time.", InpRebalanceHour, InpRebalanceMinute));

   //--- loud warning for the single most common backtest mistake: running a
   //--- monthly-rebalanced portfolio over a test window that is too short to
   //--- contain even one rebalance.
   if(InpRebalanceMode == REB_MONTHLY)
      Print("[CSMOM] NOTE: monthly rebalancing. A backtest shorter than ~2 months will "
            "produce very few or zero trades. It also needs ",
            (int)MathMax(InpFormationBars + InpSkipBars + 2, InpVolLookback + 2),
            " bars of ", EnumToString(InpSignalTF),
            " history BEFORE the test start date. For a short intraday test use "
            "InpRebalanceMode = REB_EVERY_N_BARS with an intraday InpSignalTF.");

   if(InpRebalanceOnStart && TradingAllowed())
      Rebalance();

   if(InpRunDiagnostics)
      DiagnoseUniverse();

   UpdatePanel();
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   for(int j = 0; j < g_count; j++)
      if(g_slot[j].atrHandle != INVALID_HANDLE)
         IndicatorRelease(g_slot[j].atrHandle);
   Comment("");
  }

void OnTick()
  {
   Heartbeat();
  }

void OnTimer()
  {
   Heartbeat();
  }
//+------------------------------------------------------------------+
