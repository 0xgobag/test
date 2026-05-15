//+------------------------------------------------------------------+
//|                                               Dark System EA     |
//|                        SuperTrend Strong Scaler - MQL5 v1.13     |
//+------------------------------------------------------------------+
#property copyright "Dark System"
#property version   "1.13"
#property description "EA SuperTrend Strong Scaler - v1.13 (SuperTrend flip fix & remove push notification)"
#property description "Mendukung XAU, Forex, Crypto. TF M1/M5."
#property link      ""

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\HistoryOrderInfo.mqh>

input group "=== General & Volume ==="
input double   LotSize = 0.1;
input bool     EnableSoundAlert = true;
input bool     DebugMode = false;

input group "=== SuperTrend Signal ==="
input int      ST_ATR_Period = 10;
input double   ST_Multiplier = 3.0;
input bool     UseStrongSignal = true;
input double   StrongST_Multiplier = 5.0;
input bool     WaitForClosedCandle = true;
input int      EntryDelayBars = 1;
input int      ReEntryCooldownBars = 1;
input int      DrawBars = 200;

input group "=== Entry/Exit Rules ==="
input bool     CloseOnSignalReverse = true;
input bool     CloseOnTrendChange = true;

input group "=== Fixed SL/TP ==="
input bool     UseFixedSL = true;
input int      FixedSL_Points = 200;
input bool     UseFixedTP = false;
input int      FixedTP_Points = 100;

input group "=== Breakeven & Trailing ==="
input bool     UseBreakeven = false;
input double   BreakevenStartUSD = 5.0;
input double   BreakevenLockUSD = 10.0;
input bool     UseTrailingStop = false;
input int      TrailingStartPoints = 80;
input int      TrailingStepPoints = 30;

input group "=== Trading Session Filter ==="
input bool     UseTimeFilter = false;
input string   StartTime = "08:00";
input string   EndTime = "18:00";

input group "=== Daily Risk Limits ==="
input bool     UseDailyLossLimit = false;
input double   DailyLossLimitUSD = 50.0;
input bool     UseDailyProfitTarget = false;
input double   DailyProfitTargetUSD = 100.0;

CTrade trade;
int magicNumber;
double tickValue, tickSize, point;
datetime lastBarTime = 0;
datetime lastTradeCloseTime = 0;
datetime lastStrongSignalTime = 0;
int strongDir = 0;
int stMainDir = 0;
int stStrongDir = 0;
double dailyProfit = 0, dailyLoss = 0;
int wins = 0, losses = 0, breakevens = 0;
int lastDay = -1;

ulong pendingHistoryTickets[];
ulong prevTicketList[];
ulong closedByEaThisTick[];

string DashPrefix = "DarkSys_";
string CountdownName = "DarkSys_Countdown";

bool TicketExists(const ulong &arr[], const ulong ticket)
{
   for(int i = 0; i < ArraySize(arr); i++)
      if(arr[i] == ticket) return true;
   return false;
}

void AddTicketUnique(ulong &arr[], const ulong ticket)
{
   if(TicketExists(arr, ticket)) return;
   int n = ArraySize(arr);
   ArrayResize(arr, n + 1);
   arr[n] = ticket;
}

void CreateLabel(string id, int x, int y, string text, color clr, int sz, bool bold=false)
{
   string nm = DashPrefix + id;
   ObjectCreate(0, nm, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, nm, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, nm, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, nm, OBJPROP_TEXT, text);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, nm, OBJPROP_FONTSIZE, sz);
   ObjectSetString(0, nm, OBJPROP_FONT, bold ? "Arial Bold" : "Arial");
   ObjectSetInteger(0, nm, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
}

int StringHashSimple(const string s)
{
   uint h = 2166136261u;
   for(int i = 0; i < StringLen(s); i++)
   {
      h ^= (uint)StringGetCharacter(s, i);
      h *= 16777619u;
   }
   return (int)(h & 0x7FFFFFFF);
}

