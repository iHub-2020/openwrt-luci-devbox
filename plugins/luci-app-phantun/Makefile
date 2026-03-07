#
# Copyright (C) 2026 iHub-2020
#
# This is free software, licensed under the MIT License.
#
# Project: LuCI Support for Phantun UDP Obfuscator
# Version: 1.0.0
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-phantun
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_MAINTAINER:=iHub-2020

# 这里的 Title 会显示在 make menuconfig 中
LUCI_TITLE:=LuCI support for Phantun UDP Obfuscator
# 架构设置为 all，因为是脚本和网页，不涉及二进制编译
LUCI_PKGARCH:=all
# 依赖关系：确保安装了 phantun 和 luci 基础库
LUCI_DEPENDS:=+phantun +luci-base

# 这一段描述是标准的 OpenWrt 包描述格式
define Package/luci-app-phantun/description
  Phantun UDP Obfuscator - Web interface for configuring Phantun client and server
  instances with TUN interface management and automatic iptables rules.
endef

# Post-install script: Ensure permissions and enable service
# Post-install/Prerm logic removed.
# 1. Init script permissions managed by phantun core package.
# 2. Service enablement managed by ucitrack/uci-defaults.


include $(TOPDIR)/feeds/luci/luci.mk

# Call BuildPackage - OpenWrt buildroot signature
# $(eval $(call BuildPackage,luci-app-phantun))
# Modern luci.mk handles the build call automatically. Checks indicate luci-app-lucky ends at include luci.mk.


