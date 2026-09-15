# pi 扩展打包与分发手册（安装体积 / peer 依赖 / 发布）

> 记录 2026-09-15 给 `pi-trace-id` 瘦身 880 MB 的过程：一个 `peerDependenciesMeta` 标记
> 让安装占用从 440 MB/份降到 0，以及 pi 两条安装路径参数不一致这个上游 bug。
> 同日又在 `pi-jupyter`（有真实运行时依赖 `@jupyterlab/services`）上复核了同一套手法，
> 补进 `.npmrc` 两条反例（§5.2）与"消费者裸装"这第四条验证路径（§5.3 / §6.1）。

## 1. 结论速查（TL;DR）

- **pi 扩展里的 `peerDependencies` 一定要配 `peerDependenciesMeta: { "optional": true }`**，
  否则 `pi install git:...` 会给每个包额外装一份 ~440 MB 的 `@earendil-works/pi-coding-agent`。
- 宿主类型包若只为 `npm run typecheck` / IDE 补全存在，放 `devDependencies`，不要放 `dependencies`。
- 只做 `import type` 的扩展**运行时零依赖**，安装应该接近 0 字节。若装出几百 MB，一定是配置错了。
- 仓库根的 `.npmrc`（`legacy-peer-deps` + `omit=optional`）**不是免费兜底**：前者会让 npm 停止为
  自己依赖树里的 peer 解析、可能把 lockfile 里的包删掉，后者会打断 rollup / esbuild 的本地构建。
  先看 §5.2，多数情况下**不加**，只留 `peerDependenciesMeta`。
- 判定修复是否有效，要跑**消费者裸装**路径（`npm i <tgz>`，不带任何 flag，见 §6.1）：git 安装路径
  常被 `devDependencies` 巧合兜底而显得本来就正常。
- 发布用 **npm Trusted Publishing（OIDC）**，不需要任何 `NPM_TOKEN` secret。

## 2. 背景

`pi-trace-id` 是一个单文件 pi 扩展，唯一 import 是：

```ts
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
```

`import type` 转译时被完全擦除，运行时由 pi 通过 loader alias 注入宿主 API。所以它运行时**零依赖**。

但实测：

```
项目里 npm install                -> node_modules 463 MB
~/.pi/agent/git/.../pi-trace-id/  -> node_modules 440 MB（git 安装自动跑的）
~/.pi/agent/npm/                  -> 94 MB / 4 个包（npm 安装，正常）
```

且都是**物理独立拷贝**，不是硬链接：

```bash
stat -c '%i %h %s %n' A/package.json B/package.json
# inode 不同、link count 都是 1 → 两份实体
```

440 MB 的构成：pi-coding-agent 自己的 runtime 依赖里，esbuild 把 **26 个平台的预编译二进制**
全声明成 `optionalDependencies`（`@esbuild/win32-x64`、`@esbuild/darwin-arm64`、`@esbuild/linux-mips64el` …），
约 284 MB 是纯死重量；`@aws-sdk` / `@anthropic-ai` / `@google` 等再占 ~50 MB。

## 3. 关键知识点：pi 的三种包来源与落地目录

| `pi install` 来源 | 落地目录 | 安装命令 |
| --- | --- | --- |
| `npm:pkg@1.2.3` | `~/.pi/agent/npm/`（项目级 `.pi/npm/`） | `npm install <spec> --prefix <root> --legacy-peer-deps` |
| `git:host/user/repo@ref` | `~/.pi/agent/git/<host>/<path>/` | clone 后 `npm install --omit=dev` |
| 本地路径 | 原地引用，不复制 | 不安装 |

`pi update --extensions` / `--all` 管理这些包；npm 的带版本 spec 会被 pin 住、跳过更新；
git 的 ref 也是 pin 的，换版本要 `pi install git:...@new-ref` 重装。

## 4. 🔴 根因：两条安装路径参数不一致（上游 bug）

`pi-coding-agent@0.85.1` 的 `dist/core/package-manager.js`：

