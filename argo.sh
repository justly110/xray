#!/bin/bash
# ==============================================================================
#  Xray + Cloudflare 临时隧道 (Argo / TryCloudflare) 一键部署脚本
#  仓库: https://github.com/justly110/xray   (文件: argo.sh)
#  适用: Alpine / Debian / Ubuntu | 64MB 内存小鸡 | x86_64 / arm64 / armv7
#
#  原理: 客户端 ==(VLESS over WS + TLS:443)==> Cloudflare 边缘
#        ==(cloudflared 出站隧道)==> 本机 127.0.0.1:10000 (Xray) ==> 互联网
#
#  优点: 不需要公网 IP、不用开放任何入站端口、不用域名和 CF 账号(临时域名)
#  注意: trycloudflare 临时域名每次重启都会变; 免费隧道带宽有限, 适合轻量/备用
# ==============================================================================

SCRIPT_VERSION="0.0.1"
SCRIPT_URL="https://raw.githubusercontent.com/justly110/xray/main/argo.sh"
CLI_PATH="/usr/local/bin/argo"

if [ "$(id -u)" != "0" ]; then
    echo "❌ 错误：请使用 root 权限运行本脚本"
    exit 1
fi

install_dependencies() {
    echo "📦 正在检查基础依赖..."
    if command -v apk >/dev/null 2>&1; then
        apk update >/dev/null 2>&1 || true
        apk add --no-cache bash curl ca-certificates openssl unzip >/dev/null 2>&1 || true
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates openssl unzip >/dev/null 2>&1 || true
    fi
    mkdir -p /usr/local/bin /usr/local/etc/xrayargo /var/log
}

