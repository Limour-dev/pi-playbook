# 期权与加密日报生成手册（Options & Crypto Briefing Playbook）

> 本手册写给任何新的 agent。读完全文即可独立完成一份《期权日报（Markdown）》的抓取、分析、写作与自检。
> 它总结了首次实操以来确认的口径、命令行为与踩过的坑，**优先级高于一般直觉**；用户贴出本手册、或定时任务 `@` 本手册且未指定其他任务时，即为执行本手册（生成当日 `briefing-playbook/options-briefing-YYYY-MM-DD.md`）。
> 三个技能全部**只读**：只查数据，不下单、不改账户状态。

---

## 0. 任务概述

- **一句话任务**：抓 GLD / IBIT / TLT / SPY / QQQ 的**本周五到期**期权结构，加 USDT.D / BTCUSD 走势，写成一份 Markdown 日报，供下游「每日简报 agent」二次分析。
- **交付物**：`briefing-playbook/options-briefing-YYYY-MM-DD.md`
  - `YYYY-MM-DD` = **生成本地日期（Asia/Shanghai）**，与同日 `briefing-YYYY-MM-DD.html` 对齐；文件内单独注明覆盖的**美东交易日**（两者可能差一天）。
- **一次操作**：抓取 → 分析 → 写作 → 自检 → 落盘，中间不问用户；只有抓取失败/数据缺失才停下报告。
- **三条硬规则（违反即返工）**：
  1. **期权结论只给周五到期日**。所有 GEX / 墙位 / max pain / 剧本都锁定在「最近的、尚未到期的那个周五」（§2）；0DTE 与月中月期权只在内部用于期限结构判断，**不进结论、不进表格**。
  2. **GLD / IBIT / TLT 只作为传导腿**：从美债、黄金、加密/流动性三个角度分析它们**对 SPY、QQQ 的影响**，不写这三个标的自己的独立方向性结论或交易建议。
  3. **USDT.D + BTCUSD 单独成节**（第二部分），这一节允许有自己的走势结论与关键位。
- **下游契约**：简报 agent 只读 §5 模板里的两个稳定锚点——`## 摘要卡` 和 `## 供简报引用（通俗结论）`。写这两块时**假设读者不懂期权**：不出现 GEX / gamma flip / max pain 之类术语，只给「哪里是压力、哪里可能破、偏上还是偏下」。

---

## 1. 数据源与入口

| 技能 | 入口（相对仓库根） | 用来拿什么 |
|---|---|---|
| `options-gex` | `.agents/skills/options-gex/bin/options-gex` | 单到期日的 `net_gex` / `gamma_flip` / `call_wall` / `put_wall` / `max_pain` / `implied_move_pct` / `stm_iv` / `pc_oi_ratio` / `bullish_score`；`scan` 出多标的到期日简表与 `sign_flips` |
| `optioncharts` | `.agents/skills/optioncharts/bin/optioncharts` | 链统计（`volume_total`、`volume_pcr`、`oi_total`、`iv_pct`、`expected_move_abs/pct`）、逐行权价 `oi` / `volume`、`--gex` 的 ±1EM 归一化字段；`spot` 出实时价（交叉核对用，见 §6①） |
| `tradingview` | `.agents/skills/tradingview/bin/tradingview` | USDT.D / BTCUSD / US10Y / GOLD / DXY / VIX 的已收盘 K 线与**大道至简**指标（kc1 / kc2 / kc_low / ema_high·low / median_200 / MACD） |

```bash
export PLAYBOOK_DIR=/root/pi-playbook          # 定时任务里由 run-options-briefing.sh 设置；手动执行用仓库根
export PATH="$PLAYBOOK_DIR/.agents/skills/options-gex/bin:$PLAYBOOK_DIR/.agents/skills/optioncharts/bin:$PLAYBOOK_DIR/.agents/skills/tradingview/bin:/root/micromamba/envs/pi/bin:$PATH"
node -v            # 需要 ≥ 22.13（skills 直接跑 TypeScript）
```

- **`tradingview` 首次使用必须先 `npm install`**（`cd .agents/skills/tradingview && npm install`），否则所有命令只报 `dependencies missing`。
- `.agents/` 被 `.gitignore` 忽略 → 技能不随 git 同步，**换机器要手动拷**（§9.3）。
- 两套期权数据源、三套口径，**同一张表里绝不混源**（§7）。

---

## 2. 目标到期日：只锁「本周五」

- 日报的唯一天期权 = **最近的、尚未到期的那个周五**：美东周一至周五且周五未过 16:00 ET → **本周五**；美东周五收盘后、或周六周日 → **顺延到下周五**。边界一律按**美东**算（本机 CST 差 12 小时，**别用 `date -d "next friday"`**）。

```bash
# 目标周五（美东口径，含"周五已收盘就顺延"）
FRIDAY=$(python3 - <<'PY'
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo
et = datetime.now(ZoneInfo("America/New_York"))
d = et.date()
off = (4 - d.weekday()) % 7                      # 0=Mon … 4=Fri
if off == 0 and et.hour >= 16:                   # 周五已收盘 → 顺延一周
    off = 7
print((d + timedelta(days=off)).isoformat())
PY
)
echo "$FRIDAY"
```

