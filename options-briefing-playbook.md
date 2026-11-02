# 期权与加密日报生成手册（Options & Crypto Briefing Playbook）

> 本手册写给任何新的 agent。读完全文即可独立完成一份《期权日报（Markdown）》的抓取、分析、写作与自检，满足用户的全部要求。
> 本手册总结 2026-10-05 首次实操中确认的口径、命令行为与踩过的坑，**优先级高于一般直觉**。
> **当用户贴出这份手册、或定时任务 `@` 本手册且未指定其他任务时，即为执行本手册**：生成当日的 `briefing-playbook/options-briefing-YYYY-MM-DD.md`。
> 三个技能全部**只读**：只查数据，不下单、不改账户状态。

---

## 0. 任务概述

- **一句话任务**：抓 GLD / IBIT / TLT / SPY / QQQ 的**本周五到期**期权结构，加 USDT.D / BTCUSD 走势，写成一份 Markdown 日报，供下游「每日简报 agent」二次分析。
- **交付物**：`briefing-playbook/options-briefing-YYYY-MM-DD.md`
  - 目录 = 仓库根的 `briefing-playbook/`（与 HTML 简报同一个文件夹，命名同理只是扩展名与主题前缀不同，便于简报 agent 顺手读取）。
  - `YYYY-MM-DD` = **生成本地日期（Asia/Shanghai）**，与同日 `briefing-YYYY-MM-DD.html` 对齐；文件内单独注明覆盖的**美东交易日**（两者可能差一天）。
- **执行方式**：从抓取 → 分析 → 写作 → 自检 → 落盘是一次操作，**中间不问用户**；只有抓取失败/数据缺失才停下报告。
- **三条硬规则（用户明确要求，违反即返工）**：
  1. **期权结论只给周五到期日**。所有 GEX / 墙位 / max pain / 剧本结论都锁定在「最近的、尚未到期的那个周五」（§2）；0DTE 与月中月期权只在内部用于期限结构判断（如 `sign_flips`），**不进结论、不进表格**。
  2. **GLD / IBIT / TLT 只作为传导腿**：从美债、黄金、加密/流动性三个角度分析它们**对 SPY、QQQ 的影响**，不写这三个标的自己的独立方向性结论或交易建议。
  3. **USDT.D + BTCUSD 单独成节**（第二部分），这一节允许有自己的走势结论与关键位。
- **下游契约**：简报 agent 只读 §5 模板里的两个稳定锚点——顶部「摘要卡」和 `## 供简报引用（通俗结论）` 小节。写这两块时**假设读者不懂期权**：不出现 GEX / gamma flip / max pain 之类术语，只给「哪里是压力、哪里可能破、偏上还是偏下」。

---

## 1. 数据源与入口

| 技能 | 入口（相对仓库根） | 用来拿什么 |
|---|---|---|
| `options-gex` | `.agents/skills/options-gex/bin/options-gex` | 单到期日的 `net_gex` / `gamma_flip` / `call_wall` / `put_wall` / `max_pain` / per-expiry `implied_move_pct` / `stm_iv` / `pc_oi_ratio` / `bullish_score`；`scan` 出多标多到期日简表与 `sign_flips` |
| `optioncharts` | `.agents/skills/optioncharts/bin/optioncharts` | 链统计（`volume_total`、`volume_pcr`、`oi_total`、`iv_pct`、per-expiry `expected_move_abs/pct`）、逐行权价 `oi` / `volume`、`--gex` 的 ±1EM 归一化字段；`spot` 出实时价（交叉核对 `options-gex` 的 spot，见 §3 ②b） |
| `tradingview` | `.agents/skills/tradingview/bin/tradingview` | USDT.D / BTCUSD / US10Y / GOLD / DXY / VIX 的已收盘 K 线与**大道至简**指标（kc1 / kc2 / kc_low / ema_high·low / median_200 / MACD） |

环境准备：

```bash
export PLAYBOOK_DIR=/root/pi-playbook          # 定时任务里由 run-options-briefing.sh 设置；手动执行用仓库根
export PATH="$PLAYBOOK_DIR/.agents/skills/options-gex/bin:$PLAYBOOK_DIR/.agents/skills/optioncharts/bin:$PLAYBOOK_DIR/.agents/skills/tradingview/bin:/root/micromamba/envs/pi/bin:$PATH"
node -v            # 需要 ≥ 22.13（skills 直接跑 TypeScript）
```

- **`tradingview` 首次使用必须先 `npm install`**：否则所有命令都只输出
  `tradingview: dependencies missing — run: (cd "<dir>" && npm install)`（实测 2026-10-05，装 5 个包、2 秒）。
- `.agents/` 被 `.gitignore` 忽略 → 技能不随 git 同步，**换机器要手动拷**（§9.3）。
- 两套期权数据源、三套口径，**同一张表里绝不混源**（§7）。

---

## 2. 目标到期日：只锁「本周五」

- 周度期权每周五到期，所以日报的唯一天期权就是**最近的、尚未收盘/尚未到期的那个周五**。
  - 美东为周一至周五（且周五未到 16:00 ET 收盘）→ 取**本周五**。
  - 美东已是周五收盘后、或周六/周日 → **顺延到下一个周五**。
- 一天的边界一律按**美东**算；`date` 是本机 CST，两者差 12 小时，**不要用 `date -d "next friday"` 直接算**。
- 周末/节假日运行（美东周六日）时目标周五顺延到**下一周**，DTE 常为 5–6，且**很可能是月期权**（本月第三个周五，后缀 `:m`）；周末快照下行情全部冻结在**上一个交易日收盘**，报告要写清"覆盖美东交易日"与 DTE 5 的口径差异（§5、§6）。
- **到期日当天（周五、收盘前）运行**（如手动/补跑，实测 2026-10-16 05:11 ET）：目标周五就是**当天**、两源 `dte` 均为 **0**，且第三个周五仍是 `:m`。此时 `market_session = "pre"`、价格是**前一交易日的收盘/盘前读数**，报告要写清"覆盖美东 <前一交易日>"；结构上 `±1EM` 与关键位会比平时**明显收窄**，剧本应围绕**钉子位 + max pain** 写（本轮 SPY ±1EM 仅 3.97 / 0.51%、QQQ 6.14 / 0.84%），并在标题与 §0 显式注明 **DTE 0**。

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

- **到期日后缀必须查一次**：`optioncharts` 的 `--exp` 要带 `:w` / `:m`，**第三个周五是月度到期日（`:m`）**，其余是 `:w`；只写裸日期会触发解析（多一次请求并写 warning，默认 exit 5）。用 `optioncharts expiries <T> --dte 20` 看每个周五的后缀，别猜。
- `options-gex` 的 `--exp` 用**裸日期**即可（如 `--exp 2026-10-09`），并在输出里回读 `provenance.selected_exp` 核对；**服务端不会因非法/过期日期报错，而是静默回落到最近到期日**，所以报告里必须写 `selected_exp` 与 DTE。
- 报告标题/摘要卡里写清：目标到期日（周几、DTE）、快照时刻（UTC + 美东）。

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

# ②b 现价交叉核对（**必做**：`options-gex` 的 spot 偶尔整天滞后，实测 IBIT 中过招）
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

# ⑥ 加密与宏观腿（tradingview，多周期各跑一次）
for tf in W 1D 4h; do
  "$SK/tradingview/bin/tradingview" indicators BTCUSD --tf $tf --count 12 \
    --select time_iso,open,high,low,close,kc1_mid,kc1_lower,kc_low_lower,median_200,macd,macd_hist --format csv
