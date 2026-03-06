# openwrt-luci-devbox

> 模拟 OpenWrt 环境的 LuCI 插件开发测试 Docker 沙盒

![OpenWrt](https://img.shields.io/badge/OpenWrt-24.10.0-blue)
![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker)

## 简介

基于 Docker 的 OpenWrt 模拟开发环境，专为 **LuCI 插件开发调试**设计，支持网络层插件（WireGuard 伪装、UDP 隧道等）的完整测试。

- ✅ OpenWrt 24.10.0 x86_64
- ✅ LuCI Web 界面（中文）
- ✅ WireGuard 完整套件（含二维码生成 `qrencode`）
- ✅ 模拟接口拓扑：`br-lan` / `pppoe-wan` / `wg0` / `utun`
- ✅ 网络工具链：`ip-full` / `iptables` / `nftables` / `tc`
- ✅ SSH 访问
- ✅ 插件热重载（修改代码 → 刷新浏览器即生效）
- ✅ 健康检查（自动验证 uhttpd 状态）
- ✅ **网络安全隔离**：`NET_ADMIN` 仅作用于容器命名空间，不影响宿主机

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

# 3. 启动容器
docker compose up -d

# 4. 等待就绪（首次约 2-3 分钟，需下载 opkg 包）
bash init-luci.sh
```

## 访问

| 服务 | 地址 | 凭据 |
|------|------|------|
| LuCI Web | http://localhost:8080 | root / password |
| SSH | `ssh root@localhost -p 2222` | password |

## 开发工作流

```bash
./dev.sh status        # 查看容器状态和网络接口
./dev.sh list          # 列出已加载的插件
./dev.sh reload        # 重载 uhttpd（修改代码后执行）
./dev.sh shell         # 进入容器 shell
./dev.sh ssh           # SSH 登录容器
./dev.sh log           # 查看实时日志

# WireGuard 调试
./dev.sh wg-genkey     # 生成密钥对
./dev.sh wg-qr peer1   # 生成客户端配置二维码

# 网络层调试
./dev.sh net-status    # 查看 ip/iptables/nftables 状态

# 代码提交
./dev.sh push luci-app-phantun   # 推送单个插件
./dev.sh push-all                # 推送所有变更
```

## 网络安全说明

容器使用 `network_mode: bridge`（Docker 默认），拥有独立的网络命名空间。

- 容器内的 `ip link`、`iptables`、`wg` 等操作**只影响容器自身**，不会修改宿主机路由表或防火墙规则
- `NET_ADMIN` 能力限定在容器命名空间内
- 已移除 `SYS_MODULE`（加载内核模块可影响宿主机，不安全）
- 端口绑定到 `127.0.0.1`，局域网其他设备无法直接访问容器

## 模拟网络接口

容器启动时自动创建以下接口（与真实 OpenWrt 路由器拓扑一致）：

| 接口 | 类型 | 地址 | 说明 |
|------|------|------|------|
| `br-lan` | bridge | 192.168.1.1/24 | LAN 网桥 |
| `pppoe-wan` | dummy | — | 模拟 PPPoE WAN |
| `wg0` | wireguard/dummy | 10.10.58.1/24 | WireGuard VPN |
| `utun` | tun | — | 供 phantun/udp2raw 使用 |

## 目录结构

```
openwrt-luci-devbox/
├── docker-compose.yml    # 容器编排
├── entrypoint.sh         # 容器启动脚本（接口创建 + 插件加载 + 服务启动）
├── docker-init.sh        # 首次初始化脚本（安装 opkg 包，幂等）
├── init-luci.sh          # 宿主机侧等待脚本（等待 LuCI 就绪）
├── dev.sh                # 开发辅助脚本
├── config/               # UCI 配置模板（容器启动时写入）
│   ├── network           # 接口定义（lan/wan/wan_6/wg0）
│   ├── firewall          # 防火墙规则（含 WireGuard zone）
│   ├── dhcp              # DHCP/DNS 配置
│   ├── luci              # LuCI 设置（关闭缓存）
│   ├── system            # 系统设置（时区等）
│   ├── init-firewall     # 额外 iptables 规则
│   └── ucitrack          # UCI 变更追踪
├── plugins/              # 插件目录（.gitignore 已排除）
└── doc/
    ├── DEVELOPMENT.md
    └── USAGE.md
```

## 相关项目

- [openwrt-reyan_new](https://github.com/iHub-2020/openwrt-reyan_new) — 配套 LuCI 插件仓库

## License

MIT