- **到期日后缀必须查一次**：`optioncharts` 的 `--exp` 要带 `:w` / `:m`（**第三个周五是月度到期 `:m`**），裸日期会触发解析（默认 exit 5）。用 `optioncharts expiries <T> --dte 20` 看后缀，按 `date` 定位目标周五那一行（现在也会列出周一～周四的日到期，`--dte N` 是上限不是精确值）。
- `options-gex` 的 `--exp` 用**裸日期**（如 `--exp 2026-10-09`），并回读 `provenance.selected_exp` 核对；**服务端不会因非法/过期日期报错，而是静默回落到最近到期日**。
- **两种特殊快照**：
  - **周末/节假日**：DTE 常为 5–6 且很可能是月期权，行情全部冻结在上一交易日收盘 → 报告要写清"覆盖美东交易日"与 DTE 口径差异。
  - **到期日当天（周五收盘前）**：目标周五 = 当天、两源 `dte` = 0、`market_session = "pre"`、价格是前一交易日收盘/盘前读数；`±1EM` 与关键位明显收窄，剧本围绕**钉子位 + max pain** 写，并在标题与 §0 显式注明 **DTE 0**。
- 报告标题/摘要卡写清：目标到期日（周几、DTE）、快照时刻（UTC + 美东）。

---

## 3. 抓取配方（一份日报的完整命令序列）

设 `FRIDAY=2026-10-09`（示例）。

```bash
SK="$PLAYBOOK_DIR/.agents/skills"

# ① 五个标的的周五结构：一次拿 spot / net_gex / flip / walls / max_pain / EM / IV / PCR
"$SK/options-gex/bin/options-gex" scan GLD IBIT TLT SPY QQQ --exp "$FRIDAY" --concurrency 2 --format compact > /tmp/og_scan.json

# ①b 期限结构 / sign_flips：必须**不带 --exp**（带 --exp 会把 scan 钉在单到期日上，
#     直接返回 sign_flips: [] 并给 warning "--exp pins the scan to ..."，全周对比就没了）
"$SK/options-gex/bin/options-gex" scan SPY QQQ --dte 21 --max-exp 8 --concurrency 2 --format compact > /tmp/og_term.json

# ② 墙位与墙位 OI、到现价的距离（单标的、token 小；报告里的墙位数字一律以这次为准）
for t in SPY QQQ GLD IBIT TLT; do
  "$SK/options-gex/bin/options-gex" walls $t --exp "$FRIDAY" --no-insights --format compact
done

# ②b 现价交叉核对（**必做**：`options-gex` 的 spot 常整日滞后，见 §6①）
"$SK/optioncharts/bin/optioncharts" spot GLD IBIT TLT SPY QQQ --format csv
#     → 实时价（Polygon），带 change_pct / market_status / options_delay；只吃 pretty|compact|csv（json 报 usage 错）

# ③ 链统计 + ±1EM 归一化（跨标的比较、成交量/OI 结构、per-expiry EM 都从这里取）
"$SK/optioncharts/bin/optioncharts" scan GLD IBIT TLT SPY QQQ --exp "$FRIDAY:w" --gex --format csv --units

# ④ 关键行权价的 OI 密集度（SPY/QQQ 必查，其余按需）
for t in SPY QQQ; do
  "$SK/optioncharts/bin/optioncharts" oi $t --exp "$FRIDAY:w" --format csv | tail -n +2 | sort -t, -k5 -gr | head -14
done

# ⑤ 逐行权价的 GEX 分布（找正/负 gamma 节点；SPY、QQQ 必查）
"$SK/optioncharts/bin/optioncharts" gex SPY --exp "$FRIDAY:w" --top 12 --format csv
"$SK/optioncharts/bin/optioncharts" gex QQQ --exp "$FRIDAY:w" --top 12 --format csv

# ⑥ 加密与宏观腿（tradingview，多周期各跑一次；只取 stdout，别用 2>&1）
for tf in W 1D 4h; do
  "$SK/tradingview/bin/tradingview" indicators BTCUSD --tf $tf --count 12 \
    --select time_iso,open,high,low,close,kc1_mid,kc1_lower,kc_low_lower,median_200,macd,macd_hist --format csv
done
"$SK/tradingview/bin/tradingview" indicators USDT.D --tf W --count 10 --select time_iso,close,kc1_mid,kc1_lower,median_200,macd,macd_hist --format csv
"$SK/tradingview/bin/tradingview" indicators USDT.D --tf 1D --count 25 --select time_iso,close,kc1_lower,median_200,macd,macd_hist --format csv
# 宏观背景（各 1~2 条即可，别倒几百根）
"$SK/tradingview/bin/tradingview" indicators US10Y --tf W --count 12 --select time_iso,close,median_200,macd_hist --format csv
"$SK/tradingview/bin/tradingview" indicators US10Y --tf 4h --count 6  --select time_iso,close --format csv   # 长端"当天值"
"$SK/tradingview/bin/tradingview" indicators GOLD  --tf 1D --count 12 --select time_iso,close,kc1_mid,median_200,macd_hist --format csv
"$SK/tradingview/bin/tradingview" indicators DXY   --tf 1D --count 12 --select time_iso,close,kc1_mid,median_200,macd_hist --format csv
"$SK/tradingview/bin/tradingview" indicators VIX   --tf 1D --count 8  --select time_iso,close,median_200,macd_hist --format csv
"$SK/tradingview/bin/tradingview" indicators VIX   --tf 1h --count 6  --select time_iso,close --format csv     # 恐慌"当天值"
```