done
"$SK/tradingview/bin/tradingview" indicators USDT.D --tf W --count 10 --select time_iso,close,kc1_mid,kc1_lower,median_200,macd,macd_hist --format csv
"$SK/tradingview/bin/tradingview" indicators USDT.D --tf 1D --count 25 --select time_iso,close,kc1_lower,median_200,macd,macd_hist --format csv
# 宏观背景（各 1~2 条即可，别倒几百根）
"$SK/tradingview/bin/tradingview" indicators US10Y --tf W --count 12 --select time_iso,close,median_200,macd_hist --format csv
"$SK/tradingview/bin/tradingview" indicators GOLD  --tf 1D --count 12 --select time_iso,close,kc1_mid,median_200,macd_hist --format csv
"$SK/tradingview/bin/tradingview" indicators DXY   --tf 1D --count 12 --select time_iso,close,kc1_mid,median_200,macd_hist --format csv
"$SK/tradingview/bin/tradingview" indicators VIX   --tf 1D --count 8  --select time_iso,close,median_200,macd_hist --format csv
```

**请求预算**：`options-gex` REST 限流 **30 次/IP**（60 秒本地缓存会吸收同一 `(ticker, exp)` 的重复调用），上面 ① ② 合计约 10 次；`optioncharts` 实测无限流、TTFB ~2s，②b③④⑤ 约 10 次。一天一轮完全够用，**不要跑 `raw`**。

---

## 4. 分析框架

### 4.1 期权读数顺序（每个标的都照这个顺序说）

1. **口径**：这是 `selected_exp` 单到期日的数据，不是多日汇总；`net_gex` 假设全部合约由 dealer 中介。
2. **现价 vs `gamma_flip`**：上方 = 正 gamma（dealer 高抛低吸、压波动）；下方 = 负 gamma（助涨助跌）。
3. **`net_gex` 正负**：正 = 波动被压制（区间行情）；负 = 单边容易被放大。
4. **墙位 + OI**：`call_wall`（上方卖压/硬顶）、`put_wall`（下方支撑）；墙位数字优先取 `walls` 命令，并带上墙位 OI 与到现价的百分比距离。
5. **`max_pain`**：到期日引力位；报告里给「距现价 %」（max pain 只影响到期日附近的漂移，不是日内目标）。
6. **EM 与聚集度**：`implied_move_pct`/`expected_move_abs`（**per-expiry 口径**）给 ±1EM 区间；`net_exposure_within_1em_share_pct` / `abs_share_within_1em_pct` 说明 gamma 有多集中在现价附近（>60% = 强钉住）。
7. **资金流**：`volume_pcr`（当日量）与 `pc_oi_ratio`/`oi_pcr`（持仓）；两者与 SPY 明显背离时值得单独一句。
8. **期限结构（内部用）**：`scan` 的 `sign_flips` 标出相邻到期日净 GEX 反号，用来判断「周五是不是被单独压/独独撑」——**只写进分析过程，结论仍只落周五**。

### 4.2 三条传导腿（TLT / GLD / IBIT）—— 每条四句话，缺一不可

| 腿 | 宏观腿（tradingview） | 期权腿（options-gex / optioncharts） | 必须给出的触发位 | 必须回答的问题 |
|---|---|---|---|---|
| **TLT（美债）** | US10Y 的周线方向 + MACD 柱、DXY 强弱 | TLT 周五 `net_gex`/flip/walls/max_pain/OI PCR | 跌破 flip → 长端利率压力；收复并黏在 max pain | 对 QQQ（高估值成长）是**减压还是加压**？QQQ 的哪个位对应？ |
| **GLD（黄金/实际利率）** | GOLD 的周线与日线 kc1_mid/median_200、DXY | 同上（注意 GLD 周五常是全表唯一负 gamma） | 跌破 put wall 与收复 flip 各自意味着什么 | 与收益率上行是否共振？风险偏好是收缩还是缓解？ |
| **IBIT（加密/流动性）** | BTC 周线、USDT.D 方向 | IBIT 周五 gamma 堆积区（正/负节点） | 墙位破/守 → 风偏外溢 | 给 QQQ 的是「托底」还是「退潮」？ |

- **IBIT ↔ BTC 换算**：用**当日** `IBIT spot` 与 BTCUSD **最近一根已收盘的 1h（或 4h）K 线收盘价**的比值换算（实测 2026-10-05 用 1h 18:00Z close = 85,656.87 → 比值 **1764**；区间约 1764–1790 随日漂移，**不要写死**），把 IBIT 的墙位翻译成 BTC 价位写进报告。**别用日线 close**：日线最新一根只到前一交易日，实测会把比值抬到 1781（差 ≈1.4%）。
- **只输出传导含义**：可以写「TLT 跌破 75.9 会把长端压力传导到 QQQ 的 749/742」，**不要**写「TLT 可以做多/做空」。

### 4.3 SPY / QQQ

每个标的按固定四段写：**结构 → 关键位 → 剧本 A/B/C → 与另一指数的分歧**。

- 结构：`net_gex` 量级与本周位置（是不是周五独大）、正/负 gamma 节点分布（带 `share_of_abs_total_pct`）、OI 密集度、资金流。
- 关键位表：`±1EM 区间` / 钉子位 / 上方硬顶 / 下方破位触发 / 偏向。
- 剧本：**A 基准**（概率最高，给区间与收敛方向）、**B 风险**（触发条件 → 目标位）、**C 上破**（触发条件 → 目标位，并说明为什么概率低——通常是正 gamma 墙）。
- 分歧：SPY 净买 call 而 QQQ 净买 put 这类量能背离，必须写「若风偏回落谁跌得多」。

### 4.4 加密（第二部分，允许独立结论）

- **USDT.D**：周线趋势（kc1_mid/median_200/MACD 柱）+ 日线（kc1_lower 超卖、MACD 柱转向）→ 箱体区间 → 关键位 → 一句话结论（下行使风险资产顺风）。
- **BTCUSD**：周线（趋势与 MACD 柱是否扩张）+ 日线（是否贴外轨/kc1_upper、MACD 柱收敛）+ 4h（动能是否降温）→ 阻力/支撑 → 未来一周大概率是「震荡消化」还是「续涨」。
- **合成**：USDT.D 下 + BTC 上 = 流动性宽松/risk-on；再与 **IBIT 周五期权堆积区**互证，写成「托底但不推升」这类可验证的表述。
- **反向共振**要写出来：USDT.D 若在箱体底部止跌反弹（资金回稳定币）→ 加密回调 → IBIT 丢关键支撑 → 与黄金/美债的看空腿合流。

### 4.5 跨标的比较必须归一化

- `net_exposure` 是**每 1% 标的变动的美元 gamma/delta**（`usd_per_1pct_move`），量级随合约名义额变化（实测 TLT ≈ \$7.7k/张，SPY/QQQ ≈ \$75k/张）。**直接比大小会系统性低估 TLT**。
- 正确做法：同桶内用 `share_of_abs_total_pct` 定位墙位；跨标的用**按 `sigma_pos`（±EM）对齐**或比较 `net_exposure_within_1em_share_pct` / `abs_share_within_1em_pct`。

---

## 5. 报告模板（.md 骨架）

文件名：`briefing-playbook/options-briefing-YYYY-MM-DD.md`。结构如下，**标题层级与锚点不要改名**（简报 agent 依赖 `## 供简报引用（通俗结论）` 与 `## 摘要卡` 两个锚点）：

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
（表格：抓取时刻、来源、目标到期日、现价、以及"OI 为上一交易日收盘值 / 期权 15 分钟延迟 / 第三方聚合"等口径声明）

## 1. 周五（MM-DD）一览
（五标的 × 列：spot / net GEX / flip / spot vs flip / call wall(OI) / put wall / max pain / IV / ±1EM / 量PCR · OI PCR）

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
（没有上一份就写"本日为首份"；有就逐条写变化——墙位挪动、flip 翻面、剧本切换）

## 供简报引用（通俗结论）
（3–6 句，无术语，可直接抄进每日简报；含关键位与偏向；结论反转要明说）

