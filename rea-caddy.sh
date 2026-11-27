#!/bin/bash
# ==============================================================================
# VLESS-Reality + Caddy 一体化直连版 (Debian/Ubuntu + x86_64 + 纯IPv4单栈)
# 特性：
# 1. 公网 443 由 Xray (REALITY) 接管，非代理流量透明回落至本机 127.0.0.1:8443 (Caddy)
# 2. 自动检查并安装 Caddy，保留 80 端口用于 Let's Encrypt 证书申请与自动续签
# 3. 支持交互式配置与后续菜单修改：域名、访问暗号(secret)、API Key 前缀、反代端口
# 4. 深度网络内核调优 (32MB TCP 动态缓冲区 + BBR + FQ) + 低内存 (<=256MB) 防 OOM 调优
# 5. Xray 内核、Caddy 与管理脚本在线独立检查升级
# ==============================================================================

SCRIPT_VERSION="1.0.1"
SCRIPT_URL="https://github.com/justly110/xray/raw/main/rea-caddy.sh"

ENV_FILE="/usr/local/etc/xray/params.env"
CONFIG_FILE="/usr/local/etc/xray/config.json"
LINK_FILE="/usr/local/etc/xray/link.txt"
EXTRA_NODES_FILE="/usr/local/etc/xray/extra_nodes.env"
XRAY_BIN="/usr/local/bin/xray-core"
CADDY_FILE="/etc/caddy/Caddyfile"

if [ "$(id -u)" != "0" ]; then
    echo "❌ 错误：请使用 root 权限运行本脚本"
    exit 1
fi

check_system() {
    local arch
    arch=$(uname -m)
    if [ "$arch" != "x86_64" ] && [ "$arch" != "amd64" ]; then
        echo "❌ 错误：本脚本仅支持 x86_64 架构，当前架构为: $arch"
        exit 1
    fi
    if [ ! -f /etc/debian_version ] || ! command -v apt-get >/dev/null 2>&1 || ! command -v systemctl >/dev/null 2>&1; then
        echo "❌ 错误：本脚本仅支持 Debian / Ubuntu (systemd) 系统"
        exit 1
    fi
}

check_system

