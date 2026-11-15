//+------------------------------------------------------------------+
//| STRUXA_QM_AutoTrader_v3_23.mq5                                   |
//| Structural Quasimodo (QM) trader - symbol agnostic               |
//|                                                                  |
//| v3.23 changes vs v3.15                                           |
//|  1. QM is detected on ZoneTF (M15) from ATR-filtered zigzag      |
//|     pivots: Left shoulder (Ls) -> High (H2) -> Head (lower low)  |
//|     -> close above H2 (break of structure). Bearish = mirror.    |
//|  2. Entry is the QM level (Ls) + small offset, not the head.     |
//|     SL sits just beyond the head. TP = TargetRR x risk.          |
//|  3. Zones that were already retested are MISSED, never chased.   |
//|     No stop-order conversion of broken zones.                    |
//|  4. H1/H4 EMA bias is now used (off / soft / strict).            |
//|  5. One zone per pivot (key = direction + head time). The setup  |
//|     tag is fixed at registration, so no duplicate orders.        |
//|  6. Everything is in ATR / R / % terms: spread, SL, trail,       |
//|     risk, guards. No gold-specific points or money amounts.      |
//|  7. R-based trail: break-even, then lock + ATR trail from peak.  |
//|  8. Guards use % of real balance. Overall soft = half risk,      |
//|     daily soft = no new entries until next day.                  |
//|  9. Min-lot override capped (default 1.5x planned risk).         |
//| 10. Per-trade CSV log: score, R, MFE_R, MAE_R for calibration.   |
//| 11. Dual detection: main profile on M15 plus a fast profile on  |
//|     M5 with its own swing size, break, risk, RR and min score.   |
//|     Each trade is tagged M15_ or M5_ in the stats table.         |
//| 12. Fixed: v3.16 was missing the InpMaxZones input.              |
//| 13. v3.18: funnel counters (why setups are rejected or blocked)  |
//|     in the dashboard and final stats. Strategy logic unchanged.  |
//| 14. v3.19: optional confirmation entry (InpEntryMode). After     |
//|     price touches the QM level, wait for a rejection candle on   |
//|     the execution TF, then enter at market. Default = limit.     |
//| 15. v3.20: provisional head (no fractal wait), more sensitive      |
//|     swing scale, structure-based order life, wide-pattern entry   |
//|     (order block / minor BOS), chart marks + pattern CSV log.      |
//| 16. v3.21: pending orders obey session / bias / market-closed    |
//|     after they are placed (pulled and re-armed), open-risk budget  |
//|     per side, market-edge buffer, STUDY LOGGER: virtual outcome    |
//|     for every pattern (all filters off) + joinable trade CSV.      |
//| 17. v3.22: CRT module phase 1 (marks and logs, no trade change):  |
//|     nine CRT types on H4 plus a nested lower TF, H4 anchors,       |
//|     session CRT, daily high/low, premium/discount, context flags   |
//|     on every virtual trade for the study logger.                   |
//| 18. v3.23: CRT trading rules (phase 2): sweep-QM trigger, in-range  |
//|     QMs after the trigger, daily premium/discount, H4 trend and     |
//|     lower-TF CRT filters, TP chain (previous QM, order block past    |
//|     the liquidity, range extreme), and the handoff trail (lock 80%   |
//|     of the running QM, close it when the opposite QM fills).         |
//| 19. Removed: OBV flat penalty, tester-only ignore flags,         |
//|     point-based thresholds, score penalties that never mattered. |
//|                                                                  |
//| Attach one instance per chart/symbol. Execution TF = M5,         |
//| zone TF = M15 by default. Check InpBrokerGMTOffset and the       |
//| session window for each instrument class before live use.        |
//+------------------------------------------------------------------+
#property copyright   "STRUXA"
#property version     "3.23"
#property description "STRUXA QM AutoTrader v3.23 - structural QM, QML entry, HTF bias, R-based trail"

#include <Trade/Trade.mqh>

CTrade trade;

#define DIR_BUY        (1)
#define DIR_SELL       (-1)

#define SETUP_QM       0
#define SETUP_IQM      1
#define SETUP_QMC      2
#define SETUP_QMM      3
#define SETUP_QMR      4
#define SETUP_MEF      5
#define SETUP_FAKEOUT  6
#define SETUP_COUNT    7
#define PROF_COUNT     2
#define STAT_COUNT     (SETUP_COUNT * 2 * PROF_COUNT)

#define REJ_DISABLED   0
#define REJ_STALE      1   // break too old, not counted in "found"
#define REJ_RISK       2
#define REJ_GEOMETRY   3
#define REJ_RETESTED   4   // price already retested the entry after the break
#define REJ_BIAS       5
#define REJ_SCORE      6
#define REJ_DUP        7
#define REJ_CRT        8
#define REJ_COUNT      9

#define QMH_MAX        40

#define BLK_GUARD      0
#define BLK_MODE       1
#define BLK_SESSION    2
#define BLK_BIAS       3
#define BLK_MAXDIR     4
#define BLK_MAXTOTAL   5
#define BLK_SPREAD     6
#define BLK_VOLUME     7
#define BLK_MARGIN     8
#define BLK_ORDER      9
#define BLK_CLOSED     10
#define BLK_RISKBUDGET 11
#define BLK_COUNT      12

#define VT_MAX         300
#define VF_COUNT       8
#define VA_COUNT       7

#define CRT_MAX            60
#define CRT_CLASSIC        1
#define CRT_INSIDE         2
#define CRT_MULTI          3
#define CRT_TBS            4
#define CRT_BREAK_RETEST   5
#define CRT_ENGULF         6
#define CRT_SESSION        7
#define CRT_DOUBLE         9
#define CRT_TYPE_SLOTS     10

#define CS_FORMING         0
#define CS_SWEPT           1
#define CS_BROKEN          2

#define Z_ARMED        0
#define Z_TRIGGERED    1
#define Z_USED         2
#define Z_MISSED       3
#define Z_EXPIRED      4
#define Z_BLOCKED      5
#define Z_REJECTED     6
#define Z_STATE_COUNT  7

enum STRUXA_BIAS_MODE
{
   BIAS_OFF    = 0,   // Off
   BIAS_SOFT   = 1,   // Soft (score bonus / penalty)
   BIAS_STRICT = 2    // Strict (H1 must agree, H4 must not oppose)
};

enum STRUXA_ENTRY_MODE
{
   ENTRY_LIMIT   = 0,   // Limit order at the QM level (v3.17 behaviour)
   ENTRY_CONFIRM = 1    // Wait for a rejection candle at the level, then enter at market
};

enum STRUXA_EXPIRY_MODE
{
   EXPIRY_TIME      = 0,   // Pending order lives a fixed number of bars
   EXPIRY_STRUCTURE = 1    // Lives until filled, target reached first, or the max life ends
};

enum STRUXA_WIDE_MODE
{
   WIDE_OFF       = 0,   // Always enter at the QM level
   WIDE_OB        = 1,   // Wide patterns: enter at the order block near the head
   WIDE_MINOR_BOS = 2,   // Wide patterns: enter at the first minor BOS level after the head
   WIDE_AUTO      = 3    // Order block first, minor BOS if no valid order block
};

enum STRUXA_CRT_MODE
{
   CRT_OFF  = 0,   // CRT module off
   CRT_MARK = 1    // Mark ranges on the chart and log them (no trade change yet)
};

enum STRUXA_SWEEP_MODE
{
   SWEEPQM_OFF     = 0,   // No sweep-QM requirement
   SWEEPQM_REQUIRE = 1    // QM head must sweep the H4 range extreme and break back inside
};

enum STRUXA_INRANGE_MODE
{
   INRANGE_OFF = 0,   // Only sweep QMs trade
   INRANGE_ON  = 1    // QMs inside the swept range also trade
};

enum STRUXA_TREND_MODE
{
   TRENDMODE_ANY  = 0,   // H4 trend ignored
   TRENDMODE_WITH = 1    // QM must point with the H4 trend
};

enum STRUXA_LTF_MODE
{
   LTF_OFF     = 0,   // Lower-TF CRT not required
   LTF_REQUIRE = 1    // A matching lower-TF CRT must exist
};

enum STRUXA_DAILY_MODE
{
   DAILYF_OFF              = 0,   // Daily range only drawn
   DAILYF_PREMIUM_DISCOUNT = 1    // Buys only in discount, sells only in premium
};

enum STRUXA_TP_MODE
{
   TP_RR          = 0,   // Fixed reward-to-risk
   TP_PREV_QM     = 1,   // Entry level of the previous opposite QM
   TP_OB_PAST_IRL = 2,   // Order block past the internal range liquidity
   TP_OPP_EXTREME = 3,   // Opposite extreme of the range
   TP_AUTO        = 4    // Chain: previous QM, then order block, then range extreme
};

enum STRUXA_HANDOFF_MODE
{
   HANDOFF_OFF = 0,   // Off
   HANDOFF_ON  = 1    // Lock the running QM and close it when the opposite QM fills
};

//--- Core
input group "=== Core ==="
input string            InpEAName                 = "STRUXA_QM_AutoTrader_v3_23";
input ulong             InpMagicNumber            = 26062544;
input ENUM_TIMEFRAMES   InpExecutionTF            = PERIOD_M5;
input ENUM_TIMEFRAMES   InpZoneTF                 = PERIOD_M15;
input ENUM_TIMEFRAMES   InpBiasTF1                = PERIOD_H1;
input ENUM_TIMEFRAMES   InpBiasTF2                = PERIOD_H4;
input bool              InpEnableAutoTrading      = true;
input bool              InpUseFastProfile         = true;   // M5 DETECTION ON/OFF (false = M15 only)

input group "=== Setup families (tags set by head candle and divergence) ==="
input bool              InpUseQM                  = true;
input bool              InpUseIQM                 = true;
input bool              InpUseQMC                 = true;
input bool              InpUseQMM                 = true;
input bool              InpUseQMR                 = true;
input bool              InpUseMEF                 = true;
input bool              InpUseFakeout             = true;
input double            InpMEFRangeATR            = 1.95;   // head candle range / ATR for MEF tag
input double            InpFakeoutWickRatio       = 0.62;   // head candle wick / range for FAKEOUT tag

input group "=== QM structure: main profile (ZoneTF, M15) ==="
input int               InpSwingLR                = 2;      // fractal bars each side (Ls and H2)
input double            InpMinSwingATR            = 0.9;    // min leg between pivots, in ATR
input int               InpLookbackBars           = 200;    // ZoneTF bars scanned
input double            InpHeadUndercutATR        = 0.15;   // head must undercut Ls by this much
input double            InpBreakATR               = 0.15;   // close must clear H2 by this much
input int               InpMaxBarsAfterBreak      = 6;      // ZoneTF bars since break allowed
input int               InpMaxHeadToBreakBars     = 20;     // ZoneTF bars between head and break
input bool              InpRequirePriorTrend      = true;   // lower high before Ls (bullish)

input group "=== QM structure: fast profile (M5) ==="
input ENUM_TIMEFRAMES   InpFastTF                 = PERIOD_M5;
input int               InpFastSwingLR            = 2;      // fractal bars each side (Ls and H2)
input double            InpFastMinSwingATR        = 1.0;    // min leg between pivots, in M5 ATR
input int               InpFastLookbackBars       = 300;
input double            InpFastHeadUndercutATR    = 0.15;
input double            InpFastBreakATR           = 0.15;
input int               InpFastMaxBarsAfterBreak  = 12;     // M5 bars since break allowed
input int               InpFastMaxHeadToBreakBars = 40;
input int               InpFastOrderExpiryBars    = 36;     // M5 bars (3 hours)
input double            InpFastMinRiskATR         = 1.3;
input double            InpFastMaxRiskATR         = 3.0;
input double            InpFastTargetRR           = 2.5;
input int               InpFastMinTradeScore      = 70;     // stricter than main profile

input group "=== Entry / SL / TP ==="
input double            InpEntryOffsetATR         = 0.10;   // entry = Ls +/- offset * ATR
input double            InpSLBufferATR            = 0.30;   // SL = head -/+ buffer * ATR
input double            InpMinRiskATR             = 0.80;   // SL distance floor
input double            InpMaxRiskATR             = 2.50;   // SL distance cap, wider = skipped
input double            InpTargetRR               = 3.0;
input int               InpOrderExpiryZoneBars    = 16;     // pending order lifetime in EXPIRY_TIME mode, ZoneTF bars
input double            InpDupDistATR             = 0.50;   // no second zone this close, same side

input group "=== Detection and order life (v3.20) ==="
input bool              InpProvisionalHead        = true;   // head = lowest low after H2, no fractal confirmation wait
input STRUXA_EXPIRY_MODE InpExpiryMode            = EXPIRY_STRUCTURE;
input int               InpMaxLifeBars            = 96;     // main profile max life, ZoneTF bars (M15: 24 h)
input int               InpFastMaxLifeBars        = 288;    // fast profile max life, bars (M5: 24 h)

input group "=== Wide pattern entry (v3.20) ==="
input STRUXA_WIDE_MODE  InpWideEntryMode          = WIDE_AUTO;
input double            InpWideTriggerATR         = 2.0;    // use it when SL at the QM level is wider than this
input double            InpOBEntryDepth           = 0.5;    // 0 = order block edge, 0.5 = mean threshold
input bool              InpWideKeepTP             = true;   // keep the target from the QM-level geometry
input double            InpWideMaxRR              = 6.0;    // cap on the reward-to-risk this produces

input group "=== Chart marks and pattern log (v3.20) ==="
input bool              InpMarkPatterns           = true;   // draw every detected pattern and its outcome
input int               InpMaxMarks               = 120;    // patterns kept on the chart (max 200)
input bool              InpLogPatternsCSV         = true;   // geometry of every pattern, incl. rejected
input bool              InpKeepMarksOnExit        = true;   // leave marks on the chart when the test or EA stops

input group "=== Order hygiene and risk budget (v3.21) ==="
input bool              InpCancelPendingOffSession = true;  // pull pendings when session / bias / market gate closes, re-arm later
input double            InpMaxOpenRiskPct         = 0.75;   // open + pending risk per side, % of balance (0 = off)
input int               InpMarketEdgeBufferMin    = 10;     // no entries this close to a market session open or close

input group "=== Study logger (v3.21) ==="
input bool              InpStudyMode              = true;   // virtual outcome of every pattern, writes the virtual CSV
input int               InpStudyWaitHours         = 24;     // how long a virtual trade waits for the level
input int               InpStudyHorizonHours      = 24;     // how long it is followed after the level is touched

input group "=== CRT module, phase 1: mark and log only (v3.22) ==="
input STRUXA_CRT_MODE   InpCrtMode                = CRT_MARK;
input ENUM_TIMEFRAMES   InpCrtTF1                 = PERIOD_H4;   // main CRT / anchor timeframe
input bool              InpCrtUseTF2              = true;        // also read a lower-timeframe CRT
input ENUM_TIMEFRAMES   InpCrtTF2                 = PERIOD_M15;
input bool              InpCrtLtfNestedOnly       = true;        // lower-TF CRT only counts inside a main-TF range
input bool              InpDailyMark              = true;        // previous day high / low / 50% and premium-discount flag
input bool              InpCrtClassic             = true;        // 1: range candle, sweep candle closes back inside
input bool              InpCrtInside              = true;        // 2: same, with inside bars between them
input bool              InpCrtMulti               = true;        // 3: sweep repeated by several candles
input bool              InpCrtTBS                 = true;        // 4: turtle body soup (body closes beyond, next closes back)
input bool              InpCrtBreakRetest         = true;        // 5: close beyond the range, then a held retest
input bool              InpCrtEngulf              = true;        // 6: displacement candle engulfs and closes beyond
input bool              InpCrtSession             = true;        // 7: session range (Asia by default) swept and rejected
input bool              InpCrtDouble              = true;        // 9: second, deeper sweep of the same side
input int               InpCrtMaxInside           = 8;           // inside bars allowed between range candle and sweep
input int               InpAnchorMinInside        = 2;           // inside bars that make a range candle an anchor
input int               InpCrtTrackBars           = 12;          // candles followed after a CRT forms
input double            InpCrtMinRangeATR         = 0.5;         // range candle must be at least this big
input double            InpCrtMinSweepATR         = 0.05;        // a sweep must exceed the range by this much
input double            InpCrtEngulfBodyATR       = 1.0;         // body size for the engulf type
input int               InpCrtBreakWait           = 3;           // candles waited for a retest after a break
input int               InpCrtBackfillDays        = 10;          // history replayed at start so old CRTs are marked
input int               InpSessionCrtStartGMT     = 0;           // session range start, GMT hour
input int               InpSessionCrtEndGMT       = 7;           // session range end, GMT hour
input bool              InpCrtDraw                = true;
input int               InpMaxCrtMarks            = 80;
input bool              InpCrtLog                 = true;        // CRT outcomes CSV

input group "=== CRT trading rules, phase 2 (v3.23) ==="
input STRUXA_SWEEP_MODE InpSweepQmMode            = SWEEPQM_OFF;
input STRUXA_INRANGE_MODE InpInRangeQmMode        = INRANGE_OFF;
input bool              InpInRangeNeedsTrigger    = true;        // in-range QMs wait for a sweep QM on the same range
input bool              InpInRangeAnyDirection    = false;       // allow in-range QMs against the CRT direction
input STRUXA_TREND_MODE InpH4TrendMode            = TRENDMODE_ANY;
input STRUXA_LTF_MODE   InpLtfMode                = LTF_OFF;
input STRUXA_DAILY_MODE InpDailyFilterMode        = DAILYF_OFF;
input STRUXA_TP_MODE    InpTpMode                 = TP_RR;
input double            InpTpMinRR                = 2.0;         // a chain target closer than this is skipped
input STRUXA_HANDOFF_MODE InpHandoffMode          = HANDOFF_OFF;
input double            InpHandoffLockPct         = 80.0;        // % of the peak profit kept while an opposite QM waits
input double            InpHandoffMinProfitR      = 0.5;         // profit needed before the lock and the handoff apply

input group "=== Entry mode ==="
input STRUXA_ENTRY_MODE InpEntryMode              = ENTRY_LIMIT;
input double            InpConfirmMinWickRatio    = 0.30;   // confirm candle: rejection wick / range
input bool              InpConfirmRequireDirClose = true;   // buy: close > open and > level (sell: mirror)
input double            InpConfirmMaxBreakATR     = 0.25;   // a close this far through the level kills the zone
input int               InpConfirmWaitBars        = 6;      // failed touches (exec bars) before the zone expires
input double            InpConfirmMaxChaseATR     = 0.50;   // skip if market is further than this from the level

input group "=== Bias ==="
input STRUXA_BIAS_MODE  InpBiasMode               = BIAS_STRICT;
input int               InpBiasEMAPeriod          = 50;
input int               InpBiasAlignedPoints      = 15;
input int               InpBiasOpposedPenalty     = 20;

input group "=== Score ==="
input int               InpMinTradeScore          = 66;     // plain aligned QM = 65, needs one extra confluence
input bool              InpUseRSIDivergence       = true;
input bool              InpUseMACDDivergence      = true;
input int               InpRSIPeriod              = 14;
input int               InpMACDFast               = 12;
input int               InpMACDSlow               = 26;
input int               InpMACDSignal             = 9;
input int               InpATRPeriod              = 14;

input group "=== Risk and limits ==="
input double            InpRiskPercent            = 0.25;   // % of balance per trade
input double            InpFixedLot               = 0.0;    // > 0 overrides risk sizing
input double            InpMaxLot                 = 0.0;    // 0 = no extra cap
input double            InpMinLotMaxRiskMult      = 1.5;    // min lot allowed if risk <= planned x this
input double            InpMaxMarginUsePct        = 50.0;   // order margin vs free margin
input double            InpMaxSpreadPctOfRisk     = 12.0;   // spread must be <= this % of SL distance
input int               InpMaxZones               = 30;     // live zones tracked across both profiles
input int               InpMaxPerDirection        = 3;      // positions + pendings per side (long-lived orders need room)
input int               InpMaxTotalOpen           = 5;

input group "=== Trade management (R multiples of initial risk) ==="
input bool              InpUseTrail               = true;
input double            InpBreakEvenR             = 1.0;    // move SL to BE + lock at this profit
input double            InpBreakEvenLockR         = 0.05;
input double            InpTrailStartR            = 1.5;    // start ATR trail
input double            InpTrailLockR             = 0.25;   // minimum locked profit once trailing
input double            InpTrailATRMult           = 2.0;    // trail distance from peak, ZoneTF ATR
input double            InpTrailStepR             = 0.10;   // min SL improvement per modify

input group "=== Session ==="
input bool              InpUseSessionFilter       = true;
input int               InpBrokerGMTOffset        = 0;      // broker server time minus GMT (hours)
input int               InpSessionStartGMT        = 7;
input int               InpSessionEndGMT          = 20;
input int               InpFridayStopHourGMT      = 18;     // 0 = off

input group "=== Account guards (% of real balance) ==="
input bool              InpUsePropFirmGuards      = true;
input double            InpPropAccountSize        = 0.0;    // 0 = balance at attach
input double            InpDailySoftPct           = 2.5;    // no new entries until next day
input double            InpDailyHardPct           = 3.5;    // lock, cancel pendings, close all
input double            InpOverallSoftPct         = 6.0;    // risk scaled down
input double            InpOverallHardPct         = 8.0;    // permanent lock until re-attach
input double            InpSoftRiskScale          = 0.5;
input bool              InpCancelPendingOnLock    = true;
input bool              InpCloseOnHardDD          = true;