## 数据来源与免责
（口径段落，见 §6）
```

写作要求：

- **术语只出现在 §0–§5 的分析部分**；`摘要卡` 与 `供简报引用` 必须零术语（不写 GEX / gamma / max pain / EM / PCR）。
- 数字**带来源与时刻**：来自 `options-gex` 就写 `net_gex ≈ +\$6.4B（19:17 UTC）`，来自 `optioncharts` 的 PCR 就标 `optioncharts`。同一张表里不混两个快照。
- 数字**取整到合理精度**（`$6.35B` 而不是 `$6350000000.0`），spot 保留两位小数，百分比一位小数。
- 区间用 `±1EM` 给，**不要**用 `em` 锥形的 `em_amt`（那是 spot-anchored 曲线，不是某个到期日的 EM）。
- 报告里**不要**出现第三方 insights 的英文原文；要引用就翻译改写。

---

## 6. 口径与免责（报告 §0 与末节必须照抄的要点）

- **GEX 定义（第三方口径，勿自算）**：`GEX_contract = gamma × OI × 100 × spot² × 0.01`，call 为正、put 为负。正 `net_gex` = dealer 多头 gamma（高抛低吸、压制波动），负值反之。
- **单到期日口径**：`gamma_flip` / `max_pain` / walls / `net_gex` 全部只属于 `selected_exp` 这一个到期日。
- **OI 是上一交易日收盘值**，不代表盘中持仓变化；`net_gex` 假设全部合约由 dealer 中介。
- **数据源为第三方聚合**（Sell The News / optioncharts），非交易所原始数据；`updated_at` 是服务端计算时刻，**不是行情时间戳**。
- **期权报价为 OPRA 15 分钟延迟**（不适合做盘中执行级信号），`spot` 为实时（Polygon.io）。
- **`spot` 必须交叉核对**：`options-gex` 的 `spot` 偶尔整天滞后（实测 2026-10-07 IBIT、2026-10-08 **IBIT 与 TLT 同时中招**；TLT 的 `updated_at` 停在美东 10-07 21:00，spot 返回 77.175 = 10-07 收盘，而真实 10-08 收盘 77.87（+0.94%））。以 `optioncharts spot <T>`（实时 Polygon）为准交叉，不一致时用真实价重算"距现价"，并在报告里写明"本标的现价取自 optioncharts / 墙位数值锚定在滞后 spot 上，只作结构参考"。**若该标的 `updated_at` 落后一个交易日，则整条链（walls / flip / max_pain / OI）都是上一交易日的，不能只当成 spot 一个字段的问题。** **⚠️ 反向陷阱（实测 2026-10-12）：`--no-cache` 重跑会把 `updated_at` 刷新成当次计算时刻（IBIT `10-12T12:50Z` → `10-12T21:00:31Z`、TLT `10-11T04:01Z` → `10-12T21:00:31Z`），但 spot / 墙位 / flip / max_pain 一个数都不变——`updated_at` 只证明"服务端什么时候算的"，**不能拿它当"数据新鲜"的证据**；判滞后只能靠 `optioncharts spot` 逐只比对。** **两档判据（2026-10-16 补充）：差 ≤ 0.3% 且该标的的墙位/flip/max_pain 与上一份不同 → 只是 spot 的打印时点早于收盘（同日盘中滞后、链是新的），按收盘价重算"距现价"并在正文注明即可、不必把整行降级；差 ≥ 0.5%、或链数值与上一份逐字相同 → 整条链未更新，整行标注"只作结构参考"。** **阈值是软的（2026-10-23 实测：IBIT og 46.11 vs 收盘 45.96，差 **0.33%** 略超 0.3%，但墙位 46.5/45.5 → 48/48、max pain 46.5 → 47.5 全换、optioncharts 同一到期日也给 48/48/47，且 og spot 与 tradingview **1h 16:30Z 的 46.15** 吻合 → 仍是良性同日滞后）。判据的分量排序：**链是否换新 + 第二数据源是否同值 > 差值的具体百分比**；只要这两条成立，0.4% 以内的差都按良性处理。** **补充（2026-11-02）：`spot` 一致也不等于链新鲜**——若两天的收盘价几乎相同（IBIT 10-30 的 43.36 vs 11-02 的 43.34，差 0.05%），陈旧链的 spot 会恰好落在"正确值"上，spot 比对**完全失效**（当日 og spot 43.37 vs 实时 43.34 只差 0.07%，但 `net_gex`/flip/47/44/max pain 46.5/`total_oi` 125,815 全部与上一份逐字相同，而 optioncharts 新链 OI 已是 259,681）。→ **判陈旧的硬判据排序：总 OI 是否逐字相同 > 墙位/flip/max_pain 是否逐字相同 > spot 差值。**
- **`bullish_score` 由上游定义、组成未公开**，只作横向参考，不可解释成具体指标。
- **`gamma_flip` 与 `zero_gamma_estimate`** 是两个口径：后者是行权价网格上的线性插值交叉校验，相差几美元属正常，**报告以 `gamma_flip` 为准**。
- **`oi_source` 若不是 `"oi"`**，说明统计口径可能变成成交量，必须在报告里说明。
- **tradingview 只返回已收盘 K 线**：日线在其收盘后还要等满 24 小时才出现（保守），报告里写 `coverage.last` 与 `as_of`；`USDT.D` / `US10Y` / `GOLD` / `DXY` / `VIX` 是**指数/百分比序列**，`volume_reliable: false`、`volume` 为 `null`，**不要用它们的量能做推断**。实测 2026-10-05 的滞后期：`GOLD`/`US10Y`/`DXY` 日线最末一根是 10-01、`VIX` 是 10-02（`stale: true`，age 3–4 天），BTCUSD/USDT.D 日线是 10-04（交易日的上一日），`--no-cache` 也不会让它们变新。**写"当前价"：加密用最近已收盘的 1h/4h K 线，宏观指数明确写"截至 MM-DD"。**
- 免责：本报告是公开持仓结构的读数，不构成投资建议。

---

## 7. 常见坑（实测，逐条遵守）

| 坑 | 处理 |
|---|---|
| 两个数据源的同一指标对不上 | 实测同一到期日 QQQ 的 put wall 在 `options-gex` 是 749、在 `optioncharts` 是 730；GLD 的 EM 是 1.64% vs 1.52%/1.65%。**同一指标只取单一来源**：墙位/flip/max pain 取 `options-gex`，成交量/OI/PCR/±1EM 归一化取 `optioncharts`，各自标注来源与快照时刻，**不并列进同一张表** |
| 快照漂移很快 | 实测约 2 分钟内 SPY `net_gex` 从 +\$4.84B → +\$5.71B → +\$6.35B，spot 775.67 → 776.31。**写报告前重跑一次 `scan` 与 `walls`**，全文只引用这一次的数（或分块标注各自时刻），不要把两个小时前的数字和现在的混用 |
| `options-gex` 的 `--dte` 对 `levels`/`walls`/`gex` 无效 | `--dte` 只作用于 `expiries` 与 `scan`；其它命令传了只在 stderr 提示忽略。要钉到期日就用 `--exp` |
| `options-gex` 的输出格式只有 `pretty` / `compact` / `table` | `--format json` 会直接报 usage 错并以 `exit=2` 退出（实测 2026-10-20）；**`pretty` 本身就是缩进好的 JSON**，要结构化解析就用 `pretty`（重定向到文件再 parse），要省 token 用 `compact` |
| `options-gex scan` 带 `--exp` 会**关掉 `sign_flips`** | 实测 2026-10-05：`scan ... --exp 2026-10-09` 返回 `sign_flips: []` 并在 `warnings` 里写 `"--exp pins the scan to 2026-10-09"`。**要期限结构就单跑一次不带 `--exp` 的 `scan --dte N --max-exp M`**（见 §3 ①b），带 `--exp` 的那次只用来取单日总览 |
| `walls` 输出里的 `call_wall_distance.pct` 符号反直觉 | 它的口径是 `(spot − level)/spot`，所以 **call wall 在现价上方时 pct 是负数**（实测 SPY 787 → −1.39，put wall 767 → +1.18）。报告里统一用自己的口径 `(level − spot)/spot` 重算一遍，别直接抄 |
| `tradingview` 的 `symbol -> EXCHANGE [kind]` 解析行走 **stderr** | 用 `2>&1` 拼起来会污染 CSV 表头（实测 `BTCUSD -> BITSTAMP:BTCUSD [alias/high]`）。解析 CSV/JSON 时只取 stdout，或加 `--quiet` |
| 指数/宏观序列的日线滞后 2–4 天 | 实测 2026-10-05：`GOLD`/`US10Y`/`DXY` 最末日线是 10-01、`VIX` 是 10-02（`stale: true` 时 age 3–4 天，2026-10-06 实测 age 1.8–2.3 天时 `stale: false`——**`stale: false` ≠ 是当日价**，仍要按 `coverage.last` 写"截至 MM-DD"；`--no-cache` **不会**让它们变新，不要当成当日价 |
| 宏观指数想要"当天值"就用 4h / 1h，不要死等日线 | 实测 2026-10-19：`US10Y --tf 4h` 给出 `coverage.last = 10-19T15:00Z` 收 **5.136%**（日线却停在 10-15 的 5.081%）、`VIX --tf 1h` 给出 `10-19T19:30Z` 收 **18.43**（日线停在 10-16 的 19.98）。→ **写"截至 10-15"之外再补一句当天 4h/1h 的读数**，长端与恐慌指数才有当日参照；4h 柱的时间戳是其**起点**（15:00Z 的柱覆盖 15:00–19:00Z），别把它当成"最新一分钟"。 |
| 宏观指数日线的 `time_iso` 不是自然日历日 | `GOLD`/`DXY` 的日线 `time_iso` 是 `22:00Z`、`US10Y` 是 `23:00Z`（≈ 18:00/19:00 ET，即**前一夜的会话起点**），所以 `2026-10-05T22:00Z` 那根对应的是**次一交易日**的 session。报告里沿用既有做法：**同时写出 `coverage.last` 的原始值 + "截至 MM-DD"（按 `time_iso` 的 UTC 日期）**，不做 ±1 日的再解释，读者可用原值自行校准 |
| `optioncharts` 的到期日必须带 `:w`/`:m` | 裸日期会被解析并可能静默换到期日（默认 exit 5）；第三个周五是 `:m`。用 `expiries` 查后缀 |
| `optioncharts expiries` 现在会列出**周一～周四的日到期**（不止周五） | 实测 2026-10-11：SPY `--dte 20` 返回 `2026-10-12:w` / `10-13:w` / `10-14:w` / `10-15:w` / `2026-10-16:m` / …。查目标周五后缀时按 `date` 定位那一行，别被前面的日到期行带偏（第三个周五仍是 `:m`）；`--dte N` 是**上限**不是精确值 |
| 两个来源对同一个到期日的 **DTE 计数可能差 1** | 实测 2026-10-16：`options-gex scan` 记 `dte: 5`、`optioncharts expiries` 记 `dte: 6`（边界是否计入当天不同）。报告里统一用 options-gex 的 DTE，或写"DTE 5（optioncharts 记 6）" |
| **月期权（第三个周五 `:m`）的墙位可能与现价同侧** | 实测 2026-10-16：GLD 的 `put_wall = 400`（现价 384.59）、TLT 的 `put_wall = 79`（现价 77.96）**都落在现价上方**——这是整数关口堆积的 put 持仓，不是"现价下方的支撑"。**墙位按几何位置读、不按名字读**：只有 call wall 在现价上方、put wall 在现价下方时才分别是"压力/支撑"；同侧时必须显式说明（两个数据源此时会给出一致的墙位）。**注意这是逐日结构、不是月期权的固有属性**：同一个 10-16 到期日，GLD 的 `put_wall` 在 10-09 快照是 400（现价上方），到 10-12 快照就回到 380（现价下方）——每天必须重新按几何位置判读，不要沿用上一份的结论。**同侧的不止 put wall（实测 2026-10-13）：TLT 的 `call_wall = 78` 落在现价 78.37 下方（"下方正 gamma 堆积"而非头顶压力），GLD 的 call/put wall 更是同为 380、都在现价下方。判读一律只看几何位置：call wall 在现价上方才是顶、put wall 在现价下方才是撑；同侧（含 call/put 同档）必须在报告里显式说明。** |
| 忘了 `tradingview` 要装依赖 | 首跑 `npm install`，否则所有命令报 `dependencies missing` |
| `tradingview` 偶发 `database is locked` | 连续/并发调用下 SQLite 缓存会整条返回 `{"error":{"code":"ERROR","message":"database is locked"}}`（实测 2026-10-06 `BTCUSD --tf W` 首跑即中）。**sleep 2–3 秒后重试即可成功**；脚本里对交易视调用做 2–3 次重试 |
| 同一次 `scan` 内各标的 `updated_at` 可能差数小时 | 实测 2026-10-06 一次 `scan GLD IBIT TLT SPY QQQ`：SPY/QQQ/GLD ≈ 21:00Z，但 **TLT = 01:00Z、IBIT = 12:50Z**（服务端计算时点滞后）。**必须逐标的读 `provenance.updated_at`**，滞后的在正文注明"数据略滞后"，不要当成同一时刻的快照。**但 `updated_at` 早 ≠ 数据滞后（实测 2026-10-13：TLT `updated_at = 13:52:28Z`，比同批其余标的的 ~20:59Z 早 7 小时，spot 78.35 却与当日收盘 78.37 完全吻合、链数据可用）——`updated_at` 只是"服务端何时算的"，是否滞后仍只认 `optioncharts spot` 逐只比对。** |
| **`options-gex` 的 `spot` 可能整天滞后**（实测 2026-10-07 IBIT；2026-10-08 **IBIT + TLT 同时中招**） | IBIT：`walls` / `scan` / `provenance` 全部回读 `spot = 48.515`（≈ 前两天收盘），`updated_at` 抖动但 spot 不变、`--no-cache` 重取也一样；optioncharts `spot IBIT` 与 tradingview `IBIT --tf 1h/30m` 两个独立来源都给出当日真实收盘（10-07 **47.20（−2.66%）**、10-08 **46.26（−2.01%）**）。TLT：`updated_at = 2026-10-08T01:00Z`（≈ 美东 10-07 21:00）时整条链都停在 10-07，spot 返回 77.175，真实 10-08 收盘 77.87（optioncharts 与 tradingview 1h 一致）。**处理：抓完 ② 立刻跑 §3 ②b 的 `optioncharts spot` 交叉核对；不一致时现价与"距现价"用真实值重算，并在报告里注明"墙位/flip/max pain 的数值锚定在滞后 spot 上、该标的只作结构参考"。** 其余标的两个来源一致（2026-10-08 实测 SPY 773.78/773.93、QQQ 747.61/747.58、GLD 378.47/378.62） |
| `options-gex` 某标的 `updated_at` 落后一个交易日 → **整条链都是上一交易日的** | 实测 2026-10-08 TLT：`updated_at = 2026-10-08T01:00Z`，`scan` / `walls` 的全部数值（`net_gex` +$69.11M、flip 75.91、call/put wall = max_pain = 78）与上一份报告**逐字相同**，因为源数据根本没更新。**判据（2026-10-12 修正）：`updated_at` 不可靠——`--no-cache` 会把它刷新成当次计算时刻而数据仍是旧的（同日 IBIT 46.56 / TLT 77.96 都停在 10-09 收盘）。正确判据是"该标的的 spot 与 `optioncharts spot` 是否一致"：不一致就把该标的整行（含墙位与结构结论）标注"只作结构参考"，不要用它的墙位做精确距离结论；`updated_at` 只作辅助线索。** |
| IBIT 的 spot 滞后会把"支撑"错判成"压力"（同一条坑的方向性后果） | 实测：滞后的 48.515 让 48 看起来是「下方支撑」（−1.06%）；真实 47.20 下 48 是「头顶压力」（+1.69%），结论从"托底"直接翻转成"退潮"。**别只改现价数字、忘了同时改写墙位方向与传导结论。** |
| **链数值与上一份报告逐字相同 = 整条链未更新（最硬的判据，实测 2026-10-14 IBIT）** | 当日 IBIT 的 `updated_at = 2026-10-14T12:50Z`（是**当天**、不是前一交易日），但 `net_gex` +$84.49M、flip 44.92、call wall 47/OI 52,874、put wall 46/OI 24,552 **与上一份报告完全一字不差**，而 og spot 46.94 vs 真实收盘 46.24（差 +1.51%）。**判据升级：除了"spot 与 `optioncharts spot` 是否一致"，再看该标的的墙位/flip/max_pain/各档 OI 是否与上一份报告逐字相同——相同即为链未更新，整行标注"只作结构参考"，并据此把墙位方向（如 47 由"站上"退回"压力"）一并改写。** `updated_at` 是当天也可能整条链是旧的。 |
| **og spot 的"同日盘中滞后"是良性情形，别与"整日滞后"混为一谈**（实测 2026-10-16 IBIT / TLT） | 当日 IBIT 的 og spot **46.035** vs optioncharts/收盘 **46.14（−0.23%）**、TLT 的 og spot **79.92** vs **80.04（−0.15%）**；两者 `updated_at` 都是**当天**，且 og spot 与 **tradingview 同一交易日的较早一根 1h K 线**对得上（IBIT 17:30Z 收 46.025、TLT 16:30Z 收 79.92）——**只是 spot 的打印时点早于收盘，链本身是新的**（IBIT 的墙位 48/45、TLT 的墙位 OI 都与上一份完全不同，`scan` 的 `updated_at` 也都在当天）。**判据分两档：差 ≤ 0.3% 且该标的的墙位/flip/max_pain 与上一份不同 → 良性同日滞后，按收盘价重算"距现价"+正文注明即可；差 ≥ 0.5%、或链数值与上一份逐字相同 → 整条链未更新，整行标注"只作结构参考"。** 不要一看到 spot 差 0.1–0.2% 就把整个标的降级成"仅供参考"。**另一条常态（2026-10-23 实测）：IBIT 的 `updated_at` 长期落在 ~15:5xZ（比同批其余标的的 21:00Z 早约 5 小时），此时它仍可以是新链**（当日 IBIT spot 46.11 vs 收盘 46.06 差 **0.11%**、墙位由 48/45 换成 46.5/45.5、max pain 47→46.5）——**"早算"对 IBIT 是常态，不能当陈旧证据**。 |
| og 链整条陈旧时，用 **optioncharts 的 `gex` / `oi` 做新链旁证**（**IBIT 已连续多日复现**：10-12 / 10-14 / 10-19 / 10-20 / 10-21 / **10-26**（og spot 46.11 vs 真实 45.22 差 **1.97%**，`net_gex`/flip/48-48/max pain 47.5/墙位 OI 全部与上一份逐字相同，而 `optioncharts` 同日给 **46.5/44/max pain 47**）；10-21 那次 `updated_at` 还从 `10-20T12:50Z` 刷成 `10-21T12:51Z` 而数值逐字不变，正是"反向陷阱"的样本，og spot 46.035 vs 真实 47.84 差 **3.92%**） | 当日 IBIT 的 og 链与上一份**逐字相同**（`net_gex` +$526.14K、flip 45.94、48/45、OI 10,500/8,166、`max pain` 47），og spot 46.035 vs 真实 46.28（**−0.53%**，两条判据同时命中→整行降级"只作结构参考"）。此时 **`optioncharts gex/oi --exp <FRIDAY>:w` 是新算的**（`gex_as_of` = 当次 21:00:57Z），给出 call wall **46.5**、put wall 45.5、`max_pain` 46.5、OI 48 call 32,018 / 44 put 18,605。**做法：表 1A 保留 og 值并标"滞后"，正文按几何位置（锚真实 spot）重算方向，再用 optioncharts 的新链判断"近端钉子"到底是哪个价**——46.5 压在现价上方 0.48%、且折算成 BTC ≈82.1k 正好等于 BTC 4h 中枢 82,197，两条独立数据互证后才敢写"钉子"。**别因为 og 链旧就整段跳过该标的，也别把两个来源的墙位并列进同一张表。** **另注意：新链每天要重读，别沿用昨天的钉子——10-20 的 optioncharts 链把 call wall 由 46.5 抬到 48，而 46.5 变成最大正节点（脚下钉子）、现价 46.69 已站到它上面，方向读法与 10-19 正好相反。** |
| **"`spot` 一致"≠"链新鲜"——两天的收盘价几乎相同时，spot 比对完全失效**（实测 2026-11-02 IBIT） | 当日 og 的 `spot = 43.37`、`optioncharts` 实时 43.34（差 **0.07%**，按两档判据属"良性同日滞后"），但**整条链是 10-30 的旧值**：`net_gex` −$4,081,260、flip 45.13、call wall 47 / OI 5,525、put wall 44 / OI 5,829、max pain 46.5 **与上一份逐字相同**，且 `levels.total_oi = 125,815` 与上一份完全一致（optioncharts 新链 OI 已翻到 **259,681**）。原因：**10-30 收盘 43.36 与 11-02 收盘 43.34 只差 0.05%，陈旧链的 spot 恰好落在"正确值"上。** → **判据：`spot` 一致只能证明"价格没变"，不能证明"持仓重算过"；必须同时看 ① 墙位/flip/max_pain 是否与上一份逐字相同 ② 总 OI 是否与上一份逐字相同（最灵敏，因为一条链几乎不可能两天都不变）。任一相同就按"整条链陈旧"降级为"只作结构参考"，并改用 optioncharts 新链。** 本日 IBIT 新链为 **45 / 43 / max pain 44 / 净敞口 +$7.61M**（与 og 的 47/44/46.5 **方向也相反**——旧链读"脚下 44 是磁铁"，新链读"头顶 44–46.5 是正 gamma、脚下 43 以下全负"）。 |
| **`net_gex` 大幅翻面多半是"spot 移动后的 gamma 重定价"，不是新增持仓**（实测 2026-10-21） | 当日 SPY 的 `net_gex` 从上一份的 **−$1.87B 变成 +$47.67M**、QQQ 从 −$1.47B 变成 −$481.43M，看着像"结构翻转"。但对照 OI：**SPY 的 770 call 12,495 → 12,696、769 put 32,385 → 30,902（几乎没动）**，说明这 +$1.9B 的摆动主要是**现价上移 0.53% 后 gamma 在近价行权价上重新定价**（GEX ∝ spot²、gamma 在 ATM 最陡）。**判据：翻面幅度 > 0.5×|旧值| 时，先去上一份报告比对墙位 OI——OI 没动就写"现价回到了变号线上"，不要写"结构转多/转空"。** 同理 **DTE 0 的 `net_gex` 会在到期日剧烈变号**（QQQ 的 10-20 是 −$2.46B、10-21 是 +$1.51B），只能读成"今天现价附近是正 gamma 密集区"，**不能外推到周五**。 |
| **`put_wall` 可能印在现价上/附近的 ATM 行权价上**（**逐日复现，不是偶发**：2026-10-21 IBIT、**2026-10-23 GLD**） | ① 2026-10-21 IBIT 的 `put_wall = 48`、现价 **47.84**——48 就在现价上方 0.33%（**两源同时印成 48**，所以这不是某个数据源的 bug，是 ATM gamma 的数学性质）；② **2026-10-23 GLD 的 `put_wall = 369`、现价 369.00，距离 0.00%**（`walls`/`scan`/`optioncharts` 三处一致），而 369 的 put OI 只有 **2,455 张**，远小于 360 的 5,674 与 363 的 4,425 → 真实支撑在 **363 → 360**。原因不是"48 有巨量 put"，而是**put gamma 在 ATM 最大**：48 的 put_exposure −$4.33M 比 45.5（−$3.12M，OI 17,615 张）还大，因为前者贴价、后者离价 4.9%。**读法：`put_wall` 落在现价 ±1% 内时先怀疑是 ATM gamma 尖峰，改看"最大 put OI + 最大负 gamma 节点"定位真实支撑**（该日真实支撑是 45.5 → 44）。**同侧/贴价的墙位必须在表注显式说明"这是磁铁不是支撑"，否则下游会把 48 读成脚下的垫子。** ③ **2026-10-23（10-30 到期）同一天出现两例 + 一例新形态**：SPY `put_wall = 760`、现价 759.97（**+0.00%**，真实支撑在 750 的 55,649 张 / 745 的 81,237 张）；GLD `put_wall = 368`、现价 366.61（**+0.38%**，真实支撑 363 → 360 → 355）；**IBIT 的 call wall 与 put wall 同为 48（现价上方 4.44%）**——**"双面磁铁"**（call 29,551 + put 23,556 同档），几何上只能读成头顶的盖子/磁铁，**绝不能读成"上有压力、下有支撑"**。→ 五个标的里出现任何"墙位贴价"或"两墙同档"，都要在表注单列，且**同档时按方向只保留一种解释**。 |
| **IV 大涨但 ±1EM 几乎不动**（实测 2026-10-23 SPY / QQQ） | 当日 SPY IV 13.30% → **18.27%**（+5 个点）、±1EM 5.56 → **5.25**（只缩 5.6%）；QQQ IV 23.11% → **35.42%**（+12.3 个点）、±1EM 9.37 → **9.83**（只扩 4.9%）。原因是 `EM ∝ spot × IV × √DTE`：**DTE 从 2 减到 1 的 √2 折算刚好抵掉 IV 的涨幅**。→ **不要因为"EM 没变"就说"市场没在定价"**，也不要因为"IV 跳了 12 个点"就说"1EM 要炸开"；两者要一起看，**IV 的跳升恰恰说明"同样宽的 1EM 里塞了更多恐慌"**。 |
| **到期日整体滚动（DTE 1 → 7）时，前后两份的 `net_gex`/墙位/EM 不是同一条链**（实测 2026-10-23 → 10-24） | 上一份是 10-23 到期（DTE 1）、本份是 10-30 到期（DTE 7），SPY 的 `net_gex` −$2.69B → −$3.99B、call wall 770 → 780、put wall 769 → 760、max pain 770 → 765 **整条链重排**。**把这种差额写成"负 gamma 扩大 48%"或"结构恶化"是错的**——它主要是"下一周的持仓形状"与"本周仅剩 1 天的持仓形状"不同。**写法：§3.1 与 §7 都要显式声明"换链、不可逐字对比"；可比项只保留 ① spot 与当日涨跌 ② ±1EM/IV（并说明 DTE 变化的 √DTE 折算）③ "本周内部纵向%"（如 10-30 是否为该周唯一大负格）。只有同一到期日的连续两份才允许做"翻面/扩大"的因果读法。** |
| **同一到期日、DTE 缩短时，±1EM 只按 √(DTE新/DTE旧) 折算**（实测 2026-10-26，10-30 到期，DTE 7 → 4） | SPY 13.17 → **10.11**（理论 13.17 × 0.756 = 9.96）、QQQ 20.97 → **15.91**（理论 15.85），误差 <1.5%；IV 16.28 → 16.65 / 27.60 → 27.69。→ **判据：同一条链、只有 DTE 变化时，先算理论 EM 再比实际值——实际 ≈ 理论 = "IV 没动，全是 √DTE 折算"；偏差 >5% 才是 IV 真的变了。** 反之写"EM 缩了 23% 说明恐慌消退"就是错的（那是日历效应）。**反向样本（实测 2026-11-02，同一条 11-06 链、DTE 7 → 4、按实际剩余时间折算）**：SPY 1.82% → **1.87%**（理论 1.38%，**+35.9%**）、QQQ 3.11% → **3.21%**（理论 2.35%，**+36.5%**）、TLT 1.18% → **1.19%**（理论 0.89%，+33.4%）、GLD 2.51% → **2.24%**（理论 1.90%，+18.1%）、IBIT 4.53% → **3.61%**（理论 3.42%，**+5.4%**），同期 IV 全线上行（SPY 17.01 → **23.03**、QQQ 28.76 → **39.39**、GLD 25.38 → 28.34、IBIT 45.62 → 49.04、TLT 12.84 → 16.97）。→ **写法：EM 的美元宽度几乎没变（SPY 13.78 → 14.05）却只覆盖 4 天 = "同样宽的栏里塞了近两倍的每日波动"，这是"恐慌真的跳了"的硬证据；偏差 ≤8%（IBIT）仍写"日历折算、IV 没动"。判据统一为：折算偏差 ≤8% → 日历效应；8–20% → "略有定价"；>20% → 直接写 IV 跳升。** |
| **DTE 折算要用"实际剩余时间"，不能用取整后的 `dte`**（实测 2026-10-28，10-30 到期，DTE 4 → 2） | 若按取整天数折 √(2/4)=0.707，五只标的全部"实际远宽于理论"（偏差 18–23%），会误判成"IV 大涨"；改成按**快照时刻到 16:00 ET 的实际小时数**（上一份 3.96 天、本份 2.60 天 → √(2.60/3.96)=**0.810**），偏差立刻收敛到 **+2%～+8%**（SPY 8.44 vs 理论 8.19、QQQ 13.20 vs 12.89、GLD 5.60 vs 5.49、IBIT 1.00 vs 1.00、TLT 0.61 vs 0.57）。→ **判据：先算 `remaining_days = (exp 16:00 ET − snapshot_utc) / 86400`，再做 √ 折算；取整的 `dte` 只用于写报告标签，不用于折算。** 偏差 2–8% 属"IV 基本没动"，>10% 才写 IV 变化。 |
| **两个墙位可能"同时反向贴价"**（实测 2026-10-28 QQQ） | 当日 QQQ **call wall 720 在现价 721.44 下方 0.20%、put wall 725 在上方 0.49%**（`options-gex` 与 `optioncharts` 两源一致）。**这不是数据错误，是 ATM gamma 在两个相邻行权价上同时最大**（721 夹在 720/725 中间）。→ **几何上只能读成"720–725 的磁铁带"，绝不能读成"上有 725 压力、下有 720 支撑"**；真实顶/底要退到**最大正节点（729 / 730 / 740）与最大负节点（710 / 700 / 690）**。写法：表注单列一条，正文用"磁铁带"表述。 |
| **`call wall` 是"gamma 最大的 call 档"，不是"call OI 最多的档"——两个口径不要互相校验**（实测 2026-10-26 IBIT / SPY） | IBIT 当日 `optioncharts` 的 `call_wall = 46.5`（+$7.39M，绝对 gamma 14.84%），而 call OI 最多的是 **48（47,940 张）**、46.5 只有 22,701 张；SPY 的 `call wall = 780`（26,296 张）也不是最大 call OI 档（**800 有 49,272 张**）。→ **读"盖子/压力"用 gamma 口径（call wall + 最大正节点），读"持仓堆积/到期日引力"用 OI 口径（最大 OI 档）；两者结论可以不同（IBIT 的盖在 46.5、堆积在 48）。** 报告里两个数都要给，但不要用"call OI 最大在 48 所以 call wall 应该是 48"去质疑数据源。 |
| **量 PCR 单日跳升 ≠ 抛售**（实测 2026-10-23 SPY） | 当日 SPY 量 PCR **1.06 → 3.56**（put 成交量是 call 的 3.6 倍），而价格只跌 **0.52%**、OI PCR 2.48（几乎不动）。**这是"滚保护"（把本周到期的保护滚到下一周），不是 directional flow。** 判据：**量 PCR 跳升 > 2 倍而当日价格变动 < 1% → 读作"保险成交"**，正文写"保护堆在这里"而不是"有人在抛"；反过来**量 PCR 跳升 + 价格同向大跌 → 才是真抛压**。还要回看该行权价的 OI 是否"当天才堆上去"（本份 SPY 760 的 78,081 张 put 就是新堆的，这同时解释了它为什么是 ATM 磁铁）。 |
| **量 PCR 掉到"低于 OI PCR"是另一种信号：抛压不在期权侧**（实测 2026-10-30 SPY/QQQ 大跌日） | 当日 SPY **−1.77%**、QQQ **−3.47%**，量 PCR 分别 **1.72 / 1.16**，而 OI PCR 是 **2.35 / 1.89** → **成交里 put 占比低于存量持仓的 put 占比** = 期权侧没有"新买保护"，反而是"卖 put 收租 / 把保护往后滚"。**判据：量 PCR < OI PCR 且当日大跌 → 读作"跌是现货/期货打出来的（要现金，不要合约）"，不要写"恐慌性买保护"**；相反对应的确认信号是 **IV 跳升 + 1EM 扩张**（本日恰恰相反：下周五 1EM 反而比 √DTE 折算更窄）。**写法：正文明确"抛压在现货侧"，并把"卖 put 堆积"列为下周的追卖隐患。** |
| **1EM 上沿刚好卡在头顶那层墙 = "够得着但穿不过"的量化表述**（实测 2026-10-30 全部五只） | 当日 SPY 1EM 上沿 **769.50** ≈ max pain 769 / call wall 767；QQQ **711.97** 就在 713–715 磁铁带下缘；IBIT **45.33** 在 flip 45.13 之上；GLD **364.68** 在 put wall 365 之下；TLT **82.79** 刚过 82.5。→ **五只同现 = 市场把"下周能不能上去"统一定价成"一次性边界事件"**。**判据：先算 1EM 上沿与头顶墙位的百分比差，差 ≤0.5% 就可写"一个标准差刚好够碰到、不够穿过"，这是比"上方有压力"更硬的表述。** |
| **换链时"跨链量级对照"只能做一次算术、不能当结论**（实测 2026-10-30，10-30 链 DTE 2 → 11-06 链 DTE 7） | 本份把上一篇的 1EM 乘 √(7/2) 得到"若无 IV 变化应有 2.06%"，实际 **1.82%**（SPY）→ 只能说"**下周五的定价并不比本周更恐慌**"，**不能**据此写"波动率在压缩/恐慌消退"，因为两个到期日的持仓形状完全不同。**判据：换链时这条算术只用于判断"IV 有没有真的跳"，且必须在正文标注"跨链量级参考、非同一链对比"。** |
| **多日未跑（定时任务失败）时的口径**（实测 2026-10-29 Cloudflare 525、10-30 超时未落盘 → 10-31 的报告跨 3 个交易日） | 日报"与上一份的差异"会自然变成跨多日对比：**必须在 §0 与 §7 显式写明"上一份是哪一天、中间哪几天缺"**，并把逐项差额标成"3 个交易日合计"而不是"日变化"，否则读者会以为 SPY 一天跌 1.8%（实际是 10-28/10-29 走平、跌幅集中在 10-30 一天）。**另：失败日志要区分 `pi exit=1`（网络/模型中断）与 `exit=0 但无产物`（末轮只推理不落盘），本手册 §9.1 的重试逻辑对后者才有效。** |
| `options-gex scan` 的 `sign_flips: []` 有两种含义 | 一是"没有相邻反号"，二是"**所有到期日同号**"（实测 2026-10-14：SPY/QQQ 的 10-14～10-23 八个到期日 `net_gex` 全为负，故 `sign_flips` 为空）。**别把"空"默认读成"没有翻转信号"**，要回看 `scan` 各行的正负号：全负/全正本身就是强信号（如"全周负 gamma、周五之后也没有承接"）。 |
| `net_gex` 可能≈0 且 spot 贴在 `gamma_flip` 上 | 实测 2026-10-06 GLD：`net_gex` = −\$714K（几乎归零），spot 382.25 vs flip 382.26（差 \$0.01），`regime` 被划成 negative、`spot_vs_flip` 是 below。**此时不给方向性读数**，写成"处在正负 gamma 临界点上"，结论看两侧的墙位（下方负节点 / 上方正节点） |
| 用日线当"今天" | 19:11 UTC（周一）时，日线最后一根是**上一交易日**（2026-10-04），周一的日线还没收盘。读 `coverage.last` / `last_bar_age` / `stale`，必要时用 4h 序列看最新的动能变化 |
| 引用指数序列的成交量 | `volume_reliable: false` → `volume` 全是 `null`，任何量能推断都是错的 |
| 跨标的直接比 `net_exposure` | 必须先归一化（§4.5），否则系统性低估 TLT |
| 把 `em` 锥形当某个到期日的 EM | 用 `scan`/`stats` 的 `expected_move_abs/pct`（per-expiry）；锥形的日期读 `et_date` 不读 `iso` |
| 报告里混入非周五的结论 | 严格遵守 §0 硬规则 1；`sign_flips`、0DTE、月期权只能作为分析过程 |
| 给 TLT/GLD/IBIT 写了独立结论 | 严格遵守 §0 硬规则 2；它们的每个数字都要落到"对 SPY/QQQ 意味着什么" |
| 上游英文 insights 直接粘贴 | 禁止；翻译改写后再用（或不用） |
| 报告写成给专业读者的 | `摘要卡` 与 `供简报引用` 必须零术语、初中生可读（工具会做二次分析，但简报要面向普通读者） |
| `run-options-briefing.sh` 产物缺失（pi `exit=0` **不代表产物存在**） | 实测 2026-10-10：日志 `执行结束 exit=0` + `产物: 缺失（…未生成）`——pi 数据全部抓完，最后一轮**只输出 16.4k 字符思考、没调用写文件工具**即 `end_turn`（该 session 是 41 次运行里唯一的"末条消息无 text/toolCall"样本）。脚本已加固：**产物缺失自动重试一次**（第二次 prompt 追加「先建文件再补细节、复用 /tmp 已有抓取结果」的说明，`sleep 15`），两次都缺才 `exit 1`，并在产物存在时 grep `## 摘要卡` / `## 供简报引用（通俗结论）` 做锚点告警。**每次跑完（尤其 cron / 换机器）仍要自己确认 `briefing-playbook/options-briefing-$(date +%F).md` 存在** |

