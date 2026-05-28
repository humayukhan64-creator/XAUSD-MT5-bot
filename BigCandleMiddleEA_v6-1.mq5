//+------------------------------------------------------------------+
//|     Big Candle Middle Entry EA  v6.0  FINAL CORRECT              |
//|     XAUUSD M1 | Exactly as seen in video                        |
//|                                                                  |
//|  STRATEGY (video se):                                            |
//|  1. Big candle detect karo                                       |
//|  2. Candle ke middle pe BUY STOP + SELL STOP dono place karo    |
//|  3. Jo pehle hit ho → dusra TURANT delete                       |
//|  4. Trade mein $1 SL, trailing $1 step se                       |
//|  5. Trade close hone par → NEXT big candle ka wait karo         |
//+------------------------------------------------------------------+
#property copyright "BigCandleMiddleEA v6"
#property version   "6.00"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

CTrade         trade;
CPositionInfo  posInfo;
COrderInfo     orderInfo;

//--- Inputs
input group "=== Candle Detection ==="
input double   ATRMultiplier     = 1.2;    // Big candle size (ATR x this)
input int      ATRPeriod         = 14;     // ATR period

input group "=== Risk Management ==="
input double   LotSize           = 0.01;
input double   SL_Dollars        = 1.0;    // SL in USD ($1)
input double   TrailStartDollars = 1.0;    // Trail kab start ($1 profit ke baad)
input double   TrailStepDollars  = 1.0;    // Trail step ($1)

input group "=== EA Settings ==="
input int      MagicNumber       = 777006;
input int      Slippage          = 30;
input bool     PrintLogs         = true;

//--- Globals
double   pointValue     = 0;
double   dollarPerPoint = 0;
datetime lastCandleTime = 0;
ulong    buyTicket      = 0;
ulong    sellTicket     = 0;
int      atrHandle      = INVALID_HANDLE;