write_cli() {
    cat > "$CLI_PATH" << 'ARGO_CLI_EOF'
#!/bin/bash
# ============================================================
#  argo —— Xray + Cloudflare 隧道 管理后台
#  本文件由 argo.sh 自动生成, 升级时会被覆盖, 请勿手工修改
#  仓库: https://github.com/justly110/xray
# ============================================================
SCRIPT_VERSION="0.0.1"
SCRIPT_URL="https://raw.githubusercontent.com/justly110/xray/main/argo.sh"

CONF_DIR="/usr/local/etc/xrayargo"
CONF_FILE="$CONF_DIR/config.json"
ENV_FILE="$CONF_DIR/params.env"
LINK_FILE="$CONF_DIR/link.txt"
RUN_SH="/usr/local/bin/cfargo-run"
XRAY_BIN="/usr/local/bin/xray-argo"
CF_BIN="/usr/local/bin/cloudflared"
CF_LOG="/var/log/cfargo.log"
SWAP_FILE="/swapfile"
SVC_X="xrayargo"
SVC_C="cfargo"

ARCH_TAG=""; XRAY_ZIP=""; CF_ASSET=""
UUID=""; WSPATH=""; LPORT=""; CF_MODE=""; CF_TOKEN=""; CF_HOST=""
CF_PROTOCOL=""; CF_EDGE_IP=""; NODE_NAME=""

# ------------------------------------------------------------
# 0. 通用辅助
# ------------------------------------------------------------
ok()    { printf '\033[32m%s\033[0m\n' "$*"; }
warn()  { printf '\033[33m%s\033[0m\n' "$*"; }
err()   { printf '\033[31m%s\033[0m\n' "$*"; }
info()  { printf '%s\n' "$*"; }
pause() { printf '\n'; read -n 1 -s -r -p "按任意键返回..." </dev/tty; }

check_root() { [ "$(id -u)" = "0" ] || { err "❌ 请使用 root 权限运行"; exit 1; }; }

json_escape() {
    local s="$1"
    s=${s//\\/\\\\}; s=${s//\"/\\\"}
    s=${s//$'\n'/ }; s=${s//$'\r'/ }; s=${s//$'\t'/ }
    printf '%s' "$s"
}

env_quote() {
    local s="$1"
    s=${s//\\/\\\\}; s=${s//\"/\\\"}
    s=${s//\$/\\\$}; s=${s//\`/\\\`}
    s=${s//$'\n'/ }
    printf '%s' "$s"
}

path_encode() { printf '%s' "$1" | sed -e 's/%/%25/g' -e 's|/|%2F|g'; }

mem_total_mb() { awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null; }
swap_total_mb() { awk '/^SwapTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null; }

mem_report() {
    printf '💡 内存: %sMB | Swap: %sMB | 架构: %s -> %s\n' \
        "$(mem_total_mb)" "$(swap_total_mb)" "$(uname -m)" "$ARCH_TAG"
}

# ------------------------------------------------------------
# 1. 架构识别 / 下载
# ------------------------------------------------------------
detect_arch() {
    local m; m=$(uname -m)
    case "$m" in
        x86_64|amd64)       ARCH_TAG="amd64"; XRAY_ZIP="Xray-linux-64.zip";          CF_ASSET="cloudflared-linux-amd64" ;;
        aarch64|arm64)      ARCH_TAG="arm64"; XRAY_ZIP="Xray-linux-arm64-v8a.zip";   CF_ASSET="cloudflared-linux-arm64" ;;
        armv7l|armv7|armhf) ARCH_TAG="armv7"; XRAY_ZIP="Xray-linux-arm32-v7a.zip";   CF_ASSET="cloudflared-linux-arm" ;;
        *) err "❌ 不支持的 CPU 架构: $m"; return 1 ;;
    esac
    return 0
}

fetch_file() {   # fetch_file <url> <out>  自动尝试 GitHub 加速镜像
    local url="$1" out="$2" prefix
    for prefix in "" "https://ghfast.top/" "https://gh-proxy.com/" "https://ghproxy.net/"; do
        rm -f "$out"
        if curl -fL --retry 2 --connect-timeout 10 -m 300 -o "$out" "${prefix}${url}" 2>/dev/null && [ -s "$out" ]; then
            return 0
        fi
    done
    rm -f "$out"
    return 1
}

latest_xray_version() {
    local v
    v=$(curl -sL -m 12 -o /dev/null -w '%{url_effective}' https://github.com/XTLS/Xray-core/releases/latest 2>/dev/null | grep -oE '[^/]+$')
    [ "$v" = "latest" ] && v=""
    if [ -z "$v" ]; then
        v=$(curl -sL -m 12 https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null | grep '"tag_name":' | head -n 1 | cut -d'"' -f4)
    fi
    [ -n "$v" ] && printf '%s' "$v"
}

xray_version() { [ -x "$XRAY_BIN" ] && "$XRAY_BIN" version 2>/dev/null | head -n 1 | awk '{print $2}' || printf '未安装'; }
cf_version()   { [ -x "$CF_BIN" ] && "$CF_BIN" --version 2>/dev/null | head -n 1 | awk '{print $3}' || printf '未安装'; }
xray_ver()     { local v; v=$(xray_version); case "$v" in 未安装|"") printf '未安装' ;; *) printf 'v%s' "$v" ;; esac; }

do_install_xray() {
    local force="$1" ver tmp
    if [ -x "$XRAY_BIN" ] && [ "$force" != "force" ]; then
        info "✔ Xray 内核已存在 (v$(xray_version))"
        return 0
    fi
    ver=$(latest_xray_version)
    [ -z "$ver" ] && { command -v "$XRAY_BIN" >/dev/null 2>&1 && return 0; err "❌ 无法获取 Xray 版本号, 请检查小鸡网络"; return 1; }
    tmp=$(mktemp -d /tmp/xrayargo.XXXXXX) || return 1
    info "⏳ 下载 Xray ${ver} (${ARCH_TAG}) ..."
    if ! fetch_file "https://github.com/XTLS/Xray-core/releases/download/${ver}/${XRAY_ZIP}" "$tmp/x.zip"; then
        rm -rf "$tmp"; err "❌ Xray 下载失败"; return 1
    fi
    if ! unzip -q -o "$tmp/x.zip" -d "$tmp" 2>/dev/null; then
        rm -rf "$tmp"; err "❌ Xray 压缩包解压失败"; return 1
    fi
    cp -f "$tmp/xray" "$XRAY_BIN" && chmod 755 "$XRAY_BIN"
    rm -rf "$tmp"
    ok "✔ Xray 内核就绪: v$(xray_version)"
}

do_install_cf() {
    local force="$1" tmp magic
    if [ -x "$CF_BIN" ] && [ "$force" != "force" ]; then
        info "✔ cloudflared 已存在 ($(cf_version))"
        return 0
    fi
    tmp=$(mktemp -d /tmp/cfargo.XXXXXX) || return 1
    info "⏳ 下载 cloudflared (${ARCH_TAG}) ..."
    if ! fetch_file "https://github.com/cloudflare/cloudflared/releases/latest/download/${CF_ASSET}" "$tmp/cf"; then
        rm -rf "$tmp"; err "❌ cloudflared 下载失败"; return 1
    fi
    magic=$(head -c 4 "$tmp/cf" 2>/dev/null | od -An -tx1 | tr -d ' \n')
    if [ "$magic" != "7f454c46" ]; then
        rm -rf "$tmp"; err "❌ 下载到的不是可执行 ELF 文件 (可能被网络劫持), 请重试"
        return 1
    fi
    cp -f "$tmp/cf" "$CF_BIN" && chmod 755 "$CF_BIN"
    rm -rf "$tmp"
    ok "✔ cloudflared 就绪: $(cf_version)"
}

# ------------------------------------------------------------
# 2. 服务管理 (Systemd / OpenRC)
# ------------------------------------------------------------
sysd() { command -v systemctl >/dev/null 2>&1; }

svc_start()   { if sysd; then systemctl start "$1" >/dev/null 2>&1; else rc-service "$1" start >/dev/null 2>&1; fi; }
svc_stop()    { if sysd; then systemctl stop "$1" >/dev/null 2>&1; else rc-service "$1" stop >/dev/null 2>&1; fi; }
svc_restart() { if sysd; then systemctl restart "$1" >/dev/null 2>&1; else rc-service "$1" restart >/dev/null 2>&1; fi; }
svc_running() {
    if sysd; then
        systemctl is-active --quiet "$1"
    else
        rc-service "$1" status 2>/dev/null | grep -q "started"
    fi
}

status_line() {
    local x="○ 停止" c="○ 停止"
    svc_running "$SVC_X" && x="● 运行"
    svc_running "$SVC_C" && c="● 运行"
    printf 'Xray: %s | 隧道: %s\n' "$x" "$c"
}

write_services() {
    if sysd; then
        cat > "/etc/systemd/system/${SVC_X}.service" << EOF_UNIT
[Unit]
Description=Xray core for Cloudflare tunnel
After=network.target

[Service]
Environment="GOGC=20"
Environment="GOMEMLIMIT=24MiB"
Environment="GODEBUG=madvdontneed=1"
ExecStart=${XRAY_BIN} run -c ${CONF_FILE}
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF_UNIT
        cat > "/etc/systemd/system/${SVC_C}.service" << EOF_UNIT
[Unit]
Description=Cloudflare tunnel (cloudflared) for Xray
After=network.target ${SVC_X}.service

[Service]
Environment="GOGC=20"
Environment="GOMEMLIMIT=24MiB"
Environment="GODEBUG=madvdontneed=1"
ExecStart=${RUN_SH}
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF_UNIT
        systemctl daemon-reload >/dev/null 2>&1
        systemctl enable "$SVC_X" >/dev/null 2>&1
        systemctl enable "$SVC_C" >/dev/null 2>&1
    elif command -v rc-update >/dev/null 2>&1; then
        cat > "/etc/init.d/${SVC_X}" << EOF_INIT
#!/sbin/openrc-run
name="xrayargo"
description="Xray core for Cloudflare tunnel"
command="${XRAY_BIN}"
command_args="run -c ${CONF_FILE}"
command_background="yes"
pidfile="/run/${SVC_X}.pid"
export GOGC=20
export GOMEMLIMIT=24MiB
export GODEBUG=madvdontneed=1
depend() {
    need net
    after firewall
}
EOF_INIT
        cat > "/etc/init.d/${SVC_C}" << EOF_INIT
#!/sbin/openrc-run
name="cfargo"
description="Cloudflare tunnel (cloudflared)"
command="${RUN_SH}"
command_background="yes"
pidfile="/run/${SVC_C}.pid"
export GOGC=20
export GOMEMLIMIT=24MiB
export GODEBUG=madvdontneed=1
depend() {
    need net
    after ${SVC_X} firewall
}
EOF_INIT
        chmod 755 "/etc/init.d/${SVC_X}" "/etc/init.d/${SVC_C}"
        rc-update add "$SVC_X" default >/dev/null 2>&1
        rc-update add "$SVC_C" default >/dev/null 2>&1
    else
        err "❌ 未检测到 systemd / openrc, 无法注册开机自启服务"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------
# 3. 参数 / 配置
# ------------------------------------------------------------
load_env() { [ -f "$ENV_FILE" ] && . "$ENV_FILE"; }

fill_defaults() {
    [ -n "$LPORT" ]       || LPORT=10000
    [ -n "$CF_MODE" ]     || CF_MODE="quick"
    [ -n "$CF_PROTOCOL" ] || CF_PROTOCOL="http2"
    [ -n "$CF_EDGE_IP" ]  || CF_EDGE_IP="auto"
    [ -n "$NODE_NAME" ]   || NODE_NAME="argo"
    [ -n "$WSPATH" ]      || WSPATH="/$(openssl rand -hex 8)"
    [ -n "$UUID" ]        || UUID=$("$XRAY_BIN" uuid 2>/dev/null)
}

save_env() {
    mkdir -p "$CONF_DIR"
    cat > "$ENV_FILE" << EOF_ENVF
UUID="$(env_quote "$UUID")"
WSPATH="$(env_quote "$WSPATH")"
LPORT="$(env_quote "$LPORT")"
CF_MODE="$(env_quote "$CF_MODE")"
CF_TOKEN="$(env_quote "$CF_TOKEN")"
CF_HOST="$(env_quote "$CF_HOST")"
CF_PROTOCOL="$(env_quote "$CF_PROTOCOL")"
CF_EDGE_IP="$(env_quote "$CF_EDGE_IP")"
NODE_NAME="$(env_quote "$NODE_NAME")"
EOF_ENVF
    chmod 600 "$ENV_FILE"
}

new_node_params() {
    UUID=$("$XRAY_BIN" uuid 2>/dev/null)
    [ -n "$UUID" ] || UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)
    WSPATH="/$(openssl rand -hex 8)"
    LPORT=10000
    CF_MODE="quick"
    CF_TOKEN=""
    CF_HOST=""
    CF_PROTOCOL="http2"
    CF_EDGE_IP="auto"
    NODE_NAME="argo"
}

render_config() {
    local p u
    p=$(json_escape "$WSPATH")
    u=$(json_escape "$UUID")
    cat > "$CONF_FILE" << EOF_JSON
{
  "log": {"loglevel": "warning", "access": "none"},
  "inbounds": [
    {
      "tag": "vless-argo",
      "listen": "127.0.0.1",
      "port": ${LPORT},
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "${u}", "email": "argo-user"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {"path": "${p}"},
        "sockopt": {"tcpFastOpen": true, "tcpKeepAliveInterval": 30}
      },
      "sniffing": {"enabled": false}
    }
  ],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "ip": ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
               "169.254.0.0/16", "::1/128", "fc00::/7"],
        "outboundTag": "block"
      }
    ]
  }
}
EOF_JSON
}