bool ParseHHMM(const string t, int &minutesOut)
{
   string p[];
   if(StringSplit(t, ':', p) != 2) return false;
   int h = (int)StringToInteger(p[0]);
   int m = (int)StringToInteger(p[1]);
   if(h < 0 || h > 23 || m < 0 || m > 59) return false;
   minutesOut = h * 60 + m;
   return true;
}

bool ValidateInputs()
{
   if(LotSize <= 0) { Print("Invalid input: LotSize must be > 0."); return false; }
   if(ST_ATR_Period < 2) { Print("Invalid input: ST_ATR_Period must be >= 2."); return false; }
   if(ST_Multiplier <= 0 || StrongST_Multiplier <= 0) { Print("Invalid input: multipliers must be > 0."); return false; }
   if(StrongST_Multiplier <= ST_Multiplier) Print("Warning: StrongST_Multiplier <= ST_Multiplier, strong filter may be less meaningful.");
   if(UseBreakeven && BreakevenLockUSD < BreakevenStartUSD) Print("Warning: BreakevenLockUSD < BreakevenStartUSD; lock may trigger before/without BE move.");
   if(UseFixedSL && FixedSL_Points <= 0) { Print("Invalid input: FixedSL_Points must be > 0 when UseFixedSL=true."); return false; }
   if(UseFixedTP && FixedTP_Points <= 0) { Print("Invalid input: FixedTP_Points must be > 0 when UseFixedTP=true."); return false; }
   if(UseTrailingStop && (TrailingStartPoints <= 0 || TrailingStepPoints <= 0)) { Print("Invalid input: trailing points must be > 0."); return false; }
   if(UseDailyLossLimit && DailyLossLimitUSD <= 0) { Print("Invalid input: DailyLossLimitUSD must be > 0."); return false; }
   if(UseDailyProfitTarget && DailyProfitTargetUSD <= 0) { Print("Invalid input: DailyProfitTargetUSD must be > 0."); return false; }
   return true;
}

int OnInit()
{
   if(!ValidateInputs())
      return(INIT_PARAMETERS_INCORRECT);

   magicNumber = (int)((StringHashSimple(_Symbol) ^ ((uint)PeriodSeconds() * 2654435761u))) & 0x7FFFFFFF;
   trade.SetExpertMagicNumber(magicNumber);

   point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickValue <= 0) tickValue = 1.0;
   if(tickSize <= 0) tickSize = point;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   lastDay = dt.day;

   ArrayResize(pendingHistoryTickets, 0);
   ArrayResize(prevTicketList, 0);
   ArrayResize(closedByEaThisTick, 0);

   UpdateSuperTrendSignals();
   CreateDashboard();
   if(ObjectFind(0, CountdownName) < 0)
      ObjectCreate(0, CountdownName, OBJ_TEXT, 0, TimeCurrent(), iClose(_Symbol, PERIOD_CURRENT, 0));

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   DeleteDashboard();
   ObjectDelete(0, CountdownName);
}

void OnTick()
{
   CheckNewDay();
   if(!TradingAllowed())
   {
      UpdateDashboard();
      UpdateCountdown();
      return;
   }

   SaveCurrentTickets();
   if(NewBar())
   {
      UpdateSuperTrendSignals();
      DrawSuperTrendLines();
   }

   ArrayResize(closedByEaThisTick, 0);

   ManageOpenPositions();
   CheckClosedByBroker();

   if(CountPositions() == 0) CheckEntrySignal();
   UpdateDashboard();
   UpdateCountdown();
}

void SaveCurrentTickets()
{
   ArrayResize(prevTicketList, 0);
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t > 0 && PositionSelectByTicket(t))
      {
         if(PositionGetInteger(POSITION_MAGIC) == magicNumber && PositionGetString(POSITION_SYMBOL) == _Symbol)
         {
            AddTicketUnique(prevTicketList, t);
         }
      }
   }
}

