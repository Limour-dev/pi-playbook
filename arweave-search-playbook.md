# Arweave 检索与网关访问手册（含惨痛教训）

> 记录 2026-08-22 在 Arweave 上检索「EHT 首张黑洞照片 / JWST 图像 / 有趣文件」的完整过程与教训。
> 核心结论：**黑洞照片、JWST 图均未发现可验证的链上记录**（据信为讹传/AI 幻觉）；期间因 **ID 截断** 造成大量假 404，误判"网关挂了"，浪费大量时间。

## 1. 最大的教训：交易 ID 绝不截断

- 脚本打印 ID 时用了 `id[:20]` → 所有链接与测试用 ID 残缺（完整应为 **43 字符**）。
- 后果：`arweave.net/{残缺ID}` 返回 404 / `{"error":"invalid tx id"}`，被误判为"网关故障"，进而绕了一大圈找替代网关。
- **规则**：
  - 打印/传递 ID 永远完整输出；测试链接前先 `echo ${#id}` 确认 43 字符。
  - 出现批量 404 时，先怀疑自己的 ID 是否截断，再怀疑服务方。

## 2. arweave.net GraphQL 搜索要点

端点：`POST https://arweave.net/graphql`

### 2.1 索引覆盖范围（关键！）

| 匹配模式 | 覆盖范围 |
|---|---|
| `match: WILDCARD`（`values: ["*xxx*"]`） | **仅 2022-10 以后**（block ≳ 1,000,000） |
| `match: FUZZY_OR` / `FUZZY_AND` | 全部历史（含 2018） |
| 不加 match（EXACT） | 全部历史 |

- 验证方法：旧区块搜 `Title: *a*` → 0 条 ≠ 无数据，只是索引未覆盖；换 FUZZY/EXACT 立刻能命中 2018 年交易。
- 所以：**搜老内容用 EXACT/FUZZY；搜新内容（2022-10 后）用 WILDCARD**。

### 2.2 查询技巧

```graphql
{ transactions(
    block: {min: 190000, max: 200000},          # 按区块高度过滤（≈日期）
    tags: [                                      # 多标签 = AND 语义
      {name: "Title", values: ["*hole*"], match: WILDCARD},
      {name: "Content-Type", values: ["image/jpeg"]}   # 不写 match = EXACT
    ],
    first: 20, sort: HEIGHT_ASC) {
  edges { cursor node { id block { height } tags { name value } } } }  # 直接带 tags 返回，省二次查询
}
```

- 分页：把 `edges[-1].cursor` 放入 `after:`。
- `transactions(ids: [...])` 多 ID 查询曾间歇性无输出 → 失败时逐个单 ID 查，别盲等。
- 高度↔日期换算：`curl https://arweave.net/block/height/{h}` 取 timestamp。
  参考锚点：block 175,000 ≈ 2019-04-09 00:31；194,800 ≈ 2019-05-09；200,000 ≈ 2019-05-13；932,500 ≈ 2022-05；1,039,713 ≈ 2022-10；~670 blocks/天。
  ⚠️ 锚点必须实测 timestamp，勿凭推算（曾把 5 月误当 4 月害得整周白扫）。

## 3. 搜索"著名内容"的坑

- 「black hole / M87 / webb + 图片类型」命中大量**推特存档 NFT**（SmartWeave 合约）：
  `App-Name=SmartWeaveContract`、标题形如 `Username: xxx, Tweet: ...`、`Artifact-Series: Alex.`。
  内容只是文字/网页快照，不是图片 → 必须同时看 `Title + Content-Type + App-Name` 三件套过滤。
- 网传「XX 著名图片上传到了 Arweave」大概率查无实据：中英文 Brave 检索均无任何出处。
  **给用户结论时：如实说"未找到"，绝不编造链接。**

## 4. 决定性验证：字节扫描