write_runner() {
    cat > "$RUN_SH" << EOF_RUN
#!/bin/sh
# cloudflared 启动包装 (由 argo 生成): 统一日志 + 低内存运行时参数
LOG="${CF_LOG}"
[ -f "\$LOG" ] && [ "\$(wc -c < "\$LOG" 2>/dev/null || echo 0)" -gt 2097152 ] && : > "\$LOG"
export GOGC="\${GOGC:-20}"
export GOMEMLIMIT="\${GOMEMLIMIT:-24MiB}"
export GODEBUG="\${GODEBUG:-madvdontneed=1}"
export HOME="\${HOME:-${CONF_DIR}}"
EOF_RUN
    if [ "$CF_MODE" = "token" ]; then
        cat >> "$RUN_SH" << EOF_RUN
exec "${CF_BIN}" tunnel --no-autoupdate --protocol ${CF_PROTOCOL} --edge-ip-version ${CF_EDGE_IP} run --token "${CF_TOKEN}" >> "\$LOG" 2>&1
EOF_RUN
    else
        cat >> "$RUN_SH" << EOF_RUN
exec "${CF_BIN}" tunnel --no-autoupdate --protocol ${CF_PROTOCOL} --edge-ip-version ${CF_EDGE_IP} --url "http://127.0.0.1:${LPORT}" >> "\$LOG" 2>&1
EOF_RUN
    fi
    chmod 700 "$RUN_SH"
}

apply_all() {   # 应用配置: 渲染 -> 服务 -> 重启 -> 刷新链接
    render_config
    write_runner
    write_services
    restart_all
    wait_host && update_links >/dev/null 2>&1
    return 0
}

restart_all() {
    warn "⏳ 正在重启 Xray 与隧道..."
    svc_stop "$SVC_C" >/dev/null 2>&1
    if [ "$CF_MODE" = "quick" ]; then : > "$CF_LOG" 2>/dev/null || true; fi
    svc_restart "$SVC_X"
    sleep 1
    svc_start "$SVC_C"
    sleep 1
}

