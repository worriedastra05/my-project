//+------------------------------------------------------------------+
//|                                                     OFG_Panel.mqh |
//|     Generic on-chart dashboard: sections + label/value rows +     |
//|     footer status line and control buttons                        |
//+------------------------------------------------------------------+
#ifndef __OFG_PANEL_MQH__
#define __OFG_PANEL_MQH__

#define OFG_PREFIX   "OFG_"
#define OFG_BTN_PAUSE OFG_PREFIX+"btn_pause"
#define OFG_BTN_CLOSE OFG_PREFIX+"btn_close"
#define OFG_BTN_MIN   OFG_PREFIX+"btn_min"

class COfgPanel
  {
private:
   long              m_chart;
   int               m_x,m_y,m_w,m_corner,m_fs;
   string            m_font;
   int               m_rowY;
   int               m_height;
   bool              m_created;
   bool              m_minimized;
   color             m_cBg,m_cPanel,m_cHead,m_cLabel,m_cValue,m_cSection,m_cBorder;

   string            N(const string tag) const { return(OFG_PREFIX+tag); }
   void              Rect(const string name,const int x,const int y,const int w,const int h,const color bg,const color border);
   void              Text(const string name,const int x,const int y,const string txt,const color clr,const int size,const string font);
   void              Button(const string name,const int x,const int y,const int w,const int h,const string txt,const color bg,const color fg);

public:
                     COfgPanel(void);
   void              Create(const long chart,const int corner,const int x,const int y,
                            const int width,const int fontSize,const string font,const string title);
   void              AddSection(const string title);
   void              AddRow(const string tag,const string label);
   void              Finish(void);
   void              SetValue(const string tag,const string txt,const color clr=clrNONE);
   void              SetStatus(const string txt,const color clr);
   void              SetPaused(const bool paused);
   void              ToggleMinimize(void);
   void              Destroy(void);
   bool              Created(void) const { return(m_created); }
   bool              Minimized(void) const { return(m_minimized); }
   void              Redraw(void) { ChartRedraw(m_chart); }
  };

//+------------------------------------------------------------------+
COfgPanel::COfgPanel(void)
  {
   m_chart=0; m_x=12; m_y=100; m_w=470; m_corner=CORNER_LEFT_UPPER; m_fs=8;
   m_font="Consolas"; m_rowY=0; m_height=0; m_created=false; m_minimized=false;
   m_cBg      = C'18,21,27';
   m_cPanel   = C'26,31,40';
   m_cHead    = C'212,175,55';
   m_cLabel   = C'140,150,165';
   m_cValue   = C'225,230,238';
   m_cSection = C'90,170,255';
   m_cBorder  = C'55,63,78';
  }