```js
// npm 包路径（1459 起）—— 显式禁用 peer 解析，注释写得很清楚：
//   "Disable peer dependency resolution for managed installs ... so package managers
//    do not install or solve host-provided @earendil-works/pi-* peers."
getNpmInstallArgs(specs, installRoot) {
    return ["install", ...specs, "--prefix", installRoot, "--legacy-peer-deps"];
}

// git 包路径（1448 起）—— 只 omit dev，漏了禁 peer
getGitDependencyInstallArgs() {
    const configuredCommand = this.settingsManager.getNpmCommand();
    if (configuredCommand && configuredCommand.length > 0) return ["install"];
    return ["install", "--omit=dev"];   // ← 缺 --legacy-peer-deps
}
```

对比 `~/.pi/agent/npm/` 里那些纯 npm 安装的扩展（`pi-mcp-adapter`、`pi-hashline-edit-pro` …），
它们都用了 `peerDependenciesMeta` 把 `@earendil-works/pi-*` 标 optional，所以没踩这个坑 —— 佐证了
"标记 optional 才是分发侧的正确答案"。

## 5. 解法

### 5.1 package.json（核心，一行事）

```json
{
  "peerDependencies": {
    "@earendil-works/pi-coding-agent": "*"
  },
  "peerDependenciesMeta": {
    "@earendil-works/pi-coding-agent": { "optional": true }
  },
  "devDependencies": {
    "@earendil-works/pi-coding-agent": "^0.85.1",
    "typescript": "^5.0.0"
  }
}
```

`optional: true` 后，npm/bun/pnpm **任何路径都不会自动装它**，pi 传不传 `--legacy-peer-deps` 都无所谓。
`devDependencies` 里留一份，本地类型检查与补全照常，消费者不会安装。

### 5.2 .npmrc（**别照抄，先看下面两条反例**）

```ini
legacy-peer-deps=true
omit=optional
```

git 安装路径是 `cd <clone> && npm install`，会读到仓库根的 `.npmrc`，所以这层**能**生效。
但两行都不是免费的，当天在 `pi-jupyter` 上复核时都踩到了：

- `legacy-peer-deps=true` 会让 npm 停止为**本仓库自己的真实依赖**解析 peer，lockfile 随之改变。
  `pi-jupyter` 依赖 `@jupyterlab/services`，树里有 `@jupyterlab/settingregistry`（它和它依赖的 `@rjsf/utils`
  都声明了 peer `react`）；加上这行后 `npm install --package-lock-only` 直接把 `node_modules/react` 从 lock 里删掉了。
  加之前务必 `git diff package-lock.json` 看清代价。
- `omit=optional` 会**打断本地开发工具链**：`rollup` / `esbuild` 的平台二进制
  （`@rollup/rollup-linux-x64-gnu`、`@esbuild/*`）正是声明的 `optionalDependencies`，省掉之后
  `vitest run` 直接 `MODULE_NOT_FOUND: rollup/dist/native.js`，`tsup` 同样起不来。
  而它对**分发体积**的贡献常常是 0（宿主副本问题由 `peerDependenciesMeta` 独立解决），所以多数情况下正确做法是**不写**。

结论：**`peerDependenciesMeta.optional` 是唯一必需项**；`.npmrc` 只在同时满足
①`git diff package-lock.json` 无明显副作用 ②`npm run typecheck && npm test && npm run build` 全绿
时才留下。`pi-jupyter` 最终的选择是：不加 `.npmrc`，只留 `peerDependenciesMeta`。

### 5.3 实测对照

复刻 pi 的两条安装参数（临时目录，避免污染）：

```
                       改前       改后
pi install npm:...     434 MB  →  56 KB     ✔
pi install git:...     434 MB  →  0
本地 npm install       463 MB  →  178 MB    （仅开发用类型）
```

**验证过：光靠 `peerDependenciesMeta.optional` 就够了** —— 把 `.npmrc` 排除掉再跑一遍 git 路径，
同样是 0。`.npmrc` 只是额外的保险。

同一天在 `pi-jupyter`（真实运行时依赖 `@jupyterlab/services`，不是零依赖扩展）上复核：

