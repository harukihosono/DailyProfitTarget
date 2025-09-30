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
input int MagicNumber = 0;                            // マジックナンバー(0=全ポジション)

sinput string s4 = "=== タイムゾーン設定 ===";
input int TimezoneOffset = 0;                         // サーバー時刻からのオフセット(時間)

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

// 表示最適化用キャッシュ
double g_lastDisplayedBalance = 0;                   // 前回表示した残高
double g_lastDisplayedProfit = 0;                    // 前回表示した利益
double g_lastDisplayedProgress = 0;                  // 前回表示した進捗率

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
   ResetLastError();  // エラーコードをクリア

   if(pool == MODE_TRADES && select == SELECT_BY_POS)
   {
      return (PositionGetTicket(index) > 0);
   }
   else if(select == SELECT_BY_TICKET)
   {
      return PositionSelectByTicket(index);
   }

   Print("ERROR: DPM_OrderSelect - Invalid parameters. select=", select, " pool=", pool);
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
   double price = 0;

   if(mode == MODE_BID)
      price = SymbolInfoDouble(symbol, SYMBOL_BID);
   else if(mode == MODE_ASK)
      price = SymbolInfoDouble(symbol, SYMBOL_ASK);
   else
   {
      Print("ERROR: DPM_MarketInfo - Invalid mode: ", mode);
      return 0;
   }

   if(price <= 0)
   {
      Print("ERROR: DPM_MarketInfo - Invalid price for ", symbol, " mode=", mode, " price=", price);
   }

   return price;
}

bool DPM_OrderClose(ulong ticket, double lots, double price, int slippage)
{
   g_trade.SetDeviationInPoints(slippage);
   return g_trade.PositionClose(ticket);
}

#else // MQL4

bool DPM_OrderSelect(int index, int select, int pool = MODE_TRADES)
{
   ResetLastError();  // エラーコードをクリア
   bool result = OrderSelect(index, select, pool);

   if(!result)
   {
      int error = GetLastError();
      if(error != ERR_NO_ERROR)
      {
         Print("ERROR: DPM_OrderSelect failed. index=", index, " select=", select, " pool=", pool, " Error=", error);
      }
   }

   return result;
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
   double price = MarketInfo(symbol, mode);

   if(price <= 0)
   {
      Print("ERROR: DPM_MarketInfo - Invalid price for ", symbol, " mode=", mode, " price=", price);
   }

   return price;
}

bool DPM_OrderClose(int ticket, double lots, double price, int slippage)
{
   return OrderClose(ticket, lots, price, slippage, clrYellow);
}
#endif