---

## 8. 质量检查清单（落盘前逐项过）

- [ ] 结论只针对**周五**那一个到期日，`selected_exp` 与报告标题一致
- [ ] 若快照发生在**到期日当天（DTE 0）**：已注明 DTE 0 与"覆盖美东 <前一交易日>"，剧本围绕钉子位 + max pain 写，且没有把 DTE 0 的窄 EM 当成常态
- [ ] TLT / GLD / IBIT 全部只写**传导含义**，没有独立方向性结论与交易建议
- [ ] 加密（USDT.D + BTCUSD）独立成节，多周期（周/日/4h）齐备
- [ ] 每个数字都带来源与快照时刻；同一张表没有混两个快照/两个来源；`scan` 里各标的 `updated_at` 逐只核对过，明显滞后的已在正文注明
- [ ] `摘要卡` 与 `供简报引用（通俗结论）` 存在、零术语、可直接抄进简报
- [ ] ±1EM 区间来自 per-expiry EM；剧本 A/B/C 都给了触发条件与目标位
- [ ] `optioncharts spot` 交叉核对过五个标的的现价；与 `options-gex` 不一致的（实测 IBIT 连续多日、TLT 也有）已用真实价重算距离、同步改写了墙位方向与传导结论、整行标注"只作结构参考"——**判据是 spot 比对，不是 `updated_at`**（`--no-cache` 会把 `updated_at` 刷成当下而数据照旧滞后）；**差 ≤ 0.3% 且墙位/flip 已换新 = 同日盘中滞后（良性，只需按收盘价重算距离）**
- [ ] IBIT ↔ BTC 换算用了当日**最近一根已收盘 1h/4h** 的比值，没有写死、也没拿日线 close 凑
- [ ] tradingview 数据标了 `coverage.last` / `as_of` / `stale`；宏观指数的日线滞后已在正文写明（`stale: false` 也可能滞后约 2 天，仍按 `coverage.last` 写"截至 MM-DD"）；指数序列没有用成交量
- [ ] 期限结构（`sign_flips`）来自一次**不带 `--exp`** 的 `scan`，且只用进分析过程、没进结论
- [ ] §0 口径段落与末节免责段落完整
- [ ] 若本份与上一份的**目标到期日不同（滚动到下一周）**：§3.1 / §7 已显式声明"换链、不可逐字对比"，没有把换链造成的差额写成"结构恶化 / 翻面"
- [ ] 若本份与上一份**同到期日、只是 DTE 缩短**：折算用的是**实际剩余时间**（`(exp 16:00 ET − snapshot)/86400`），不是取整的 `dte`；折算后偏差 ≤8% → 写"日历折算、IV 没动"，没有把日历效应写成"恐慌消退/升温"
- [ ] 墙位按**两种口径**分开读：`call wall` 是 gamma 最大档、不是 call OI 最大档（IBIT 2026-10-26：盖 46.5 / 堆积 48），两个数都给了、没有互相校验
- [ ] 量 PCR 相对上一份跳升 > 2 倍时，已核对当日涨跌幅与 OI PCR，写成"滚保护"而不是"抛售"
- [ ] 若**量 PCR 低于 OI PCR 且当日大跌**：已写成"抛压在现货侧、期权侧在卖 put 收租"，并把"空头 put 变成追卖燃料"列为风险；没有写成"恐慌性买保护"
- [ ] 已算过**头顶墙位与 1EM 上沿的差**：差 ≤0.5% 时用"一个标准差刚好碰到、不够穿过"表述（比"上方有压力"更硬）
- [ ] 若本份因**前几日定时任务失败**而跨多个交易日对比：§0 与 §7 已写明上一份日期与缺失日，差额标成"N 个交易日合计"
- [ ] §7「与上一份报告的差异」已写（或注明首份）；写法：先 `ls -t briefing-playbook/options-briefing-*.md | head -2` 找上一份，用关键词 grep 确认哪些结论变了
- [ ] 文件路径与命名：`briefing-playbook/options-briefing-YYYY-MM-DD.md`
- [ ] 无编造：所有价格/赔率/OI 都能在本次命令输出里找到出处
- [ ] 每个墙位都按**几何位置**核过一遍：call wall 在现价上方、put wall 在现价下方才是"顶/撑"；出现同侧（含 call/put 同档）时已在表注/正文显式说明
- [ ] 若出现**两面墙同时反向贴价**（call wall 在现价下方 + put wall 在上方，如 2026-10-28 QQQ 720/725），已读成"ATM 磁铁带"并在表注单列，没有写成"上有压力、下有支撑"
- [ ] `net_gex` 相对上一份大幅翻面（> 0.5×|旧值|）时，已比对墙位 OI：**OI 没动 = 现价移动后的 gamma 重定价**，正文已按此写，没有误读成"结构转多/转空"；DTE 0 的 `net_gex` 只当"今日现价附近的 gamma 环境"，没有外推到周五
- [ ] 若某标的的 `put_wall` 落在现价 ±1% 内，已确认它不是 ATM gamma 尖峰（否则改按"最大 put OI + 最大负 gamma 节点"定位真实支撑，并在表注写明）
- [ ] 判"链是否陈旧"时**没有只靠 `spot` 差值**：已同时核对 ① 墙位/flip/max_pain 是否与上一份逐字相同 ② **`levels.total_oi` 是否与上一份逐字相同**（最灵敏）；两天的收盘价相同时 spot 比对会完全失效（2026-11-02 IBIT：spot 只差 0.07% 但整条链是旧的）