# ------------------------------------------------------------
# 4. 隧道域名与节点链接
# ------------------------------------------------------------
get_tunnel_host() {
    [ -f "$CF_LOG" ] || return 1
    local h
    h=$(grep -oE 'https://[A-Za-z0-9-]+\.trycloudflare\.com' "$CF_LOG" 2>/dev/null \
        | sed 's#https://##' | grep -v '^api\.' | tail -n 1)
    [ -n "$h" ] && printf '%s' "$h"
}

current_host() {
    if [ "$CF_MODE" = "token" ]; then
        printf '%s' "$CF_HOST"
    else
        get_tunnel_host
    fi
}

wait_host() {
    local i=0
    if [ "$CF_MODE" = "token" ]; then
        [ -n "$CF_HOST" ] && return 0
        return 1
    fi
    while [ "$i" -lt 60 ]; do
        [ -n "$(get_tunnel_host)" ] && return 0
        i=$((i + 1))
        sleep 1
    done
    return 1
}

update_links() {
    local host p tag l443 l8443 l2053
    host=$(current_host)
    if [ -z "$host" ]; then
        err "❌ 尚未获取到隧道域名 (隧道可能还在连接/启动失败), 请稍后重试或查看日志"
        return 1
    fi
    p=$(path_encode "$WSPATH")
    tag="${NODE_NAME:-argo}"
    l443="vless://${UUID}@${host}:443?encryption=none&security=tls&sni=${host}&fp=chrome&type=ws&host=${host}&path=${p}&headerType=none#${tag}"
    l8443="vless://${UUID}@${host}:8443?encryption=none&security=tls&sni=${host}&fp=chrome&type=ws&host=${host}&path=${p}&headerType=none#${tag}-8443"
    l2053="vless://${UUID}@${host}:2053?encryption=none&security=tls&sni=${host}&fp=chrome&type=ws&host=${host}&path=${p}&headerType=none#${tag}-2053"

    {
        printf '==========================================================\n'
        printf ' 🎉 Xray + Cloudflare 隧道 节点信息\n'
        printf '==========================================================\n'
        if [ "$CF_MODE" = "token" ]; then
            printf ' 隧道模式 : token (固定域名)\n'
        else
            printf ' 隧道模式 : quick (临时域名, 每次重启都会变)\n'
        fi
        printf ' 隧道域名 : %s\n' "$host"
        printf ' UUID     : %s\n' "$UUID"
        printf ' WS 路径  : %s\n' "$WSPATH"
        printf ' 本地监听 : 127.0.0.1:%s\n' "$LPORT"
        printf '%s\n' '----------------------------------------------------------'
        printf '【节点链接 · 主端口 443】\n%s\n\n' "$l443"
        printf '【备用端口 8443 / 2053 (443 被封时用)】\n%s\n%s\n' "$l8443" "$l2053"
        printf '%s\n' '----------------------------------------------------------'
        printf '【Clash / Mihomo 片段】\n'
        cat << EOF_CLASH
proxies:
  - name: ${tag}
    type: vless
    server: ${host}
    port: 443
    uuid: ${UUID}
    udp: true
    tls: true
    servername: ${host}
    client-fingerprint: chrome
    network: ws
    ws-opts:
      path: ${WSPATH}
      headers:
        Host: ${host}
EOF_CLASH
        printf '==========================================================\n'
        printf ' 生成时间: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$LINK_FILE"
    chmod 600 "$LINK_FILE"
    return 0
}

# ------------------------------------------------------------
# 5. 网络调优 (内存自适应)
# ------------------------------------------------------------
tune_network() {
    local quiet="$1" m keys r_max w_max r_def w_def tcp_rmem tcp_wmem
    m=$(mem_total_mb); m=${m:-512}
    if [ "$m" -lt 160 ]; then
        r_max=16777216; w_max=16777216; r_def=262144; w_def=262144
        tcp_rmem="4096 131072 8388608"; tcp_wmem="4096 131072 8388608"
    else
        r_max=33554432; w_max=33554432; r_def=1048576; w_def=1048576
        tcp_rmem="4096 1048576 33554432"; tcp_wmem="4096 1048576 33554432"
    fi

    [ "$quiet" = "quiet" ] || echo "🚀 正在优化 TCP 缓冲区 / BBR ..."
    command -v sysctl >/dev/null 2>&1 || apk add --no-cache procps >/dev/null 2>&1 || true
    modprobe tcp_bbr 2>/dev/null || true

    keys="net.ipv4.tcp_window_scaling net.core.rmem_max net.core.wmem_max net.core.rmem_default net.core.wmem_default net.core.netdev_max_backlog net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_mtu_probing net.ipv4.tcp_notsent_lowat net.core.default_qdisc net.ipv4.tcp_congestion_control vm.swappiness"
    for k in $keys; do
        sed -i "/^${k}[[:space:]]*=/d" /etc/sysctl.conf 2>/dev/null
    done

    cat >> /etc/sysctl.conf << EOF_SYSCTL
net.ipv4.tcp_window_scaling = 1
net.core.rmem_max = ${r_max}
net.core.wmem_max = ${w_max}
net.core.rmem_default = ${r_def}
net.core.wmem_default = ${w_def}
net.core.netdev_max_backlog = 4096
net.ipv4.tcp_rmem = ${tcp_rmem}
net.ipv4.tcp_wmem = ${tcp_wmem}
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 16384
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
vm.swappiness = 60
EOF_SYSCTL

    sysctl -p >/dev/null 2>&1 || true
    if [ ! -w /proc/sys/net/ipv4/tcp_congestion_control ]; then
        warn "⚠️ 当前为容器/只读内核环境, 网络参数可能无法真正生效 (由母鸡接管)"
    elif [ "$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)" = "bbr" ]; then
        [ "$quiet" = "quiet" ] || ok "✔ 已启用 BBR + FQ, TCP 缓冲上限 $((r_max / 1024 / 1024))MB"
    else
        warn "⚠️ BBR 未生效, 可能需要更新内核 (Alpine: apk add linux-lts 后重启)"
    fi
}

# ------------------------------------------------------------
# 6. Swap 管理
# ------------------------------------------------------------
swap_on() {
    local mb="$1" rootfs
    if [ "$(swap_total_mb)" -gt 0 ]; then
        info "ℹ️ 当前已有 swap ($(swap_total_mb)MB), 跳过创建"
        return 0
    fi
    rootfs=$(stat -f -c %T / 2>/dev/null)
    case "$rootfs" in
        overlayfs|tmpfs)
            warn "⚠️ 根分区为 ${rootfs} (容器环境), 无法创建 swap 文件"
            return 1 ;;
    esac
    if ! command -v mkswap >/dev/null 2>&1; then
        apk add --no-cache util-linux >/dev/null 2>&1 || true
    fi
    command -v mkswap >/dev/null 2>&1 || { warn "⚠️ 缺少 mkswap 命令, 跳过 swap"; return 1; }
    info "⏳ 正在创建 ${mb}MB swap 文件 ($SWAP_FILE) ..."
    dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$mb" 2>/dev/null || { rm -f "$SWAP_FILE"; warn "⚠️ swap 文件创建失败 (磁盘空间不足?)"; return 1; }
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE" >/dev/null 2>&1 || { rm -f "$SWAP_FILE"; warn "⚠️ mkswap 失败, 当前文件系统可能不支持 swap 文件"; return 1; }
    swapon "$SWAP_FILE" 2>/dev/null || { rm -f "$SWAP_FILE"; warn "⚠️ swapon 失败 (容器通常禁止 swap)"; return 1; }
    grep -qF "$SWAP_FILE" /etc/fstab 2>/dev/null || echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
    sysctl -w vm.swappiness=60 >/dev/null 2>&1 || true
    ok "✔ swap 已启用: $(swap_total_mb)MB"
}