input group "=== Output ==="
input bool              InpPrintDebug             = true;
input bool              InpShowDashboard          = true;
input bool              InpDrawObjects            = true;
input bool              InpLogTradesCSV           = true;

//+------------------------------------------------------------------+
//| Types and globals                                                |
//+------------------------------------------------------------------+
struct Zone
{
   ulong     id;
   string    key;
   int       direction;
   int       setupType;
   int       prof;
   int       state;
   int       score;
   datetime  headTime;
   datetime  createdTime;
   datetime  expiryTime;
   datetime  retryAfter;
   double    entry;
   double    sl;
   double    tp;
   double    rr;
   double    atr;
   int       blocks;
   string    lastBlock;
   int       lastBlockCat;
   bool      confirmed;
   int       touchBars;
   ulong     orderTicket;
   bool      alt;
   string    altKind;
   datetime  crtC1;
   bool      trigger;
   string    tpHow;
};

struct Pivot
{
   int       shift;
   double    price;
   int       type;      // 1 = high, -1 = low
};

struct ScanProfile
{
   string          name;
   ENUM_TIMEFRAMES tf;
   int             lr;
   double          minSwingATR;
   int             lookback;
   double          undercutATR;
   double          breakATR;
   int             maxBarsAfterBreak;
   int             maxHeadToBreak;
   int             expiryBars;
   int             maxLifeBars;
   double          minRiskATR;
   double          maxRiskATR;
   double          targetRR;
   int             minScore;
   int             hAtr;
   int             hRsi;
   int             hMacd;
};

struct CrtCtx
{
   int       h4Active;
   int       h4Type;
   int       h4Dir;
   int       h4Match;
   int       h4Swept;
   double    h4Pos;
   int       h4Trend;
   int       ltfActive;
   int       ltfType;
   int       ltfDir;
   int       ltfMatch;
   int       ltfSwept;
   int       pdZone;
   int       d1Bias;
   int       d1Crt;
   int       nested;
   int       h4Idx;
   double    h4Hi;
   double    h4Lo;
   datetime  h4C1;
   int       h4Triggered;
};

struct PatInfo
{
   string    key;
   int       p;
   int       dir;
   int       setup;
   datetime  tLs;
   double    pLs;
   datetime  tH2;
   double    pH2;
   datetime  tHead;
   double    pHead;
   datetime  tBos;
   double    pBos;
   int       barsLsH2;
   int       barsH2Head;
   int       barsHeadBos;
   int       bosAge;
   double    wickR;
   double    rangeATR;
   int       rsiDiv;
   int       macdDiv;
   int       bias1;
   int       bias2;
   int       hour;
   CrtCtx    ctx;
   double    legLsH2ATR;
   double    legH2HeadATR;
   double    undercutATR;
   double    riskQmlATR;
   int       score;
   double    entry;
   double    sl;
   double    tp;
   string    alt;
};

struct VTrade
{
   PatInfo   pat;
   string    kind;
   string    decision;
   double    entry;
   double    sl;
   double    R;
   double    atr;
   datetime  created;
   datetime  expiry;
   datetime  lastBar;
   int       state;
   datetime  touchTime;
   int       barsSince;
   double    mfe;
   double    mae;
   int       tF[VF_COUNT];
   int       tA[VA_COUNT];
};

struct CrtRange
{
   int       tf;
   datetime  c1;
   datetime  lastT;
   double    hi;
   double    lo;
   double    atr;
   int       state;
   int       nInside;
   int       side;
   int       nSweep;
   double    sweepExt;
   datetime  formTime;
   int       type;
   int       dir;
   int       trend;
   bool      reachedMid;
   bool      reachedTarget;
   int       midBars;
   int       tgtBars;
   int       age;
   int       formAge;
   int       breakSide;
   int       breakBars;
   bool      nested;
   bool      anchor;
   bool      isSession;
   int       maxInside;
   bool      deeper;
   bool      drawn;
   bool      triggered;
   int       trigDir;
};

struct QmHist
{
   ulong     zid;
   int       dir;
   double    entry;
   datetime  t;
   datetime  c1;
   int       status;
};

struct SetupStat
{
   string    tag;
   int       setupType;
   int       direction;
   long      found;
   long      rejected;
   long      missed;
   long      registered;
   long      sent;
   long      executed;
   long      closed;
   long      wins;
   long      losses;
   double    grossProfit;
   double    grossLoss;
   double    net;
   double    sumR;
};

struct PosTrack
{
   ulong     posId;
   ulong     zid;
   string    key;
   string    kind;
   int       ageMin;
   int       hour;
   int       stat;
   int       score;
   int       dir;
   double    entry;
   double    risk;
   double    lots;
   double    tickMoneyPerPrice;   // money per 1.0 price move per lot
   double    atrRef;              // zone ATR at registration, used for the trail
   double    best;
   double    worst;
   datetime  openTime;
};

Zone       g_zones[];
int        g_zoneCount = 0;
ulong      g_nextZoneId = 1;
long       g_stateCount[Z_STATE_COUNT];

SetupStat  g_stats[STAT_COUNT];
ScanProfile g_prof[PROF_COUNT];
int        g_profCount = 0;
long       g_rej[PROF_COUNT][REJ_COUNT];
long       g_altCount[PROF_COUNT];
string     g_markKeys[200];
int        g_markCount = 0;
VTrade     g_vt[];
int        g_vtCount = 0;
long       g_vtSkipped = 0;
long       g_pulled = 0;

CrtRange   g_crt[];
int        g_crtCount = 0;
bool       g_crtOn = false;
int        g_crtAtr[2] = {INVALID_HANDLE, INVALID_HANDLE};
int        g_crtEma[2] = {INVALID_HANDLE, INVALID_HANDLE};
datetime   g_crtLastBar[2];
datetime   g_crtProcessed[2];
long       g_crtTypeCount[CRT_TYPE_SLOTS];
string     g_crtMarkNames[200];
int        g_crtMarkCount = 0;
bool       g_sessIn = false;
datetime   g_sessStart = 0;
double     g_sessHi = 0.0;
double     g_sessLo = 0.0;
datetime   g_dayShown = 0;
double     g_pdh = 0.0;
double     g_pdl = 0.0;
int        g_d1bias = 0;
int        g_d1crt = 0;
datetime   g_crtEventBar = 0;
QmHist     g_qmh[QMH_MAX];
int        g_qmhCount = 0;
long       g_trigQm = 0;
long       g_inRangeQm = 0;
long       g_handoffs = 0;
bool       g_hoPending = false;
int        g_hoDir = 0;
ulong      g_hoPid = 0;

const double VF_LEVELS[VF_COUNT] = {0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0};
const double VA_LEVELS[VA_COUNT] = {0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0};
long       g_blk[PROF_COUNT][BLK_COUNT];
long       g_endBlk[Z_STATE_COUNT][BLK_COUNT + 1];
PosTrack   g_trk[];
int        g_trkCount = 0;

string     g_seen[300];
int        g_seenCount = 0;

int        g_rsi  = INVALID_HANDLE;
int        g_macd = INVALID_HANDLE;
int        g_atr  = INVALID_HANDLE;
int        g_ema1 = INVALID_HANDLE;
int        g_ema2 = INVALID_HANDLE;
int        g_rsiF  = INVALID_HANDLE;
int        g_macdF = INVALID_HANDLE;
int        g_atrF  = INVALID_HANDLE;

datetime   g_lastExecBar = 0;
datetime   g_lastProfBar[PROF_COUNT];

int        g_dayKey = -1;
double     g_dayStartBal = 0.0;
double     g_initBal = 0.0;
bool       g_dailySoft = false;
bool       g_dailyHard = false;
bool       g_overallSoft = false;
bool       g_overallHard = false;
string     g_guardReason = "";
string     g_lastSkip = "";

string     g_prefix = "STX323_";

//+------------------------------------------------------------------+
//| Small helpers                                                    |
//+------------------------------------------------------------------+
void DebugPrint(const string label, const string msg)
{
   if(InpPrintDebug)
      Print("[", InpEAName, "] ", label, " ", msg);
}

string DirChar(const int dir)
{
   return (dir == DIR_BUY ? "B" : "S");
}

string DirName(const int dir)
{
   return (dir == DIR_BUY ? "BUY" : "SELL");
}

string SetupName(const int s)
{
   switch(s)
   {
      case SETUP_QM:      return "QM";
      case SETUP_IQM:     return "IQM";
      case SETUP_QMC:     return "QMC";
      case SETUP_QMM:     return "QMM";
      case SETUP_QMR:     return "QMR";
      case SETUP_MEF:     return "MEF";
      case SETUP_FAKEOUT: return "FAKEOUT";
   }
   return "QM";
}

int SetupFromName(const string name)
{
   for(int i = 0; i < SETUP_COUNT; i++)
      if(SetupName(i) == name)
         return i;
   return -1;
}

bool FamilyEnabled(const int s)
{
   switch(s)
   {
      case SETUP_QM:      return InpUseQM;
      case SETUP_IQM:     return InpUseIQM;
      case SETUP_QMC:     return InpUseQMC;
      case SETUP_QMM:     return InpUseQMM;
      case SETUP_QMR:     return InpUseQMR;
      case SETUP_MEF:     return InpUseMEF;
      case SETUP_FAKEOUT: return InpUseFakeout;
   }
   return false;
}

int StatsIndex(const int setupType, const int dir, const int prof)
{
   int p = MathMax(0, MathMin(PROF_COUNT - 1, prof));
   return (p * SETUP_COUNT + setupType) * 2 + (dir == DIR_BUY ? 0 : 1);
}

string TFName(const ENUM_TIMEFRAMES tf)
{
   string s = EnumToString(tf);
   StringReplace(s, "PERIOD_", "");
   return s;
}

double Pt()
{
   double p = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   return (p > 0.0 ? p : _Point);
}

double NormPrice(const double v)
{
   int d = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return NormalizeDouble(v, d);
}

double RoundTick(double v)
{
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts > 0.0)
      v = MathRound(v / ts) * ts;
   return NormPrice(v);
}

int VolumeDigits(const double step)
{
   if(step <= 0.0)
      return 2;
   int digits = 0;
   double s = step;
   while(digits < 8 && MathAbs(s - MathRound(s)) > 0.00000001)
   {
      s *= 10.0;
      digits++;
   }
   return digits;
}

double NormVolume(double volume)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      step = 0.01;
   volume = MathFloor(volume / step + 0.0000001) * step;
   volume = MathMax(minLot, MathMin(maxLot, volume));
   return NormalizeDouble(volume, VolumeDigits(step));
}

bool GetBuf(const int handle, const int buffer, const int shift, double &value)
{
   value = 0.0;
   if(handle == INVALID_HANDLE)
      return false;
   double d[];
   ArraySetAsSeries(d, true);
   if(CopyBuffer(handle, buffer, shift, 1, d) < 1)
      return false;
   value = d[0];
   return true;
}

double ATRNow()
{
   double v = 0.0;
   if(GetBuf(g_atr, 0, 1, v) && v > 0.0)
      return v;
   return 0.0;
}

int DeviationPts()
{
   double a = ATRNow();
   double p = Pt();
   if(a <= 0.0 || p <= 0.0)
      return 50;
   return MathMax(10, (int)(0.05 * a / p));
}

double BrokerMinDist()
{
   int stops  = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int freeze = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double d = MathMax(stops, freeze) * Pt();
   double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
   return d + MathMax(spread, Pt() * 2.0);
}

bool NewBar(const ENUM_TIMEFRAMES tf, datetime &last)
{
   datetime t = iTime(_Symbol, tf, 0);
   if(t <= 0)
      return false;
   if(t != last)
   {
      last = t;
      return true;
   }
   return false;
}

int DateKey(const datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return dt.year * 10000 + dt.mon * 100 + dt.day;
}

bool SessionAllowed()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(dt.day_of_week == 0 || dt.day_of_week == 6)
      return false;

   int h = (dt.hour - InpBrokerGMTOffset + 48) % 24;

   if(InpFridayStopHourGMT > 0 && dt.day_of_week == 5 && h >= InpFridayStopHourGMT)
      return false;

   if(!InpUseSessionFilter)
      return true;

   if(InpSessionStartGMT <= InpSessionEndGMT)
      return (h >= InpSessionStartGMT && h < InpSessionEndGMT);

   return (h >= InpSessionStartGMT || h < InpSessionEndGMT);
}

bool TradeModeAllows(const int dir, string &reason)
{
   reason = "";
   long mode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);

   if(mode == SYMBOL_TRADE_MODE_DISABLED)
   {
      reason = "symbol trade disabled";
      return false;
   }
   if(mode == SYMBOL_TRADE_MODE_CLOSEONLY)
   {
      reason = "symbol close-only";
      return false;
   }
   if(mode == SYMBOL_TRADE_MODE_LONGONLY && dir == DIR_SELL)
   {
      reason = "symbol long-only";
      return false;
   }
   if(mode == SYMBOL_TRADE_MODE_SHORTONLY && dir == DIR_BUY)
   {
      reason = "symbol short-only";
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Seen-key ring (stops the same pivot being evaluated every scan)  |
//+------------------------------------------------------------------+
bool KeySeen(const string key)
{
   int n = MathMin(g_seenCount, 300);
   for(int i = 0; i < n; i++)
      if(g_seen[i] == key)
         return true;
   return false;
}

void AddSeenKey(const string key)
{
   g_seen[g_seenCount % 300] = key;
   g_seenCount++;
}

//+------------------------------------------------------------------+
//| Stats                                                            |
//+------------------------------------------------------------------+
void InitStats()
{
   for(int p = 0; p < PROF_COUNT; p++)
   {
      string pname = (p == 0 ? TFName(InpZoneTF) : TFName(InpFastTF));
      for(int s = 0; s < SETUP_COUNT; s++)
      {
         for(int d = 0; d < 2; d++)
         {
            int dir = (d == 0 ? DIR_BUY : DIR_SELL);
            int i = StatsIndex(s, dir, p);
            g_stats[i].tag         = pname + "_" + DirName(dir) + "_" + SetupName(s);
            g_stats[i].setupType   = s;
            g_stats[i].direction   = dir;
            g_stats[i].found       = 0;
            g_stats[i].rejected    = 0;
            g_stats[i].missed      = 0;
            g_stats[i].registered  = 0;
            g_stats[i].sent        = 0;
            g_stats[i].executed    = 0;
            g_stats[i].closed      = 0;
            g_stats[i].wins        = 0;
            g_stats[i].losses      = 0;
            g_stats[i].grossProfit = 0.0;
            g_stats[i].grossLoss   = 0.0;
            g_stats[i].net         = 0.0;
            g_stats[i].sumR        = 0.0;
         }
      }
   }
   for(int k = 0; k < Z_STATE_COUNT; k++)
   {
      g_stateCount[k] = 0;
      for(int b = 0; b <= BLK_COUNT; b++)
         g_endBlk[k][b] = 0;
   }
   for(int q = 0; q < PROF_COUNT; q++)
   {
      for(int a = 0; a < REJ_COUNT; a++)
         g_rej[q][a] = 0;
      for(int c = 0; c < BLK_COUNT; c++)
         g_blk[q][c] = 0;
      g_altCount[q] = 0;
   }
}

double StatPF(const SetupStat &s)
{
   if(s.grossLoss <= 0.0)
      return (s.grossProfit > 0.0 ? 99.0 : 0.0);
   return s.grossProfit / s.grossLoss;
}

string StatLine(const SetupStat &s)
{
   double wr = (s.closed > 0 ? 100.0 * (double)s.wins / (double)s.closed : 0.0);
   double avgR = (s.closed > 0 ? s.sumR / (double)s.closed : 0.0);
   return StringFormat("%-16s found %d rej %d miss %d reg %d exec %d closed %d W %d L %d win %.1f%% net %.2f PF %.2f avgR %.2f",
                       s.tag, (int)s.found, (int)s.rejected, (int)s.missed, (int)s.registered,
                       (int)s.executed, (int)s.closed, (int)s.wins, (int)s.losses,
                       wr, s.net, StatPF(s), avgR);
}

//+------------------------------------------------------------------+
//| Zone registry                                                    |
//+------------------------------------------------------------------+
int ZoneIndexById(const ulong id)
{
   for(int i = 0; i < g_zoneCount; i++)
      if(g_zones[i].id == id)
         return i;
   return -1;
}

void DeleteZoneObjects(const ulong id)
{
   string nm = g_prefix + IntegerToString((long)id);
   if(ObjectFind(0, nm) >= 0)
      ObjectDelete(0, nm);
}

void RemoveZone(const int index, const int state, const string reason)
{
   if(index < 0 || index >= g_zoneCount)
      return;

   if(state >= 0 && state < Z_STATE_COUNT)
   {
      g_stateCount[state]++;
      int bc = g_zones[index].lastBlockCat;
      if(bc < 0 || bc >= BLK_COUNT)
         bc = BLK_COUNT;
      g_endBlk[state][bc]++;
   }

   if(state == Z_MISSED)
      g_stats[StatsIndex(g_zones[index].setupType, g_zones[index].direction, g_zones[index].prof)].missed++;

   DebugPrint("ZONE_END",
              StringFormat("%s_%s id=%I64u state=%d %s",
                           DirName(g_zones[index].direction),
                           SetupName(g_zones[index].setupType),
                           g_zones[index].id, state, reason));

   if(state != Z_USED)
      MarkStatus(g_zones[index].key, StringFormat("%s: %s", EndStateText(state), reason));

   QmHistSetStatus(g_zones[index].id, 2);
   DeleteZoneObjects(g_zones[index].id);

   for(int i = index; i < g_zoneCount - 1; i++)
      g_zones[i] = g_zones[i + 1];
   g_zoneCount--;
}

bool ZoneNear(const int dir, const double price, const double maxDist)
{
   for(int i = 0; i < g_zoneCount; i++)
   {
      if(g_zones[i].direction != dir)
         continue;
      if(MathAbs(g_zones[i].entry - price) <= maxDist)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Orders / positions lookups                                       |
//+------------------------------------------------------------------+
int CountLive(const int dir)
{
   int count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      long type = PositionGetInteger(POSITION_TYPE);
      if(dir == 0 ||
         (dir == DIR_BUY && type == POSITION_TYPE_BUY) ||
         (dir == DIR_SELL && type == POSITION_TYPE_SELL))
         count++;
   }

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket))
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)
         continue;

      long type = OrderGetInteger(ORDER_TYPE);
      bool isBuy  = (type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_BUY_STOP_LIMIT);
      bool isSell = (type == ORDER_TYPE_SELL_LIMIT || type == ORDER_TYPE_SELL_STOP || type == ORDER_TYPE_SELL_STOP_LIMIT);

      if(dir == 0 ||
         (dir == DIR_BUY && isBuy) ||
         (dir == DIR_SELL && isSell))
         count++;
   }

   return count;
}

bool PositionByZone(const ulong id)
{
   string marker = StringFormat("|%I64u|", id);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      if(StringFind(PositionGetString(POSITION_COMMENT), marker) >= 0)
         return true;
   }
   return false;
}

bool HistoryHasZoneEntry(const ulong id, const datetime fromTime)
{
   if(!HistorySelect(fromTime - 86400, TimeCurrent() + 60))
      return false;

   string marker = StringFormat("|%I64u|", id);
   int total = HistoryDealsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0)
         continue;
      if(HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol)
         continue;
      if((ulong)HistoryDealGetInteger(d, DEAL_MAGIC) != InpMagicNumber)
         continue;
      if(HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_IN)
         continue;
      if(StringFind(HistoryDealGetString(d, DEAL_COMMENT), marker) >= 0)
         return true;
   }
   return false;
}

void CancelAllPending()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket))
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)
         continue;
      trade.OrderDelete(ticket);
   }
}

void CloseAllPositions()
{
   trade.SetDeviationInPoints(DeviationPts());
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      trade.PositionClose(ticket);
   }
}

//+------------------------------------------------------------------+
//| Account guards                                                   |
//+------------------------------------------------------------------+
void ResetDailyIfNeeded()
{
   int key = DateKey(TimeCurrent());
   if(g_dayKey == -1)
   {
      g_dayKey = key;
      g_dayStartBal = AccountInfoDouble(ACCOUNT_BALANCE);
      return;
   }
   if(key != g_dayKey)
   {
      g_dayKey = key;
      g_dayStartBal = AccountInfoDouble(ACCOUNT_BALANCE);
      g_dailySoft = false;
      g_dailyHard = false;
      DebugPrint("DAILY_RESET", StringFormat("start balance %.2f", g_dayStartBal));
   }
}

void EvaluateGuards()
{
   ResetDailyIfNeeded();

   if(!InpUsePropFirmGuards)
   {
      g_dailySoft = false;
      g_dailyHard = false;
      g_overallSoft = false;
      g_overallHard = false;
      return;
   }

   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double ref = (InpPropAccountSize > 0.0 ? InpPropAccountSize : g_initBal);

   double dPct = (g_dayStartBal > 0.0 ? (g_dayStartBal - eq) / g_dayStartBal * 100.0 : 0.0);
   double oPct = (ref > 0.0 ? (ref - eq) / ref * 100.0 : 0.0);

   g_overallSoft = (oPct >= InpOverallSoftPct);

   bool newHard = false;
   bool newSoft = false;

   if(dPct >= InpDailyHardPct && !g_dailyHard)
   {
      g_dailyHard = true;
      newHard = true;
      g_guardReason = StringFormat("daily hard dd %.2f%%", dPct);
   }
   if(oPct >= InpOverallHardPct && !g_overallHard)
   {
      g_overallHard = true;
      newHard = true;
      g_guardReason = StringFormat("overall hard dd %.2f%%", oPct);
   }
   if(dPct >= InpDailySoftPct && !g_dailySoft)
   {
      g_dailySoft = true;
      newSoft = true;
      if(!newHard)
         g_guardReason = StringFormat("daily soft dd %.2f%%", dPct);
   }

   if(newHard || newSoft)
   {
      DebugPrint("GUARD", g_guardReason);
      if(InpCancelPendingOnLock)
         CancelAllPending();
   }
   if(newHard && InpCloseOnHardDD)
      CloseAllPositions();
}

