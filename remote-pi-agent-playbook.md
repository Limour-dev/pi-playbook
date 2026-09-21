# 远程 pi Agent 部署手册（micromamba + 扩展分发 + 免密互信）

> 记录 2026-09-21 在 gcp（Debian 12，cdn-g.limour.top:2022）上从零搭建 pi coding agent 运行时、
> 安装三个扩展、打通 gcp → b 免密、并把 `models.json` 安全搬运过去的完整过程与踩坑。

## 1. 最终形态与目标

| 项 | 值 |
|---|---|
| 远端主机 | `gcp` = `cdn-g.limour.top:2022`（root，Debian 12，kernel 6.1） |
| 包管理器 | `/root/.local/bin/micromamba` v2.9.0，root prefix `/root/micromamba` |
| 运行环境 | conda env `pi` = `/root/micromamba/envs/pi`（node 26.8.2 / npm 11.19.1） |
| pi 本体 | **不全局安装**，走 `npx -y @earendil-works/pi-coding-agent`（每次拿最新版） |
| 扩展 | `git:github.com/Limour-dev/pi-trace-id`、`npm:pi-hashline-edit-pro`、`npm:pi-rtk-optimizer` |
| rtk | `conda-forge::rtk-cli` 0.49.0 → `/root/micromamba/envs/pi/bin/rtk` |
| 模型 | provider `axon` / model `deepseek-flash`，凭据来自 `models.json` 的 `apiKey` |
| 互信 | gcp → b 免密，**独立密钥**，本机私钥零流转 |

设计取舍（用户明确要求）：

- **不全局安装 pi**：npx 每次解析最新版，代价是首次 430MB 缓存、启动略慢。
- **不暴露任何已存在密钥**：不给 gcp 拷本机 `b_ed25519`，改在 gcp 本地生成专属密钥。

## 2. micromamba 安装

```bash
ssh gcp 'bash <(curl -L https://raw.githubusercontent.com/mamba-org/micromamba-releases/main/install.sh)'
```

要点：

- **非交互时不会提问**。install.sh 用 `if [ -t 0 ]` 判断，SSH 非 tty 下自动取默认值：
  `BIN_FOLDER=~/.local/bin`、`INIT_YES=yes`、`CONDA_FORGE_YES=yes`、`PREFIX_LOCATION=~/micromamba`。
  所以直接跑即可，无需 `yes |` 或喂 stdin。
- 它会自动把初始化块写进 `~/.bashrc`（`# >>> mamba initialize >>>` … `# <<< mamba initialize <<<`）。
- 验证：`source ~/.bashrc; micromamba --version`。
- **后续所有 micromamba 命令在非交互 SSH 里都要先 eval hook**：
  ```bash
  ssh gcp 'eval "$(micromamba shell hook -s bash)"; micromamba <cmd>'
  ```

## 3. `~/.condarc`

```bash
ssh gcp 'cat > ~/.condarc <<"EOF"
channels:
  - conda-forge
channel_priority: strict
auto_activate_base: false
EOF'
```

坑：

- **覆盖前必须备份**。原有 `~/.condarc` 里是 `channels: [conda-forge, nodefaults]`，直接覆盖把 `nodefaults` 丢了。
  `nodefaults` 的作用是防止隐式回落到 `defaults` 频道。正确做法：`cp -a ~/.condarc ~/.condarc.bak.$(date +%Y%m%d%H%M%S)` 再写。
- 写入用 `<<"EOF"`（带引号）避免 `$` 被远端 shell 展开。
- 检查生效：`micromamba config list`、`micromamba config sources`。
- `auto_activate_base: false` 对 micromamba 的 `shell hook` **不生效**（base 仍是默认激活项），别指望它。

## 4. 统一环境变量文件 `~/.config/ai-env.sh`

```bash
ssh gcp 'mkdir -p ~/.config && cat > ~/.config/ai-env.sh <<"EOF"
export PATH="$HOME/.local/bin:$PATH"
export MAMBA_EXE="$HOME/.local/bin/micromamba"
export MAMBA_ROOT_PREFIX="$HOME/micromamba"
export PI_FFF_MODE="override"
EOF'
```

在 `~/.bashrc` **首行**插入加载语句：

```bash
[ -f "$HOME/.config/ai-env.sh" ] && . "$HOME/.config/ai-env.sh"
```

插入方法（无需 sed，避免转义地狱）：

```bash
printf '%s\n' '[ -f "$HOME/.config/ai-env.sh" ] && . "$HOME/.config/ai-env.sh"' \
  | cat - ~/.bashrc > /tmp/.bashrc.new && mv /tmp/.bashrc.new ~/.bashrc
```

要点：