swap_off() {
    [ -f "$SWAP_FILE" ] || { info "ℹ️ 未发现脚本创建的 swap 文件"; return 0; }
    swapoff "$SWAP_FILE" >/dev/null 2>&1 || true
    sed -i "\|^${SWAP_FILE}[[:space:]]|d" /etc/fstab 2>/dev/null || true
    rm -f "$SWAP_FILE"
    ok "✔ 已关闭并删除 swap 文件"
}

auto_swap() {
    local m s
    m=$(mem_total_mb); s=$(swap_total_mb)
    if [ "${m:-999}" -lt 160 ] && [ "${s:-0}" -lt 64 ]; then
        warn "💡 内存仅 ${m}MB, 自动创建 256MB swap 以防止 OOM ..."
        swap_on 256 || warn "⚠️ 自动 swap 失败, 低内存下服务可能被杀, 建议手动加 swap"
    fi
}

# ------------------------------------------------------------
# 7. 安装流程
# ------------------------------------------------------------
do_install() {
    local keep="$1" ans
    check_root
    detect_arch || exit 1
    mkdir -p "$CONF_DIR" /var/log

    printf '==========================================\n'
    printf '   Xray + Cloudflare 隧道 部署 / 升级\n'
    printf '==========================================\n'
    mem_report

    do_install_xray || exit 1
    do_install_cf   || exit 1

    if [ -f "$ENV_FILE" ]; then
        load_env
        fill_defaults
        if [ "$keep" != "keep" ]; then
            printf '检测到已有配置: 路径 %s | 本地端口 %s | 模式 %s\n' "$WSPATH" "$LPORT" "$CF_MODE"
            read -p "是否保留现有节点参数 (UUID/路径/端口)? [Y/n]: " ans </dev/tty
            if printf '%s' "$ans" | grep -qE '^[nN]$'; then
                warn "已重新生成全部节点参数 (客户端需重新导入)"
                new_node_params
            fi
        fi
    else
        new_node_params
    fi
    fill_defaults
    save_env

    render_config
    if "$XRAY_BIN" run -test -c "$CONF_FILE" >/tmp/argo_test.log 2>&1; then
        info "✔ Xray 配置校验通过"
    else
        warn "⚠️ Xray 配置校验告警:"; cat /tmp/argo_test.log 2>/dev/null
    fi
    rm -f /tmp/argo_test.log

    write_runner
    write_services
    tune_network quiet
    auto_swap
    restart_all

    if wait_host; then
        update_links && printf '\n' && cat "$LINK_FILE"
    else
        warn "⏳ 60 秒内未获取到隧道域名, 稍后执行 argo 用菜单 3 刷新"
    fi

    printf '\n'
    ok "🎉 部署完成! 以后在终端输入 argo 即可打开管理后台"
}

# ------------------------------------------------------------
# 8. 菜单功能
# ------------------------------------------------------------
show_info() {
    clear
    update_links >/dev/null 2>&1 || true
    if [ -f "$LINK_FILE" ]; then cat "$LINK_FILE"; else err "未找到节点信息, 请先刷新隧道"; fi
    pause
}

refresh_links() {
    clear
    printf '==========================================\n'
    printf '        刷新隧道域名并输出节点链接\n'
    printf '==========================================\n'
    restart_all
    if wait_host && update_links; then
        printf '\n'; cat "$LINK_FILE"
    else
        err "❌ 获取隧道域名失败, 请用菜单 8 查看隧道日志"
    fi
    pause
}

restart_everything() {
    clear
    load_env; fill_defaults
    restart_all
    if wait_host && update_links; then
        ok "✔ 已重启, 新链接:"; printf '\n'; cat "$LINK_FILE"
    else
        warn "⏳ 隧道尚未就绪, 请稍后用菜单 3 刷新"
    fi
    pause
}