bool EntriesBlocked(string &why)
{
   why = "";
   if(!InpUsePropFirmGuards)
      return false;
   if(g_overallHard || g_dailyHard || g_dailySoft)
   {
      why = g_guardReason;
      return true;
   }
   return false;
}

double RiskScale()
{
   if(InpUsePropFirmGuards && g_overallSoft)
      return MathMax(0.05, InpSoftRiskScale);
   return 1.0;
}

//+------------------------------------------------------------------+
//| Position sizing                                                  |
//+------------------------------------------------------------------+
double CalcLot(const double entry, const double sl, string &reason)
{
   reason = "";

   if(InpFixedLot > 0.0)
      return NormVolume(InpFixedLot);

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(InpPropAccountSize > 0.0)
      bal = MathMin(bal, InpPropAccountSize);

   double riskMoney = bal * InpRiskPercent / 100.0 * RiskScale();

   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tv <= 0.0)
      tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(minLot <= 0.0)
      minLot = 0.01;
   if(maxLot <= 0.0)
      maxLot = minLot;

   double dist = MathAbs(entry - sl);
   if(riskMoney <= 0.0 || tv <= 0.0 || ts <= 0.0 || dist <= 0.0)
   {
      reason = "bad lot inputs";
      return 0.0;
   }

   double riskPerLot = dist / ts * tv;
   if(riskPerLot <= 0.0)
   {
      reason = "riskPerLot invalid";
      return 0.0;
   }

   double raw = riskMoney / riskPerLot;

   if(raw < minLot)
   {
      double minRisk = minLot * riskPerLot;
      if(minRisk <= riskMoney * MathMax(1.0, InpMinLotMaxRiskMult))
         return NormVolume(minLot);

      reason = StringFormat("min lot risk %.2f > planned %.2f", minRisk, riskMoney);
      return 0.0;
   }

   double lot = NormVolume(raw);
   if(InpMaxLot > 0.0)
      lot = NormVolume(MathMin(lot, InpMaxLot));
   if(lot > maxLot)
      lot = maxLot;
   return lot;
}

//+------------------------------------------------------------------+
//| Structure detection                                              |
//+------------------------------------------------------------------+
bool IsFractal(const MqlRates &r[], const int i, const int lr, const bool isHigh)
{
   for(int k = 1; k <= lr; k++)
   {
      if(isHigh)
      {
         if(r[i - k].high >= r[i].high)
            return false;
         if(r[i + k].high > r[i].high)
            return false;
      }
      else
      {
         if(r[i - k].low <= r[i].low)
            return false;
         if(r[i + k].low < r[i].low)
            return false;
      }
   }
   return true;
}

void AddPivot(Pivot &piv[], int &pc, const int shift, const double price, const int type, const double minAmp)
{
   if(pc == 0)
   {
      ArrayResize(piv, 1);
      piv[0].shift = shift;
      piv[0].price = price;
      piv[0].type  = type;
      pc = 1;
      return;
   }

   if(piv[pc - 1].type == type)
   {
      if((type == 1 && price > piv[pc - 1].price) ||
         (type == -1 && price < piv[pc - 1].price))
      {
         piv[pc - 1].shift = shift;
         piv[pc - 1].price = price;
      }
      return;
   }

   if(MathAbs(price - piv[pc - 1].price) >= minAmp)
   {
      ArrayResize(piv, pc + 1);
      piv[pc].shift = shift;
      piv[pc].price = price;
      piv[pc].type  = type;
      pc++;
   }
}

int BiasSign(const int handle, const ENUM_TIMEFRAMES tf)
{
   double ema = 0.0;
   if(!GetBuf(handle, 0, 1, ema))
      return 0;
   double c = iClose(_Symbol, tf, 1);
   if(c <= 0.0)
      return 0;
   if(c > ema)
      return 1;
   if(c < ema)
      return -1;
   return 0;
}

bool BiasPassesStrict(const int dir)
{
   int s1 = BiasSign(g_ema1, InpBiasTF1);
   int s2 = BiasSign(g_ema2, InpBiasTF2);
   return (s1 == dir && s2 != -dir);
}

int ClassifySetup(const double rangeATR, const double wickR, const double bodyR,
                  const bool rsiDiv, const bool macdDiv)
{
   if(rangeATR >= InpMEFRangeATR)
      return SETUP_MEF;
   if(wickR >= InpFakeoutWickRatio)
      return SETUP_FAKEOUT;
   if(rsiDiv && macdDiv)
      return SETUP_QMC;
   if(rsiDiv)
      return SETUP_IQM;
   if(macdDiv)
      return SETUP_QMR;
   if(bodyR <= 0.25 && wickR >= 0.30)
      return SETUP_QMM;
   return SETUP_QM;
}

//--- risk money helpers -----------------------------------------------
double LotRiskMoney(const double lot, const double entry, const double sl)
{
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tv <= 0.0)
      tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tv <= 0.0 || ts <= 0.0)
      return 0.0;
   return lot * MathAbs(entry - sl) / ts * tv;
}

// risk of open positions (distance to the current stop) plus pending orders on one side
double OpenRiskMoney(const int dir)
{
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tv <= 0.0)
      tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tv <= 0.0 || ts <= 0.0)
      return 0.0;

   double sum = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      long type = PositionGetInteger(POSITION_TYPE);
      int pdir = (type == POSITION_TYPE_BUY ? DIR_BUY : DIR_SELL);
      if(pdir != dir)
         continue;

      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      if(sl <= 0.0)
         continue;
      double dist = MathMax(0.0, pdir * (open - sl));
      sum += PositionGetDouble(POSITION_VOLUME) * dist / ts * tv;
   }

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket))
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)
         continue;

      long type = OrderGetInteger(ORDER_TYPE);
      bool isBuy  = (type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_BUY_STOP_LIMIT);
      bool isSell = (type == ORDER_TYPE_SELL_LIMIT || type == ORDER_TYPE_SELL_STOP || type == ORDER_TYPE_SELL_STOP_LIMIT);
      if((dir == DIR_BUY && !isBuy) || (dir == DIR_SELL && !isSell))
         continue;

      double sl = OrderGetDouble(ORDER_SL);
      if(sl <= 0.0)
         continue;
      sum += OrderGetDouble(ORDER_VOLUME_CURRENT) * MathAbs(OrderGetDouble(ORDER_PRICE_OPEN) - sl) / ts * tv;
   }

   return sum;
}

//--- study logger: virtual outcome of every pattern ----------------------
// Each virtual trade waits for the level, then records the first bar on which
// price reached each favourable (+R) and adverse (-R) threshold. With those
// first-passage times any SL/TP pair can be scored offline.
void VTAdd(const PatInfo &pi, const string kind, const double entry, const double sl, const double atr)
{
   if(!InpStudyMode)
      return;
   if(g_vtCount >= VT_MAX)
   {
      g_vtSkipped++;
      return;
   }
   double R = MathAbs(entry - sl);
   if(R <= 0.0)
      return;

   int i = g_vtCount;
   g_vt[i].pat       = pi;
   g_vt[i].kind      = kind;
   g_vt[i].decision  = "pending";
   g_vt[i].entry     = entry;
   g_vt[i].sl        = sl;
   g_vt[i].R         = R;
   g_vt[i].atr       = atr;
   g_vt[i].created   = TimeCurrent();
   g_vt[i].expiry    = TimeCurrent() + (datetime)(InpStudyWaitHours * 3600);
   g_vt[i].lastBar   = 0;
   g_vt[i].state     = 0;
   g_vt[i].touchTime = 0;
   g_vt[i].barsSince = 0;
   g_vt[i].mfe       = 0.0;
   g_vt[i].mae       = 0.0;
   for(int k = 0; k < VF_COUNT; k++)
      g_vt[i].tF[k] = -1;
   for(int k = 0; k < VA_COUNT; k++)
      g_vt[i].tA[k] = -1;
   g_vtCount++;
}

void VTSetDecision(const string key, const string decision, const int score)
{
   for(int i = 0; i < g_vtCount; i++)
   {
      if(g_vt[i].pat.key != key)
         continue;
      g_vt[i].decision = decision;
      g_vt[i].pat.score = score;
   }
}

void VTFinish(const int i, const string status)
{
   if(i < 0 || i >= g_vtCount)
      return;

   if(InpStudyMode)
   {
      string fn = StringFormat("STRUXA_v323_virtual_%s.csv", _Symbol);
      int h = FileOpen(fn, FILE_READ | FILE_WRITE | FILE_CSV | FILE_COMMON | FILE_ANSI, ';');
      if(h != INVALID_HANDLE)
      {
         if(FileSize(h) == 0)
         {
            string hdr = "key;symbol;profile;dir;tag;kind;decision;score;created;server_hour;entry;sl;R_price;R_atr;"
                         "bars_Ls_H2;bars_H2_head;bars_head_BOS;BOS_age_bars;leg_Ls_H2_ATR;leg_H2_head_ATR;undercut_ATR;"
                         "wick_ratio;range_ATR;rsi_div;macd_div;bias_H1;bias_H4;status;touch_min;mfe_R;mae_R";
            for(int k = 0; k < VF_COUNT; k++)
               hdr += ";F" + DoubleToString(VF_LEVELS[k], 2);
            for(int k = 0; k < VA_COUNT; k++)
               hdr += ";A" + DoubleToString(VA_LEVELS[k], 2);
            hdr += ";h4_active;h4_type;h4_dir;h4_match;h4_swept;h4_pos;h4_trend;ltf_active;ltf_type;ltf_dir;ltf_match;ltf_swept;pd_zone;d1_bias;d1_crt;crt_nested";
            FileWrite(h, hdr);
         }
         FileSeek(h, 0, SEEK_END);

         int dg = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
         int tag = StatsIndex(g_vt[i].pat.setup, g_vt[i].pat.dir, g_vt[i].pat.p);
         int touchMin = (g_vt[i].touchTime > 0 ? (int)((g_vt[i].touchTime - g_vt[i].created) / 60) : -1);

         string row = StringFormat("%s;%s;%s;%s;%s;%s;%s;%d;%s;%d;%s;%s;%s;%.2f;",
                                   g_vt[i].pat.key, _Symbol, g_prof[g_vt[i].pat.p].name, DirName(g_vt[i].pat.dir),
                                   g_stats[tag].tag, g_vt[i].kind, g_vt[i].decision, g_vt[i].pat.score,
                                   TimeToString(g_vt[i].created, TIME_DATE | TIME_MINUTES), g_vt[i].pat.hour,
                                   DoubleToString(g_vt[i].entry, dg), DoubleToString(g_vt[i].sl, dg),
                                   DoubleToString(g_vt[i].R, dg), (g_vt[i].atr > 0.0 ? g_vt[i].R / g_vt[i].atr : 0.0));
         row += StringFormat("%d;%d;%d;%d;%.2f;%.2f;%.2f;%.2f;%.2f;%d;%d;%d;%d;%s;%d;%.2f;%.2f",
                             g_vt[i].pat.barsLsH2, g_vt[i].pat.barsH2Head, g_vt[i].pat.barsHeadBos, g_vt[i].pat.bosAge,
                             g_vt[i].pat.legLsH2ATR, g_vt[i].pat.legH2HeadATR, g_vt[i].pat.undercutATR,
                             g_vt[i].pat.wickR, g_vt[i].pat.rangeATR, g_vt[i].pat.rsiDiv, g_vt[i].pat.macdDiv,
                             g_vt[i].pat.bias1, g_vt[i].pat.bias2, status, touchMin, g_vt[i].mfe, g_vt[i].mae);
         for(int k = 0; k < VF_COUNT; k++)
            row += ";" + IntegerToString(g_vt[i].tF[k]);
         for(int k = 0; k < VA_COUNT; k++)
            row += ";" + IntegerToString(g_vt[i].tA[k]);
         row += StringFormat(";%d;%d;%d;%d;%d;%.2f;%d;%d;%d;%d;%d;%d;%d;%d;%d;%d",
                             g_vt[i].pat.ctx.h4Active, g_vt[i].pat.ctx.h4Type, g_vt[i].pat.ctx.h4Dir,
                             g_vt[i].pat.ctx.h4Match, g_vt[i].pat.ctx.h4Swept, g_vt[i].pat.ctx.h4Pos,
                             g_vt[i].pat.ctx.h4Trend, g_vt[i].pat.ctx.ltfActive, g_vt[i].pat.ctx.ltfType,
                             g_vt[i].pat.ctx.ltfDir, g_vt[i].pat.ctx.ltfMatch, g_vt[i].pat.ctx.ltfSwept,
                             g_vt[i].pat.ctx.pdZone, g_vt[i].pat.ctx.d1Bias, g_vt[i].pat.ctx.d1Crt,
                             g_vt[i].pat.ctx.nested);
         FileWrite(h, row);
         FileClose(h);
      }
   }

   g_vt[i] = g_vt[g_vtCount - 1];
   g_vtCount--;
}

void VTRecord(const int i, const double adv, const double fav, const int bars, const bool favorable)
{
   if(adv > g_vt[i].mae)
      g_vt[i].mae = adv;
   for(int k = 0; k < VA_COUNT; k++)
      if(g_vt[i].tA[k] < 0 && adv >= VA_LEVELS[k])
         g_vt[i].tA[k] = bars;

   if(!favorable)
      return;

   if(fav > g_vt[i].mfe)
      g_vt[i].mfe = fav;
   for(int k = 0; k < VF_COUNT; k++)
      if(g_vt[i].tF[k] < 0 && fav >= VF_LEVELS[k])
         g_vt[i].tF[k] = bars;
}

void UpdateVirtualTrades()
{
   if(!InpStudyMode || g_vtCount == 0)
      return;

   datetime barOpen = iTime(_Symbol, InpExecutionTF, 1);
   double h = iHigh(_Symbol, InpExecutionTF, 1);
   double l = iLow(_Symbol, InpExecutionTF, 1);
   if(barOpen <= 0 || h <= 0.0 || l <= 0.0)
      return;

   int horizonBars = (int)((long)InpStudyHorizonHours * 3600 / MathMax(1, PeriodSeconds(InpExecutionTF)));

   for(int i = g_vtCount - 1; i >= 0; i--)
   {
      if(g_vt[i].lastBar >= barOpen)
         continue;
      if(barOpen < g_vt[i].created)
         continue;
      g_vt[i].lastBar = barOpen;

      int    dir   = g_vt[i].pat.dir;
      double entry = g_vt[i].entry;
      double R     = g_vt[i].R;

      double adv = (dir == DIR_BUY ? entry - l : h - entry) / R;
      double fav = (dir == DIR_BUY ? h - entry : entry - l) / R;

      if(g_vt[i].state == 0)
      {
         if(barOpen > g_vt[i].expiry)
         {
            VTFinish(i, "NO_TOUCH");
            continue;
         }

         bool touched = (dir == DIR_BUY ? l <= entry : h >= entry);
         if(!touched)
         {
            if(fav >= VF_LEVELS[VF_COUNT - 1])
               VTFinish(i, "RAN_AWAY");
            continue;
         }

         // touch bar: only adverse moves count (order inside the bar is unknown)
         g_vt[i].state = 1;
         g_vt[i].touchTime = barOpen;
         g_vt[i].barsSince = 0;
         VTRecord(i, adv, 0.0, 0, false);
         continue;
      }

      g_vt[i].barsSince++;
      VTRecord(i, adv, fav, g_vt[i].barsSince, true);

      if(adv >= VA_LEVELS[VA_COUNT - 1] || fav >= VF_LEVELS[VF_COUNT - 1] || g_vt[i].barsSince >= horizonBars)
         VTFinish(i, "DONE");
   }
}

bool TouchedSince(const int dir, const MqlRates &r[], const int bos, const double level)
{
   for(int s = bos - 1; s >= 1; s--)
   {
      if(dir == DIR_BUY && r[s].low <= level)
         return true;
      if(dir == DIR_SELL && r[s].high >= level)
         return true;
   }
   if(dir == DIR_BUY && r[0].low <= level)
      return true;
   if(dir == DIR_SELL && r[0].high >= level)
      return true;
   return false;
}

//=====================================================================
//  CRT module, phase 1: detect, mark and log. It changes no trades.
//  Range = the FIRST candle of the formation, full high to low, wicks included.
//=====================================================================
string CrtTypeName(const int t)
{
   switch(t)
   {
      case CRT_CLASSIC:      return "CLASSIC";
      case CRT_INSIDE:       return "INSIDE_BAR";
      case CRT_MULTI:        return "MULTI_SWEEP";
      case CRT_TBS:          return "TBS";
      case CRT_BREAK_RETEST: return "BREAK_RETEST";
      case CRT_ENGULF:       return "ENGULF";
      case CRT_SESSION:      return "SESSION";
      case CRT_DOUBLE:       return "DOUBLE_SWEEP";
   }
   return "NONE";
}

bool CrtTypeEnabled(const int t)
{
   switch(t)
   {
      case CRT_CLASSIC:      return InpCrtClassic;
      case CRT_INSIDE:       return InpCrtInside;
      case CRT_MULTI:        return InpCrtMulti;
      case CRT_TBS:          return InpCrtTBS;
      case CRT_BREAK_RETEST: return InpCrtBreakRetest;
      case CRT_ENGULF:       return InpCrtEngulf;
      case CRT_SESSION:      return InpCrtSession;
      case CRT_DOUBLE:       return InpCrtDouble;
   }
   return false;
}

ENUM_TIMEFRAMES CrtTF(const int t)
{
   return (t == 0 ? InpCrtTF1 : InpCrtTF2);
}

void CrtCtxZero(CrtCtx &c)
{
   c.h4Active = 0;
   c.h4Type = 0;
   c.h4Dir = 0;
   c.h4Match = 0;
   c.h4Swept = 0;
   c.h4Pos = 0.0;
   c.h4Trend = 0;
   c.ltfActive = 0;
   c.ltfType = 0;
   c.ltfDir = 0;
   c.ltfMatch = 0;
   c.ltfSwept = 0;
   c.pdZone = 0;
   c.d1Bias = 0;
   c.d1Crt = 0;
   c.nested = 0;
   c.h4Idx = -1;
   c.h4Hi = 0.0;
   c.h4Lo = 0.0;
   c.h4C1 = 0;
   c.h4Triggered = 0;
}

//--- marks ---------------------------------------------------------------
string CrtObjName(const int i)
{
   return g_prefix + "C" + IntegerToString(g_crt[i].tf) + "_" + IntegerToString((long)g_crt[i].c1);
}

void CrtDeleteMarks(const string base)
{
   string suffix[3] = {"", "_t", "_m"};
   for(int k = 0; k < 3; k++)
      if(ObjectFind(0, base + suffix[k]) >= 0)
         ObjectDelete(0, base + suffix[k]);
}

void CrtRegisterMark(const string base)
{
   int cap = MathMax(10, MathMin(200, InpMaxCrtMarks));
   int slot = g_crtMarkCount % cap;
   if(g_crtMarkCount >= cap && g_crtMarkNames[slot] != "")
      CrtDeleteMarks(g_crtMarkNames[slot]);
   g_crtMarkNames[slot] = base;
   g_crtMarkCount++;
}

string CrtLabelText(const int i, const string status)
{
   string tfn = TFName(CrtTF(g_crt[i].tf));
   string s;
   if(g_crt[i].type == 0)
      s = tfn + " ANCHOR (" + IntegerToString(g_crt[i].nInside) + " inside)";
   else
      s = tfn + " " + CrtTypeName(g_crt[i].type) + (g_crt[i].dir > 0 ? " BULL" : " BEAR");
   if(g_crt[i].nested)
      s += " nested";
   if(g_crt[i].type > 0 && g_crt[i].trend != 0)
      s += (g_crt[i].dir == g_crt[i].trend ? " with-trend" : " counter-trend");
   if(status != "")
      s += " | " + status;
   else if(g_crt[i].reachedTarget)
      s += " | TARGET";
   else if(g_crt[i].reachedMid)
      s += " | MID";
   return s;
}

