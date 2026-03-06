#!/bin/bash
# ==============================================================
#  dev.sh — 开发辅助脚本
#  用法: ./dev.sh <命令> [参数]
# ==============================================================

CONTAINER_SINGLE="openwrt-luci-devbox"
CONTAINER_SERVER="openwrt-server"
CONTAINER_PEER="openwrt-peer"
PLUGIN_DIR="./plugins"

# 颜色输出
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
ok()   { echo -e "${GREEN}✅ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $*${NC}"; }
err()  { echo -e "${RED}❌ $*${NC}"; }

# ----------------------------------------------------------------
#  内部辅助
# ----------------------------------------------------------------
detect_mode() {
    if docker ps --filter "name=^${CONTAINER_SERVER}$" --filter "status=running" -q | grep -q .; then
        echo dual
    elif docker ps --filter "name=^${CONTAINER_SINGLE}$" --filter "status=running" -q | grep -q .; then
        echo single
    else
        echo none
    fi
}

primary_container() {
    case "$(detect_mode)" in
        dual) echo "$CONTAINER_SERVER" ;;
        single) echo "$CONTAINER_SINGLE" ;;
        *) return 1 ;;
    esac
}

container_running() {
    primary_container >/dev/null 2>&1
}

exec_in() {
    local c
    c="$(primary_container)" || return 1
    docker exec -it "$c" "$@"
}

require_running() {
    if ! container_running; then
        err "容器未运行，请先执行: docker compose up -d 或 docker compose -f docker-compose.dual.yml up -d"
        exit 1
    fi
}

# ----------------------------------------------------------------
#  命令实现
# ----------------------------------------------------------------

cmd_status() {
    local mode c
    mode="$(detect_mode)"
    echo "=== 运行模式 ==="
    echo "$mode"
    echo ""
    echo "=== 容器状态 ==="
    docker ps --format "{{.Names}} | {{.Status}} | {{.Ports}}" | grep -E "^(openwrt-luci-devbox|openwrt-server|openwrt-peer) \|" || true
    echo ""
    c="$(primary_container 2>/dev/null)" || { warn "容器未运行"; return 0; }
    echo "=== 主容器网络接口 ($c) ==="
    docker exec "$c" ip -br link 2>/dev/null || warn "容器未运行"
    echo ""
    echo "=== 主容器 WireGuard ($c) ==="
    docker exec "$c" wg show 2>/dev/null || warn "wg 命令不可用或无 WireGuard 接口"
    if [ "$mode" = "dual" ]; then
        echo ""
        echo "=== peer 网络接口 ($CONTAINER_PEER) ==="
        docker exec "$CONTAINER_PEER" ip -br link 2>/dev/null || true
    fi
}

cmd_list() {
    require_running
    local c
    c="$(primary_container)"
    echo "=== 已加载的插件 ($c) ==="
    docker exec "$c" ls /luci-plugins/ 2>/dev/null | grep "^luci-app-" | while read -r p; do
        echo "  📦 $p"
    done
    echo ""
    echo "=== Controller 链接 ==="
    docker exec "$c" ls /usr/lib/lua/luci/controller/ 2>/dev/null
}

