//+------------------------------------------------------------------+
//|                                          DailyProfitTarget.mq5  |
//|                                  Copyright 2024, Daily Trading   |
//|                                       https://dailytrading.net   |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, Daily Trading"
#property version   "2.0"
#property description "日次利益目標管理EA - MQL5版"

// 共通ヘッダーファイルをインクルード
#include "DailyProfitTarget.mqh"

//+------------------------------------------------------------------+
//| Expert initialization function                                  |
//+------------------------------------------------------------------+
int OnInit()
{
   DPM_Init();
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   DPM_Deinit();
}

//+------------------------------------------------------------------+
//| Expert tick function                                            |
//+------------------------------------------------------------------+
void OnTick()
{
   DPM_OnTick();
}