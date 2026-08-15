# 每日简报生成手册（Daily Briefing Playbook）

> 本手册写给任何新的 agent。读完全文即可独立完成"订阅 + HN 融合简报"的生成与发布，满足用户的全部要求。本手册总结了历次迭代中用户明确提出的偏好与踩过的坑，**优先级高于一般直觉**。

---

## 0. 任务概述

用户每天会要求：

> "总结我订阅最近两天的消息，结合 HN 简报，生成一份简报 HTML 以便发布。"

交付物：**一个自包含、可直接发布的 HTML 文件**（内联 CSS，无外部依赖），命名如 `briefing-YYYY-MM-DD.html`，**放在 `briefing-playbook/` 文件夹下**（与 playbook 同名的文件夹）。
发布：每次生成后推送到服务器 b 的 `~/base/NGPM/data/briefing/`，远端 `index.html` 软链接始终指向最新一篇（详见 §8.1）。

**执行方式（用户明确要求）**：整个 playbook 从数据获取 → 写作 → 标记已读 → 发布 → 校验，是**一次操作**，中间不向用户请求确认；更新服务器 b 的内容无需确认，直接执行到底。只有出错（抓取失败/推送失败）才停下报告。**全部执行完毕后，若有新的经验（坑/偏好/验证过的命令行为），总结进本 playbook 并 git 提交（见 §8.2）。**

---

## 1. 环境准备

两个技能是唯一入口，都在 `/home/limour/.pi/agent/skills/` 下：

```bash
export PATH="/home/limour/.pi/agent/skills/miniflux/bin:$PATH"
export PATH="/home/limour/.pi/agent/skills/hn-briefing/bin:$PATH"

miniflux healthcheck          # 应输出 healthy
miniflux me                   # 当前用户
```

- 首次执行前**先读两个技能的 SKILL.md**（`miniflux/SKILL.md`、`hn-briefing/SKILL.md`），它们描述了全部命令。
- 所有命令输出 JSON 到 stdout。

---

## 2. 数据获取

### 2.1 订阅数据（miniflux）

```bash
# 最近两天，必须包含已读！(用户：简报每日生成，昨天的简报已把前两天的标为已读了)
miniflux entries --status read,unread --after <绝对日期> --order published_at --direction desc --limit 200 --compact
```

**关键坑（务必遵守）：**

1. **不要用相对时间 `--after 2d`**——实测返回 0 结果，有 bug。一律用绝对 ISO 日期：`--after 2026-08-07`（今天减 2 天）。
2. **必须带 `--status read,unread`**——否则默认只查 unread，会漏掉昨天已读的消息。
3. **不要用 `--fields`**——它会丢掉 feed 信息（feed 变成 `?`），无法按订阅源筛选。要精简用 `--compact`。
4. 数量大时分页：`--offset 200 --limit 200` 再查一次。**两天窗口可能高达 1200+ 条（8/12 实测 total 1252）**：`total` 是窗口内全部条目（含已读），必须 offset 分页到 1200（共 7 页）才能覆盖完整两天；只拉前 400 条只覆盖最近约 15 小时（8/12 实测前 400 条从 08-11T14:47 起），会漏掉 08-10 整天与 08-11 早段。标已读前务必拉全窗口再取 unread 并集。
5. 条目超过 200 时，先按 feed 统计分布（`collections.Counter`），心里有数再读正文。

### 2.2 HN 数据

```bash
hn-briefing top 100 > /tmp/hn_top.json
hn-briefing content "<url>"    # 抓取头条正文，返回 {title, text}
```

- **头条选择**：默认取 rank 1，但 rank 1 常是刚发布、分数很低（如 42 分）的帖子，无实质正文。此时**结合分数与评论数**选 rank 2 或更高的成熟帖子（如 282 分/106 评论），并在简报中说明。同日重跑时 HN 榜单几乎不变，同一篇有实质内容的帖子可继续当头条，但 points/comments 要用**最新拉取值**（实测 772→775）。
- 正文抓取可能失败（付费墙/反爬），失败时退回标题 + 常识，**不要编造内容**。