void CheckClosedByBroker()
{
   for(int i = ArraySize(pendingHistoryTickets) - 1; i >= 0; i--)
   {
      ulong ticket = pendingHistoryTickets[i];
      bool historyReady = false;
      double totalPnL = GetPositionTotalPnL(ticket, historyReady);

      if(historyReady && !PositionSelectByTicket(ticket))
      {
         if(totalPnL > 0) { dailyProfit += totalPnL; wins++; }
         else if(totalPnL < 0) { dailyLoss += MathAbs(totalPnL); losses++; }
         else { breakevens++; }

         lastTradeCloseTime = TimeCurrent();
         ArrayRemove(pendingHistoryTickets, i, 1);
      }
   }

   for(int i=0; i<ArraySize(prevTicketList); i++)
   {
      ulong ticket = prevTicketList[i];
      if(!PositionSelectByTicket(ticket))
      {
         bool closedByEA = false;
         for(int j=0; j<ArraySize(closedByEaThisTick); j++)
            if(closedByEaThisTick[j] == ticket) { closedByEA = true; break; }

         if(!closedByEA)
         {
            bool historyReady = false;
            double totalPnL = GetPositionTotalPnL(ticket, historyReady);
            if(historyReady)
            {
               if(totalPnL > 0) { dailyProfit += totalPnL; wins++; }
               else if(totalPnL < 0) { dailyLoss += MathAbs(totalPnL); losses++; }
               else { breakevens++; }
               lastTradeCloseTime = TimeCurrent();
            }
            else
            {
               AddTicketUnique(pendingHistoryTickets, ticket);
            }
         }
      }
   }
}

void ResolvePendingTicketsForDayEnd()
{
   // Try to settle all pending tickets before day stats reset.
   for(int i = ArraySize(pendingHistoryTickets) - 1; i >= 0; i--)
   {
      ulong ticket = pendingHistoryTickets[i];
      bool historyReady = false;
      double totalPnL = GetPositionTotalPnL(ticket, historyReady);
      if(historyReady && !PositionSelectByTicket(ticket))
      {
         if(totalPnL > 0) { dailyProfit += totalPnL; wins++; }
         else if(totalPnL < 0) { dailyLoss += MathAbs(totalPnL); losses++; }
         else { breakevens++; }
         ArrayRemove(pendingHistoryTickets, i, 1);
      }
   }
   // Keep unresolved tickets for next ticks to avoid data loss.
}

double GetPositionTotalPnL(ulong ticket, bool &historyReady)
{
   historyReady = false;
   if(!HistorySelectByPosition(ticket)) return 0;

   double total = 0;
   int dealCount = HistoryDealsTotal();
   for(int i=dealCount-1; i>=0; i--)
   {
      ulong d = HistoryDealGetTicket(i);
      if(d > 0 && HistoryDealGetInteger(d, DEAL_POSITION_ID) == (long)ticket)
      {
         long entry = HistoryDealGetInteger(d, DEAL_ENTRY);
         if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
         {
            total += HistoryDealGetDouble(d, DEAL_PROFIT);
            total += HistoryDealGetDouble(d, DEAL_SWAP);
            total += HistoryDealGetDouble(d, DEAL_COMMISSION);
            historyReady = true;
         }
      }
   }
   return total;
}

void CalculateSuperTrend(int atrPeriod, double multiplier, double &high[], double &low[], double &close[], int totalBars, double &stArray[], int &dirArray[])
{
   ArrayResize(stArray, totalBars);
   ArrayResize(dirArray, totalBars);
   ArrayInitialize(stArray, 0);
   ArrayInitialize(dirArray, 0);
   if(totalBars <= atrPeriod) return;

   double atr[];
   ArrayResize(atr, totalBars);
   ArrayInitialize(atr, 0);

   for(int i=totalBars-1; i>=0; i--)
   {
      double tr = (i < totalBars-1) ? MathMax(high[i]-low[i], MathMax(MathAbs(high[i]-close[i+1]), MathAbs(low[i]-close[i+1]))) : (high[i]-low[i]);
      if(i >= totalBars-atrPeriod) atr[i] = tr;
      else atr[i] = (atr[i+1]*(atrPeriod-1) + tr)/atrPeriod;
   }

   double prevUp = 0, prevDown = 0;
   int lastDir = 0;
   int startIdx = MathMax(0, totalBars-atrPeriod-1);

   for(int i=startIdx; i>=0; i--)
   {
      double hl2 = (high[i] + low[i])/2.0;
      double basicUp = hl2 - multiplier * atr[i];
      double basicDown = hl2 + multiplier * atr[i];

      double up, down;
      if(lastDir == 0)
      {
         up = basicUp; down = basicDown;
         lastDir = (close[i] > basicDown) ? 1 : -1;
         prevUp = up; prevDown = down;
      }
      else
      {
         up = (basicUp > prevUp) ? basicUp : prevUp;
         down = (basicDown < prevDown) ? basicDown : prevDown;
      }

      bool flipped = false;
      if(lastDir == 1)
      {
         if(close[i] < down) { lastDir = -1; stArray[i] = down; flipped = true; }
         else stArray[i] = up;
      }
      else
      {
         if(close[i] > up) { lastDir = 1; stArray[i] = up; flipped = true; }
         else stArray[i] = down;
      }
      dirArray[i] = lastDir;

      if(flipped) { prevUp = basicUp; prevDown = basicDown; }
      else { prevUp = up; prevDown = down; }
   }
}

