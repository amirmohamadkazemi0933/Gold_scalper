//+------------------------------------------------------------------+
//|                                 LiquiditySweep_SuperScalp.mq4     |
//|  Regime-aware super-scalp EA for XAUUSD M1                        |
//|                                                                    |
//|  TRENDING regime (M5 & M15 trend agree): only trades M1 in that   |
//|  higher-timeframe direction, using EMA8 reversal + breakout entry. |
//|                                                                    |
//|  RANGING regime (M5/M15 disagree or flat): only trades at the      |
//|  edges of the recent range - buys after a liquidity-sweep spike    |
//|  below support that reclaims back inside, sells after a spike      |
//|  above resistance that reclaims back inside. NEVER trades the      |
//|  middle of the range.                                              |
//|                                                                    |
//|  Risk-% position sizing. No external files needed.                |
//|  NOTE: No EA guarantees profit - forward test on demo first.      |
//+------------------------------------------------------------------+
#property copyright "Custom EA"
#property strict

//================== INPUTS ==================
input int    MagicNumber            = 555111;
input double RiskPercentPerTrade    = 1.0;     // % of equity risked per trade (0 = use FixedLot)
input double FixedLot               = 0.01;
input int    MaxSlippage            = 10;
input int    MaxPositions           = 1;

//---------------- Higher-timeframe trend filter ----------------
input bool   UseM5Trend              = true;
input bool   UseM15Trend             = true;
input int    HigherTF_EMA_Period     = 20;    // EMA used on M5/M15 to define their trend

//---------------- TRENDING mode: M1 EMA8 reversal + breakout ----------------
input int    EMA_Period              = 8;
input int    ReversalConfirmBars     = 2;
input int    MaxWaitBarsForBreakout  = 5;
input int    BreakoutLookbackBars    = 1;

//---------------- RANGING mode: support/resistance liquidity sweep ----------------
input int    RangeLookbackBars       = 100;   // M1 bars used to define the range high/low
input double OuterZonePercent        = 25.0;  // % of range height counted as support/resistance zone (rest = no-trade middle)
input double RangeSweepRSIOversold   = 35.0;  // required at the sweep candle for a support-buy
input double RangeSweepRSIOverbought = 65.0;  // required at the sweep candle for a resistance-sell

//---------------- RSI dead-flat filter (trending mode only) ----------------
input int    RSIPeriod               = 14;
input double RSIRangeLow             = 45.0;
input double RSIRangeHigh            = 55.0;

//---------------- Risk management ----------------
input double RiskRewardRatio         = 2.0;
input int    StopBufferPoints        = 20;
input double MaxSpreadUSD            = 0.50;
input int    ATRPeriodForStops       = 14;
input bool   TrailToEMA8AfterR       = true;
input double TrailArmRMultiple       = 1.0;

input bool   ShowDebugDashboard      = true;
input bool   PrintDebugLog           = true;

//================== REGIME CONSTANTS ==================
#define REGIME_TRENDING 1
#define REGIME_RANGING  2

//================== GLOBALS ==================
int      regime         = 0;
int      higherTrend    = 0;   // agreed M5/M15 direction, only meaningful when regime==REGIME_TRENDING

// trending-mode state
int      confirmedTrend = 0;
int      rawTrendPrev   = 0;
int      trendStreak    = 0;
int      armDirection   = 0;   // 1 = waiting to buy breakout, -1 = waiting to sell breakout
int      barsWaitedForBreakout = 0;

// ranging-mode state
int      rangeArm       = 0;   // 1 = armed buy at support, -1 = armed sell at resistance
double   rangeSweepExtreme = 0.0;
int      rangeBarsWaited   = 0;
double   lastRangeHigh = 0, lastRangeLow = 0;

datetime lastBarTime    = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   if(StringFind(Symbol(),"XAU") < 0)
      Print("Warning: this EA is tuned for XAUUSD. Current symbol: ", Symbol());
   lastBarTime = Time[0];
   return(INIT_SUCCEEDED);
  }
void OnDeinit(const int reason) { }