---

## 9. 定时任务与部署

### 9.1 触发方式（用户明确要求）

`run-options-briefing.sh`（本目录）就是「定时 `@` 手册」的实现：用 `pi -p "@options-briefing-playbook.md"` 非交互执行本手册。

```bash
# 与简报同机（gcp:/root/pi-playbook）时，加在 root 的 crontab：
# TZ=Asia/Shanghai 05:00 执行 —— 美东 16:00 收盘 = CST 04:00/05:00，05:00 已有当日收盘快照
0 5 * * 2-6 /root/pi-playbook/run-options-briefing.sh >> /var/log/run-options-briefing-cron.log 2>&1
```

- **时间顺序**：期权日报必须**早于**每日简报（简报 06:00 读它）。**不要**把期权日报排在简报之后。
- **`2-6`（CST 周二至周六）= 美东周一至周五的收盘后**。想每天跑就写 `*`，但周末的报告只是上一交易日的重复。
- 幂等：当天 `options-briefing-YYYY-MM-DD.md` 已存在就跳过（脚本内 `-s` 判断）；重跑先删文件。
- 失败重试：`MAX_ATTEMPTS=2`，产物缺失（不存在或为空）时 `sleep 15` 重跑一次，第二次的 prompt 会要求「先落盘骨架再补内容、可复用 /tmp 里上一轮的抓取结果」；两次都缺则 `exit 1`，日志写「脚本 exit=1（最后一次 pi exit=0）」便于区分"pi 挂了"与"pi 正常结束但没落盘"。
- 防重入：`flock` 持 `briefing-playbook/options-briefing.lock`。