//+------------------------------------------------------------------+
//| エラーコード説明関数                                            |
//+------------------------------------------------------------------+
string ErrorDescription(int error_code)
{
   string error_string = "";

   switch(error_code)
   {
      case 0:     error_string = "No error"; break;
      case 1:     error_string = "No error, trade operation successful"; break;
      case 2:     error_string = "Common error"; break;
      case 3:     error_string = "Invalid trade parameters"; break;
      case 4:     error_string = "Trade server is busy"; break;
      case 5:     error_string = "Old version of the client terminal"; break;
      case 6:     error_string = "No connection with trade server"; break;
      case 7:     error_string = "Not enough rights"; break;
      case 8:     error_string = "Too frequent requests"; break;
      case 9:     error_string = "Malfunctional trade operation"; break;
      case 64:    error_string = "Account disabled"; break;
      case 65:    error_string = "Invalid account"; break;
      case 128:   error_string = "Trade timeout"; break;
      case 129:   error_string = "Invalid price"; break;
      case 130:   error_string = "Invalid stops"; break;
      case 131:   error_string = "Invalid trade volume"; break;
      case 132:   error_string = "Market is closed"; break;
      case 133:   error_string = "Trade is disabled"; break;
      case 134:   error_string = "Not enough money"; break;
      case 135:   error_string = "Price changed"; break;
      case 136:   error_string = "Off quotes"; break;
      case 137:   error_string = "Broker is busy"; break;
      case 138:   error_string = "Requote"; break;
      case 139:   error_string = "Order is locked"; break;
      case 140:   error_string = "Long positions only allowed"; break;
      case 141:   error_string = "Too many requests"; break;
      case 145:   error_string = "Modification denied because order too close to market"; break;
      case 146:   error_string = "Trade context is busy"; break;
      case 147:   error_string = "Expirations are denied by broker"; break;
      case 148:   error_string = "Amount of open and pending orders has reached the limit"; break;
      case 4000:  error_string = "No error"; break;
      case 4001:  error_string = "Wrong function pointer"; break;
      case 4051:  error_string = "Invalid function parameter value"; break;
      case 4106:  error_string = "Unknown symbol"; break;
      case 4108:  error_string = "Invalid ticket"; break;
      case 4109:  error_string = "Trading not allowed"; break;
      case 4110:  error_string = "Longs not allowed"; break;
      case 4111:  error_string = "Shorts not allowed"; break;
      default:    error_string = "Unknown error (" + IntegerToString(error_code) + ")";
   }

   return error_string;
}

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
//| 現在の日付を取得（タイムゾーン調整済み）                          |
//+------------------------------------------------------------------+
int GetCurrentDay()
{
   datetime localTime = TimeCurrent() + TimezoneOffset * 3600;
   MqlDateTime dt;
   TimeToStruct(localTime, dt);
   return dt.year * 10000 + dt.mon * 100 + dt.day;
}

//+------------------------------------------------------------------+
//| 週末判定（タイムゾーン調整済み）                                  |
//+------------------------------------------------------------------+
bool IsWeekend()
{
   datetime localTime = TimeCurrent() + TimezoneOffset * 3600;
   MqlDateTime dt;
   TimeToStruct(localTime, dt);
   // day_of_week: 0=Sunday, 1=Monday, ..., 6=Saturday
   return (dt.day_of_week == 0 || dt.day_of_week == 6);
}

