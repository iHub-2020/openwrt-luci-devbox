#!/bin/bash
# ============================================================
# OpenWrt LuCI 开发环境 - 初始化脚本
# 在 Portainer 部署容器后执行此脚本来安装 LuCI
# 用法: bash /opt/openwrt-dev/init-luci.sh
# ============================================================

set -e

CONTAINER="openwrt-dev"

echo "⏳ 等待容器启动..."
until docker exec "$CONTAINER" true 2>/dev/null; do
    sleep 2
done
echo "✅ 容器已运行"

echo ""
echo "📦 更新 opkg 包索引..."
docker exec "$CONTAINER" opkg update

echo ""
echo "📦 安装 LuCI 及依赖..."
docker exec "$CONTAINER" opkg install \
    luci luci-base luci-mod-admin-full \
    luci-mod-network luci-mod-status luci-mod-system \
    luci-proto-ipv6 luci-theme-bootstrap \
    uhttpd uhttpd-mod-ubus \
    luci-lib-ip luci-lib-jsonc luci-lib-nixio \
    luci-compat

echo ""
echo "🔧 配置 uhttpd..."
docker exec "$CONTAINER" sh -c '
    # 确保 uhttpd 启用
    /etc/init.d/uhttpd enable 2>/dev/null
    /etc/init.d/uhttpd restart 2>/dev/null
'

echo ""
echo "🔑 设置 root 密码为 'password'（开发环境）..."
docker exec "$CONTAINER" sh -c 'echo -e "password\npassword" | passwd root'

echo ""
echo "============================================================"
echo "✅ LuCI 开发环境初始化完成！"
echo ""
echo "🌐 LuCI 访问地址:  http://$(hostname -I | awk '{print $1}'):8080"
echo "👤 用户名: root"
echo "🔑 密码: password"
echo ""
echo "📂 插件开发目录:"
echo "   宿主机: /opt/openwrt-dev/plugins/"
echo "   容器内: /luci-plugins/"
echo ""
echo "📋 常用命令:"
echo "   进入容器:     docker exec -it openwrt-dev sh"
echo "   安装 ipk 包:  docker exec openwrt-dev opkg install /packages/xxx.ipk"
echo "   重启 uhttpd:  docker exec openwrt-dev /etc/init.d/uhttpd restart"
echo "   查看日志:     docker exec openwrt-dev logread"
echo "============================================================"
