#!/bin/sh
# ============================================================
# OpenWrt Docker 适配脚本 (uci-defaults)
# 在首次启动时自动执行，让 OpenWrt 适配 Docker 环境
# ============================================================

# 1. 禁用防火墙（防止 iptables 冲突）
/etc/init.d/firewall stop 2>/dev/null
/etc/init.d/firewall disable 2>/dev/null

# 2. 禁用 dnsmasq（使用 Docker 的 DNS）
/etc/init.d/dnsmasq stop 2>/dev/null
/etc/init.d/dnsmasq disable 2>/dev/null

# 3. 禁用 odhcpd（不需要 DHCP 服务）
/etc/init.d/odhcpd stop 2>/dev/null
/etc/init.d/odhcpd disable 2>/dev/null

# 4. 修复网络配置：不再创建 br-lan，直接用 eth0
uci set network.loopback=interface
uci set network.loopback.device='lo'
uci set network.loopback.proto='static'
uci set network.loopback.ipaddr='127.0.0.1'
uci set network.loopback.netmask='255.0.0.0'

# 删除 lan 桥接配置
uci delete network.@device[0] 2>/dev/null
uci delete network.lan 2>/dev/null
uci commit network

# 5. 启用 uhttpd
/etc/init.d/uhttpd enable 2>/dev/null

exit 0