**请求预算**：`options-gex` REST 限流 **30 次/IP**（60 秒本地缓存吸收同一 `(ticker, exp)` 的重复调用），① ② 合计约 10 次；`optioncharts` 实测无限流、TTFB ~2s，②b③④⑤ 约 10 次。一天一轮足够，**不要跑 `raw`**。

---

## 4. 分析框架

### 4.1 期权读数顺序（每个标的都照这个顺序说）

1. **口径**：这是 `selected_exp` 单到期日的数据，不是多日汇总；`net_gex` 假设全部合约由 dealer 中介。
2. **现价 vs `gamma_flip`**：上方 = 正 gamma（dealer 高抛低吸、压波动）；下方 = 负 gamma（助涨助跌）。
3. **`net_gex` 正负**：正 = 波动被压制（区间行情）；负 = 单边容易被放大。
4. **墙位 + OI**：`call_wall`（上方卖压）、`put_wall`（下方支撑）；数字优先取 `walls` 命令，带上墙位 OI 与到现价的百分比距离。**墙位一律按几何位置读，见 §7.2。**
5. **`max_pain`**：到期日引力位；给「距现价 %」（只影响到期日附近漂移，不是日内目标）。
6. **EM 与聚集度**：`implied_move_pct`/`expected_move_abs`（**per-expiry 口径**）给 ±1EM 区间；`net_exposure_within_1em_share_pct` / `abs_share_within_1em_pct` 说明 gamma 有多集中（>60% = 强钉住）。
7. **资金流**：`volume_pcr`（当日量）与 `pc_oi_ratio`/`oi_pcr`（持仓），四象限读法见 §7.4。
8. **期限结构（内部用）**：`scan` 的 `sign_flips` 判断「周五是不是被单独压/独独撑」——**只写进分析过程，结论仍只落周五**。

### 4.2 三条传导腿（TLT / GLD / IBIT）—— 每条四句话，缺一不可

| 腿 | 宏观腿（tradingview） | 期权腿（options-gex / optioncharts） | 必须给出的触发位 | 必须回答的问题 |
|---|---|---|---|---|
| **TLT（美债）** | US10Y 周线方向 + MACD 柱、DXY 强弱 | 周五 `net_gex`/flip/walls/max_pain/OI PCR | 跌破 flip → 长端利率压力；收复并黏在 max pain | 对 QQQ（高估值成长）是**减压还是加压**？QQQ 的哪个位对应？ |
| **GLD（黄金/实际利率）** | GOLD 周线与日线 kc1_mid/median_200、DXY | 同上（GLD 常是全表唯一负 gamma） | 跌破 put wall 与收复 flip 各自意味着什么 | 与收益率上行是否共振？风偏收缩还是缓解？ |
| **IBIT（加密/流动性）** | BTC 周线、USDT.D 方向 | IBIT 周五 gamma 堆积区（正/负节点） | 墙位破/守 → 风偏外溢 | 给 QQQ 的是「托底」还是「退潮」？ |

- **IBIT ↔ BTC 换算**：用**当日** `IBIT spot` ÷ BTCUSD **最近一根已收盘的 1h（或 4h）K 线收盘价**得到比值（实测约 1764–1790，随日漂移，**不要写死**），把 IBIT 墙位翻译成 BTC 价位。**别用日线 close**（日线最新一根只到前一交易日，会把比值抬高 ≈1.4%）。
- **只输出传导含义**：可以写「TLT 跌破 75.9 会把长端压力传导到 QQQ 的 749/742」，**不要**写「TLT 可以做多/做空」。

### 4.3 SPY / QQQ

每个标的按固定四段写：**结构 → 关键位 → 剧本 A/B/C → 与另一指数的分歧**。

- 结构：`net_gex` 量级与本周位置、正/负 gamma 节点分布（带 `share_of_abs_total_pct`）、OI 密集度、资金流。
- 关键位表：`±1EM 区间` / 钉子位 / 上方硬顶 / 下方破位触发 / 偏向。
- 剧本：**A 基准**（概率最高，给区间与收敛方向）、**B 风险**（触发条件 → 目标位）、**C 上破**（触发条件 → 目标位，并说明为何概率低）。
- 分歧：SPY 净买 call 而 QQQ 净买 put 这类背离，必须写「若风偏回落谁跌得多」。

### 4.4 加密（第二部分，允许独立结论）