//+------------------------------------------------------------------+
//| Helpers                                                            |
//+------------------------------------------------------------------+
double EMA8v(int shift) { return iMA(NULL,0,EMA_Period,0,MODE_EMA,PRICE_CLOSE,shift); }
double RSIv(int shift)  { return iRSI(NULL,0,RSIPeriod,PRICE_CLOSE,shift); }
double ATRv()           { return iATR(NULL,0,ATRPeriodForStops,0); }

double RecentHigh(int shiftStart, int lookback)
  {
   double h = -1;
   for(int i=shiftStart;i<shiftStart+lookback;i++) if(High[i]>h) h=High[i];
   return h;
  }
double RecentLow(int shiftStart, int lookback)
  {
   double l = -1;
   for(int i=shiftStart;i<shiftStart+lookback;i++) if(l<0 || Low[i]<l) l=Low[i];
   return l;
  }

bool IsRSIDeadFlat()
  {
   double r = RSIv(0);
   return (r>=RSIRangeLow && r<=RSIRangeHigh);
  }

bool IsSpreadOK() { return (Ask-Bid) <= MaxSpreadUSD; }

int CountMyOrders()
  {
   int c=0;
   for(int i=0;i<OrdersTotal();i++)
     {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
      if(OrderSymbol()==Symbol() && OrderMagicNumber()==MagicNumber) c++;
     }
   return c;
  }

//+------------------------------------------------------------------+
//| Trend on a higher timeframe: closed-bar price vs EMA on that TF    |
//+------------------------------------------------------------------+
int TrendOnTF(int tf)
  {
   double c = iClose(NULL,tf,1);
   double e = iMA(NULL,tf,HigherTF_EMA_Period,0,MODE_EMA,PRICE_CLOSE,1);
   if(c>e) return 1;
   if(c<e) return -1;
   return 0;
  }

//+------------------------------------------------------------------+
//| Decide regime: TRENDING only if the enabled higher timeframes      |
//| agree on a direction; otherwise RANGING.                           |
//+------------------------------------------------------------------+
void DetermineRegime()
  {
   int votes = 0, sum = 0;
   if(UseM5Trend)  { int t=TrendOnTF(PERIOD_M5);  if(t!=0){votes++; sum+=t;} else {votes=-999;} }
   if(UseM15Trend) { int t=TrendOnTF(PERIOD_M15); if(t!=0){votes++; sum+=t;} else {votes=-999;} }

   int newRegime; int newHigherTrend = 0;
   if(votes<=0)
     {
      newRegime = REGIME_RANGING; // a flat higher TF or no filters enabled with disagreement -> treat as ranging
     }
   else if(sum==votes || sum==-votes) // all enabled TFs agree in the same direction
     {
      newRegime = REGIME_TRENDING;
      newHigherTrend = (sum>0) ? 1 : -1;
     }
   else
     {
      newRegime = REGIME_RANGING;
     }

   if(newRegime != regime && PrintDebugLog)
      Print("Regime change -> ", (newRegime==REGIME_TRENDING?"TRENDING":"RANGING"),
            (newRegime==REGIME_TRENDING? " (direction "+IntegerToString(newHigherTrend)+")" : ""));

   if(newRegime != regime)
     {
      // reset the state of whichever mode we're leaving so stale setups don't leak across regimes
      if(regime==REGIME_TRENDING) { confirmedTrend=0; armDirection=0; }
      if(regime==REGIME_RANGING)  { rangeArm=0; }
     }

   regime = newRegime;
   higherTrend = newHigherTrend;
  }

//+------------------------------------------------------------------+
//| TRENDING mode: EMA8 reversal confirmation, gated by higher TF      |
//+------------------------------------------------------------------+
void UpdateTrendAndReversal()
  {
   int rawTrend = 0;
   if(Close[1] > EMA8v(1)) rawTrend = 1;
   else if(Close[1] < EMA8v(1)) rawTrend = -1;

   if(rawTrend == rawTrendPrev) trendStreak++;
   else { trendStreak = 1; rawTrendPrev = rawTrend; }

   if(rawTrend != 0 && rawTrend != confirmedTrend && trendStreak >= ReversalConfirmBars)
     {
      confirmedTrend = rawTrend;
      if(rawTrend == higherTrend) // NEVER trade against the M5/M15 trend
        {
         armDirection = rawTrend;
         barsWaitedForBreakout = 0;
         if(PrintDebugLog)
            Print("Trending reversal confirmed & aligned with higher TF -> arming ",rawTrend);
        }
      else if(PrintDebugLog)
         Print("M1 reversal to ",rawTrend," conflicts with higher TF trend (",higherTrend,") -> ignored.");
     }
  }