# ------------------------------------------------------------------------------
# 1. 辅助工具与环境保存
# ------------------------------------------------------------------------------
json_escape() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/ }
    s=${s//$'\r'/ }
    s=${s//$'\t'/ }
    printf '%s' "$s"
}

env_quote() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//\$/\\\$}
    s=${s//\`/\\\`}
    s=${s//$'\n'/ }
    printf '%s' "$s"
}

sanitize_domain() {
    local d="$1"
    d="${d#http://}"
    d="${d#https://}"
    d="${d%%/*}"
    d="${d%%:*}"
    d="${d//[[:space:]]/}"
    printf '%s' "$d"
}

validate_domain() {
    local d="$1"
    [ -n "$d" ] || return 1
    [[ "$d" != *..* ]] || return 1
    [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]
}

validate_safe_token() {
    local t="$1"
    [ -n "$t" ] || return 1
    if [[ "$t" =~ [[:space:]\"\'\;] ]]; then
        return 1
    fi
    return 0
}

optimize_network() {
    echo "====================================="
    echo "🚀 正在调优系统 TCP 缓冲区与网络参数..."
    echo "====================================="
    modprobe tcp_bbr 2>/dev/null || true

    local params=(
        "net.ipv4.tcp_window_scaling"
        "net.core.rmem_max"
        "net.core.wmem_max"
        "net.core.rmem_default"
        "net.core.wmem_default"
        "net.core.netdev_max_backlog"
        "net.ipv4.tcp_rmem"
        "net.ipv4.tcp_wmem"
        "net.ipv4.tcp_slow_start_after_idle"
        "net.ipv4.tcp_mtu_probing"
        "net.ipv4.tcp_notsent_lowat"
        "net.core.default_qdisc"
        "net.ipv4.tcp_congestion_control"
    )
    for p in "${params[@]}"; do
        sed -i "/^${p}[[:space:]]*=/d" /etc/sysctl.conf 2>/dev/null
    done

    cat >> /etc/sysctl.conf << 'EOF'
net.ipv4.tcp_window_scaling = 1
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.netdev_max_backlog = 10000
net.ipv4.tcp_rmem = 4096 1048576 33554432
net.ipv4.tcp_wmem = 4096 1048576 33554432
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 16384
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl -p >/dev/null 2>&1 || true
    echo "✔ 网络参数优化完成！"
}

is_config_complete() {
    [ -f "$ENV_FILE" ] || return 1
    local PORT DEST_SNI UUID_DIRECT PUBLIC_KEY PRIVATE_KEY SHORT_ID
    local CADDY_DOMAIN CADDY_EMAIL CADDY_SECRET CADDY_COOKIE CADDY_KEY_PREFIX BACKEND_PORT CADDY_HTTPS_PORT
    eval "$(grep -E '^(PORT|DEST_SNI|UUID_DIRECT|PUBLIC_KEY|PRIVATE_KEY|SHORT_ID|CADDY_DOMAIN|CADDY_EMAIL|CADDY_SECRET|CADDY_COOKIE|CADDY_KEY_PREFIX|BACKEND_PORT|CADDY_HTTPS_PORT)=' "$ENV_FILE" 2>/dev/null)"
    [ -n "$PORT" ] && \
    [ -n "$DEST_SNI" ] && \
    [ -n "$UUID_DIRECT" ] && \
    [ -n "$PUBLIC_KEY" ] && \
    [ -n "$PRIVATE_KEY" ] && \
    [ -n "$SHORT_ID" ] && \
    [ -n "$CADDY_DOMAIN" ] && \
    [ -n "$CADDY_EMAIL" ] && \
    [ -n "$CADDY_SECRET" ] && \
    [ -n "$CADDY_COOKIE" ] && \
    [ -n "$CADDY_KEY_PREFIX" ] && \
    [ -n "$BACKEND_PORT" ] && \
    [ -n "$CADDY_HTTPS_PORT" ]
}

save_params_env() {
    {
        echo "PORT=\"$(env_quote "$PORT")\""
        echo "DEST_SNI=\"$(env_quote "$DEST_SNI")\""
        echo "UUID_DIRECT=\"$(env_quote "$UUID_DIRECT")\""
        echo "PUBLIC_KEY=\"$(env_quote "$PUBLIC_KEY")\""
        echo "PRIVATE_KEY=\"$(env_quote "$PRIVATE_KEY")\""
        echo "SHORT_ID=\"$(env_quote "$SHORT_ID")\""
        echo "CADDY_DOMAIN=\"$(env_quote "$CADDY_DOMAIN")\""
        echo "CADDY_EMAIL=\"$(env_quote "$CADDY_EMAIL")\""
        echo "CADDY_SECRET=\"$(env_quote "$CADDY_SECRET")\""
        echo "CADDY_COOKIE=\"$(env_quote "$CADDY_COOKIE")\""
        echo "CADDY_KEY_PREFIX=\"$(env_quote "$CADDY_KEY_PREFIX")\""
        echo "BACKEND_PORT=\"$(env_quote "$BACKEND_PORT")\""
        echo "CADDY_HTTPS_PORT=\"$(env_quote "$CADDY_HTTPS_PORT")\""
        echo "LOCAL_LOOPBACK_ENABLED=\"$(env_quote "${LOCAL_LOOPBACK_ENABLED:-0}")\""
        echo "LOCAL_LOOPBACK_DOMAIN=\"$(env_quote "${LOCAL_LOOPBACK_DOMAIN:-}")\""
    } > "$ENV_FILE"
}

install_dependencies() {
    echo "====================================="
    echo "📦 正在检查并安装基础依赖组件..."
    echo "====================================="
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        curl openssl bash unzip cron ca-certificates gnupg \
        debian-keyring debian-archive-keyring apt-transport-https
    mkdir -p /usr/local/bin /usr/local/etc/xray /root/xray_temp /etc/caddy
}

install_caddy() {
    echo "====================================="
    echo "🌐 正在检查/安装 Caddy..."
    echo "====================================="
    if command -v caddy >/dev/null 2>&1; then
        echo "✔ 检测到已安装 Caddy ($(caddy version 2>/dev/null | head -n 1))"
        systemctl enable caddy >/dev/null 2>&1 || true
        return 0
    fi

    echo "未检测到 Caddy，正在通过官方源安装..."
    curl -1fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1fsSL 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.tar.txt' | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
    chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list 2>/dev/null || true
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y caddy

    if ! command -v caddy >/dev/null 2>&1; then
        echo "❌ Caddy 安装失败，请检查网络或软件源！"
        exit 1
    fi
    systemctl enable caddy >/dev/null 2>&1 || true
    echo "✔ Caddy 安装完成！($(caddy version 2>/dev/null | head -n 1))"
}

install_xray_core() {
    echo "====================================="
    echo "⬇️ 正在检查/部署 Xray 核心程序 (x86_64)..."
    echo "====================================="
    local ZIP_NAME="Xray-linux-64.zip"

    local VERSION=$(curl -sL -m 8 -o /dev/null -w %{url_effective} https://github.com/XTLS/Xray-core/releases/latest | grep -oE '[^/]+$')
    if [ -z "$VERSION" ] || [ "$VERSION" = "latest" ]; then
        VERSION=$(curl -sL -m 8 https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null | grep '"tag_name":' | head -n 1 | cut -d '"' -f 4)
    fi
    if [ -z "$VERSION" ] || [ "$VERSION" = "latest" ]; then
        if [ -f "$XRAY_BIN" ]; then
            echo "⚠️ 无法获取 GitHub 最新版本，保留现有内核继续运行。"
            return 0
        fi
        echo "❌ 无法获取 Xray 最新版本号，请检查网络！"
        exit 1
    fi

    echo "正在拉取 Xray 官方发布版 (${VERSION}) ..."
    curl -sL -o /root/xray_temp/xray.zip "https://github.com/XTLS/Xray-core/releases/download/${VERSION}/${ZIP_NAME}"
    unzip -q -o /root/xray_temp/xray.zip -d /root/xray_temp/
    mv -f /root/xray_temp/xray "$XRAY_BIN"
    rm -rf /root/xray_temp
    chmod +x "$XRAY_BIN"
    echo "✔ Xray 核心程序就绪！"
}

render_caddyfile() {
    if [ -f "$CADDY_FILE" ] && [ ! -f "${CADDY_FILE}.rea_caddy_managed" ]; then
        cp "$CADDY_FILE" "${CADDY_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    fi

    cat > "$CADDY_FILE" << EOF
{
    https_port ${CADDY_HTTPS_PORT}
    auto_https disable_redirects
}

# 保留 80 端口：用于 Let's Encrypt 证书自动申请/续签，并跳转至公网 443
http://${CADDY_DOMAIN} {
    redir https://{host}{uri} permanent
}

# 仅监听本机 127.0.0.1:${CADDY_HTTPS_PORT}，由 Xray (REALITY) 转发进来
https://${CADDY_DOMAIN} {
    bind 127.0.0.1
    tls ${CADDY_EMAIL}

    @is_secret query secret=${CADDY_SECRET}
    @has_cookie header Cookie "*admin_auth=${CADDY_COOKIE}*"
    @has_auth1 header Authorization "Bearer ${CADDY_KEY_PREFIX}*"
    @has_auth2 header x-api-key "${CADDY_KEY_PREFIX}*"
    @has_auth3 header x-goog-api-key "${CADDY_KEY_PREFIX}*"

    handle @is_secret {
        header +Set-Cookie "admin_auth=${CADDY_COOKIE}; Path=/; Max-Age=2592000; HttpOnly; Secure; SameSite=Lax"
        rewrite * /
        reverse_proxy 127.0.0.1:${BACKEND_PORT} {
            flush_interval -1
        }
    }

    handle @has_cookie {
        reverse_proxy 127.0.0.1:${BACKEND_PORT} {
            flush_interval -1
        }
    }

    handle @has_auth1 {
        reverse_proxy 127.0.0.1:${BACKEND_PORT} {
            flush_interval -1
        }
    }

    handle @has_auth2 {
        reverse_proxy 127.0.0.1:${BACKEND_PORT} {
            flush_interval -1
        }
    }

    handle @has_auth3 {
        reverse_proxy 127.0.0.1:${BACKEND_PORT} {
            flush_interval -1
        }
    }

    handle {
        respond "Not Found" 404
    }
}
EOF
    touch "${CADDY_FILE}.rea_caddy_managed"
    caddy fmt --overwrite "$CADDY_FILE" >/dev/null 2>&1 || true
    if ! caddy validate --config "$CADDY_FILE" >/dev/null 2>&1; then
        echo "❌ Caddyfile 语法校验失败，请检查配置！"
        caddy validate --config "$CADDY_FILE"
        return 1
    fi
    systemctl restart caddy
    return 0
}

wait_caddy_tls_ready() {
    echo "⏳ 正在等待 Caddy 申请/加载 [${CADDY_DOMAIN}] 的 TLS 1.3 证书..."
    local i=0
    while [ $i -lt 12 ]; do
        local tls_out
        tls_out=$(timeout 3 openssl s_client -connect "127.0.0.1:${CADDY_HTTPS_PORT}" -servername "${CADDY_DOMAIN}" -tls1_3 </dev/null 2>&1)
        if echo "$tls_out" | grep -qE "(Protocol.*TLSv1\.3|New, *TLSv1\.3)"; then
            echo "✔ Caddy 本地 TLS 1.3 握手就绪！(127.0.0.1:${CADDY_HTTPS_PORT})"
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    echo -e "\033[33m⚠️ 提示：Caddy 暂未完成证书签发（可能是域名尚未解析到本机或 80 端口未放行）。\033[0m"
    echo -e "   程序会继续启动，待域名解析生效且 80 端口连通后 Caddy 会自动完成签发。"
    return 0
}

build_inbounds_json() {
    local port="$1"
    local sni="$2"
    local u_direct="$3"
    local priv="$4"
    local sid="$5"
    local caddy_port="$6"

    sni=$(json_escape "$sni")
    u_direct=$(json_escape "$u_direct")
    priv=$(json_escape "$priv")
    sid=$(json_escape "$sid")

    cat << EOF
[
  {
    "tag": "vless-v4",
    "listen": "0.0.0.0",
    "port": $port,
    "protocol": "vless",
    "settings": {
      "clients": [
        {"id": "$u_direct", "flow": "xtls-rprx-vision", "email": "direct-local"}
      ],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "dest": "127.0.0.1:$caddy_port",
        "serverNames": ["$sni"],
        "privateKey": "$priv",
        "shortIds": ["$sid"]
      },
      "sockopt": {
        "tcpFastOpen": true,
        "tcpKeepAliveInterval": 15
      }
    },
    "sniffing": {"enabled": false}
  }
EOF

    if [ -f "$EXTRA_NODES_FILE" ]; then
        while IFS='|' read -r e_port e_uuid e_sid e_sni e_tag; do
            [ -z "$e_port" ] && continue
            e_uuid=$(json_escape "$e_uuid")
            e_sid=$(json_escape "$e_sid")
            e_sni=$(json_escape "$e_sni")
            cat << EOF
  ,
  {
    "tag": "reality-in-$e_port",
    "listen": "0.0.0.0",
    "port": $e_port,
    "protocol": "vless",
    "settings": {
      "clients": [
        {"id": "$e_uuid", "flow": "xtls-rprx-vision", "email": "user-$e_port"}
      ],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "dest": "$e_sni:443",
        "serverNames": ["$e_sni"],
        "privateKey": "$priv",
        "shortIds": ["$sid"]
      },
      "sockopt": {
        "tcpFastOpen": true,
        "tcpKeepAliveInterval": 15
      }
    },
    "sniffing": {"enabled": false}
  }
EOF
        done < "$EXTRA_NODES_FILE"
    fi

    echo "]"
}

write_config_json_body() {
    local use_final_rules="${1:-1}"
    local lb_domain=""
    if [ "${LOCAL_LOOPBACK_ENABLED:-0}" = "1" ] && validate_domain "${LOCAL_LOOPBACK_DOMAIN:-}"; then
        lb_domain=$(json_escape "$LOCAL_LOOPBACK_DOMAIN")
    fi

    {
        echo "{"
        echo '  "log": {"loglevel": "warning"},'
        echo "  \"inbounds\": $(build_inbounds_json "$PORT" "$DEST_SNI" "$UUID_DIRECT" "$PRIVATE_KEY" "$SHORT_ID" "$CADDY_HTTPS_PORT"),"
        echo '  "outbounds": ['
        if [ -n "$lb_domain" ]; then
            echo '    {"protocol": "freedom", "tag": "direct"},'
            echo '    {'
            echo '      "protocol": "freedom",'
            echo '      "tag": "local-vps",'
            echo '      "settings": {'
            if [ "$use_final_rules" = "1" ]; then
                echo '        "redirect": "127.0.0.1:0",'
                echo '        "finalRules": ['
                echo '          {'
                echo '            "action": "allow",'
                echo '            "network": "tcp,udp",'
                echo '            "ip": ["127.0.0.1/32"]'
                echo '          }'
                echo '        ]'
            else
                echo '        "redirect": "127.0.0.1:0"'
            fi
            echo '      }'
            echo '    }'
        else
            echo '    {"protocol": "freedom", "tag": "direct"}'
        fi
        echo '  ],'
        echo '  "routing": {'
        echo '    "rules": ['
        if [ -n "$lb_domain" ]; then
            echo '      {'
            echo '        "type": "field",'
            echo "        \"domain\": [\"domain:${lb_domain}\"],"
            echo '        "outboundTag": "local-vps"'
            echo '      },'
        fi
        echo '      {'
        echo '        "type": "field",'
        echo '        "network": "tcp,udp",'
        echo '        "outboundTag": "direct"'
        echo '      }'
        echo '    ]'
        echo '  }'
        echo "}"
    } > "$CONFIG_FILE"
}

render_config_json() {
    write_config_json_body 1
    if [ "${LOCAL_LOOPBACK_ENABLED:-0}" = "1" ] && [ -x "$XRAY_BIN" ]; then
        if ! "$XRAY_BIN" run -c "$CONFIG_FILE" -test >/dev/null 2>&1; then
            write_config_json_body 0
        fi
    fi
}

write_service() {
    local TOTAL_MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)
    TOTAL_MEM_MB=${TOTAL_MEM_MB:-512}
    local SYSTEMD_ENV=""

    if [ "$TOTAL_MEM_MB" -lt 260 ]; then
        echo -e "💡 检测到当前内存较小 (\033[33m${TOTAL_MEM_MB}MB\033[0m <= 256MB)，\033[32m已自动启用低内存防 OOM 调优参数\033[0m (GOGC=20, GOMEMLIMIT=30MiB, madvdontneed=1)"
        SYSTEMD_ENV=$(cat << 'EOF'
Environment="GOGC=20"
Environment="GOMEMLIMIT=30MiB"
Environment="GODEBUG=madvdontneed=1"
EOF
)
    else
        echo "💡 检测到当前机器内存充裕 (${TOTAL_MEM_MB}MB)，使用标准模式运行。"
    fi

    cat > /etc/systemd/system/xray.service << EOF_SYSTEMD
[Unit]
Description=Xray Service
After=network.target nss-lookup.target caddy.service

[Service]
${SYSTEMD_ENV}
ExecStart=/usr/local/bin/xray-core run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF_SYSTEMD
    systemctl daemon-reload
    systemctl enable xray >/dev/null 2>&1
    systemctl restart xray
}

clean_traffic_cron() {
    rm -f /etc/cron.d/xray-traffic 2>/dev/null || true
    if command -v crontab >/dev/null 2>&1; then
        crontab -l 2>/dev/null | grep -v "xray -s" | grep -v "xray --sync-traffic" | crontab - 2>/dev/null || true
    fi
}

update_links_info() {
    local s_v4=$(curl -s4 -m 5 ip.sb 2>/dev/null || curl -s4 -m 5 ifconfig.me 2>/dev/null || curl -s4 -m 5 api.ipify.org 2>/dev/null)
    local host_v4="${s_v4:-你的本机IPv4}"

    local l_direct="vless://${UUID_DIRECT}@${host_v4}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${DEST_SNI}&sid=${SHORT_ID}#${CADDY_DOMAIN}"

    {
        echo "=========================================================================="
        echo "🎉 VLESS-Reality + Caddy 一体化配置列表"
        echo "=========================================================================="
        echo "【主节点：本机直连 (direct-local)】"
        echo "● 节点链接: ${l_direct}"
        echo ""
        echo "--------------------------------------------------------------------------"
        echo "Xray Reality 参数："
        echo "- 本机 IPv4: ${s_v4:-未检测到 (需手动替换)}"
        echo "- Reality 端口: ${PORT}"
        echo "- 伪装域名 (SNI): ${DEST_SNI}"
        echo "- 回落目标 (dest): 127.0.0.1:${CADDY_HTTPS_PORT}"
        echo "- 公钥 (pbk): ${PUBLIC_KEY}"
        echo "- ShortId: ${SHORT_ID}"
        echo "- 本机直连 UUID: ${UUID_DIRECT}"
        if [ "${LOCAL_LOOPBACK_ENABLED:-0}" = "1" ] && [ -n "${LOCAL_LOOPBACK_DOMAIN:-}" ]; then
            echo "- 本机回环映射: 已开启 (${LOCAL_LOOPBACK_DOMAIN} / *.${LOCAL_LOOPBACK_DOMAIN} -> 127.0.0.1:原端口)"
        else
            echo "- 本机回环映射: 未开启"
        fi
        echo ""
        echo "--------------------------------------------------------------------------"
        echo "Caddy 网站防护参数："
        echo "- 网站域名: https://${CADDY_DOMAIN}"
        echo "- 暗号入口: https://${CADDY_DOMAIN}/?secret=${CADDY_SECRET}"
        echo "- API Key 前缀: ${CADDY_KEY_PREFIX}*"
        echo "- 后端反代地址: 127.0.0.1:${BACKEND_PORT}"
        echo "- TLS 证书邮箱: ${CADDY_EMAIL}"
        echo "- 本地 HTTPS 端口: 127.0.0.1:${CADDY_HTTPS_PORT} (80 端口保持开放用于续签)"

        if [ -f "$EXTRA_NODES_FILE" ] && [ -s "$EXTRA_NODES_FILE" ]; then
            echo "=========================================================================="
            echo "【扩展 Reality 节点列表】"
            while IFS='|' read -r e_port e_uuid e_sid e_sni e_tag; do
                [ -z "$e_port" ] && continue
                local e_link="vless://${e_uuid}@${host_v4}:${e_port}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${e_sni}&sid=${e_sid}#${e_tag}"
                echo ""
                echo "● 扩展节点: ${e_tag} (端口: ${e_port})"
                echo "  链接: ${e_link}"
            done < "$EXTRA_NODES_FILE"
        fi
        echo "=========================================================================="
    } > "$LINK_FILE"
}

prompt_caddy_params() {
    echo ""
    echo "====================================="
    echo "📝 请配置 Caddy 伪装站点与防护参数"
    echo "====================================="

    while true; do
        read -p "1. 请输入网站域名 (需已解析到本机IP，如 ai.123.xyz): " input_domain </dev/tty
        input_domain=$(sanitize_domain "$input_domain")
        if [ -n "$input_domain" ] && [[ "$input_domain" == *.* ]]; then
            CADDY_DOMAIN="$input_domain"
            break
        fi
        echo -e "\033[31m域名格式不正确，请重新输入！\033[0m"
    done

    read -p "2. 请输入 TLS 证书邮箱 (直接回车默认 admin@${CADDY_DOMAIN}): " input_email </dev/tty
    input_email="${input_email//[[:space:]]/}"
    CADDY_EMAIL="${input_email:-admin@${CADDY_DOMAIN}}"

    while true; do
        read -p "3. 请输入后台访问暗号 secret (用于 ?secret=暗号，勿含空格引号): " input_secret </dev/tty
        if validate_safe_token "$input_secret"; then
            CADDY_SECRET="$input_secret"
            break
        fi
        echo -e "\033[31m暗号不能为空且不能包含空格、引号或分号！\033[0m"
    done

    while true; do
        read -p "4. 请输入 API Key 允许前缀 (如 sk-123，直接回车默认 sk-): " input_prefix </dev/tty
        input_prefix="${input_prefix:-sk-}"
        if validate_safe_token "$input_prefix"; then
            CADDY_KEY_PREFIX="$input_prefix"
            break
        fi
        echo -e "\033[31mKey 前缀不能包含空格、引号或分号！\033[0m"
    done

    while true; do
        read -p "5. 请输入网站后端反代端口 (直接回车默认 3000): " input_bport </dev/tty
        input_bport="${input_bport:-3000}"
        if [[ "$input_bport" =~ ^[0-9]+$ ]] && [ "$input_bport" -ge 1 ] && [ "$input_bport" -le 65535 ]; then
            BACKEND_PORT="$input_bport"
            break
        fi
        echo -e "\033[31m端口不合法，请输入 1-65535 之间的数字！\033[0m"
    done

    CADDY_COOKIE=$(openssl rand -hex 12)
    CADDY_HTTPS_PORT=8443
    DEST_SNI="$CADDY_DOMAIN"
}

# ------------------------------------------------------------------------------
# 2. 写入全局管理脚本 /usr/local/bin/xray
# ------------------------------------------------------------------------------
write_management_cli() {
    cat > /usr/local/bin/xray << 'EOF_MANAGEMENT_SCRIPT'
#!/bin/bash

SCRIPT_VERSION="1.0.1"
SCRIPT_URL="https://github.com/justly110/xray/raw/main/rea-caddy.sh"

ENV_FILE="/usr/local/etc/xray/params.env"
CONFIG_FILE="/usr/local/etc/xray/config.json"
LINK_FILE="/usr/local/etc/xray/link.txt"
EXTRA_NODES_FILE="/usr/local/etc/xray/extra_nodes.env"
XRAY_BIN="/usr/local/bin/xray-core"
CADDY_FILE="/etc/caddy/Caddyfile"

json_escape() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/ }
    s=${s//$'\r'/ }
    s=${s//$'\t'/ }
    printf '%s' "$s"
}

env_quote() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//\$/\\\$}
    s=${s//\`/\\\`}
    s=${s//$'\n'/ }
    printf '%s' "$s"
}

sanitize_domain() {
    local d="$1"
    d="${d#http://}"
    d="${d#https://}"
    d="${d%%/*}"
    d="${d%%:*}"
    d="${d//[[:space:]]/}"
    printf '%s' "$d"
}

validate_domain() {
    local d="$1"
    [ -n "$d" ] || return 1
    [[ "$d" != *..* ]] || return 1
    [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]
}

validate_safe_token() {
    local t="$1"
    [ -n "$t" ] || return 1
    if [[ "$t" =~ [[:space:]\"\'\;] ]]; then
        return 1
    fi
    return 0
}

load_env() {
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
        LOCAL_LOOPBACK_ENABLED="${LOCAL_LOOPBACK_ENABLED:-0}"
        LOCAL_LOOPBACK_DOMAIN="${LOCAL_LOOPBACK_DOMAIN:-}"
    else
        echo "❌ 缺少 $ENV_FILE"
        exit 1
    fi
}

get_xray_status() {
    if systemctl is-active --quiet xray; then
        echo -e "\033[32m● 正在运行 (Running)\033[0m"
    else
        echo -e "\033[31m○ 未运行 (Stopped)\033[0m"
    fi
}

get_caddy_status() {
    if ! command -v caddy >/dev/null 2>&1; then
        echo -e "\033[31m○ 未安装\033[0m"
    elif systemctl is-active --quiet caddy; then
        echo -e "\033[32m● 正在运行 (Running)\033[0m"
    else
        echo -e "\033[31m○ 未运行 (Stopped)\033[0m"
    fi
}

get_xray_core_version() {
    local v=$($XRAY_BIN version 2>/dev/null | head -n 1 | awk '{print $2}')
    [ -n "$v" ] && echo "$v" || echo "未知"
}

get_caddy_version() {
    local v=$(caddy version 2>/dev/null | head -n 1 | awk '{print $1}')
    [ -n "$v" ] && echo "$v" || echo "未知"
}

do_restart() {
    systemctl restart caddy
    systemctl restart xray
}
do_start() {
    systemctl start caddy
    systemctl start xray
}
do_stop() {
    systemctl stop xray
    systemctl stop caddy
}

apply_sysctl_optimization() {
    modprobe tcp_bbr 2>/dev/null || true
    local params=(
        "net.ipv4.tcp_window_scaling"
        "net.core.rmem_max"
        "net.core.wmem_max"
        "net.core.rmem_default"
        "net.core.wmem_default"
        "net.core.netdev_max_backlog"
        "net.ipv4.tcp_rmem"
        "net.ipv4.tcp_wmem"
        "net.ipv4.tcp_slow_start_after_idle"
        "net.ipv4.tcp_mtu_probing"
        "net.ipv4.tcp_notsent_lowat"
        "net.core.default_qdisc"
        "net.ipv4.tcp_congestion_control"
    )
    for p in "${params[@]}"; do
        sed -i "/^${p}[[:space:]]*=/d" /etc/sysctl.conf 2>/dev/null
    done
    cat >> /etc/sysctl.conf << 'EOF_SYSCTL'
net.ipv4.tcp_window_scaling = 1
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.netdev_max_backlog = 10000
net.ipv4.tcp_rmem = 4096 1048576 33554432
net.ipv4.tcp_wmem = 4096 1048576 33554432
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 16384
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF_SYSCTL
    sysctl -p >/dev/null 2>&1 || true
}

manage_bbr() {
    clear
    echo "=========================================="
    echo "       TCP BBR 加速与网络内核调优         "
    echo "=========================================="
    local cur_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)
    local cur_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || cat /proc/sys/net/core/default_qdisc 2>/dev/null)
    local cur_rmem=$(sysctl -n net.core.rmem_max 2>/dev/null || true)
    local virt=$(systemd-detect-virt 2>/dev/null || true)

    echo "当前拥塞控制算法 : ${cur_cc:-未知}"
    echo "当前网络队列算法 : ${cur_qdisc:-未知}"
    [ -n "$cur_rmem" ] && echo "核心读缓冲区上限 : $((cur_rmem / 1024 / 1024)) MB"
    [ -n "$virt" ] && echo "底层虚拟化架构   : $virt"
    echo "------------------------------------------"

    local is_container=0
    if [ "$virt" = "lxc" ] || [ "$virt" = "openvz" ] || [ ! -w "/proc/sys/net/ipv4/tcp_congestion_control" ]; then
        is_container=1
    fi

    if [ "$is_container" -eq 1 ]; then
        echo -e "\033[33m⚠️ 提示: 当前 VPS 处于容器虚拟化架构 ($virt) 或内核只读环境。\033[0m"
        echo "该架构下网络协议栈由母鸡宿主机统一接管，无需且无法在小鸡内单独修改 BBR。"
        echo ""
        read -n 1 -s -r -p "按任意键返回管理菜单..." </dev/tty
        return
    fi

    if [ "$cur_cc" = "bbr" ]; then
        echo -e "\033[32m✔ 系统已成功启用 BBR 拥塞控制算法。\033[0m"
        read -p "是否重新应用/刷新 32MB TCP 动态缓冲区参数？[y/N]: " re_opt </dev/tty
        if [[ "$re_opt" =~ ^[yY]$ ]]; then
            apply_sysctl_optimization
            echo -e "\033[32m🎉 网络优化参数刷新成功！\033[0m"
        fi
        echo ""
        read -n 1 -s -r -p "按任意键返回管理菜单..." </dev/tty
        return
    fi

    echo "当前未开启 BBR，系统支持开启。"
    read -p "是否现在一键开启 BBR + FQ 加速并优化 TCP 缓冲区 (32MB)？[Y/n]: " do_bbr </dev/tty
    if [[ ! "$do_bbr" =~ ^[nN]$ ]]; then
        apply_sysctl_optimization
        sleep 1
        local check_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
        if [ "$check_cc" = "bbr" ]; then
            echo -e "\033[32m🎉 BBR 及高带宽 TCP 缓冲区配置成功！\033[0m"
        else
            echo -e "\033[31m❌ 开启失败，可能需要更新系统内核。\033[0m"
        fi
    fi
    echo ""
    read -n 1 -s -r -p "按任意键返回管理菜单..." </dev/tty
}

render_caddyfile() {
    cat > "$CADDY_FILE" << EOF
{
    https_port ${CADDY_HTTPS_PORT}
    auto_https disable_redirects
}

# 保留 80 端口：用于 Let's Encrypt 证书自动申请/续签，并跳转至公网 443
http://${CADDY_DOMAIN} {
    redir https://{host}{uri} permanent
}

# 仅监听本机 127.0.0.1:${CADDY_HTTPS_PORT}，由 Xray (REALITY) 转发进来
https://${CADDY_DOMAIN} {
    bind 127.0.0.1
    tls ${CADDY_EMAIL}

    @is_secret query secret=${CADDY_SECRET}
    @has_cookie header Cookie "*admin_auth=${CADDY_COOKIE}*"
    @has_auth1 header Authorization "Bearer ${CADDY_KEY_PREFIX}*"
    @has_auth2 header x-api-key "${CADDY_KEY_PREFIX}*"
    @has_auth3 header x-goog-api-key "${CADDY_KEY_PREFIX}*"

    handle @is_secret {
        header +Set-Cookie "admin_auth=${CADDY_COOKIE}; Path=/; Max-Age=2592000; HttpOnly; Secure; SameSite=Lax"
        rewrite * /
        reverse_proxy 127.0.0.1:${BACKEND_PORT} {
            flush_interval -1
        }
    }

    handle @has_cookie {
        reverse_proxy 127.0.0.1:${BACKEND_PORT} {
            flush_interval -1
        }
    }

    handle @has_auth1 {
        reverse_proxy 127.0.0.1:${BACKEND_PORT} {
            flush_interval -1
        }
    }

    handle @has_auth2 {
        reverse_proxy 127.0.0.1:${BACKEND_PORT} {
            flush_interval -1
        }
    }

    handle @has_auth3 {
        reverse_proxy 127.0.0.1:${BACKEND_PORT} {
            flush_interval -1
        }
    }

    handle {
        respond "Not Found" 404
    }
}
EOF
    caddy fmt --overwrite "$CADDY_FILE" >/dev/null 2>&1 || true
    if ! caddy validate --config "$CADDY_FILE" >/dev/null 2>&1; then
        echo "❌ Caddyfile 语法校验失败！"
        caddy validate --config "$CADDY_FILE"
        return 1
    fi
    return 0
}

build_inbounds_json() {
    local port="$1"; local sni="$2"; local u_direct="$3"; local priv="$4"; local sid="$5"; local caddy_port="$6"
    sni=$(json_escape "$sni"); u_direct=$(json_escape "$u_direct")
    priv=$(json_escape "$priv"); sid=$(json_escape "$sid")
    cat << EOF
[
  {
    "tag": "vless-v4",
    "listen": "0.0.0.0",
    "port": $port,
    "protocol": "vless",
    "settings": {
      "clients": [
        {"id": "$u_direct", "flow": "xtls-rprx-vision", "email": "direct-local"}
      ],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "dest": "127.0.0.1:$caddy_port",
        "serverNames": ["$sni"],
        "privateKey": "$priv",
        "shortIds": ["$sid"]
      },
      "sockopt": {
        "tcpFastOpen": true,
        "tcpKeepAliveInterval": 15
      }
    },
    "sniffing": {"enabled": false}
  }
EOF

    if [ -f "$EXTRA_NODES_FILE" ]; then
        while IFS='|' read -r e_port e_uuid e_sid e_sni e_tag; do
            [ -z "$e_port" ] && continue
            e_uuid=$(json_escape "$e_uuid"); e_sid=$(json_escape "$e_sid"); e_sni=$(json_escape "$e_sni")
            cat << EOF
  ,
  {
    "tag": "reality-in-$e_port",
    "listen": "0.0.0.0",
    "port": $e_port,
    "protocol": "vless",
    "settings": {
      "clients": [
        {"id": "$e_uuid", "flow": "xtls-rprx-vision", "email": "user-$e_port"}
      ],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "dest": "$e_sni:443",
        "serverNames": ["$e_sni"],
        "privateKey": "$priv",
        "shortIds": ["$sid"]
      },
      "sockopt": {
        "tcpFastOpen": true,
        "tcpKeepAliveInterval": 15
      }
    },
    "sniffing": {"enabled": false}
  }
EOF
        done < "$EXTRA_NODES_FILE"
    fi

    echo "]"
}

write_config_json_body() {
    local use_final_rules="${1:-1}"
    local lb_domain=""
    if [ "${LOCAL_LOOPBACK_ENABLED:-0}" = "1" ] && validate_domain "${LOCAL_LOOPBACK_DOMAIN:-}"; then
        lb_domain=$(json_escape "$LOCAL_LOOPBACK_DOMAIN")
    fi

    {
        echo "{"
        echo '  "log": {"loglevel": "warning"},'
        echo "  \"inbounds\": $(build_inbounds_json "$PORT" "$DEST_SNI" "$UUID_DIRECT" "$PRIVATE_KEY" "$SHORT_ID" "$CADDY_HTTPS_PORT"),"
        echo '  "outbounds": ['
        if [ -n "$lb_domain" ]; then
            echo '    {"protocol": "freedom", "tag": "direct"},'
            echo '    {'
            echo '      "protocol": "freedom",'
            echo '      "tag": "local-vps",'
            echo '      "settings": {'
            if [ "$use_final_rules" = "1" ]; then
                echo '        "redirect": "127.0.0.1:0",'
                echo '        "finalRules": ['
                echo '          {'
                echo '            "action": "allow",'
                echo '            "network": "tcp,udp",'
                echo '            "ip": ["127.0.0.1/32"]'
                echo '          }'
                echo '        ]'
            else
                echo '        "redirect": "127.0.0.1:0"'
            fi
            echo '      }'
            echo '    }'
        else
            echo '    {"protocol": "freedom", "tag": "direct"}'
        fi
        echo '  ],'
        echo '  "routing": {'
        echo '    "rules": ['
        if [ -n "$lb_domain" ]; then
            echo '      {'
            echo '        "type": "field",'
            echo "        \"domain\": [\"domain:${lb_domain}\"],"
            echo '        "outboundTag": "local-vps"'
            echo '      },'
        fi
        echo '      {'
        echo '        "type": "field",'
        echo '        "network": "tcp,udp",'
        echo '        "outboundTag": "direct"'
        echo '      }'
        echo '    ]'
        echo '  }'
        echo "}"
    } > "$CONFIG_FILE"
}

rebuild_and_apply() {
    echo -e "\n⏳ 正在校验并更新 Caddy 与 Xray 配置..."
    if ! render_caddyfile; then
        read -n 1 -s -r -p "按任意键返回..." </dev/tty
        return 1
    fi

    write_config_json_body 1
    if [ "${LOCAL_LOOPBACK_ENABLED:-0}" = "1" ] && [ -x "$XRAY_BIN" ]; then
        if ! "$XRAY_BIN" run -c "$CONFIG_FILE" -test >/dev/null 2>&1; then
            write_config_json_body 0
        fi
    fi

    {
        echo "PORT=\"$(env_quote "$PORT")\""
        echo "DEST_SNI=\"$(env_quote "$DEST_SNI")\""
        echo "UUID_DIRECT=\"$(env_quote "$UUID_DIRECT")\""
        echo "PUBLIC_KEY=\"$(env_quote "$PUBLIC_KEY")\""
        echo "PRIVATE_KEY=\"$(env_quote "$PRIVATE_KEY")\""
        echo "SHORT_ID=\"$(env_quote "$SHORT_ID")\""
        echo "CADDY_DOMAIN=\"$(env_quote "$CADDY_DOMAIN")\""
        echo "CADDY_EMAIL=\"$(env_quote "$CADDY_EMAIL")\""
        echo "CADDY_SECRET=\"$(env_quote "$CADDY_SECRET")\""
        echo "CADDY_COOKIE=\"$(env_quote "$CADDY_COOKIE")\""
        echo "CADDY_KEY_PREFIX=\"$(env_quote "$CADDY_KEY_PREFIX")\""
        echo "BACKEND_PORT=\"$(env_quote "$BACKEND_PORT")\""
        echo "CADDY_HTTPS_PORT=\"$(env_quote "$CADDY_HTTPS_PORT")\""
        echo "LOCAL_LOOPBACK_ENABLED=\"$(env_quote "${LOCAL_LOOPBACK_ENABLED:-0}")\""
        echo "LOCAL_LOOPBACK_DOMAIN=\"$(env_quote "${LOCAL_LOOPBACK_DOMAIN:-}")\""
    } > "$ENV_FILE"

    do_restart
    sleep 1

    local s_v4=$(curl -s4 -m 5 ip.sb 2>/dev/null || curl -s4 -m 5 ifconfig.me 2>/dev/null || curl -s4 -m 5 api.ipify.org 2>/dev/null)
    local host_v4="${s_v4:-你的本机IPv4}"
    local l_direct="vless://${UUID_DIRECT}@${host_v4}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${DEST_SNI}&sid=${SHORT_ID}#${CADDY_DOMAIN}"

    {
        echo "=========================================================================="
        echo "🎉 VLESS-Reality + Caddy 一体化配置列表"
        echo "=========================================================================="
        echo "【主节点：本机直连 (direct-local)】"
        echo "● 节点链接: ${l_direct}"
        echo ""
        echo "--------------------------------------------------------------------------"
        echo "Xray Reality 参数："
        echo "- 本机 IPv4: ${s_v4:-未检测到 (需手动替换)}"
        echo "- Reality 端口: ${PORT}"
        echo "- 伪装域名 (SNI): ${DEST_SNI}"
        echo "- 回落目标 (dest): 127.0.0.1:${CADDY_HTTPS_PORT}"
        echo "- 公钥 (pbk): ${PUBLIC_KEY}"
        echo "- ShortId: ${SHORT_ID}"
        echo "- 本机直连 UUID: ${UUID_DIRECT}"
        if [ "${LOCAL_LOOPBACK_ENABLED:-0}" = "1" ] && [ -n "${LOCAL_LOOPBACK_DOMAIN:-}" ]; then
            echo "- 本机回环映射: 已开启 (${LOCAL_LOOPBACK_DOMAIN} / *.${LOCAL_LOOPBACK_DOMAIN} -> 127.0.0.1:原端口)"
        else
            echo "- 本机回环映射: 未开启"
        fi
        echo ""
        echo "--------------------------------------------------------------------------"
        echo "Caddy 网站防护参数："
        echo "- 网站域名: https://${CADDY_DOMAIN}"
        echo "- 暗号入口: https://${CADDY_DOMAIN}/?secret=${CADDY_SECRET}"
        echo "- API Key 前缀: ${CADDY_KEY_PREFIX}*"
        echo "- 后端反代地址: 127.0.0.1:${BACKEND_PORT}"
        echo "- TLS 证书邮箱: ${CADDY_EMAIL}"
        echo "- 本地 HTTPS 端口: 127.0.0.1:${CADDY_HTTPS_PORT} (80 端口保持开放用于续签)"

        if [ -f "$EXTRA_NODES_FILE" ] && [ -s "$EXTRA_NODES_FILE" ]; then
            echo "=========================================================================="
            echo "【扩展 Reality 节点列表】"
            while IFS='|' read -r e_port e_uuid e_sid e_sni e_tag; do
                [ -z "$e_port" ] && continue
                local e_link="vless://${e_uuid}@${host_v4}:${e_port}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${e_sni}&sid=${e_sid}#${e_tag}"
                echo ""
                echo "● 扩展节点: ${e_tag} (端口: ${e_port})"
                echo "  链接: ${e_link}"
            done < "$EXTRA_NODES_FILE"
        fi
        echo "=========================================================================="
    } > "$LINK_FILE"

    clear
    echo -e "\033[32m✔ 配置已更新并成功重启 Caddy 与 Xray！\033[0m\n"
    cat "$LINK_FILE"
    echo ""
    read -n 1 -s -r -p "按任意键返回管理菜单..." </dev/tty
}

configure_local_loopback() {
    while true; do
        clear
        local lb_status="已关闭"
        if [ "${LOCAL_LOOPBACK_ENABLED:-0}" = "1" ] && [ -n "${LOCAL_LOOPBACK_DOMAIN:-}" ]; then
            lb_status="已开启 (${LOCAL_LOOPBACK_DOMAIN} -> 127.0.0.1:原端口)"
        fi
        echo "=========================================="
        echo "      本机回环自定义域名 (127.0.0.1)      "
        echo "=========================================="
        echo "作用: 代理中访问 自编域名:任意端口 时直连本机 127.0.0.1:对应端口"
        echo "当前状态: ${lb_status}"
        echo "------------------------------------------"
        echo " 1. 开启 / 修改本机回环域名 (支持主域名及子域名)"
        echo " 2. 关闭本机回环域名映射"
        echo " 0. 返回上一级"
        echo "=========================================="
        read -p "请输入选项 [0-2]: " lb_opt </dev/tty
        case "$lb_opt" in
            1)
                local def_domain="${LOCAL_LOOPBACK_DOMAIN:-vps.ai}"
                read -p "请输入自定义域名 (直接回车默认 ${def_domain}): " input_lb </dev/tty
                input_lb="${input_lb:-$def_domain}"
                input_lb=$(sanitize_domain "$input_lb")
                if validate_domain "$input_lb"; then
                    LOCAL_LOOPBACK_ENABLED="1"
                    LOCAL_LOOPBACK_DOMAIN="$input_lb"
                    rebuild_and_apply
                    return 0
                else
                    echo -e "\033[31m域名格式不合法，请输入纯域名（如 vps.ai）！\033[0m"
                    sleep 1
                fi
                ;;
            2)
                if [ "${LOCAL_LOOPBACK_ENABLED:-0}" = "0" ]; then
                    echo -e "\033[33m当前已处于关闭状态。\033[0m"
                    sleep 1
                else
                    LOCAL_LOOPBACK_ENABLED="0"
                    rebuild_and_apply
                    return 0
                fi
                ;;
            0) return 1 ;;
            *) echo -e "\033[31m无效输入！\033[0m"; sleep 1 ;;
        esac
    done
}