void CrtDraw(const int i)
{
   if(!InpCrtDraw)
      return;
   if(g_crt[i].type == 0 && (g_crt[i].tf != 0 || !g_crt[i].anchor))
      return;

   string base = CrtObjName(i);
   int psec = PeriodSeconds(CrtTF(g_crt[i].tf));
   datetime t2 = g_crt[i].lastT + (datetime)(psec * 2);
   double mid = 0.5 * (g_crt[i].hi + g_crt[i].lo);

   if(!g_crt[i].drawn)
   {
      ObjectCreate(0, base, OBJ_RECTANGLE, 0, g_crt[i].c1, g_crt[i].hi, t2, g_crt[i].lo);
      ObjectCreate(0, base + "_m", OBJ_TREND, 0, g_crt[i].c1, mid, t2, mid);
      ObjectCreate(0, base + "_t", OBJ_TEXT, 0, g_crt[i].c1, g_crt[i].hi);
      CrtRegisterMark(base);
      g_crt[i].drawn = true;
   }
   else
   {
      ObjectSetInteger(0, base, OBJPROP_TIME, 1, t2);
      ObjectSetInteger(0, base + "_m", OBJPROP_TIME, 1, t2);
   }

   color col = clrSilver;
   if(g_crt[i].type > 0)
      col = (g_crt[i].dir > 0 ? clrLimeGreen : clrTomato);

   ObjectSetInteger(0, base, OBJPROP_COLOR, col);
   ObjectSetInteger(0, base, OBJPROP_STYLE, (g_crt[i].type == 0 ? STYLE_DOT : STYLE_SOLID));
   ObjectSetInteger(0, base, OBJPROP_WIDTH, (g_crt[i].tf == 0 ? 2 : 1));
   ObjectSetInteger(0, base, OBJPROP_FILL, false);
   ObjectSetInteger(0, base, OBJPROP_BACK, true);
   ObjectSetInteger(0, base, OBJPROP_SELECTABLE, false);

   ObjectSetInteger(0, base + "_m", OBJPROP_COLOR, col);
   ObjectSetInteger(0, base + "_m", OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, base + "_m", OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, base + "_m", OBJPROP_SELECTABLE, false);

   ObjectSetString(0, base + "_t", OBJPROP_TEXT, CrtLabelText(i, ""));
   ObjectSetInteger(0, base + "_t", OBJPROP_COLOR, col);
   ObjectSetInteger(0, base + "_t", OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, base + "_t", OBJPROP_SELECTABLE, false);
}

//--- records ---------------------------------------------------------------
void CrtRemoveRaw(const int i)
{
   g_crt[i] = g_crt[g_crtCount - 1];
   g_crtCount--;
}

void CrtRemoveSilent(const int i)
{
   if(g_crt[i].drawn)
      CrtDeleteMarks(CrtObjName(i));
   CrtRemoveRaw(i);
}

void CrtLogCSV(const int i, const string status)
{
   if(!InpCrtLog)
      return;

   string fn = StringFormat("STRUXA_v323_crt_%s.csv", _Symbol);
   int h = FileOpen(fn, FILE_READ | FILE_WRITE | FILE_CSV | FILE_COMMON | FILE_ANSI, ';');
   if(h == INVALID_HANDLE)
      return;

   if(FileSize(h) == 0)
      FileWrite(h, "tf;type;dir;session;c1_time;form_time;hi;lo;range_ATR;n_inside;n_sweep;trend;with_trend;nested;reached_mid;reached_target;bars_to_mid;bars_to_target;status");

   FileSeek(h, 0, SEEK_END);
   int dg = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   int withTrend = (g_crt[i].trend == 0 ? 0 : (g_crt[i].dir == g_crt[i].trend ? 1 : -1));
   string row = StringFormat("%s;%s;%d;%d;%s;%s;%s;%s;%.2f;%d;%d;%d;%d;%d;%d;%d;%d;%d;%s",
                             TFName(CrtTF(g_crt[i].tf)), CrtTypeName(g_crt[i].type), g_crt[i].dir,
                             (g_crt[i].isSession ? 1 : 0),
                             TimeToString(g_crt[i].c1, TIME_DATE | TIME_MINUTES),
                             TimeToString(g_crt[i].formTime, TIME_DATE | TIME_MINUTES),
                             DoubleToString(g_crt[i].hi, dg), DoubleToString(g_crt[i].lo, dg),
                             (g_crt[i].atr > 0.0 ? (g_crt[i].hi - g_crt[i].lo) / g_crt[i].atr : 0.0),
                             g_crt[i].nInside, g_crt[i].nSweep, g_crt[i].trend, withTrend,
                             (g_crt[i].nested ? 1 : 0), (g_crt[i].reachedMid ? 1 : 0),
                             (g_crt[i].reachedTarget ? 1 : 0), g_crt[i].midBars, g_crt[i].tgtBars, status);
   FileWrite(h, row);
   FileClose(h);
}

void CrtFinish(const int i, const string status)
{
   if(g_crt[i].type > 0)
   {
      if(g_crt[i].drawn && InpCrtDraw)
         ObjectSetString(0, CrtObjName(i) + "_t", OBJPROP_TEXT, CrtLabelText(i, status));
      CrtLogCSV(i, status);
   }
   else if(g_crt[i].drawn)
      CrtDeleteMarks(CrtObjName(i));

   CrtRemoveRaw(i);
}

void CrtCreate(const int t, const datetime c1, const double hi, const double lo, const double atr,
               const bool isSession, const int maxInside, const int trendSign)
{
   if(g_crtCount >= CRT_MAX)
   {
      int oldest = 0;
      for(int k = 1; k < g_crtCount; k++)
         if(g_crt[k].c1 < g_crt[oldest].c1)
            oldest = k;
      CrtFinish(oldest, "DROPPED");
   }

   int i = g_crtCount;
   g_crt[i].tf = t;
   g_crt[i].c1 = c1;
   g_crt[i].lastT = c1;
   g_crt[i].hi = hi;
   g_crt[i].lo = lo;
   g_crt[i].atr = atr;
   g_crt[i].state = CS_FORMING;
   g_crt[i].nInside = 0;
   g_crt[i].side = 0;
   g_crt[i].nSweep = 0;
   g_crt[i].sweepExt = 0.0;
   g_crt[i].formTime = 0;
   g_crt[i].type = 0;
   g_crt[i].dir = 0;
   g_crt[i].trend = trendSign;
   g_crt[i].reachedMid = false;
   g_crt[i].reachedTarget = false;
   g_crt[i].midBars = -1;
   g_crt[i].tgtBars = -1;
   g_crt[i].age = 0;
   g_crt[i].formAge = 0;
   g_crt[i].breakSide = 0;
   g_crt[i].breakBars = 0;
   g_crt[i].nested = false;
   g_crt[i].anchor = false;
   g_crt[i].isSession = isSession;
   g_crt[i].maxInside = maxInside;
   g_crt[i].deeper = false;
   g_crt[i].drawn = false;
   g_crt[i].triggered = false;
   g_crt[i].trigDir = 0;
   g_crtCount++;
}

// the LTF range sits inside a TF1 anchor or TF1 CRT that is still alive
bool CrtNestedIn(const double lo, const double hi)
{
   for(int i = 0; i < g_crtCount; i++)
   {
      if(g_crt[i].tf != 0)
         continue;
      if(!(g_crt[i].anchor || g_crt[i].type > 0))
         continue;
      double tol = InpCrtMinSweepATR * g_crt[i].atr;
      if(lo >= g_crt[i].lo - tol && hi <= g_crt[i].hi + tol)
         return true;
   }
   return false;
}

// returns true when the record is still alive after forming
bool CrtForm(const int i, const int type, const int dir, const datetime xt, const int psec,
             const int trendSign, const bool finalizeNow)
{
   if(!CrtTypeEnabled(type))
   {
      CrtRemoveSilent(i);
      return false;
   }

   bool nested = false;
   if(g_crt[i].tf == 1 && !g_crt[i].isSession)
   {
      nested = CrtNestedIn(g_crt[i].lo, g_crt[i].hi);
      if(InpCrtLtfNestedOnly && !nested)
      {
         CrtRemoveSilent(i);
         return false;
      }
   }

   g_crt[i].type = type;
   g_crt[i].dir = dir;
   g_crt[i].formTime = xt + psec;
   g_crt[i].formAge = g_crt[i].age;
   g_crt[i].trend = trendSign;
   g_crt[i].nested = nested;
   g_crtTypeCount[type]++;
   CrtDraw(i);

   if(finalizeNow)
   {
      CrtFinish(i, "FORMED");
      return false;
   }
   return true;
}

void CrtRefine(const int i)
{
   if(g_crt[i].isSession)
      return;
   int cur = g_crt[i].type;
   int nt = cur;
   if(g_crt[i].deeper && InpCrtDouble)
      nt = CRT_DOUBLE;
   else if(g_crt[i].nSweep >= 2 && InpCrtMulti)
      nt = CRT_MULTI;
   if(nt != cur)
   {
      if(cur > 0)
         g_crtTypeCount[cur]--;
      g_crt[i].type = nt;
      g_crtTypeCount[nt]++;
      CrtDraw(i);
   }
}

//--- state machine: one closed candle X after the range candle ------------
void CrtProcess(const int i, const datetime xt, const double xo, const double xh, const double xl,
                const double xc, const int psec, const int trendSign)
{
   if(g_crt[i].c1 >= xt)
      return;

   g_crt[i].age++;
   g_crt[i].lastT = xt;

   double hi  = g_crt[i].hi;
   double lo  = g_crt[i].lo;
   double mid = 0.5 * (hi + lo);
   double atr = g_crt[i].atr;
   double tol = InpCrtMinSweepATR * atr;

   bool inside = (xh <= hi + tol && xl >= lo - tol);
   bool aboveH = (xh > hi + tol);
   bool belowL = (xl < lo - tol);

   //--- forming: counting inside bars until the first candle that leaves the range
   if(g_crt[i].state == CS_FORMING)
   {
      if(inside)
      {
         g_crt[i].nInside++;
         if(g_crt[i].nInside >= InpAnchorMinInside && !g_crt[i].anchor && !g_crt[i].isSession)
         {
            g_crt[i].anchor = true;
            CrtDraw(i);
         }
         if(g_crt[i].nInside > g_crt[i].maxInside)
            CrtRemoveSilent(i);
         return;
      }

      if(aboveH && belowL)
      {
         g_crtEventBar = xt;
         double body = MathAbs(xc - xo);
         if(body >= InpCrtEngulfBodyATR * atr && xc > hi)
            CrtForm(i, CRT_ENGULF, 1, xt, psec, trendSign, true);
         else if(body >= InpCrtEngulfBodyATR * atr && xc < lo)
            CrtForm(i, CRT_ENGULF, -1, xt, psec, trendSign, true);
         else
            CrtRemoveSilent(i);
         return;
      }

      if(aboveH)
      {
         g_crtEventBar = xt;
         g_crt[i].side = 1;
         g_crt[i].sweepExt = xh;
         if(xc <= hi)
         {
            g_crt[i].nSweep = 1;
            g_crt[i].state = CS_SWEPT;
            int baseType = (g_crt[i].isSession ? CRT_SESSION : (g_crt[i].nInside == 0 ? CRT_CLASSIC : CRT_INSIDE));
            CrtForm(i, baseType, -1, xt, psec, trendSign, false);
         }
         else
         {
            g_crt[i].state = CS_BROKEN;
            g_crt[i].breakSide = 1;
            g_crt[i].breakBars = 0;
         }
         return;
      }

      if(belowL)
      {
         g_crtEventBar = xt;
         g_crt[i].side = -1;
         g_crt[i].sweepExt = xl;
         if(xc >= lo)
         {
            g_crt[i].nSweep = 1;
            g_crt[i].state = CS_SWEPT;
            int baseType = (g_crt[i].isSession ? CRT_SESSION : (g_crt[i].nInside == 0 ? CRT_CLASSIC : CRT_INSIDE));
            CrtForm(i, baseType, 1, xt, psec, trendSign, false);
         }
         else
         {
            g_crt[i].state = CS_BROKEN;
            g_crt[i].breakSide = -1;
            g_crt[i].breakBars = 0;
         }
         return;
      }
      return;
   }

   //--- a body closed beyond the range: turtle body soup or break and retest
   if(g_crt[i].state == CS_BROKEN)
   {
      g_crtEventBar = xt;
      g_crt[i].breakBars++;

      if(g_crt[i].breakSide > 0)
      {
         g_crt[i].sweepExt = MathMax(g_crt[i].sweepExt, xh);
         if(xc <= hi)
         {
            g_crt[i].side = 1;
            g_crt[i].nSweep = 1;
            g_crt[i].state = CS_SWEPT;
            CrtForm(i, CRT_TBS, -1, xt, psec, trendSign, false);
         }
         else if(xl <= hi + tol)
            CrtForm(i, CRT_BREAK_RETEST, 1, xt, psec, trendSign, true);
         else if(g_crt[i].breakBars >= InpCrtBreakWait)
            CrtRemoveSilent(i);
      }
      else
      {
         g_crt[i].sweepExt = MathMin(g_crt[i].sweepExt, xl);
         if(xc >= lo)
         {
            g_crt[i].side = -1;
            g_crt[i].nSweep = 1;
            g_crt[i].state = CS_SWEPT;
            CrtForm(i, CRT_TBS, 1, xt, psec, trendSign, false);
         }
         else if(xh >= lo - tol)
            CrtForm(i, CRT_BREAK_RETEST, -1, xt, psec, trendSign, true);
         else if(g_crt[i].breakBars >= InpCrtBreakWait)
            CrtRemoveSilent(i);
      }
      return;
   }

   //--- swept: follow the move toward the opposite side
   if(g_crt[i].state == CS_SWEPT)
   {
      int side = g_crt[i].side;

      if((side > 0 && xc > hi) || (side < 0 && xc < lo))
      {
         CrtFinish(i, "FAILED");
         return;
      }

      double ext = g_crt[i].sweepExt;
      bool again = (side > 0 ? xh > ext : xl < ext);
      if(again)
      {
         g_crt[i].nSweep++;
         double deeperBy = (side > 0 ? xh - ext : ext - xl);
         if(deeperBy >= 0.1 * atr)
            g_crt[i].deeper = true;
         g_crt[i].sweepExt = (side > 0 ? xh : xl);
         CrtRefine(i);
      }

      int sinceForm = g_crt[i].age - g_crt[i].formAge;
      bool reachMid = (side > 0 ? xl <= mid : xh >= mid);
      bool reachTgt = (side > 0 ? xl <= lo : xh >= hi);

      if(reachMid && !g_crt[i].reachedMid)
      {
         g_crt[i].reachedMid = true;
         g_crt[i].midBars = sinceForm;
      }
      if(reachTgt && !g_crt[i].reachedTarget)
      {
         g_crt[i].reachedTarget = true;
         g_crt[i].tgtBars = sinceForm;
         CrtFinish(i, "COMPLETED");
         return;
      }
      if(sinceForm >= InpCrtTrackBars)
         CrtFinish(i, g_crt[i].reachedMid ? "MID_ONLY" : "EXPIRED");
   }
}

//--- session range (Asia by default) as a CRT range ------------------------
void SessionOnBar(const datetime xt, const double xh, const double xl, const double atr)
{
   MqlDateTime dt;
   TimeToStruct(xt, dt);
   int h = (dt.hour - InpBrokerGMTOffset + 48) % 24;

   bool inSess = (InpSessionCrtStartGMT <= InpSessionCrtEndGMT
                  ? (h >= InpSessionCrtStartGMT && h < InpSessionCrtEndGMT)
                  : (h >= InpSessionCrtStartGMT || h < InpSessionCrtEndGMT));

   if(inSess)
   {
      if(!g_sessIn)
      {
         g_sessIn = true;
         g_sessStart = xt;
         g_sessHi = xh;
         g_sessLo = xl;
      }
      else
      {
         g_sessHi = MathMax(g_sessHi, xh);
         g_sessLo = MathMin(g_sessLo, xl);
      }
   }
   else if(g_sessIn)
   {
      g_sessIn = false;
      if((g_sessHi - g_sessLo) >= InpCrtMinRangeATR * atr)
         CrtCreate(1, g_sessStart, g_sessHi, g_sessLo, atr, true, 96, 0);
   }
}

//--- one closed candle of CRT timeframe t (0 = TF1, 1 = TF2) ---------------
void CrtOnBar(const int t, const int shift)
{
   if(!g_crtOn)
      return;

   ENUM_TIMEFRAMES tf = CrtTF(t);
   datetime xt = iTime(_Symbol, tf, shift);
   if(xt <= 0 || g_crtProcessed[t] >= xt)
      return;
   g_crtProcessed[t] = xt;

   double xo = iOpen(_Symbol, tf, shift);
   double xh = iHigh(_Symbol, tf, shift);
   double xl = iLow(_Symbol, tf, shift);
   double xc = iClose(_Symbol, tf, shift);

   double atr = 0.0;
   if(!GetBuf(g_crtAtr[t], 0, shift, atr) || atr <= 0.0)
      return;

   double ema = 0.0;
   int trendSign = 0;
   if(GetBuf(g_crtEma[t], 0, shift, ema))
      trendSign = (xc > ema ? 1 : (xc < ema ? -1 : 0));

   int psec = PeriodSeconds(tf);

   if(t == 1 && InpCrtSession)
      SessionOnBar(xt, xh, xl, atr);

   for(int i = g_crtCount - 1; i >= 0; i--)
      if(g_crt[i].tf == t)
         CrtProcess(i, xt, xo, xh, xl, xc, psec, trendSign);

   // a candle inside a range that is still forming belongs to that formation
   bool insideForming = false;
   for(int i = 0; i < g_crtCount; i++)
   {
      if(g_crt[i].tf != t || g_crt[i].state != CS_FORMING)
         continue;
      double tol = InpCrtMinSweepATR * g_crt[i].atr;
      if(xh <= g_crt[i].hi + tol && xl >= g_crt[i].lo - tol)
      {
         insideForming = true;
         break;
      }
   }
   if(!insideForming && g_crtEventBar != xt && (xh - xl) >= InpCrtMinRangeATR * atr)
      CrtCreate(t, xt, xh, xl, atr, false, InpCrtMaxInside, trendSign);

   // keep the boxes of live ranges stretching to the latest candle
   for(int i = 0; i < g_crtCount; i++)
      if(g_crt[i].tf == t && g_crt[i].drawn)
         CrtDraw(i);
}

//--- daily levels -----------------------------------------------------------
void DailyUpdate()
{
   if(!InpDailyMark)
      return;

   datetime d0 = iTime(_Symbol, PERIOD_D1, 0);
   if(d0 <= 0 || d0 == g_dayShown)
      return;
   g_dayShown = d0;

   g_pdh = iHigh(_Symbol, PERIOD_D1, 1);
   g_pdl = iLow(_Symbol, PERIOD_D1, 1);
   double po = iOpen(_Symbol, PERIOD_D1, 1);
   double pc = iClose(_Symbol, PERIOD_D1, 1);
   g_d1bias = (pc > po ? 1 : -1);

   double h2 = iHigh(_Symbol, PERIOD_D1, 2);
   double l2 = iLow(_Symbol, PERIOD_D1, 2);
   g_d1crt = 0;
   if(g_pdh > h2 && pc <= h2)
      g_d1crt = -1;
   if(g_pdl < l2 && pc >= l2)
      g_d1crt = (g_d1crt == -1 ? 0 : 1);

   if(!InpCrtDraw || g_pdh <= 0.0 || g_pdl <= 0.0)
      return;

   string names[3];
   names[0] = g_prefix + "D_PDH";
   names[1] = g_prefix + "D_PDL";
   names[2] = g_prefix + "D_EQ";
   double prices[3];
   prices[0] = g_pdh;
   prices[1] = g_pdl;
   prices[2] = 0.5 * (g_pdh + g_pdl);
   string labels[3] = {"PDH", "PDL", "EQ 50%"};
   color cols[3] = {clrGold, clrGold, clrDarkOrange};

   for(int k = 0; k < 3; k++)
   {
      if(ObjectFind(0, names[k]) >= 0)
         ObjectDelete(0, names[k]);
      if(ObjectFind(0, names[k] + "_t") >= 0)
         ObjectDelete(0, names[k] + "_t");

      ObjectCreate(0, names[k], OBJ_TREND, 0, d0, prices[k], d0 + 86400, prices[k]);
      ObjectSetInteger(0, names[k], OBJPROP_COLOR, cols[k]);
      ObjectSetInteger(0, names[k], OBJPROP_STYLE, (k == 2 ? STYLE_DOT : STYLE_SOLID));
      ObjectSetInteger(0, names[k], OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, names[k], OBJPROP_SELECTABLE, false);

      ObjectCreate(0, names[k] + "_t", OBJ_TEXT, 0, d0, prices[k]);
      ObjectSetString(0, names[k] + "_t", OBJPROP_TEXT, labels[k]);
      ObjectSetInteger(0, names[k] + "_t", OBJPROP_COLOR, cols[k]);
      ObjectSetInteger(0, names[k] + "_t", OBJPROP_FONTSIZE, 8);
      ObjectSetInteger(0, names[k] + "_t", OBJPROP_SELECTABLE, false);
   }
}