### 9.2 产物必须与简报 agent 同机同目录

简报 agent 在 **gcp:/root/pi-playbook** 上 06:00 执行，只读本机文件。所以：

- 在 gcp 上跑 → 产物直接落在 `/root/pi-playbook/briefing-playbook/`，无需同步。
- 在别的机器（如本机 debian13）上跑 → 生成后必须同步过去（否则简报读不到）：

```bash
scp -q briefing-playbook/options-briefing-$(date +%F).md \
    gcp:/root/pi-playbook/briefing-playbook/ && \
ssh gcp "md5sum /root/pi-playbook/briefing-playbook/options-briefing-$(date +%F).md" && \
md5sum briefing-playbook/options-briefing-$(date +%F).md        # 两端一致即成功
```

### 9.3 换机器要补的东西（`.agents/` 不入 git）

1. `git clone` 仓库 → 得到本手册、`run-options-briefing.sh`、`run-briefing.sh`。
2. 拷三个技能目录到 `.agents/skills/`：`options-gex`、`optioncharts`、`tradingview`（**实测 gcp 上缺 `optioncharts` 与 `tradingview`**）。
3. `cd .agents/skills/tradingview && npm install`。
4. 确认 node ≥ 22.13（cron 环境靠 `~/.config/ai-env.sh` + `run-options-briefing.sh` 里显式加 `/root/micromamba/envs/pi/bin` 进 PATH）。

---

## 10. 经验沉淀（全部执行完毕后必做）

- 本次执行有没有新的坑（命令行为、限流、字段含义、数据源改版）、用户新偏好、或实测验证过的结论？**有就立即写回本手册对应章节**（口径→§6，坑→§7，检查项→§8）。沉淀**只留结论与判据**，不要堆日志与逐日流水；同类情形合并成一条。
- 更新后提交（本手册与脚本都在 git 里；`briefing-playbook/` 被 `.gitignore` 忽略，日报不用提交）：

```bash
cd "$PLAYBOOK_DIR" && git add options-briefing-playbook.md run-options-briefing.sh && \
  git commit -m "docs: 更新期权日报 playbook（<一句本次经验>）"
```

- 无新经验则跳过，不强行改动。