modify_xray_config() {
    load_env
    while true; do
        clear
        local lb_summary="已关闭"
        if [ "${LOCAL_LOOPBACK_ENABLED:-0}" = "1" ] && [ -n "${LOCAL_LOOPBACK_DOMAIN:-}" ]; then
            lb_summary="已开启 -> ${LOCAL_LOOPBACK_DOMAIN}"
        fi
        echo "=========================================="
        echo "           修改 Xray 节点配置             "
        echo "=========================================="
        echo " 1. 修改 Reality 监听端口 (当前: $PORT)"
        echo " 2. 重新生成 Reality 密钥对(Keypair)及 ShortID"
        echo " 3. 重新生成【本机直连】UUID"
        echo " 4. 手动输入新的【本机直连】UUID"
        echo " 5. 自定义伪装域名 SNI (当前: $DEST_SNI)"
        echo " 6. 本机回环自定义域名开关 (当前: ${lb_summary})"
        echo "------------------------------------------"
        echo " 0. 返回主菜单"
        echo "=========================================="
        read -p "请输入选项 [0-6]: " opt </dev/tty
        case "$opt" in
            1)
                read -p "请输入新的端口 (1-65535，通常保持 443): " new_port </dev/tty
                if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
                    PORT="$new_port"; rebuild_and_apply; break
                else echo -e "\033[31m端口不合法！\033[0m"; sleep 1; fi
                ;;
            2)
                KEYS=$($XRAY_BIN x25519)
                PRIVATE_KEY=$(echo "$KEYS" | awk '/^PrivateKey:/ {print $2}')
                PUBLIC_KEY=$(echo "$KEYS" | awk '/PublicKey|Password/ {print $NF}')
                if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
                    echo -e "\033[31m密钥解析失败，已取消。\033[0m"; echo "$KEYS"; sleep 2; break
                fi
                SHORT_ID=$(openssl rand -hex 8)
                rebuild_and_apply; break
                ;;
            3) UUID_DIRECT=$($XRAY_BIN uuid); rebuild_and_apply; break ;;
            4)
                read -p "请输入新的【本机直连】UUID: " custom_uid_dir </dev/tty
                [ -n "$custom_uid_dir" ] && { UUID_DIRECT="$custom_uid_dir"; rebuild_and_apply; break; }
                ;;
            5)
                read -p "请输入新的 SNI (一般应与 Caddy 域名 ${CADDY_DOMAIN} 一致): " new_sni </dev/tty
                new_sni=$(sanitize_domain "$new_sni")
                if [ -n "$new_sni" ]; then
                    DEST_SNI="$new_sni"; rebuild_and_apply; break
                fi
                ;;
            6) configure_local_loopback && break ;;
            0) break ;;
            *) echo -e "\033[31m无效输入！\033[0m"; sleep 1 ;;
        esac
    done
}