- **USDT.D**：周线趋势（kc1_mid/median_200/MACD 柱）+ 日线（kc1_lower 超卖、MACD 柱转向）→ 箱体区间 → 关键位 → 一句话结论（下行使风险资产顺风）。
- **BTCUSD**：周线（趋势与 MACD 柱是否扩张）+ 日线（是否贴外轨、MACD 柱收敛）+ 4h（动能是否降温）→ 阻力/支撑 → 未来一周「震荡消化」还是「续涨」。
- **合成**：USDT.D 下 + BTC 上 = 流动性宽松/risk-on；再与 **IBIT 周五期权堆积区**互证，写成「托底但不推升」这类可验证的表述。
- **反向共振**要写出来：USDT.D 箱体底部止跌反弹 → 加密回调 → IBIT 丢关键支撑 → 与黄金/美债的看空腿合流。

### 4.5 跨标的比较必须归一化

- `net_exposure` 是**每 1% 标的变动的美元 gamma/delta**（`usd_per_1pct_move`），量级随合约名义额变化（TLT ≈ \$7.7k/张，SPY/QQQ ≈ \$75k/张）。**直接比大小会系统性低估 TLT**。
- 正确做法：同桶内用 `share_of_abs_total_pct` 定位墙位；跨标的用**按 `sigma_pos`（±EM）对齐**或比较 `net_exposure_within_1em_share_pct` / `abs_share_within_1em_pct`。

---

## 5. 报告模板（.md 骨架）

文件名：`briefing-playbook/options-briefing-YYYY-MM-DD.md`。**标题层级与锚点不要改名**（简报 agent 依赖 `## 摘要卡` 与 `## 供简报引用（通俗结论）`）：

```markdown
# 期权日报 · YYYY-MM-DD（覆盖美东 MM-DD 周X）

## 摘要卡
- 目标到期日：2026-10-09（周五，DTE 4）
- 数据快照：2026-10-05 19:20 UTC（美东 15:20，盘中/盘后要写明）
- 来源：options-gex（Sell The News）· optioncharts（OPRA 15 分钟延迟）· tradingview
- SPY 周五：中性偏下，区间 769–783，硬顶 787，破 767 看 760
- QQQ 周五：偏下，区间 746–766，钉住 754–760，破 749 看 742
- 传导腿：美债（TLT 76.04 上方=减压）· 黄金（GLD 负 gamma，破 375=加压）· 加密（IBIT 48–49 上方=托底）
- 加密：USDT.D 6.28–6.56 弱震荡；BTC 83.8k–87.2k 高位消化

## 0. 数据口径与快照
（表格：抓取时刻、来源、目标到期日、现价，以及"OI 为上一交易日收盘值 / 期权 15 分钟延迟 / 第三方聚合"等口径声明；滞后标的在此声明）

## 1. 周五（MM-DD）一览
（五标的 × 列：spot / net GEX / flip / spot vs flip / call wall(OI) / put wall / max pain / IV / ±1EM / 量PCR · OI PCR）
（末尾一段：±1EM 上下沿与其两侧节点的差值、两端节点符号、失效条件）

## 2. 跨资产三条腿如何传导到 SPY / QQQ
### 2.1 TLT / 美债
### 2.2 GLD / 黄金
### 2.3 IBIT / 加密
（每条 = 宏观腿 + 期权腿 + 触发位 + 对 SPY/QQQ 的含义）
（一句话合成：几空几多 + 结论）

## 3. SPY（周五 MM-DD）
## 4. QQQ（周五 MM-DD）
（每个含：结构 / 关键位表 / 剧本 A·B·C / 与另一指数的分歧）

## 5. 周五剧本总表
（列：±1EM 区间 / 钉子 / 上方硬顶 / 下方破位触发 / 偏向；行：SPY QQQ TLT GLD IBIT）

## 6. 加密：USDT.D 与 BTCUSD
### 6.1 USDT.D
### 6.2 BTCUSD
### 6.3 合成与互证

## 7. 与上一份报告的差异
（没有上一份就写"本日为首份"；有就逐条写变化——墙位挪动、flip 翻面、剧本切换；换链或跨多日时显式声明，见 §7.5）

## 供简报引用（通俗结论）
（3–6 句，无术语，可直接抄进每日简报；含关键位与偏向；结论反转要明说）

## 数据来源与免责
（口径段落，见 §6）
```

写作要求：

- **术语只出现在 §0–§5 的分析部分**；`摘要卡` 与 `供简报引用` 必须零术语。
- 数字**带来源与时刻**（`net_gex ≈ +\$6.4B（19:17 UTC）`、PCR 标 `optioncharts`）；同一张表不混两个快照。
- 数字**取整到合理精度**（`$6.35B` 而非 `$6350000000.0`），spot 两位小数，百分比一位小数。
- 区间用 `±1EM`（per-expiry），**不要**用 `em` 锥形的 `em_amt`（spot-anchored 曲线）；锥形日期读 `et_date` 不读 `iso`。
- 写报告前**重跑一次 `scan` 与 `walls`**（实测 2 分钟内 SPY `net_gex` 可漂移 +\$4.84B → +\$6.35B），全文只引用这一次的数。
- 报告里**不要**出现第三方 insights 的英文原文；要引用就翻译改写。

