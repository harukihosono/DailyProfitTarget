//+------------------------------------------------------------------+
//|                                         DailyProfitTarget.mqh   |
//|                              Copyright 2024, Daily Trading      |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, Daily Trading"
#property strict

//+------------------------------------------------------------------+
//| MQL4/MQL5 互換性マクロ定義                                      |
//+------------------------------------------------------------------+
#ifdef __MQL5__
   #include <Trade\Trade.mqh>
   CTrade g_trade;

   #define MODE_TRADES 0
   #define SELECT_BY_POS 0
   #define MODE_HISTORY 1
   #define SELECT_BY_TICKET 1
   #define MODE_BID 1
   #define MODE_ASK 2
   #define OP_BUY 0
   #define OP_SELL 1
#endif

// AutoTradingControlをインクルード
#include "AutoTradingControl.mqh"

//+------------------------------------------------------------------+
//| 目標達成時のアクション                                          |
//+------------------------------------------------------------------+
enum ENUM_TARGET_ACTION
{
   ACTION_STOP_ONLY,        // EAを停止のみ
   ACTION_CLOSE_AND_STOP    // 全決済＋EA停止
};

//+------------------------------------------------------------------+
//| Input Parameters                                                |
//+------------------------------------------------------------------+
sinput string s1 = "=== 日次目標設定 ===";
input double DailyTargetAmount = 10000.0;             // 日次目標金額
input ENUM_TARGET_ACTION TargetAction = ACTION_CLOSE_AND_STOP; // 目標達成時のアクション
input bool EnableSound = true;                        // サウンド通知を有効化
input string SoundFile = "alert.wav";                 // 通知サウンドファイル

sinput string s2 = "=== 表示設定 ===";
input int DisplayX = 10;                              // 表示位置X座標
input int DisplayY = 25;                              // 表示位置Y座標
input int FontSize = 10;                              // フォントサイズ
input string FontName = "Arial";                      // フォント名

sinput string s3 = "=== 決済設定 ===";
input int MaxRetries = 3;                             // 決済リトライ回数
input int RetryDelay = 1000;                          // リトライ間隔(ミリ秒)

//+------------------------------------------------------------------+
//| グローバル変数                                                  |
//+------------------------------------------------------------------+
double g_dailyStartBalance = 0;                       // 日次開始時残高
int g_currentDay = 0;                                 // 現在の日付(YYYYMMDD形式)
bool g_targetReached = false;                         // 目標達成フラグ
bool g_eaStopped = false;                            // EA停止フラグ
bool g_pendingAutoTradingStop = false;               // 自動売買停止待機フラグ
datetime g_pendingStopStartTime = 0;                 // 自動売買停止待機開始時刻
string g_prefix = "DPM_";                            // オブジェクト名プレフィックス

//+------------------------------------------------------------------+
//| アカウント情報関数ラッパー                                      |
//+------------------------------------------------------------------+
double DPM_AccountBalance()
{
#ifdef __MQL5__
   return AccountInfoDouble(ACCOUNT_BALANCE);
#else
   return AccountBalance();
#endif
}

double DPM_AccountEquity()
{
#ifdef __MQL5__
   return AccountInfoDouble(ACCOUNT_EQUITY);
#else
   return AccountEquity();
#endif
}

int DPM_OrdersTotal()
{
#ifdef __MQL5__
   return PositionsTotal();
#else
   return OrdersTotal();
#endif
}

//+------------------------------------------------------------------+
//| MQL5用関数ラッパー                                              |
//+------------------------------------------------------------------+
#ifdef __MQL5__
bool DPM_OrderSelect(int index, int select, int pool = MODE_TRADES)
{
   if(pool == MODE_TRADES && select == SELECT_BY_POS)
   {
      return (PositionGetTicket(index) > 0);
   }
   else if(select == SELECT_BY_TICKET)
   {
      return PositionSelectByTicket(index);
   }
   return false;
}

string DPM_OrderSymbol()
{
   return PositionGetString(POSITION_SYMBOL);
}

int DPM_OrderType()
{
   ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   return (type == POSITION_TYPE_BUY) ? OP_BUY : OP_SELL;
}

double DPM_OrderLots()
{
   return PositionGetDouble(POSITION_VOLUME);
}

ulong DPM_OrderTicket()
{
   return PositionGetInteger(POSITION_TICKET);
}

