<div align="center">

# ⚡ Xray 极速一键部署脚本集

**Reality 直连版** · **Reality + Caddy 共存版** · **Reality 双栈版** · **Cloudflare 隧道版 (Argo)**

轻量 · 高性能 · 深度网络调优 · 极简交互 · 64MB 小鸡可用

[![Xray-core](https://img.shields.io/badge/Xray--core-v26.10.21-blue.svg?logo=github)](https://github.com/XTLS/Xray-core)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Debian%20%7C%20Ubuntu%20%7C%20Alpine-orange.svg)](#-系统要求)
[![Arch](https://img.shields.io/badge/Arch-x86__64%20%7C%20arm64%20%7C%20armv7-lightgrey.svg)](#-系统要求)

</div>

---

## 📖 项目简介

本项目提供四套一键部署方案，覆盖公网直连、同端口建站伪装、IPv4/IPv6 双栈以及无公网 IP 隧道等常见场景：

| 方案 | 脚本 | 方案说明 | 适用场景 |
| :--- | :--- | :--- | :--- |
| **方案一** | [`rea.sh`](rea.sh) | **VLESS + Reality + Vision 直连（纯 IPv4）** | 有公网 IPv4 的常规 VPS，追求速度、简洁与高稳定性 |
| **方案二** | [`rea-caddy.sh`](rea-caddy.sh) | **VLESS + Reality + Caddy 443 共存（偷自己）** | 本机有网站/反代（如 New-API 3000 端口），想共用 443 并用自有域名伪装（仅 Debian/Ubuntu + x86_64） |
| **方案三** | [`rea-dual.sh`](rea-dual.sh) | **VLESS + Reality + Vision 双栈（IPv4 + IPv6）** | 同时有公网 IPv4 和 IPv6 的 VPS，独立端口双栈接入、出站统一 `UseIPv4` |
| **方案四** | [`argo.sh`](argo.sh) | **Xray + Cloudflare 临时/固定隧道 (Argo)** | **64MB 内存小鸡**、NAT 无公网端口、家宽动态 IP、IP 被墙但能连 Cloudflare |

> **注意**：`rea.sh`、`rea-caddy.sh`、`rea-dual.sh` 均使用 `/usr/local/etc/xray` 与 `xray` 管理命令（三者选其一部署或切换升级）；`argo.sh` 使用独立目录与 `argo` 命令，可与任意 Reality 方案共存。

---

## ✨ 核心特性

- 🚀 **深度内核网络调优**：
  - 自动启用 **BBR + FQ** 拥塞控制算法。
  - 深度注入 **TCP 动态缓冲区** 及长肥管道参数（32MB 上限；Argo 版在内存 < 160MB 时自动降为低内存档）。
  - 开启 **TCP Fast Open** 与 TCP KeepAlive，禁用无用服务端嗅探，降低握手延迟与资源开销。
- 🛡️ **纯粹原生安全**：
  - Reality 系列基于最新官方规范：`VLESS` + `Reality` + `xtls-rprx-vision`。
  - `rea.sh` / `rea-dual.sh` 支持**修改 SNI 自动握手体检**（TLS 1.3 支持与证书体积检测，防超 8KB 缓冲区）。
  - `rea-caddy.sh` 实现“**443 偷自己**”：Xray 占公网 443，Caddy 自动退守 `127.0.0.1:8443`（保留 80 端口续签证书），内置 `?secret=` 暗号开门 + Cookie + API Key 前缀三重防护，未授权请求统一返回 `404`。
  - `argo.sh` Xray 仅监听 `127.0.0.1`，外部无法直连，并拦截内网地址防 SSRF。
- 🖥️ **全终端命令行后台**：
  - Reality 系列输入 `xray`、隧道版输入 `argo` 即可呼出交互式管理菜单。
- 📉 **极低资源自适应（小鸡友好）**：
  - 识别低内存环境自动注入 Go 运行时防 OOM 参数（`GOGC` / `GOMEMLIMIT` / `madvdontneed`）；Argo 版支持自动创建 256MB Swap。
- 🔄 **在线平滑升级**：
  - Xray 内核、Caddy（APT）、cloudflared 与各自管理脚本均支持在线独立检测与升级。

---

## 💻 方案一：VLESS-Reality 直连版（rea.sh）

> **适用场景**：纯 IPv4 单栈常规 VPS（支持 Debian / Ubuntu / Alpine，`x86_64` / `arm64`），开箱即用、默认伪装 `www.java.com`。

### 1. 一键快速安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/justly110/xray/main/rea.sh)
```

> **备用命令（通过 wget）：**
> ```bash
> wget -O rea.sh https://raw.githubusercontent.com/justly110/xray/main/rea.sh && bash rea.sh
> ```

### 2. 管理面板

```bash
xray
```

```text
==========================================
      Xray-Reality 直连节点管理后台       
==========================================
程序版本: 脚本 v0.0.20 | 内核 v26.10.21
服务状态: ● 正在运行 (Running)
------------------------------------------
 1. 重启 Xray
 2. 启动 Xray
 3. 停止 Xray
 4. 查看全部节点链接及详细配置
 5. 修改主节点配置 (端口/SNI/UUID/密钥)
 6. TCP BBR 加速与网络调优
 7. 检查与升级 (Xray内核 / 管理脚本)
 8. 查看运行日志
 9. 彻底卸载 Xray
 0. 退出菜单
==========================================
```

---

## 🌐 方案二：VLESS-Reality + Caddy 一体化共存版（rea-caddy.sh）

> **适用场景**：在同一台 VPS 上同时部署自建网站/反代（如 3000 端口的 New-API）与 Reality 节点，**共用标准 443 端口并以自有域名作 SNI**（“偷自己”），IP 与域名真实对应、回落零延迟。
> **环境限制**：仅支持 **Debian / Ubuntu（systemd）+ `x86_64`**；需提前将域名直接解析到本机 IPv4（勿开 CDN 小云朵）并放行 **TCP 80 与 443** 端口。

### 1. 流量架构

```text
代理客户端 --(VLESS Reality :443, SNI=你的域名)--> Xray (0.0.0.0:443) --(直接代理出站)
普通访客/API/探测 --(HTTPS :443)--> Xray 识别非代理后透传 --> Caddy (127.0.0.1:8443) --> 后端网站 (127.0.0.1:3000)
Let's Encrypt 续签 --(HTTP-01 :80)--> Caddy (0.0.0.0:80) 自动完成证书申请与续签
```

### 2. 一键快速安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/justly110/xray/main/rea-caddy.sh)
```

安装过程中会引导交互输入：
1. **网站域名**（自动同步为 Reality 的 SNI，如 `ai.example.com`）
2. **TLS 证书邮箱**（默认 `admin@你的域名`）
3. **后台访问暗号 `secret`**（访问 `https://你的域名/?secret=暗号` 种下通行 Cookie 并进入网站，未带凭证一律返回 `404`）
4. **API Key 允许前缀**（默认 `sk-`，同时匹配 `Authorization: Bearer`、`x-api-key`、`x-goog-api-key`）
5. **后端反代端口**（默认 `3000`）

> 若系统未安装 Caddy，脚本会自动通过官方 APT 源安装；若是从旧版 `rea.sh`（原 `reality.sh`）直接覆盖运行，会自动备份原 `Caddyfile` 并询问是否复用原有 UUID 与 Reality 密钥。

### 3. 管理面板

```bash
xray
```

```text
==========================================
   Xray-Reality + Caddy 一体化管理后台    
==========================================
版本信息 : 脚本 v1.0.0 | Xray v26.10.21 | Caddy v2.x.x
Xray 状态: ● 正在运行 (Running)
Caddy状态: ● 正在运行 (Running)
------------------------------------------
 1. 重启 Xray & Caddy
 2. 启动 Xray & Caddy
 3. 停止 Xray & Caddy
 4. 查看节点链接与 Caddy 防护配置
 5. 修改 Xray 节点配置 (端口/UUID/密钥/SNI)
 6. 修改 Caddy 网站配置 (域名/暗号/Key前缀/反代端口)
 7. TCP BBR 加速与网络调优
 8. 检查与升级 (Xray / Caddy / 管理脚本)
 9. 查看运行日志 (Xray / Caddy)
10. 彻底卸载
 0. 退出菜单
==========================================
```

---

## 🔀 方案三：VLESS-Reality 双栈直连版（rea-dual.sh）

> **适用场景**：同时拥有公网 IPv4 与 IPv6 的 VPS（支持 Debian / Ubuntu / Alpine，`x86_64` / `arm64`），需要**同时输出 IPv4 与 IPv6 两条节点链接**，分别应付不同网络环境。

### 1. 一键快速安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/justly110/xray/main/rea-dual.sh)
```

> **备用命令（通过 wget）：**
> ```bash
> wget -O rea-dual.sh https://raw.githubusercontent.com/justly110/xray/main/rea-dual.sh && bash rea-dual.sh
> ```

### 2. 特性与工作原理

- **双栈独立端口监听**：IPv4 监听 `0.0.0.0:443`，IPv6 启用 `v6only` 监听 `[::]:8443`（可在菜单中分别修改端口），避免 Xray 默认双栈占位引起绑定冲突。
- **出站统一 `UseIPv4`**：无论客户端从 IPv4 还是 IPv6 入口连入，出站策略统一优先走 IPv4（纯 IPv6 目标自动回退），避免访问流媒体或 AI 服务时 IPv4/IPv6 横跳触发风控。
- **双链接自动生成**：`link.txt` 同时输出 `-v4` 与 `-v6` 两条节点链接；若机器未开启 IPv6 则自动退化为仅监听 IPv4。

### 3. 管理面板

```bash
xray
```

```text
==========================================
     Xray-Reality 双栈节点管理后台        
==========================================
程序版本: 脚本 v0.0.3 | 内核 v26.10.21
服务状态: ● 正在运行 (Running)
网络协议: IPv4 + IPv6 双栈
------------------------------------------
 1. 重启 Xray
 2. 启动 Xray
 3. 停止 Xray
 4. 查看全部节点链接及详细配置
 5. 修改主节点配置 (端口/SNI/UUID/密钥)
 6. TCP BBR 加速与网络调优
 7. 检查与升级 (Xray内核 / 管理脚本)
 8. 查看运行日志
 9. 彻底卸载 Xray
 0. 退出菜单
==========================================
```

---

## ☁️ 方案四：Cloudflare 临时隧道版（argo.sh）

> **典型用户**：64MB 内存的 Alpine 小鸡、只有 IPv6 的机器、NAT 小鸡没有任何可用入站端口、家宽动态 IP、IP 被墙但能访问 Cloudflare 的机器。
> 不需要公网 IP、不需要开放入站端口、不需要域名，也不需要 Cloudflare 账号。

### 1. 一键安装

```bash
# Alpine 需要先装 bash（Debian / Ubuntu 可跳过）
apk add --no-cache bash curl

bash <(curl -fsSL https://raw.githubusercontent.com/justly110/xray/main/argo.sh)
```

脚本会自动完成：识别架构（`x86_64` / `arm64` / `armv7`）→ 下载官方 `xray-core` 与 `cloudflared` → 生成 UUID / WS 路径 → 渲染配置 → 注册服务 → 网络调优 → 按需创建 Swap → 启动并打印节点链接。

### 2. 管理后台

```bash
argo
```

```text
==========================================
     Xray + Cloudflare 隧道 管理后台
==========================================
 脚本: v0.0.1 | Xray: v26.10.21 | cf: 2026.x.x
 状态: Xray: ● 运行 | 隧道: ● 运行
 模式: quick | 协议: http2
 域名: xxxx-xxxx-xxxx.trycloudflare.com
------------------------------------------
  1. 查看节点链接 / 当前隧道域名
  2. 重启全部服务
  3. 刷新隧道域名并输出新链接
  4. 修改节点参数 (路径/UUID/端口/备注)
  5. 隧道设置 (协议/边缘IP/固定域名Token)
  6. 网络内核调优 (BBR / TCP)
  7. 管理 Swap
  8. 查看日志
  9. 检查与升级
 10. 彻底卸载
  0. 退出
==========================================
```

也可以直接命令行取链接：

```bash
argo --link
```

### 3. 工作原理

```text
客户端 --(VLESS over WS + TLS :443)--> Cloudflare 边缘节点
        --(cloudflared 主动出站隧道)--> 你的小鸡 127.0.0.1:10000 (Xray)
        --(freedom 出站)--> 互联网
```

- `cloudflared` 是**主动向外**连接 Cloudflare 边缘的，所以小鸡**不需要公网 IP、不需要开放任何入站端口**，也不受运营商封端口影响；
- 免账号免域名，自动获得一个 `https://xxxx-xxxx.trycloudflare.com` 临时域名（TryCloudflare 快速隧道）；
- 客户端用这个域名作 `address` + `sni` + `host`，协议为 `VLESS + WebSocket + TLS`。

### 4. 使用要点

- **临时域名每次重启都会变**：`argo` → `3` 刷新即可拿到新链接，脚本每次重启服务后也会自动打印新链接。域名保存在 `/var/log/cfargo.log`，可用 `argo` → `8` 查看。
- **备用端口**：脚本同时输出 `8443` / `2053` 两个备用端口链接（Cloudflare 支持的 HTTPS 端口），443 被运营商干扰时可直接换端口，无需改服务端。
- **低配内存策略**（自动，无需干预）：
  - 内存 ≤ 160MB 且无 Swap → 自动创建 **256MB Swap**（`argo` → `7` 可手动加/删）；
  - 两个进程分别注入 `GOGC=20`、`GOMEMLIMIT=24MiB`，防止瞬时握手把内存打满被 OOM Killer 杀掉；
  - TCP 缓冲上限在低内存档自动降到 8MB（正常机器为 32MB）。
  - **64MB 属于极限**：能跑，但建议 swap 至少 512MB，且不要跑大流量下载。
- **传输协议**：默认 `http2`（省内存、穿透性好）；若速度不理想，`argo` → `5` → `1` 切到 `quic`。纯 IPv6 小鸡把边缘 IP 版本切成 `6`。
- **固定域名（可选，需自己的域名）**：
  1. Cloudflare Zero Trust → Networks → Tunnels → 新建隧道，复制 Token；
  2. 在该隧道 Public Hostname 中添加：子域名 + 域名 → 服务 `http://127.0.0.1:10000`；
  3. 在小鸡上 `argo` → `5` → `3`，填入 Token 和完整域名（如 `a.example.com`）。
  脚本会切到 `token` 模式并输出固定域名链接，重启不再变化。

### 5. 客户端导入

- **v2rayN / v2rayNG / sing-box / Shadowrocket / NekoBox**：直接导入脚本输出的 `vless://` 链接；
- **Clash / Mihomo（FlClash、Clash Verge Rev 等）**：`/usr/local/etc/xrayargo/link.txt` 里附带可直接粘贴的 `proxies:` 片段；
- 因为走的是 Cloudflare CDN，**延迟会比直连略高**，但胜在免端口、免公网 IP、抗封锁。

### 6. 说明与限制

- TryCloudflare 免费隧道有带宽与连接数限制，**适合个人轻量使用与应急备用**；大流量、长期主力请用 Reality 直连系列方案。
- 免费隧道不保证稳定性，Cloudflare 可随时调整策略。
- Argo 方案与 Reality 系列可以装在同一台机器上（服务名、目录、二进制完全隔离），互不干扰。

---

## 📁 核心文件与路径说明

### Reality 系列（`rea.sh` / `rea-caddy.sh` / `rea-dual.sh`）

| 文件路径 | 说明 |
| :--- | :--- |
| `/usr/local/bin/xray-core` | Xray 核心执行二进制程序 |
| `/usr/local/bin/xray` | 面板快捷管理脚本（终端命令 `xray`） |
| `/usr/local/etc/xray/config.json` | Xray 核心服务端运行配置文件 |
| `/usr/local/etc/xray/params.env` | 当前节点（及 Caddy 联动）持久化环境变量 |
| `/usr/local/etc/xray/link.txt` | 节点直连链接与参数明细备份 |
| `/usr/local/etc/xray/extra_nodes.env`| 多端口/多用户扩展节点记录文件 |
| `/etc/caddy/Caddyfile` | Caddy 配置文件（仅 `rea-caddy.sh` 方案使用） |

### Cloudflare 隧道版（`argo.sh`）

| 文件路径 | 说明 |
| :--- | :--- |
| `/usr/local/bin/argo` | 面板快捷管理脚本（终端命令 `argo`） |
| `/usr/local/bin/xray-argo` | Xray 核心（仅监听 `127.0.0.1`） |
| `/usr/local/bin/cloudflared` | Cloudflare 隧道客户端（官方版） |
| `/usr/local/bin/cfargo-run` | 隧道启动包装脚本（日志重定向 + 低内存参数） |
| `/usr/local/etc/xrayargo/config.json` | Xray 配置（VLESS + WS，本地回环） |
| `/usr/local/etc/xrayargo/params.env` | 节点参数（UUID / 路径 / 端口 / 隧道模式 / Token） |
| `/usr/local/etc/xrayargo/link.txt` | 最新节点链接 + Clash 片段 |
| `/var/log/cfargo.log` | 隧道运行日志（含临时域名） |
| `/swapfile` | 低内存自动创建的 Swap 文件（如有） |

> Reality 服务名：`xray`（`systemctl status xray`）。
> Argo 服务名：`xrayargo`（Xray 核心）、`cfargo`（隧道）。Systemd：`systemctl status xrayargo cfargo`；OpenRC：`rc-service cfargo status`。

---

## ⚙️ 系统要求

| 脚本 | 支持系统 | 支持架构 |
| :--- | :--- | :--- |
| `rea.sh` / `rea-dual.sh` | Debian 10+ / Ubuntu 20.04+ / Alpine 3.16+ | `x86_64` / `arm64` |
| `rea-caddy.sh` | Debian 10+ / Ubuntu 20.04+（systemd） | `x86_64` |
| `argo.sh` | Debian 10+ / Ubuntu 20.04+ / Alpine 3.16+ | `x86_64` / `arm64` / `armv7` |

- **基础依赖**：脚本会自动检查并安装 `bash`、`curl`、`openssl`、`unzip`、`ca-certificates` 等（`rea-caddy.sh` 还会自动安装 `gnupg` 与官方 `caddy`）。

---

## 📱 客户端兼容性指南

Reality 版生成的节点链接协议格式为：
```text
vless://${UUID}@${IP}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${SNI}&sid=${SHORT_ID}#节点名称
```

Argo 隧道版生成的节点链接协议格式为：
```text
vless://${UUID}@${隧道域名}:443?encryption=none&security=tls&sni=${隧道域名}&fp=chrome&type=ws&host=${隧道域名}&path=${WS_PATH}&headerType=none#节点名称
```

- **v2rayN / v2rayNG / Sing-box / Shadowrocket**：直接导入上方生成的链接即可使用。
- **FlClash / Clash Verge Rev (Mihomo 内核)**：
  - Reality 版：由于新版 Xray-core（v26.9.8+）强化了对 Chrome 指纹的后量子协商检测，Mihomo 内核需在 `reality-opts` 中包含 `support-x25519mlkem768: true`，建议搭配配套的订阅转换工具使用。
  - Argo 隧道版：使用 WS + TLS，无需 Reality 相关参数，`link.txt` 中已附带可直接使用的 `proxies:` 片段。

---

## ⚠️ 免责声明

- 本项目仅供网络技术学习、科研与管理自身 VPS 使用。
- 请遵守服务器所在地区以及相关法律法规，请勿用于非法用途。
- 使用 Cloudflare 隧道即表示你同意 Cloudflare 的服务条款，请勿滥用免费资源。