---

## 6. 口径与免责（报告 §0 与末节必须照抄的要点）

- **GEX 定义（第三方口径，勿自算）**：`GEX_contract = gamma × OI × 100 × spot² × 0.01`，call 为正、put 为负。正 `net_gex` = dealer 多头 gamma（高抛低吸、压制波动），负值反之。
- **单到期日口径**：`gamma_flip` / `max_pain` / walls / `net_gex` 全部只属于 `selected_exp` 这一个到期日。
- **OI 是上一交易日收盘值**，不代表盘中持仓变化；`net_gex` 假设全部合约由 dealer 中介。
- **数据源为第三方聚合**（Sell The News / optioncharts），非交易所原始数据；`updated_at` 是服务端计算时刻，**不是行情时间戳**。
- **期权报价为 OPRA 15 分钟延迟**（不适合盘中执行级信号），`spot` 为实时（Polygon.io）。
- **`bullish_score` 由上游定义、组成未公开**，只作横向参考。
- **`gamma_flip` 与 `zero_gamma_estimate`** 是两个口径：后者是行权价网格上的线性插值交叉校验，相差几美元属正常，**报告以 `gamma_flip` 为准**。
- **`oi_source` 若不是 `"oi"`**，说明统计口径可能变成成交量，必须在报告里说明。
- **tradingview 只返回已收盘 K 线**：日线在其收盘后还要等满 24 小时才出现；报告里写 `coverage.last` / `as_of` / `stale`，并按 `coverage.last` 写「截至 MM-DD」。`USDT.D` / `US10Y` / `GOLD` / `DXY` / `VIX` 是**指数/百分比序列**（`volume_reliable: false`、`volume = null`），**不要用它们的量能做推断**。
- 免责：本报告是公开持仓结构的读数，不构成投资建议。

### 6① 判「链是否陈旧」—— 每天必做，唯一硬判据

`options-gex` 的 spot 与整条链常年滞后（IBIT 已连续多日复现，TLT 也中过招）。每天抓完 ② 立刻跑 ②b，然后按下面顺序判：

1. **比对四项是否与上一份报告逐字相同**：`墙位(含墙位 OI)` / `flip` / `max_pain` / **`levels.total_oi`（最灵敏：一条链几乎不可能两天都不变）**。任一逐字相同 → 整条链未更新。
2. **比对 spot**：`options-gex` spot vs `optioncharts spot`。
   - 差 ≤0.3%（阈值是软的，≤0.4% 且链已换新 → 良性）、**且**四项已换新 → **同日盘中滞后（良性）**：按真实价重算「距现价」，正文注明打印时点即可，**不必降级整行**。
   - 差 ≥0.5%，**或** 四项逐字相同 → **整条链陈旧**：整行标注「只作结构参考」。
3. **`updated_at` 与 `cf_cache` 都不能当新鲜证据**：`--no-cache` 会把 `updated_at` 刷成当次时刻（`cf_cache` 由 `EXPIRED` → `REVALIDATED`）而数值一字不变；`updated_at` 是当天也可能整条链是旧的；`updated_at` 比同批早数小时（IBIT 常落在 ~15:5xZ）也可能仍是新链。
4. **两天的收盘价几乎相同时 spot 比对完全失效**（IBIT 10-30 收 43.36 vs 11-02 收 43.34，差 0.05%）→ 只认第 1 条的总 OI / 四项。

**陈旧时的处置**：① 表 1A 保留 og 值并标「滞后」；② 现价与「距现价」用 `optioncharts spot` 重算；③ **同步改写墙位方向与传导结论**（滞后 spot 会把「支撑」错判成「压力」，结论可能整个翻转）；④ 用 `optioncharts gex/oi --exp <FRIDAY>:w` 的新链判断「近端钉子到底是哪个价」，但**不把两源墙位并列进同一张表**；⑤ 新链每天重读，别沿用昨天的钉子。

---

## 7. 判据与常见坑（实测，逐条遵守）

### 7.1 数据源与命令行为

