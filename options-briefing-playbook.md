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
| `optioncharts` | `.agents/skills/optioncharts/bin/optioncharts` | 链统计（`volume_total`、`volume_pcr`、`oi_total`、`iv_pct`、per-expiry `expected_move_abs/pct`）、逐行权价 `oi` / `volume`、`--gex` 的 ±1EM 归一化字段 |
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

# ② 墙位与墙位 OI、到现价的距离（单标的、token 小；报告里的墙位数字一律以这次为准）
for t in SPY QQQ GLD IBIT TLT; do
  "$SK/options-gex/bin/options-gex" walls $t --exp "$FRIDAY" --no-insights --format compact
done

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

**请求预算**：`options-gex` REST 限流 **30 次/IP**（60 秒本地缓存会吸收同一 `(ticker, exp)` 的重复调用），上面 ① ② 合计约 10 次；`optioncharts` 实测无限流、TTFB ~2s，③④⑤ 约 9 次。一天一轮完全够用，**不要跑 `raw`**。

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

- **IBIT ↔ BTC 换算**：用**当日** `IBIT spot` 与 `BTCUSD close` 的比值换算（实测 ≈1765–1790，不要写死），把 IBIT 的墙位翻译成 BTC 价位写进报告。
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
- **`bullish_score` 由上游定义、组成未公开**，只作横向参考，不可解释成具体指标。
- **`gamma_flip` 与 `zero_gamma_estimate`** 是两个口径：后者是行权价网格上的线性插值交叉校验，相差几美元属正常，**报告以 `gamma_flip` 为准**。
- **`oi_source` 若不是 `"oi"`**，说明统计口径可能变成成交量，必须在报告里说明。
- **tradingview 只返回已收盘 K 线**：日线在其收盘后还要等满 24 小时才出现（保守），报告里写 `coverage.last` 与 `as_of`；`USDT.D` / `US10Y` / `GOLD` / `DXY` / `VIX` 是**指数/百分比序列**，`volume_reliable: false`、`volume` 为 `null`，**不要用它们的量能做推断**。
- 免责：本报告是公开持仓结构的读数，不构成投资建议。

---

## 7. 常见坑（实测，逐条遵守）

| 坑 | 处理 |
|---|---|
| 两个数据源的同一指标对不上 | 实测同一到期日 QQQ 的 put wall 在 `options-gex` 是 749、在 `optioncharts` 是 730；GLD 的 EM 是 1.64% vs 1.52%/1.65%。**同一指标只取单一来源**：墙位/flip/max pain 取 `options-gex`，成交量/OI/PCR/±1EM 归一化取 `optioncharts`，各自标注来源与快照时刻，**不并列进同一张表** |
| 快照漂移很快 | 实测约 2 分钟内 SPY `net_gex` 从 +\$4.84B → +\$5.71B → +\$6.35B，spot 775.67 → 776.31。**写报告前重跑一次 `scan` 与 `walls`**，全文只引用这一次的数（或分块标注各自时刻），不要把两个小时前的数字和现在的混用 |
| `options-gex` 的 `--dte` 对 `levels`/`walls`/`gex` 无效 | `--dte` 只作用于 `expiries` 与 `scan`；其它命令传了只在 stderr 提示忽略。要钉到期日就用 `--exp` |
| `optioncharts` 的到期日必须带 `:w`/`:m` | 裸日期会被解析并可能静默换到期日（默认 exit 5）；第三个周五是 `:m`。用 `expiries` 查后缀 |
| 忘了 `tradingview` 要装依赖 | 首跑 `npm install`，否则所有命令报 `dependencies missing` |
| 用日线当"今天" | 19:11 UTC（周一）时，日线最后一根是**上一交易日**（2026-10-04），周一的日线还没收盘。读 `coverage.last` / `last_bar_age` / `stale`，必要时用 4h 序列看最新的动能变化 |
| 引用指数序列的成交量 | `volume_reliable: false` → `volume` 全是 `null`，任何量能推断都是错的 |
| 跨标的直接比 `net_exposure` | 必须先归一化（§4.5），否则系统性低估 TLT |
| 把 `em` 锥形当某个到期日的 EM | 用 `scan`/`stats` 的 `expected_move_abs/pct`（per-expiry）；锥形的日期读 `et_date` 不读 `iso` |
| 报告里混入非周五的结论 | 严格遵守 §0 硬规则 1；`sign_flips`、0DTE、月期权只能作为分析过程 |
| 给 TLT/GLD/IBIT 写了独立结论 | 严格遵守 §0 硬规则 2；它们的每个数字都要落到"对 SPY/QQQ 意味着什么" |
| 上游英文 insights 直接粘贴 | 禁止；翻译改写后再用（或不用） |
| 报告写成给专业读者的 | `摘要卡` 与 `供简报引用` 必须零术语、初中生可读（工具会做二次分析，但简报要面向普通读者） |

---

## 8. 质量检查清单（落盘前逐项过）

- [ ] 结论只针对**周五**那一个到期日，`selected_exp` 与报告标题一致
- [ ] TLT / GLD / IBIT 全部只写**传导含义**，没有独立方向性结论与交易建议
- [ ] 加密（USDT.D + BTCUSD）独立成节，多周期（周/日/4h）齐备
- [ ] 每个数字都带来源与快照时刻；同一张表没有混两个快照/两个来源
- [ ] `摘要卡` 与 `供简报引用（通俗结论）` 存在、零术语、可直接抄进简报
- [ ] ±1EM 区间来自 per-expiry EM；剧本 A/B/C 都给了触发条件与目标位
- [ ] IBIT ↔ BTC 换算用了当日比值，没有写死
- [ ] tradingview 数据标了 `coverage.last` / `as_of`；指数序列没有用成交量
- [ ] §0 口径段落与末节免责段落完整
- [ ] §7「与上一份报告的差异」已写（或注明首份）；写法：先 `ls -t briefing-playbook/options-briefing-*.md | head -2` 找上一份，用关键词 grep 确认哪些结论变了
- [ ] 文件路径与命名：`briefing-playbook/options-briefing-YYYY-MM-DD.md`
- [ ] 无编造：所有价格/赔率/OI 都能在本次命令输出里找到出处

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