void UpdateSuperTrendSignals()
{
   int bars = 500;
   double high[], low[], close[];
   ArraySetAsSeries(high, true); ArraySetAsSeries(low, true); ArraySetAsSeries(close, true);
   int c1 = CopyHigh(_Symbol, PERIOD_CURRENT, 0, bars, high);
   int c2 = CopyLow(_Symbol, PERIOD_CURRENT, 0, bars, low);
   int c3 = CopyClose(_Symbol, PERIOD_CURRENT, 0, bars, close);
   int n = MathMin(c1, MathMin(c2, c3));
   if(n <= ST_ATR_Period + 2)
   {
      stMainDir = 0; stStrongDir = 0; strongDir = 0;
      return;
   }

   double stMainBuf[], stStrongBuf[];
   int dirMainBuf[], dirStrongBuf[];
   CalculateSuperTrend(ST_ATR_Period, ST_Multiplier, high, low, close, n, stMainBuf, dirMainBuf);
   CalculateSuperTrend(ST_ATR_Period, StrongST_Multiplier, high, low, close, n, stStrongBuf, dirStrongBuf);

   stMainDir = dirMainBuf[0];
   stStrongDir = dirStrongBuf[0];

   int oldStrong = strongDir;
   if(UseStrongSignal)
   {
      if(stMainDir == 1 && stStrongDir == 1) strongDir = 1;
      else if(stMainDir == -1 && stStrongDir == -1) strongDir = -1;
      else strongDir = 0;
   }
   else strongDir = stMainDir;

   if(strongDir != 0 && strongDir != oldStrong) lastStrongSignalTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   else if(strongDir == 0) lastStrongSignalTime = 0;
}

void DrawSuperTrendLines()
{
   ObjectsDeleteAll(0, "STLine_");
   int barsToShow = MathMax(50, DrawBars);
   double high[], low[], close[];
   ArraySetAsSeries(high, true); ArraySetAsSeries(low, true); ArraySetAsSeries(close, true);
   int c1 = CopyHigh(_Symbol, PERIOD_CURRENT, 0, barsToShow, high);
   int c2 = CopyLow(_Symbol, PERIOD_CURRENT, 0, barsToShow, low);
   int c3 = CopyClose(_Symbol, PERIOD_CURRENT, 0, barsToShow, close);
   int n = MathMin(c1, MathMin(c2, c3));
   if(n <= ST_ATR_Period + 2) return;

   double stMainBuf[], stStrongBuf[];
   int dirMainBuf[], dirStrongBuf[];
   CalculateSuperTrend(ST_ATR_Period, ST_Multiplier, high, low, close, n, stMainBuf, dirMainBuf);
   CalculateSuperTrend(ST_ATR_Period, StrongST_Multiplier, high, low, close, n, stStrongBuf, dirStrongBuf);

   datetime time[];
   ArraySetAsSeries(time, true);
   if(CopyTime(_Symbol, PERIOD_CURRENT, 0, n, time) <= 1) return;

   for(int i=1; i<n; i++)
   {
      if(dirMainBuf[i] != 0 && dirMainBuf[i-1] != 0)
      {
         string name = "STLine_Main_" + IntegerToString(i);
         ObjectCreate(0, name, OBJ_TREND, 0, time[i-1], stMainBuf[i-1], time[i], stMainBuf[i]);
         ObjectSetInteger(0, name, OBJPROP_COLOR, dirMainBuf[i]==1 ? clrLime : clrRed);
         ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
         ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
      }
   }

   if(UseStrongSignal)
   {
      for(int i=1; i<n; i++)
      {
         if(dirStrongBuf[i] != 0 && dirStrongBuf[i-1] != 0)
         {
            string name = "STLine_Strong_" + IntegerToString(i);
            ObjectCreate(0, name, OBJ_TREND, 0, time[i-1], stStrongBuf[i-1], time[i], stStrongBuf[i]);
            ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
            ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
            ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
         }
      }
   }
}

