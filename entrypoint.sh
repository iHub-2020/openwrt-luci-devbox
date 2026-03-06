#!/bin/sh
# ==============================================================
#  entrypoint.sh — 容器启动入口
#
#  支持两种运行模式（由环境变量 DEVBOX_ROLE 区分）：
#    server（默认）：路由器/服务端角色，启动 LuCI + SSH
#    peer           ：对端/客户端角色，只启动 SSH，用于流量对打
#
#  环境变量：
#    DEVBOX_ROLE      = server | peer   （默认 server）
#    WG_ADDR          = 10.10.58.1/24   （wg0 地址）
#    WG_LISTEN_PORT   = 51820
#    WG_SERVER_IP     = 172.30.0.10     （peer 模式下 server 的 IP）
#    FORCE_REINIT     = 0 | 1
# ==============================================================

set -e

ROLE="${DEVBOX_ROLE:-server}"
WG_ADDR="${WG_ADDR:-10.10.58.1/24}"
WG_LISTEN_PORT="${WG_LISTEN_PORT:-51820}"

echo "========================================================"
echo " OpenWrt LuCI DevBox — 启动中 [角色: $ROLE]"
echo "========================================================"

# ================================================================
# 1. 首次初始化（安装 opkg 包）
# ================================================================
mkdir -p /var/lock /var/run /var/log /tmp/run
/bin/sh /docker-init.sh