```
                                 改前              改后
npm path, pi 参数(--legacy-peer-deps)   29 MB      →   29 MB
npm path, 裸 `npm i <tgz>`              564 MB     →   29 MB   （改前含 pi-coding-agent 434 MB）
git path (clone + npm i --omit=dev)     29 MB *    →   29 MB
```

* 改前 git 路径看着干净是**假象**，真因是 package.json 里同一批 peer 也列在 `devDependencies`，
  `npm install --omit=dev` 先把 peer 解析到那个 dev 条目、再随 dev 一起 omit 掉，属于巧合而非配置正确。
  所以**别用 git 路径的干净结果判定修复有效**，必须跑 §6 的第四条路径。

改后 29 MB 全部是 `@jupyterlab/services` 的真实依赖树（lodash / yjs / ajv / `@lumino/*`…；
git 路径下还会多一个 peer `react`，npm 路径因 `--legacy-peer-deps` 不带它 —— 两种树都能正常
`import("@jupyterlab/services")`，实测均通过）：
`node_modules/@earendil-works` 不存在（0 个包），tarball 20 文件 / 57 KB。

## 6. 验证方法（复用套路）

不要靠猜，**复刻 pi 的安装参数在临时目录跑一遍**：

```bash
set -e; T=$(mktemp -d)

# 模拟 pi install git:...（见 getGitDependencyInstallArgs）
mkdir -p "$T/clone"
tar --exclude=node_modules --exclude=.git -cf - . | (cd "$T/clone" && tar xf -)
(cd "$T/clone" && npm install --omit=dev --no-audit --no-fund --loglevel=error)
du -sh "$T/clone/node_modules" 2>/dev/null        # 期望：不存在或极小
ls "$T/clone/node_modules" | grep -c earendil     # 期望：0

# 模拟 pi install npm:...
npm pack --silent --pack-destination "$T"
mkdir -p "$T/root" && (cd "$T/root" && npm init -y >/dev/null)
npm install "$T"/*.tgz --prefix "$T/root" --legacy-peer-deps --no-audit --no-fund
du -sh "$T/root/node_modules"                     # 期望：几十 KB

rm -rf "$T"
```

### 6.1 第四条路径：消费者裸装（**最容易漏、也最能暴露问题**）

```bash
# 不带 --legacy-peer-deps，也就是消费者自己 `npm i <pkg>` 的真实路径
mkdir -p "$T/e" && (cd "$T/e" && npm init -y >/dev/null)
npm install "$T"/*.tgz --prefix "$T/e" --no-audit --no-fund --loglevel=error
du -sh "$T/e/node_modules"
ls "$T/e/node_modules/@earendil-works" 2>/dev/null    # 期望：不存在
```

为什么必须有这一条：pi 的 npm 路径自带 `--legacy-peer-deps`，git 路径又可能被
`devDependencies` 巧合兜底（§5.3 的星号），两者都会"看起来正常"。
**只有这条路径每次都复现 400 MB 量级的宿主副本**（本机 `pi-jupyter` 改前复现出 564 MB / 434 MB）。

### 6.2 改动后必跑的回归

```bash
npm install --package-lock-only   # 同步 lockfile 的 packages[""]，否则 npm ci 与 package.json 漂移
git diff package-lock.json        # 看清有没有顺手删掉别的包（如 react）
npm install                       # 干净目录，验证 .npmrc 没打断 esbuild / rollup 平台包
npm run typecheck && npm test && npm run build
```

其他检查：

```bash
npm pack --dry-run        # 确认 tarball 内容与体积（files 白名单生效）
npm run typecheck         # 确认 devDependencies 的类型仍可用
git status --short        # 确认没误提交 node_modules
```

## 7. 发布到 npm

### 7.1 三条路

1. **本地发**：`npm login --auth-type=web && npm publish`（最快，无 provenance）。
2. **GitHub Actions + Trusted Publishing（推荐）**：OIDC，**不需要任何 secret**，带 provenance。
3. **Actions + `NPM_TOKEN`**：老办法，token 会过期，能不建就不建。

### 7.2 workflow 要点

```yaml
on:
  push:
    tags: ["v*"]        # ← 只推 tag 才触发；普通分支推送不会跑
  workflow_dispatch:

permissions:
  contents: read
  id-token: write       # OIDC：换 npm 短期凭证 + 生成 provenance
```

