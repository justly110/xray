<div align="center">

# ⚡ Xray 极速一键部署脚本集

**VLESS-Reality 直连版** · **Cloudflare 临时隧道版 (Argo)**

轻量 · 高性能 · 深度网络调优 · 极简交互 · 64MB 小鸡可用

[![Xray-core](https://img.shields.io/badge/Xray--core-v26.10.21-blue.svg?logo=github)](https://github.com/XTLS/Xray-core)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Debian%20%7C%20Ubuntu%20%7C%20Alpine-orange.svg)](#-系统要求)
[![Arch](https://img.shields.io/badge/Arch-x86__64%20%7C%20arm64%20%7C%20armv7-lightgrey.svg)](#-系统要求)

</div>

---

## 📖 项目简介

本项目提供两套互相独立、可共存的一键部署方案：

| 脚本 | 方案 | 适用场景 |
| :--- | :--- | :--- |
| [`reality.sh`](reality.sh) | **VLESS + Reality + Vision 直连** | 有公网 IP 的正常 VPS，追求速度与隐蔽性（推荐主力） |
| [`argo.sh`](argo.sh) | **Xray + Cloudflare 临时隧道 (Argo)** | **64MB 内存小鸡**、NAT 无公网端口、家宽动态 IP、IP 被墙但能连 Cloudflare |

两者都内置**长肥管道网络优化**、**低内存防 OOM 自动保护**、**全终端交互式管理后台**与**在线平滑升级**。

---

## ✨ 核心特性

- 🚀 **深度内核网络调优**：
  - 自动启用 **BBR + FQ** 拥塞控制算法。
  - 深度注入 **TCP 动态缓冲区** 及长肥管道参数，显著提升高延迟、跨洲跨洋线路的吞吐速度（内存 < 160MB 时自动降为低内存档，避免把内存吃满）。
  - 开启 **TCP Fast Open** 与 TCP KeepAlive，禁用无用服务端嗅探，降低握手延迟与资源开销。
- 🛡️ **纯粹原生安全**：
  - Reality 版基于最新官方规范：`VLESS` + `Reality` + `xtls-rprx-vision`，默认伪装 `www.java.com`。
  - 支持**修改 SNI 自动握手体检**：验证目标站点 TLS 1.3 支持与证书体积（防超 8KB 缓冲区）。
  - Argo 版 Xray 仅监听 `127.0.0.1`，外部无法直连，杜绝端口暴露；同时拦截内网地址，防 SSRF。
- 🖥️ **全终端命令行后台**：
  - 部署完成后直接在终端输入 `xray`（Reality 版）或 `argo`（隧道版）即可呼出多功能交互式管理菜单。
- 📉 **极低资源自适应（小鸡友好）**：
  - 识别内存 ≤ 256MB（Reality）/ ≤ 160MB（Argo）环境，自动注入 Go 运行时防 OOM 参数（`GOGC` / `GOMEMLIMIT` / `madvdontneed`）。
  - Argo 版在内存不足且无 Swap 时，**自动创建 256MB Swap**，64MB 小鸡也能跑起来。
- 🔄 **双独立在线平滑升级**：
  - Xray 内核、cloudflared、管理脚本支持在线独立检测与升级，无需重复配置。
- 🌐 **双系统全环境支持**：
  - 完美适配 **Systemd** 发行版（Debian 10+ / Ubuntu 20.04+）与 **OpenRC** 超轻量发行版（Alpine Linux）。

---

## 💻 方案一：VLESS-Reality 直连版（reality.sh）

### 1. 一键快速安装

在服务器终端中以 `root` 权限运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/justly110/xray/main/reality.sh)
```

> **备用命令（通过 wget）：**
> ```bash
> wget -O reality.sh https://raw.githubusercontent.com/justly110/xray/main/reality.sh && bash reality.sh
> ```

### 2. 随时呼出管理面板

```bash
xray
```

```text
==========================================
      Xray-Reality 直连节点管理后台       
==========================================
程序版本: 脚本 v0.0.19 | 内核 v26.10.21
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

## ☁️ 方案二：Cloudflare 临时隧道版（argo.sh）

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

- TryCloudflare 免费隧道有带宽与连接数限制，**适合个人轻量使用与应急备用**；大流量、长期主力请用 `reality.sh` 直连版。
- 免费隧道不保证稳定性，Cloudflare 可随时调整策略。
- 两种方案可以装在同一台机器上（服务名、目录、二进制完全隔离），互不干扰。

---

## 📁 核心文件与路径说明

### Reality 直连版（reality.sh）

| 文件路径 | 说明 |
| :--- | :--- |
| `/usr/local/bin/xray-core` | Xray 核心执行二进制程序 |
| `/usr/local/bin/xray` | 面板快捷管理脚本（终端命令 `xray`） |
| `/usr/local/etc/xray/config.json` | Xray 核心服务端运行配置文件 |
| `/usr/local/etc/xray/params.env` | 当前节点的核心参数持久化环境变量 |
| `/usr/local/etc/xray/link.txt` | 节点直连链接与参数明细备份 |
| `/usr/local/etc/xray/extra_nodes.env`| 多端口/多用户扩展节点记录文件 |

### Cloudflare 隧道版（argo.sh）

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

> 服务名：`xrayargo`（Xray 核心）、`cfargo`（隧道）。
> Systemd：`systemctl status xrayargo cfargo`；OpenRC：`rc-service cfargo status`。

---

## ⚙️ 系统要求

- **操作系统**：
  - Debian 10+
  - Ubuntu 20.04+
  - Alpine Linux 3.16+（64MB 内存实测可用）
- **CPU 架构**：
  - `x86_64` / `amd64`
  - `aarch64` / `arm64`
  - `armv7l` / `armhf`（仅 argo 隧道版支持）
- **基础依赖**：脚本会自动检查并安装 `bash`、`curl`、`openssl`、`unzip`、`ca-certificates` 等。

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
