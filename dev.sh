#!/bin/bash
# ==============================================================
#  dev.sh — 开发辅助脚本
#  用法: ./dev.sh <命令> [参数]
# ==============================================================

CONTAINER="openwrt-luci-devbox"
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
container_running() {
    docker ps --filter "name=^${CONTAINER}$" --filter "status=running" -q | grep -q .
}

exec_in() {
    docker exec -it "$CONTAINER" "$@"
}

require_running() {
    if ! container_running; then
        err "容器未运行，请先执行: docker compose up -d"
        exit 1
    fi
}

# ----------------------------------------------------------------
#  命令实现
# ----------------------------------------------------------------

cmd_status() {
    echo "=== 容器状态 ==="
    docker ps --filter "name=$CONTAINER" --format \
        "ID: {{.ID}}\n状态: {{.Status}}\n端口: {{.Ports}}"
    echo ""
    echo "=== 网络接口 ==="
    docker exec "$CONTAINER" ip -br link 2>/dev/null || warn "容器未运行"
    echo ""
    echo "=== WireGuard ==="
    docker exec "$CONTAINER" wg show 2>/dev/null || warn "wg 命令不可用或无 WireGuard 接口"
}

cmd_list() {
    require_running
    echo "=== 已加载的插件 ==="
    docker exec "$CONTAINER" ls /luci-plugins/ 2>/dev/null | grep "^luci-app-" | while read -r p; do
        echo "  📦 $p"
    done
    echo ""
    echo "=== Controller 链接 ==="
    docker exec "$CONTAINER" ls /usr/lib/lua/luci/controller/ 2>/dev/null
}

cmd_reload() {
    require_running
    echo "重载 uhttpd + 清除 LuCI 缓存..."
    exec_in rm -rf /tmp/luci-* /tmp/lua-* /tmp/*.luac 2>/dev/null || true
    exec_in kill -HUP "$(docker exec "$CONTAINER" pidof uhttpd 2>/dev/null)" 2>/dev/null \
        || exec_in /etc/init.d/uhttpd restart 2>/dev/null \
        || warn "uhttpd 重启失败，请手动检查"
    ok "已重载，刷新浏览器即可看到最新变更"
}

cmd_ssh() {
    require_running
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -p 2222 root@localhost
}

cmd_log() {
    docker logs -f --tail=100 "$CONTAINER"
}

cmd_shell() {
    require_running
    exec_in /bin/bash 2>/dev/null || exec_in /bin/ash
}

cmd_wg_genkey() {
    # 在容器内生成 WireGuard 密钥对并打印（方便配置 peer）
    require_running
    echo "=== 生成 WireGuard 密钥对 ==="
    PRIVKEY=$(exec_in wg genkey 2>/dev/null)
    PUBKEY=$(echo "$PRIVKEY" | exec_in wg pubkey 2>/dev/null)
    echo "PrivateKey = $PRIVKEY"
    echo "PublicKey  = $PUBKEY"
}

cmd_wg_qr() {
    # 生成 WireGuard 客户端配置二维码
    require_running
    local peer_name="${1:-peer1}"
    echo "=== 生成 $peer_name 的 WireGuard 配置二维码 ==="
    PEER_PRIVKEY=$(exec_in wg genkey)
    PEER_PUBKEY=$(echo "$PEER_PRIVKEY" | exec_in wg pubkey)
    SERVER_PUBKEY=$(exec_in wg show wg0 public-key 2>/dev/null || echo "SERVER_PUB_KEY")
    
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
    echo "$CONFIG" | exec_in qrencode -t ANSIUTF8
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
    warn "将强制重新初始化容器（重新安装所有包）..."
    docker exec "$CONTAINER" rm -f /etc/.devbox-initialized
    docker restart "$CONTAINER"
    ok "容器已重启，正在重新初始化（请等待约 2 分钟）"
    docker logs -f "$CONTAINER"
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
  ssh           SSH 登录容器 (root/password)
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
  LuCI Web  http://localhost:8080  (root/password)
  SSH       ssh root@localhost -p 2222
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