//--- context flags for a QM pattern -----------------------------------------
void CrtContext(const int dir, const double entry, const double headP, const datetime headTime, CrtCtx &c)
{
   CrtCtxZero(c);

   if(InpDailyMark && g_pdh > g_pdl && g_pdh > 0.0)
   {
      double mid = 0.5 * (g_pdh + g_pdl);
      c.pdZone = (entry > mid ? 1 : -1);
      if(entry > g_pdh)
         c.pdZone = 2;
      if(entry < g_pdl)
         c.pdZone = -2;
      c.d1Bias = g_d1bias;
      c.d1Crt = g_d1crt;
   }

   if(!g_crtOn)
      return;

   for(int t = 0; t < 2; t++)
   {
      int best = -1;
      for(int i = 0; i < g_crtCount; i++)
      {
         if(g_crt[i].tf != t)
            continue;
         if(!(g_crt[i].type > 0 || (t == 0 && g_crt[i].anchor)))
            continue;
         double tol = 0.25 * g_crt[i].atr;
         if(entry < g_crt[i].lo - tol || entry > g_crt[i].hi + tol)
            continue;
         if(best < 0 || g_crt[i].c1 > g_crt[best].c1)
            best = i;
      }
      if(best < 0)
         continue;

      int rdir = g_crt[best].dir;
      if(rdir == 0 && g_crt[best].triggered)
         rdir = g_crt[best].trigDir;   // sweep candle not closed yet: the trigger QM sets the direction
      int match = (rdir == 0 ? 0 : (rdir == dir ? 1 : -1));
      bool beyond = (dir == DIR_BUY ? headP < g_crt[best].lo : headP > g_crt[best].hi);
      int swept = (beyond && headTime >= g_crt[best].c1) ? 1 : 0;
      double span = g_crt[best].hi - g_crt[best].lo;
      double pos = (span > 0.0 ? (entry - g_crt[best].lo) / span : 0.5);
      pos = MathMax(0.0, MathMin(1.0, pos));

      if(t == 0)
      {
         c.h4Active = 1;
         c.h4Type = g_crt[best].type;
         c.h4Dir = rdir;
         c.h4Match = match;
         c.h4Swept = swept;
         c.h4Pos = pos;
         c.h4Trend = g_crt[best].trend;
         c.h4Idx = best;
         c.h4Hi = g_crt[best].hi;
         c.h4Lo = g_crt[best].lo;
         c.h4C1 = g_crt[best].c1;
         c.h4Triggered = (g_crt[best].triggered ? 1 : 0);
      }
      else
      {
         c.ltfActive = 1;
         c.ltfType = g_crt[best].type;
         c.ltfDir = rdir;
         c.ltfMatch = match;
         c.ltfSwept = swept;
         if(g_crt[best].nested)
            c.nested = 1;
      }
   }
}

//--- setup, tick, shutdown ----------------------------------------------------
void CrtInit()
{
   g_crtOn = false;
   g_crtCount = 0;
   g_qmhCount = 0;
   g_trigQm = 0;
   g_inRangeQm = 0;
   g_handoffs = 0;
   g_hoPending = false;
   ArrayResize(g_crt, CRT_MAX);
   for(int k = 0; k < CRT_TYPE_SLOTS; k++)
      g_crtTypeCount[k] = 0;
   g_crtMarkCount = 0;
   g_sessIn = false;
   g_crtProcessed[0] = 0;
   g_crtProcessed[1] = 0;
   g_crtLastBar[0] = 0;
   g_crtLastBar[1] = 0;
   g_dayShown = 0;
   g_crtEventBar = 0;
   g_pdh = 0.0;
   g_pdl = 0.0;
   g_d1bias = 0;
   g_d1crt = 0;

   DailyUpdate();

   if(InpCrtMode == CRT_OFF)
      return;

   g_crtAtr[0] = iATR(_Symbol, InpCrtTF1, InpATRPeriod);
   g_crtEma[0] = iMA(_Symbol, InpCrtTF1, InpBiasEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(InpCrtUseTF2)
   {
      g_crtAtr[1] = iATR(_Symbol, InpCrtTF2, InpATRPeriod);
      g_crtEma[1] = iMA(_Symbol, InpCrtTF2, InpBiasEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   }

   bool ok = (g_crtAtr[0] != INVALID_HANDLE && g_crtEma[0] != INVALID_HANDLE);
   if(InpCrtUseTF2)
      ok = ok && (g_crtAtr[1] != INVALID_HANDLE && g_crtEma[1] != INVALID_HANDLE);
   if(!ok)
   {
      Print("[", InpEAName, "] CRT module disabled: indicator handle failed");
      return;
   }
   g_crtOn = true;

   // replay recent history so existing CRTs are marked on the chart at once
   int psec1 = PeriodSeconds(InpCrtTF1);
   int n1 = (int)MathMin(2000.0, (double)InpCrtBackfillDays * 86400.0 / psec1);

   if(!InpCrtUseTF2)
   {
      for(int s = n1; s >= 1; s--)
         CrtOnBar(0, s);
   }
   else
   {
      int psec2 = PeriodSeconds(InpCrtTF2);
      int n2 = (int)MathMin(5000.0, (double)InpCrtBackfillDays * 86400.0 / psec2);
      int s1 = n1;
      for(int s2 = n2; s2 >= 1; s2--)
      {
         datetime xt2 = iTime(_Symbol, InpCrtTF2, s2);
         if(xt2 <= 0)
            continue;
         while(s1 >= 1 && iTime(_Symbol, InpCrtTF1, s1) + psec1 <= xt2 + psec2)
         {
            CrtOnBar(0, s1);
            s1--;
         }
         CrtOnBar(1, s2);
      }
      while(s1 >= 1)
      {
         CrtOnBar(0, s1);
         s1--;
      }
   }
}

void CrtTick()
{
   DailyUpdate();
   if(!g_crtOn)
      return;
   if(NewBar(InpCrtTF1, g_crtLastBar[0]))
      CrtOnBar(0, 1);
   if(InpCrtUseTF2 && NewBar(InpCrtTF2, g_crtLastBar[1]))
      CrtOnBar(1, 1);
}

void CrtShutdown()
{
   for(int i = g_crtCount - 1; i >= 0; i--)
      CrtFinish(i, "UNRESOLVED");

   for(int k = 0; k < 2; k++)
   {
      if(g_crtAtr[k] != INVALID_HANDLE)
      {
         IndicatorRelease(g_crtAtr[k]);
         g_crtAtr[k] = INVALID_HANDLE;
      }
      if(g_crtEma[k] != INVALID_HANDLE)
      {
         IndicatorRelease(g_crtEma[k]);
         g_crtEma[k] = INVALID_HANDLE;
      }
   }
}

//=====================================================================
//  Phase 2: CRT trading rules, TP chain, QM history, handoff trail
//=====================================================================
void QmHistAdd(const ulong zid, const int dir, const double entry, const datetime c1)
{
   int idx;
   if(g_qmhCount < QMH_MAX)
   {
      idx = g_qmhCount;
      g_qmhCount++;
   }
   else
   {
      for(int k = 1; k < QMH_MAX; k++)
         g_qmh[k - 1] = g_qmh[k];
      idx = QMH_MAX - 1;
   }
   g_qmh[idx].zid = zid;
   g_qmh[idx].dir = dir;
   g_qmh[idx].entry = entry;
   g_qmh[idx].t = TimeCurrent();
   g_qmh[idx].c1 = c1;
   g_qmh[idx].status = 0;
}

void QmHistSetStatus(const ulong zid, const int status)
{
   for(int k = g_qmhCount - 1; k >= 0; k--)
   {
      if(g_qmh[k].zid == zid)
      {
         g_qmh[k].status = status;
         return;
      }
   }
}

// entry level of the most recent opposite QM in the same marked range
bool QmPrevOpposite(const int dir, const datetime c1, double &entryOut)
{
   for(int k = g_qmhCount - 1; k >= 0; k--)
   {
      if(g_qmh[k].dir != -dir)
         continue;
      bool same = (c1 != 0 ? g_qmh[k].c1 == c1 : (TimeCurrent() - g_qmh[k].t) <= 12 * 3600);
      if(!same)
         continue;
      entryOut = g_qmh[k].entry;
      return true;
   }
   return false;
}

// order block beyond the internal range liquidity (the nearest swing in the trade direction)
bool FindIrlObTarget(const int dir, const double entry, const Pivot &piv[], const int pc,
                     const MqlRates &r[], const double farLevel, double &tpOut)
{
   double best1 = 0.0, best2 = 0.0;
   int s1 = -1, s2 = -1;

   for(int k = 0; k < pc; k++)
   {
      if(piv[k].type != dir)
         continue;
      double d = dir * (piv[k].price - entry);
      if(d <= 0.0)
         continue;
      if(farLevel > 0.0 && dir * (piv[k].price - farLevel) > 0.0)
         continue;

      if(s1 < 0 || d < dir * (best1 - entry))
      {
         s2 = s1;
         best2 = best1;
         s1 = k;
         best1 = piv[k].price;
      }
      else if(s2 < 0 || d < dir * (best2 - entry))
      {
         s2 = k;
         best2 = piv[k].price;
      }
   }

   if(s2 < 0)
      return false;   // needs the liquidity swing and one more swing beyond it

   int sh = piv[s2].shift;
   for(int s = sh; s <= sh + 3 && s < ArraySize(r); s++)
   {
      bool lastPush = (dir == DIR_BUY ? r[s].close > r[s].open : r[s].close < r[s].open);
      if(lastPush)
      {
         tpOut = (dir == DIR_BUY ? r[s].low : r[s].high);   // near edge of the block
         return true;
      }
   }
   return false;
}

// TP chain: previous opposite QM, then order block past the liquidity, then the range extreme
bool PickTp(const int dir, const double entry, const double sl, const CrtCtx &ctx,
            const Pivot &piv[], const int pc, const MqlRates &r[], double &tpOut, string &how)
{
   double risk = MathAbs(entry - sl);
   if(risk <= 0.0)
      return false;
   double need = InpTpMinRR * risk;

   bool tryPrev = (InpTpMode == TP_PREV_QM || InpTpMode == TP_AUTO);
   bool tryOb   = (InpTpMode == TP_OB_PAST_IRL || InpTpMode == TP_AUTO);
   bool tryExt  = (InpTpMode == TP_OPP_EXTREME || InpTpMode == TP_AUTO);

   if(tryPrev)
   {
      double e = 0.0;
      if(QmPrevOpposite(dir, ctx.h4C1, e) && dir * (e - entry) >= need)
      {
         tpOut = e;
         how = "PREV_QM";
         return true;
      }
   }
   if(tryOb)
   {
      double farLevel = 0.0;
      if(ctx.h4Active == 1)
         farLevel = (dir == DIR_BUY ? ctx.h4Hi : ctx.h4Lo);
      double t = 0.0;
      if(FindIrlObTarget(dir, entry, piv, pc, r, farLevel, t) && dir * (t - entry) >= need)
      {
         tpOut = t;
         how = "OB_PAST_IRL";
         return true;
      }
   }
   if(tryExt && ctx.h4Active == 1)
   {
      double t = (dir == DIR_BUY ? ctx.h4Hi : ctx.h4Lo);
      if(dir * (t - entry) >= need)
      {
         tpOut = t;
         how = "RANGE_EXTREME";
         return true;
      }
   }
   return false;
}

// "" = allowed, otherwise the reason it is blocked
string CrtGate(const int dir, const CrtCtx &c, bool &sweepQm, bool &inRangeQm)
{
   sweepQm = false;
   inRangeQm = false;

   if(InpDailyFilterMode == DAILYF_PREMIUM_DISCOUNT && c.pdZone != 0)
   {
      if(dir == DIR_BUY && c.pdZone > 0)
         return "buy in daily premium";
      if(dir == DIR_SELL && c.pdZone < 0)
         return "sell in daily discount";
   }

   if(!g_crtOn)
      return "";

   if(InpH4TrendMode == TRENDMODE_WITH && c.h4Active == 1 && c.h4Trend != 0 && c.h4Trend != dir)
      return "against H4 trend";

   if(InpLtfMode == LTF_REQUIRE && !(c.ltfActive == 1 && c.ltfMatch == 1))
      return "no matching lower-TF CRT";

   bool gateOn = (InpSweepQmMode == SWEEPQM_REQUIRE || InpInRangeQmMode == INRANGE_ON);
   if(!gateOn)
      return "";

   if(c.h4Active != 1)
      return "no H4 range";

   sweepQm = (c.h4Swept == 1 && (c.h4Type == 0 || c.h4Match == 1));
   if(sweepQm)
      return "";

   if(InpInRangeQmMode == INRANGE_ON && (c.h4Type > 0 || c.h4Triggered == 1) && (c.h4Match == 1 || InpInRangeAnyDirection))
   {
      if(InpInRangeNeedsTrigger && c.h4Triggered == 0)
         return "in-range QM before the sweep QM";
      inRangeQm = true;
      return "";
   }
   return "not a sweep QM";
}

// handoff: an opposite QM is waiting with a live limit order
bool OppositePendingExists(const int dir)
{
   for(int i = 0; i < g_zoneCount; i++)
   {
      if(g_zones[i].state != Z_TRIGGERED || g_zones[i].direction != -dir)
         continue;
      if(g_zones[i].orderTicket == 0 || !OrderSelect(g_zones[i].orderTicket))
         continue;
      return true;
   }
   return false;
}

void HandoffTrail()
{
   if(InpHandoffMode == HANDOFF_OFF || PositionsTotal() == 0)
   {
      g_hoPending = false;
      return;
   }

   double minDist = BrokerMinDist();
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // a new QM just filled: close opposite trades that are in profit
   if(g_hoPending)
   {
      g_hoPending = false;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PositionSelectByTicket(ticket))
            continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;
         if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
            continue;

         ulong pid = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
         if(pid == g_hoPid)
            continue;
         int pdir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? DIR_BUY : DIR_SELL);
         if(pdir != -g_hoDir)
            continue;

         int ti = TrackIndex(pid);
         if(ti < 0 || g_trk[ti].risk <= 0.0)
            continue;

         double open = PositionGetDouble(POSITION_PRICE_OPEN);
         double px = (pdir == DIR_BUY ? bid : ask);
         double floating = pdir * (px - open);
         if(floating < InpHandoffMinProfitR * g_trk[ti].risk)
            continue;

         trade.SetDeviationInPoints(DeviationPts());
         if(trade.PositionClose(ticket))
         {
            g_handoffs++;
            DebugPrint("HANDOFF_CLOSE", StringFormat("ticket=%I64u closed at %.2fR for the new opposite QM",
                                                      ticket, floating / g_trk[ti].risk));
         }
      }
   }

   // an opposite QM is pending: lock a share of the peak profit (never loosened)
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      ulong pid = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
      int ti = TrackIndex(pid);
      if(ti < 0)
         continue;

      int dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? DIR_BUY : DIR_SELL);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      double risk = g_trk[ti].risk;
      if(risk <= 0.0)
         continue;

      double peak = dir * (g_trk[ti].best - open);
      if(peak < InpHandoffMinProfitR * risk)
         continue;
      if(!OppositePendingExists(dir))
         continue;

      double newSL = RoundTick(open + dir * (InpHandoffLockPct / 100.0) * peak);
      if(sl > 0.0 && dir * (newSL - sl) < 0.05 * risk)
         continue;
      if(dir == DIR_BUY && newSL > bid - minDist)
         continue;
      if(dir == DIR_SELL && newSL < ask + minDist)
         continue;

      if(trade.PositionModify(ticket, newSL, tp))
         DebugPrint("HANDOFF_LOCK", StringFormat("ticket=%I64u SL %.5f locks %.0f%% of peak %.2fR",
                                                  ticket, newSL, InpHandoffLockPct, peak / risk));
   }
}

string EndStateText(const int state)
{
   switch(state)
   {
      case Z_USED:    return "USED";
      case Z_MISSED:  return "MISSED";
      case Z_EXPIRED: return "EXPIRED";
      case Z_BLOCKED: return "BLOCKED";
   }
   return "ENDED";
}

bool MarketOpenNow()
{
   MqlDateTime dt;
   TimeToStruct(TimeTradeServer(), dt);
   long sec = dt.hour * 3600 + dt.min * 60 + dt.sec;

   datetime from = 0, to = 0;
   bool anySession = false;
   for(int i = 0; i < 12; i++)
   {
      if(!SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)dt.day_of_week, i, from, to))
         break;
      anySession = true;
      long buf = (long)InpMarketEdgeBufferMin * 60;
      long lo = ((long)from > 0 ? (long)from + buf : (long)from);
      long hi = ((long)to < 86400 ? (long)to - buf : (long)to);
      if(sec >= lo && sec < hi)
         return true;
   }
   return !anySession;   // no session data: assume open
}

//--- chart marks -----------------------------------------------------
string MarkBase(const string key)
{
   return g_prefix + "P_" + key;
}

void DeleteMark(const string key)
{
   string b = MarkBase(key);
   string suffix[4] = {"_a", "_b", "_c", "_t"};
   for(int i = 0; i < 4; i++)
      if(ObjectFind(0, b + suffix[i]) >= 0)
         ObjectDelete(0, b + suffix[i]);
}

void MarkStatus(const string key, const string status)
{
   if(!InpMarkPatterns)
      return;
   string nm = MarkBase(key) + "_t";
   if(ObjectFind(0, nm) < 0)
      return;
   string baseText = ObjectGetString(0, nm, OBJPROP_TOOLTIP);
   ObjectSetString(0, nm, OBJPROP_TEXT, baseText + " | " + status);
}

void DrawPatternMarks(const PatInfo &pi)
{
   if(!InpMarkPatterns)
      return;

   int cap = MathMax(10, MathMin(200, InpMaxMarks));
   int slot = g_markCount % cap;
   if(g_markCount >= cap && g_markKeys[slot] != "")
      DeleteMark(g_markKeys[slot]);
   g_markKeys[slot] = pi.key;
   g_markCount++;

   string b = MarkBase(pi.key);
   color col = (pi.dir == DIR_BUY ? clrDodgerBlue : clrOrangeRed);

   string names[3];
   names[0] = b + "_a";
   names[1] = b + "_b";
   names[2] = b + "_c";

   ObjectCreate(0, names[0], OBJ_TREND, 0, pi.tLs, pi.pLs, pi.tH2, pi.pH2);
   ObjectCreate(0, names[1], OBJ_TREND, 0, pi.tH2, pi.pH2, pi.tHead, pi.pHead);
   ObjectCreate(0, names[2], OBJ_TREND, 0, pi.tHead, pi.pHead, pi.tBos, pi.pBos);

   for(int i = 0; i < 3; i++)
   {
      ObjectSetInteger(0, names[i], OBJPROP_COLOR, col);
      ObjectSetInteger(0, names[i], OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, names[i], OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, names[i], OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, names[i], OBJPROP_BACK, true);
   }

   string nm = b + "_t";
   string baseText = StringFormat("%s %s %s", g_prof[pi.p].name, DirName(pi.dir), SetupName(pi.setup));
   ObjectCreate(0, nm, OBJ_TEXT, 0, pi.tHead, pi.pHead);
   ObjectSetString(0, nm, OBJPROP_TOOLTIP, baseText);
   ObjectSetString(0, nm, OBJPROP_TEXT, baseText + " | found");
   ObjectSetInteger(0, nm, OBJPROP_COLOR, col);
   ObjectSetInteger(0, nm, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
}

void LogPatternCSV(const PatInfo &pi, const string decision)
{
   if(!InpLogPatternsCSV)
      return;

   string fn = StringFormat("STRUXA_v323_patterns_%s.csv", _Symbol);
   int h = FileOpen(fn, FILE_READ | FILE_WRITE | FILE_CSV | FILE_COMMON | FILE_ANSI, ';');
   if(h == INVALID_HANDLE)
      return;

   if(FileSize(h) == 0)
      FileWrite(h, "time", "symbol", "profile", "dir", "tag", "decision",
                "bars_Ls_H2", "bars_H2_head", "bars_head_BOS", "bars_Ls_BOS", "BOS_age_bars",
                "leg_Ls_H2_ATR", "leg_H2_head_ATR", "undercut_ATR", "risk_at_QML_ATR",
                "score", "entry", "sl", "tp", "wide_entry");

   FileSeek(h, 0, SEEK_END);
   int dg = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   FileWrite(h,
             TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES), _Symbol, g_prof[pi.p].name,
             DirName(pi.dir), SetupName(pi.setup), decision,
             pi.barsLsH2, pi.barsH2Head, pi.barsHeadBos, pi.barsLsH2 + pi.barsH2Head + pi.barsHeadBos, pi.bosAge,
             DoubleToString(pi.legLsH2ATR, 2), DoubleToString(pi.legH2HeadATR, 2),
             DoubleToString(pi.undercutATR, 2), DoubleToString(pi.riskQmlATR, 2),
             pi.score, DoubleToString(pi.entry, dg), DoubleToString(pi.sl, dg), DoubleToString(pi.tp, dg),
             pi.alt);
   FileClose(h);
}

void EndPattern(const PatInfo &pi, const string decision)
{
   LogPatternCSV(pi, decision);
   MarkStatus(pi.key, decision);
   VTSetDecision(pi.key, decision, pi.score);
}

//--- wide-pattern entry helpers ----------------------------------------
// last opposite-colour candle before the displacement that broke structure
bool FindOB(const int dir, const MqlRates &r[], const int hs, const int bos, double &obHigh, double &obLow)
{
   for(int s = bos + 1; s <= hs; s++)
   {
      bool opposite = (dir == DIR_BUY ? r[s].close < r[s].open : r[s].close > r[s].open);
      if(opposite)
      {
         obHigh = r[s].high;
         obLow  = r[s].low;
         return true;
      }
   }
   return false;
}

// first minor swing after the head that sits between the head and the left shoulder
bool FindMinorBOS(const int dir, const MqlRates &r[], const int hs, const int bos,
                  const double headP, const double lsP, double &level)
{
   for(int s = hs - 1; s >= bos + 1 && s >= 2; s--)
   {
      bool isSwing = (dir == DIR_BUY ? (r[s].high > r[s + 1].high && r[s].high > r[s - 1].high)
                                     : (r[s].low < r[s + 1].low && r[s].low < r[s - 1].low));
      if(!isSwing)
         continue;
      double lvl = (dir == DIR_BUY ? r[s].high : r[s].low);
      if(dir * (lsP - lvl) > 0.0 && dir * (lvl - headP) > 0.0)
      {
         level = lvl;
         return true;
      }
   }
   return false;
}