cmd_reload() {
    require_running
    local c pid
    c="$(primary_container)"
    echo "重载 uhttpd + 清除 LuCI 缓存 ($c)..."
    docker exec "$c" rm -rf /tmp/luci-* /tmp/lua-* /tmp/*.luac 2>/dev/null || true
    pid="$(docker exec "$c" pidof uhttpd 2>/dev/null || true)"
    if [ -n "$pid" ]; then
        docker exec "$c" kill -HUP "$pid" 2>/dev/null || docker exec "$c" /etc/init.d/uhttpd restart 2>/dev/null || warn "uhttpd 重启失败，请手动检查"
    else
        docker exec "$c" /etc/init.d/uhttpd restart 2>/dev/null || warn "uhttpd 未运行或重启失败，请手动检查"
    fi
    ok "已重载，刷新浏览器即可看到最新变更"
}

cmd_ssh() {
    require_running
    local target="${1:-server}"
    local port
    case "$target" in
        server) port=2222 ;;
        peer) port=2223 ;;
        *) err "用法: ./dev.sh ssh [server|peer]"; exit 1 ;;
    esac
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -p "$port" root@localhost
}

cmd_log() {
    local mode
    mode="$(detect_mode)"
    case "$mode" in
        dual)
            docker logs -f --tail=100 "$CONTAINER_SERVER" &
            docker logs -f --tail=100 "$CONTAINER_PEER"
            ;;
        single)
            docker logs -f --tail=100 "$CONTAINER_SINGLE"
            ;;
        *) err "容器未运行"; exit 1 ;;
    esac
}

cmd_shell() {
    require_running
    local c
    c="$(primary_container)"
    docker exec -it "$c" /bin/bash 2>/dev/null || docker exec -it "$c" /bin/ash
}

cmd_wg_genkey() {
    # 在主容器内生成 WireGuard 密钥对并打印（方便配置 peer）
    require_running
    local c
    c="$(primary_container)"
    echo "=== 生成 WireGuard 密钥对 ($c) ==="
    PRIVKEY=$(docker exec "$c" wg genkey 2>/dev/null)
    PUBKEY=$(printf '%s\n' "$PRIVKEY" | docker exec -i "$c" wg pubkey 2>/dev/null)
    echo "PrivateKey = $PRIVKEY"
    echo "PublicKey  = $PUBKEY"
}

cmd_wg_qr() {
    # 生成 WireGuard 客户端配置二维码
    require_running
    local c peer_name
    c="$(primary_container)"
    peer_name="${1:-peer1}"
    echo "=== 生成 $peer_name 的 WireGuard 配置二维码 ($c) ==="
    PEER_PRIVKEY=$(docker exec "$c" wg genkey)
    PEER_PUBKEY=$(printf '%s\n' "$PEER_PRIVKEY" | docker exec -i "$c" wg pubkey)
    SERVER_PUBKEY=$(docker exec "$c" wg show wg0 public-key 2>/dev/null || echo "SERVER_PUB_KEY")
    
    CONFIG=$(cat << EOF
[Interface]
PrivateKey = ${PEER_PRIVKEY}
Address = 10.10.58.100/24
DNS = 1.1.1.1

[Peer]
PublicKey = ${SERVER_PUBKEY}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = YOUR_SERVER_IP:51820
PersistentKeepalive = 25
EOF
)
    printf '%s\n' "$CONFIG" | docker exec -i "$c" qrencode -t ANSIUTF8
    echo ""
    echo "--- 文本配置 ---"
    echo "$CONFIG"
}

cmd_net_status() {
    # 显示容器内完整网络状态（适合调试网络层插件）
    require_running
    echo "=== IP 地址 ==="
    exec_in ip addr
    echo ""
    echo "=== 路由表 ==="
    exec_in ip route
    echo ""
    echo "=== iptables 规则 ==="
    exec_in iptables -L -n -v 2>/dev/null || warn "iptables 不可用"
    echo ""
    echo "=== nftables 规则 ==="
    exec_in nft list ruleset 2>/dev/null || warn "nftables 不可用"
}

cmd_push() {
    local plugin="${1}"
    [ -z "$plugin" ] && { err "用法: ./dev.sh push <插件名>"; exit 1; }
    local plugin_path="$PLUGIN_DIR/$plugin"
    [ -d "$plugin_path" ] || { err "插件目录不存在: $plugin_path"; exit 1; }
    
    cd "$PLUGIN_DIR" || exit 1
    if git diff --quiet HEAD -- "$plugin" 2>/dev/null; then
        warn "$plugin 没有未提交的变更"
    else
        git add "$plugin"
        git commit -m "feat($plugin): update plugin"
        git push origin HEAD
        ok "已推送 $plugin"
    fi
    cd - > /dev/null
}

cmd_push_all() {
    cd "$PLUGIN_DIR" || exit 1
    if git diff --quiet HEAD 2>/dev/null; then
        warn "没有未提交的变更"
    else
        git add -A
        git commit -m "chore: update plugins"
        git push origin HEAD
        ok "已推送所有变更"
    fi
    cd - > /dev/null
}

cmd_reinit() {
    # 强制重新安装所有包
    require_running
    local mode c
    mode="$(detect_mode)"
    warn "将强制重新初始化容器（重新安装所有包）..."
    if [ "$mode" = "dual" ]; then
        for c in "$CONTAINER_SERVER" "$CONTAINER_PEER"; do
            docker exec "$c" rm -f /etc/.devbox-initialized
            docker restart "$c" >/dev/null
        done
        ok "双容器已重启，正在重新初始化（请等待约 2 分钟）"
        docker logs -f "$CONTAINER_SERVER"
    else
        c="$(primary_container)"
        docker exec "$c" rm -f /etc/.devbox-initialized
        docker restart "$c" >/dev/null
        ok "容器已重启，正在重新初始化（请等待约 2 分钟）"
        docker logs -f "$c"
    fi
}

# ----------------------------------------------------------------
#  帮助
# ----------------------------------------------------------------
cmd_help() {
    cat << 'HELP'
用法: ./dev.sh <命令> [参数]

容器管理:
  status        显示容器状态和网络接口
  log           查看容器日志 (实时)
  shell         进入容器 shell
  ssh [目标]    SSH 登录容器，目标为 server|peer（默认 server）
  reinit        强制重新安装所有包（更新后使用）

插件开发:
  list          列出已加载的插件
  reload        重载 uhttpd（修改代码后执行）

WireGuard:
  wg-genkey     生成 WireGuard 密钥对
  wg-qr [名称]  生成客户端配置二维码

网络调试:
  net-status    显示完整网络状态（ip/iptables/nftables）

代码提交:
  push <插件名> 推送单个插件到 GitHub
  push-all      推送所有有变更的插件

访问地址:
  LuCI Web  http://localhost:8080         (root/password, server)
  SSH       ssh root@localhost -p 2222    (server)
            ssh root@localhost -p 2223    (peer, dual mode)
HELP
}

# ----------------------------------------------------------------
#  入口分发
# ----------------------------------------------------------------
case "${1:-help}" in
    status)     cmd_status ;;
    list)       cmd_list ;;
    reload)     cmd_reload ;;
    ssh)        cmd_ssh ;;
    log)        cmd_log ;;
    shell)      cmd_shell ;;
    wg-genkey)  cmd_wg_genkey ;;
    wg-qr)      cmd_wg_qr "${2}" ;;
    net-status) cmd_net_status ;;
    push)       cmd_push "${2}" ;;
    push-all)   cmd_push_all ;;
    reinit)     cmd_reinit ;;
    help|--help|-h) cmd_help ;;
    *)
        err "未知命令: $1"
        cmd_help
        exit 1
        ;;
esac
