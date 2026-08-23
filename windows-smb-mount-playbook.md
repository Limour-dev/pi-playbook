# Windows SMB 共享挂载手册（含排查经验）

> 记录 2026-08-23 从 Debian 挂载 Windows 10 共享文件夹（file://host/share）的完整流程、排查链路与坑。

## 1. 背景与目标

- 宿主机 Windows 10 共享了文件夹，共享权限设为 **Everyone 可读**。
- 目标：Linux 侧通过 SMB/CIFS 挂载到本地目录，正常读写。
- 环境：Debian 13 (trixie)，cifs-utils + smbclient。

## 2. 排查链路（按序执行）

### 2.1 网络连通性

```bash
getent hosts <WIN_HOST>            # 主机名解析
ping -c 2 -W 2 <WIN_HOST>
timeout 5 bash -c 'cat < /dev/null > /dev/tcp/<WIN_HOST>/445' && echo "445 OPEN"
```

- **TCP 445 通 ≠ 认证能过**。防火墙只挡连接层，认证失败是另一回事（见 2.3）。

### 2.2 探测共享与匿名访问

```bash
smbclient -L //<WIN_HOST> -N              # 匿名列举 → 通常 NT_STATUS_ACCESS_DENIED
smbclient -L //<WIN_HOST> -U guest%       # guest → 通常 NT_STATUS_ACCOUNT_DISABLED
```

- Win10 默认禁用 guest 匿名登录，即使共享设了 Everyone，匿名也进不去。

### 2.3 认证失败错误码对照（dmesg / smbclient）

| 报错 | 含义 | 处理 |
|---|---|---|
| `NT_STATUS_ACCESS_DENIED` | 会话/session 被拒 | 换真实凭据；或启用 guest |
| `NT_STATUS_ACCOUNT_DISABLED` | guest 账户禁用 | `net user guest /active:yes`（不推荐，见坑 4.4） |
| `NT_STATUS_LOGON_FAILURE` / `0xc000006d` | 用户名或密码错 | 核对账户类型（本地/MS 账户）、密码 |
| `mount error(13)` | 同上，内核层 SessSetup 失败 | 看 `dmesg \| tail` 定位具体状态码 |

排查认证必看：

```bash
sudo dmesg | grep -i cifs | tail      # 例：STATUS_LOGON_FAILURE (0xc000006d)
```

## 3. 凭据安全处理（关键）

**密码绝不进命令行、不进聊天、不进工具流**。用凭据文件 + 交互式输入：

```bash
# 由用户在自己终端执行：提示输入用户名/密码，密码不回显
sudo bash -c 'read -p "用户名: " u && read -s -p "密码: " pw && \
  printf "username=%s\npassword=%s\n" "$u" "$pw" > /etc/samba/<SHARE>.cred && \
  chmod 600 /etc/samba/<SHARE>.cred && echo 已保存'
```

- 凭据文件权限 600（仅 root 可读），username/password 各一行，无多余空行。
- 挂载命令用 `credentials=` 引用文件，避免密码出现在 `ps`、shell history。

## 4. 踩坑记录（务必先看）

### 4.1 🔴 Microsoft 账户无法本地改密码

`net user <用户名> 新密码` 报 **错误 8646**（"系统对指定的账户没有授权"）= 该账户是 **Microsoft 账户（联机账户）**，密码只能在微软官网改，且 SMB 访问通常需要生成**应用密码**（两步验证开启时）。

**推荐解法：新建专用本地账户**，与日常账户隔离：

```cmd
net user <NEW_LOCAL_USER> <密码> /add
```

无论共享设的是 Everyone 还是单独授权，新建的本地账户 + 凭据认证都能访问。

### 4.2 PIN / 指纹不能用于 SMB

Windows 登录用 PIN 不代表账户有这个密码。SMB 认证只认**账户真实密码**（或应用密码）。用户"以为自己有密码"是常见假象。

### 4.3 防火墙不是万能挡板

本次实测 445 TCP 已通、但认证被拒 → 主因是账户认证而非防火墙。但若防火墙确实挡了，配置如下（Windows 管理员）：

```cmd
netsh advfirewall firewall set rule group="文件和打印机共享" new enable=yes
netsh advfirewall firewall add rule name="SMB-In-445" dir=in action=allow protocol=TCP localport=445
```

另需确认当前网络配置文件为"专用网络"（设置 → 网络和 Internet → 当前连接）。

### 4.4 启用 guest 的代价

`net user guest /active:yes` 能解决匿名访问，但**安全性差**（任何人可匿名读共享），且还需改 secpol 策略（来宾账户状态、本地账户共享模型）。优先用专用本地账户。

### 4.5 Windows 账户列表里的"幽灵账户"

`net user` 列出的 `Administrator / DefaultAccount / Guest / WDAGUtilityAccount` 均为系统内置（WDAG 为 Win10 1709+ 自带），非病毒。出现不认识的用户账户时先查状态再判断：

```powershell
Get-LocalUser | Select Name, Enabled, Description, PasswordLastSet, LastLogon
net localgroup administrators
```

禁用状态 + 不在管理员组 = 多为历史遗留（二手/公用机），风险低。

## 5. 挂载与验证

```bash
# 挂载（凭据文件已配好；uid/gid 映射到普通用户，免 sudo 读写）
sudo mount -t cifs //<WIN_HOST>/<SHARE> /mnt/<SHARE> \
  -o credentials=/etc/samba/<SHARE>.cred,vers=3.0,uid=1000,gid=1000,iocharset=utf8

mount | grep <SHARE>        # 查看挂载选项确认已挂载
ls /mnt/<SHARE>             # 验证可读
cp /mnt/<SHARE>/<file> ./   # 验证可读写
```

- `vers=3.0`：Win10 支持 SMB2/3，兼容性好。
- `uid=1000,gid=1000`：使挂载点属主为普通用户（注意会隐式启用 forceuid/forcegid，权限位以挂载参数为准）。

## 6. 重启后的处理

- CIFS 挂载**重启即失效**，需重新挂载（凭据文件保留，命令重跑即可，无需再输密码）。
- 也可写入 `/etc/fstab` 实现开机自动挂载：

```
//<WIN_HOST>/<SHARE>  /mnt/<SHARE>  cifs  credentials=/etc/samba/<SHARE>.cred,vers=3.0,uid=1000,gid=1000,iocharset=utf8  0  0
```

然后用 `sudo mount -a` 验证。

## 7. 一句话总结

网络通 → 匿名被拒属正常 → 真实凭据（本地账户优先，MS 账户需应用密码）→ 凭据文件 + `read -s` 交互输入 → `mount -t cifs` 挂载 → 重启记得重挂（或上 fstab）。