| 坑 | 处理 |
|---|---|
| 两个数据源同一指标对不上（QQQ put wall 749 vs 730；GLD EM 1.64% vs 1.52%） | **同一指标只取单一来源**：墙位/flip/max pain 取 `options-gex`，成交量/OI/PCR/±1EM 归一化取 `optioncharts`，各自标注来源与时刻，**不并列进同一张表** |
| `put_wall` 的两源分歧表现为「一个在现价上方、一个在下方」（QQQ 680 vs 713） | 不是矛盾而是**选档口径不同**：og 取「现价下方最近的厚 put 档」、oc 取「put gamma/持仓最大档」。墙位字形沿用 og，但表注+正文写出 oc 那一档的几何位置（在上方则是磁铁）。**oc 的 put wall 落在现价上方时，先确认它是否「最大 put OI 档」——是就按磁铁处理** |
| `options-gex` 的 `--dte` 对 `levels`/`walls`/`gex` 无效 | `--dte` 只作用于 `expiries` 与 `scan`；要钉到期日就用 `--exp` |
| `options-gex` 输出格式只有 `pretty` / `compact` / `table` | `--format json` 直接 usage 错、`exit=2`；`pretty` 本身就是缩进 JSON（要结构化就重定向再 parse） |
| `scan` 带 `--exp` 会**关掉 `sign_flips`** | 要期限结构就单跑一次不带 `--exp` 的 `scan --dte N --max-exp M` |
| `sign_flips: []` 有两种含义 | 一是「没有相邻反号」，二是**所有到期日同号**。回看各行正负号：全负/全正本身是强信号 |
| `walls` 的 `call_wall_distance.pct` 符号反直觉 | 其口径是 `(spot − level)/spot`，call wall 在上方时 pct 为负。统一用自己的 `(level − spot)/spot` 重算 |
| `tradingview` 的 `symbol -> EXCHANGE [kind]` 解析行走在 **stderr** | `2>&1` 会污染 CSV 表头；只取 stdout 或加 `--quiet` |
| `tradingview` 偶发 `database is locked` | SQLite 缓存并发报错，`sleep 2–3` 后重试（脚本做 2–3 次重试） |
| 指数/宏观日线滞后 2–4 天，`--no-cache` 也不会变新 | `stale: false` ≠ 是当日价，一律按 `coverage.last` 写「截至 MM-DD」；想要当天值就查 `US10Y --tf 4h` / `VIX --tf 1h`（4h 柱时间戳是其**起点**，15:00Z 覆盖 15:00–19:00Z） |
| 宏观指数日线 `time_iso` 不是自然日历日（GOLD/DXY 是 `22:00Z`、US10Y 是 `23:00Z` ≈ 前一夜会话起点） | 同时写 `coverage.last` 原始值 + 「截至 MM-DD」（按 `time_iso` 的 UTC 日期），不做 ±1 日再解释 |
| 用日线当「今天」 | 日线最后一根常是上一交易日；读 `coverage.last` / `last_bar_age` / `stale`，必要时看 4h |

### 7.2 墙位几何（每天重判，别沿用上一份）

- **`call wall` = gamma 最大的 call 档，不是 call OI 最多的档**（IBIT 盖在 46.5 而堆积在 48；SPY 780 vs 800）。读「盖子/压力」用 gamma 口径，读「持仓堆积/到期引力」用 OI 口径，**两个数都给、但不互相校验**。
- **只有 call wall 在现价上方、put wall 在现价下方才分别是「压力/支撑」**；同侧必须显式说明，改写为「头顶磁铁」，并**另起一行给出脚下最近三格 + 下方最大 put OI 档**。月期权（`:m`）与暴跌日后同侧很常见（GLD/TLT 的 put wall 回到现价上方；暴跌后 SPY put wall 735 在现价上方 0.21%、QQQ 675 在上方 4.17%）。
- **`put_wall` 落在现价 ±1% 内 → 先怀疑 ATM gamma 尖峰**（put gamma 在 ATM 最大）：改看「最大 put OI + 最大负 gamma 节点」定位真实支撑（GLD 369 贴价但只有 2,455 张，真实支撑 363 → 360）。
- **两墙同档**（IBIT call/put 同为 48）= **双面磁铁**，只能读成头顶盖子，**绝不能读成「上有压力、下有支撑」**。
- **两墙反向贴价**（QQQ call wall 720 在下方 0.20% + put wall 725 在上方 0.49%）= **720–725 磁铁带**，真实顶/底退到最大正/负节点。
- **墙位翻转时先看那格 OI 有没有动**：OI 没动 = 现价穿过了那批持仓（几何变化），不是新建仓/撤仓（TLT 81.5 从脚下垫子变成头顶磁铁，OI 只动 <0.2%）。同时补一句「丢掉它之后下面还有没有承接」。

### 7.3 EM / IV / `net_gex` 翻面的读法

- **`EM ∝ spot × IV × √DTE`**。折算一律用**实际剩余时间**：`remaining_days = (exp 16:00 ET − snapshot_utc)/86400`，**取整的 `dte` 只用于报告标签**。同链 `理论 = 旧 1EM × √(Tn/Tp) × (IV_new/IV_old)`（IV 变化 >10% 时必须乘 IV 比例，否则误判成「恐慌消退」）。
- **偏差判据**：≤8% → 日历折算（± 小幅 IV），可直接写「IV 没动」；8–20% → 「略有定价」；>20% → IV 真的跳升。**别把日历效应写成恐慌消退/升温**（IV 涨 12 点而 1EM 只扩 4.9% 是 √DTE 抵消，不是「市场没定价」）。
- **换链（DTE 1 → 7 这类滚动到下周）不可逐字对比**：差额不是「结构恶化/翻面」。§3.1 与 §7 都要声明「换链、不可逐字对比」；可比项只留 ① spot 与当日涨跌 ② ±1EM/IV（注明 √DTE 折算）③ 当周内部纵向%。跨链量级算术只用于判「IV 有没有真的跳」，不作为结论。
- **`net_gex` 大幅翻面（>0.5×|旧值|）先查 OI**：墙位 OI 没动 = 现价移动后的 gamma 重定价（GEX ∝ spot²），写「现价回到了变号线上」，**不要**写「结构转多/转空」。**再跑一次不带 `--exp` 的 `scan` 看整条曲线**：曲线单日翻负而其余混号 = 重定价；全负/全正 = 性质真的变了。**绝对值缩小 + 墙位从脚下搬到头顶 = 脚下保护被抽空（坏消息），不是「负 gamma 减轻」**。
- **DTE 0 的 `net_gex` 当天剧烈变号**（QQQ −\$2.46B → +\$1.51B），只能读成「今日现价附近的 gamma 环境」，**不能外推到周五**。
- **`net_gex` ≈ 0 且 spot 贴在 flip 上**（GLD −\$714K、382.25 vs 382.26）：**不给方向性读数**，写「处在正负 gamma 临界点」，结论看两侧墙位。

