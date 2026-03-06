#!/bin/sh
# ==============================================================
#  docker-init.sh — 容器首次启动时执行，安装所有依赖包
#  幂等：通过 /etc/.devbox-initialized 标记避免重复安装
# ==============================================================

INIT_MARKER="/etc/.devbox-initialized"
FORCE_REINIT="${FORCE_REINIT:-0}"

if [ -f "$INIT_MARKER" ] && [ "$FORCE_REINIT" != "1" ]; then
    echo "[init] 已初始化，跳过安装（如需重装请设置 FORCE_REINIT=1）"
    return 0
fi

echo "========================================================"
echo " OpenWrt 24.10 LuCI 开发环境初始化"
echo "========================================================"

# ----------------------------------------------------------------
# 配置 opkg 源（确保使用 24.10 稳定版仓库）
# ----------------------------------------------------------------
cat > /etc/opkg/distfeeds.conf << 'EOF'
src/gz openwrt_core https://downloads.openwrt.org/releases/24.10.3/targets/x86/64/packages
src/gz openwrt_base https://downloads.openwrt.org/releases/24.10.3/packages/x86_64/base
src/gz openwrt_luci https://downloads.openwrt.org/releases/24.10.3/packages/x86_64/luci
src/gz openwrt_packages https://downloads.openwrt.org/releases/24.10.3/packages/x86_64/packages
src/gz openwrt_routing https://downloads.openwrt.org/releases/24.10.3/packages/x86_64/routing
src/gz openwrt_telephony https://downloads.openwrt.org/releases/24.10.3/packages/x86_64/telephony
EOF

echo "[init] 更新包列表..."
opkg update 2>&1 | tail -5

# ----------------------------------------------------------------
# 基础系统包（SSH + LuCI Web 界面）
# ----------------------------------------------------------------
echo "[init] 安装基础系统包..."
opkg install \
    uhttpd uhttpd-mod-ubus \
    rpcd rpcd-mod-rpcsys rpcd-mod-file \
    luci-base luci-mod-admin-full \
    luci-theme-bootstrap \
    luci-app-firewall \
    luci-i18n-base-zh-cn \
    luci-i18n-firewall-zh-cn \
    openssh-server \
    curl wget-ssl \
    bash kmod-nft-core \
    2>&1 | grep -E "(Installing|Configuring|ERROR|error)" || true

# ----------------------------------------------------------------
# 网络工具（网络层插件开发必备）
# ----------------------------------------------------------------
echo "[init] 安装网络工具..."
opkg install \
    ip-full \
    iptables iptables-mod-extra iptables-mod-conntrack-extra \
    ip6tables \
    nftables kmod-nft-nat \
    tc-full \
    conntrack \
    ipset \
    socat \
    tcpdump \
    bind-dig \
    iproute2 \
    2>&1 | grep -E "(Installing|Configuring|ERROR|error)" || true

# ----------------------------------------------------------------
# WireGuard 完整套件
#   wireguard-tools : wg / wg-quick 命令行工具（UI 测试必须）
#   kmod-wireguard  : 内核模块（容器内不一定能加载，取决于宿主机内核）
#   luci-app-wireguard : LuCI 管理界面
#   luci-proto-wireguard : UCI 协议支持
#   qrencode        : WireGuard 配置二维码生成
# ----------------------------------------------------------------
echo "[init] 安装 WireGuard 套件..."
opkg install \
    wireguard-tools \
    kmod-wireguard \
    luci-app-wireguard \
    luci-proto-wireguard \
    luci-i18n-wireguard-zh-cn \
    qrencode \
    2>&1 | grep -E "(Installing|Configuring|ERROR|error)" || true

# ----------------------------------------------------------------
# UDP 隧道/伪装相关内核模块（phantun/udp2raw/udpspeeder 的依赖）
# ----------------------------------------------------------------
echo "[init] 安装 UDP 隧道相关模块..."
opkg install \
    kmod-tun \
    kmod-ipt-tproxy \
    kmod-ipt-nat \
    kmod-ipt-conntrack \
    kmod-nf-tproxy \
    2>&1 | grep -E "(Installing|Configuring|ERROR|error)" || true

# ----------------------------------------------------------------
# PPPoE 相关包（模拟 wan 接口）
# ----------------------------------------------------------------
echo "[init] 安装 PPPoE 相关包..."
opkg install \
    ppp ppp-mod-pppoe \
    luci-proto-ppp \
    2>&1 | grep -E "(Installing|Configuring|ERROR|error)" || true

# ----------------------------------------------------------------
# 开发调试辅助工具
# ----------------------------------------------------------------
echo "[init] 安装调试工具..."
opkg install \
    strace \
    file \
    less \
    logread \
    2>&1 | grep -E "(Installing|Configuring|ERROR|error)" || true

# ----------------------------------------------------------------
# 关闭 LuCI 代码缓存（开发模式：修改即生效）
# ----------------------------------------------------------------
uci set luci.ccache.enable=0
uci commit luci

# ----------------------------------------------------------------
# 配置 SSH（允许 root 密码登录）
# ----------------------------------------------------------------
cat > /etc/ssh/sshd_config << 'SSHEOF'
Port 22
PermitRootLogin yes
PasswordAuthentication yes
ChallengeResponseAuthentication no
UsePAM no
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
SSHEOF

# 设置 root 密码
echo "root:password" | chpasswd 2>/dev/null || \
    echo -e "password\npassword" | passwd root 2>/dev/null || true

# ----------------------------------------------------------------
# 打标记，避免重复初始化
# ----------------------------------------------------------------
date > "$INIT_MARKER"
echo "[init] ✅ 初始化完成！"
