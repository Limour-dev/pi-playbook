# 全局 Skill 迁移到项目级手册

> 记录 2026-08 将 `miniflux` 与 `hn-briefing` 两个全局 skill 迁移到本项目（`pi-playbook`）`./.pi/skills/` 的完整过程、坑与验证方法。以后迁移其他 skill 时照此执行。

## 1. 背景与目标

pi 的 skill 发现分两级：

- **全局**：`~/.pi/agent/skills/`、`~/.agents/skills/`（所有目录的 agent 都能看到）
- **项目级**：`.pi/skills/`、`.agents/skills/`（cwd 及祖先目录，直到 git 仓库根；**仅本项目**的 agent 可见）

目标：把只服务于本项目（每日简报）的 skill 从全局移到项目级，**不再向当前目录以外的 agent 暴露**；同时更新依赖旧路径的脚本与文档。

## 2. 关键知识点（先读，避免踩坑）

### 2.1 发现规则（pi docs/skills.md「Locations」）

- `~/.pi/agent/skills/` 与 `.pi/skills/`：根目录下的 `.md` 直接作为 skill；含 `SKILL.md` 的目录递归发现。
- `~/.agents/skills/` 与项目 `.agents/skills/`：忽略根目录 `.md`，只递归发现含 `SKILL.md` 的目录。
- `--no-skills` 关闭**发现**，但显式 `--skill <path>` 仍然加载（可重复）。

### 2.2 项目信任门控（本项目实测踩到的坑）

项目级资源（含 `.pi/skills/`）**只有在本项目被信任后才会被发现**：

| 场景 | 行为 |
|---|---|
| 交互模式启动 | 询问是否信任本目录；`/trust` 保存决定（写入 `~/.pi/agent/trust.json`，**重启 pi 生效**） |
| 非交互 `-p` 模式 | 不弹询问；无已存决定时按 `defaultProjectTrust`（默认 `ask`/`never`）**忽略项目资源**；加 `--approve` 信任本次运行 |
| 显式 `--skill <绝对路径>` | **不受信任门控影响**（已实测：`--no-skills --skill ...` 无需 `--approve` 即可加载） |

结论：**脚本/cron 里加载项目 skill 一律用 `--no-skills --skill <绝对路径>`**，这是最稳的路径。

## 3. 迁移步骤（以 miniflux + hn-briefing 为例，均为实测命令）

### 3.1 盘点全局副本（先做，别急着删）

`~/.pi/agent/skills/` 与 `~/.agents/skills/` 可能同时存在同一 skill 的**不同版本**：

```bash
diff -rq ~/.pi/agent/skills/miniflux ~/.agents/skills/miniflux   # 两份内容不同
stat -c '%y %n' ~/.pi/agent/skills/miniflux/SKILL.md ~/.agents/skills/miniflux/SKILL.md
```

判断哪个是在用版本：对比 SKILL.md 的 `description` 是否与当前 pi 会话系统提示（available_skills）里加载的一致，且 mtime 更新。本项目结论：保留 `.pi/agent/skills/miniflux`（新、带 `references/`），删除 `.agents/skills/miniflux`（旧安装器副本）。`hn-briefing` 只有一份真实目录（`.agents/skills/`），`.pi/agent/skills/` 下只是符号链接。

### 3.2 移动进项目

```bash
mkdir -p /home/limour/pi-playbook/.pi/skills
mv ~/.pi/agent/skills/miniflux  /home/limour/pi-playbook/.pi/skills/miniflux
mv ~/.agents/skills/hn-briefing /home/limour/pi-playbook/.pi/skills/hn-briefing
# mv 保留权限（bin/ 下 775 的 wrapper 原样保留）
```

### 3.3 清理全局残留（破坏性，确认无误再执行）

```bash
rm -rf ~/.agents/skills/miniflux              # 旧版重复副本
rm ~/.pi/agent/skills/hn-briefing             # 符号链接（真实目录已移走，留着会悬空）
rm -f ~/.pi/agent/bin/miniflux                # 指向旧路径的 PATH 链接
# 复查：两个全局目录里都必须查无此 skill
ls ~/.pi/agent/skills/ ; ls ~/.agents/skills/
```