//+------------------------------------------------------------------+
void COfgPanel::Rect(const string name,const int x,const int y,const int w,const int h,const color bg,const color border)
  {
   if(ObjectFind(m_chart,name)<0) ObjectCreate(m_chart,name,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(m_chart,name,OBJPROP_CORNER,m_corner);
   ObjectSetInteger(m_chart,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(m_chart,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(m_chart,name,OBJPROP_XSIZE,w);
   ObjectSetInteger(m_chart,name,OBJPROP_YSIZE,h);
   ObjectSetInteger(m_chart,name,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(m_chart,name,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(m_chart,name,OBJPROP_COLOR,border);
   ObjectSetInteger(m_chart,name,OBJPROP_BACK,false);
   ObjectSetInteger(m_chart,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(m_chart,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(m_chart,name,OBJPROP_ZORDER,0);
  }

//+------------------------------------------------------------------+
void COfgPanel::Text(const string name,const int x,const int y,const string txt,const color clr,const int size,const string font)
  {
   if(ObjectFind(m_chart,name)<0) ObjectCreate(m_chart,name,OBJ_LABEL,0,0,0);
   ObjectSetInteger(m_chart,name,OBJPROP_CORNER,m_corner);
   ObjectSetInteger(m_chart,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(m_chart,name,OBJPROP_YDISTANCE,y);
   ObjectSetString(m_chart,name,OBJPROP_TEXT,txt);
   ObjectSetString(m_chart,name,OBJPROP_FONT,font);
   ObjectSetInteger(m_chart,name,OBJPROP_FONTSIZE,size);
   ObjectSetInteger(m_chart,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(m_chart,name,OBJPROP_BACK,false);
   ObjectSetInteger(m_chart,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(m_chart,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(m_chart,name,OBJPROP_ZORDER,1);
  }

//+------------------------------------------------------------------+
void COfgPanel::Button(const string name,const int x,const int y,const int w,const int h,const string txt,const color bg,const color fg)
  {
   if(ObjectFind(m_chart,name)<0) ObjectCreate(m_chart,name,OBJ_BUTTON,0,0,0);
   ObjectSetInteger(m_chart,name,OBJPROP_CORNER,m_corner);
   ObjectSetInteger(m_chart,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(m_chart,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(m_chart,name,OBJPROP_XSIZE,w);
   ObjectSetInteger(m_chart,name,OBJPROP_YSIZE,h);
   ObjectSetString(m_chart,name,OBJPROP_TEXT,txt);
   ObjectSetString(m_chart,name,OBJPROP_FONT,m_font);
   ObjectSetInteger(m_chart,name,OBJPROP_FONTSIZE,m_fs);
   ObjectSetInteger(m_chart,name,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(m_chart,name,OBJPROP_COLOR,fg);
   ObjectSetInteger(m_chart,name,OBJPROP_BORDER_COLOR,m_cBorder);
   ObjectSetInteger(m_chart,name,OBJPROP_STATE,false);
   ObjectSetInteger(m_chart,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(m_chart,name,OBJPROP_ZORDER,2);
  }

//+------------------------------------------------------------------+
void COfgPanel::Create(const long chart,const int corner,const int x,const int y,
                       const int width,const int fontSize,const string font,const string title)
  {
   m_chart  = chart;
   m_corner = corner;
   m_x      = x;
   m_y      = y;
   m_w      = (width<360 ? 360 : width);
   m_fs     = (fontSize<6 ? 6 : fontSize);
   m_font   = (font=="" ? "Consolas" : font);
   Destroy();

   Rect(N("bg"),m_x,m_y,m_w,600,m_cBg,m_cBorder);
   Rect(N("hdr"),m_x,m_y,m_w,24,m_cPanel,m_cBorder);
   Text(N("title"),m_x+10,m_y+5,title,m_cHead,m_fs+1,"Segoe UI Semibold");
   Button(OFG_BTN_MIN,m_x+m_w-26,m_y+4,18,16,"_",m_cPanel,m_cValue);
   m_rowY   = m_y+28;
   m_created= true;
  }

//+------------------------------------------------------------------+
void COfgPanel::AddSection(const string title)
  {
   m_rowY += 6;
   string tag = "sec"+IntegerToString(m_rowY);
   Text(N(tag),m_x+10,m_rowY,title,m_cSection,m_fs,m_font);
   Rect(N("ln"+tag),m_x+8,m_rowY+14,m_w-16,1,m_cBorder,m_cBorder);
   m_rowY += 19;
  }

//+------------------------------------------------------------------+
void COfgPanel::AddRow(const string tag,const string label)
  {
   Text(N("lb_"+tag),m_x+12,m_rowY,label,m_cLabel,m_fs,m_font);
   Text(N("vl_"+tag),m_x+118,m_rowY,"-",m_cValue,m_fs,m_font);
   m_rowY += 15;
  }

//+------------------------------------------------------------------+
void COfgPanel::Finish(void)
  {
   m_rowY += 6;
   Rect(N("ftln"),m_x+8,m_rowY,m_w-16,1,m_cBorder,m_cBorder);
   m_rowY += 6;
   Text(N("vl_status"),m_x+12,m_rowY+5,"INITIALISING",m_cValue,m_fs,m_font);
   Button(OFG_BTN_PAUSE,m_x+m_w-166,m_rowY+2,78,20,"PAUSE",C'40,48,60',m_cValue);
   Button(OFG_BTN_CLOSE,m_x+m_w-84,m_rowY+2,76,20,"CLOSE ALL",C'70,35,40',C'255,190,190');
   m_rowY  += 30;
   m_height = m_rowY-m_y;
   ObjectSetInteger(m_chart,N("bg"),OBJPROP_YSIZE,m_height);
   ChartRedraw(m_chart);
  }

//+------------------------------------------------------------------+
void COfgPanel::SetValue(const string tag,const string txt,const color clr)
  {
   string nm = N("vl_"+tag);
   if(ObjectFind(m_chart,nm)<0) return;
   ObjectSetString(m_chart,nm,OBJPROP_TEXT,txt);
   if(clr!=clrNONE) ObjectSetInteger(m_chart,nm,OBJPROP_COLOR,clr);
  }

//+------------------------------------------------------------------+
void COfgPanel::SetStatus(const string txt,const color clr)
  {
   string nm = N("vl_status");
   if(ObjectFind(m_chart,nm)<0) return;
   ObjectSetString(m_chart,nm,OBJPROP_TEXT,txt);
   ObjectSetInteger(m_chart,nm,OBJPROP_COLOR,clr);
  }

//+------------------------------------------------------------------+
void COfgPanel::SetPaused(const bool paused)
  {
   if(ObjectFind(m_chart,OFG_BTN_PAUSE)<0) return;
   ObjectSetString(m_chart,OFG_BTN_PAUSE,OBJPROP_TEXT,(paused ? "RESUME" : "PAUSE"));
   ObjectSetInteger(m_chart,OFG_BTN_PAUSE,OBJPROP_BGCOLOR,(paused ? C'80,60,20' : C'40,48,60'));
   ObjectSetInteger(m_chart,OFG_BTN_PAUSE,OBJPROP_STATE,false);
  }

//+------------------------------------------------------------------+
void COfgPanel::ToggleMinimize(void)
  {
   m_minimized = !m_minimized;
   for(int i=ObjectsTotal(m_chart)-1;i>=0;i--)
     {
      string nm = ObjectName(m_chart,i);
      if(StringFind(nm,OFG_PREFIX)!=0) continue;
      if(nm==N("bg") || nm==N("hdr") || nm==N("title") || nm==OFG_BTN_MIN) continue;
      ObjectSetInteger(m_chart,nm,OBJPROP_TIMEFRAMES,(m_minimized ? OBJ_NO_PERIODS : OBJ_ALL_PERIODS));
     }
   ObjectSetInteger(m_chart,N("bg"),OBJPROP_YSIZE,(m_minimized ? 24 : m_height));
   ObjectSetString(m_chart,OFG_BTN_MIN,OBJPROP_TEXT,(m_minimized ? "+" : "_"));
   ObjectSetInteger(m_chart,OFG_BTN_MIN,OBJPROP_STATE,false);
   ChartRedraw(m_chart);
  }

//+------------------------------------------------------------------+
void COfgPanel::Destroy(void)
  {
   ObjectsDeleteAll(m_chart,OFG_PREFIX);
   m_created = false;
   ChartRedraw(m_chart);
  }

#endif // __OFG_PANEL_MQH__
//+------------------------------------------------------------------+