### 2.3 阅读正文的策略

- 快讯类 feed（金十数据、联合早报、风向旗、竹新社）：**看标题即可**，偶尔读正文。
- 深度类 feed（MIT 科技评论、cnBeta、AI 聚合、小众软件、中国数字时代）：**读正文**，提取 1–2 个硬事实（具体数字、确切结论）。
- **科研前沿 feed（Nature、MIT 科技评论）必须读正文**：生物/医学/物理/能源/太空等硬科学进展（新药、临床试验、天文发现、材料突破）单独成段写入简报，不能因"不够热"而省略。
- **地缘政治与人文素材**主要来自金十数据、联合早报、竹新社、风向旗、中国数字时代、十年之约博客聚合：战争/贸易/能源/社会事件看标题，深度评论与特稿（联合早报特稿、中国数字时代专栏、博客长文）读正文。
- **HN 不只看科技**：教育制度、职业意义、社会议题等高分人文帖（如丹麦口头答辩、知识工作无意义）同样纳入对应主题。
- **中国数字时代等批判性内容必须直面，不能回避**：司法/信访/立法/科研伦理/审查类题材按可交叉验证的事实写入简报（辉大基因试验致死、国企招聘"无信访记录证明"、法院局长索贿录音等）。唯一例外：单一来源、情绪化的极端指控（如个案细节）只略写或不展开。
  - 与"剔除存疑内容"的区别：剔除只针对标题党/离谱传闻（如"SpaceX 收购 Cursor"）；可验证的批判事实属于必写内容。
- 读正文命令：

```bash
miniflux entries --status unread --limit 100 --order published_at --direction desc --compact --plain-text   # 批量读未读正文
miniflux entry <id>    # 单篇全文（HTML），用正则去标签
```

- **剔除标题党/存疑内容**：AI 聚合频道里离谱的传闻（如"SpaceX 收购 Cursor"、"OpenAI 最大预训练模型 Doug 曝光"）不要写进简报。只写可验证的事实。注意：真实存在的人文故事（如"AV 转码"Noa 用 AI 自学编程）不算传闻，可写入人文主题。

### 2.4 一周回顾的数据

一周回顾需要 `--after <一周前日期>` 再拉一次（如 `--after 2026-08-02`），重点看深度 feed 在 8 天窗口内的主线（模型发布、安全事件、组织变动、硬件动向、科研进展（Nature/MIT 科技评论）），同时扫一遍地缘（战争/贸易）与国内批判（司法/信访/科研伦理）的周度主线。
**注意（实测）**：`--limit 200` 只返回窗口内**最新**的 200 条，要看到 8 天窗口里较早的条目必须继续 offset 分页，否则一周回顾会漏掉前半周的主线。窗口总量每天都在涨：8/9 实测 total 1021（offset 到 400 即可），8/12 实测 total 2098，offset 分页到 1800（共 10 页）才覆盖到 08-05，8/14 实测 total 3105，offset 分页到 3000（共 16 页）才覆盖到 08-07。分页到最早日期为止（页数≈total/200），再按 feed 分组扫主线。

---

## 3. 标记已读

读完并写进简报的未读条目，全部标记已读（用户明确要求）：

```bash
miniflux mark <id1> <id2> ... --status read
```

- **只标窗口内 unread 的 id**：从拉取数据里筛 `status == 'unread'` 的 id，直接 `miniflux mark <id...> --status read`（实测一条 argv 里放 124、乃至 628 条 id 都没问题，输出 `Marked N entries as read` 即成功）。
- **不要用 `mark --all`**：会误标窗口外的旧未读；仅在确认无窗口外未读时才可考虑。
- 数量极大（几百条）时先 `--dry-run` 预览，再决定分批或 `--yes`。
- **标记前重新拉一次最新数据**：写作期间快讯 feed（金十等）会不断进新条目，直接用第一次拉的 id 清单会漏标；footer 的“已读 N 条”以本次实际 `Marked N` 的 N 为准。

