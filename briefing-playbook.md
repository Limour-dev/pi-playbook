# 每日简报生成手册（Daily Briefing Playbook）

> 本手册写给任何新的 agent。读完全文即可独立完成"订阅 + HN 融合简报"的生成与发布，满足用户的全部要求。本手册总结了历次迭代中用户明确提出的偏好与踩过的坑，**优先级高于一般直觉**。
> 当用户贴出这份手册， 未指定其他任务时，即为执行该手册

---

## 0. 任务概述

用户每天会要求：

> "总结我订阅最近两天的消息，结合 HN 简报，生成一份简报 HTML 以便发布。"

交付物：**一个自包含、可直接发布的 HTML 文件**（内联 CSS，无外部依赖），命名如 `briefing-YYYY-MM-DD.html`，**放在 `briefing-playbook/` 文件夹下**（与 playbook 同名的文件夹）。
发布：每次生成后推送到服务器 b 的 `~/base/NGPM/data/briefing/`，远端 `index.html` 软链接始终指向最新一篇（详见 §8.1）。

**执行方式（用户明确要求）**：整个 playbook 从数据获取 → 写作 → 标记已读（§3/§9.3）→ 质量检查（§6/§9.4）→ 发布校验（§8.1）→ 经验沉淀（§8.2），是**一次操作**，中间不向用户请求确认，直接执行到底；只有出错（抓取失败/推送失败）才停下报告。全部执行完毕后，若有新的经验（坑/偏好/验证过的命令行为），总结进本 playbook 并 git 提交。

---

## 1. 环境准备

两个技能是唯一入口，都在项目级 `.pi/skills/` 目录下（`/home/limour/pi-playbook/.pi/skills/`，只在项目目录内运行时加载）：

```bash
export PATH="/home/limour/pi-playbook/.pi/skills/miniflux/bin:$PATH"
export PATH="/home/limour/pi-playbook/.pi/skills/hn-briefing/bin:$PATH"

miniflux healthcheck          # 应输出 healthy
miniflux me                   # 当前用户
```

- 首次执行前**先读两个技能的 SKILL.md**（`.pi/skills/miniflux/SKILL.md`、`.pi/skills/hn-briefing/SKILL.md`），它们描述了全部命令。所有命令输出 JSON 到 stdout。
- **项目信任**：项目技能只在项目被信任后才被发现（交互模式会询问，可用 `/trust` 保存；非交互 `-p` 默认不信任，需 `--approve`）。`run-briefing.sh` 用 `--no-skills --skill <绝对路径>` 显式加载，**不受信任门控影响**（已实测）。

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

### 2.2 HN 数据

```bash
hn-briefing top 100 > /tmp/hn_top.json
hn-briefing content "<url>"    # 抓取头条正文，返回 {title, text}
```

- **头条选择**：默认取 rank 1，但它常是刚发布、分数很低且无实质正文的帖子。按三个标准重选：**实质内容优先于纯分数**、正文可抓取、与订阅可交叉印证（通常落到 rank 2 或更高），并在简报中说明选择理由。完整判定规则（含「昨日执行终点之后的帖优先」「同事件多帖合并」「分数用最新拉取值」）见 §7「头条选择」行。
- 正文抓取失败时退回标题 + 订阅端同日报道，**不要编造内容**（处理顺序见 §7「`hn-briefing content` 抓不到正文」行）。
- **Mastodon 帖优先改抓其链出的独立站点**：HN 头条常是 mathstodon.xyz 这类实例的短帖（正文抓不到），但帖子里通常链有独立声明站点（实测 2026-09-12 头条 `A misalignment of AI in mathematics` → `mathandai.org` 抓取成功，拿到完整公开信正文）。直接抓站点 URL，stats 标明来源站点，比走「订阅端同日报道」更硬。

### 2.3 阅读正文的策略