// State tracking
bool     waitingForBigCandle = true;
datetime bigCandleTime       = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFilling(ORDER_FILLING_RETURN);

   double tickValue   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   pointValue         = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   dollarPerPoint     = (tickValue / tickSize) * pointValue * LotSize;

   atrHandle = iATR(_Symbol, PERIOD_M1, ATRPeriod);
   if(atrHandle == INVALID_HANDLE) { Alert("ATR indicator failed!"); return INIT_FAILED; }

   Print("=== BigCandle EA v6 FINAL ===");
   Print("Symbol=", _Symbol, " | DollarPerPoint=", DoubleToString(dollarPerPoint, 6));
   Print("SL=$", SL_Dollars, " = ", DoubleToString(SL_Dollars/dollarPerPoint, 1), " points");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnTick()
{
   // Har tick pe trailing SL manage karo
   ManageTrailingSL();

   // Sirf naye candle pe logic run karo
   datetime curBar = iTime(_Symbol, PERIOD_M1, 0);
   if(curBar == lastCandleTime) return;
   lastCandleTime = curBar;

   // Agar position ya pending order hai → skip (OCO handle karega)
   if(HasOpenPosition() || HasPendingOrders()) return;

   // Big candle dhundo
   double hi   = iHigh (_Symbol, PERIOD_M1, 1);
   double lo   = iLow  (_Symbol, PERIOD_M1, 1);
   double size = hi - lo;

   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(atrHandle, 0, 1, 1, atrBuf) <= 0) return;
   double atr = atrBuf[0];

   if(PrintLogs)
      Print("Candle[1] size=", DoubleToString(size,2),
            " | ATR threshold=", DoubleToString(atr*ATRMultiplier,2));

   if(size < atr * ATRMultiplier) return;

   // --- BIG CANDLE MILI! ---
   double middle = NormalizeDouble((hi + lo) / 2.0, _Digits);

   // SL / TP calculations
   double slPts = SL_Dollars / dollarPerPoint;
   // TP sirf backup (20x SL) — exit trailing SL se hoga
   double tpPts = slPts * 20.0;

   // Broker minimum stop distance
   long   stopLvl = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = (stopLvl + 3) * pointValue;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(PrintLogs)
   {
      Print("=== BIG CANDLE! Hi=", hi, " Lo=", lo, " Mid=", middle, " ===");
      Print("Ask=", ask, " Bid=", bid);
      Print("SL_pts=", DoubleToString(slPts,1), " minDist=", DoubleToString(minDist,_Digits));
   }

   buyTicket  = 0;
   sellTicket = 0;

   // =============================================================
   // BUY ORDER
   // Middle > ask → BUY STOP (price upar aaye tab buy)
   // Middle < bid → BUY LIMIT (price neeche aaye tab buy)
   // Middle ~ current → adjust karke place karo
   // =============================================================
   double buyEntry = middle;
   double buySL, buyTP;
   buySL = NormalizeDouble(buyEntry - MathMax(slPts, (double)stopLvl+3) * pointValue, _Digits);
   buyTP = NormalizeDouble(buyEntry + tpPts * pointValue, _Digits);

   if(buyEntry > ask + minDist)
   {
      if(trade.BuyStop(LotSize, buyEntry, _Symbol, buySL, buyTP, ORDER_TIME_GTC, 0, "BCM_BUY"))
      {
         buyTicket = trade.ResultOrder();
         if(PrintLogs) Print("✓ BUY STOP @ ", buyEntry, " SL=", buySL);
      }
      else Print("✗ BuyStop fail code=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   }
   else if(buyEntry < bid - minDist)
   {
      if(trade.BuyLimit(LotSize, buyEntry, _Symbol, buySL, buyTP, ORDER_TIME_GTC, 0, "BCM_BUY"))
      {
         buyTicket = trade.ResultOrder();
         if(PrintLogs) Print("✓ BUY LIMIT @ ", buyEntry, " SL=", buySL);
      }
      else Print("✗ BuyLimit fail code=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   }
   else
   {
      // Too close — put BUY LIMIT just below bid
      buyEntry = NormalizeDouble(bid - minDist, _Digits);
      buySL    = NormalizeDouble(buyEntry - MathMax(slPts, (double)stopLvl+3)*pointValue, _Digits);
      buyTP    = NormalizeDouble(buyEntry + tpPts * pointValue, _Digits);
      if(trade.BuyLimit(LotSize, buyEntry, _Symbol, buySL, buyTP, ORDER_TIME_GTC, 0, "BCM_BUY"))
      {
         buyTicket = trade.ResultOrder();
         if(PrintLogs) Print("✓ BUY LIMIT (adj) @ ", buyEntry, " SL=", buySL);
      }
      else Print("✗ BuyLimit(adj) fail code=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   }

   // =============================================================
   // SELL ORDER
   // Middle < bid → SELL STOP (price neeche aaye tab sell)
   // Middle > ask → SELL LIMIT (price upar aaye tab sell)
   // =============================================================
   double sellEntry = middle;
   double sellSL, sellTP;
   sellSL = NormalizeDouble(sellEntry + MathMax(slPts, (double)stopLvl+3)*pointValue, _Digits);
   sellTP = NormalizeDouble(sellEntry - tpPts * pointValue, _Digits);

   if(sellEntry < bid - minDist)
   {
      if(trade.SellStop(LotSize, sellEntry, _Symbol, sellSL, sellTP, ORDER_TIME_GTC, 0, "BCM_SELL"))
      {
         sellTicket = trade.ResultOrder();
         if(PrintLogs) Print("✓ SELL STOP @ ", sellEntry, " SL=", sellSL);
      }
      else Print("✗ SellStop fail code=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   }
   else if(sellEntry > ask + minDist)
   {
      if(trade.SellLimit(LotSize, sellEntry, _Symbol, sellSL, sellTP, ORDER_TIME_GTC, 0, "BCM_SELL"))
      {
         sellTicket = trade.ResultOrder();
         if(PrintLogs) Print("✓ SELL LIMIT @ ", sellEntry, " SL=", sellSL);
      }
      else Print("✗ SellLimit fail code=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   }
   else
   {
      // Too close — put SELL LIMIT just above ask
      sellEntry = NormalizeDouble(ask + minDist, _Digits);
      sellSL    = NormalizeDouble(sellEntry + MathMax(slPts, (double)stopLvl+3)*pointValue, _Digits);
      sellTP    = NormalizeDouble(sellEntry - tpPts * pointValue, _Digits);
      if(trade.SellLimit(LotSize, sellEntry, _Symbol, sellSL, sellTP, ORDER_TIME_GTC, 0, "BCM_SELL"))
      {
         sellTicket = trade.ResultOrder();
         if(PrintLogs) Print("✓ SELL LIMIT (adj) @ ", sellEntry, " SL=", sellSL);
      }
      else Print("✗ SellLimit(adj) fail code=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   }

   if(PrintLogs)
      Print("Orders placed → BUY ticket=", buyTicket, " | SELL ticket=", sellTicket);
}

//+------------------------------------------------------------------+
// OCO: Ek order FILL hote hi dusra TURANT delete
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
{
   // Sirf ORDER_DELETE events handle karo
   if(trans.type != TRADE_TRANSACTION_ORDER_DELETE) return;
   if(trans.order_state != ORDER_STATE_FILLED)      return;

   ulong filled = trans.order;
   Sleep(200); // Broker ko process karne do

   if(PrintLogs)
      Print("Order filled: ", filled, " | buyTicket=", buyTicket, " sellTicket=", sellTicket);

   // BUY fill hua → SELL delete karo
   if(filled == buyTicket && sellTicket != 0)
   {
      if(IsOrderExists(sellTicket))
      {
         if(trade.OrderDelete(sellTicket))
            if(PrintLogs) Print("OCO ✓ BUY filled → SELL (", sellTicket, ") DELETED");
         else
            if(PrintLogs) Print("OCO ✗ SELL delete failed: ", trade.ResultRetcode());
      }
      sellTicket = 0;
   }
   // SELL fill hua → BUY delete karo
   else if(filled == sellTicket && buyTicket != 0)
   {
      if(IsOrderExists(buyTicket))
      {
         if(trade.OrderDelete(buyTicket))
            if(PrintLogs) Print("OCO ✓ SELL filled → BUY (", buyTicket, ") DELETED");
         else
            if(PrintLogs) Print("OCO ✗ BUY delete failed: ", trade.ResultRetcode());
      }
      buyTicket = 0;
   }
}

//+------------------------------------------------------------------+
// Trailing SL — $1 dollar step
// $1 profit  → SL breakeven
// $2 profit  → SL +$1 locked
// $3 profit  → SL +$2 locked
//+------------------------------------------------------------------+
void ManageTrailingSL()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i))       continue;
      if(posInfo.Magic()  != MagicNumber) continue;
      if(posInfo.Symbol() != _Symbol)     continue;

      double profit = posInfo.Profit();
      if(profit < TrailStartDollars)      continue;

      ulong  ticket    = posInfo.Ticket();
      double openPrice = posInfo.PriceOpen();
      double curSL     = posInfo.StopLoss();
      double curTP     = posInfo.TakeProfit();

      double steps   = MathFloor((profit - TrailStartDollars) / TrailStepDollars);
      double lockPts = (steps * TrailStepDollars) / dollarPerPoint;

      if(posInfo.PositionType() == POSITION_TYPE_BUY)
      {
         double newSL = NormalizeDouble(openPrice + lockPts * pointValue, _Digits);
         if(newSL > curSL + pointValue)
         {
            if(trade.PositionModify(ticket, newSL, curTP))
               if(PrintLogs)
                  Print("BUY Trail ✓ SL: ", curSL, "→", newSL,
                        " | Locked=$", DoubleToString(steps*TrailStepDollars,2),
                        " | Profit=$", DoubleToString(profit,2));
         }
      }
      else // SELL
      {
         double newSL = NormalizeDouble(openPrice - lockPts * pointValue, _Digits);
         if(curSL == 0 || newSL < curSL - pointValue)
         {
            if(trade.PositionModify(ticket, newSL, curTP))
               if(PrintLogs)
                  Print("SELL Trail ✓ SL: ", curSL, "→", newSL,
                        " | Locked=$", DoubleToString(steps*TrailStepDollars,2),
                        " | Profit=$", DoubleToString(profit,2));
         }
      }
   }
}

//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Magic() == MagicNumber && posInfo.Symbol() == _Symbol)
         return true;
   }
   return false;
}

bool HasPendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!orderInfo.SelectByIndex(i)) continue;
      if(orderInfo.Magic() == MagicNumber && orderInfo.Symbol() == _Symbol)
         return true;
   }
   return false;
}

bool IsOrderExists(ulong ticket)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!orderInfo.SelectByIndex(i)) continue;
      if(orderInfo.Ticket() == ticket) return true;
   }
   return false;
}

void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   Print("EA v6 stopped. Reason=", reason);
}
//+------------------------------------------------------------------+
