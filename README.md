# openwrt-luci-devbox

> 模拟 OpenWrt 环境的 LuCI 插件开发测试 Docker 沙盒

[![OpenWrt](https://img.shields.io/badge/OpenWrt-23.05.5-blue)](https://openwrt.org)
[![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker)](https://docs.docker.com/compose/)

## 简介

基于 Docker 的 OpenWrt 模拟开发环境，专为 **LuCI 插件开发调试**设计。无需真实硬件，即可在本地快速验证插件功能。

- ✅ OpenWrt 23.05.5 x86_64
- ✅ LuCI Web 界面（中文）
- ✅ SSH 访问
- ✅ 健康检查（自动验证 uhttpd 状态）
- ✅ 插件热重载（修改代码 → 刷新浏览器即生效）
- ✅ 启动时自动加载 `plugins/luci-app-*` 目录下的所有插件

## 快速开始

```bash
# 1. 克隆本仓库
git clone https://github.com/iHub-2020/openwrt-luci-devbox.git
cd openwrt-luci-devbox

# 2. 拉取插件仓库（sparse-checkout，只下载插件和依赖目录）
git clone --filter=blob:none --sparse https://github.com/iHub-2020/openwrt-reyan_new.git plugins/
cd plugins && git sparse-checkout set \
  luci-app-phantun phantun \
  luci-app-poweroffdevice \
  luci-app-udp-speeder udpspeeder \
  luci-app-udp-tunnel udp2raw
cd ..

# 3. 启动容器（Portainer Stack 或命令行）
docker compose up -d

# 4. 等待约 60 秒（首次安装依赖），查看状态
docker ps --filter "name=openwrt-luci-devbox"
# 状态显示 (healthy) 即就绪
```

## 访问

| 服务 | 地址 | 凭据 |
|------|------|------|
| LuCI Web | http://localhost:8080 | root / password |
| SSH | ssh root@localhost -p 2222 | password |

## 开发工作流

```bash
# 查看容器和插件状态
./dev.sh status
./dev.sh list

# 重启 uhttpd 使改动生效（修改代码后执行）
./dev.sh reload

# 验证成功后推送单个插件到 GitHub
./dev.sh push luci-app-poweroffdevice

# 推送所有有改动的插件
./dev.sh push-all

# 查看容器日志
./dev.sh log

# SSH 进入容器调试
./dev.sh ssh
```

## 目录结构

```
openwrt-luci-devbox/
├── docker-compose.yml   # 容器编排配置
├── entrypoint.sh        # 容器启动脚本（自动加载插件）
├── dev.sh               # 开发辅助脚本
├── config/              # OpenWrt UCI 配置模板
├── plugins/             # 插件目录（挂载到容器 /luci-plugins，.gitignore 已排除）
│   ├── .git/            # → openwrt-reyan_new 仓库（用于 push 回 GitHub）
│   ├── luci-app-phantun/       # LuCI 插件
│   ├── phantun/                # ↑ 依赖二进制
│   ├── luci-app-poweroffdevice/ # LuCI 插件（独立）
│   ├── luci-app-udp-speeder/   # LuCI 插件
│   ├── udpspeeder/             # ↑ 依赖二进制
│   ├── luci-app-udp-tunnel/    # LuCI 插件
│   └── udp2raw/                # ↑ 依赖二进制
└── doc/
    ├── DEVELOPMENT.md   # 开发手册（插件结构、新建流程）
    └── USAGE.md         # 使用手册（调试命令、常见问题）
```

## 插件自动加载机制

容器启动时，`entrypoint.sh` 会自动扫描 `/luci-plugins/luci-app-*` 并：

1. 将 `luasrc/controller/*.lua` 链接到 `/usr/lib/lua/luci/controller/`
2. 将 `luasrc/view/<子目录>` 链接到 `/usr/lib/lua/luci/view/`
3. 将 `root/` 目录合并到容器根文件系统

**无需手动 link**，直接修改代码后执行 `./dev.sh reload` 即可。

## 文档

- 📖 [开发手册](doc/DEVELOPMENT.md) — 目录结构、插件开发规范、dev.sh 说明
- 📖 [使用/调试手册](doc/USAGE.md) — 容器管理、健康检查、常见问题

## 相关项目

- [openwrt-reyan_new](https://github.com/iHub-2020/openwrt-reyan_new) — 配套 LuCI 插件仓库

## License

MIT