- 快讯类 feed（金十数据、联合早报、风向旗、竹新社）：**看标题即可**，偶尔读正文。金十每天有大量模板噪音（`https://www.jin10.com/`、「金十图示」「期货热点追踪」「A股温度计」「XX价格追踪」「VIP事件提醒」「十分钟后公布」等），扫标题时直接跳过；真正有信息量的是带具体数字的快讯与「金十数据整理：每日科技要闻速递 / 中东局势跟踪 / 俄乌冲突跟踪」，这三类建议读正文（一条顶十条）。
- 深度类 feed（MIT 科技评论、cnBeta、AI 聚合、小众软件、中国数字时代）：**读正文**，提取 1–2 个硬事实（具体数字、确切结论）。
- **科研前沿 feed（Nature、MIT 科技评论）必须读正文**：生物/医学/物理/能源/太空等硬科学进展（新药、临床试验、天文发现、材料突破）单独成段写入简报，不能因"不够热"而省略。
- **地缘政治与人文素材**主要来自金十数据、联合早报、竹新社、风向旗、中国数字时代、十年之约博客聚合：战争/贸易/能源/社会事件看标题，深度评论与特稿（联合早报特稿、中国数字时代专栏、博客长文）读正文。
- **HN 不只看科技**：教育制度、职业意义、社会议题等高分人文帖（如丹麦口头答辩、知识工作无意义）同样纳入对应主题。
- **中国数字时代等批判性内容必须直面，不能回避**：司法/信访/立法/科研伦理/审查类题材按可交叉验证的事实写入简报，不因敏感而略过（写作原则详见 §4.2）。
  - 与「剔除存疑内容」的区别：剔除只针对标题党/离谱传闻；可验证的批判事实属于必写内容。
- 读正文命令：

```bash
miniflux entries --status unread --limit 100 --order published_at --direction desc --compact --plain-text   # 批量读未读正文
miniflux entry <id>    # 单篇全文（HTML），用正则去标签
```

- **剔除标题党/存疑内容**：AI 聚合频道里离谱的传闻不要写进简报；已被官方或多源交叉印证的消息以官方口径为准。真实存在的人文故事不算传闻，可写入人文主题。

### 2.4 一周回顾的数据

一周回顾需要 `--after <一周前日期>` 再拉一次，重点看深度 feed 在一周窗口内的主线（模型发布、安全事件、组织变动、硬件动向、科研进展（Nature/MIT 科技评论）），同时扫一遍地缘（战争/贸易）与国内批判（司法/信访/科研伦理）的周度主线。

**注意（实测）**：`--limit 200` 只返回窗口内**最新**的 200 条，必须 offset 分页到最早条目为止（页数 ≈ total/200），否则一周回顾会漏掉前半周主线。窗口总量持续增长（近期已到约 5000 条），分页很慢，更省的做法见 §7 末行；分页完成后按 feed 分组扫主线。

---

## 3. 标记已读

读完并写进简报的未读条目，全部标记已读（用户明确要求）：

```bash
miniflux mark <id1> <id2> ... --status read
```

- **只标窗口内 unread 的 id**：从拉取数据里筛 `status == 'unread'` 的 id，直接 `miniflux mark <id...> --status read`（实测一条 argv 可放数百个 id，输出 `Marked N entries as read` 即成功）。
- **不要用 `mark --all`**：会误标窗口外的旧未读；仅在确认无窗口外未读时才可考虑。
- 数量极大（上千条）时按 300 一批分批 mark，累加每批的 `Marked N`（代码见 §9.3）。
- **标记前重新拉一次最新数据**：写作期间快讯 feed（金十等）会不断进新条目，直接用第一次拉的 id 清单会漏标；footer 的“已读 N 条”以本次实际 `Marked N` 的 N 为准。
- **「新增素材」与「待标已读」是两个集合**：写作只看 `unread 且 published_at > 昨日终点` 的条目；但标已读时要标窗口内**全部** unread——窗口内、昨日终点之前仍可能有上一轮漏标的 unread（实测 2026-09-11 就有 27 条落在 9 月 9 日 22:37 至昨日终点之间），这些同样要标掉。

---

## 4. 写作规范（用户的核心要求，逐条遵守）

### 4.1 结构（自上而下）