bool AltEntryValid(const int dir, const double e, const double entryQml, const double headP, const double aNow)
{
   return (dir * (entryQml - e) > 0.25 * aNow &&
           dir * (e - headP) > 0.5 * InpSLBufferATR * aNow);
}

void TryPattern(const int p, const int dir, const Pivot &piv[], const int pc,
                const MqlRates &r[], const double &atr[],
                const double &rsi[], const double &macd[])
{
   double undercutReq = g_prof[p].undercutATR;
   double breakReq    = g_prof[p].breakATR;
   int minA = (InpRequirePriorTrend ? 1 : 0);

   // candidate pairs: Ls (low for buy) at pa, H2 (high for buy) at pa + 1
   for(int pa = pc - 2; pa >= minA && pa >= pc - 9; pa--)
   {
      if(g_zoneCount >= InpMaxZones)
         return;

      if(piv[pa].type != -dir || piv[pa + 1].type != dir)
         continue;

      int    ls    = piv[pa].shift;
      int    h2s   = piv[pa + 1].shift;
      double lsP   = piv[pa].price;
      double h2P   = piv[pa + 1].price;

      // the head
      int    hs    = -1;
      double headP = 0.0;

      if(InpProvisionalHead)
      {
         // most extreme bar after H2 up to the last closed bar: no waiting for a fractal
         for(int s = h2s - 1; s >= 1; s--)
         {
            double v = (dir == DIR_BUY ? r[s].low : r[s].high);
            if(hs < 0 || (dir == DIR_BUY ? v < headP : v > headP))
            {
               hs = s;
               headP = v;
            }
         }
      }
      else
      {
         if(pa + 2 >= pc || piv[pa + 2].type != -dir)
            continue;
         hs = piv[pa + 2].shift;
         headP = piv[pa + 2].price;
      }
      if(hs < 1)
         continue;

      double aH = atr[hs];
      if(aH <= 0.0)
         continue;

      string key = StringFormat("%s_%d_%I64d", DirChar(dir), p, (long)r[hs].time);
      if(KeySeen(key))
         continue;

      // head must undercut (buy) / overshoot (sell) the left shoulder
      double undercut = dir * (lsP - headP);
      if(undercut < undercutReq * aH)
         continue;

      // prior trend: lower high before Ls (buy) / higher low before Ls (sell)
      if(InpRequirePriorTrend && dir * (piv[pa - 1].price - h2P) <= 0.0)
         continue;

      // classic mode only: the head pivot must still be the extreme
      if(!InpProvisionalHead)
      {
         bool headOK = true;
         for(int s = hs - 1; s >= 1; s--)
         {
            if(dir == DIR_BUY && r[s].low < headP)
            {
               headOK = false;
               break;
            }
            if(dir == DIR_SELL && r[s].high > headP)
            {
               headOK = false;
               break;
            }
         }
         if(!headOK)
            continue;
      }

      // break of structure: a close beyond H2 on this profile's timeframe
      int bos = -1;
      for(int s = hs - 1; s >= 1; s--)
      {
         double ab = atr[s];
         if(ab <= 0.0)
            ab = aH;
         double lvl = h2P + dir * breakReq * ab;
         if(dir * (r[s].close - lvl) > 0.0)
         {
            bos = s;
            break;
         }
      }
      if(bos < 0)
         continue;

      AddSeenKey(key);

      // head candle features
      double hi = r[hs].high;
      double lo = r[hs].low;
      double op = r[hs].open;
      double cl = r[hs].close;
      double range = hi - lo;
      double body  = MathAbs(cl - op);
      double wick  = (dir == DIR_BUY ? MathMin(op, cl) - lo : hi - MathMax(op, cl));
      double wickR = (range > 0.0 ? wick / range : 0.0);
      double bodyR = (range > 0.0 ? body / range : 0.0);
      double rangeATR = range / aH;

      bool rsiDiv = false;
      bool macdDiv = false;
      if(InpUseRSIDivergence)
         rsiDiv = (dir == DIR_BUY ? rsi[hs] > rsi[ls] : rsi[hs] < rsi[ls]);
      if(InpUseMACDDivergence)
         macdDiv = (dir == DIR_BUY ? macd[hs] > macd[ls] : macd[hs] < macd[ls]);

      int setup = ClassifySetup(rangeATR, wickR, bodyR, rsiDiv, macdDiv);
      int si = StatsIndex(setup, dir, p);

      double aNow = atr[1];
      if(aNow <= 0.0)
         aNow = aH;
      double aB = atr[bos];
      if(aB <= 0.0)
         aB = aNow;

      int s1 = BiasSign(g_ema1, InpBiasTF1);
      int s2 = BiasSign(g_ema2, InpBiasTF2);

      MqlDateTime dtn;
      TimeToStruct(TimeCurrent(), dtn);

      PatInfo pi;
      pi.key = key;
      pi.p = p;
      pi.dir = dir;
      pi.setup = setup;
      pi.tLs = r[ls].time;
      pi.pLs = lsP;
      pi.tH2 = r[h2s].time;
      pi.pH2 = h2P;
      pi.tHead = r[hs].time;
      pi.pHead = headP;
      pi.tBos = r[bos].time;
      pi.pBos = r[bos].close;
      pi.barsLsH2 = ls - h2s;
      pi.barsH2Head = h2s - hs;
      pi.barsHeadBos = hs - bos;
      pi.bosAge = bos;
      pi.wickR = wickR;
      pi.rangeATR = rangeATR;
      pi.rsiDiv = (rsiDiv ? 1 : 0);
      pi.macdDiv = (macdDiv ? 1 : 0);
      pi.bias1 = s1;
      pi.bias2 = s2;
      pi.hour = dtn.hour;
      pi.legLsH2ATR = MathAbs(h2P - lsP) / aH;
      pi.legH2HeadATR = MathAbs(h2P - headP) / aH;
      pi.undercutATR = undercut / aH;
      pi.riskQmlATR = 0.0;
      pi.score = 0;
      pi.entry = 0.0;
      pi.sl = 0.0;
      pi.tp = 0.0;
      pi.alt = "";
      CrtCtxZero(pi.ctx);

      DrawPatternMarks(pi);

      if(bos > g_prof[p].maxBarsAfterBreak || (hs - bos) > g_prof[p].maxHeadToBreak)
      {
         g_rej[p][REJ_STALE]++;
         EndPattern(pi, "STALE (break too old)");
         continue;
      }

      g_stats[si].found++;

      if(!FamilyEnabled(setup))
      {
         g_stats[si].rejected++;
         g_rej[p][REJ_DISABLED]++;
         DebugPrint("REJECTED_DISABLED", g_stats[si].tag);
         EndPattern(pi, "REJ family off");
         continue;
      }

      // levels at the QM level (left shoulder)
      double entry0  = lsP + dir * InpEntryOffsetATR * aNow;
      double sl      = headP - dir * InpSLBufferATR * aNow;
      double risk0   = dir * (entry0 - sl);
      double minRisk = g_prof[p].minRiskATR * aNow;
      double maxRisk = g_prof[p].maxRiskATR * aNow;
      double riskQ   = MathMax(risk0, minRisk);
      double tpQml   = entry0 + dir * riskQ * g_prof[p].targetRR;
      pi.riskQmlATR  = risk0 / aNow;

      // wide pattern: enter deeper, near the head, with the same stop
      double entry = entry0;
      string altKind = "";
      if(InpWideEntryMode != WIDE_OFF && risk0 > InpWideTriggerATR * aNow)
      {
         double altE = 0.0;
         string kind = "";

         if(InpWideEntryMode == WIDE_OB || InpWideEntryMode == WIDE_AUTO)
         {
            double obH = 0.0, obL = 0.0;
            if(FindOB(dir, r, hs, bos, obH, obL))
            {
               double e = (dir == DIR_BUY ? obH - InpOBEntryDepth * (obH - obL)
                                          : obL + InpOBEntryDepth * (obH - obL));
               if(AltEntryValid(dir, e, entry0, headP, aNow))
               {
                  altE = e;
                  kind = "OB";
               }
            }
         }
         if(kind == "" && (InpWideEntryMode == WIDE_MINOR_BOS || InpWideEntryMode == WIDE_AUTO))
         {
            double lvl = 0.0;
            if(FindMinorBOS(dir, r, hs, bos, headP, lsP, lvl))
            {
               double e = lvl + dir * InpEntryOffsetATR * aNow;
               if(AltEntryValid(dir, e, entry0, headP, aNow))
               {
                  altE = e;
                  kind = "MINOR_BOS";
               }
            }
         }
         if(kind != "")
         {
            entry = altE;
            altKind = kind;
         }
      }

      double risk = dir * (entry - sl);
      if(risk < minRisk)
      {
         risk = minRisk;
         sl = entry - dir * risk;
      }
      if(dir * (h2P - entry) <= 0.0)
      {
         g_stats[si].rejected++;
         g_rej[p][REJ_GEOMETRY]++;
         DebugPrint("REJECTED_GEOMETRY", g_stats[si].tag + " entry beyond H2");
         EndPattern(pi, "REJ geometry");
         continue;
      }

      entry = RoundTick(entry);
      sl    = RoundTick(sl);

      double tp = 0.0;
      if(altKind != "" && InpWideKeepTP)
      {
         tp = tpQml;
         double rrAlt = dir * (tp - entry) / MathAbs(entry - sl);
         if(rrAlt > InpWideMaxRR)
            tp = entry + dir * MathAbs(entry - sl) * InpWideMaxRR;
      }
      else
         tp = entry + dir * MathAbs(entry - sl) * g_prof[p].targetRR;
      tp = RoundTick(tp);

      pi.entry = entry;
      pi.sl = sl;
      pi.tp = tp;
      pi.alt = altKind;
      CrtContext(dir, entry, headP, r[hs].time, pi.ctx);

      string tpHow = "RR";
      if(InpTpMode != TP_RR)
      {
         double tpAlt = 0.0;
         string how = "";
         if(PickTp(dir, entry, sl, pi.ctx, piv, pc, r, tpAlt, how))
         {
            tp = RoundTick(tpAlt);
            tpHow = how;
            pi.tp = tp;
         }
      }

      // first retest already happened after the break: do not chase
      if(TouchedSince(dir, r, bos, entry))
      {
         g_stats[si].missed++;
         g_rej[p][REJ_RETESTED]++;
         DebugPrint("MISSED", StringFormat("%s already retested entry %.5f", g_stats[si].tag, entry));
         EndPattern(pi, "MISSED already retested");
         continue;
      }

      // study logger: virtual trades for the entry the EA would use, plus the QM level for comparison
      if(altKind != "")
      {
         VTAdd(pi, altKind, entry, sl, aNow);
         if(!TouchedSince(dir, r, bos, entry0))
            VTAdd(pi, "QML", RoundTick(entry0), RoundTick(entry0 - dir * riskQ), aNow);
      }
      else
         VTAdd(pi, "QML", entry, sl, aNow);

      if(risk > maxRisk)
      {
         g_stats[si].rejected++;
         g_rej[p][REJ_RISK]++;
         DebugPrint("REJECTED_RISK", StringFormat("%s risk %.5f > cap %.5f", g_stats[si].tag, risk, maxRisk));
         EndPattern(pi, "REJ SL too wide");
         continue;
      }

      // bias
      int aligned = (s1 == dir ? 1 : 0) + (s2 == dir ? 1 : 0);
      int opposed = (s1 == -dir ? 1 : 0) + (s2 == -dir ? 1 : 0);
      int biasPts = 0;

      if(InpBiasMode == BIAS_OFF)
         biasPts = InpBiasAlignedPoints;
      else
         biasPts = aligned * InpBiasAlignedPoints / 2 - opposed * InpBiasOpposedPenalty / 2;

      if(InpBiasMode == BIAS_STRICT && !(s1 == dir && s2 != -dir))
      {
         g_stats[si].rejected++;
         g_rej[p][REJ_BIAS]++;
         DebugPrint("REJECTED_BIAS", StringFormat("%s H1=%d H4=%d", g_stats[si].tag, s1, s2));
         EndPattern(pi, StringFormat("REJ bias H1=%d H4=%d", s1, s2));
         continue;
      }

      // CRT rules: sweep QM, in-range QM, daily zone, H4 trend, lower-TF CRT
      bool sweepQm = false;
      bool inRangeQm = false;
      string gateWhy = CrtGate(dir, pi.ctx, sweepQm, inRangeQm);
      if(gateWhy != "")
      {
         g_stats[si].rejected++;
         g_rej[p][REJ_CRT]++;
         DebugPrint("REJECTED_CRT", StringFormat("%s %s", g_stats[si].tag, gateWhy));
         EndPattern(pi, "REJ CRT: " + gateWhy);
         continue;
      }

      // score
      int score = 50 + biasPts;
      if(rsiDiv)
         score += 8;
      if(macdDiv)
         score += 8;
      if(undercut >= 0.5 * aH)
         score += 5;
      if(wickR >= 0.35)
         score += 5;
      double brk = dir * (r[bos].close - h2P) / aB;
      if(brk >= 0.30)
         score += 6;
      score = MathMax(0, MathMin(100, score));
      pi.score = score;

      if(score < g_prof[p].minScore)
      {
         g_stats[si].rejected++;
         g_rej[p][REJ_SCORE]++;
         DebugPrint("REJECTED_SCORE", StringFormat("%s @ %.5f S=%d min=%d", g_stats[si].tag, entry, score, g_prof[p].minScore));
         EndPattern(pi, StringFormat("REJ score %d < %d", score, g_prof[p].minScore));
         continue;
      }

      // no second zone near an existing one on the same side (covers M15 vs M5 overlap)
      double dupDist = InpDupDistATR * MathMax(aNow, ATRNow());
      if(ZoneNear(dir, entry, dupDist))
      {
         g_stats[si].rejected++;
         g_rej[p][REJ_DUP]++;
         DebugPrint("REJECTED_DUP", StringFormat("%s @ %.5f", g_stats[si].tag, entry));
         EndPattern(pi, "REJ duplicate");
         continue;
      }

      // register
      int life = (InpExpiryMode == EXPIRY_STRUCTURE ? g_prof[p].maxLifeBars : g_prof[p].expiryBars);

      Zone z;
      z.id          = g_nextZoneId;
      z.key         = key;
      z.direction   = dir;
      z.setupType   = setup;
      z.prof        = p;
      z.state       = Z_ARMED;
      z.score       = score;
      z.headTime    = r[hs].time;
      z.createdTime = TimeCurrent();
      z.expiryTime  = TimeCurrent() + PeriodSeconds(g_prof[p].tf) * life;
      z.retryAfter  = 0;
      z.entry       = entry;
      z.sl          = sl;
      z.tp          = tp;
      z.rr          = (MathAbs(entry - sl) > 0.0 ? MathAbs(tp - entry) / MathAbs(entry - sl) : 0.0);
      z.atr         = aNow;
      z.blocks      = 0;
      z.lastBlock   = "";
      z.lastBlockCat = -1;
      z.confirmed   = false;
      z.touchBars   = 0;
      z.orderTicket = 0;
      z.alt         = (altKind != "");
      z.altKind     = altKind;
      z.crtC1       = pi.ctx.h4C1;
      z.trigger     = sweepQm;
      z.tpHow       = tpHow;

      g_zones[g_zoneCount] = z;
      g_zoneCount++;
      g_nextZoneId++;
      g_stats[si].registered++;
      if(sweepQm && pi.ctx.h4Idx >= 0)
      {
         g_crt[pi.ctx.h4Idx].triggered = true;
         g_crt[pi.ctx.h4Idx].trigDir = dir;
      }
      if(sweepQm)
         g_trigQm++;
      else if(inRangeQm)
         g_inRangeQm++;
      QmHistAdd(z.id, dir, entry, pi.ctx.h4C1);
      if(altKind != "")
         g_altCount[p]++;

      DebugPrint("REGISTERED",
                 StringFormat("%s id=%I64u entry=%.5f sl=%.5f tp=%.5f S=%d RR=%.2f H1=%d H4=%d zones=%d%s",
                              g_stats[si].tag, z.id, entry, sl, tp, score, z.rr, s1, s2, g_zoneCount,
                              (altKind != "" ? " wide-entry=" + altKind : "") + " tpBy=" + tpHow +
                              (sweepQm ? " SWEEP_QM" : (inRangeQm ? " IN_RANGE_QM" : ""))));
      EndPattern(pi, StringFormat("ARMED S=%d RR=%.1f%s", score, z.rr,
                                  (altKind != "" ? " (" + altKind + " entry)" : "")));
   }
}

void ScanForSetups(const int p)
{
   if(g_zoneCount >= InpMaxZones)
      return;

   int lr = MathMax(2, g_prof[p].lr);
   int need = MathMax(g_prof[p].lookback, 60) + lr + 5;

   MqlRates r[];
   ArraySetAsSeries(r, true);
   int n = CopyRates(_Symbol, g_prof[p].tf, 0, need, r);
   if(n < 40 + 2 * lr)
      return;

   double atr[], rsi[], macd[];
   ArraySetAsSeries(atr, true);
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(macd, true);

   int na = CopyBuffer(g_prof[p].hAtr, 0, 0, n, atr);
   int nr = CopyBuffer(g_prof[p].hRsi, 0, 0, n, rsi);
   int nm = CopyBuffer(g_prof[p].hMacd, 0, 0, n, macd);
   n = MathMin(n, MathMin(na, MathMin(nr, nm)));
   if(n < 40 + 2 * lr)
      return;

   Pivot piv[];
   int pc = 0;

   for(int i = n - 1 - lr; i >= lr + 1; i--)
   {
      double a = atr[i];
      if(a <= 0.0)
         continue;
      double minAmp = g_prof[p].minSwingATR * a;

      if(IsFractal(r, i, lr, true))
         AddPivot(piv, pc, i, r[i].high, 1, minAmp);
      if(IsFractal(r, i, lr, false))
         AddPivot(piv, pc, i, r[i].low, -1, minAmp);
   }

   if(pc < 4)
      return;

   TryPattern(p, DIR_BUY, piv, pc, r, atr, rsi, macd);
   TryPattern(p, DIR_SELL, piv, pc, r, atr, rsi, macd);
}

//+------------------------------------------------------------------+
//| Execution                                                        |
//+------------------------------------------------------------------+
void TempBlock(const int index, const string reason, const int cat)
{
   if(index < 0 || index >= g_zoneCount)
      return;

   bool changed = (g_zones[index].lastBlockCat != cat);

   g_zones[index].retryAfter = iTime(_Symbol, InpExecutionTF, 0) + PeriodSeconds(InpExecutionTF);
   g_zones[index].blocks++;
   g_zones[index].lastBlock = reason;
   g_zones[index].lastBlockCat = cat;
   g_lastSkip = reason;

   if(changed)
   {
      if(cat >= 0 && cat < BLK_COUNT)
         g_blk[g_zones[index].prof][cat]++;
      DebugPrint("BLOCKED_TEMP",
                 StringFormat("%s_%s id=%I64u %s",
                              DirName(g_zones[index].direction),
                              SetupName(g_zones[index].setupType),
                              g_zones[index].id, reason));
   }
}

// gates that do not depend on how many trades are open
string GateReason(const Zone &z, int &cat)
{
   string why = "";
   cat = -1;

   if(EntriesBlocked(why))
   {
      cat = BLK_GUARD;
      return why;
   }
   if(!TradeModeAllows(z.direction, why))
   {
      cat = BLK_MODE;
      return why;
   }
   if(!MarketOpenNow())
   {
      cat = BLK_CLOSED;
      return "market closed";
   }
   if(!SessionAllowed())
   {
      cat = BLK_SESSION;
      return "session";
   }
   if(InpBiasMode == BIAS_STRICT && !BiasPassesStrict(z.direction))
   {
      cat = BLK_BIAS;
      return "bias";
   }
   return "";
}

string CommonBlockReason(const Zone &z, int &cat)
{
   string why = GateReason(z, cat);
   if(why != "")
      return why;

   if(CountLive(z.direction) >= InpMaxPerDirection)
   {
      cat = BLK_MAXDIR;
      return "max per direction";
   }
   if(CountLive(0) >= InpMaxTotalOpen)
   {
      cat = BLK_MAXTOTAL;
      return "max total";
   }

   return "";
}