void TryEnterTrend()
  {
   if(armDirection==0) return;
   if(CountMyOrders() >= MaxPositions) return;
   if(!IsSpreadOK()) return;
   if(IsRSIDeadFlat()) return;

   double brkHigh = RecentHigh(1, BreakoutLookbackBars);
   double brkLow  = RecentLow(1, BreakoutLookbackBars);
   double ema8    = EMA8v(0);
   double atr     = ATRv();

   if(armDirection==1 && Ask > brkHigh)
     {
      double stopPrice = MathMin(ema8, brkLow) - StopBufferPoints*Point - atr*0.2;
      double stopPts   = (Ask-stopPrice)/Point;
      double tp        = Ask + stopPts*RiskRewardRatio*Point;
      double lot       = CalcLot(stopPts);
      int ticket = OrderSend(Symbol(),OP_BUY,lot,Ask,MaxSlippage,stopPrice,tp,"TrendBuy",MagicNumber,0,clrBlue);
      if(ticket<0) Print("Buy OrderSend failed: ",GetLastError());
      else if(PrintDebugLog) Print("TREND BUY at ",Ask," SL=",stopPrice," TP=",tp);
      armDirection = 0;
     }
   else if(armDirection==-1 && Bid < brkLow)
     {
      double stopPrice = MathMax(ema8, brkHigh) + StopBufferPoints*Point + atr*0.2;
      double stopPts   = (stopPrice-Bid)/Point;
      double tp        = Bid - stopPts*RiskRewardRatio*Point;
      double lot       = CalcLot(stopPts);
      int ticket = OrderSend(Symbol(),OP_SELL,lot,Bid,MaxSlippage,stopPrice,tp,"TrendSell",MagicNumber,0,clrRed);
      if(ticket<0) Print("Sell OrderSend failed: ",GetLastError());
      else if(PrintDebugLog) Print("TREND SELL at ",Bid," SL=",stopPrice," TP=",tp);
      armDirection = 0;
     }
  }

//+------------------------------------------------------------------+
//| RANGING mode: liquidity sweep at support/resistance only           |
//+------------------------------------------------------------------+
void UpdateRangeSweep()
  {
   lastRangeHigh = RecentHigh(1, RangeLookbackBars);
   lastRangeLow  = RecentLow(1, RangeLookbackBars);
   double rangeSize = lastRangeHigh - lastRangeLow;
   if(rangeSize<=0) return;

   double supportZoneTop     = lastRangeLow  + rangeSize*OuterZonePercent/100.0;
   double resistanceZoneBot  = lastRangeHigh - rangeSize*OuterZonePercent/100.0;

   // Bullish sweep at support: wick pierces below the range low, closes back above it
   if(Low[1] < lastRangeLow && Close[1] > lastRangeLow && Close[1] <= supportZoneTop)
     {
      if(RSIv(1) <= RangeSweepRSIOversold)
        {
         rangeArm = 1;
         rangeSweepExtreme = Low[1];
         rangeBarsWaited = 0;
         if(PrintDebugLog) Print("Range: liquidity sweep at SUPPORT, arming BUY. Low=",Low[1]," rangeLow=",lastRangeLow);
        }
     }
   // Bearish sweep at resistance: wick pierces above the range high, closes back below it
   else if(High[1] > lastRangeHigh && Close[1] < lastRangeHigh && Close[1] >= resistanceZoneBot)
     {
      if(RSIv(1) >= RangeSweepRSIOverbought)
        {
         rangeArm = -1;
         rangeSweepExtreme = High[1];
         rangeBarsWaited = 0;
         if(PrintDebugLog) Print("Range: liquidity sweep at RESISTANCE, arming SELL. High=",High[1]," rangeHigh=",lastRangeHigh);
        }
     }
  }

