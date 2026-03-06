#!/bin/sh
# ==============================================================
#  entrypoint.sh — 容器启动入口
#  1. 首次运行时调用 docker-init.sh 安装依赖
#  2. 创建模拟网络接口（与真实路由器拓扑一致）
#  3. 配置 UCI 网络（lan / wan / wan_6 / wg0）
#  4. 自动加载 /luci-plugins/luci-app-* 下的所有插件
#  5. 启动 uhttpd / sshd / rpcd 等服务
# ==============================================================

set -e

echo "========================================================"
echo " OpenWrt LuCI DevBox — 启动中"
echo "========================================================"

# ================================================================
# 1. 首次初始化（安装包）
# ================================================================
mkdir -p /var/lock /var/run /var/log /tmp/run
/bin/sh /docker-init.sh

# ================================================================
# 2. 模拟网络接口
#    目标：在容器内创建与截图中真实路由器一致的接口结构
#      - br-lan  (网桥，静态地址，对应 LAN)
#      - eth0    (已由 Docker 提供，作为 br-lan 成员或独立使用)
#      - pppoe-wan (隧道设备，模拟 PPPoE WAN)
#      - wg0     (WireGuard VPN，10.10.58.1/24)
#      - utun    (TUN 设备，供 phantun/udp2raw 等使用)
# ================================================================

echo "[net] 创建模拟网络接口..."

# ── 加载必要内核模块（如果宿主机支持）──
modprobe wireguard 2>/dev/null && echo "[net] ✅ WireGuard 内核模块已加载" \
    || echo "[net] ⚠️  WireGuard 内核模块不可用（宿主机不支持），wg0 将用 dummy 替代"
modprobe tun 2>/dev/null && echo "[net] ✅ TUN 模块已加载" || true
modprobe dummy 2>/dev/null && echo "[net] ✅ dummy 模块已加载" || true

# ── 创建 br-lan（网桥）──
if ! ip link show br-lan > /dev/null 2>&1; then
    ip link add name br-lan type bridge 2>/dev/null \
        && echo "[net] 创建 br-lan (bridge)" \
        || echo "[net] br-lan 创建失败，跳过"
fi
ip link set br-lan up 2>/dev/null || true
ip addr add 192.168.1.1/24 dev br-lan 2>/dev/null || true

# ── 创建 wg0（WireGuard，10.10.58.1/24）──
if ! ip link show wg0 > /dev/null 2>&1; then
    # 优先尝试 wireguard 类型
    if ip link add dev wg0 type wireguard 2>/dev/null; then
        echo "[net] ✅ 创建 wg0 (wireguard)"
    else
        # 回退：用 dummy 设备模拟接口（UI 展示不受影响）
        ip link add dev wg0 type dummy 2>/dev/null \
            && echo "[net] ⚠️  wg0 用 dummy 类型替代（WireGuard 模块不可用）" \
            || echo "[net] wg0 创建失败，跳过"
    fi
fi
ip link set wg0 up 2>/dev/null || true
ip addr add 10.10.58.1/24 dev wg0 2>/dev/null || true

# ── 创建 pppoe-wan（dummy 模拟 PPPoE 隧道接口）──
if ! ip link show pppoe-wan > /dev/null 2>&1; then
    ip link add dev pppoe-wan type dummy 2>/dev/null \
        && echo "[net] 创建 pppoe-wan (dummy)" \
        || echo "[net] pppoe-wan 创建失败，跳过"
fi
ip link set pppoe-wan up 2>/dev/null || true

# ── 创建 utun（TUN 设备，供 phantun 等使用）──
if ! ip link show utun > /dev/null 2>&1; then
    ip tuntap add dev utun mode tun 2>/dev/null \
        && echo "[net] 创建 utun (tun)" \
        || echo "[net] utun 创建失败，跳过"
fi
ip link set utun up 2>/dev/null || true

# ================================================================
# 3. 配置 UCI 网络接口定义
#    让 LuCI 能正确识别和展示接口（与真实路由器截图一致）
# ================================================================

echo "[uci] 配置网络接口..."

# ── LAN ──
uci -q set network.lan=interface
uci set network.lan.proto='static'
uci set network.lan.device='br-lan'
uci set network.lan.ipaddr='192.168.1.1'
uci set network.lan.netmask='255.255.255.0'

# ── WAN（PPPoE 模拟）──
uci -q set network.wan=interface
uci set network.wan.proto='pppoe'
uci set network.wan.device='eth0'
# 模拟 PPPoE 拨号参数（不会真实拨号，仅供 UI 展示）
uci set network.wan.username='test@isp.example'
uci set network.wan.password='testpassword'