modify_params() {
    while true; do
        load_env; fill_defaults
        clear
        printf '==========================================\n'
        printf '            修改节点参数\n'
        printf '==========================================\n'
        printf ' 1. 修改 WS 路径 (当前: %s)\n' "$WSPATH"
        printf ' 2. 重新生成 UUID (当前: %s)\n' "$UUID"
        printf ' 3. 修改本地监听端口 (当前: %s)\n' "$LPORT"
        printf ' 4. 修改节点备注名 (当前: %s)\n' "$NODE_NAME"
        printf ' 5. 一键随机重置 (路径 + UUID)\n'
        printf ' 0. 返回主菜单\n'
        printf '==========================================\n'
        read -p '请输入选项 [0-5]: ' o </dev/tty
        case "$o" in
            1)
                read -p '请输入新的 WS 路径 (如 /abcdef): ' np </dev/tty
                case "$np" in
                    /?*) WSPATH="$np"; save_env; apply_all; ok "✔ 路径已更新"; pause; return ;;
                    *) err "路径必须以 / 开头"; sleep 1 ;;
                esac
                ;;
            2)
                UUID=$("$XRAY_BIN" uuid 2>/dev/null)
                [ -n "$UUID" ] || UUID=$(cat /proc/sys/kernel/random/uuid)
                save_env; apply_all; ok "✔ UUID 已更新, 新链接:"; printf '\n'; cat "$LINK_FILE" 2>/dev/null; pause; return
                ;;
            3)
                read -p '请输入本地监听端口 [1024-65535]: ' npt </dev/tty
                if printf '%s' "$npt" | grep -qE '^[0-9]+$' && [ "$npt" -ge 1024 ] && [ "$npt" -le 65535 ]; then
                    LPORT="$npt"; save_env; apply_all; ok "✔ 本地端口已更新为 $LPORT"; pause; return
                else
                    err "端口不合法"; sleep 1
                fi
                ;;
            4)
                read -p '请输入节点备注名: ' nn </dev/tty
                [ -n "$nn" ] && { NODE_NAME="$nn"; save_env; update_links >/dev/null 2>&1; ok "✔ 备注名已更新"; pause; return; }
                ;;
            5)
                WSPATH="/$(openssl rand -hex 8)"
                UUID=$("$XRAY_BIN" uuid 2>/dev/null)
                [ -n "$UUID" ] || UUID=$(cat /proc/sys/kernel/random/uuid)
                save_env; apply_all; ok "✔ 已随机重置, 新链接:"; printf '\n'; cat "$LINK_FILE" 2>/dev/null; pause; return
                ;;
            0) return ;;
            *) err "无效输入"; sleep 1 ;;
        esac
    done
}

tunnel_settings() {
    while true; do
        load_env; fill_defaults
        clear
        printf '==========================================\n'
        printf '              隧道设置\n'
        printf '==========================================\n'
        printf ' 当前模式 : %s\n' "$CF_MODE"
        [ "$CF_MODE" = "token" ] && printf ' 隧道域名 : %s\n' "$CF_HOST"
        printf ' 传输协议 : %s\n' "$CF_PROTOCOL"
        printf ' 边缘 IP  : %s\n' "$CF_EDGE_IP"
        printf '%s\n' '------------------------------------------'
        printf ' 1. 切换传输协议 (http2 / quic)\n'
        printf ' 2. 切换边缘 IP 版本 (auto / 4 / 6)\n'
        printf ' 3. 使用 Cloudflare Token 固定域名隧道\n'
        printf ' 4. 恢复为临时隧道 (trycloudflare)\n'
        printf ' 0. 返回主菜单\n'
        printf '==========================================\n'
        read -p '请输入选项 [0-4]: ' o </dev/tty
        case "$o" in
            1)
                if [ "$CF_PROTOCOL" = "http2" ]; then CF_PROTOCOL="quic"; else CF_PROTOCOL="http2"; fi
                save_env; apply_all; ok "✔ 传输协议已切换为 $CF_PROTOCOL"
                wait_host && update_links >/dev/null 2>&1
                pause; return
                ;;
            2)
                case "$CF_EDGE_IP" in
                    auto) CF_EDGE_IP=4 ;;
                    4)    CF_EDGE_IP=6 ;;
                    *)    CF_EDGE_IP=auto ;;
                esac
                save_env; apply_all; ok "✔ 边缘 IP 版本已切换为 $CF_EDGE_IP"
                wait_host && update_links >/dev/null 2>&1
                pause; return
                ;;
            3)
                printf '\n请在 Cloudflare Zero Trust -> Networks -> Tunnels 新建隧道并复制 Token。\n'
                printf '然后在隧道 Public Hostname 中添加: 子域名 + 域名 -> 服务 http://127.0.0.1:%s\n\n' "$LPORT"
                read -p 'Token: ' tk </dev/tty
                read -p '该隧道对应的完整域名 (如 a.example.com): ' hm </dev/tty
                if [ -z "$tk" ] || [ -z "$hm" ]; then err "Token 与域名不能为空"; sleep 1; continue; fi
                CF_TOKEN="$tk"; CF_HOST="$hm"; CF_MODE="token"
                save_env; apply_all
                if wait_host; then
                    update_links && printf '\n' && cat "$LINK_FILE"
                else
                    warn "⚠️ 已切换为 token 模式, 若 30 秒内无连接请用菜单 8 查看日志"
                fi
                pause; return
                ;;
            4)
                CF_MODE="quick"; CF_TOKEN=""; CF_HOST=""
                save_env; apply_all
                wait_host && update_links && printf '\n' && cat "$LINK_FILE"
                pause; return
                ;;
            0) return ;;
            *) err "无效输入"; sleep 1 ;;
        esac
    done
}