modify_caddy_config() {
    load_env
    while true; do
        clear
        echo "=========================================="
        echo "           修改 Caddy 网站配置            "
        echo "=========================================="
        echo " 1. 修改网站域名 (同步更新 SNI，当前: $CADDY_DOMAIN)"
        echo " 2. 修改后台访问暗号 secret (当前: $CADDY_SECRET)"
        echo " 3. 修改 API Key 前缀 (当前: $CADDY_KEY_PREFIX)"
        echo " 4. 修改后端反代端口 (当前: $BACKEND_PORT)"
        echo " 5. 修改 TLS 证书邮箱 (当前: $CADDY_EMAIL)"
        echo " 6. 修改 Caddy 本地 HTTPS 端口 (当前: $CADDY_HTTPS_PORT)"
        echo " 7. 查看当前 Caddyfile 内容"
        echo "------------------------------------------"
        echo " 0. 返回主菜单"
        echo "=========================================="
        read -p "请输入选项 [0-7]: " c_opt </dev/tty
        case "$c_opt" in
            1)
                read -p "请输入新的网站域名 (如 ai.123.xyz): " new_domain </dev/tty
                new_domain=$(sanitize_domain "$new_domain")
                if [ -n "$new_domain" ] && [[ "$new_domain" == *.* ]]; then
                    CADDY_DOMAIN="$new_domain"
                    DEST_SNI="$new_domain"
                    rebuild_and_apply; break
                else
                    echo -e "\033[31m域名格式不正确！\033[0m"; sleep 1
                fi
                ;;
            2)
                read -p "请输入新的访问暗号 secret (勿含空格引号): " new_secret </dev/tty
                if validate_safe_token "$new_secret"; then
                    CADDY_SECRET="$new_secret"
                    CADDY_COOKIE=$(openssl rand -hex 12)
                    rebuild_and_apply; break
                else
                    echo -e "\033[31m暗号不能为空且不能包含空格、引号或分号！\033[0m"; sleep 1
                fi
                ;;
            3)
                read -p "请输入新的 API Key 前缀 (如 sk-123): " new_prefix </dev/tty
                if validate_safe_token "$new_prefix"; then
                    CADDY_KEY_PREFIX="$new_prefix"
                    rebuild_and_apply; break
                else
                    echo -e "\033[31mKey 前缀不能为空且不能包含空格、引号或分号！\033[0m"; sleep 1
                fi
                ;;
            4)
                read -p "请输入新的后端反代端口 (1-65535): " new_bport </dev/tty
                if [[ "$new_bport" =~ ^[0-9]+$ ]] && [ "$new_bport" -ge 1 ] && [ "$new_bport" -le 65535 ]; then
                    BACKEND_PORT="$new_bport"
                    rebuild_and_apply; break
                else
                    echo -e "\033[31m端口不合法！\033[0m"; sleep 1
                fi
                ;;
            5)
                read -p "请输入新的 TLS 证书邮箱: " new_email </dev/tty
                new_email="${new_email//[[:space:]]/}"
                if [ -n "$new_email" ]; then
                    CADDY_EMAIL="$new_email"
                    rebuild_and_apply; break
                else
                    echo -e "\033[31m邮箱不能为空！\033[0m"; sleep 1
                fi
                ;;
            6)
                read -p "请输入新的 Caddy 本地 HTTPS 端口 (默认 8443): " new_chport </dev/tty
                if [[ "$new_chport" =~ ^[0-9]+$ ]] && [ "$new_chport" -ge 1 ] && [ "$new_chport" -le 65535 ] && [ "$new_chport" != "$PORT" ]; then
                    CADDY_HTTPS_PORT="$new_chport"
                    rebuild_and_apply; break
                else
                    echo -e "\033[31m端口不合法或与 Xray 端口 ($PORT) 冲突！\033[0m"; sleep 1
                fi
                ;;
            7)
                clear
                [ -f "$CADDY_FILE" ] && cat "$CADDY_FILE" || echo "未找到 $CADDY_FILE"
                echo ""
                read -n 1 -s -r -p "按任意键返回..." </dev/tty
                ;;
            0) break ;;
            *) echo -e "\033[31m无效输入！\033[0m"; sleep 1 ;;
        esac
    done
}

