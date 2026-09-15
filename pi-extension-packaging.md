# pi 扩展打包与分发手册（安装体积 / peer 依赖 / 发布）

> 记录 2026-09-15 给 `pi-trace-id` 瘦身 880 MB 的过程：一个 `peerDependenciesMeta` 标记
> 让安装占用从 440 MB/份降到 0，以及 pi 两条安装路径参数不一致这个上游 bug。

## 1. 结论速查（TL;DR）

- **pi 扩展里的 `peerDependencies` 一定要配 `peerDependenciesMeta: { "optional": true }`**，
  否则 `pi install git:...` 会给每个包额外装一份 ~440 MB 的 `@earendil-works/pi-coding-agent`。
- 宿主类型包若只为 `npm run typecheck` / IDE 补全存在，放 `devDependencies`，不要放 `dependencies`。
- 只做 `import type` 的扩展**运行时零依赖**，安装应该接近 0 字节。若装出几百 MB，一定是配置错了。
- 仓库根的 `.npmrc` 里 `legacy-peer-deps=true` + `omit=optional` 是便宜的兜底（顺手跳过 esbuild 的
  26 个预编译平台二进制，约 284 MB）。
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

### 5.2 .npmrc（兜底，可选但便宜）

```ini
legacy-peer-deps=true
omit=optional
```

git 安装路径是 `cd <clone> && npm install`，会读到仓库根的 `.npmrc`，所以这层能生效。
`omit=optional` 跳过 esbuild 的平台包，让本地开发也少 284 MB。

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
- `omit=optional` 不能写进 `.npmrc` 就算完 —— 它同时影响开发环境，若依赖里有必需的可选包要慎用。
- 清残留时不要只删 `node_modules`：pi 的 `~/.pi/agent/git/**` 下每个装过的包都可能有一份，
  用 `find ~/.pi/agent/git -maxdepth 4 -name node_modules -type d` 一次性查全。
- 别去删 `~/.npm/_npx/<hash>/node_modules` —— 那是 pi 自身的运行实体（本机 999 MB），删了 pi 跑不起来。
- `~/.npm/_cacache` 会跟着涨（本机 779 MB 压缩包缓存），属正常，可用 `npm cache clean --force` 回收。

## 9. 待办

- [ ] 向上游报 bug：`getGitDependencyInstallArgs` 缺 `--legacy-peer-deps`，与
      `getNpmInstallArgs` 不一致，导致所有 git 安装的扩展被拖入一份 ~440 MB 宿主副本。
      影响面：任何把 `@earendil-works/pi-*` 写在 `peerDependencies` 且未标 `optional` 的包。