bool TradingAllowed()
{
   if(UseTimeFilter)
   {
      int start = 0, end = 0;
      if(!ParseHHMM(StartTime, start) || !ParseHHMM(EndTime, end)) return false;

      MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
      int curr = dt.hour * 60 + dt.min;

      bool inSession;
      if(start == end) inSession = true;
      else if(start < end) inSession = (curr >= start && curr < end);
      else inSession = (curr >= start || curr < end);
      if(!inSession) return false;
   }

   if(UseDailyLossLimit && dailyLoss >= DailyLossLimitUSD) return false;
   if(UseDailyProfitTarget && dailyProfit >= DailyProfitTargetUSD) return false;
   return true;
}

bool NewBar(){ datetime t=iTime(_Symbol, PERIOD_CURRENT, 0); if(t!=lastBarTime){lastBarTime=t; return true;} return false; }
void CheckNewDay(){ MqlDateTime dt; TimeToStruct(TimeCurrent(), dt); if(dt.day!=lastDay){ ResolvePendingTicketsForDayEnd(); lastDay=dt.day; dailyProfit=0; dailyLoss=0; wins=0; losses=0; breakevens=0; lastTradeCloseTime=0; } }
int CountPositions(){ int c=0; for(int i=PositionsTotal()-1;i>=0;i--){ ulong t=PositionGetTicket(i); if(PositionSelectByTicket(t) && PositionGetInteger(POSITION_MAGIC)==magicNumber && PositionGetString(POSITION_SYMBOL)==_Symbol) c++; } return c; }

void ManageOpenPositions()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magicNumber || PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      long type = PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double profitUSD = PositionGetDouble(POSITION_PROFIT);
      double price = (type==POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double profitPoints = (type==POSITION_TYPE_BUY) ? (price-openPrice)/point : (openPrice-price)/point;

      bool closed = false;
      if((CloseOnTrendChange && ((type==POSITION_TYPE_BUY && stMainDir==-1) || (type==POSITION_TYPE_SELL && stMainDir==1))) ||
         (CloseOnSignalReverse && ((type==POSITION_TYPE_BUY && strongDir!=1) || (type==POSITION_TYPE_SELL && strongDir!=-1))))
      {
         if(trade.PositionClose(ticket) && trade.ResultRetcode() == TRADE_RETCODE_DONE) closed = true;
      }

      bool beModified = false;
      if(!closed && UseBreakeven)
      {
         double pointVal = (tickValue / tickSize) * point * LotSize;
         if(pointVal <= 0) pointVal = 1.0;

         if(profitUSD >= BreakevenStartUSD)
         {
            bool slCanMove = (type == POSITION_TYPE_BUY) ? (currentSL < openPrice || currentSL == 0) : (currentSL > openPrice || currentSL == 0);
            if(slCanMove) { ModifySL(ticket, openPrice); PositionSelectByTicket(ticket); currentSL = PositionGetDouble(POSITION_SL); beModified = true; }
         }

         bool atBreakeven = (type == POSITION_TYPE_BUY) ? (currentSL >= openPrice - point) : (currentSL <= openPrice + point);
         if(profitUSD >= BreakevenLockUSD && atBreakeven)
         {
            double lockPoints = BreakevenLockUSD / pointVal;
            double lockPrice = (type == POSITION_TYPE_BUY) ? openPrice + lockPoints * point : openPrice - lockPoints * point;
            bool slCanMove = (type == POSITION_TYPE_BUY) ? (lockPrice > currentSL + point) : (lockPrice < currentSL - point);
            if(slCanMove) { ModifySL(ticket, lockPrice); beModified = true; }
         }
      }

      if(!closed && !beModified && UseTrailingStop && profitPoints >= TrailingStartPoints)
      {
         double trailSL = (type==POSITION_TYPE_BUY) ? price - TrailingStepPoints*point : price + TrailingStepPoints*point;
         bool better = (type==POSITION_TYPE_BUY && trailSL > currentSL) || (type==POSITION_TYPE_SELL && trailSL < currentSL);
         if(better && trailSL != 0) ModifySL(ticket, trailSL);
      }

      if(closed)
      {
         AddTicketUnique(closedByEaThisTick, ticket);
         AddTicketUnique(pendingHistoryTickets, ticket);
         lastTradeCloseTime = TimeCurrent();
      }
   }
}

