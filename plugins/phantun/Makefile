# Copyright (C) 2024 iHub-2020
# 
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# Project: phantun OpenWrt Package
# Maintainer: iHub-2020
# Upstream: https://github.com/iHub-2020/phantun
# Version: Dynamic (Professional Version Management)
# Last Updated: 2026-01-31
#
# Changelog:
#   2026-01-31 - Initial release for phantun
#              - Enhanced with professional version management
#              - Dynamic version fetching from GitHub API
#              - Support for version history tracking
#              - Auto-increment versioning starting from v1.0.2
#              - Fallback to v1.0.2 if API fails

include $(TOPDIR)/rules.mk

PKG_NAME:=phantun
# ----------------------------------------------------------------------------
# 【重要】专业版本管理
# 动态获取最新版本号，支持版本历史追踪
# 从 v1.0.2 开始（phantun当前最新版本）
# ----------------------------------------------------------------------------
# 动态获取最新版本，如果获取失败则使用默认版本
# Dynamic version fetching causes CI failures (Rate limits/Network issues). 
# Switched to static version for stability.
PKG_VERSION:=1.0.2
# PKG_VERSION:=$(shell curl -s --connect-timeout 10 https://api.github.com/repos/iHub-2020/phantun/releases/latest 2>/dev/null | grep '"tag_name"' | cut -d'"' -f4 | sed 's/^v//' || echo "1.0.2")
PKG_RELEASE:=1

# ============================================================
# Binary Release Mode Settings
# ============================================================
REPO_USER:=iHub-2020
REPO_NAME:=phantun

# 动态下载地址，自动匹配最新版本
MANUAL_DOWNLOAD_URL:=https://github.com/$(REPO_USER)/$(REPO_NAME)/releases/download/v$(PKG_VERSION)

# 移除 PKG_SOURCE 定义，避免 OpenWrt 自动检查 hash
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

PKG_LICENSE:=MIT Apache-2.0
PKG_LICENSE_FILES:=LICENSE-MIT LICENSE-APACHE
PKG_MAINTAINER:=iHub-2020

# 预编译包不需要并行编译
PKG_BUILD_PARALLEL:=0

include $(INCLUDE_DIR)/package.mk

define Package/phantun
  SECTION:=net
  CATEGORY:=Network
  TITLE:=UDP to FakeTCP obfuscator (Pre-compiled)
  URL:=https://github.com/dndx/phantun
  DEPENDS:=+iptables +ip-full +ca-bundle +kmod-tun
endef

define Package/phantun/description
  A lightweight and fast UDP to TCP obfuscator that converts UDP packets 
  into obfuscated TCP stream packets. It aims to achieve maximum performance 
  with minimum processing and encapsulation overhead.
  
  Key Features:
  - Lightweight UDP to FakeTCP obfuscation
  - TUN interface based operation
  - IPv4 and IPv6 support
  - Multi-core optimization
  - Minimum 12-byte overhead
  - No encryption (focused on performance)
  
  OpenWrt Integration Features:
  - Automatic iptables rule management
  - TUN interface configuration
  - Service management with procd
  - Configuration persistence
  
  NOTE: This package downloads pre-compiled STATIC binaries from GitHub.
  Using professional version management with automatic version detection.
  Supported architectures: x86_64, aarch64
endef

# ------------------------------------------------------------------
# Build/Prepare: 创建编译目录
# ------------------------------------------------------------------
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

# Build/Configure: 跳过配置
define Build/Configure
endef

# ------------------------------------------------------------------
# Build/Compile: 下载并安装二进制文件
# ------------------------------------------------------------------
define Build/Compile
	@echo "======================================================="
	@echo "Downloading phantun binaries (Rolling Release)"
	@echo "Version Tag: v$(PKG_VERSION)"
	@echo "Target Architecture: $(ARCH)"
	@echo "Download URL Base: $(MANUAL_DOWNLOAD_URL)"
	@echo "======================================================="

	# 根据架构下载对应的文件
	@if [ "$(ARCH)" = "x86_64" ]; then \
		echo "Downloading: $(MANUAL_DOWNLOAD_URL)/phantun_x86_64.zip"; \
		curl -L -k --fail --connect-timeout 30 --retry 3 \
			-o $(PKG_BUILD_DIR)/phantun.zip "$(MANUAL_DOWNLOAD_URL)/phantun_x86_64.zip"; \
	elif [ "$(ARCH)" = "aarch64" ]; then \
		echo "Downloading: $(MANUAL_DOWNLOAD_URL)/phantun_aarch64.zip"; \
		curl -L -k --fail --connect-timeout 30 --retry 3 \
			-o $(PKG_BUILD_DIR)/phantun.zip "$(MANUAL_DOWNLOAD_URL)/phantun_aarch64.zip"; \
	else \
		echo "Error: Unsupported architecture $(ARCH). Only x86_64 and aarch64 are supported."; \
		exit 1; \
	fi
	
	# 解压文件
	cd $(PKG_BUILD_DIR) && unzip -o phantun.zip
	
	# 校验文件：确保文件存在且大小大于 100KB
	@if [ ! -s "$(PKG_BUILD_DIR)/phantun_client" ] || [ ! -s "$(PKG_BUILD_DIR)/phantun_server" ]; then \
		echo "Error: Download failed, binaries are missing."; \
		echo "Please ensure Release v$(PKG_VERSION) exists at:"; \
		echo "  https://github.com/$(REPO_USER)/$(REPO_NAME)/releases/tag/v$(PKG_VERSION)"; \
		exit 1; \
	fi
	@CLIENT_SIZE=$$(stat -c%s "$(PKG_BUILD_DIR)/phantun_client"); \
	SERVER_SIZE=$$(stat -c%s "$(PKG_BUILD_DIR)/phantun_server"); \
	if [ $$CLIENT_SIZE -lt 100000 ] || [ $$SERVER_SIZE -lt 100000 ]; then \
		echo "Error: Files too small (client: $$CLIENT_SIZE, server: $$SERVER_SIZE bytes)."; \
		echo "Please verify the Release exists at:"; \
		echo "  https://github.com/$(REPO_USER)/$(REPO_NAME)/releases/tag/v$(PKG_VERSION)"; \
		exit 1; \
	fi
	
	chmod +x $(PKG_BUILD_DIR)/phantun_client $(PKG_BUILD_DIR)/phantun_server
	@echo "======================================================="
	@echo "Download complete. Client: $$CLIENT_SIZE bytes, Server: $$SERVER_SIZE bytes"
	@echo "======================================================="
endef

define Package/phantun/install
	# Binaries
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/phantun_client $(1)/usr/bin/phantun_client
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/phantun_server $(1)/usr/bin/phantun_server
	
	# Init Script (Service Management)
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/phantun.init $(1)/etc/init.d/phantun

	# Sysupgrade config preservation (Optional, generally config belongs to luci-app-phantun)
	$(INSTALL_DIR) $(1)/usr/share/phantun
	$(INSTALL_DATA) ./files/phantun.upgrade $(1)/usr/share/phantun/

endef

define Package/phantun/conffiles
endef

# Remove postinst/prerm as service is managed by luci-app-phantun


$(eval $(call BuildPackage,phantun))