manage_network() {
    clear
    printf '==========================================\n'
    printf '        网络内核调优 (BBR / TCP)\n'
    printf '==========================================\n'
    printf ' 拥塞控制 : %s\n' "$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)"
    printf ' 队列算法 : %s\n' "$(cat /proc/sys/net/core/default_qdisc 2>/dev/null)"
    printf ' 读取上限 : %s MB\n' "$(( $(cat /proc/sys/net/core/rmem_max 2>/dev/null || echo 0) / 1024 / 1024 ))"
    printf ' 内存     : %s MB | Swap: %s MB\n' "$(mem_total_mb)" "$(swap_total_mb)"
    printf '%s\n' '------------------------------------------'
    read -p '是否重新应用网络优化参数? [Y/n]: ' a </dev/tty
    if ! printf '%s' "$a" | grep -qE '^[nN]$'; then
        tune_network
        ok "✔ 已完成"
    fi
    pause
}

manage_swap() {
    while true; do
        clear
        printf '==========================================\n'
        printf '              Swap 管理\n'
        printf '==========================================\n'
        printf ' 当前内存: %s MB | 当前 Swap: %s MB\n' "$(mem_total_mb)" "$(swap_total_mb)"
        printf '%s\n' '------------------------------------------'
        printf ' 1. 创建 256MB swap\n'
        printf ' 2. 自定义大小创建 swap\n'
        printf ' 3. 关闭并删除脚本创建的 swap\n'
        printf ' 0. 返回主菜单\n'
        printf '==========================================\n'
        read -p '请输入选项 [0-3]: ' o </dev/tty
        case "$o" in
            1) swap_on 256; pause; return ;;
            2)
                read -p '请输入大小 (MB, 128-2048): ' mb </dev/tty
                if printf '%s' "$mb" | grep -qE '^[0-9]+$' && [ "$mb" -ge 64 ] && [ "$mb" -le 2048 ]; then
                    swap_on "$mb"; pause; return
                else
                    err "数值不合法"; sleep 1
                fi
                ;;
            3) swap_off; pause; return ;;
            0) return ;;
            *) err "无效输入"; sleep 1 ;;
        esac
    done
}

manage_logs() {
    while true; do
        clear
        printf '==========================================\n'
        printf '                查看日志\n'
        printf '==========================================\n'
        printf ' 1. 隧道日志 (最近 40 行, 含临时域名)\n'
        printf ' 2. 实时跟踪隧道日志 (Ctrl+C 退出)\n'
        printf ' 3. Xray 日志\n'
        printf ' 0. 返回主菜单\n'
        printf '==========================================\n'
        read -p '请输入选项 [0-3]: ' o </dev/tty
        case "$o" in
            1) [ -f "$CF_LOG" ] && tail -n 40 "$CF_LOG" || err "无日志文件 $CF_LOG"; pause; return ;;
            2)
                printf '按 Ctrl+C 退出实时日志\n'
                sleep 1
                tail -f "$CF_LOG" </dev/tty
                return
                ;;
            3)
                if sysd; then
                    journalctl -u "$SVC_X" -n 40 --no-pager 2>/dev/null | tail -n 40
                else
                    tail -n 40 /var/log/messages 2>/dev/null | grep -i xray
                    [ -f /var/log/xrayargo.log ] && tail -n 40 /var/log/xrayargo.log
                fi
                pause; return
                ;;
            0) return ;;
            *) err "无效输入"; sleep 1 ;;
        esac
    done
}

update_core() {
    clear
    printf '==========================================\n'
    printf '           升级 Xray 内核\n'
    printf '==========================================\n'
    local cur latest
    cur=$(xray_version)
    latest=$(latest_xray_version)
    printf ' 当前版本: %s\n' "$(xray_ver)"
    if [ -z "$latest" ]; then err "❌ 无法获取最新版本"; pause; return 1; fi
    printf ' 最新版本: %s\n' "$latest"
    read -p '是否升级? [Y/n]: ' a </dev/tty
    printf '%s' "$a" | grep -qE '^[nN]$' && return 0
    do_install_xray force || { pause; return 1; }
    svc_restart "$SVC_X"
    ok "✔ 内核已更新并通过服务重启生效"
    pause
}

update_cf() {
    clear
    printf '==========================================\n'
    printf '         升级 cloudflared\n'
    printf '==========================================\n'
    printf ' 当前版本: %s\n' "$(cf_version)"
    read -p '是否下载并覆盖最新版? [Y/n]: ' a </dev/tty
    printf '%s' "$a" | grep -qE '^[nN]$' && return 0
    do_install_cf force || { pause; return 1; }
    restart_all
    wait_host && update_links >/dev/null 2>&1
    ok "✔ cloudflared 已更新 (临时域名已刷新, 请用菜单 1 查看新链接)"
    pause
}

update_script() {
    clear
    printf '==========================================\n'
    printf '           升级管理脚本\n'
    printf '==========================================\n'
    printf ' 当前版本: v%s\n' "$SCRIPT_VERSION"
    local remote tmp
    tmp=/tmp/argo_new.sh
    if ! curl -fsSL -m 30 "$SCRIPT_URL" -o "$tmp" 2>/dev/null; then
        err "❌ 下载脚本失败, 请检查网络"; pause; return 1
    fi
    remote=$(grep -m 1 '^SCRIPT_VERSION=' "$tmp" | cut -d'"' -f2)
    printf ' 远程版本: v%s\n' "${remote:-未知}"
    if [ "$remote" = "$SCRIPT_VERSION" ]; then
        printf 'ℹ️ 已是最新版本\n'
        read -p '是否强制重新安装 (重写后台命令)? [y/N]: ' a </dev/tty
        printf '%s' "$a" | grep -qE '^[yY]$' || { rm -f "$tmp"; return 0; }
    fi
    if ! grep -q 'ARGO_CLI_EOF' "$tmp"; then
        err "❌ 脚本内容校验失败, 已取消"; rm -f "$tmp"; pause; return 1
    fi
    chmod 755 "$tmp"
    printf '⏳ 正在应用升级 (会重写管理后台并重启服务)...\n'
    exec bash "$tmp" --upgrade
}