double DPM_MarketInfo(string symbol, int mode)
{
   if(mode == MODE_BID)
      return SymbolInfoDouble(symbol, SYMBOL_BID);
   else if(mode == MODE_ASK)
      return SymbolInfoDouble(symbol, SYMBOL_ASK);
   return 0;
}

bool DPM_OrderClose(ulong ticket, double lots, double price, int slippage)
{
   g_trade.SetDeviationInPoints(slippage);
   return g_trade.PositionClose(ticket);
}

#else // MQL4

bool DPM_OrderSelect(int index, int select, int pool = MODE_TRADES)
{
   return OrderSelect(index, select, pool);
}

string DPM_OrderSymbol()
{
   return OrderSymbol();
}

int DPM_OrderType()
{
   return OrderType();
}

double DPM_OrderLots()
{
   return OrderLots();
}

int DPM_OrderTicket()
{
   return OrderTicket();
}

double DPM_MarketInfo(string symbol, int mode)
{
   return MarketInfo(symbol, mode);
}

bool DPM_OrderClose(int ticket, double lots, double price, int slippage)
{
   return OrderClose(ticket, lots, price, slippage, clrYellow);
}
#endif

//+------------------------------------------------------------------+
//| ポジション情報構造体                                            |
//+------------------------------------------------------------------+
struct PositionInfo
{
#ifdef __MQL5__
   ulong ticket;
#else
   int ticket;
#endif
   string symbol;
   int type;
   double lots;
};

//+------------------------------------------------------------------+
//| 共通関数実装                                                    |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| 初期化処理                                                      |
//+------------------------------------------------------------------+
void DPM_Init()
{
   // 入力パラメータ検証
   if(MathAbs(DailyTargetAmount) < 0.01)
   {
      Print("ERROR: DailyTargetAmount is too small or zero (", DailyTargetAmount, "). EA cannot function properly.");
      Alert("DailyProfitTarget: 目標金額が小さすぎるか0です。EAを停止します。");
      ExpertRemove();
      return;
   }

   // 現在の日付をYYYYMMDD形式で初期化
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   g_currentDay = dt.year * 10000 + dt.mon * 100 + dt.day;

   // 開始残高を現在の残高で初期化
   g_dailyStartBalance = DPM_AccountBalance();

   // フラグ初期化
   g_targetReached = false;
   g_eaStopped = false;
   g_pendingAutoTradingStop = false;
   g_pendingStopStartTime = 0;

#ifdef __MQL5__
   // CTrade設定
   g_trade.SetDeviationInPoints(10);
   g_trade.SetAsyncMode(false);  // 同期実行を保証
   g_trade.LogLevel(LOG_LEVEL_ERRORS);
#endif

   // 表示初期化
   CreateDisplay();
   UpdateDisplay();

   Print("DailyProfitTarget initialized");
   Print("Daily start balance: ", DoubleToString(g_dailyStartBalance, 2));
   Print("Daily target amount: ", DoubleToString(DailyTargetAmount, 2));
}

//+------------------------------------------------------------------+
//| 終了処理                                                        |
//+------------------------------------------------------------------+
void DPM_Deinit()
{
   // オブジェクト削除
   ObjectDelete(0, g_prefix + "Title");
   ObjectDelete(0, g_prefix + "StartBalance");
   ObjectDelete(0, g_prefix + "CurrentBalance");
   ObjectDelete(0, g_prefix + "DailyProfit");
   ObjectDelete(0, g_prefix + "Target");
   ObjectDelete(0, g_prefix + "Progress");
   ObjectDelete(0, g_prefix + "Remaining");
   ObjectDelete(0, g_prefix + "Status");
   ObjectDelete(0, g_prefix + "StartTime");

   Print("DailyProfitTarget deinitialized");
}