- **heredoc 必须加引号**。`<<"EOF"` 让 `$HOME` 保持字面量；不加引号会被展开成写死 `/root`，可移植性变差。
- 加载语句放首行，保证后续 `.bashrc` 里其他逻辑（含 mamba initialize 块）能用到这些变量。
- 验证：`ssh gcp 'bash -ic "echo \$PATH; echo \$PI_FFF_MODE"'`。
- 已知无害副作用：PATH 里 `.local/bin` 出现两次（ai-env.sh 一次 + mamba hook 一次）。

## 5. SSH 免密：零密钥流转

需求是"让 gcp 上也能 `ssh b`，跟本机效果一致，但**不暴露任何密钥**"。

❌ 错误做法：把本机 `~/.ssh/b_ed25519` scp 到 gcp。那等于把长期私钥复制到第二台机器，扩大暴露面，也无法单独撤销。

✅ 正确做法：**为 gcp 单独签发密钥对**，只把**公钥**下发到 b。

```bash
# 1) 在 gcp 本地生成专属密钥（私钥永不出 gcp）
ssh gcp 'mkdir -p ~/.ssh && chmod 700 ~/.ssh
  ssh-keygen -t ed25519 -N "" -C "gcp-cdn-g" -f ~/.ssh/b_ed25519
  chmod 600 ~/.ssh/b_ed25519 && chmod 644 ~/.ssh/b_ed25519.pub'

# 2) 只取公钥，追加到 b 的 authorized_keys（先备份）
PUB=$(ssh gcp 'cat ~/.ssh/b_ed25519.pub')
ssh b "cp -a ~/.ssh/authorized_keys ~/.ssh/authorized_keys.bak.\$(date +%Y%m%d%H%M%S)
  printf '%s\n' '$PUB' >> ~/.ssh/authorized_keys
  chmod 600 ~/.ssh/authorized_keys"

# 3) gcp 写 config（与本机 Host b 段等价）
ssh gcp 'cat > ~/.ssh/config <<"EOF"
Host b
    HostName b.limour.top
    Port 20022
    User root
    IdentityFile ~/.ssh/b_ed25519
    IdentitiesOnly yes
    AddKeysToAgent yes
EOF
chmod 600 ~/.ssh/config'

# 4) 预置 known_hosts，免首次交互确认
ssh gcp 'ssh-keyscan -p 20022 -t ed25519 b.limour.top 2>/dev/null >> ~/.ssh/known_hosts
  sort -u ~/.ssh/known_hosts -o ~/.ssh/known_hosts; chmod 600 ~/.ssh/known_hosts'
```

验证（注意 `~/.ssh/authorized_keys` 属主属组必须对，否则 sshd 静默拒绝）：

```bash
ssh gcp 'ssh -o BatchMode=yes b "hostname; whoami"'   # → ECS-9678761429 / root
ssh b 'hostname; whoami'                              # 本机对照
```

安全边界：

- 撤销 gcp 的访问 = 删 b 上 `authorized_keys` 里 `gcp-cdn-g` 那行，**不影响本机**。
- **不要用 `ssh -A gcp`**。Agent Forwarding 会让 gcp 上的 root 借用你本机 agent 里**所有**密钥。
  嵌套 `ssh gcp 'ssh b ...'` 完全不需要 `-A`。
- 确认隔离：`ssh gcp 'for f in ~/.ssh/*_ed25519; do ssh-keygen -lf "$f"; done'` 只应看到 gcp 自己的密钥指纹。

## 6. 环境与包安装

```bash
# 装 node（创建环境），非交互必须 -y
ssh gcp 'eval "$(micromamba shell hook -s bash)"
  micromamba create -y -n pi conda-forge::nodejs'

# 装 rtk-cli 到已有环境
ssh gcp 'eval "$(micromamba shell hook -s bash)"
  micromamba install -y -n pi conda-forge::rtk-cli'
```

要点：

- **非交互下 `-y` 是必须的**，否则会卡在确认提示直到超时。
- 验证要用 `micromamba run -n <env>` 而不是 `micromamba activate`（activate 在非交互脚本里不可靠）：
  ```bash
  micromamba run -n pi bash -c "node -v; npm -v; which rtk; rtk --version"
  ```
- `rtk-cli` 包提供的命令是 `rtk`。注意别和同名但不同项目的 `rtk`（Rust Toolkit）搞混 ——
  用 `rtk --help` 确认子命令（这里是 `ls/tree/read/git/grep/rg/...` 的 token 优化代理）。

## 7. pi 扩展安装

```bash
ssh gcp 'eval "$(micromamba shell hook -s bash)"
  micromamba run -n pi npx -y @earendil-works/pi-coding-agent install <source>'
```

坑与要点：

- **`pi install` 一次只接受一个 source**。`install npm:a npm:b` 会报
  `Unexpected argument npm:b.  Usage: pi install <source> [-l] [--approve|--no-approve]`。必须分两次调用。
