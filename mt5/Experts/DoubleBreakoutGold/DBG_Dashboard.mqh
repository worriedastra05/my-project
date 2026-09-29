//+------------------------------------------------------------------+
//|                                                 DBG_Dashboard.mqh |
//|       On-chart control panel: clock/timezone, market, strategy,   |
//|       news filter state, risk & statistics + control buttons      |
//+------------------------------------------------------------------+
#ifndef __DBG_DASHBOARD_MQH__
#define __DBG_DASHBOARD_MQH__

#include "DBG_Utils.mqh"

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