bool SendOrderForZone(const int index)
{
   if(index < 0 || index >= g_zoneCount)
      return false;

   int blockCat = -1;
   string why = CommonBlockReason(g_zones[index], blockCat);
   if(why != "")
   {
      TempBlock(index, why, blockCat);
      return false;
   }

   Zone z = g_zones[index];

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
      return false;

   double minDist = BrokerMinDist();
   double risk = MathAbs(z.entry - z.sl);

   // price already at or through the level: missed
   if(z.direction == DIR_BUY && ask <= z.entry + minDist)
   {
      RemoveZone(index, Z_MISSED, "price at entry before order");
      return false;
   }
   if(z.direction == DIR_SELL && bid >= z.entry - minDist)
   {
      RemoveZone(index, Z_MISSED, "price at entry before order");
      return false;
   }

   if(risk < minDist * 1.5 || MathAbs(z.tp - z.entry) < minDist)
   {
      RemoveZone(index, Z_BLOCKED, "stops inside broker minimum distance");
      return false;
   }

   double spread = ask - bid;
   if(spread > InpMaxSpreadPctOfRisk / 100.0 * risk)
   {
      TempBlock(index, StringFormat("spread %.5f > %.1f%% of risk", spread, InpMaxSpreadPctOfRisk), BLK_SPREAD);
      return false;
   }

   string lotReason = "";
   double lot = CalcLot(z.entry, z.sl, lotReason);
   if(lot <= 0.0)
   {
      TempBlock(index, "volume blocked: " + lotReason, BLK_VOLUME);
      return false;
   }

   if(InpMaxOpenRiskPct > 0.0)
   {
      double newRisk = LotRiskMoney(lot, z.entry, z.sl);
      double budget = AccountInfoDouble(ACCOUNT_BALANCE) * InpMaxOpenRiskPct / 100.0;
      double openRisk = OpenRiskMoney(z.direction);
      if(openRisk + newRisk > budget)
      {
         TempBlock(index, StringFormat("open-risk budget %.2f + %.2f > %.2f", openRisk, newRisk, budget), BLK_RISKBUDGET);
         return false;
      }
   }

   double margin = 0.0;
   ENUM_ORDER_TYPE mt = (z.direction == DIR_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   if(OrderCalcMargin(mt, _Symbol, lot, z.entry, margin))
   {
      double freeM = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      if(margin > freeM * InpMaxMarginUsePct / 100.0)
      {
         TempBlock(index, StringFormat("margin %.2f > %.0f%% of free %.2f", margin, InpMaxMarginUsePct, freeM), BLK_MARGIN);
         return false;
      }
   }

   string comment = StringFormat("S323|%s|%s|%I64u|%d|%d",
                                 SetupName(z.setupType), DirChar(z.direction), z.id, z.score, z.prof);

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(DeviationPts());

   bool ok = false;
   datetime expiry = z.expiryTime;
   if(expiry <= TimeCurrent() + 60)
      expiry = TimeCurrent() + 60;

   if(z.direction == DIR_BUY)
      ok = trade.BuyLimit(lot, z.entry, _Symbol, z.sl, z.tp, ORDER_TIME_SPECIFIED, expiry, comment);
   else
      ok = trade.SellLimit(lot, z.entry, _Symbol, z.sl, z.tp, ORDER_TIME_SPECIFIED, expiry, comment);

   if(!ok && (int)trade.ResultRetcode() == 10022)
   {
      // broker rejects expiration: send GTC, expiry is enforced in ManageZones
      if(z.direction == DIR_BUY)
         ok = trade.BuyLimit(lot, z.entry, _Symbol, z.sl, z.tp, ORDER_TIME_GTC, 0, comment);
      else
         ok = trade.SellLimit(lot, z.entry, _Symbol, z.sl, z.tp, ORDER_TIME_GTC, 0, comment);
   }

   if(!ok)
   {
      int rc = (int)trade.ResultRetcode();
      string msg = StringFormat("ordersend failed rc=%d %s", rc, trade.ResultRetcodeDescription());
      if(rc == 10044)
      {
         RemoveZone(index, Z_BLOCKED, msg);
         return false;
      }
      TempBlock(index, msg, BLK_ORDER);
      return false;
   }

   g_zones[index].state = Z_TRIGGERED;
   g_zones[index].orderTicket = trade.ResultOrder();
   g_stats[StatsIndex(z.setupType, z.direction, z.prof)].sent++;

   DebugPrint("ORDER_SENT",
              StringFormat("%s id=%I64u lot=%.2f entry=%.5f sl=%.5f tp=%.5f S=%d ticket=%I64u",
                           g_stats[StatsIndex(z.setupType, z.direction, z.prof)].tag, z.id, lot,
                           z.entry, z.sl, z.tp, z.score, trade.ResultOrder()));
   return true;
}

void CheckConfirmations()
{
   if(InpEntryMode != ENTRY_CONFIRM || g_zoneCount == 0)
      return;

   datetime barOpen = iTime(_Symbol, InpExecutionTF, 1);
   double o = iOpen(_Symbol, InpExecutionTF, 1);
   double h = iHigh(_Symbol, InpExecutionTF, 1);
   double l = iLow(_Symbol, InpExecutionTF, 1);
   double c = iClose(_Symbol, InpExecutionTF, 1);
   if(barOpen <= 0 || h <= l)
      return;
   double range = h - l;

   for(int i = g_zoneCount - 1; i >= 0; i--)
   {
      if(g_zones[i].state != Z_ARMED || g_zones[i].confirmed)
         continue;
      if(barOpen < g_zones[i].createdTime)
         continue;

      int    dir   = g_zones[i].direction;
      double entry = g_zones[i].entry;
      double sl    = g_zones[i].sl;
      double a     = g_zones[i].atr;

      // level lost: stop zone reached, or a close well through the level
      bool lost = false;
      if(dir == DIR_BUY)
         lost = (l <= sl || c < entry - InpConfirmMaxBreakATR * a);
      else
         lost = (h >= sl || c > entry + InpConfirmMaxBreakATR * a);
      if(lost)
      {
         RemoveZone(i, Z_MISSED, "level lost before confirmation");
         continue;
      }

      bool touched = (dir == DIR_BUY ? l <= entry : h >= entry);
      if(!touched)
         continue;

      double wick  = (dir == DIR_BUY ? MathMin(o, c) - l : h - MathMax(o, c));
      double wickR = wick / range;

      bool dirClose = false;
      if(dir == DIR_BUY)
         dirClose = (c > entry && (!InpConfirmRequireDirClose || c > o));
      else
         dirClose = (c < entry && (!InpConfirmRequireDirClose || c < o));

      if(dirClose && wickR >= InpConfirmMinWickRatio)
      {
         g_zones[i].confirmed = true;
         DebugPrint("CONFIRMED",
                    StringFormat("%s id=%I64u level=%.5f candle close=%.5f wick=%.2f",
                                 g_stats[StatsIndex(g_zones[i].setupType, dir, g_zones[i].prof)].tag,
                                 g_zones[i].id, entry, c, wickR));
         continue;
      }

      g_zones[i].touchBars++;
      if(g_zones[i].touchBars >= InpConfirmWaitBars)
         RemoveZone(i, Z_EXPIRED, "no confirmation after touching the level");
   }
}

bool SendMarketForZone(const int index)
{
   if(index < 0 || index >= g_zoneCount)
      return false;

   int blockCat = -1;
   string why = CommonBlockReason(g_zones[index], blockCat);
   if(why != "")
   {
      TempBlock(index, why, blockCat);
      return false;
   }

   Zone z = g_zones[index];

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
      return false;

   double minDist = BrokerMinDist();
   double px = (z.direction == DIR_BUY ? ask : bid);

   if(MathAbs(px - z.entry) > InpConfirmMaxChaseATR * z.atr)
   {
      RemoveZone(index, Z_MISSED, "price ran from the level after confirmation");
      return false;
   }

   double risk = z.direction * (px - z.sl);
   if(risk < minDist * 1.5)
   {
      RemoveZone(index, Z_BLOCKED, "stop too close to market");
      return false;
   }
   if(risk > g_prof[z.prof].maxRiskATR * z.atr)
   {
      RemoveZone(index, Z_MISSED, "risk too wide at confirmation price");
      return false;
   }

   double tp = RoundTick(px + z.direction * risk * g_prof[z.prof].targetRR);

   double spread = ask - bid;
   if(spread > InpMaxSpreadPctOfRisk / 100.0 * risk)
   {
      TempBlock(index, StringFormat("spread %.5f > %.1f%% of risk", spread, InpMaxSpreadPctOfRisk), BLK_SPREAD);
      return false;
   }

   string lotReason = "";
   double lot = CalcLot(px, z.sl, lotReason);
   if(lot <= 0.0)
   {
      TempBlock(index, "volume blocked: " + lotReason, BLK_VOLUME);
      return false;
   }

   if(InpMaxOpenRiskPct > 0.0)
   {
      double newRisk = LotRiskMoney(lot, px, z.sl);
      double budget = AccountInfoDouble(ACCOUNT_BALANCE) * InpMaxOpenRiskPct / 100.0;
      double openRisk = OpenRiskMoney(z.direction);
      if(openRisk + newRisk > budget)
      {
         TempBlock(index, StringFormat("open-risk budget %.2f + %.2f > %.2f", openRisk, newRisk, budget), BLK_RISKBUDGET);
         return false;
      }
   }

   double margin = 0.0;
   ENUM_ORDER_TYPE mt = (z.direction == DIR_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   if(OrderCalcMargin(mt, _Symbol, lot, px, margin))
   {
      double freeM = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      if(margin > freeM * InpMaxMarginUsePct / 100.0)
      {
         TempBlock(index, StringFormat("margin %.2f > %.0f%% of free %.2f", margin, InpMaxMarginUsePct, freeM), BLK_MARGIN);
         return false;
      }
   }

   string comment = StringFormat("S323|%s|%s|%I64u|%d|%d",
                                 SetupName(z.setupType), DirChar(z.direction), z.id, z.score, z.prof);

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(DeviationPts());

   bool ok = false;
   if(z.direction == DIR_BUY)
      ok = trade.Buy(lot, _Symbol, 0.0, z.sl, tp, comment);
   else
      ok = trade.Sell(lot, _Symbol, 0.0, z.sl, tp, comment);

   if(!ok)
   {
      int rc = (int)trade.ResultRetcode();
      string msg = StringFormat("market order failed rc=%d %s", rc, trade.ResultRetcodeDescription());
      if(rc == 10044)
      {
         RemoveZone(index, Z_BLOCKED, msg);
         return false;
      }
      TempBlock(index, msg, BLK_ORDER);
      return false;
   }

   g_zones[index].state = Z_TRIGGERED;
   g_zones[index].orderTicket = 0;
   g_zones[index].tp = tp;
   g_stats[StatsIndex(z.setupType, z.direction, z.prof)].sent++;

   DebugPrint("MARKET_SENT",
              StringFormat("%s id=%I64u lot=%.2f price=%.5f sl=%.5f tp=%.5f S=%d risk=%.5f",
                           g_stats[StatsIndex(z.setupType, z.direction, z.prof)].tag, z.id, lot,
                           px, z.sl, tp, z.score, risk));
   return true;
}

void ExecuteArmed()
{
   if(!InpEnableAutoTrading || g_zoneCount == 0)
      return;

   ulong ids[];
   int   sc[];
   int   cnt = 0;
   ArrayResize(ids, g_zoneCount);
   ArrayResize(sc, g_zoneCount);

   for(int i = 0; i < g_zoneCount; i++)
   {
      if(g_zones[i].state != Z_ARMED)
         continue;
      ids[cnt] = g_zones[i].id;
      sc[cnt]  = g_zones[i].score;
      cnt++;
   }

   // best score first
   for(int a = 0; a < cnt - 1; a++)
   {
      for(int b = a + 1; b < cnt; b++)
      {
         if(sc[b] > sc[a])
         {
            int ts = sc[a];
            sc[a] = sc[b];
            sc[b] = ts;
            ulong ti = ids[a];
            ids[a] = ids[b];
            ids[b] = ti;
         }
      }
   }

   for(int k = 0; k < cnt; k++)
   {
      int idx = ZoneIndexById(ids[k]);
      if(idx < 0)
         continue;
      if(g_zones[idx].state != Z_ARMED)
         continue;
      if(TimeCurrent() < g_zones[idx].retryAfter)
         continue;
      if(InpEntryMode == ENTRY_CONFIRM)
      {
         if(g_zones[idx].confirmed)
            SendMarketForZone(idx);
      }
      else
         SendOrderForZone(idx);
   }
}

void ManageZones()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = g_zoneCount - 1; i >= 0; i--)
   {
      int st = g_zones[i].state;

      if(st == Z_ARMED)
      {
         if(TimeCurrent() > g_zones[i].expiryTime)
         {
            RemoveZone(i, Z_EXPIRED, "expiry");
            continue;
         }
         if(InpExpiryMode == EXPIRY_STRUCTURE &&
            ((g_zones[i].direction == DIR_BUY && bid > 0.0 && bid >= g_zones[i].tp) ||
             (g_zones[i].direction == DIR_SELL && ask > 0.0 && ask <= g_zones[i].tp)))
         {
            RemoveZone(i, Z_MISSED, "target reached before entry");
            continue;
         }
         if(InpEntryMode == ENTRY_LIMIT && g_zones[i].direction == DIR_BUY && bid > 0.0 && bid <= g_zones[i].entry)
         {
            RemoveZone(i, Z_MISSED, "entry traded before order");
            continue;
         }
         if(InpEntryMode == ENTRY_LIMIT && g_zones[i].direction == DIR_SELL && ask > 0.0 && ask >= g_zones[i].entry)
         {
            RemoveZone(i, Z_MISSED, "entry traded before order");
            continue;
         }
      }
      else if(st == Z_TRIGGERED)
      {
         bool orderLive = (g_zones[i].orderTicket > 0 && OrderSelect(g_zones[i].orderTicket));
         bool posLive   = PositionByZone(g_zones[i].id);

         if(InpExpiryMode == EXPIRY_STRUCTURE && orderLive)
         {
            bool tpHit = (g_zones[i].direction == DIR_BUY ? (bid > 0.0 && bid >= g_zones[i].tp)
                                                          : (ask > 0.0 && ask <= g_zones[i].tp));
            bool slHit = (g_zones[i].direction == DIR_BUY ? (bid > 0.0 && bid <= g_zones[i].sl)
                                                          : (ask > 0.0 && ask >= g_zones[i].sl));
            if(tpHit || slHit)
            {
               if(trade.OrderDelete(g_zones[i].orderTicket))
                  RemoveZone(i, Z_MISSED, tpHit ? "target reached before entry" : "structure broken before entry");
               continue;
            }
         }

         if(InpCancelPendingOffSession && orderLive)
         {
            int gcat = -1;
            string gwhy = GateReason(g_zones[i], gcat);
            if(gwhy != "")
            {
               if(trade.OrderDelete(g_zones[i].orderTicket))
               {
                  g_zones[i].state = Z_ARMED;
                  g_zones[i].orderTicket = 0;
                  g_zones[i].retryAfter = 0;
                  g_zones[i].lastBlock = gwhy;
                  g_zones[i].lastBlockCat = gcat;
                  g_pulled++;
                  DebugPrint("ORDER_PULLED", StringFormat("id=%I64u %s", g_zones[i].id, gwhy));
               }
               continue;
            }
         }

         if(orderLive && TimeCurrent() > g_zones[i].expiryTime + PeriodSeconds(InpExecutionTF))
         {
            trade.OrderDelete(g_zones[i].orderTicket);
            continue;
         }

         if(!orderLive && !posLive)
         {
            if(HistoryHasZoneEntry(g_zones[i].id, g_zones[i].createdTime))
               RemoveZone(i, Z_USED, "trade completed");
            else
               RemoveZone(i, Z_EXPIRED, "order gone without fill");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Open position management: MFE/MAE tracking and R-based trail     |
//+------------------------------------------------------------------+
int TrackIndex(const ulong posId)
{
   for(int i = 0; i < g_trkCount; i++)
      if(g_trk[i].posId == posId)
         return i;
   return -1;
}

int AddTrack(const ulong posId, const int stat, const int score, const int dir,
             const double entry, const double risk, const double lots, const datetime t,
             const double atrRef, const ulong zid = 0,
             const string key = "", const string kind = "", const int ageMin = 0, const int hour = 0)
{
   int i = g_trkCount;
   ArrayResize(g_trk, g_trkCount + 1);

   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tv <= 0.0)
      tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   g_trk[i].posId = posId;
   g_trk[i].zid   = zid;
   g_trk[i].key   = key;
   g_trk[i].kind  = kind;
   g_trk[i].ageMin = ageMin;
   g_trk[i].hour  = hour;
   g_trk[i].stat  = stat;
   g_trk[i].score = score;
   g_trk[i].dir   = dir;
   g_trk[i].entry = entry;
   g_trk[i].risk  = risk;
   g_trk[i].lots  = lots;
   g_trk[i].tickMoneyPerPrice = (ts > 0.0 ? tv / ts : 0.0);
   g_trk[i].atrRef = atrRef;
   g_trk[i].best  = entry;
   g_trk[i].worst = entry;
   g_trk[i].openTime = t;
   g_trkCount++;
   return i;
}

void RemoveTrack(const int index)
{
   if(index < 0 || index >= g_trkCount)
      return;
   for(int i = index; i < g_trkCount - 1; i++)
      g_trk[i] = g_trk[i + 1];
   g_trkCount--;
   ArrayResize(g_trk, g_trkCount);
}

void ManageOpenPositions()
{
   if(PositionsTotal() == 0)
      return;

   double atr = ATRNow();
   double minDist = BrokerMinDist();
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      ulong pid = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
      long type = PositionGetInteger(POSITION_TYPE);
      int dir = (type == POSITION_TYPE_BUY ? DIR_BUY : DIR_SELL);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);

      int ti = TrackIndex(pid);
      if(ti < 0)
      {
         double risk0 = (sl > 0.0 ? MathAbs(open - sl) : 0.0);
         ti = AddTrack(pid, -1, 0, dir, open, risk0,
                       PositionGetDouble(POSITION_VOLUME),
                       (datetime)PositionGetInteger(POSITION_TIME), atr);
      }

      double px = (dir == DIR_BUY ? bid : ask);
      if(px <= 0.0)
         continue;

      if(dir == DIR_BUY)
      {
         if(px > g_trk[ti].best)  g_trk[ti].best = px;
         if(px < g_trk[ti].worst) g_trk[ti].worst = px;
      }
      else
      {
         if(px < g_trk[ti].best)  g_trk[ti].best = px;
         if(px > g_trk[ti].worst) g_trk[ti].worst = px;
      }

      double risk = g_trk[ti].risk;
      if(!InpUseTrail || risk <= 0.0)
         continue;

      double fav = dir * (g_trk[ti].best - open);
      double target = 0.0;

      double tAtr = (g_trk[ti].atrRef > 0.0 ? g_trk[ti].atrRef : atr);

      if(fav >= InpTrailStartR * risk && tAtr > 0.0)
      {
         double lockSL  = open + dir * InpTrailLockR * risk;
         double trailSL = g_trk[ti].best - dir * InpTrailATRMult * tAtr;
         target = (dir == DIR_BUY ? MathMax(lockSL, trailSL) : MathMin(lockSL, trailSL));
      }
      else if(fav >= InpBreakEvenR * risk)
      {
         target = open + dir * InpBreakEvenLockR * risk;
      }
      else
         continue;

      target = RoundTick(target);

      bool improves = (sl <= 0.0) || (dir * (target - sl) >= InpTrailStepR * risk);
      if(!improves)
         continue;

      if(dir == DIR_BUY && target > bid - minDist)
         continue;
      if(dir == DIR_SELL && target < ask + minDist)
         continue;

      if(trade.PositionModify(ticket, target, tp))
         DebugPrint("TRAIL", StringFormat("ticket=%I64u newSL=%.5f peakR=%.2f", ticket, target, fav / risk));
      else
         DebugPrint("TRAIL_FAIL", StringFormat("ticket=%I64u rc=%d %s", ticket,
                                               (int)trade.ResultRetcode(), trade.ResultRetcodeDescription()));
   }
}

//+------------------------------------------------------------------+
//| Trade events: stats and CSV                                      |
//+------------------------------------------------------------------+
bool ParseComment(const string comment, int &setup, int &dir, ulong &zid, int &score, int &prof)
{
   string parts[];
   int k = StringSplit(comment, (ushort)'|', parts);
   if(k < 6 || parts[0] != "S323")
      return false;

   setup = SetupFromName(parts[1]);
   if(setup < 0)
      return false;

   dir   = (parts[2] == "B" ? DIR_BUY : DIR_SELL);
   zid   = (ulong)StringToInteger(parts[3]);
   score = (int)StringToInteger(parts[4]);
   prof  = (int)StringToInteger(parts[5]);
   if(prof < 0 || prof >= PROF_COUNT)
      prof = 0;
   return true;
}

void LogTradeCSV(const PosTrack &t, const double profit, const double r,
                 const double mfe, const double mae, const datetime closeTime)
{
   if(!InpLogTradesCSV)
      return;

   string fn = StringFormat("STRUXA_v323_%s.csv", _Symbol);
   int h = FileOpen(fn, FILE_READ | FILE_WRITE | FILE_CSV | FILE_COMMON | FILE_ANSI, ';');
   if(h == INVALID_HANDLE)
      return;

   if(FileSize(h) == 0)
      FileWrite(h, "close_time", "symbol", "tag", "score", "lots", "entry", "risk_price",
                "profit", "R", "MFE_R", "MAE_R", "minutes_open", "key", "kind", "age_min", "server_hour");

   FileSeek(h, 0, SEEK_END);

   string tag = (t.stat >= 0 && t.stat < STAT_COUNT ? g_stats[t.stat].tag : "UNKNOWN");
   FileWrite(h,
             TimeToString(closeTime, TIME_DATE | TIME_SECONDS),
             _Symbol, tag, t.score,
             DoubleToString(t.lots, 2),
             DoubleToString(t.entry, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)),
             DoubleToString(t.risk, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)),
             DoubleToString(profit, 2),
             DoubleToString(r, 2),
             DoubleToString(mfe, 2),
             DoubleToString(mae, 2),
             IntegerToString((long)((closeTime - t.openTime) / 60)),
             t.key, t.kind, t.ageMin, t.hour);
   FileClose(h);
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   ulong deal = trans.deal;
   if(deal == 0 || !HistoryDealSelect(deal))
      return;
   if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
      return;
   if((ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagicNumber)
      return;

   long entryType = HistoryDealGetInteger(deal, DEAL_ENTRY);
   ulong pid = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);

   if(entryType == DEAL_ENTRY_IN)
   {
      int setup, dir, score, prof;
      ulong zid;
      if(!ParseComment(HistoryDealGetString(deal, DEAL_COMMENT), setup, dir, zid, score, prof))
         return;

      double price = HistoryDealGetDouble(deal, DEAL_PRICE);
      double lots  = HistoryDealGetDouble(deal, DEAL_VOLUME);

      double sl0 = 0.0;
      ulong ord = (ulong)HistoryDealGetInteger(deal, DEAL_ORDER);
      if(ord > 0 && HistoryOrderSelect(ord))
         sl0 = HistoryOrderGetDouble(ord, ORDER_SL);
      if(sl0 <= 0.0 && PositionSelectByTicket(pid))
         sl0 = PositionGetDouble(POSITION_SL);

      double risk = (sl0 > 0.0 ? MathAbs(price - sl0) : 0.0);
      int si = StatsIndex(setup, dir, prof);

      int zi = ZoneIndexById(zid);
      double aRef = (zi >= 0 ? g_zones[zi].atr : ATRNow());
      string zKey = (zi >= 0 ? g_zones[zi].key : "");
      string zKind = (zi >= 0 ? (g_zones[zi].alt ? g_zones[zi].altKind : "QML") : "");
      datetime dealT = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
      int zAge = (zi >= 0 ? (int)((dealT - g_zones[zi].createdTime) / 60) : 0);
      MqlDateTime dtd;
      TimeToStruct(dealT, dtd);
      QmHistSetStatus(zid, 1);
      g_hoPending = true;
      g_hoDir = dir;
      g_hoPid = pid;

      int existing = TrackIndex(pid);
      if(existing < 0)
         AddTrack(pid, si, score, dir, price, risk, lots, dealT, aRef, zid, zKey, zKind, zAge, dtd.hour);
      else
      {
         g_trk[existing].stat  = si;
         g_trk[existing].score = score;
         g_trk[existing].atrRef = aRef;
         g_trk[existing].zid = zid;
         g_trk[existing].key = zKey;
         g_trk[existing].kind = zKind;
         g_trk[existing].ageMin = zAge;
         g_trk[existing].hour = dtd.hour;
         if(risk > 0.0)
            g_trk[existing].risk = risk;
      }

      g_stats[si].executed++;
      DebugPrint("ENTRY", StringFormat("%s zone=%I64u pos=%I64u price=%.5f lots=%.2f risk=%.5f",
                                       g_stats[si].tag, zid, pid, price, lots, risk));
      return;
   }

   if(entryType == DEAL_ENTRY_OUT || entryType == DEAL_ENTRY_INOUT || entryType == DEAL_ENTRY_OUT_BY)
   {
      int ti = TrackIndex(pid);
      if(ti < 0)
         return;

      double profit = HistoryDealGetDouble(deal, DEAL_PROFIT) +
                      HistoryDealGetDouble(deal, DEAL_SWAP) +
                      HistoryDealGetDouble(deal, DEAL_COMMISSION);

      PosTrack t = g_trk[ti];
      double riskMoney = t.lots * t.risk * t.tickMoneyPerPrice;
      double rMult = (riskMoney > 0.0 ? profit / riskMoney : 0.0);
      double mfe = (t.risk > 0.0 ? t.dir * (t.best - t.entry) / t.risk : 0.0);
      double mae = (t.risk > 0.0 ? t.dir * (t.entry - t.worst) / t.risk : 0.0);

      if(t.stat >= 0 && t.stat < STAT_COUNT)
      {
         g_stats[t.stat].closed++;
         g_stats[t.stat].net += profit;
         g_stats[t.stat].sumR += rMult;
         if(profit > 0.0)
         {
            g_stats[t.stat].wins++;
            g_stats[t.stat].grossProfit += profit;
         }
         else if(profit < 0.0)
         {
            g_stats[t.stat].losses++;
            g_stats[t.stat].grossLoss += MathAbs(profit);
         }
      }

      if(t.zid > 0)
      {
         int zi2 = ZoneIndexById(t.zid);
         if(zi2 >= 0)
            MarkStatus(g_zones[zi2].key, StringFormat("%s %.2fR", (profit > 0.0 ? "WIN" : (profit < 0.0 ? "LOSS" : "BE")), rMult));
      }

      LogTradeCSV(t, profit, rMult, mfe, mae, (datetime)HistoryDealGetInteger(deal, DEAL_TIME));
      RemoveTrack(ti);
   }
}