//+------------------------------------------------------------------+
//| 初期化処理                                                      |
//+------------------------------------------------------------------+
void DPM_Init()
{
   // DLL機能の確認
   if(!IsDLLAvailable())
   {
      Print("ERROR: DLL imports are not enabled. AutoTrading control will not work.");
      Alert("DailyProfitTarget: DLL機能が無効です。\nツール > オプション > エキスパートアドバイザ > DLLの使用を許可 をチェックしてください。");
      ExpertRemove();
      return;
   }

   // 入力パラメータ検証
   if(MathAbs(DailyTargetAmount) < 0.01)
   {
      Print("ERROR: DailyTargetAmount is too small or zero (", DailyTargetAmount, "). EA cannot function properly.");
      Alert("DailyProfitTarget: 目標金額が小さすぎるか0です。EAを停止します。");
      ExpertRemove();
      return;
   }

   // 現在の日付を取得（タイムゾーン調整済み）
   g_currentDay = GetCurrentDay();

   // 週末チェック
   if(IsWeekend())
   {
      Print("WARNING: EA started on weekend");
      Print("WARNING: Daily tracking will begin on next trading day");
      Print("INFO: Timezone offset: ", TimezoneOffset, " hours from server time");
   }

   // 開始残高を現在の残高で初期化
   g_dailyStartBalance = DPM_AccountBalance();

   // フラグ初期化
   g_targetReached = false;
   g_eaStopped = false;
   g_pendingAutoTradingStop = false;
   g_pendingStopStartTime = 0;

   // 表示キャッシュ初期化
   g_lastDisplayedBalance = 0;
   g_lastDisplayedProfit = 0;
   g_lastDisplayedProgress = 0;

#ifdef __MQL5__
   // CTrade設定
   g_trade.SetDeviationInPoints(10);
   g_trade.SetAsyncMode(false);  // 同期実行を保証
   g_trade.LogLevel(LOG_LEVEL_ERRORS);
#endif

   // 表示初期化
   CreateDisplay();
   UpdateDisplay();

   Print("===========================================");
   Print("DailyProfitTarget EA v2.0 initialized");
   Print("Daily start balance: ", DoubleToString(g_dailyStartBalance, 2));
   Print("Daily target amount: ", DoubleToString(DailyTargetAmount, 2));
   Print("Target action: ", (TargetAction == ACTION_CLOSE_AND_STOP ? "Close all + Stop" : "Stop only"));
   Print("Max retry attempts: ", MaxRetries);
   Print("Magic number filter: ", MagicNumber == 0 ? "Disabled (all positions)" : IntegerToString(MagicNumber));
   Print("Timezone offset: ", TimezoneOffset, " hours");
   Print("===========================================");
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
   int today = GetCurrentDay();

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

      int remainingPositions = DPM_OrdersTotal();

      if(remainingPositions == 0)
      {
         DisableAutoTrading();
         g_pendingAutoTradingStop = false;
         g_pendingStopStartTime = 0;
         Print("All positions closed. AutoTrading disabled successfully.");
      }
      else if(TimeCurrent() - g_pendingStopStartTime > 60)
      {
         Print("WARNING: Timeout waiting for positions to close (60 seconds elapsed).");
         Print("WARNING: ", remainingPositions, " positions still remain open.");
         Print("WARNING: Disabling AutoTrading anyway. Please check positions manually!");
         DisableAutoTrading();
         g_pendingAutoTradingStop = false;
         g_pendingStopStartTime = 0;
      }
      else
      {
         // 待機中のステータス表示
         int elapsedTime = (int)(TimeCurrent() - g_pendingStopStartTime);
         Print("Waiting for ", remainingPositions, " positions to close... (", elapsedTime, "/60 seconds)");
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
   // 週末チェック
   if(IsWeekend())
   {
      Print("Weekend detected. Skipping daily reset.");
      g_currentDay = newDay;  // 日付だけ更新
      return;
   }

   double finalBalance = DPM_AccountBalance();
   Print("===========================================");
   Print("New trading day started");
   Print("Previous day final balance: ", DoubleToString(finalBalance, 2));

   // 新しい日の設定
   g_currentDay = newDay;
   g_dailyStartBalance = finalBalance;

   // フラグリセット（新しい日には自動的に再開）
   g_targetReached = false;
   g_eaStopped = false;
   g_pendingAutoTradingStop = false;
   g_pendingStopStartTime = 0;

   // 表示キャッシュリセット
   g_lastDisplayedBalance = 0;
   g_lastDisplayedProfit = 0;
   g_lastDisplayedProgress = 0;

   // 自動売買を再開
   EnableAutoTrading();

   Print("New day initialized. Start balance: ", DoubleToString(g_dailyStartBalance, 2));
   Print("Target amount: ", DoubleToString(DailyTargetAmount, 2));
   Print("EA automatically restarted and AutoTrading enabled");
   Print("===========================================");
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
//| 全ポジション決済（改良版：競合状態を解消）                        |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   int maxAttempts = MaxRetries;
   int attempt = 0;
   int totalClosed = 0;

   Print("Starting CloseAllPositions - Initial position count: ", DPM_OrdersTotal());

   while(attempt < maxAttempts)
   {
      int total = DPM_OrdersTotal();

      if(total == 0)
      {
         Print("All positions successfully closed. Total closed: ", totalClosed);
         return;
      }

      bool anySuccess = false;
      int closedThisRound = 0;

      // 逆順で処理（インデックスの変化に対応）
      for(int i = total - 1; i >= 0; i--)
      {
         // 最新のポジション情報を取得
         if(!DPM_OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         {
            Print("WARNING: Failed to select position at index ", i);
            continue;
         }

         // マジックナンバーフィルター
         if(MagicNumber != 0)
         {
#ifdef __MQL5__
            long posMagic = PositionGetInteger(POSITION_MAGIC);
#else
            int posMagic = OrderMagicNumber();
#endif
            if(posMagic != MagicNumber)
               continue;  // 指定されたマジックナンバー以外はスキップ
         }

         // ポジション情報を直前に取得（常に最新）
         int type = DPM_OrderType();
         if(type != OP_BUY && type != OP_SELL)
            continue;

#ifdef __MQL5__
         ulong ticket = DPM_OrderTicket();
#else
         int ticket = DPM_OrderTicket();
#endif
         string symbol = DPM_OrderSymbol();
         double lots = DPM_OrderLots();  // 最新のロット数

         // 最新の決済価格を取得
         double closePrice = (type == OP_BUY) ?
                            DPM_MarketInfo(symbol, MODE_BID) :
                            DPM_MarketInfo(symbol, MODE_ASK);

         // 価格が有効か確認
         if(closePrice <= 0)
         {
            Print("ERROR: Invalid close price for ", symbol, " (", closePrice, ")");
            continue;
         }

         // 決済実行
         bool success = DPM_OrderClose(ticket, lots, closePrice, 3);

         if(success)
         {
            anySuccess = true;
            closedThisRound++;
            totalClosed++;
            Print("Successfully closed order #", ticket, " (", symbol, " ",
                  (type == OP_BUY ? "BUY" : "SELL"), " ", lots, " lots)");
            Sleep(100);  // 次の決済まで短い遅延
         }
         else
         {
            int error = GetLastError();

            // リクオートエラーの場合は次のラウンドで再試行
            if(error == 138 || error == 135)  // Requote or Price changed
            {
               Print("Requote/Price change for #", ticket, " - will retry with fresh price");
            }
            else
            {
               Print("Failed to close order #", ticket,
                     " Symbol: ", symbol,
                     " Type: ", (type == OP_BUY ? "BUY" : "SELL"),
                     " Lots: ", lots,
                     " Price: ", closePrice,
                     " Error: ", error, " - ", ErrorDescription(error));
            }
         }
      }

      Print("Close round ", attempt + 1, " completed. Closed: ", closedThisRound,
            " Remaining: ", DPM_OrdersTotal());

      // 進捗があった場合はカウンターリセット
      if(anySuccess)
      {
         attempt = 0;  // 進捗があればリトライカウントをリセット
         Sleep(RetryDelay / 2);  // 次のラウンド前に短い待機
      }
      else if(DPM_OrdersTotal() > 0)
      {
         // 進捗がない場合のみカウント
         attempt++;
         if(attempt < maxAttempts)
         {
            Print("No progress in this round. Retry attempt ", attempt, " of ", maxAttempts);
            Sleep(RetryDelay);
         }
      }
   }

   // 最終確認
   int remaining = DPM_OrdersTotal();
   if(remaining > 0)
   {
      Print("WARNING: ", remaining, " positions could not be closed after all attempts");
      Print("WARNING: Total successfully closed: ", totalClosed);
      Alert("DailyProfitTarget: ", remaining, " positions failed to close! Please close manually.");
   }
   else
   {
      Print("All positions closed successfully. Total: ", totalClosed);
   }
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

   // 進捗率計算（ゼロ除算対策）
   double progressPercent = 0;
   if(MathAbs(DailyTargetAmount) > 0.01)  // ゼロチェック
   {
      progressPercent = (dailyProfit / DailyTargetAmount) * 100.0;
      progressPercent = MathMin(MathMax(progressPercent, -100.0), 100.0);
   }

   // 変化がない場合はスキップ（最適化）
   double balanceDiff = MathAbs(currentBalance - g_lastDisplayedBalance);
   double profitDiff = MathAbs(dailyProfit - g_lastDisplayedProfit);
   double progressDiff = MathAbs(progressPercent - g_lastDisplayedProgress);

   // 0.01の変化があるか、目標達成状態の変更がある場合のみ更新
   if(balanceDiff < 0.01 && profitDiff < 0.01 && progressDiff < 0.01)
   {
      return;  // 更新不要
   }

   // キャッシュ更新
   g_lastDisplayedBalance = currentBalance;
   g_lastDisplayedProfit = dailyProfit;
   g_lastDisplayedProgress = progressPercent;

   double remaining = DailyTargetAmount - dailyProfit;

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