# ----------------- 在线升级模块 -----------------
check_and_update_core() {
    clear
    echo "=========================================="
    echo "           检查 Xray 内核更新             "
    echo "=========================================="
    local cur_ver=$(get_xray_core_version)
    cur_ver="v${cur_ver#v}"
    echo "正在获取官方最新版本信息..."
    local latest_ver=$(curl -sL -m 8 -o /dev/null -w %{url_effective} https://github.com/XTLS/Xray-core/releases/latest | grep -oE '[^/]+$')
    if [ -z "$latest_ver" ] || [ "$latest_ver" = "latest" ]; then
        latest_ver=$(curl -sL -m 8 https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null | grep '"tag_name":' | head -n 1 | cut -d '"' -f 4)
    fi
    latest_ver="v${latest_ver#v}"

    if [ -z "$latest_ver" ] || [ "$latest_ver" = "v" ] || [ "$latest_ver" = "vlatest" ]; then
        echo -e "\033[31m❌ 无法获取最新版本号，请检查网络！\033[0m"
        read -n 1 -s -r -p "按任意键返回..." </dev/tty
        return
    fi

    echo "当前本地内核版本: $cur_ver"
    echo "官方最新内核版本: $latest_ver"
    echo "------------------------------------------"

    if [ "$cur_ver" = "$latest_ver" ]; then
        echo -e "\033[32m✔ 当前已是最新内核，无需更新！\033[0m"
        read -p "是否强制重新下载覆盖？[y/N]: " force_up </dev/tty
        [[ ! "$force_up" =~ ^[yY]$ ]] && return
    else
        read -p "检测到内核更新，是否立即升级？[Y/n]: " do_up </dev/tty
        [[ "$do_up" =~ ^[nN]$ ]] && return
    fi

    echo -e "\n⏳ 正在拉取 Xray ${latest_ver} (x86_64)..."
    mkdir -p /tmp/xray_update
    if curl -sL -o /tmp/xray_update/xray.zip "https://github.com/XTLS/Xray-core/releases/download/${latest_ver}/Xray-linux-64.zip"; then
        unzip -q -o /tmp/xray_update/xray.zip -d /tmp/xray_update/
        mv -f /tmp/xray_update/xray "$XRAY_BIN"
        chmod +x "$XRAY_BIN"
        rm -rf /tmp/xray_update
        systemctl restart xray
        echo -e "\033[32m🎉 Xray 内核已成功更新至 ${latest_ver}！\033[0m"
    else
        echo -e "\033[31m❌ 下载失败，请检查网络！\033[0m"
        rm -rf /tmp/xray_update
    fi
    echo ""
    read -n 1 -s -r -p "按任意键返回..." </dev/tty
}

update_caddy() {
    clear
    echo "=========================================="
    echo "           更新 Caddy (APT 官方源)        "
    echo "=========================================="
    echo "当前 Caddy 版本: $(get_caddy_version)"
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade caddy
    systemctl restart caddy
    echo -e "\033[32m✔ Caddy 当前版本: $(get_caddy_version)\033[0m"
    echo ""
    read -n 1 -s -r -p "按任意键返回..." </dev/tty
}

check_and_update_script() {
    clear
    echo "=========================================="
    echo "           检查管理脚本更新               "
    echo "=========================================="
    echo "当前本地脚本版本: $SCRIPT_VERSION"
    local fetch_url="${SCRIPT_URL}?t=$(date +%s)"
    local remote_ver=$(curl -sL -m 8 "$fetch_url" 2>/dev/null | grep -m 1 '^SCRIPT_VERSION=' | cut -d'"' -f2)

    if [ -z "$remote_ver" ]; then
        echo -e "\033[31m❌ 无法获取远程版本，请检查网络！\033[0m"
        read -n 1 -s -r -p "按任意键返回..." </dev/tty
        return
    fi
    echo "远程最新脚本版本: $remote_ver"
    echo "------------------------------------------"

    if [ "$SCRIPT_VERSION" = "$remote_ver" ]; then
        echo -e "\033[32m✔ 当前管理脚本已是最新版本！\033[0m"
        read -p "是否强制重新覆盖？[y/N]: " force_sc </dev/tty
        [[ ! "$force_sc" =~ ^[yY]$ ]] && return
    else
        read -p "检测到脚本更新，是否立即升级？[Y/n]: " do_sc </dev/tty
        [[ "$do_sc" =~ ^[nN]$ ]] && return
    fi

    echo -e "\n⏳ 正在拉取最新脚本并平滑升级..."
    if curl -fsSL "$fetch_url" -o /tmp/xray_new.sh \
        && grep -q '^SCRIPT_VERSION="' /tmp/xray_new.sh \
        && grep -q 'write_management_cli' /tmp/xray_new.sh; then
        chmod +x /tmp/xray_new.sh
        if ! bash /tmp/xray_new.sh --auto-upgrade </dev/tty; then
            rm -f /tmp/xray_new.sh
            echo "管理脚本升级失败，请检查上方错误信息。"
            return 1
        fi
        rm -f /tmp/xray_new.sh
        echo -e "\033[32m🎉 管理脚本升级完成！\033[0m"
        exit 0
    fi
    rm -f /tmp/xray_new.sh
    echo -e "\033[31m❌ 下载内容校验失败，已取消升级。\033[0m"
    read -n 1 -s -r -p "按任意键返回..." </dev/tty
}

update_menu() {
    while true; do
        clear
        echo "=========================================="
        echo "       Xray / Caddy / 脚本在线更新        "
        echo "=========================================="
        echo " 1. 更新 Xray 内核 (xray-core)"
        echo " 2. 更新 Caddy (APT)"
        echo " 3. 更新管理脚本 (rea-caddy.sh)"
        echo " 4. 一键更新全部"
        echo " 0. 返回主菜单"
        echo "=========================================="
        read -p "请输入选项 [0-4]: " u_opt </dev/tty
        case "$u_opt" in
            1) check_and_update_core ;;
            2) update_caddy ;;
            3) check_and_update_script ;;
            4) check_and_update_core; update_caddy; check_and_update_script ;;
            0) break ;;
            *) echo -e "\033[31m无效输入！\033[0m"; sleep 1 ;;
        esac
    done
}

