//+------------------------------------------------------------------+
//| mql5_shim.hpp                                                     |
//|                                                                   |
//| A minimal C++ stand-in for the MQL5 runtime, used ONLY to run a   |
//| static syntax / type check of the Expert Advisor with g++ on a    |
//| machine that has no MetaEditor. It is never compiled into MT5.    |
//|                                                                   |
//| It declares the subset of the MQL5 standard library that the EA   |
//| touches, with the same signatures, so that typos, wrong argument  |
//| counts, undefined helpers and type errors surface here.           |
//+------------------------------------------------------------------+
#pragma once

#include <string>
#include <vector>
#include <cmath>
#include <cstdio>
#include <cstdint>

//------------------------------------------------------------------ types
typedef std::string      string;
typedef long long        datetime;
typedef unsigned char    uchar;
typedef unsigned int     color;
// NOTE: glibc's <sys/types.h> already provides ushort / uint / ulong on Linux.
// These typedefs must match it exactly or g++ reports a conflicting declaration.
typedef unsigned short int ushort;
typedef unsigned int       uint;
typedef unsigned long int  ulong;

#define NULL_STR ""

//------------------------------------------------------------------ dynamic arrays
template<class T>
struct MqlArr
  {
   std::vector<T> v;
   T&       operator[](long long i)       { return v[(size_t)i]; }
   const T& operator[](long long i) const { return v[(size_t)i]; }
  };

template<class T> int ArrayResize(MqlArr<T> &a, int n)          { a.v.resize((size_t)(n < 0 ? 0 : n)); return n; }
template<class T> int ArrayResize(MqlArr<T> &a, int n, int r)   { (void)r; a.v.resize((size_t)(n < 0 ? 0 : n)); return n; }
template<class T> int ArraySize(const MqlArr<T> &a)             { return (int)a.v.size(); }
template<class T, class U> int ArrayInitialize(MqlArr<T> &a, U val) { for(auto &x : a.v) x = (T)val; return (int)a.v.size(); }
template<class T> bool ArraySetAsSeries(MqlArr<T> &a, bool f)   { (void)a; (void)f; return true; }
template<class T> void ArrayFree(MqlArr<T> &a)                  { a.v.clear(); }

//------------------------------------------------------------------ math
template<class A, class B> auto MathMax(A a, B b) -> decltype(a + b) { return (a > b) ? (decltype(a + b))a : (decltype(a + b))b; }
template<class A, class B> auto MathMin(A a, B b) -> decltype(a + b) { return (a < b) ? (decltype(a + b))a : (decltype(a + b))b; }
inline double MathAbs(double v)   { return std::fabs(v); }
inline double MathFloor(double v) { return std::floor(v); }
inline double MathCeil(double v)  { return std::ceil(v); }
inline double MathSqrt(double v)  { return std::sqrt(v); }
inline double MathLog(double v)   { return std::log(v); }
inline double MathPow(double a, double b) { return std::pow(a, b); }
inline double NormalizeDouble(double v, int d) { (void)d; return v; }

//------------------------------------------------------------------ strings
inline int    StringLen(const string &s)                    { return (int)s.size(); }
inline int    StringTrimLeft(string &s)                     { (void)s; return 0; }
inline int    StringTrimRight(string &s)                    { (void)s; return 0; }
inline int    StringFind(const string &s, const string &w, int start = 0) { (void)s; (void)w; (void)start; return 0; }
inline ushort StringGetCharacter(const string &s, int i)    { (void)s; (void)i; return 0; }
inline string StringSubstr(const string &s, int a, int n = -1) { (void)a; (void)n; return s; }
inline int    StringSplit(const string &s, ushort sep, MqlArr<string> &out) { (void)s; (void)sep; (void)out; return 0; }
inline string IntegerToString(long long v, int len = 0, ushort fill = ' ') { (void)v; (void)len; (void)fill; return string(); }
inline string DoubleToString(double v, int digits = 8)      { (void)v; (void)digits; return string(); }
inline string TimeToString(datetime t, int mode = 0)        { (void)t; (void)mode; return string(); }
template<class... A> string StringFormat(const string &fmt, A... a) { (void)fmt; return string(); }
template<class T>    string EnumToString(T v)               { (void)v; return string(); }

//------------------------------------------------------------------ output
template<class... A> void Print(A... a)       {}
template<class... A> void PrintFormat(A... a) {}
inline void Comment(const string &s)          { (void)s; }