### 7.4 ±1EM 区间与量 PCR

- **两端都要验算**：上沿对头顶节点、下沿对脚下节点，差 ≤0.5%（五只同时 ≤0.25% 更有说服力）→ 写「一个标准差刚好够碰到、不够穿过」/「跌得到破不了」，两端同时成立 → 「区间被封在一格之内」，并给出**双向失效条件**（收盘站上/跌破那一格）。这比「上方有压力」硬得多。
- **两端节点的符号必须分开判**：两端全负（SPY/QQQ 暴跌日）→「两道门，出了区间是进入更深的水」（**不是边界事件，没有保护**）；两端全正（GLD/TLT）→「盖子加垫子，真的被钉住」（一次性边界事件）；一正一负 → 分别写。别只写「区间被封在一格之内」就收尾。
- **量 PCR 四象限（先定格当日涨跌，再比量 PCR vs OI PCR）**：
  - 跌 + 量 < OI：抛压在现货/期货侧，期权侧在卖 put 收租；
  - 跌 + 量 > OI：**真的在买保护**；
  - 涨 + 量 < OI：涨着还在卖 put = 纯卖波动率；
  - 涨 + 量 > OI：**「涨着买保险」**，不能写成看多。
- **量 PCR 跳升 > 2 倍而当日价格变动 < 1% → 读作「滚保护」（保险成交）**，不是抛售；跳升 + 同向大跌才是真抛压。
- **暴跌日量 PCR 远低于 OI PCR = 抛压在现货侧**（SPY −4.35% 时 1.13 vs 1.90）：写「要现金不要合约 / 仓位被迫调整」，并说明「没有保护性买盘托市、也没有恐慌性买盘见底」；**确认恐慌要用 IV 与每日隐含幅度**（SPY IV 14.91 → 37.04、每日隐含幅度 +246%），不能用量 PCR。只有量 PCR > OI PCR 才是真在买保护。

### 7.5 流程与其他

- **多日未跑（定时任务失败）时**：§0 与 §7 必须写明「上一份是哪一天、中间哪几天缺」，逐项差额标成「N 个交易日合计」而非日变化。失败日志要区分 `pi exit=1`（网络/模型中断）与 `exit=0 但无产物`（末轮只推理不落盘），§9.1 的重试只对后者有效。
- **两源 `dte` 计数可能差 1**（og 5 / oc 6，边界是否含当天不同）：报告统一用 `options-gex` 的 DTE，或写「DTE 5（optioncharts 记 6）」。
- **禁项**：跨标的直接比 `net_exposure`（§4.5）；引用指数序列的成交量；把 `em` 锥形当某到期日 EM；报告里混入非周五的结论；给 TLT/GLD/IBIT 写独立结论；粘贴英文 insights；写成给专业读者的语气。
- **`run-options-briefing.sh` 产物缺失**（`exit=0` 不代表有产物：曾出现末轮只输出思考、没调写文件工具）：脚本已加固为产物缺失自动重试一次（第二次 prompt 要求「先建骨架再补细节、复用 /tmp 抓取结果」），两次都缺才 `exit 1`，并对 `## 摘要卡` / `## 供简报引用（通俗结论）` 做锚点告警。每次跑完仍要自己确认产物存在。

---

## 8. 质量检查清单（落盘前逐项过）