restart_all() { echo -e "\n正在重启 Caddy & Xray..."; do_restart; sleep 1; echo -e "\033[32m重启完成！\033[0m"; read -n 1 -s -r -p "按任意键继续..." </dev/tty; }
start_all() { echo -e "\n正在启动 Caddy & Xray..."; do_start; sleep 1; echo -e "\033[32m启动完成！\033[0m"; read -n 1 -s -r -p "按任意键继续..." </dev/tty; }
stop_all() { echo -e "\n正在停止 Xray & Caddy..."; do_stop; sleep 1; echo -e "\033[33m已停止！\033[0m"; read -n 1 -s -r -p "按任意键继续..." </dev/tty; }
show_info() { clear; [ -f "$LINK_FILE" ] && cat "$LINK_FILE" || echo "未找到节点信息！"; echo ""; read -n 1 -s -r -p "按任意键返回菜单..." </dev/tty; }

show_logs() {
    clear
    echo "=========================================="
    echo "               查看运行日志               "
    echo "=========================================="
    echo " 1. 查看 Xray 最近 40 行日志"
    echo " 2. 查看 Caddy 最近 40 行日志"
    echo " 0. 返回主菜单"
    read -p "请输入选项 [0-2]: " l_opt </dev/tty
    case "$l_opt" in
        1) echo ""; journalctl -u xray -n 40 --no-pager ;;
        2) echo ""; journalctl -u caddy -n 40 --no-pager ;;
        0) return ;;
    esac
    echo ""
    read -n 1 -s -r -p "按任意键返回菜单..." </dev/tty
}