//+------------------------------------------------------------------+
//| メイン処理                                                      |
//+------------------------------------------------------------------+
void DPM_OnTick()
{
   // 日付変更チェック（EA停止中でも実行）
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int today = dt.year * 10000 + dt.mon * 100 + dt.day;

   if(today != g_currentDay)
   {
      OnNewDay(today);
   }

   // 自動売買停止待機中の場合、ポジション・オーダー確認
   if(g_pendingAutoTradingStop)
   {
      // タイムアウトチェック（60秒）
      if(g_pendingStopStartTime == 0)
         g_pendingStopStartTime = TimeCurrent();

      if(DPM_OrdersTotal() == 0)
      {
         DisableAutoTrading();
         g_pendingAutoTradingStop = false;
         g_pendingStopStartTime = 0;
         Print("All positions closed. AutoTrading disabled.");
      }
      else if(TimeCurrent() - g_pendingStopStartTime > 60)
      {
         Print("WARNING: Timeout waiting for positions to close (60 seconds). Disabling AutoTrading anyway.");
         DisableAutoTrading();
         g_pendingAutoTradingStop = false;
         g_pendingStopStartTime = 0;
      }
      UpdateDisplay();
      return;
   }

   // EA停止中の場合は表示のみ更新
   if(g_eaStopped)
   {
      UpdateDisplay();
      return;
   }

   // 日次利益計算（Balance基準：確定損益のみ）
   double currentBalance = DPM_AccountBalance();
   double dailyProfit = currentBalance - g_dailyStartBalance;

   // 目標達成チェック
   if(!g_targetReached && dailyProfit >= DailyTargetAmount)
   {
      OnTargetReached(dailyProfit);
   }

   // 表示更新
   UpdateDisplay();
}

//+------------------------------------------------------------------+
//| 新しい日の処理                                                  |
//+------------------------------------------------------------------+
void OnNewDay(int newDay)
{
   double finalBalance = DPM_AccountBalance();
   Print("New day started. Previous day final balance: ", DoubleToString(finalBalance, 2));

   // 新しい日の設定
   g_currentDay = newDay;
   g_dailyStartBalance = finalBalance;

   // フラグリセット（新しい日には自動的に再開）
   g_targetReached = false;
   g_eaStopped = false;
   g_pendingAutoTradingStop = false;
   g_pendingStopStartTime = 0;

   // 自動売買を再開
   EnableAutoTrading();

   Print("New day initialized. Start balance: ", DoubleToString(g_dailyStartBalance, 2));
   Print("EA automatically restarted and AutoTrading enabled for new day");
}

//+------------------------------------------------------------------+
//| 目標達成時の処理                                                |
//+------------------------------------------------------------------+
void OnTargetReached(double profit)
{
   g_targetReached = true;
   g_eaStopped = true;

   Print("===========================================");
   Print("Daily target reached! Profit: ", DoubleToString(profit, 2));
   Print("===========================================");

   // サウンド通知
   if(EnableSound)
   {
      PlaySound(SoundFile);
   }

   // アクション実行
   if(TargetAction == ACTION_CLOSE_AND_STOP)
   {
      Print("Closing all positions...");
      CloseAllPositions();

      // 全決済完了後に自動売買停止（ポジション・オーダーがなくなるまで待機）
      g_pendingAutoTradingStop = true;
      Print("EA stopped. Waiting for all positions to close before disabling AutoTrading. Will automatically restart tomorrow.");
   }
   else if(TargetAction == ACTION_STOP_ONLY)
   {
      // 自動売買を停止
      DisableAutoTrading();
      Print("EA stopped and AutoTrading disabled (positions remain open). Will automatically restart tomorrow.");
   }
}

//+------------------------------------------------------------------+
//| 全ポジション決済（修正版：チケット配列使用）                        |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   int total = DPM_OrdersTotal();
   
   // 決済対象のポジション情報を配列に格納
   PositionInfo positions[];
   ArrayResize(positions, total);
   int posCount = 0;
   
   // ステップ1: 全ポジション情報を取得
   for(int i = 0; i < total; i++)
   {
      if(!DPM_OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
         
      int type = DPM_OrderType();
      if(type != OP_BUY && type != OP_SELL)
         continue;
      
      positions[posCount].ticket = DPM_OrderTicket();
      positions[posCount].symbol = DPM_OrderSymbol();
      positions[posCount].type = type;
      positions[posCount].lots = DPM_OrderLots();
      posCount++;
   }
   
   // ステップ2: チケット番号で決済
   int closedCount = 0;
   int failedCount = 0;
   
   for(int i = 0; i < posCount; i++)
   {
      bool success = false;
      
      // リトライ処理
      for(int retry = 0; retry < MaxRetries && !success; retry++)
      {
         if(retry > 0)
         {
            Print("Retry closing order #", positions[i].ticket, " attempt ", retry + 1);
            Sleep(RetryDelay);
         }
         
         // 最新の価格を取得
         double closePrice = (positions[i].type == OP_BUY) ?
                            DPM_MarketInfo(positions[i].symbol, MODE_BID) :
                            DPM_MarketInfo(positions[i].symbol, MODE_ASK);
         
         // 決済実行
         success = DPM_OrderClose(positions[i].ticket, positions[i].lots, closePrice, 3);
         
         if(!success)
         {
            int error = GetLastError();
            Print("Failed to close order #", positions[i].ticket, 
                  " Symbol: ", positions[i].symbol, " Error: ", error);
         }
         else
         {
            Print("Successfully closed order #", positions[i].ticket);
         }
      }
      
      if(success)
         closedCount++;
      else
         failedCount++;
   }
   
   Print("Close summary - Total: ", posCount, " Success: ", closedCount, " Failed: ", failedCount);
}

