#!/bin/sh
# ==============================================================
#  标题: docker-init.sh
#  作者: reyan
#  日期: 2026-03-08
#  版本: 1.2.0
#  描述: OpenWrt LuCI DevBox 首次初始化脚本，负责 opkg 源配置、依赖安装与基础运行态准备。
#  最近三次更新:
#    - 2026-03-08: 优化可选包安装策略，逐项探测并跳过不可用包，减少初始化噪音。
#    - 2026-03-08: 补充 firewall4 基础依赖并修复 SSH 配置目录缺失问题。
#    - 2026-03-08: 收敛网络工具安装范围，避免无谓的内核依赖报错干扰验收。
# ==============================================================
# ==============================================================
#  docker-init.sh — 容器首次启动时执行，安装所有依赖包
#  幂等：通过 /etc/.devbox-initialized 标记避免重复安装
# ==============================================================

INIT_MARKER="/etc/.devbox-initialized"
FORCE_REINIT="${FORCE_REINIT:-0}"

if [ -f "$INIT_MARKER" ] && [ "$FORCE_REINIT" != "1" ]; then
    echo "[init] 已初始化，跳过安装（如需重装请设置 FORCE_REINIT=1）"
    exit 0
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

is_installed() {
    local pkg="$1"
    opkg list-installed | grep -qE "^$pkg -"
}

install_pkgs_required() {
    local pkg missing=""
    for pkg in "$@"; do
        is_installed "$pkg" || missing="$missing $pkg"
    done

    [ -n "$missing" ] || return 0

    echo "[init] 安装必需包:$missing"
    opkg install $missing || return 1
}

install_pkgs_optional() {
    local pkg available
    for pkg in "$@"; do
        if is_installed "$pkg"; then
            continue
        fi
        available="$(opkg list 2>/dev/null | grep -E "^$pkg -" || true)"
        if [ -z "$available" ]; then
            echo "[init] 跳过不可用可选包: $pkg"
            continue
        fi

        echo "[init] 安装可选包: $pkg"
        opkg install "$pkg" || echo "[init] ⚠️ 可选包安装失败，已忽略: $pkg"
    done
}

# ----------------------------------------------------------------
# 基础系统包（SSH + LuCI Web 界面）
# ----------------------------------------------------------------
echo "[init] 安装基础系统包..."
install_pkgs_required \
    firewall4 \
    uhttpd uhttpd-mod-ubus uhttpd-mod-ucode uhttpd-mod-lua \
    rpcd rpcd-mod-rpcsys rpcd-mod-file \
    luci-base luci-mod-admin-full \
    luci-theme-bootstrap \
    luci-app-firewall \
    luci-i18n-base-zh-cn \
    luci-i18n-firewall-zh-cn \
    openssh-server \
    curl wget-ssl \
    bash kmod-nft-core

# ----------------------------------------------------------------
# 网络工具（网络层插件开发必备）
# ----------------------------------------------------------------
echo "[init] 安装网络工具..."
install_pkgs_optional \
    ip-full \
    nftables kmod-nft-nat \
    socat \
    tcpdump \
    bind-dig \
    iproute2

# ----------------------------------------------------------------
# WireGuard 完整套件
#   wireguard-tools : wg / wg-quick 命令行工具（UI 测试必须）
#   kmod-wireguard  : 内核模块（容器内不一定能加载，取决于宿主机内核）
#   luci-app-wireguard : LuCI 管理界面
#   luci-proto-wireguard : UCI 协议支持
#   qrencode        : WireGuard 配置二维码生成
# ----------------------------------------------------------------
echo "[init] 安装 WireGuard 套件..."
WG_REQUIRED="wireguard-tools luci-proto-wireguard qrencode"
WG_FORCE="rpcd-mod-wireguard"
for pkg in $WG_REQUIRED $WG_FORCE; do
    is_installed "$pkg" && continue
    available="$(opkg list 2>/dev/null | grep -E "^$pkg -" || true)"
    if [ -z "$available" ]; then
        echo "[init] 跳过不可用 WireGuard 相关包: $pkg"
        continue
    fi

    echo "[init] 安装 WireGuard 相关包(允许缺失内核依赖): $pkg"
    opkg install --force-depends "$pkg" || echo "[init] ⚠️ WireGuard 相关包安装失败，已忽略: $pkg"
done

install_pkgs_optional \
    kmod-wireguard \
    luci-app-wireguard \
    luci-i18n-wireguard-zh-cn

# ----------------------------------------------------------------
# UDP 隧道/伪装相关内核模块（phantun/udp2raw/udpspeeder 的依赖）
# ----------------------------------------------------------------
echo "[init] 安装 UDP 隧道相关模块..."
install_pkgs_optional \
    kmod-tun \
    kmod-ipt-tproxy \
    kmod-ipt-nat \
    kmod-ipt-conntrack \
    kmod-nf-tproxy

# ----------------------------------------------------------------
# PPPoE 相关包（模拟 wan 接口）
# ----------------------------------------------------------------
echo "[init] 安装 PPPoE 相关包..."
install_pkgs_required \
    ppp ppp-mod-pppoe \
    luci-proto-ppp

# ----------------------------------------------------------------
# 开发调试辅助工具
# ----------------------------------------------------------------
echo "[init] 安装调试工具..."
install_pkgs_optional \
    strace \
    file \
    less \
    logread

# ----------------------------------------------------------------
# 关键运行时验收（WireGuard / LuCI 协议支持）
# ----------------------------------------------------------------
for req in wireguard-tools luci-proto-wireguard qrencode; do
    if ! is_installed "$req"; then
        echo "[init] ERROR: required package missing after install: $req" >&2
        exit 1
    fi
done

if ! command -v wg >/dev/null 2>&1; then
    echo "[init] ERROR: wg command missing after install" >&2
    exit 1
fi

# ----------------------------------------------------------------
# 关闭 LuCI 代码缓存（开发模式：修改即生效）
# ----------------------------------------------------------------
uci set luci.ccache.enable=0
uci commit luci

# ----------------------------------------------------------------
# 配置 SSH（允许 root 密码登录）
# ----------------------------------------------------------------
mkdir -p /etc/ssh

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