//+------------------------------------------------------------------+
//| Drawing and dashboard                                            |
//+------------------------------------------------------------------+
void DrawZones()
{
   if(!InpDrawObjects)
      return;

   for(int i = 0; i < g_zoneCount; i++)
   {
      string nm = g_prefix + IntegerToString((long)g_zones[i].id);
      color col = (g_zones[i].direction == DIR_BUY ? clrDodgerBlue : clrOrangeRed);
      if(g_zones[i].state == Z_TRIGGERED)
         col = clrGold;

      if(ObjectFind(0, nm) < 0)
         ObjectCreate(0, nm, OBJ_RECTANGLE, 0, g_zones[i].createdTime, g_zones[i].entry,
                      g_zones[i].expiryTime, g_zones[i].sl);

      ObjectSetInteger(0, nm, OBJPROP_COLOR, col);
      ObjectSetInteger(0, nm, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, nm, OBJPROP_BACK, true);
      ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
      ObjectSetString(0, nm, OBJPROP_TOOLTIP,
                      StringFormat("%s_%s S=%d entry %.5f sl %.5f tp %.5f",
                                   DirName(g_zones[i].direction), SetupName(g_zones[i].setupType),
                                   g_zones[i].score, g_zones[i].entry, g_zones[i].sl, g_zones[i].tp));
   }
}

string RejName(const int i)
{
   switch(i)
   {
      case REJ_DISABLED: return "family off";
      case REJ_STALE:    return "stale break";
      case REJ_RISK:     return "SL too wide";
      case REJ_GEOMETRY: return "geometry";
      case REJ_RETESTED: return "already retested";
      case REJ_BIAS:     return "bias";
      case REJ_SCORE:    return "score";
      case REJ_DUP:      return "duplicate";
      case REJ_CRT:      return "CRT rule";
   }
   return "?";
}

string BlkName(const int i)
{
   switch(i)
   {
      case BLK_GUARD:    return "account guard";
      case BLK_MODE:     return "symbol mode";
      case BLK_SESSION:  return "session";
      case BLK_BIAS:     return "bias";
      case BLK_MAXDIR:   return "max per side";
      case BLK_MAXTOTAL: return "max total";
      case BLK_SPREAD:   return "spread";
      case BLK_VOLUME:   return "volume/min lot";
      case BLK_MARGIN:   return "margin";
      case BLK_ORDER:    return "order error";
      case BLK_CLOSED:   return "market closed";
      case BLK_RISKBUDGET: return "open-risk budget";
   }
   return "?";
}

string FunnelLine(const int p)
{
   long found = 0, reg = 0, sent = 0, exec = 0;
   for(int s = 0; s < SETUP_COUNT * 2; s++)
   {
      int i = p * SETUP_COUNT * 2 + s;
      found += g_stats[i].found;
      reg   += g_stats[i].registered;
      sent  += g_stats[i].sent;
      exec  += g_stats[i].executed;
   }

   long rejTotal = 0;
   string list = "";
   for(int i = 0; i < REJ_COUNT; i++)
   {
      if(i == REJ_STALE)
         continue;
      rejTotal += g_rej[p][i];
      if(g_rej[p][i] > 0)
         list += StringFormat(" %s %d;", RejName(i), (int)g_rej[p][i]);
   }
   if(list == "")
      list = " -";

   return StringFormat("%s funnel: found %d | rejected %d (%s ) | registered %d | order sent %d | filled %d | stale breaks skipped %d | wide-entry used %d",
                       g_prof[p].name, (int)found, (int)rejTotal, list, (int)reg, (int)sent, (int)exec,
                       (int)g_rej[p][REJ_STALE], (int)g_altCount[p]);
}

string BlockLine(const int p)
{
   string list = "";
   for(int i = 0; i < BLK_COUNT; i++)
      if(g_blk[p][i] > 0)
         list += StringFormat(" %s %d;", BlkName(i), (int)g_blk[p][i]);
   if(list == "")
      list = " none";
   return StringFormat("%s zones blocked at least once by:%s", g_prof[p].name, list);
}

string EndLine(const int state, const string label)
{
   string s = StringFormat("%s %d:", label, (int)g_stateCount[state]);
   bool any = false;
   for(int b = 0; b <= BLK_COUNT; b++)
   {
      if(g_endBlk[state][b] == 0)
         continue;
      string nm = (b == BLK_COUNT ? "never blocked" : BlkName(b));
      s += StringFormat(" %s %d;", nm, (int)g_endBlk[state][b]);
      any = true;
   }
   if(!any)
      s += " -";
   return s;
}

void DrawDashboard()
{
   if(!InpShowDashboard)
      return;

   int s1 = BiasSign(g_ema1, InpBiasTF1);
   int s2 = BiasSign(g_ema2, InpBiasTF2);
   double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);

   string guard = "ok";
   if(g_overallHard)       guard = "OVERALL HARD LOCK";
   else if(g_dailyHard)    guard = "daily hard lock";
   else if(g_dailySoft)    guard = "daily soft lock";
   else if(g_overallSoft)  guard = "overall soft: risk scaled";

   string t = StringFormat("STRUXA QM v3.23  %s  exec %s  |  %s detection ON  |  %s detection %s\n", _Symbol,
                           TFName(InpExecutionTF), TFName(InpZoneTF), TFName(InpFastTF),
                           (g_profCount > 1 ? "ON" : "OFF"));
   t += StringFormat("Bias H1 %d  H4 %d  mode %d | entry %s | spread %.5f | ATR(zone) %.5f | guard: %s\n",
                     s1, s2, (int)InpBiasMode, (InpEntryMode == ENTRY_CONFIRM ? "confirm" : "limit"), spread, ATRNow(), guard);
   t += StringFormat("Zones live %d (armed/trig)  used %d  missed %d  expired %d  blocked %d\n",
                     g_zoneCount, (int)g_stateCount[Z_USED], (int)g_stateCount[Z_MISSED],
                     (int)g_stateCount[Z_EXPIRED], (int)g_stateCount[Z_BLOCKED]);
   for(int fp = 0; fp < g_profCount; fp++)
      t += FunnelLine(fp) + "\n" + BlockLine(fp) + "\n";
   t += StringFormat("Orders pulled and re-armed %d | study: %d virtual trades live (%d skipped, cap %d)\n",
                     (int)g_pulled, g_vtCount, (int)g_vtSkipped, VT_MAX);
   if(g_crtOn)
      t += StringFormat("CRT ranges tracked %d | formed: classic %d inside %d multi %d tbs %d break-retest %d engulf %d session %d double %d | PDH %.2f PDL %.2f\n",
                        g_crtCount, (int)g_crtTypeCount[CRT_CLASSIC], (int)g_crtTypeCount[CRT_INSIDE],
                        (int)g_crtTypeCount[CRT_MULTI], (int)g_crtTypeCount[CRT_TBS],
                        (int)g_crtTypeCount[CRT_BREAK_RETEST], (int)g_crtTypeCount[CRT_ENGULF],
                        (int)g_crtTypeCount[CRT_SESSION], (int)g_crtTypeCount[CRT_DOUBLE], g_pdh, g_pdl);
   if(g_crtOn)
      t += StringFormat("Phase 2: sweep QMs %d | in-range QMs %d | CRT-rule rejections M15 %d / M5 %d | handoff closes %d\n",
                        (int)g_trigQm, (int)g_inRangeQm, (int)g_rej[0][REJ_CRT], (int)g_rej[1][REJ_CRT], (int)g_handoffs);

   double net = 0.0;
   long closed = 0;
   long wins = 0;
   double gp = 0.0;
   double gl = 0.0;

   for(int i = 0; i < STAT_COUNT; i++)
   {
      net += g_stats[i].net;
      closed += g_stats[i].closed;
      wins += g_stats[i].wins;
      gp += g_stats[i].grossProfit;
      gl += g_stats[i].grossLoss;
      if(g_stats[i].found > 0)
         t += StatLine(g_stats[i]) + "\n";
   }

   double pf = (gl > 0.0 ? gp / gl : (gp > 0.0 ? 99.0 : 0.0));
   t += StringFormat("TOTAL closed %d  win %.1f%%  net %.2f  PF %.2f\n",
                     (int)closed, (closed > 0 ? 100.0 * (double)wins / (double)closed : 0.0), net, pf);
   t += "Last skip: " + g_lastSkip;

   Comment(t);
}

void PrintFinalStats()
{
   Print("[", InpEAName, "] ===== FINAL STATS =====");
   double net = 0.0;
   for(int i = 0; i < STAT_COUNT; i++)
   {
      if(g_stats[i].found > 0)
         Print("[", InpEAName, "] ", StatLine(g_stats[i]));
      net += g_stats[i].net;
   }
   for(int fp = 0; fp < g_profCount; fp++)
   {
      Print("[", InpEAName, "] ", FunnelLine(fp));
      Print("[", InpEAName, "] ", BlockLine(fp));
   }
   Print("[", InpEAName, "] ZONE ENDS (last block reason before the end)");
   Print("[", InpEAName, "]   ", EndLine(Z_USED, "used"));
   Print("[", InpEAName, "]   ", EndLine(Z_EXPIRED, "expired"));
   Print("[", InpEAName, "]   ", EndLine(Z_MISSED, "missed (entry traded before order)"));
   Print("[", InpEAName, "]   ", EndLine(Z_BLOCKED, "blocked (stops too close)"));
   Print("[", InpEAName, "] NET ", DoubleToString(net, 2),
         " | zones used ", (int)g_stateCount[Z_USED],
         " missed ", (int)g_stateCount[Z_MISSED],
         " expired ", (int)g_stateCount[Z_EXPIRED]);
}

//+------------------------------------------------------------------+
//| Init / deinit / tick                                             |
//+------------------------------------------------------------------+
bool InitProfiles()
{
   g_profCount = 0;

   g_prof[0].name              = TFName(InpZoneTF);
   g_prof[0].tf                = InpZoneTF;
   g_prof[0].lr                = InpSwingLR;
   g_prof[0].minSwingATR       = InpMinSwingATR;
   g_prof[0].lookback          = InpLookbackBars;
   g_prof[0].undercutATR       = InpHeadUndercutATR;
   g_prof[0].breakATR          = InpBreakATR;
   g_prof[0].maxBarsAfterBreak = InpMaxBarsAfterBreak;
   g_prof[0].maxHeadToBreak    = InpMaxHeadToBreakBars;
   g_prof[0].expiryBars        = InpOrderExpiryZoneBars;
   g_prof[0].maxLifeBars       = InpMaxLifeBars;
   g_prof[0].minRiskATR        = InpMinRiskATR;
   g_prof[0].maxRiskATR        = InpMaxRiskATR;
   g_prof[0].targetRR          = InpTargetRR;
   g_prof[0].minScore          = InpMinTradeScore;
   g_prof[0].hAtr              = g_atr;
   g_prof[0].hRsi              = g_rsi;
   g_prof[0].hMacd             = g_macd;
   g_profCount = 1;

   if(!InpUseFastProfile)
      return true;

   if(InpFastTF == InpZoneTF)
   {
      Print("[", InpEAName, "] Fast profile skipped: InpFastTF equals InpZoneTF");
      return true;
   }
   if(PeriodSeconds(InpFastTF) < PeriodSeconds(InpExecutionTF))
   {
      Print("[", InpEAName, "] InpFastTF must be equal to or higher than ExecutionTF");
      return false;
   }

   g_rsiF  = iRSI(_Symbol, InpFastTF, InpRSIPeriod, PRICE_CLOSE);
   g_macdF = iMACD(_Symbol, InpFastTF, InpMACDFast, InpMACDSlow, InpMACDSignal, PRICE_CLOSE);
   g_atrF  = iATR(_Symbol, InpFastTF, InpATRPeriod);
   if(g_rsiF == INVALID_HANDLE || g_macdF == INVALID_HANDLE || g_atrF == INVALID_HANDLE)
   {
      Print("[", InpEAName, "] fast profile indicator handle init failed");
      return false;
   }

   g_prof[1].name              = TFName(InpFastTF);
   g_prof[1].tf                = InpFastTF;
   g_prof[1].lr                = InpFastSwingLR;
   g_prof[1].minSwingATR       = InpFastMinSwingATR;
   g_prof[1].lookback          = InpFastLookbackBars;
   g_prof[1].undercutATR       = InpFastHeadUndercutATR;
   g_prof[1].breakATR          = InpFastBreakATR;
   g_prof[1].maxBarsAfterBreak = InpFastMaxBarsAfterBreak;
   g_prof[1].maxHeadToBreak    = InpFastMaxHeadToBreakBars;
   g_prof[1].expiryBars        = InpFastOrderExpiryBars;
   g_prof[1].maxLifeBars       = InpFastMaxLifeBars;
   g_prof[1].minRiskATR        = InpFastMinRiskATR;
   g_prof[1].maxRiskATR        = InpFastMaxRiskATR;
   g_prof[1].targetRR          = InpFastTargetRR;
   g_prof[1].minScore          = InpFastMinTradeScore;
   g_prof[1].hAtr              = g_atrF;
   g_prof[1].hRsi              = g_rsiF;
   g_prof[1].hMacd             = g_macdF;
   g_profCount = 2;
   return true;
}

int OnInit()
{
   if(PeriodSeconds(InpZoneTF) < PeriodSeconds(InpExecutionTF))
   {
      Print("[", InpEAName, "] ZoneTF must be equal to or higher than ExecutionTF");
      return INIT_PARAMETERS_INCORRECT;
   }

   g_rsi  = iRSI(_Symbol, InpZoneTF, InpRSIPeriod, PRICE_CLOSE);
   g_macd = iMACD(_Symbol, InpZoneTF, InpMACDFast, InpMACDSlow, InpMACDSignal, PRICE_CLOSE);
   g_atr  = iATR(_Symbol, InpZoneTF, InpATRPeriod);
   g_ema1 = iMA(_Symbol, InpBiasTF1, InpBiasEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_ema2 = iMA(_Symbol, InpBiasTF2, InpBiasEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);

   if(g_rsi == INVALID_HANDLE || g_macd == INVALID_HANDLE || g_atr == INVALID_HANDLE ||
      g_ema1 == INVALID_HANDLE || g_ema2 == INVALID_HANDLE)
   {
      Print("[", InpEAName, "] indicator handle init failed");
      return INIT_FAILED;
   }

   if(!InitProfiles())
      return INIT_PARAMETERS_INCORRECT;

   ArrayResize(g_zones, MathMax(8, InpMaxZones));
   g_zoneCount = 0;
   g_nextZoneId = 1;
   g_trkCount = 0;
   ArrayResize(g_trk, 0);
   g_seenCount = 0;
   g_markCount = 0;
   ArrayResize(g_vt, VT_MAX);
   g_vtCount = 0;
   g_vtSkipped = 0;
   g_pulled = 0;
   for(int pp = 0; pp < PROF_COUNT; pp++)
      g_lastProfBar[pp] = 0;
   InitStats();

   g_initBal = AccountInfoDouble(ACCOUNT_BALANCE);
   g_dayKey = DateKey(TimeCurrent());
   g_dayStartBal = g_initBal;

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(50);

   ObjectsDeleteAll(0, g_prefix);
   CrtInit();

   DebugPrint("INIT",
              StringFormat("v3.23 %s main=%s fast=%s exec=%s bias=%d risk=%.2f%% balance=%.2f provisionalHead=%d expiry=%d wide=%d",
                           _Symbol, TFName(InpZoneTF), (g_profCount > 1 ? TFName(InpFastTF) : "off"),
                           TFName(InpExecutionTF), (int)InpBiasMode, InpRiskPercent, g_initBal,
                           (int)InpProvisionalHead, (int)InpExpiryMode, (int)InpWideEntryMode));

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   PrintFinalStats();

   for(int vi = g_vtCount - 1; vi >= 0; vi--)
      VTFinish(vi, "UNRESOLVED");

   CrtShutdown();

   if(g_rsi != INVALID_HANDLE)  IndicatorRelease(g_rsi);
   if(g_macd != INVALID_HANDLE) IndicatorRelease(g_macd);
   if(g_atr != INVALID_HANDLE)  IndicatorRelease(g_atr);
   if(g_ema1 != INVALID_HANDLE) IndicatorRelease(g_ema1);
   if(g_ema2 != INVALID_HANDLE) IndicatorRelease(g_ema2);
   if(g_rsiF != INVALID_HANDLE)  IndicatorRelease(g_rsiF);
   if(g_macdF != INVALID_HANDLE) IndicatorRelease(g_macdF);
   if(g_atrF != INVALID_HANDLE)  IndicatorRelease(g_atrF);

   if(!InpKeepMarksOnExit)
      ObjectsDeleteAll(0, g_prefix);
   Comment("");
}

void OnTick()
{
   EvaluateGuards();
   ManageOpenPositions();
   HandoffTrail();
   CrtTick();

   bool newExec = NewBar(InpExecutionTF, g_lastExecBar);
   bool newScan = false;

   for(int p = 0; p < g_profCount; p++)
   {
      if(NewBar(g_prof[p].tf, g_lastProfBar[p]))
      {
         newScan = true;
         ScanForSetups(p);
      }
   }

   if(newExec)
      UpdateVirtualTrades();

   if(newExec || newScan)
   {
      ManageZones();
      CheckConfirmations();
      ExecuteArmed();
      DrawZones();
      DrawDashboard();
   }
}
//+------------------------------------------------------------------+