void TryEnterRange()
  {
   if(rangeArm==0) return;
   if(CountMyOrders() >= MaxPositions) return;
   if(!IsSpreadOK()) return;

   double mid = (Bid+Ask)/2.0;
   double rangeSize = lastRangeHigh - lastRangeLow;
   if(rangeSize<=0) { rangeArm=0; return; }
   double supportZoneTop    = lastRangeLow  + rangeSize*OuterZonePercent/100.0;
   double resistanceZoneBot = lastRangeHigh - rangeSize*OuterZonePercent/100.0;

   double brkHigh = RecentHigh(1, BreakoutLookbackBars);
   double brkLow  = RecentLow(1, BreakoutLookbackBars);

   if(rangeArm==1)
     {
      if(mid > supportZoneTop) { rangeArm=0; return; } // price already ran into the middle - setup invalid, do NOT chase
      if(Ask > brkHigh)
        {
         double stopPrice = rangeSweepExtreme - StopBufferPoints*Point;
         double stopPts   = (Ask-stopPrice)/Point;
         double tpRange    = lastRangeHigh;
         double tpRR       = Ask + stopPts*RiskRewardRatio*Point;
         double tp         = MathMin(tpRange, tpRR); // take the nearer, more conservative target
         double lot        = CalcLot(stopPts);
         int ticket = OrderSend(Symbol(),OP_BUY,lot,Ask,MaxSlippage,stopPrice,tp,"RangeBuySupport",MagicNumber,0,clrBlue);
         if(ticket<0) Print("Buy OrderSend failed: ",GetLastError());
         else if(PrintDebugLog) Print("RANGE BUY (support) at ",Ask," SL=",stopPrice," TP=",tp);
         rangeArm = 0;
        }
     }
   else if(rangeArm==-1)
     {
      if(mid < resistanceZoneBot) { rangeArm=0; return; }
      if(Bid < brkLow)
        {
         double stopPrice = rangeSweepExtreme + StopBufferPoints*Point;
         double stopPts   = (stopPrice-Bid)/Point;
         double tpRange    = lastRangeLow;
         double tpRR       = Bid - stopPts*RiskRewardRatio*Point;
         double tp         = MathMax(tpRange, tpRR);
         double lot        = CalcLot(stopPts);
         int ticket = OrderSend(Symbol(),OP_SELL,lot,Bid,MaxSlippage,stopPrice,tp,"RangeSellResistance",MagicNumber,0,clrRed);
         if(ticket<0) Print("Sell OrderSend failed: ",GetLastError());
         else if(PrintDebugLog) Print("RANGE SELL (resistance) at ",Bid," SL=",stopPrice," TP=",tp);
         rangeArm = 0;
        }
     }
  }

//+------------------------------------------------------------------+
//| Position sizing                                                    |
//+------------------------------------------------------------------+
double CalcLot(double stopPoints)
  {
   if(RiskPercentPerTrade<=0) return FixedLot;
   double riskAmount = AccountEquity()*RiskPercentPerTrade/100.0;
   double tickValue  = MarketInfo(Symbol(),MODE_TICKVALUE);
   double lot = 0.01;
   if(tickValue>0 && stopPoints>0)
      lot = riskAmount/(stopPoints*tickValue);
   double minLot=MarketInfo(Symbol(),MODE_MINLOT), maxLot=MarketInfo(Symbol(),MODE_MAXLOT), step=MarketInfo(Symbol(),MODE_LOTSTEP);
   lot = MathFloor(lot/step)*step;
   lot = MathMax(minLot, MathMin(maxLot, lot));
   return lot;
  }