- 必须 npm ≥ 11.5（`npm install -g npm@latest`）。
- **不要**给 `setup-node` 设 `registry-url`：它会往 `.npmrc` 写一行 `authToken` 占位，
  可能遮住 OIDC 交换。npm 默认就发 registry.npmjs.org。
- 前置条件在 npmjs.com 包设置里配一次 publisher（org / repo / workflow 文件名 / environment），
  之后 `npm version patch && git push --follow-tags` 即可发版。
- 加一步 tag 与 `package.json` version 一致性校验，避免发错版本。

### 7.3 两个容易吓到自己的点

- **仓库里没有 tag 时，workflow 一次都不会触发**（`tags: ["v*"]` + `workflow_dispatch` 都不匹配
  普通分支推送），所以可以放心把 workflow 先提交上去、以后再配 npm 后端。
- **`.npmrc` 和 `.github/` 不会进 npm 包**：npm 强制排除 `.npmrc`，`files` 白名单挡住其余。
  实测 tarball 仍是 4 个文件 / 17 KB。

### 7.4 HTTPS remote 的坑

GitHub 对含 `.github/workflows/` 的提交，用 HTTPS + PAT 推送时要求 token 有 **`workflow` scope**，
否则直接 reject。SSH remote 不受影响。

## 8. 其他坑

- `npm pack` 会把 tarball 落在**当前目录**（不是 `/tmp`），记得 `--pack-destination` 或事后清理。
- `omit=optional` 会顺手废掉本地工具链：rollup / esbuild 的平台二进制（`@rollup/rollup-linux-x64-gnu`、
  `@esbuild/*`）本身就是 `optionalDependencies`，省略后 `vitest run` 报 `MODULE_NOT_FOUND: rollup/dist/native.js`。
  若仓库里没有*运行时*的可选依赖，这条 flag 对分发体积的贡献是 0，别加。
- `legacy-peer-deps=true` 会让 npm 停止为**你自己依赖树里的 peer** 解析，lockfile 可能被删条目
  （`pi-jupyter`：`@jupyterlab/settingregistry` / `@rjsf/utils` 的 peer `react` 被删）。加完必须
  `git diff package-lock.json`，并补跑 `npm ci` 语义的验证。
- 同一批 peer 同时出现在 `devDependencies` 会**伪装成"git 路径本来就没问题"**：`npm install --omit=dev`
  先把 peer 解析到那个 dev 条目、再随 dev 一起 omit。所以干净结果不能作为修复有效的证据（见 §6.1）。
- `package-lock.json` **不进 tarball、也不参与消费者安装**（`pi-jupyter` tarball 实测 20 文件 / 57 KB，
  无 lock、无 `.npmrc`、无 `.github`）：本地有 lock 时的干净结果不代表消费者，消费者走的是无 lock 裸解析。
- 改完 `peerDependencies` / `peerDependenciesMeta` 记得 `npm install --package-lock-only`，把
  `packages[""]` 里的 `peerDependenciesMeta` 同步进 lockfile（实测只 +14 行），否则 `npm ci` 与 package.json 漂移。
- 清残留时不要只删 `node_modules`：pi 的 `~/.pi/agent/git/**` 下每个装过的包都可能有一份，
  用 `find ~/.pi/agent/git -maxdepth 4 -name node_modules -type d` 一次性查全。
- 别去删 `~/.npm/_npx/<hash>/node_modules` —— 那是 pi 自身的运行实体（本机 999 MB），删了 pi 跑不起来。
- `~/.npm/_cacache` 会跟着涨（本机 779 MB 压缩包缓存），属正常，可用 `npm cache clean --force` 回收。

## 9. 待办

- [ ] 向上游报 bug：`getGitDependencyInstallArgs` 缺 `--legacy-peer-deps`，与
      `getNpmInstallArgs` 不一致，导致所有 git 安装的扩展被拖入一份 ~440 MB 宿主副本。
      影响面：任何把 `@earendil-works/pi-*` 写在 `peerDependencies` 且未标 `optional` 的包。