- source 形式：`npm:<pkg>` / `git:github.com/<owner>/<repo>`。
- 结果落在 `~/.pi/agent/settings.json` 的 `packages` 数组：
  ```json
  { "packages": [
      "git:github.com/Limour-dev/pi-trace-id",
      "npm:pi-hashline-edit-pro",
      "npm:pi-rtk-optimizer" ] }
  ```
- 安装位置：git 类 → `~/.pi/agent/git/github.com/<owner>/<repo>/`；npm 类 → `~/.pi/agent/npm/node_modules/<pkg>/`。
- 更新（保持最新版）：
  ```bash
  pi update                                       # pi 本体 + 所有包
  pi update git:github.com/<owner>/<repo>         # 只更新某个
  ```
- 可加 shell 函数省掉前缀：
  ```bash
  pi() { eval "$(micromamba shell hook -s bash)"; micromamba run -n pi npx -y @earendil-works/pi-coding-agent "$@"; }
  ```

### npm `install-scripts` 警告可忽略

```
npm warn install-scripts 1 package has install scripts not yet covered by allowScripts:
npm warn install-scripts   pi-rtk-optimizer@0.9.0 (postinstall: node -e "...")
```

该 postinstall 自带路径守卫：`if(!normalized.includes('/.pi/agent/extensions/'))process.exit(0)`。
我们装在 `~/.pi/agent/npm/node_modules/pi-rtk-optimizer`（不含 `/extensions/`），脚本**本来就会直接退出**，
被 npm 拦下不产生任何差异。不需要 `npm install-scripts approve`。

## 8. 凭据机制：不一定要单独配 auth.json

pi 的凭据解析顺序（`docs/providers.md` → Resolution Order）：

1. CLI `--api-key`
2. `auth.json` 条目（API key 或 OAuth token）
3. 环境变量（`GEMINI_API_KEY`、`OPENAI_API_KEY` …）
4. **`models.json` 里自定义 provider 的 `apiKey`**

`models.json` 是**路由表**（`baseUrl` / `api` / 模型清单），但它的 `apiKey` 字段本身就支持三种形式：

```json
{ "apiKey": "sk-..." }                // 字面量
{ "apiKey": "$MY_ENV_VAR" }           // 环境变量插值（也支持 ${A}_${B}）
{ "apiKey": "!op read 'op://...'" }   // 请求时执行命令取 stdout
```

所以 **`auth.json` 是空的（2 字节）不代表没凭据** —— 凭据可能在 `models.json` 里。

判断凭据是否就绪的正确方式（不必读文件内容）：

```bash
pi auth check --provider <name> --json
# → {"status":"ready","provider":"axon","authType":"api_key"}
pi --list-models          # 列出模型 ID，能列出来即凭据就绪
```

两个额外坑：

- 本地无鉴权服务（如 Ollama）也**必须给个 dummy key**，否则模型会加载但**不出现在 `/model` 列表**：
  > pi still treats models as requiring auth before they appear in `/model`, so keyless local servers
  > should keep a dummy value
- 若 `apiKey` 是 `$FOO` 形式，远端机器上必须有 `FOO` 环境变量；若是 `!命令` 形式，该命令会在**远端**执行，
  要保证命令在远端可用（macOS 的 `security find-generic-password` 在 Linux 上就不存在）。

## 9. 搬运 `models.json`：不偷看内容

需求：把本机 `~/.pi/agent/models.json` 传到 gcp，**不读内容**。

```bash
# 只做存在性/元数据检查，不 cat
ls -l ~/.pi/agent/models.json

# 远端若有同名文件先备份
ssh gcp 'if [ -f ~/.pi/agent/models.json ]; then
    cp -a ~/.pi/agent/models.json ~/.pi/agent/models.json.bak.$(date +%Y%m%d%H%M%S); fi'

# 传 + 权限
scp -q ~/.pi/agent/models.json gcp:~/.pi/agent/models.json
ssh gcp 'chmod 600 ~/.pi/agent/models.json'

# 完整性校验：只比 size 和 sha256，不打印内容
sha256sum ~/.pi/agent/models.json
ssh gcp 'sha256sum ~/.pi/agent/models.json'
```

要点：

- 私密配置搬运的验证靠 **`sha256sum` + `stat -c%s`**，不要靠 `cat`/`diff`。
- 传完 `chmod 600`（本机原文件就是 600）。
- 上游 `models-store.json`（内置目录缓存）和 `auth.json` 是另外的文件，注意区分。

## 10. 测试方法论：怎么证明扩展真的生效

`pi -p "hi"` 只报 `No API key found` 时**看不出扩展有没有加载成功**。要主动构造可观测量。

### 10.1 加载失败会报错 → 用"故意写坏的扩展"做对照