# ── WAN6（虚拟 DHCPv6 客户端）──
uci -q set network.wan_6=interface
uci set network.wan_6.proto='dhcpv6'
uci set network.wan_6.device='@wan'

# ── WireGuard VPN 接口 ──
uci -q set network.wg0=interface
uci set network.wg0.proto='wireguard'
uci set network.wg0.private_key="$(wg genkey 2>/dev/null || echo 'PLACEHOLDER_PRIVATE_KEY_BASE64=')"
uci set network.wg0.listen_port='51820'
uci add_list network.wg0.addresses='10.10.58.1/24'

# ── loopback ──
uci -q set network.loopback=interface
uci set network.loopback.proto='static'
uci set network.loopback.device='lo'
uci set network.loopback.ipaddr='127.0.0.1'
uci set network.loopback.netmask='255.0.0.0'

uci commit network
echo "[uci] ✅ UCI 网络配置已写入"

# ================================================================
# 4. 自动加载插件
#    扫描 /luci-plugins/luci-app-* 并创建符号链接
# ================================================================

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

    # Controller 文件
    if [ -d "$plugin_dir/luasrc/controller" ]; then
        for f in "$plugin_dir/luasrc/controller/"*.lua; do
            [ -f "$f" ] || continue
            fname=$(basename "$f")
            target="$LUCI_CTRL/$fname"
            [ -L "$target" ] || ln -sf "$f" "$target"
        done
    fi

    # View 目录
    if [ -d "$plugin_dir/luasrc/view" ]; then
        for d in "$plugin_dir/luasrc/view/"/*/; do
            [ -d "$d" ] || continue
            dname=$(basename "$d")
            target="$LUCI_VIEW/$dname"
            [ -L "$target" ] || ln -sf "$d" "$target"
        done
        # 直接在 view 根下的 .htm 文件
        for f in "$plugin_dir/luasrc/view/"*.htm; do
            [ -f "$f" ] || continue
            fname=$(basename "$f")
            target="$LUCI_VIEW/$fname"
            [ -L "$target" ] || ln -sf "$f" "$target"
        done
    fi

    # Model/CBI 文件
    if [ -d "$plugin_dir/luasrc/model/cbi" ]; then
        for f in "$plugin_dir/luasrc/model/cbi/"*.lua; do
            [ -f "$f" ] || continue
            fname=$(basename "$f")
            target="$LUCI_MODEL/$fname"
            [ -L "$target" ] || ln -sf "$f" "$target"
        done
    fi

    # root/ 目录覆盖（系统配置文件、init.d 脚本等）
    if [ -d "$plugin_dir/root" ]; then
        cp -rl "$plugin_dir/root/." / 2>/dev/null || \
        cp -r  "$plugin_dir/root/." / 2>/dev/null || true
    fi

    # 如果插件有 init.d 脚本，注册启动
    if [ -d "$plugin_dir/root/etc/init.d" ]; then
        for initf in "$plugin_dir/root/etc/init.d/"*; do
            [ -f "$initf" ] || continue
            svc=$(basename "$initf")
            chmod +x "/etc/init.d/$svc" 2>/dev/null || true
        done
    fi
done

echo "[plugin] ✅ 插件加载完毕"

# ================================================================
# 5. 启动系统服务
# ================================================================

echo "[service] 启动服务..."

# rpcd（LuCI 后端 RPC 守护进程）
if [ -x /sbin/rpcd ] || [ -x /usr/sbin/rpcd ]; then
    rpcd -s /var/run/ubus.sock &
    sleep 1
fi

# ubusd
if [ -x /sbin/ubusd ]; then
    ubusd &
    sleep 1
fi

# netifd（网络接口守护进程，让 UCI 生效）
if [ -x /sbin/netifd ]; then
    /sbin/netifd &
    sleep 2
fi

# SSH（守护进程模式）
if [ -x /usr/sbin/sshd ]; then
    mkdir -p /var/run/sshd
    # 生成宿主密钥（如果不存在）
    [ -f /etc/ssh/ssh_host_rsa_key ] || ssh-keygen -A 2>/dev/null || true
    /usr/sbin/sshd &
    echo "[service] ✅ sshd 已启动（端口 22 → 宿主机 2222）"
fi

# uhttpd（LuCI Web 服务器，前台运行保持容器存活）
echo "[service] 启动 uhttpd（LuCI Web 端口 80 → 宿主机 8080）..."
echo "[service] ✅ LuCI 就绪 → http://localhost:8080  (root/password)"
echo "========================================================"

exec /usr/sbin/uhttpd -f \
    -h /www \
    -l 0.0.0.0:80 \
    -L /usr/share/uhttpd/lua.sh \
    -u /ubus \
    -x /cgi-bin \
    -t 60 \
    -T 30 \
    2>&1