```
1. 顶部一句话（lead，深色块）        —— 全文唯一的总述
2. ①~⑧ 主题部分（7–8 个）           —— 科技科研前沿 + 地缘政治 + 人文 + 批判监督 + 区块链/加密，订阅与 HN 完全融合
3. 头条黑卡（Headline of the Day）    —— 放在最相关的主题段之后
4. ⑨ 一周回顾                        —— 最后，对最近一周的总结
5. footer                            —— 数据来源 + 数据窗口 + 已读标记说明
```

### 4.2 融合规则

- **订阅与 HN 彻底融合**：每个主题部分内部同时编织订阅消息和 HN 热度（例如「AI 军备竞赛」段既写国产算力/模型发布，也写 HN 的对应高分帖），**不要**出现「一、我的订阅」「二、Hacker News 简报」这样的分节。
- **主题不限于科技**：地缘政治（战争/贸易/能源）与人文社会（教育/文化/数字生活/社会事件）必须成段。素材来自金十数据、联合早报、竹新社、风向旗、中国数字时代、博客聚合；HN 上的人文向高分帖（教育制度、职业意义、社会议题）纳入对应主题，不硬塞进科技段落。
- **科技科研前沿必须成段**：除 AI 商业/产品外，Nature、MIT 科技评论的硬科学进展（生物/医学/物理/能源/太空）单独一个主题；HN 上的科研向高分帖（论文、开源科学、实验发现）也进这段。
- **批判内容直面原则**：负面新闻与监督性报道（中国数字时代、风声 OPINION、知识分子等转载）按事实写入对应主题或单列「直面批判」主题。「剔除存疑内容」只针对标题党/离谱传闻，不适用于可验证的批判事实；唯一例外是单一来源、情绪化的极端指控，只略写或不展开。

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

### 4.4 语言风格（去 AI 腔）

- 用平实的因果陈述，不用修辞性总结。
- 反面例子（曾犯过，不要重复）：
  - "它把…表层问题，连到了…更深的结构性焦虑上"
  - "脱钩与能源安全是同一枚硬币的两面：一方在为失去市场买单"
  - "把镜头拉远一点看这一周"
  - "AI 的钱与人都在从'做大模型'转向…"
  - "模型不再只是更快地计算，而是开始适应个体与场景"
- 正确示范（平铺直叙、信息密度高）：
  - "德国上半年对华出口同比降逾 12%，中国从 2021 年的第二大出口市场跌至第九大。"
  - "德国在承受减少对华依赖的代价，中国在增加自己的能源储备，两件事在本周同时发生。"

### 4.5 数字使用

- 只在分析段出现，用 `<span class="num">` 高亮。
- 只标注原文给出的数字（points/comments、营收、百分比、金额），不编造。
- HN 帖子标注：`（772 分）` 或 `（928 分/694 评论）`。

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
    <div class="meta">YYYY 年 M 月 D 日 · 周X · 订阅聚合 + Hacker News 融合</div>
  </header>

  <div class="lead"><b>一句话：</b>……（全文唯一总述，纯事实，无修辞）</div>

  <h3>① 主题一</h3>
  <div class="plain">……（引入：无数字、初中生可读、落具体事实）</div>
  <div class="card">
    <p>……（分析：带数字、融合订阅+HN、逻辑连贯）</p>
    <p>……</p>
  </div>

  <!-- 更多主题部分 ②③④⑤ -->

  <div class="hn-headline">
    <div class="rank">Headline of the Day</div>
    <h4>头条标题</h4>
    <div class="stats">N points / M comments · 来源</div>
    <p>……（2–3 句实质摘要，不复述标题）</p>
  </div>

  <h3>⑧ 一周回顾</h3>
  <div class="plain">……</div>
  <div class="card">
    <p><b>小标题。</b>……</p>
    <p><b>小标题。</b>……</p>
    <p><b>小标题。</b>……</p>
  </div>

  <footer>
    数据来源：Miniflux 订阅聚合（…，覆盖 M 月 D–D 日，含已读与未读）· Hacker News 前 100 名。<br>
    由 pi 自动生成 · 今日未读 N 条已全部标记为已读。
  </footer>