标签搜不到 ≠ 不存在（可能是**无标签上传**，任何搜索引擎都搜不到）。唯一定论方法是按区块范围拉数据查魔数：

```bash
curl -s -r 0-15 "https://arweave.net/{txid}" | od -c   # JPEG=\xff\xd8\xff  PNG=\x89PNG
```

- 2019-04-08~13（EHT 发布会周，block 174,300–177,800，实际枚举 174,311–177,558 共 241 笔）**全量字节扫描 → 0 张图片**（206 文本/未知、35 空数据）。黑洞照片当时确实没传。
- ⚠️ 旧记录勘误：初版手册写「block 194,800–196,200 = 2019-04-09~12」是**错的**，实测该区间对应 **2019-05-09~11**（5 月），当年据此扫的 137 笔白扫了；4 月发布周的正确区间是 174,300–177,800（4/8 0:00 ~ 4/13 2:00）。凡按高度估日期，先 `curl arweave.net/block/height/{h}` 取 timestamp 核对，别信记忆。
- 注意：字节扫描同样受"必须完整 ID"约束。
## 5. 网关访问模式（本会话最大乌龙）

- `https://arweave.net/{txid}` 会 **302 重定向**到 `{hash}.arweave.net/{txid}` 子域（AR.IO 网关架构，子域由 txid 决定；浏览器自动跟随，用户视角"直接打开"）。
- 个别子域节点故障时返回 cdn77 错误页 → **局部节点问题，不是全局挂**。换时间/网络/节点即恢复。
- 备用取数端点（不走子域）：`https://arweave.net/tx/{txid}/data`（实测 200 直达原始字节）。
- 判断网关死活：用一条**确定存在且 ID 完整**的老交易（如 2018 年直传）测试，`curl -sL -o /dev/null -w "%{http_code}"`。
- 自查顺序：① ID 完整？② 单节点故障？③ 换 `/tx/{id}/data`；最后才怀疑全局故障。

## 6. 其他入口存活状况（2026-08 实测）

| 入口 | 状态 |
|---|---|
| arweave.net/graphql | ✅ 活着（搜索主通道） |
| arweave.net/tx/{id}/data | ✅ 活着（原始数据） |
| viewblock.io/arweave/tx/{id} | 浏览器（元数据/预览） |
| sonar.wtf | 搜索 |
| arweave.app | 已变成钱包应用，无搜索 |
| gateway.irys.xyz / permagate.io / ar-io.net | ❌ 404 或连不上（社区老网关大多已死） |
| arweave.live | ❌ 域名已过期 |
| grep.app / Bing / DDG / GitHub code search | 反爬或需认证（Sourcegraph stream API 可用但默认排除 fork/archived） |

## 7. 快速定位"有趣文件"的方法（本会话有效路径）

```bash
# 最新上传（HEIGHT_DESC）按类型翻
{ transactions(tags: [{name: "Content-Type", values: ["image/*"], match: WILDCARD}], first: 8, sort: HEIGHT_DESC) { edges { node { id } } } }

# 按关键词翻有趣标题（2022-10 后）
# "meme"、"funny"、"cat" 等，HEIGHT_DESC
```

- 命中：meme.png 梗图（2025）、古笑话书《Uncle Wiggily's funny auto》《Famous funny fellows》《Lincoln's yarns and stories》、"funny guy" 网页、Genesis Certificate 元数据等。
- 2026-08 最新区块大量上传无任何标签（匿名批量/测试数据），按类型翻比按标题翻有效。

## 8. 一句话清单

1. ID 保持 43 字符完整，先自查再怀疑服务。
2. 老区块用 EXACT/FUZZY，新区块才用 WILDCARD。
3. 查询时直接返回 tags，过滤 NFT 存档（App-Name=SmartWeaveContract / Alex. 系列）。
4. 标签搜不到 → 字节扫描定论；给结论不编造。
5. 网关 404 → 先查 ID → 再试 `/tx/{id}/data` → 别轻易判"挂了"。