---

## 4. 写作规范（用户的核心要求，逐条遵守）

### 4.1 结构（自上而下）

```
1. 顶部一句话（lead，深色块）        —— 全文唯一的总述
2. ①~⑦ 主题部分（6–7 个）           —— 科技科研前沿 + 地缘政治 + 人文 + 批判监督，订阅与 HN 完全融合
3. 头条黑卡（Headline of the Day）    —— 放在最相关的主题段之后
4. ⑧ 一周回顾                        —— 最后，对最近一周的总结
5. footer                            —— 数据来源 + 数据窗口 + 已读标记说明
```

### 4.2 融合规则

- **订阅与 HN 彻底融合**：每个主题部分内部同时编织订阅消息和 HN 热度。例如"AI 军备竞赛"部分既写摩尔线程/月之暗面，也写 HN 的 DeepSeek V4/AMD 收购；"硬件焦虑"部分把 HN 头条《My server is a phone now》和订阅里的国产算力对照。
- **主题不限于科技**：地缘政治（战争/贸易/能源）与人文社会（教育/文化/数字生活/社会事件）必须成段。素材来自金十数据、联合早报、竹新社、风向旗、中国数字时代、博客聚合；HN 上的人文向高分帖（教育制度、职业意义、社会议题）纳入对应主题，不硬塞进科技段落。
- **科技科研前沿必须成段**：除 AI 商业/产品外，Nature、MIT 科技评论的硬科学进展（生物/医学/物理/能源/太空）单独一个主题；HN 上的科研向高分帖（论文、开源科学、实验发现）也进这段。
- **批判内容直面原则**：负面新闻与监督性报道（中国数字时代、风声 OPINION、知识分子等转载）按事实写入对应主题或单列"直面批判"主题；"剔除存疑内容"只针对标题党/离谱传闻，不适用于可验证的批判事实。
- **不要**出现"一、我的订阅""二、Hacker News 简报"这样的分节。

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

**常用主题划分（参考，按当天内容调整，科技科研前沿 + 地缘政治 + 人文 + 批判监督各至少一段）**：① AI 军备竞赛与人才洗牌 ② 写代码的人在想什么（程序员职业焦虑）③ 电脑越来越贵（硬件/内存焦虑）④ 科技科研前沿（Nature/MIT 科技评论：生物·医学·物理·能源·太空等硬科学，含 AI 研究本身）⑤ 地缘政治与世界大事（战争/能源/贸易/台海）⑥ 人文与社会（教育/文化/数字生活/社会事件）⑦ 直面批判（社会治理与监督：司法/信访/立法/科研伦理/审查）⑧ 一周回顾。

---

## 6. 质量检查清单（发布前逐项过）

- [ ] 顶部有一句话（lead），纯事实、无修辞
- [ ] 没有"我的订阅 / HN 简报"分节，已完全融合
- [ ] 地缘政治、人文/社会题材已纳入主题（不局限于科技），素材来自金十数据/联合早报/竹新社/中国数字时代/博客聚合，HN 人文高分帖也进了对应主题
- [ ] 科技科研前沿已成段：Nature/MIT 科技评论的硬科学进展（生物/医学/物理/能源/太空）写入简报，未因"不够热"而省略
- [ ] 中国数字时代等批判性内容已直面：可验证的批判事实（司法/信访/立法/科研伦理/审查）写入简报，未因敏感回避；仅单一来源的极端指控略写
- [ ] 每个主题部分 = plain 引入 + card 分析；引入无数字、初中生可读、落具体事实
- [ ] 全文无"不是…而是…"、无空泛比喻、无 AI 腔总结句
- [ ] 分析段逻辑连贯，每句有明确因果/并列关系
- [ ] 数字全部来自原文，标注了 HN 的 points/comments；无编造
- [ ] 头条选的是有实质内容的帖子（结合分数和评论数判断，不盲从 rank 1）
- [ ] 标题党/存疑传闻已剔除
- [ ] 一周回顾放在最后，基于一周窗口（`--after` 一周前日期）的数据
- [ ] 未读条目已全部 `mark --status read`，footer 注明
- [ ] HTML 标签配对（`<div>`、`<span>`、`<b>`、`<h3>` 等 open==close），自包含无外部资源
- [ ] footer 注明数据来源与窗口
- [ ] 已推送至 b:~/base/NGPM/data/briefing/，两端 MD5 一致
- [ ] 远端无多余软链接，`index.html` 软链接指向最新一篇
---

