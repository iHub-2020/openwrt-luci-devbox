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
/bin/ash /docker-init.sh

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
    # 不要接管 Docker 分配给容器管理面的 eth0，否则会打断宿主机 -> 容器端口映射。
    # 用我们自己创建的 dummy 设备承载 PPPoE 测试语义，保留 UI/协议对象，又不影响 LuCI/SSH 暴露。
    uci set network.wan.device='pppoe-wan'
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
    LUCI_JS_VIEW="/www/luci-static/resources/view"
    mkdir -p "$LUCI_CTRL" "$LUCI_VIEW" "$LUCI_MODEL" "$LUCI_JS_VIEW"

    # 仅保留本轮允许的 phantun 前端，先清理越权残留，避免“脚本没加载但运行态还在”。
    rm -f \
        /usr/share/luci/menu.d/luci-app-poweroffdevice.json \
        /usr/share/rpcd/acl.d/luci-app-poweroffdevice.json \
        /usr/share/luci/menu.d/luci-app-udp-tunnel.json \
        /usr/share/rpcd/acl.d/luci-app-udp-tunnel.json \
        /usr/share/luci/menu.d/luci-app-udp-speeder.json \
        /usr/share/rpcd/acl.d/luci-app-udp-speeder.json 2>/dev/null || true
    rm -rf \
        /www/luci-static/resources/view/udp2raw \
        /www/luci-static/resources/view/udpspeeder \
        /www/luci-static/resources/view/poweroffdevice 2>/dev/null || true

    for plugin_dir in "$PLUGIN_ROOT"/luci-app-*/; do
        [ -d "$plugin_dir" ] || continue
        plugin_name=$(basename "$plugin_dir")

        case "$plugin_name" in
            luci-app-phantun)
                ;;
            *)
                echo "[plugin] 跳过 $plugin_name（超出当前 phantun 验收范围）"
                continue
                ;;
        esac

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

        # New-style JS LuCI views (24.10 常见)
        if [ -d "$plugin_dir/htdocs/luci-static/resources/view" ]; then
            for d in "$plugin_dir/htdocs/luci-static/resources/view/"/*/; do
                [ -d "$d" ] || continue
                ln -snf "$d" "$LUCI_JS_VIEW/$(basename "$d")" 2>/dev/null || true
            done
        fi

        if [ -d "$plugin_dir/root" ]; then
            cp -r "$plugin_dir/root/." / 2>/dev/null || true
        fi
    done

    if [ -f /etc/uci-defaults/40_luci-app-phantun ] && [ ! -f /etc/config/phantun ]; then
        echo "[plugin] 初始化 phantun 默认配置"
        /bin/sh /etc/uci-defaults/40_luci-app-phantun 2>/dev/null || true
    fi

    echo "[plugin] ✅ 插件加载完毕"
fi

patch_luci_templates_for_devbox() {
    for f in \
        /usr/share/ucode/luci/template/themes/bootstrap/header.ut \
        /usr/share/ucode/luci/template/themes/bootstrap-light/header.ut \
        /usr/share/ucode/luci/template/themes/bootstrap-dark/header.ut; do
        [ -f "$f" ] || continue

        # OpenWrt 24.10 在当前 devbox 这种精简/非 procd 完整引导环境里，
        # ubus.call('system', 'board') 可能返回空值，默认模板会在登录页直接 500。
        # 这里做幂等兼容补丁：空值时退化为 {}，并把用户可见品牌稳定回退到 OpenWrt。
        sed -i "s/const boardinfo = ubus.call('system', 'board');/const boardinfo = ubus.call('system', 'board') || {};/" "$f" 2>/dev/null || true
        sed -i 's#<title>{{ striptags(`${boardinfo.hostname ?? '\''?'\''}${node ? ` - ${node.title}` : '\''''\''}`) }} - LuCI</title>#<title>{{ striptags(`${boardinfo.release?.distribution ?? boardinfo.hostname ?? '\''OpenWrt'\''}${node ? ` - ${node.title}` : '\''''\''}`) }} - LuCI</title>#' "$f" 2>/dev/null || true
        sed -i 's#<a class="brand" href="/">{{ striptags(boardinfo.hostname ?? '\''?'\'') }}</a>#<a class="brand" href="/">{{ striptags(boardinfo.release?.distribution ?? boardinfo.hostname ?? '\''OpenWrt'\'') }}</a>#' "$f" 2>/dev/null || true
    done
}

run_startup_selfcheck() {
    local i
    [ "$ROLE" = "server" ] || return 0
    [ -f /devbox-selfcheck.sh ] || return 0

    echo "[selfcheck] 执行启动后自检..."
    for i in 1 2 3 4 5; do
        if /bin/ash /devbox-selfcheck.sh --startup; then
            return 0
        fi
        echo "[selfcheck] 第 ${i} 次失败，2s 后重试..."
        sleep 2
    done

    echo "[selfcheck] 启动自检失败，保留容器供排障；Docker healthcheck 将继续阻止其进入 healthy。" >&2
    /bin/ash /devbox-selfcheck.sh --evidence || true
    return 0
}

seed_phantun_runtime() {
    local runtime_root
    runtime_root="/luci-plugins/phantun/files"
    [ -d "$runtime_root" ] || return 0

    if [ -f "$runtime_root/usr/bin/phantun_client" ] && [ ! -x /usr/bin/phantun_client ]; then
        echo "[phantun] 安装 phantun_client 运行时"
        cp "$runtime_root/usr/bin/phantun_client" /usr/bin/phantun_client
        chmod 0755 /usr/bin/phantun_client
    fi

    if [ -f "$runtime_root/usr/bin/phantun_server" ] && [ ! -x /usr/bin/phantun_server ]; then
        echo "[phantun] 安装 phantun_server 运行时"
        cp "$runtime_root/usr/bin/phantun_server" /usr/bin/phantun_server
        chmod 0755 /usr/bin/phantun_server
    fi

    if [ -f "$runtime_root/phantun.init" ] && [ ! -f /etc/init.d/phantun ]; then
        echo "[phantun] 安装 init 脚本"
        cp "$runtime_root/phantun.init" /etc/init.d/phantun
        chmod 0755 /etc/init.d/phantun
    fi

    if [ -f "$runtime_root/phantun.upgrade" ] && [ ! -f /usr/share/phantun/phantun.upgrade ]; then
        mkdir -p /usr/share/phantun
        cp "$runtime_root/phantun.upgrade" /usr/share/phantun/phantun.upgrade
        chmod 0755 /usr/share/phantun/phantun.upgrade
    fi
}

if [ "$ROLE" = "server" ]; then
    patch_luci_templates_for_devbox
    seed_phantun_runtime
fi

# ================================================================
# 7. 启动系统服务
# ================================================================
echo "[service] 启动服务..."

# ubusd / procd / rpcd
UBUS_DIR="/var/run/ubus"
UBUS_SOCK="$UBUS_DIR/ubus.sock"
mkdir -p "$UBUS_DIR"
if [ -x /sbin/ubusd ]; then
    ubusd -s "$UBUS_SOCK" &
    sleep 1
    ln -snf "$UBUS_SOCK" /var/run/ubus.sock
fi

# procd 提供 system ubus 对象；没有它，System 页面和 header board 信息都会残缺。
if [ -x /sbin/procd ] && ! pgrep -x procd >/dev/null 2>&1; then
    /sbin/procd -s "$UBUS_SOCK" &
    sleep 2
fi

if [ -x /sbin/rpcd ]; then
    /sbin/rpcd -s "$UBUS_SOCK" &
    sleep 1
elif [ -x /usr/sbin/rpcd ]; then
    /usr/sbin/rpcd -s "$UBUS_SOCK" &
    sleep 1
fi

# netifd
[ -x /sbin/netifd ] && { /sbin/netifd & sleep 2; }

# SSH（两种角色都启动，方便进容器调试）
if [ -x /usr/sbin/sshd ]; then
    mkdir -p /var/run/sshd
    [ -f /etc/ssh/sshd_config ] && sed -i '/^UsePAM[[:space:]]\+/d' /etc/ssh/sshd_config
    [ -f /etc/ssh/ssh_host_rsa_key ] || ssh-keygen -A 2>/dev/null || true
    /usr/sbin/sshd &
    echo "[service] ✅ sshd 已启动"
fi

# ================================================================
# 8. 根据角色决定前台进程
# ================================================================
if [ "$ROLE" = "server" ]; then
    echo "[service] 启动 uhttpd（LuCI Web → http://localhost:8080）..."
    set -- /usr/sbin/uhttpd -f -h /www -p 0.0.0.0:80 -x /cgi-bin -u /ubus -t 60 -T 30

    # LuCI 24.10 默认优先走 ucode handler
    if [ -f /usr/lib/uhttpd_ucode.so ] && [ -f /usr/share/ucode/luci/uhttpd.uc ]; then
        set -- "$@" -o /cgi-bin/luci -O /usr/share/ucode/luci/uhttpd.uc
    fi

    # 兼容仍依赖 Lua handler 的场景
    if [ -f /usr/lib/uhttpd_lua.so ] && [ -f /usr/lib/lua/luci/sgi/uhttpd.lua ]; then
        set -- "$@" -l /cgi-bin/luci -L /usr/lib/lua/luci/sgi/uhttpd.lua
    fi

    echo "[service] ✅ 就绪 (root/password)"
    echo "========================================================"

    "$@" &
    UHTTPD_PID=$!
    sleep 2
    run_startup_selfcheck
    wait "$UHTTPD_PID"
else
    # peer 模式：没有 LuCI，用 tail 保持容器存活
    echo "[service] peer 容器就绪（无 LuCI，仅 SSH 端口 2223）"
    echo "[service] 进入对端调试：docker exec -it openwrt-peer /bin/ash"
    echo "========================================================"
    exec tail -f /dev/null
fi