</div>
</body>
</html>
```

**常用主题划分（参考，按当天内容调整，科技科研前沿 + 地缘政治 + 人文 + 批判监督各至少一段）**：① AI 军备竞赛与人才洗牌 ② 写代码的人在想什么（程序员职业焦虑）③ 电脑越来越贵（硬件/内存焦虑）④ 科技科研前沿（Nature/MIT 科技评论：生物·医学·物理·能源·太空等硬科学，含 AI 研究本身）⑤ 地缘政治与世界大事（战争/能源/贸易/台海）⑥ 人文与社会（教育/文化/数字生活/社会事件）⑦ 直面批判（社会治理与监督：司法/信访/立法/科研伦理/审查）⑧ 区块链与加密市场（吴说为主：行情/ETF 资金流/链上安全事件/监管与代币化；**用户明确要求必须有**）⑨ 一周回顾。

---

## 6. 质量检查清单（发布前逐项过）

- [ ] 顶部有一句话（lead），纯事实、无修辞
- [ ] 没有「我的订阅 / HN 简报」分节，订阅与 HN 已彻底融合
- [ ] 主题覆盖到位：地缘政治、人文/社会、科技科研前沿（Nature/MIT 科技评论硬科学进展）、直面批判（司法/信访/立法/科研伦理/审查）、区块链与加密各至少一段，均未被回避、未因「不够热」省略
- [ ] 每个主题部分 = plain 引入 + card 分析；引入无数字、初中生可读、落具体事实
- [ ] 全文无「不是…而是…」、无空泛比喻、无 AI 腔总结句；分析段逻辑连贯，每句有明确因果/并列关系
- [ ] 数字全部来自原文，标注了 HN 的 points/comments；无编造；标题党/存疑传闻已剔除
- [ ] 头条选的是有实质内容、正文可抓取、与订阅可交叉印证的新帖（不盲从 rank 1）
- [ ] 一周回顾放在最后，基于一周窗口（`--after` 一周前日期）的数据
- [ ] 未读条目已全部 `mark --status read`，footer 注明
- [ ] HTML 标签配对（`<div>`、`<span>`、`<b>`、`<h3>` 等 open==close），自包含无外部资源
- [ ] footer 注明数据来源与窗口
- [ ] 已推送至 `b:~/base/NGPM/data/briefing/`，两端 MD5 一致；远端无多余软链接，`index.html` 指向最新一篇

---

## 7. 常见问题

| 问题 | 处理 |
|---|---|
| `--after 2d` 返回 0 条 | 用绝对日期 `--after YYYY-MM-DD`（今天减 2 天） |
| `miniflux entries` 输出不是数组 | 返回的是 `{total, entries}`，取 `["entries"]`；`total` 可能远大于 200，需分页（§9.1） |
| `--compact` 里 feed 不是字符串 | 用 `e['feed']['title']`（当成字符串会报错） |
| 漏掉已读消息 | 必须带 `--status read,unread` |
| 分页偶发 `fetch failed` / offset 漂移 / 空页 | 瞬时错误重试该页，判空要判断 entries 非空（`json.load` 对空列表也通过）。分页期间快讯会进新条目导致 offset 错位漏页：凌晨窗口稳定、白天执行需在标已读前重拉一次取 unread 并集，或把两天窗与一周窗按 id 合并去重补齐。offset 超出 total 的空页是正常终点，不是网络错误 |
| 一次性打印数百条标题/正文被截断 | 输出在约 50KB 处静默截断、较旧条目被丢弃，按标题清单扫主线会漏料。按时间段分批打印，或 `title[:60]` 缩短每条 |
| `hn-briefing top` 偶发 fetch failed / 连到同一 IP 持续 Connect Timeout | 先重试一次；CLI 反复失败时放弃 CLI，改用自写 node 脚本直连 HN API（每请求最多 5 次重试、15s 超时、8 并发，输出结构与 CLI 一致） |
| `hn-briefing content` 抓不到正文 | 付费墙/反爬/改版站点常返回空或只有导航外壳（bloomberg、guardian、wiley/newscientist、yahoo、sciencealert、openai.com 官方博客与 newsroom 等）。处理顺序：① 导航壳页用 `text.find(标题关键词)` 定位正文起点再截取；② 改由订阅端同日中文报道（cnBeta / AI 聚合 / 财联社 / 风向旗 / MIT 科技评论）补硬数据，标题仍标 HN points/comments；③ 都拿不到就只写标题 + 讨论走向并注明「正文未能抓取」，不编造、不硬凑。视频帖同理：标注「正文为视频」、只写标题与讨论走向。apple.com 要分开判断：**产品页可抓**（规格/价格/发售日齐全），`newsroom` 新闻稿抓不到。**Mastodon/mathstodon 实例（如 HN 头条常客 mathstodon.xyz）返回 `text` 为空**（JS 渲染），直接走 ②/③：这类帖多为数学家的短评，用订阅端同日报道 + HN 标题即可成稿 |
| 头条选择（rank 1 分低无正文 / 跨天榜单几乎不变 / 榜单被旧帖霸榜） | 不盲从 rank 1：按 **points/comments + 正文可抓取性 + 与订阅交叉印证程度**选帖，优先「昨日简报执行终点之后新提交」的帖，通常是 rank 2 或更高。**判定昨日终点别按 cron 的 06:00 假定**：取窗口内 `status=='read'` 的最新 `published_at` 即为昨日执行终点，其后未读才是真正新增素材。已当过昨日头条/背景的旧帖一律排除，即使分数继续涨（如次日 1802→1944 分）；同一事件多帖霸榜时合并为一条头条叙事：取最高分帖为题、stats 注明同事件另一帖、正文并列双方口径 |
| HN 帖标题被改写 / 分数日内变动 | HN 会改写标题、跨天旧帖分数可大涨，同一天两次 `top 100` 也 rank 互换、points 微涨（实测头条 30 分钟内 701→704、EPA 帖 377→379），个别帖可能被 flag/重置分数暴跌。按标题 + URL 识别同一帖，一律引用**最后一次拉取**的 points/comments，rank 号仅作参考（写简报前再拉一次，且**发布前复核一次**：连正文里引用的次级帖分数也要同步改成最新值）。榜尾帖（rank 90+）可能掉出前 100，已掉榜帖用首次拉取值或省略分数；`top 100` 偶返回 99 条、个别 Ask/文本帖无 `url` 键属正常，解析用 `x.get('url','')` |
| 用户说「太 AI 了」 | 见 §4.4：检查是否用了「不是…而是…」、空泛比喻、跳跃式总结句，改为平实因果陈述 |
| 远端 `index.html` 指向旧的 / 不确定是否推送成功 | 见 §8.1：先 `find -type l -delete` 清掉所有软链接再 `ln -sf 最新文件 index.html`；以两端 MD5 一致为成功标准 |
| 当天已有同日期成品 / cron 正在并行跑 | 先看 `briefing-playbook/` 成品时间戳、`run-YYYY-MM-DD.log`、`ps aux \| grep run-briefing`；手动会话不持 flock、可与 cron 并行 → 推送后等其结束再核一次远端 MD5，被覆盖就重推。**`ps aux \| grep run-briefing` 抓不到正在跑的 cron**（脚本名不出现在进程表里）：改用 `lsof briefing-playbook/run-$(date +%F).log`，持有者是 `bash`→`npm exec`→`sh`→`pi` 即说明 cron 在跑；日志在 06:00 之后仍持续增长（`wc -c` 多次递增、内容是 `[pi-trace-id]` 块）同样是证据 |
| 自己就是 cron 拉起的进程 | 若父进程链是 `bash`→`npm exec …pi`→`pi`、且持有 `run-YYYY-MM-DD.log`，说明本次会话就是 `run-briefing.sh` 的 `-p @playbook` 运行（flock 已由自己持有）：直接执行到底，不要等 cron、不要重跑、也不要按「手动会话可与 cron 并行」去反复核 MD5 |
| cron 跑完无产出 | 四种表现都按「未执行」处理、放心手动跑：① 日志只有 header；② 日志是「你贴了手册但没说要做什么」的提问式输出（agent 把 `-p @file` 当成未给任务就退出 exit=0）；③ 连 `run-YYYY-MM-DD.log` 都没生成；④ **日志有 `[pi-trace-id]` 块、末尾是 `Connection error.`、结尾行 `执行结束 exit=1`**（provider 侧连接失败，发生在 06:00 刚起跑时，实测 2026-09-12）。**以「日志里有没有执行痕迹/成品文件」为准，别被非空日志骗了**，判定顺序先 `ls briefing-playbook/run-$(date +%F).log`。cron 失败会把新增窗口拉长成「昨日终点 → 现在」（可超 30 小时，unread 累积上千条），判定昨日终点仍用窗口内已读条目的 `max(published_at)`。手动 scp 会覆盖 cron 留下的同名空文件，推送后再核一次 MD5 |
| 同一订阅事件跨天状态反转 / 连续剧式进展 | 写作前先读昨日简报对应段落，反转写成「同一事件的最新一轮交锋」并并列双方说法；连续剧事件围绕新角度展开，不复述昨天内容 |
| 质量检查脚本打印的 `len(html)` | 是字符数不是 UTF-8 字节数（12760 字符 ≈ 23354 字节），与 scp 文件大小对比时别误读 |
| QA 报 "PLAIN HAS DIGITS" | 引入段出现阿拉伯数字即触发：中文量词前的数字（「2 纳米」「16 岁」「113 天」「8 万美元」）、模型/软件版本号（「Fable 5.1」「htmx 4.0」）、游戏名里的数字（「《半条命 2》」）、组织缩写（「G20」）都算。改写为「最新工艺」「未成年人」「新的大版本」「《半条命》系列第三章」「二十国集团」，数字与版本号全部留给 card；中文数字（「四成多」）可通过但仍尽量避免 |
| 一周回顾分页量过大（窗内约 5000 条） | 用 `--after <一周前> --before <今天窗口起点>` 只拉窗口前半段，再与今天的两天窗按 id 合并去重 |

---

## 8. 交付

- 文件放在 `briefing-playbook/` 文件夹（与 playbook 同名）下：`briefing-playbook/briefing-YYYY-MM-DD.html`
- 完成后向用户简述：① 结构（几个主题+回顾）② 头条选择理由 ③ 已读标记情况 ④ 剔除的存疑内容 ⑤ 可选的调整项（版式/长度/导出 Markdown）


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
- 有没有新的坑、用户新偏好、或实测验证过的命令行为？**有就立即总结进本 playbook**（改对应章节或 §7 常见问题表），不要留到下次。
- 更新后 git 提交（playbook 文件已被跟踪，`briefing-playbook/` 目录被 `.gitignore` 忽略，无需提交简报文件）：

```bash
cd /home/limour/pi-playbook && git add briefing-playbook.md && git commit -m "docs: 更新简报 playbook（<一句本次经验>）"
```

- 无新经验则跳过，不强行改动。

---

## 9. 常用代码段（直接抄，均为本次实操验证）

### 9.1 拉取两天窗口数据（探 total 全量分页）+ 按 feed 统计

```bash
export PATH="/home/limour/pi-playbook/.pi/skills/miniflux/bin:$PATH"
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

### 9.4 发布前质量检查（标签配对 / 禁句 / 外链）

```python
import re
html = open('briefing-YYYY-MM-DD.html').read()
for tag in ['div', 'span', 'b', 'h3', 'h4', 'p', 'footer']:
    o = len(re.findall(r'<%s[\s>]' % tag, html)); c = len(re.findall(r'</%s>' % tag, html))
    assert o == c, f'{tag} {o}/{c} MISMATCH'
for bad in ['不是…而是…', '硬币的两面', '把镜头拉远']:
    assert bad not in html, bad
assert not re.findall(r'不是[^，。；\n]{0,14}[，,][^。；\n]{0,14}而是', html), '不是X，而是Y 句式！'
assert not re.findall(r'https?://[^"]+', html), '外部资源！'
# 引入段(plain)不得出现数字（允许一周回顾的日期窗口如"8 月 18 日至 25 日"）
for m in re.finditer(r'<div class="plain">(.*?)</div>', html, re.S):
    txt = re.sub(r'\d+ 月 \d+ 日至 \d+ 日', '', m.group(1))
    assert not re.findall(r'\d', txt), f'plain 含数字: {m.group(1)[:50]}'
print('OK')
```