# ================================================================
# 2. 写入 UCI 配置模板（从挂载的 /config-templates/ 复制）
# ================================================================
if [ -d /config-templates ]; then
    for f in /config-templates/*; do
        fname=$(basename "$f")
        # init-firewall 是脚本，不是 UCI 配置，单独处理
        [ "$fname" = "init-firewall" ] && continue
        cp "$f" "/etc/config/$fname" 2>/dev/null && \
            echo "[config] 写入 /etc/config/$fname" || true
    done
fi

# ================================================================
# 3. 创建模拟网络接口
# ================================================================
echo "[net] 创建模拟网络接口（角色：$ROLE）..."

# 加载内核模块（由宿主机提供，失败不阻断启动）
modprobe wireguard 2>/dev/null && echo "[net] ✅ WireGuard 内核模块已加载" \
    || echo "[net] ⚠️  WireGuard 模块不可用，wg0 将用 dummy 替代"
modprobe tun   2>/dev/null || true
modprobe dummy 2>/dev/null || true

# ── br-lan（server 模式才需要）──
if [ "$ROLE" = "server" ]; then
    if ! ip link show br-lan > /dev/null 2>&1; then
        ip link add name br-lan type bridge 2>/dev/null || true
    fi
    ip link set br-lan up 2>/dev/null || true
    ip addr add 192.168.1.1/24 dev br-lan 2>/dev/null || true
fi

# ── wg0（两种角色都需要，地址由环境变量决定）──
if ! ip link show wg0 > /dev/null 2>&1; then
    ip link add dev wg0 type wireguard 2>/dev/null \
        || ip link add dev wg0 type dummy 2>/dev/null || true
fi
ip link set wg0 up 2>/dev/null || true
ip addr add "$WG_ADDR" dev wg0 2>/dev/null || true

# ── pppoe-wan（只有 server 模式需要模拟 WAN）──
if [ "$ROLE" = "server" ]; then
    if ! ip link show pppoe-wan > /dev/null 2>&1; then
        ip link add dev pppoe-wan type dummy 2>/dev/null || true
    fi
    ip link set pppoe-wan up 2>/dev/null || true
fi

# ── utun（两种角色都需要，phantun/udp2raw 使用）──
if ! ip link show utun > /dev/null 2>&1; then
    ip tuntap add dev utun mode tun 2>/dev/null || true
fi
ip link set utun up 2>/dev/null || true

# ================================================================
# 4. 写入 UCI 网络配置（覆盖模板中的占位符）
# ================================================================
echo "[uci] 配置网络接口..."

if [ "$ROLE" = "server" ]; then
    uci -q set network.lan=interface
    uci set network.lan.proto='static'
    uci set network.lan.device='br-lan'
    uci set network.lan.ipaddr='192.168.1.1'
    uci set network.lan.netmask='255.255.255.0'

    uci -q set network.wan=interface
    uci set network.wan.proto='pppoe'
    uci set network.wan.device='eth0'
    uci set network.wan.username='test@isp.example'
    uci set network.wan.password='testpassword'

    uci -q set network.wan_6=interface
    uci set network.wan_6.proto='dhcpv6'
    uci set network.wan_6.device='@wan'
fi

# wg0 两个角色都配置
WG_PRIVKEY=$(wg genkey 2>/dev/null || echo "PLACEHOLDER_KEY=")
uci -q set network.wg0=interface
uci set network.wg0.proto='wireguard'
uci set network.wg0.private_key="$WG_PRIVKEY"
uci set network.wg0.listen_port="$WG_LISTEN_PORT"
uci -q del network.wg0.addresses 2>/dev/null || true
uci add_list network.wg0.addresses="$WG_ADDR"

uci commit network
echo "[uci] ✅ UCI 网络配置完成"

# ================================================================
# 5. 应用额外防火墙规则
# ================================================================
if [ -f /config-templates/init-firewall ]; then
    sh /config-templates/init-firewall 2>/dev/null || true
fi

# ================================================================
# 6. 加载插件（仅 server 模式）
# ================================================================
if [ "$ROLE" = "server" ]; then
    echo "[plugin] 扫描并加载插件..."

    PLUGIN_ROOT="/luci-plugins"
    LUCI_CTRL="/usr/lib/lua/luci/controller"
    LUCI_VIEW="/usr/lib/lua/luci/view"
    LUCI_MODEL="/usr/lib/lua/luci/model/cbi"
    mkdir -p "$LUCI_CTRL" "$LUCI_VIEW" "$LUCI_MODEL"

    for plugin_dir in "$PLUGIN_ROOT"/luci-app-*/; do
        [ -d "$plugin_dir" ] || continue
        plugin_name=$(basename "$plugin_dir")
        echo "[plugin] 加载 $plugin_name"

        if [ -d "$plugin_dir/luasrc/controller" ]; then
            for f in "$plugin_dir/luasrc/controller/"*.lua; do
                [ -f "$f" ] || continue
                ln -sf "$f" "$LUCI_CTRL/$(basename "$f")" 2>/dev/null || true
            done
        fi

        if [ -d "$plugin_dir/luasrc/view" ]; then
            for d in "$plugin_dir/luasrc/view/"/*/; do
                [ -d "$d" ] || continue
                ln -sf "$d" "$LUCI_VIEW/$(basename "$d")" 2>/dev/null || true
            done
        fi

        if [ -d "$plugin_dir/luasrc/model/cbi" ]; then
            for f in "$plugin_dir/luasrc/model/cbi/"*.lua; do
                [ -f "$f" ] || continue
                ln -sf "$f" "$LUCI_MODEL/$(basename "$f")" 2>/dev/null || true
            done
        fi

        if [ -d "$plugin_dir/root" ]; then
            cp -r "$plugin_dir/root/." / 2>/dev/null || true
        fi
    done
    echo "[plugin] ✅ 插件加载完毕"
fi

# ================================================================
# 7. 启动系统服务
# ================================================================
echo "[service] 启动服务..."

# ubusd
[ -x /sbin/ubusd ] && { ubusd & sleep 1; }

# rpcd
[ -x /sbin/rpcd ] || [ -x /usr/sbin/rpcd ] && { rpcd -s /var/run/ubus.sock & sleep 1; }

# netifd
[ -x /sbin/netifd ] && { /sbin/netifd & sleep 2; }

# SSH（两种角色都启动，方便进容器调试）
if [ -x /usr/sbin/sshd ]; then
    mkdir -p /var/run/sshd
    [ -f /etc/ssh/ssh_host_rsa_key ] || ssh-keygen -A 2>/dev/null || true
    /usr/sbin/sshd &
    echo "[service] ✅ sshd 已启动"
fi

# ================================================================
# 8. 根据角色决定前台进程
# ================================================================
if [ "$ROLE" = "server" ]; then
    echo "[service] 启动 uhttpd（LuCI Web → http://localhost:8080）..."
    echo "[service] ✅ 就绪 (root/password)"
    echo "========================================================"
    exec /usr/sbin/uhttpd -f \
        -h /www \
        -l 0.0.0.0:80 \
        -L /usr/share/uhttpd/lua.sh \
        -u /ubus \
        -x /cgi-bin \
        -t 60 -T 30 2>&1
else
    # peer 模式：没有 LuCI，用 tail 保持容器存活
    echo "[service] peer 容器就绪（无 LuCI，仅 SSH 端口 2223）"
    echo "[service] 进入对端调试：docker exec -it openwrt-peer /bin/ash"
    echo "========================================================"
    exec tail -f /dev/null
fi