### 3.4 更新所有路径引用

```bash
grep -rn "\.pi/agent/skills\|\.agents/skills" 项目内脚本 / 文档 / .pi/skills/ 2>/dev/null | grep -v node_modules
```

本项目需要改的位置：

- **`run-briefing.sh`**：PATH 导出与 `--skill` 参数 → `$PLAYBOOK_DIR/.pi/skills/{miniflux,hn-briefing}`；头注释同步说明"项目级"。
- **`briefing-playbook.md`**：§1 环境准备（路径 + 新增"项目信任"说明）、§9.1 代码段的 PATH 导出。
- **技能内部文档**：`references/setup.md`、`README.md`、`bin/` wrapper 注释里过时的"安装器复制到 `~/.agents/skills/`、pi 软链进 `~/.pi/agent/skills/`"叙述，改为项目级位置描述。
- **crontab 无需改**：本来就以绝对路径调用 `run-briefing.sh`。

### 3.5 验证（每步必做）

```bash
bash -n run-briefing.sh                       # 脚本语法
# 冒烟测试 CLI（node 来自 micromamba envs/pi/bin，PATH 必须带上，否则 node: not found）
. "$HOME/.config/ai-env.sh"
export PATH="/home/limour/micromamba/envs/pi/bin:$HOME/pi-playbook/.pi/skills/miniflux/bin:$HOME/pi-playbook/.pi/skills/hn-briefing/bin:$PATH"
miniflux healthcheck                          # → Miniflux instance is healthy
miniflux me ; hn-briefing top 3               # → 正常 JSON
# 发现验证（项目目录内）
cd /home/limour/pi-playbook
npx @earendil-works/pi-coding-agent pi --provider axon --model deepseek-v4-flash --approve \
  -p "列出本会话全部可用 skill（逗号分隔，要完整）"
#   → 应含 hn-briefing, miniflux（无 --approve 时不会出现，属预期）
# cron 路径验证（显式 --skill 不依赖信任，可不带 --approve）
npx @earendil-works/pi-coding-agent pi --no-skills \
  --skill "$PWD/.pi/skills/miniflux" --skill "$PWD/.pi/skills/hn-briefing" \
  -p "列出本会话全部可用 skill"
#   → 应恰好列出 hn-briefing, miniflux
```

## 4. 注意事项与 FAQ

| 问题 | 说明 |
|---|---|
| `.pi/skills/` 进不了 git | `.gitignore` 末尾的 `*/` 忽略所有目录；与 `briefing-playbook/`（输出目录）同一策略。需要版本管理就 `git add -f .pi/skills/` 或加 `!.pi/` 例外 |
| 交互会话看不到项目 skill | 在项目目录内启动 pi 时确认信任，或 `/trust` 保存决定（写入 `~/.pi/agent/trust.json`，重启生效） |
| 全局副本删了会不会丢 | 不丢：先 diff 确认保留的是最新版；`mv` 而非 `cp`，避免两份内容漂移 |
| 迁移后其他目录的 agent 会怎样 | 完全看不到这两个 skill；`miniflux` 也不再在 `~/.pi/agent/bin` 全局 PATH 上 —— 这是预期行为 |
| 同名技能多个位置 | pi 报警告并保留第一个发现的；迁移前先确认不再全局残留 |

## 5. 本次迁移涉及文件清单

- 移入项目：`.pi/skills/miniflux/`（源：`~/.pi/agent/skills/miniflux`）、`.pi/skills/hn-briefing/`（源：`~/.agents/skills/hn-briefing`）
- 删除：`~/.agents/skills/miniflux/`、`~/.pi/agent/skills/hn-briefing`（软链）、`~/.pi/agent/bin/miniflux`（软链）
- 更新：`run-briefing.sh`、`briefing-playbook.md`、`.pi/skills/miniflux/{references/setup.md,README.md,bin/miniflux}`
- 参考：pi 文档 `docs/skills.md`（Locations / Skills 部分）