//------------------------------------------------------------------ enums / constants
enum ENUM_TIMEFRAMES
  {
   PERIOD_CURRENT = 0, PERIOD_M1 = 1, PERIOD_M5 = 5, PERIOD_M15 = 15, PERIOD_M30 = 30,
   PERIOD_H1 = 16385, PERIOD_H4 = 16388, PERIOD_D1 = 16408, PERIOD_W1 = 32769, PERIOD_MN1 = 49153
  };

enum ENUM_ORDER_TYPE
  { ORDER_TYPE_BUY = 0, ORDER_TYPE_SELL = 1 };

enum ENUM_ORDER_TYPE_FILLING
  { ORDER_FILLING_FOK = 0, ORDER_FILLING_IOC = 1, ORDER_FILLING_RETURN = 2, ORDER_FILLING_BOC = 3 };

const int INVALID_HANDLE            = -1;
const int INIT_SUCCEEDED            = 0;
const int INIT_FAILED               = 1;
const int INIT_PARAMETERS_INCORRECT = 2;

const int TIME_DATE    = 1;
const int TIME_MINUTES = 2;
const int TIME_SECONDS = 4;

const uint TRADE_RETCODE_INVALID_STOPS = 10016;

//--- symbol properties (the real enums are distinct types; int is enough here)
const int SYMBOL_DIGITS               = 1;
const int SYMBOL_POINT                = 2;
const int SYMBOL_TRADE_TICK_SIZE      = 3;
const int SYMBOL_TRADE_TICK_VALUE     = 4;
const int SYMBOL_TRADE_TICK_VALUE_LOSS = 5;
const int SYMBOL_VOLUME_STEP          = 6;
const int SYMBOL_VOLUME_MIN           = 7;
const int SYMBOL_VOLUME_MAX           = 8;
const int SYMBOL_TRADE_CONTRACT_SIZE  = 9;
const int SYMBOL_TRADE_STOPS_LEVEL    = 10;
const int SYMBOL_TRADE_FREEZE_LEVEL   = 11;
const int SYMBOL_ASK                  = 12;
const int SYMBOL_BID                  = 13;
const int SYMBOL_SPREAD               = 14;
const int SYMBOL_CURRENCY_BASE        = 15;
const int SYMBOL_CURRENCY_PROFIT      = 16;
const int SYMBOL_FILLING_MODE         = 17;
const int SYMBOL_TRADE_MODE           = 18;
const int SYMBOL_FILLING_FOK          = 1;
const int SYMBOL_FILLING_IOC          = 2;
const int SYMBOL_FILLING_BOC          = 4;

const int ACCOUNT_EQUITY        = 30;
const int ACCOUNT_BALANCE       = 31;
const int ACCOUNT_MARGIN_FREE   = 32;
const int ACCOUNT_TRADE_EXPERT  = 33;
const int ACCOUNT_TRADE_ALLOWED = 34;
const int ACCOUNT_CURRENCY      = 35;

const int TERMINAL_TRADE_ALLOWED = 40;
const int MQL_TRADE_ALLOWED      = 41;
const int MQL_TESTER             = 42;

const int POSITION_SYMBOL     = 50;
const int POSITION_MAGIC      = 51;
const int POSITION_TYPE       = 52;
const int POSITION_VOLUME     = 53;
const int POSITION_PRICE_OPEN = 54;
const int POSITION_SL         = 55;
const int POSITION_TP         = 56;
const int POSITION_PROFIT     = 57;
const int POSITION_TYPE_BUY   = 0;
const int POSITION_TYPE_SELL  = 1;

//------------------------------------------------------------------ structures
struct MqlRates
  {
   datetime time;
   double   open, high, low, close;
   long long tick_volume, real_volume;
   int      spread;
  };

struct MqlTick
  {
   datetime time;
   double   bid, ask, last, volume_real;
  };

struct MqlDateTime
  {
   int year, mon, day, hour, min, sec, day_of_week, day_of_year;
  };