void ModifySL(ulong ticket, double newSL)
{
   if(!PositionSelectByTicket(ticket)) return;
   double tp = PositionGetDouble(POSITION_TP);
   if(!trade.PositionModify(ticket, newSL, tp) && DebugMode)
      Print("ModifySL gagal untuk ticket #", ticket, " retcode=", trade.ResultRetcode());
}

void CheckEntrySignal()
{
   if(strongDir == 0) return;
   int barsSinceClose = (lastTradeCloseTime > 0) ? GetBarsSince(lastTradeCloseTime) : 999;
   if(lastTradeCloseTime > 0 && barsSinceClose < ReEntryCooldownBars) return;

   int minBars = EntryDelayBars;
   if(WaitForClosedCandle && minBars < 1) minBars = 1;
   int barsSinceSignal = (lastStrongSignalTime > 0) ? GetBarsSince(lastStrongSignalTime) : 999;
   if(lastStrongSignalTime > 0 && barsSinceSignal < minBars) return;

   double price = (strongDir==1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = 0, tp = 0;
   if(UseFixedSL) sl = (strongDir==1) ? price - FixedSL_Points*point : price + FixedSL_Points*point;
   if(UseFixedTP) tp = (strongDir==1) ? price + FixedTP_Points*point : price - FixedTP_Points*point;

   ENUM_ORDER_TYPE type = (strongDir==1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(trade.PositionOpen(_Symbol, type, LotSize, price, sl, tp, "Dark System"))
   {
      if(EnableSoundAlert) Alert("Dark System: Entry ", (type==ORDER_TYPE_BUY?"BUY":"SELL"), " dibuka.");
   }
}

int GetBarsSince(datetime fromTime){ int maxBars=MathMax(600, MathMax(EntryDelayBars, ReEntryCooldownBars)+100); for(int i=0;i<maxBars;i++){ if(iTime(_Symbol, PERIOD_CURRENT, i) <= fromTime) return i; } return maxBars; }

void CreateDashboard()
{
   string pn = DashPrefix+"Panel";
   ObjectCreate(0, pn, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, pn, OBJPROP_XDISTANCE, 10);
   ObjectSetInteger(0, pn, OBJPROP_YDISTANCE, 20);
   ObjectSetInteger(0, pn, OBJPROP_XSIZE, 220);
   ObjectSetInteger(0, pn, OBJPROP_YSIZE, 190);
   ObjectSetInteger(0, pn, OBJPROP_BGCOLOR, clrBlack);
   ObjectSetInteger(0, pn, OBJPROP_COLOR, clrDimGray);

   CreateLabel("Title", 15, 25, "DARK SYSTEM SCALPER", clrGold, 9, true);
   CreateLabel("SignalMain", 15, 45, "Main: -", clrWhite, 8);
   CreateLabel("SignalStrong", 15, 60, "Strong: -", clrWhite, 8);
   CreateLabel("Position", 15, 75, "Posisi: 0", clrWhite, 8);
   CreateLabel("Status", 15, 90, "Status: Menunggu", clrLightGray, 8);
   CreateLabel("Profit", 15, 110, "Profit: +$0.00", clrLime, 8);
   CreateLabel("Loss", 15, 125, "Loss: -$0.00", clrRed, 8);
   CreateLabel("WinLoss", 15, 140, "W/L/BE: 0/0/0", clrWhite, 8);
   CreateLabel("Target", 15, 155, "", clrWhite, 8);
}

void UpdateDashboard()
{
   string mainTxt = (stMainDir == 1) ? "Main: BUY" : (stMainDir == -1 ? "Main: SELL" : "Main: NO SIGNAL");
   string strongTxt = (strongDir == 1) ? "Strong: BUY" : (strongDir == -1 ? "Strong: SELL" : "Strong: WEAK");
   ObjectSetString(0, DashPrefix+"SignalMain", OBJPROP_TEXT, mainTxt);
   ObjectSetString(0, DashPrefix+"SignalStrong", OBJPROP_TEXT, strongTxt);
   ObjectSetInteger(0, DashPrefix+"SignalMain", OBJPROP_COLOR, stMainDir == 1 ? clrLime : (stMainDir == -1 ? clrRed : clrGray));

   int pc = CountPositions();
   ObjectSetString(0, DashPrefix+"Position", OBJPROP_TEXT, "Posisi: " + IntegerToString(pc));

   string status = "Menunggu";
   if(pc > 0) status = "Posisi Aktif";
   else if(strongDir == 0) status = "Menunggu Sinyal";
   else if(lastTradeCloseTime > 0 && GetBarsSince(lastTradeCloseTime) < ReEntryCooldownBars) status = "Cooldown";
   else status = "Siap Entry";
   ObjectSetString(0, DashPrefix+"Status", OBJPROP_TEXT, "Status: " + status);

   ObjectSetString(0, DashPrefix+"Profit", OBJPROP_TEXT, StringFormat("Profit: +$%.2f", dailyProfit));
   ObjectSetString(0, DashPrefix+"Loss", OBJPROP_TEXT, StringFormat("Loss: -$%.2f", dailyLoss));
   ObjectSetString(0, DashPrefix+"WinLoss", OBJPROP_TEXT, "W/L/BE: " + IntegerToString(wins) + "/" + IntegerToString(losses) + "/" + IntegerToString(breakevens));

   string tg = "";
   if(UseDailyProfitTarget) tg += StringFormat("Target %.2f ", DailyProfitTargetUSD);
   if(UseDailyLossLimit) tg += StringFormat("Limit %.2f", DailyLossLimitUSD);
   ObjectSetString(0, DashPrefix+"Target", OBJPROP_TEXT, tg);

   Comment("");
}

void DeleteDashboard()
{
   ObjectsDeleteAll(0, DashPrefix);
   Comment("");
}

void UpdateCountdown()
{
   int ps = PeriodSeconds();
   if(ps <= 0) return;
   int secLeft = ps - (int)(TimeCurrent() - iTime(_Symbol, PERIOD_CURRENT, 0));
   secLeft = MathMax(0, secLeft);
   string cd = IntegerToString(secLeft/60) + ":" + StringFormat("%02d", secLeft%60);
   ObjectSetString(0, CountdownName, OBJPROP_TEXT, cd);
   ObjectSetInteger(0, CountdownName, OBJPROP_COLOR, clrCyan);
   ObjectSetInteger(0, CountdownName, OBJPROP_FONTSIZE, 8);
   ObjectSetString(0, CountdownName, OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, CountdownName, OBJPROP_ANCHOR, ANCHOR_LEFT);
   datetime barTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   double price = iClose(_Symbol, PERIOD_CURRENT, 0);
   ObjectSetInteger(0, CountdownName, OBJPROP_TIME, barTime + ps/10);
   ObjectSetDouble(0, CountdownName, OBJPROP_PRICE, price + (5 * point));
}