uninstall_all() {
    echo ""
    read -p "⚠️ 确定要彻底卸载 Xray 及其配置与管理脚本吗？[y/N]: " confirm </dev/tty
    case "$confirm" in
        [yY][eE][sS]|[yY])
            echo -e "\n正在停止并清理 Xray 服务..."
            systemctl stop xray 2>/dev/null || true
            systemctl disable xray 2>/dev/null || true
            rm -f /etc/systemd/system/xray.service
            systemctl daemon-reload
            rm -f /etc/cron.d/xray-traffic 2>/dev/null || true
            crontab -l 2>/dev/null | grep -v "xray -s" | grep -v "xray --sync-traffic" | crontab - 2>/dev/null || true
            rm -f /usr/local/bin/xray-core /usr/local/bin/xray
            rm -rf /usr/local/etc/xray /root/xray_temp

            read -p "是否同时卸载 Caddy 及其配置文件？[y/N]: " rm_caddy </dev/tty
            if [[ "$rm_caddy" =~ ^[yY]$ ]]; then
                systemctl stop caddy 2>/dev/null || true
                systemctl disable caddy 2>/dev/null || true
                apt-get purge -y caddy 2>/dev/null || true
                rm -rf /etc/caddy /var/lib/caddy
            fi
            echo -e "\033[32m🎉 卸载清理完成！\033[0m"
            exit 0
            ;;
        *) echo -e "\033[33m已取消卸载。\033[0m"; sleep 1 ;;
    esac
}