```bash
cat > /tmp/broken-ext.ts <<'EOF'
export default function () { throw new Error("BOOM deliberate"); }
EOF
pi --no-extensions -e /tmp/broken-ext.ts -p --no-session "hi"
# → Error: Failed to load extension "/tmp/broken-ext.ts": Failed to load extension: BOOM deliberate
#   Hint: Start without extensions using "pi -ne".
```

有了这个对照，才能反证"真实扩展启动时无报错 = 加载成功"。
（`--verbose` **不会**输出扩展加载日志，别指望它。）

### 10.2 用输出格式差异证明 rtk 重写真实发生

`rtk rewrite <cmd>` 的退出码语义：`0|3` = 有改写（stdout 是新命令），`1` = 无需改写，`2` = 被拒绝。

```bash
rtk rewrite "git status"   # → "rtk git status", exit=3
rtk rewrite "ls -la"       # → "rtk ls -la",    exit=3
```

但"rewrite 可用"≠"optimizer 真的调用了它"。可靠做法是找**输出格式差异**：

```bash
ls /usr/lib          # 原生：多列无斜杠  X11  apparmor  apt  ...
# 让 agent 执行 ls /usr/lib 并原样贴回第一行
# agent 收到的是：X11/ apparmor/ apt/ ...   ← rtk ls 的格式
```

格式变了 = 命令确实被重写。这是**行为级证据**，比读配置强。

### 10.3 三个扩展各自的验证抓手

| 扩展 | 抓手 | 通过的判据 |
|---|---|---|
| pi-trace-id | stdout 出现 `[pi-trace-id] { 'AH-Thread-Id':…, 'AH-Trace-Id':… }` | Thread-Id 会话内恒定、Trace-Id 每轮唯一 |
| pi-hashline-edit-pro | `read` 返回 4 字符锚点；`replace` + `undo_last_change` | 问锚点能答对；undo 后 `cat -A` 确认磁盘内容回滚 |
| pi-rtk-optimizer | 命令输出格式（见 10.2）；`/rtk stats` 会话指标 | agent 收到的是 rtk 格式输出 |

### 10.4 全流程冒烟测试（在临时目录做，跑完清理）

```bash
ssh gcp 'rm -rf /tmp/pi-agent-test && mkdir -p /tmp/pi-agent-test && cd /tmp/pi-agent-test
  echo "hello world" > seed.txt
  eval "$(micromamba shell hook -s bash)"
  # 1) 基础对话
  micromamba run -n pi npx -y @earendil-works/pi-coding-agent \
    -p --no-session --model axon/deepseek-flash "Reply with exactly: PONG"
  # 2) 工具调用：read/bash + write
  micromamba run -n pi npx -y @earendil-works/pi-coding-agent \
    -p --no-session --model axon/deepseek-flash \
    "Run bash: cat seed.txt . Then write result.txt containing exactly DONE."
  # 3) session 持久化
  ... -p --model ... "Remember this number: 424242."
  ... -p --continue --model ... "What number did I ask you to remember?"
  # 4) 无错误启动
  ... -p --no-session --model ... "say OK" 2>&1 | grep -iE "error|fail|warning" || echo "(clean)"
'
# 清理
ssh gcp 'rm -rf /tmp/pi-agent-test ~/.pi/agent/sessions/--tmp-pi-agent-test--'
```

实测结果（全部通过）：PONG ✅、`cat seed.txt` 读到 `hello world` 且写出 `result.txt=DONE` ✅、
`--continue` 后仍记得 `424242` ✅、启动零 error/warning ✅。

## 11. 已知遗留问题

- **`pi-trace-id` 污染 stdout**：`-p` 模式下 trace 头打到 stdout，会弄脏非交互输出的 JSON/纯文本。
  做自动化管道调用前需确认该扩展有无静音开关（环境变量/配置项），或临时 `pi -ne` 关闭扩展。
- **PATH 重复**：`.local/bin` 出现两次，无功能影响。想干净可把 `.bashrc` 里 mamba initialize 块改成只调 hook、不重复导 PATH。
- **`auto_activate_base: false` 未生效**：micromamba 的 base 仍是默认激活环境。如需新 shell 不激活 base，得在 hook 之后手动 `micromamba deactivate`。
- **npx 缓存膨胀**：首次 430MB（`~/.npm/_npx/99fca8174466655b`）。定期 `npm cache clean --force` 或接受它。

## 12. 命令速查

```bash
# 远端跑 pi（每次最新版）
ssh gcp 'eval "$(micromamba shell hook -s bash)"
  micromamba run -n pi npx -y @earendil-works/pi-coding-agent <args>'

# 更新 pi 与所有扩展
pi update

# 列出扩展 / 模型
pi list
pi --list-models

# 检查凭据
pi auth check --provider <name> --json

# 诊断扩展加载问题
pi -ne                       # 完全禁用扩展启动
pi -e /tmp/broken.ts -ne     # 只加载指定扩展
```
