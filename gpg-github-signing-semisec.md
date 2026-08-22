# GPG 签名 + GitHub 配置手册（含安全教训）

> 记录 2026-08-22 配置 GPG 签名提交、加密备份，以及一次**密钥泄露事故**（解密明文被输出到工具流 → 传输给模型服务商）的完整过程与教训。

## 1. 背景与目标

- 生成 GPG 密钥对 → 公钥添加到 GitHub（提交显示 Verified）。
- 配置 git 全局签名：`commit.gpgsign` / `tag.gpgsign`。
- 备份 `~/.gnupg` 并用对称加密保护。

## 2. 关键知识点

### 2.1 密钥生成（非交互）

```bash
gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-generate-key "Name <email>" ed25519 sign 0
# 0 = 永不过期；ed25519 现代且快；空口令 = 提交时不弹框
```

- 指纹 = 完整 ID（40 hex），生成时打印的 `C062D043...` 即指纹。
- 撤销证书自动存到 `~/.gnupg/openpgp-revocs.d/<FPR>.rev`。

### 2.2 git 签名配置

```bash
git config --global user.signingkey <FPR 或短ID>
git config --global commit.gpgsign true
git config --global tag.gpgsign true
```

- GitHub 要求密钥 uid 邮箱 = 账号已验证邮箱，否则显示 Unverified。

### 2.3 备份与对称加密

```bash
tar czf gpg-backup-$(date +%Y%m%d).tar.gz ~/.gnupg
gpg -c gpg-backup-*.tar.gz        # 对称加密，任意文件都行（AES-256，口令→密钥）
rm gpg-backup-*.tar.gz            # 删除明文！只留 .gpg
```

- `gpg -c` 不需要密钥对，口令经 SHA512 迭代哈希生成对称密钥，可加密任意字节流。
- 明文备份含私钥且无口令保护 = 拿到即用，必须删除。

## 3. 🔴 重大事故与教训（务必遵守）

### 3.1 事故经过

验证备份时执行了 `gpg -d 备份.gpg 2>&1 | head -5`，**解密出的明文（含无口令私钥）被打印到 stdout，经工具输出回传给模型服务商**。因密钥无 passphrase，泄露字节 = 直接可用的私钥。

### 3.2 铁律：解密内容永不输出到工具流

- ❌ `gpg -d 文件 | head` / `cat 明文` / `显示解密内容`
- ✅ 验证解密成功：`gpg -d 文件 > /dev/null`（只丢弃，不显示）
- ✅ 查看加密文件类型：`file 文件.gpg`（只读头部，不解密）
- ✅ 显示签名指纹不敏感：`git log --format="%G? %GK" -1`
- 任何可能含私钥/口令的明文输出（tar 包、keyring 导出、agent 缓存转储）都禁止进 stdout。

### 3.3 泄露后的应急流程（已执行，可复用）

```bash
# 1. 撤销旧密钥（导入撤销证书）
sed 's/^:-----BEGIN/-----BEGIN/' ~/.gnupg/openpgp-revocs.d/<FPR>.rev > /tmp/r.asc
gpg --import /tmp/r.asc && rm /tmp/r.asc
# 2. 删除旧密钥（同一 uid 无法再生成，必须先删）
gpg --batch --yes --delete-secret-keys <FPR>
gpg --batch --yes --delete-keys <FPR>
# 3. 生成新密钥（同 uid），更新 git signingkey，重新导出公钥
# 4. GitHub：删除旧 key → 添加新 key（settings/keys）
# 5. 重新制作加密备份（口令由用户在自己终端输入，绝不经过工具流）
```

## 4. 其他坑

- **撤销证书有防误用冒号**：`.rev` 文件里是 `:-----BEGIN PGP PUBLIC KEY BLOCK-----`，直接 `gpg --import` 报 "no valid OpenPGP data found"，必须 `sed` 去掉冒号再导入。
- 本构建（gpg 2.4.7）无 `--quick-revoke-key` 选项，只能走撤销证书导入。
- 同 uid 已有密钥（即使已撤销）时 `--quick-generate-key` 报 "A key for ... already exists"，要先删除。
- 备份口令由**用户**在自己终端交互输入（`gpg -c`），agent 用 `--pinentry-mode loopback --passphrase 'xxx'` 会把口令写进工具流，同样泄露。

## 5. 验证方法（不泄密）

```bash
echo test | gpg --sign --armor -o /dev/null   # 本地签名自检
git commit -S -m "test"                        # 真实签名提交
git log --show-signature -1                    # 本机验证 Good signature
git log --format="%G? %GK" -1                  # G = 好签名，GK = 指纹
# GitHub 上推提交后看绿色 Verified 徽章
```