//+------------------------------------------------------------------+
//| Trailing stop to EMA8 once trade is in profit                      |
//+------------------------------------------------------------------+
void ManageTrailing()
  {
   if(!TrailToEMA8AfterR) return;
   double ema8 = EMA8v(0);

   for(int i=0;i<OrdersTotal();i++)
     {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
      if(OrderSymbol()!=Symbol() || OrderMagicNumber()!=MagicNumber) continue;

      double openP = OrderOpenPrice();
      double sl    = OrderStopLoss();
      if(sl==0) continue;
      double riskPts = MathAbs(openP-sl)/Point;
      if(riskPts<=0) continue;

      if(OrderType()==OP_BUY)
        {
         double profitR = (Bid-openP)/(riskPts*Point);
         if(profitR>=TrailArmRMultiple && ema8>sl && ema8<Bid)
            OrderModify(OrderTicket(),openP,ema8,OrderTakeProfit(),0,clrBlue);
        }
      else if(OrderType()==OP_SELL)
        {
         double profitR = (openP-Ask)/(riskPts*Point);
         if(profitR>=TrailArmRMultiple && ema8<sl && ema8>Ask)
            OrderModify(OrderTicket(),openP,ema8,OrderTakeProfit(),0,clrRed);
        }
     }
  }

//+------------------------------------------------------------------+
//| Diagnostics                                                         |
//+------------------------------------------------------------------+
void UpdateDashboard()
  {
   if(!ShowDebugDashboard) return;
   string txt = "";
   txt += "AutoTrading: "+(IsTradeAllowed()?"YES":"NO - enable it!")+"   Connected: "+(IsConnected()?"YES":"NO")+"\n";
   txt += "Regime: "+(regime==REGIME_TRENDING?"TRENDING (dir "+IntegerToString(higherTrend)+")":"RANGING")+"\n";
   if(regime==REGIME_TRENDING)
     {
      txt += "M1 trend streak: "+IntegerToString(trendStreak)+"/"+IntegerToString(ReversalConfirmBars)+"  Confirmed: "+IntegerToString(confirmedTrend)+"\n";
      txt += "Armed breakout: "+IntegerToString(armDirection)+" (waited "+IntegerToString(barsWaitedForBreakout)+"/"+IntegerToString(MaxWaitBarsForBreakout)+")\n";
     }
   else
     {
      txt += "Range: "+DoubleToString(lastRangeLow,2)+" - "+DoubleToString(lastRangeHigh,2)+"\n";
      txt += "Armed at S/R: "+IntegerToString(rangeArm)+" (waited "+IntegerToString(rangeBarsWaited)+")\n";
     }
   txt += "Spread: "+DoubleToString(Ask-Bid,2)+" / max "+DoubleToString(MaxSpreadUSD,2)+"\n";
   txt += "RSI: "+DoubleToString(RSIv(0),1)+"\n";
   txt += "Open orders (this EA): "+IntegerToString(CountMyOrders())+"\n";
   Comment(txt);
  }

//+------------------------------------------------------------------+
//| Main                                                                |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(!IsTradeAllowed())
     {
      Comment("AutoTrading is OFF or EA doesn't have permission.\nClick the AutoTrading button in MT4 toolbar\nand check Tools > Options > Expert Advisors\n> 'Allow automated trading' is ticked.");
      return;
     }

   ManageTrailing();

   if(Time[0]!=lastBarTime)
     {
      lastBarTime = Time[0];
      DetermineRegime();

      if(regime==REGIME_TRENDING)
        {
         UpdateTrendAndReversal();
         if(armDirection!=0)
           {
            barsWaitedForBreakout++;
            if(barsWaitedForBreakout>MaxWaitBarsForBreakout)
              {
               if(PrintDebugLog) Print("Trend breakout didn't come in time, dropping this arm.");
               armDirection = 0;
              }
           }
        }
      else // REGIME_RANGING
        {
         UpdateRangeSweep();
         if(rangeArm!=0)
           {
            rangeBarsWaited++;
            if(rangeBarsWaited>MaxWaitBarsForBreakout)
              {
               if(PrintDebugLog) Print("Range breakout didn't come in time, dropping this arm.");
               rangeArm = 0;
              }
           }
        }
     }

   if(regime==REGIME_TRENDING) TryEnterTrend();
   else                        TryEnterRange();

   UpdateDashboard();
  }
//+------------------------------------------------------------------+