main_menu() {
    while true; do
        clear
        local core_v=$(get_xray_core_version)
        local caddy_v=$(get_caddy_version)

        echo "=========================================="
        echo "   Xray-Reality + Caddy 一体化管理后台    "
        echo "=========================================="
        echo -e "版本信息 : 脚本 \033[1;36mv${SCRIPT_VERSION}\033[0m | Xray \033[1;32mv${core_v#v}\033[0m | Caddy \033[1;35m${caddy_v}\033[0m"
        echo -e "Xray 状态: $(get_xray_status)"
        echo -e "Caddy状态: $(get_caddy_status)"
        echo "------------------------------------------"
        echo " 1. 重启 Xray & Caddy"
        echo " 2. 启动 Xray & Caddy"
        echo " 3. 停止 Xray & Caddy"
        echo " 4. 查看节点链接与 Caddy 防护配置"
        echo " 5. 修改 Xray 节点配置 (端口/UUID/密钥/SNI/回环域名)"
        echo " 6. 修改 Caddy 网站配置 (域名/暗号/Key前缀/反代端口)"
        echo " 7. TCP BBR 加速与网络调优"
        echo " 8. 检查与升级 (Xray / Caddy / 管理脚本)"
        echo " 9. 查看运行日志 (Xray / Caddy)"
        echo "10. 彻底卸载"
        echo " 0. 退出菜单"
        echo "=========================================="
        read -p "请输入选项 [0-10]: " choice </dev/tty
        case "$choice" in
            1) restart_all ;;
            2) start_all ;;
            3) stop_all ;;
            4) show_info ;;
            5) modify_xray_config ;;
            6) modify_caddy_config ;;
            7) manage_bbr ;;
            8) update_menu ;;
            9) show_logs ;;
            10) uninstall_all ;;
            0) clear; exit 0 ;;
            *) echo -e "\033[31m无效输入！\033[0m"; sleep 1 ;;
        esac
    done
}

main_menu
EOF_MANAGEMENT_SCRIPT
    chmod +x /usr/local/bin/xray
}

# ------------------------------------------------------------------------------
# 3. 脚本主安装 / 升级执行入口
# ------------------------------------------------------------------------------
install_dependencies
install_caddy

if is_config_complete; then
    echo "=========================================================="
    echo -e "\033[32m✔ 检测到本机已存在完整的 Reality + Caddy 配置！\033[0m"
    echo "=========================================================="
    source "$ENV_FILE"
    LOCAL_LOOPBACK_ENABLED="${LOCAL_LOOPBACK_ENABLED:-0}"
    LOCAL_LOOPBACK_DOMAIN="${LOCAL_LOOPBACK_DOMAIN:-}"
    echo "  - Reality 端口: $PORT"
    echo "  - 网站域名 / SNI: $CADDY_DOMAIN ($DEST_SNI)"
    echo "  - 访问暗号 secret: $CADDY_SECRET"
    echo "  - API Key 前缀: ${CADDY_KEY_PREFIX}*"
    echo "  - 后端反代端口: $BACKEND_PORT"
    echo "----------------------------------------------------------"

    if [ "$1" = "--auto-upgrade" ]; then
        mode_choice=1
    else
        echo "请选择运行模式："
        echo "  1. 保留现有配置并升级 (刷新脚本与网络调优)"
        echo "  2. 重新配置 (重新输入域名/暗号/Key前缀，生成新 UUID 及密钥)"
        echo "----------------------------------------------------------"
        read -p "请输入选项 [1-2] (默认 1): " mode_choice </dev/tty
        mode_choice=${mode_choice:-1}
    fi

    if [ "$mode_choice" = "1" ]; then
        echo -e "\n⏳ 正在执行平滑升级..."
        write_management_cli
        clean_traffic_cron
        optimize_network
        if [ "$1" != "--auto-upgrade" ]; then
            install_xray_core
        fi
        save_params_env
        systemctl stop xray 2>/dev/null || true
        render_caddyfile || exit 1
        render_config_json
        write_service
        update_links_info
        echo -e "\033[32m🎉 升级完成！在终端直接输入 \033[1;33mxray\033[32m 即可打开管理后台。\033[0m\n"
        exit 0
    fi
fi

# 全新部署 / 从旧版迁移流程
echo -e "\n====================================="
echo "开始 Reality + Caddy 部署流程..."
echo "====================================="
install_xray_core
optimize_network

# 避免旧 xray 占着 443 影响后续端口切换
systemctl stop xray 2>/dev/null || true

# 若存在旧 reality.sh 的 UUID 与密钥，询问是否复用
REUSE_KEYS="n"
if [ -f "$ENV_FILE" ]; then
    eval "$(grep -E '^(UUID_DIRECT|PUBLIC_KEY|PRIVATE_KEY|SHORT_ID)=' "$ENV_FILE" 2>/dev/null)"
    if [ -n "$UUID_DIRECT" ] && [ -n "$PRIVATE_KEY" ] && [ -n "$PUBLIC_KEY" ] && [ -n "$SHORT_ID" ]; then
        read -p "检测到本机已有 Xray UUID 与 Reality 密钥，是否保留复用？[Y/n]: " REUSE_KEYS </dev/tty
        REUSE_KEYS=${REUSE_KEYS:-y}
    fi
fi

if [[ ! "$REUSE_KEYS" =~ ^[yY]$ ]]; then
    UUID_DIRECT=$($XRAY_BIN uuid)
    KEYS=$($XRAY_BIN x25519)
    PRIVATE_KEY=$(echo "$KEYS" | awk '/^PrivateKey:/ {print $2}')
    PUBLIC_KEY=$(echo "$KEYS" | awk '/PublicKey|Password/ {print $NF}')
    if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
        echo "❌ 密钥解析失败，xray x25519 输出格式无法识别："
        echo "$KEYS"
        exit 1
    fi
    SHORT_ID=$(openssl rand -hex 8)
fi

PORT=443
LOCAL_LOOPBACK_ENABLED="0"
LOCAL_LOOPBACK_DOMAIN=""
prompt_caddy_params

save_params_env
render_caddyfile || exit 1
wait_caddy_tls_ready
render_config_json
write_service
clean_traffic_cron
write_management_cli
update_links_info

cat "$LINK_FILE"
echo -e "\033[36m💡 部署完成！以后在终端输入 \033[1;33mxray\033[0;36m 即可随时修改 Reality 与 Caddy 配置。\033[0m\n"