- [ ] 结论只针对**周五**那一个到期日，`selected_exp` 与标题一致；**限结构（`sign_flips`）来自不带 `--exp` 的 `scan`，且只进分析过程**
- [ ] TLT / GLD / IBIT 只写**传导含义**，无独立方向性结论与交易建议；加密（USDT.D + BTCUSD）独立成节、周/日/4h 齐备
- [ ] 每个数字都带来源与快照时刻；同一张表不混源、不混快照；全文数字来自落盘前最后一次重跑的 `scan`/`walls`
- [ ] **判旧链四项已比对**（墙位/flip/max_pain/`total_oi`）且 `optioncharts spot` 逐只交叉核对：不一致的已重算距现价、**改写墙位方向与传导结论**、整行标注「只作结构参考」；没有只靠 spot 差值或 `updated_at` 判新鲜
- [ ] `摘要卡` 与 `供简报引用（通俗结论）` 存在、零术语、可直接抄进简报
- [ ] ±1EM 来自 per-expiry EM；剧本 A/B/C 都给了触发条件与目标位
- [ ] 1EM **两端**都验算过（含与墙位差 ≤0.5% 的表述）且**两端节点符号**已判（全负=两道门 / 全正=盖子加垫子）
- [ ] 每个墙位都按**几何位置**核过；同侧、贴价（±1%）、两墙同档、两墙反向贴价四种情形已按 §7.2 改写并单列表注；若 `put_wall` 在 ±1% 内已排除 ATM gamma 尖峰
- [ ] 墙位翻转 / `net_gex` 翻面已先查 OI 与整条期限曲线；`net_gex` ≈0 未给方向性读数；DTE 0 的窄 EM 未被当成常态
- [ ] 量 PCR 已按当日涨跌做四象限判读；跳升 >2 倍、或低于 OI PCR 的大跌日已按 §7.4 固定写法处理
- [ ] 同链 DTE 缩短时折算用了**实际剩余时间**，IV 变化 >10% 时乘了 IV 比例；偏差写对档位；**换链已声明「不可逐字对比」**
- [ ] IBIT ↔ BTC 换算用了当日**最近一根已收盘 1h/4h** 的比值，没写死、没用日线 close
- [ ] tradingview 标了 `coverage.last`/`as_of`/`stale`，宏观指数按「截至 MM-DD」写；没用量能推断
- [ ] 若前后两份跨多个交易日：§0 与 §7 写明上一份日期与缺失日，差额标「N 个交易日合计」
- [ ] §7「与上一份报告的差异」已写（或注明首份）；找上一份：`ls -t briefing-playbook/options-briefing-*.md | head -2`
- [ ] §0 口径段落与末节免责完整；无编造（所有数字都能在本次命令输出里找到出处）；文件名与路径正确

---

## 9. 定时任务与部署

### 9.1 触发方式

`run-options-briefing.sh`（本目录）就是「定时 `@` 手册」的实现：用 `pi -p "@options-briefing-playbook.md"` 非交互执行本手册。

```bash
# 与简报同机（gcp:/root/pi-playbook）时，加在 root 的 crontab：
# TZ=Asia/Shanghai 05:00 执行 —— 美东 16:00 收盘 = CST 04:00/05:00，05:00 已有当日收盘快照
0 5 * * 2-6 /root/pi-playbook/run-options-briefing.sh >> /var/log/run-options-briefing-cron.log 2>&1
```

- **时间顺序**：期权日报必须**早于**每日简报（简报 06:00 读它）。
- **`2-6`（CST 周二至周六）= 美东周一至周五收盘后**；写 `*` 也可以，但周末报告只是上一交易日的重复。
- 幂等：当天产物已存在（`-s`）就跳过；重跑先删文件。防重入：`flock` 持 `briefing-playbook/options-briefing.lock`。失败重试见 §7.5。

### 9.2 产物必须与简报 agent 同机同目录

简报 agent 在 **gcp:/root/pi-playbook** 上 06:00 执行，只读本机文件。

- 在 gcp 上跑 → 产物直接落 `/root/pi-playbook/briefing-playbook/`，无需同步。
- 在别的机器跑 → 生成后必须同步：

```bash
scp -q briefing-playbook/options-briefing-$(date +%F).md \
    gcp:/root/pi-playbook/briefing-playbook/ && \
ssh gcp "md5sum /root/pi-playbook/briefing-playbook/options-briefing-$(date +%F).md" && \
md5sum briefing-playbook/options-briefing-$(date +%F).md        # 两端一致即成功
```

### 9.3 换机器要补的东西（`.agents/` 不入 git）

1. `git clone` 仓库 → 得到本手册与两个 `run-*.sh`。
2. 拷三个技能目录到 `.agents/skills/`：`options-gex`、`optioncharts`、`tradingview`（gcp 上曾缺后两个）。
3. `cd .agents/skills/tradingview && npm install`。
4. 确认 node ≥ 22.13（cron 环境靠 `~/.config/ai-env.sh` + 脚本里显式把 `/root/micromamba/envs/pi/bin` 加进 PATH）。

---

## 10. 经验沉淀（全部执行完毕后必做）

- 本次执行有没有新的坑（命令行为、限流、字段含义、数据源改版）、用户新偏好、或实测验证过的结论？**有就立即写回本手册对应章节**（口径→§6，判据/坑→§7，检查项→§8）。沉淀**只留结论与判据**，不要堆日志与逐日流水；同类情形合并成一条。
- 更新后提交（`briefing-playbook/` 被 `.gitignore` 忽略，日报不用提交）：

```bash
cd "$PLAYBOOK_DIR" && git add options-briefing-playbook.md run-options-briefing.sh && \
  git commit -m "docs: 更新期权日报 playbook（<一句本次经验>）"
```

- 无新经验则跳过，不强行改动。