//+------------------------------------------------------------------+
//| 表示作成                                                        |
//+------------------------------------------------------------------+
void CreateDisplay()
{
   int y = DisplayY;

   CreateLabel(g_prefix + "Title", "■ 日次利益管理", DisplayX, y, clrWhite, FontSize + 2, true);
   y += 25;

   CreateLabel(g_prefix + "StartBalance", "", DisplayX, y, clrSilver, FontSize);
   y += 20;

   CreateLabel(g_prefix + "CurrentBalance", "", DisplayX, y, clrSilver, FontSize);
   y += 20;

   CreateLabel(g_prefix + "DailyProfit", "", DisplayX, y, clrWhite, FontSize);
   y += 20;

   CreateLabel(g_prefix + "Target", "", DisplayX, y, clrGold, FontSize);
   y += 20;

   CreateLabel(g_prefix + "Progress", "", DisplayX, y, clrCyan, FontSize);
   y += 20;

   CreateLabel(g_prefix + "Remaining", "", DisplayX, y, clrSilver, FontSize);
   y += 20;

   CreateLabel(g_prefix + "Status", "", DisplayX, y, clrWhite, FontSize + 1);
   y += 20;

   CreateLabel(g_prefix + "StartTime", "", DisplayX, y, clrGray, FontSize - 1);
}

//+------------------------------------------------------------------+
//| 表示更新                                                        |
//+------------------------------------------------------------------+
void UpdateDisplay()
{
   double currentBalance = DPM_AccountBalance();
   double dailyProfit = currentBalance - g_dailyStartBalance;
   double remaining = DailyTargetAmount - dailyProfit;

   // 進捗率計算（ゼロ除算対策）
   double progressPercent = 0;
   if(MathAbs(DailyTargetAmount) > 0.01)  // ゼロチェック
   {
      progressPercent = (dailyProfit / DailyTargetAmount) * 100.0;
      progressPercent = MathMin(MathMax(progressPercent, -100.0), 100.0);
   }

   // 色設定
   color profitColor = (dailyProfit >= 0) ? clrLime : clrRed;
   color progressColor = (progressPercent >= 100) ? clrLime :
                        (progressPercent >= 50) ? clrCyan :
                        (progressPercent >= 0) ? clrYellow : clrRed;

   // テキスト更新
   UpdateLabel(g_prefix + "StartBalance", "開始残高: " + DoubleToString(g_dailyStartBalance, 2), clrSilver);
   UpdateLabel(g_prefix + "CurrentBalance", "現在残高: " + DoubleToString(currentBalance, 2), clrSilver);
   UpdateLabel(g_prefix + "DailyProfit", "日次利益: " + DoubleToString(dailyProfit, 2), profitColor);
   UpdateLabel(g_prefix + "Target", "目標金額: " + DoubleToString(DailyTargetAmount, 2), clrGold);
   UpdateLabel(g_prefix + "Progress", "進捗率: " + DoubleToString(progressPercent, 1) + "%", progressColor);

   if(!g_targetReached)
   {
      UpdateLabel(g_prefix + "Remaining", "残り: " + DoubleToString(remaining, 2), clrSilver);
      UpdateLabel(g_prefix + "Status", "状態: 稼働中", clrLime);
   }
   else
   {
      UpdateLabel(g_prefix + "Remaining", "目標達成!", clrLime);
      UpdateLabel(g_prefix + "Status", "状態: 目標達成(停止)", clrGold);
   }
}

//+------------------------------------------------------------------+
//| ラベル作成                                                      |
//+------------------------------------------------------------------+
void CreateLabel(string name, string text, int x, int y, color clr, int size, bool bold = false)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
      ObjectSetString(0, name, OBJPROP_FONT, bold ? FontName + " Bold" : FontName);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   }

   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}

//+------------------------------------------------------------------+
//| ラベル更新                                                      |
//+------------------------------------------------------------------+
void UpdateLabel(string name, string text, color clr)
{
   if(ObjectFind(0, name) >= 0)
   {
      ObjectSetString(0, name, OBJPROP_TEXT, text);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   }
}