update_menu() {
    while true; do
        clear
        printf '==========================================\n'
        printf '              检查与升级\n'
        printf '==========================================\n'
        printf ' 脚本: v%s | Xray: %s | cloudflared: %s\n' "$SCRIPT_VERSION" "$(xray_ver)" "$(cf_version)"
        printf '%s\n' '------------------------------------------'
        printf ' 1. 升级 Xray 内核\n'
        printf ' 2. 升级 cloudflared\n'
        printf ' 3. 升级管理脚本\n'
        printf ' 0. 返回主菜单\n'
        printf '==========================================\n'
        read -p '请输入选项 [0-3]: ' o </dev/tty
        case "$o" in
            1) update_core ;;
            2) update_cf ;;
            3) update_script ;;
            0) return ;;
            *) err "无效输入"; sleep 1 ;;
        esac
    done
}

uninstall_all() {
    clear
    printf '==========================================\n'
    printf '              彻底卸载\n'
    printf '==========================================\n'
    read -p '⚠️ 确定卸载 Xray + 隧道 及其全部配置? [y/N]: ' a </dev/tty
    printf '%s' "$a" | grep -qE '^[yY]$' || { printf '已取消\n'; sleep 1; return; }

    if sysd; then
        svc_stop "$SVC_C"; svc_stop "$SVC_X"
        systemctl disable "$SVC_C" >/dev/null 2>&1
        systemctl disable "$SVC_X" >/dev/null 2>&1
        rm -f "/etc/systemd/system/${SVC_C}.service" "/etc/systemd/system/${SVC_X}.service"
        systemctl daemon-reload >/dev/null 2>&1
    elif command -v rc-update >/dev/null 2>&1; then
        svc_stop "$SVC_C"; svc_stop "$SVC_X"
        rc-update del "$SVC_C" default >/dev/null 2>&1
        rc-update del "$SVC_X" default >/dev/null 2>&1
        rm -f "/etc/init.d/${SVC_C}" "/etc/init.d/${SVC_X}"
    fi

    rm -f "$XRAY_BIN" "$CF_BIN" "$RUN_SH" "$CLI_PATH" "$CF_LOG"
    rm -rf "$CONF_DIR"
    read -p '是否同时删除脚本创建的 swap 文件? [y/N]: ' b </dev/tty
    printf '%s' "$b" | grep -qE '^[yY]$' && swap_off
    ok "🎉 卸载完成"
    exit 0
}

# ------------------------------------------------------------
# 9. 主菜单
# ------------------------------------------------------------
main_menu() {
    while true; do
        load_env 2>/dev/null
        fill_defaults 2>/dev/null
        clear
        local host
        host=$(current_host 2>/dev/null)

        printf '==========================================\n'
        printf '     Xray + Cloudflare 隧道 管理后台\n'
        printf '==========================================\n'
        printf ' 脚本: v%s | Xray: %s | cf: %s\n' "$SCRIPT_VERSION" "$(xray_ver)" "$(cf_version)"
        printf ' 状态: %s\n' "$(status_line)"
        printf ' 模式: %s | 协议: %s\n' "$CF_MODE" "$CF_PROTOCOL"
        if [ -n "$host" ]; then
            printf ' 域名: %s\n' "$host"
        else
            printf ' 域名: (尚未获取, 请选择 3 刷新)\n'
        fi
        printf '%s\n' '------------------------------------------'
        printf '  1. 查看节点链接 / 当前隧道域名\n'
        printf '  2. 重启全部服务\n'
        printf '  3. 刷新隧道域名并输出新链接\n'
        printf '  4. 修改节点参数 (路径/UUID/端口/备注)\n'
        printf '  5. 隧道设置 (协议/边缘IP/固定域名Token)\n'
        printf '  6. 网络内核调优 (BBR / TCP)\n'
        printf '  7. 管理 Swap\n'
        printf '  8. 查看日志\n'
        printf '  9. 检查与升级\n'
        printf ' 10. 彻底卸载\n'
        printf '  0. 退出\n'
        printf '==========================================\n'
        read -p '请输入选项 [0-10]: ' c </dev/tty
        case "$c" in
            1) show_info ;;
            2) restart_everything ;;
            3) refresh_links ;;
            4) modify_params ;;
            5) tunnel_settings ;;
            6) manage_network ;;
            7) manage_swap ;;
            8) manage_logs ;;
            9) update_menu ;;
            10) uninstall_all ;;
            0) clear; exit 0 ;;
            *) err "无效输入"; sleep 1 ;;
        esac
    done
}

usage() {
    printf 'argo — Xray + Cloudflare 隧道 管理后台 (v%s)\n\n' "$SCRIPT_VERSION"
    printf '用法:\n'
    printf '  argo                 打开交互式管理菜单\n'
    printf '  argo --install [keep] 部署/升级服务 (keep = 保留现有参数)\n'
    printf '  argo --link          直接输出当前节点链接\n'
}

case "${1:-}" in
    --install) shift; do_install "$@" ;;
    --link)    load_env 2>/dev/null; fill_defaults 2>/dev/null; update_links && cat "$LINK_FILE" || exit 1 ;;
    --help|-h) usage ;;
    *)         check_root; main_menu ;;
esac
ARGO_CLI_EOF
    chmod 755 "$CLI_PATH"
}

install_dependencies
write_cli

case "${1:-}" in
    --upgrade)
        echo "🔄 正在升级管理后台并保留现有节点参数..."
        exec bash "$CLI_PATH" --install keep
        ;;
    *)
        exec bash "$CLI_PATH" --install
        ;;
esac