## 7. 常见问题

| 问题 | 处理 |
|---|---|
| `--after 2d` 返回 0 条 | 改用绝对日期 `--after YYYY-MM-DD` |
| `miniflux entries` 输出不是数组 | 返回的是 `{total, entries}` 对象，解析用 `d['entries']`；`total` 可能大于 200 |
| 窗口内条目 > 200（如 328 条） | `--offset 200 --limit 200` 再查一次，两次结果合并 |
| `--compact` 里 feed 不是字符串 | feed 是嵌套对象，用 `e['feed']['title']`（别当成字符串 `.get('title')` 会报错） |
| 漏掉已读消息 | 必须带 `--status read,unread` |
| HN 正文抓取失败 | leanrada / energy.gov / bloomberg / guardian / techcrunch 等常失败返回空或只有导航外壳，退回标题+评论数写，不编造；thewalrus.ca 等站点正文前有大量导航壳，用 `text.find(标题关键词)` 定位正文起点再截取（8/12 实测可用） |
| 不知道哪些是深度文章 | 按 feed 分组统计，快讯看标题、深度读正文 |
| rank 1 分数很低且无正文 | 选 rank 2+ 有实质内容的帖子当头条（如 8/9 头条 rank 54、772 分） |
| 跨天重跑，HN 榜单几乎不变 | 头条先排除昨天已写过/已当过头条的帖子（如 8/9 头条 DeepSeek V4 Flash、Noema、丹麦答辩等今天仍在榜），从昨天未覆盖的新帖里按分数+评论数+正文可抓取性选（8/10 选 Windows 天气 266 分/218 评论） |
| 同一 HN 帖标题被改写/分数继续涨 | HN 会自动改写帖标题（8/16 数学论文从 "AI Isn't Outthinking Mathematicians…" 变为 "AI has access to a vastly larger working memory…"，分数 317→320、评论 274→277）；跨天旧帖分数可大涨（Firefox/uBlock 帖 77→1635 分）。按 URL/内容识别同一帖，引用时一律用最新一次拉取的 points/comments |
| 头条正文抓取失败 | 用标题+评论数写，注明"正文未能抓取"，不编造；若订阅源有对应中文报道（8/15 智谱 GLM-5.3 的 z.ai 抓取失败、Qwen3.8 的 HuggingFace 模型卡正文被导航/模板淹没），改用 miniflux 订阅正文补硬数据（基准分、参数、价格），头条仍标注 HN points/comments |
| 用户说"太 AI 了" | 检查：是否用了"不是…而是…"、比喻、跳跃式总结句；改为平实因果陈述 |
| 远端 index.html 指向旧的/缺失 | 先 `find -type l -delete` 清掉所有软链接，再 `ln -sf 最新文件 index.html` |
| 不确定是否推送成功 | 对比两端 MD5 + `ls -la` 看软链接；文件大小与本地一致即成功 |
| 当天已有同日期 `briefing-YYYY-MM-DD.html` / cron 正在跑 | 先看 `briefing-playbook/` 成品时间戳、`run-YYYY-MM-DD.log`、`ps aux | grep run-briefing`；同名文件会被后写者覆盖，手动会话不持 flock、可与 cron 并行 → 推送后在其结束后再核一次远端 MD5，被覆盖就重推 |
| cron 日志只有 header 无产出 | `run-YYYY-MM-DD.log` 只有开始行、无后续输出、`ps` 无 run-briefing 进程、lock 文件为空 → cron 启动即失败（8/10 实测 06:00 启动后无任何产出），可放心手动执行；手动 scp 会覆盖 cron 可能留下的同名空文件，推送后再核一次 MD5 即可 |
| 一周窗口条目太多，`--limit 200` 看不到早期数据 | `--limit` 只回最新 N 条，必须按 total 分页（8/9 一周 total 1021 → offset 400 够；8/12 已涨到 2098 → offset 分页到 1800 共 10 页）才能看到窗口早期 |
| 两天窗口 `total` 上千（8/12 实测 1252），只拉前 400 条只有最近 15 小时 | 两天窗口也按 total 分页（offset 0–1200 共 7 页）拉全；标已读前务必拉全窗口再取 unread 并集，否则漏标 |
| 质量检查脚本打印的 `len(html)` | 是字符数不是 UTF-8 字节数（8/9 实测 12760 字符 ≈ 23354 字节），与 scp 的文件大小对比时别误读 |
| 分页拉取时个别页偶发 `Network error ... fetch failed`（8/13 实测 offset 200/1000/1200/1400 各失败一次） | 属瞬时网络错误，重试即可；批量拉页时先判空再重试（判空要判断 entries 非空，`json.load` 对空列表也会通过，否则空页不会触发重试），不必整窗重来；标已读前仍要重拉一次全窗取 unread 并集 |
| 分页期间快讯 feed 持续进新条目导致 offset 错位漏页（8/16 实测） | 先以 `--limit 1` 探 total 再分页时，paging 期间 total 从 3821 涨到约 4020，offset 200 起就漏掉了最新约 199 条；可把两天窗口数据（覆盖新尾部）与一周数据按 id 合并去重补齐，不必重拉整窗 |
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