//------------------------------------------------------------------ market info
inline double SymbolInfoDouble(const string &s, int prop)   { (void)s; (void)prop; return 0.0; }
inline long   SymbolInfoInteger(const string &s, int prop)  { (void)s; (void)prop; return 0; }
inline string SymbolInfoString(const string &s, int prop)   { (void)s; (void)prop; return string(); }
inline bool   SymbolInfoTick(const string &s, MqlTick &t)   { (void)s; (void)t; return true; }
inline bool   SymbolSelect(const string &s, bool sel)       { (void)s; (void)sel; return true; }
inline int    SymbolsTotal(bool selected)                   { (void)selected; return 0; }
inline string SymbolName(int idx, bool selected)            { (void)idx; (void)selected; return string(); }

inline double AccountInfoDouble(int prop)   { (void)prop; return 0.0; }
inline long   AccountInfoInteger(int prop)  { (void)prop; return 0; }
inline string AccountInfoString(int prop)   { (void)prop; return string(); }
inline long   TerminalInfoInteger(int prop) { (void)prop; return 0; }
inline long   MQLInfoInteger(int prop)      { (void)prop; return 0; }

//--- predefined variables
//------------------------------------------------------------------ timeseries / indicators
inline int  CopyRates(const string &s, ENUM_TIMEFRAMES tf, int start, int count, MqlArr<MqlRates> &out)
  { (void)s; (void)tf; (void)start; (void)count; (void)out; return 0; }
inline int  CopyBuffer(int handle, int buf, int start, int count, MqlArr<double> &out)
  { (void)handle; (void)buf; (void)start; (void)count; (void)out; return 0; }
inline int  iATR(const string &s, ENUM_TIMEFRAMES tf, int period) { (void)s; (void)tf; (void)period; return 0; }
inline bool IndicatorRelease(int handle) { (void)handle; return true; }
inline int  CopyTime(const string &s, ENUM_TIMEFRAMES tf, int start, int count, MqlArr<datetime> &out)
  { (void)s; (void)tf; (void)start; (void)count; (void)out; return 0; }
inline int  PeriodSeconds(ENUM_TIMEFRAMES tf) { (void)tf; return 60; }
inline int  Bars(const string &s, ENUM_TIMEFRAMES tf) { (void)s; (void)tf; return 0; }

//--- predefined variables
static const string _Symbol = "EURUSD";
static const ENUM_TIMEFRAMES _Period = PERIOD_D1;

//------------------------------------------------------------------ time
inline datetime TimeCurrent() { return 0; }
inline datetime TimeLocal()   { return 0; }
inline bool     TimeToStruct(datetime t, MqlDateTime &dt) { (void)t; (void)dt; return true; }
inline bool     EventSetTimer(int seconds) { (void)seconds; return true; }
inline void     EventKillTimer() {}

//------------------------------------------------------------------ trading
inline int   PositionsTotal() { return 0; }
inline ulong PositionGetTicket(int index) { (void)index; return 0; }
inline bool  PositionSelectByTicket(ulong ticket) { (void)ticket; return true; }
inline long  PositionGetInteger(int prop)  { (void)prop; return 0; }
inline double PositionGetDouble(int prop)  { (void)prop; return 0.0; }
inline string PositionGetString(int prop)  { (void)prop; return string(); }
inline bool  OrderCalcMargin(ENUM_ORDER_TYPE t, const string &s, double vol, double price, double &margin)
  { (void)t; (void)s; (void)vol; (void)price; (void)margin; return true; }

//------------------------------------------------------------------ CTrade (Trade\Trade.mqh)
class CTrade
  {
public:
   void   SetExpertMagicNumber(ulong magic)                 { (void)magic; }
   void   SetDeviationInPoints(ulong dev)                   { (void)dev; }
   void   SetAsyncMode(bool mode)                           { (void)mode; }
   void   SetTypeFilling(ENUM_ORDER_TYPE_FILLING f)         { (void)f; }
   bool   PositionOpen(const string &sym, ENUM_ORDER_TYPE type, double volume,
                       double price, double sl, double tp, const string &comment = "")
     { (void)sym; (void)type; (void)volume; (void)price; (void)sl; (void)tp; (void)comment; return true; }
   bool   PositionClose(ulong ticket, ulong deviation = 0)  { (void)ticket; (void)deviation; return true; }
   bool   PositionClose(const string &sym, ulong dev = 0)   { (void)sym; (void)dev; return true; }
   bool   PositionModify(ulong ticket, double sl, double tp){ (void)ticket; (void)sl; (void)tp; return true; }
   uint   ResultRetcode()                                   { return 0; }
   string ResultRetcodeDescription()                        { return string(); }
  };