### 9.1 拉取两天窗口数据 + 分页 + 按 feed 统计

```bash
export PATH="/home/limour/.pi/agent/skills/miniflux/bin:$PATH"
miniflux entries --status read,unread --after <今天减2天> --order published_at --direction desc --limit 200 --compact > /tmp/mf1.json
miniflux entries --status read,unread --after <今天减2天> --order published_at --direction desc --limit 200 --offset 200 --compact > /tmp/mf2.json
```

```python
import json
from collections import Counter
d1 = json.load(open('/tmp/mf1.json'))['entries']   # 返回 {total, entries}，不是数组！
d2 = json.load(open('/tmp/mf2.json'))['entries']
all_e = d1 + d2                                    # total > 200 时必须合并两页
json.dump(all_e, open('/tmp/mf_all.json', 'w'), ensure_ascii=False)
print('total:', len(all_e))
c = Counter(e['feed']['title'] for e in all_e)     # --compact 下 feed 是嵌套对象
for k, v in c.most_common(): print(f'{v:4d}  {k}')
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
IDS=$(tail -1 /tmp/mark_ids.txt)
miniflux mark $IDS --status read    # 输出 Marked N entries as read 即成功
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
assert not re.findall(r'https?://[^"]+', html), '外部资源！'
print('OK')
```

### 9.5 一次执行完整流程（发布已在 §8.1）

```bash
cd /home/limour/pi-playbook
# 1) 数据 → 2) 写作 → 3) 标已读(9.3) → 4) 质量检查(9.4) → 5) 发布(8.1) → 6) 经验沉淀(8.2)：有新经验则总结进 playbook 并 git 提交
# 全流程一次操作，发布环节不向用户确认（见 §0）
```
