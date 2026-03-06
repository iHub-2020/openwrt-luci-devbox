# openwrt-luci-devbox

> 模拟 OpenWrt 环境的 LuCI 插件开发测试 Docker 沙盒

![OpenWrt](https://img.shields.io/badge/OpenWrt-24.10.3-blue)
![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker)

---

## 目录

- [项目简介](#项目简介)
- [工作原理](#工作原理)
- [目录结构](#目录结构)
- [启动流程详解](#启动流程详解)
- [快速开始](#快速开始)
- [两种运行模式](#两种运行模式)
- [访问方式](#访问方式)
- [开发工作流](#开发工作流)
- [插件自动加载机制](#插件自动加载机制)
- [模拟网络接口拓扑](#模拟网络接口拓扑)
- [网络安全设计](#网络安全设计)
- [配置文件说明](#配置文件说明)
- [环境变量参考](#环境变量参考)
- [dev.sh 命令参考](#devsh-命令参考)
- [WireGuard 开发指南](#wireguard-开发指南)
- [通讯类插件流量验证指南](#通讯类插件流量验证指南)
- [常见问题](#常见问题)
- [相关项目](#相关项目)

---

## 项目简介

本项目是一个基于 Docker 的 OpenWrt 模拟开发环境，专为 **LuCI 插件开发与调试**设计。

**核心价值：**
- 无需真实路由器硬件，在普通 Linux/macOS/Windows 主机上即可完整开发和测试 LuCI 插件
- 模拟真实 OpenWrt 路由器的网络接口拓扑（lan/wan/wg0 等），UI 展示与真机完全一致
- 支持网络层插件（WireGuard 伪装、UDP 隧道等）的端对端流量验证
- 插件代码热重载，修改文件后刷新浏览器即可看到效果

**配套插件仓库：** [openwrt-reyan_new](https://github.com/iHub-2020/openwrt-reyan_new)

---

## 工作原理

### 整体架构

```
宿主机
├── docker-compose.yml         ← 编排配置，定义容器能力和挂载关系
├── entrypoint.sh              ← 容器启动入口（每次启动都执行）
├── docker-init.sh             ← 包安装脚本（首次启动执行，后续跳过）
├── init-luci.sh               ← 宿主机侧等待脚本（等待 LuCI 就绪）
├── config/                    ← UCI 配置模板（启动时写入容器 /etc/config/）
└── plugins/                   ← 插件源码目录（挂载到容器 /luci-plugins/）
    ├── .git/                  ← 指向 openwrt-reyan_new 仓库
    ├── luci-app-phantun/
    ├── luci-app-wireguard/
    └── ...

Docker 容器（OpenWrt 24.10 x86_64 rootfs）
├── /luci-plugins/             ← 挂载自宿主机 ./plugins/（双向同步）
├── /usr/lib/lua/luci/         ← LuCI 框架核心
│   ├── controller/            ← 插件控制器（从 /luci-plugins/ 符号链接）
│   ├── view/                  ← 插件视图模板（从 /luci-plugins/ 符号链接）
│   └── model/cbi/             ← 插件 CBI 模型（从 /luci-plugins/ 符号链接）
├── /etc/config/               ← UCI 配置（network/firewall/dhcp 等）
└── /www/                      ← LuCI Web 静态资源
```

### 关键设计决策

#### 1. 为什么用 OpenWrt 官方 rootfs 镜像而非 Alpine/Ubuntu？

OpenWrt 的 LuCI 框架依赖 OpenWrt 特有的组件：
- `uci`：OpenWrt 的统一配置接口，语法和行为与标准 Linux 不同
- `ubus`/`rpcd`：LuCI 后端 RPC 总线，所有 AJAX 请求都通过它
- `opkg`：OpenWrt 包管理器，LuCI 插件和依赖都从 OpenWrt 官方源安装
- `uhttpd`：OpenWrt 专用轻量 HTTP 服务器，内置 LuCI CGI 支持

使用标准 Linux 镜像无法还原这些运行时环境，插件行为会与真机不一致。

#### 2. 插件加载的核心机制（符号链接而非复制）

`entrypoint.sh` 启动时扫描 `/luci-plugins/luci-app-*/`，将插件文件**符号链接**（而非复制）到 LuCI 框架目录：

```
/luci-plugins/luci-app-phantun/luasrc/controller/phantun.lua
    → 符号链接 → /usr/lib/lua/luci/controller/phantun.lua

/luci-plugins/luci-app-phantun/luasrc/view/phantun/
    → 符号链接 → /usr/lib/lua/luci/view/phantun/
```

**效果：** 宿主机上修改 `plugins/luci-app-phantun/` 下的任何文件，容器内立即可见（因为挂载+符号链接），执行 `./dev.sh reload` 清除 LuCI 缓存后刷新浏览器即生效。

#### 3. 初始化幂等性设计

`docker-init.sh` 通过 `/etc/.devbox-initialized` 文件标记是否已完成初始化：
- 首次启动：文件不存在 → 执行完整 opkg 安装流程（约 2~3 分钟）
- 后续重启：文件存在 → 直接跳过，启动时间 < 10 秒
- 强制重装：设置环境变量 `FORCE_REINIT=1` 或执行 `./dev.sh reinit`

#### 4. 网络接口的实现方式

真实 OpenWrt 路由器有 `br-lan`（网桥）、`pppoe-wan`（PPPoE 拨号）、`wg0`（WireGuard）等接口。
容器内通过 `ip link` 命令创建对应的虚拟接口：

| 真实接口 | 容器内实现 | 说明 |
|---------|-----------|------|
| `br-lan` | `type bridge` | 真实网桥 |
| `pppoe-wan` | `type dummy` | 模拟 PPPoE 隧道（无真实拨号） |
| `wg0` | `type wireguard` 或 `type dummy` | 优先真 WireGuard，失败降级 |
| `utun` | `tuntap mode tun` | TUN 设备，供 phantun/udp2raw 使用 |

UCI 网络配置同步写入 `/etc/config/network`，LuCI 界面展示与真机一致。

---

## 目录结构

```
openwrt-luci-devbox/
│
├── docker-compose.yml          # 单容器版（普通插件开发，默认使用）
├── docker-compose.dual.yml     # 双容器版（通讯类插件流量验证）
│
├── entrypoint.sh               # 容器启动入口脚本（核心，每次启动执行）
├── docker-init.sh              # 首次初始化脚本（安装 opkg 包，幂等）
├── init-luci.sh                # 宿主机侧辅助脚本（等待 LuCI 就绪）
├── dev.sh                      # 开发辅助脚本（日常操作入口）
│
├── config/                     # UCI 配置模板目录
│   ├── network                 # 接口定义：lan / wan / wan_6 / wg0
│   ├── firewall                # 防火墙规则：含 WireGuard vpn zone
│   ├── dhcp                    # DHCP/DNS 配置
│   ├── luci                    # LuCI 设置（开发模式关闭代码缓存）
│   ├── system                  # 系统设置（主机名、时区）
│   ├── init-firewall           # 额外 iptables 规则脚本（启动时执行）
│   └── ucitrack                # UCI 变更追踪依赖关系表
│
├── plugins/                    # 插件源码目录（.gitignore 已排除）
│   ├── .git/                   # → openwrt-reyan_new 仓库
│   ├── luci-app-phantun/       # 插件：phantun TCP 伪装
│   ├── phantun/                # 依赖二进制
│   ├── luci-app-poweroffdevice/
│   ├── luci-app-udp-speeder/
│   ├── udpspeeder/
│   ├── luci-app-udp-tunnel/
│   └── udp2raw/
│
└── doc/
    ├── DEVELOPMENT.md          # 插件开发规范、新建插件流程
    └── USAGE.md                # 调试命令、常见问题
```

### 插件目录结构规范

每个 `luci-app-*` 插件必须遵循以下结构，`entrypoint.sh` 才能正确加载：

```
luci-app-myplugin/
├── luasrc/
│   ├── controller/
│   │   └── myplugin.lua        # LuCI 路由控制器（必须）
│   ├── view/
│   │   └── myplugin/           # HTML 模板目录
│   │       └── index.htm
│   └── model/
│       └── cbi/
│           └── myplugin.lua    # CBI 配置模型（可选）
└── root/
    ├── etc/
    │   ├── config/
    │   │   └── myplugin        # UCI 配置文件（可选）
    │   └── init.d/
    │       └── myplugin        # 系统服务脚本（可选）
    └── usr/
        └── bin/
            └── myplugin        # 可执行文件（可选）
```

---

## 启动流程详解

容器每次启动时，`entrypoint.sh` 按以下顺序执行：

```
启动
 │
 ▼
[1] 调用 docker-init.sh
     ├── 检查 /etc/.devbox-initialized 是否存在
     ├── 存在 → 跳过（< 1s）
     └── 不存在 → 执行：
          ├── 写入 opkg 源配置（OpenWrt 24.10.0 官方源）
          ├── opkg update
          ├── 安装 LuCI 基础包
          ├── 安装 WireGuard 套件（含 qrencode）
          ├── 安装网络工具链（ip-full/iptables/nftables/tc）
          ├── 安装 UDP 隧道相关内核模块
          ├── 安装 PPPoE 相关包
          ├── 安装调试工具（strace/tcpdump 等）
          ├── 关闭 LuCI 代码缓存（开发模式）
          ├── 配置 SSH（允许 root 密码登录）
          └── 创建 /etc/.devbox-initialized 标记
 │
 ▼
[2] 写入 UCI 配置模板
     └── 将 /config-templates/ 下的文件复制到 /etc/config/
 │
 ▼
[3] 创建模拟网络接口
     ├── 尝试加载内核模块（wireguard/tun/dummy）
     ├── 创建 br-lan（bridge，192.168.1.1/24）    [server 模式]
     ├── 创建 wg0（wireguard 或 dummy，10.10.58.x/24）
     ├── 创建 pppoe-wan（dummy）                   [server 模式]
     └── 创建 utun（tuntap）
 │
 ▼
[4] 写入 UCI 网络配置
     └── uci set network.lan / wan / wan_6 / wg0 并 commit
 │
 ▼
[5] 应用额外防火墙规则
     └── 执行 /config-templates/init-firewall
 │
 ▼
[6] 扫描并加载插件                                 [server 模式]
     └── 遍历 /luci-plugins/luci-app-*/
          ├── 链接 luasrc/controller/*.lua → /usr/lib/lua/luci/controller/
          ├── 链接 luasrc/view/*/         → /usr/lib/lua/luci/view/
          ├── 链接 luasrc/model/cbi/*.lua → /usr/lib/lua/luci/model/cbi/
          └── 复制 root/ 到容器根文件系统
 │
 ▼
[7] 启动系统服务
     ├── ubusd（RPC 总线守护进程）
     ├── rpcd（LuCI 后端 RPC）
     ├── netifd（网络接口守护进程）
     └── sshd（SSH 服务）
 │
 ▼
[8] 前台进程（保持容器存活）
     ├── server 模式 → exec uhttpd -f（LuCI Web 服务器，前台运行）
     └── peer 模式   → exec tail -f /dev/null
```

---

## 快速开始

### 前置条件

- Docker >= 20.10
- Docker Compose >= 2.0
- 宿主机已安装 WireGuard 内核模块（可选，没有时自动降级）
  ```bash
  # Ubuntu/Debian
  sudo apt install wireguard
  # 验证
  modinfo wireguard
  ```

### 步骤

```bash
# 1. 克隆本仓库
git clone https://github.com/iHub-2020/openwrt-luci-devbox.git
cd openwrt-luci-devbox

# 2. 拉取插件仓库（sparse-checkout，只下载所需目录）
git clone --filter=blob:none --sparse \
    https://github.com/iHub-2020/openwrt-reyan_new.git plugins/
cd plugins && git sparse-checkout set \
    luci-app-phantun phantun \
    luci-app-poweroffdevice \
    luci-app-udp-speeder udpspeeder \
    luci-app-udp-tunnel udp2raw
cd ..

# 3. 构建镜像（首次需下载 rootfs.tar.gz，约 5MB）
docker compose build

# 4. 启动容器
docker compose up -d

# 4. 等待就绪（首次约 2~3 分钟）
bash init-luci.sh

# 5. 打开浏览器访问 LuCI
# http://localhost:8080  用户名: root  密码: password
```

---

## 两种运行模式

### 单容器模式（默认，普通插件开发）

**适用场景：**
- LuCI 配置界面开发（表单、状态展示、UCI 读写）
- WireGuard 密钥生成、二维码生成
- init.d 脚本逻辑验证
- poweroffdevice、系统管理类、状态监控类插件
- 任何不需要验证"真实流量"的插件

```bash
# 启动
docker compose up -d

# 停止
docker compose down
```

### 双容器模式（通讯类插件流量验证）

**适用场景：**
- phantun（将 UDP 伪装为 TCP 流量）的端对端验证
- udp2raw（将 UDP 伪装为 TCP/ICMP）的穿透测试
- udp-speeder 多倍发包效果验证
- WireGuard over TCP 伪装插件的真实流量测试
- 任何需要"服务端 ↔ 客户端"双向流量的场景

```bash
# 启动（两个容器同时启动）
docker compose -f docker-compose.dual.yml up -d

# 停止
docker compose -f docker-compose.dual.yml down
```

**双容器网络拓扑：**

```
宿主机 (127.0.0.1)
  │
  ├── :8080 → openwrt-server:80   (LuCI Web)
  ├── :2222 → openwrt-server:22   (SSH)
  └── :2223 → openwrt-peer:22     (SSH)

Docker 内部网络 devnet (172.30.0.0/24)
  ├── openwrt-server  172.30.0.10  wg0: 10.10.58.1/24
  └── openwrt-peer    172.30.0.20  wg0: 10.10.58.2/24
```

**进入对端容器调试：**

```bash
# SSH 进入 peer 容器
ssh root@localhost -p 2223

# 或直接 exec
docker exec -it openwrt-peer /bin/ash
```

---

## 访问方式

| 服务 | 地址 | 凭据 | 说明 |
|------|------|------|------|
| LuCI Web | http://localhost:8080 | root / password | 仅绑定 127.0.0.1 |
| SSH（server）| `ssh root@localhost -p 2222` | password | |
| SSH（peer）| `ssh root@localhost -p 2223` | password | 双容器模式 |

> **注意：** 端口绑定到 `127.0.0.1`，局域网内其他设备无法直接访问容器，这是安全设计。

---

## 开发工作流

### 日常开发循环

```
1. 修改 plugins/luci-app-xxx/ 下的源码（宿主机上用任意编辑器）
       ↓
2. 执行 ./dev.sh reload（清除 LuCI 缓存，重启 uhttpd）
       ↓
3. 刷新浏览器 http://localhost:8080
       ↓
4. 验证功能，如有问题继续修改
       ↓
5. 验证通过后：./dev.sh push luci-app-xxx（提交到 GitHub）
```

### 新建插件

参考 [doc/DEVELOPMENT.md](doc/DEVELOPMENT.md)，在 `plugins/` 目录下按规范创建 `luci-app-myplugin/` 目录，重启容器或执行 `./dev.sh reload` 后自动加载。

### 修改系统配置

如果需要修改网络/防火墙等 UCI 配置：

```bash
# 方式一：进入容器直接修改（重启后会被模板覆盖）
./dev.sh shell
uci set network.lan.ipaddr='192.168.2.1'
uci commit network

# 方式二：修改 config/ 目录下的模板文件（永久生效）
# 修改 config/network 后，重启容器生效
docker compose restart
```

---

## 插件自动加载机制

### 触发时机

每次容器启动时，`entrypoint.sh` 的第 [6] 步自动执行。

### 加载逻辑

```sh
# 伪代码描述
for plugin_dir in /luci-plugins/luci-app-*/; do
    # Controller：LuCI 路由注册（旧式 Lua）
    ln -sf $plugin_dir/luasrc/controller/*.lua \
           /usr/lib/lua/luci/controller/

    # View：HTML 模板（旧式 Lua/CBI）
    ln -sf $plugin_dir/luasrc/view/*/ \
           /usr/lib/lua/luci/view/

    # CBI Model：配置模型（旧式 Lua/CBI）
    ln -sf $plugin_dir/luasrc/model/cbi/*.lua \
           /usr/lib/lua/luci/model/cbi/

    # JS View：新式 LuCI 资源（如 htdocs/luci-static/resources/view/*）
    ln -snf $plugin_dir/htdocs/luci-static/resources/view/*/ \
            /www/luci-static/resources/view/

    # root/ 覆盖：menu.d、ACL、UCI 配置、init.d 脚本、可执行文件等
    cp -r $plugin_dir/root/. /
done
```

### 实时重载（不重启容器）

```bash
./dev.sh reload
```

该命令：
1. 删除 LuCI 的 Lua 字节码缓存（`/tmp/luci-*`）
2. 向 uhttpd 发送 HUP 信号重新加载

**注意：** 如果新增了插件目录（而非修改现有插件），需要重启容器才能重新执行符号链接扫描：

```bash
docker compose restart
```

---

## 模拟网络接口拓扑

容器启动后，网络接口结构与真实 OpenWrt 路由器（你截图中的设备）完全一致：

```
容器内网络接口
├── lo              127.0.0.1/8         loopback
├── eth0            172.x.x.x           Docker 分配的容器 IP（对外通讯）
├── br-lan          192.168.1.1/24      LAN 网桥（bridge 类型）
├── pppoe-wan       —                   WAN PPPoE 隧道（dummy 模拟）
├── wg0             10.10.58.1/24       WireGuard VPN 接口
└── utun            —                   TUN 设备（phantun/udp2raw 使用）
```

**对应的 LuCI 接口页面（网络 → 接口）：**

| LuCI 接口名 | 协议 | 底层设备 | IP 地址 |
|------------|------|---------|---------|
| lan | 静态地址 | br-lan | 192.168.1.1/24 |
| wan | PPPoE | pppoe-wan | （模拟，无真实拨号）|
| wan_6 | DHCPv6 客户端 | @wan | — |
| wg0 | WireGuard VPN | wg0 | 10.10.58.1/24 |

---

## 网络安全设计

### 为什么 NET_ADMIN 不会影响宿主机？

Docker 容器默认运行在独立的**网络命名空间**（network namespace）中。
`NET_ADMIN` 能力授予的是**容器自己命名空间内**的网络管理权限。

```
宿主机网络命名空间          容器网络命名空间
  iptables 规则               iptables 规则
  路由表                       路由表
  物理网卡 eth0                虚拟网卡 eth0（veth pair）
      ↕ 隔离，互不影响 ↕
```

容器内执行 `ip link add`、`iptables -I`、`wg genkey` 等操作，**只修改容器自己的命名空间**，不影响宿主机。

### 安全措施清单

| 措施 | 实现方式 | 作用 |
|------|---------|------|
| 网络命名空间隔离 | `network_mode: bridge`（默认）| 容器网络与宿主机隔离 |
| 最小权限 | `cap_drop: ALL` + 只添加 NET_ADMIN/NET_RAW | 不给不需要的系统能力 |
| 移除 SYS_MODULE | 不添加此 capability | 防止容器加载宿主机内核模块 |
| 本地绑定 | 端口绑定 `127.0.0.1` | 局域网其他设备无法访问容器 |
| 无 host 模式 | 不使用 `network_mode: host` | 防止直接操作宿主机网络 |

### 关于 WireGuard 内核模块

`kmod-wireguard` 的加载依赖**宿主机内核是否已支持 WireGuard**：
- 宿主机已有 WireGuard 模块（Linux >= 5.6 内置，或手动安装）→ 容器内 `wg0` 创建为真正的 wireguard 接口，`wg show` 等命令完全可用
- 宿主机无 WireGuard 模块 → `wg0` 自动降级为 dummy 接口，LuCI 界面展示不受影响，但无法进行真实的 WireGuard 加密通讯测试

---

## 配置文件说明

`config/` 目录下的文件是 UCI 配置模板，容器每次启动时会被复制到 `/etc/config/`。

| 文件 | 对应 `/etc/config/` | 说明 |
|------|---------------------|------|
| `network` | `/etc/config/network` | 接口定义（lan/wan/wan_6/wg0），**需要按需修改** |
| `firewall` | `/etc/config/firewall` | 防火墙 zone 和规则，含 WireGuard vpn zone |
| `dhcp` | `/etc/config/dhcp` | dnsmasq 和 DHCP 服务配置 |
| `luci` | `/etc/config/luci` | LuCI 语言、主题、缓存设置（开发模式已关闭缓存）|
| `system` | `/etc/config/system` | 主机名（OpenWrt-DevBox）、时区（CST-8）|
| `init-firewall` | 启动时执行的脚本 | 额外 iptables 规则，含 WireGuard fwmark/policy routing |
| `ucitrack` | `/etc/config/ucitrack` | UCI 变更追踪依赖关系，通常不需要修改 |

> **修改 config/ 文件后，需要重启容器才能生效：**
> ```bash
> docker compose restart
> ```

---

## 环境变量参考

在 `docker-compose.yml` 或 `docker-compose.dual.yml` 的 `environment` 段中配置：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `FORCE_REINIT` | `0` | 设为 `1` 时强制重新安装所有 opkg 包 |
| `DEVBOX_ROLE` | `server` | 容器角色：`server`（默认）或 `peer`（双容器模式） |
| `WG_ADDR` | `10.10.58.1/24` | wg0 接口地址（server 用 .1，peer 用 .2）|
| `WG_LISTEN_PORT` | `51820` | WireGuard 监听端口 |
| `WG_SERVER_IP` | `172.30.0.10` | peer 模式下 server 容器的 devnet IP |

---

## dev.sh 命令参考

`dev.sh` 是日常开发的主要操作入口，所有命令都在宿主机上执行。

### 容器管理

```bash
./dev.sh status         # 查看当前模式、容器状态、网络接口、WireGuard 状态
./dev.sh log            # 实时查看容器日志（dual 模式会同时跟随 server/peer）
./dev.sh shell          # 进入主容器 shell（single=单容器，dual=server）
./dev.sh ssh            # SSH 登录 server（等同于 ssh root@localhost -p 2222）
./dev.sh ssh peer       # 双容器模式下 SSH 登录 peer（2223）
./dev.sh reinit         # 强制重新安装所有 opkg 包（dual 模式会重装两边）
```

### 插件开发

```bash
./dev.sh list         # 列出所有已加载的插件和 controller 链接
./dev.sh reload       # 清除 LuCI 缓存并重载 uhttpd（修改代码后执行）
```

### WireGuard 工具

```bash
./dev.sh wg-genkey          # 在容器内生成 WireGuard 密钥对（私钥+公钥）
./dev.sh wg-qr [peer名称]   # 生成客户端配置文件并输出二维码（终端 ANSI）
```

### 网络调试

```bash
./dev.sh net-status   # 完整网络状态：ip addr + ip route + iptables + nftables
```

### 代码提交

```bash
./dev.sh push luci-app-phantun    # 提交并推送单个插件到 GitHub
./dev.sh push-all                 # 提交并推送所有有变更的插件
```

---

## WireGuard 开发指南

### 在容器内测试 WireGuard 配置

```bash
# 进入容器
./dev.sh shell

# 查看 wg0 接口状态
wg show

# 生成服务端密钥对
SERVER_PRIV=$(wg genkey)
SERVER_PUB=$(echo "$SERVER_PRIV" | wg pubkey)
echo "Server Private: $SERVER_PRIV"
echo "Server Public:  $SERVER_PUB"

# 生成客户端密钥对
CLIENT_PRIV=$(wg genkey)
CLIENT_PUB=$(echo "$CLIENT_PRIV" | wg pubkey)

# 添加 peer
wg set wg0 \
    private-key <(echo "$SERVER_PRIV") \
    peer "$CLIENT_PUB" \
    allowed-ips 10.10.58.100/32

# 查看结果
wg show wg0
```

### 生成客户端二维码（qrencode）

```bash
# 方式一：使用 dev.sh
./dev.sh wg-qr myphonepeeer

# 方式二：手动生成
./dev.sh shell
cat << EOF | qrencode -t ANSIUTF8
[Interface]
PrivateKey = $(wg genkey)
Address = 10.10.58.100/24
DNS = 1.1.1.1

[Peer]
PublicKey = $(wg show wg0 public-key)
AllowedIPs = 0.0.0.0/0
Endpoint = YOUR_SERVER_IP:51820
PersistentKeepalive = 25
EOF
```

### LuCI WireGuard 插件路径说明

WireGuard 的 UCI 协议支持由 `luci-proto-wireguard` 提供，接口配置页面在：
`网络 → 接口 → wg0 → 编辑 → 协议: WireGuard VPN`

---

## 通讯类插件流量验证指南

使用 `docker-compose.dual.yml` 启动双容器后：

### phantun 测试流程

```bash
# 1. 启动双容器
docker compose -f docker-compose.dual.yml up -d

# 2. 在 server 容器内启动 phantun 服务端
docker exec -it openwrt-server /bin/ash
# （容器内）
phantun-server -l 4567 -r 127.0.0.1:51820 &

# 3. 在 peer 容器内启动 phantun 客户端
docker exec -it openwrt-peer /bin/ash
# （容器内，172.30.0.10 是 server 的 devnet IP）
phantun-client -l 127.0.0.1:51820 -r 172.30.0.10:4567 &

# 4. 在 peer 容器内验证流量（通过伪装后的 TCP 通道连接 WireGuard）
wg-quick up wg0
ping 10.10.58.1
```

### udp2raw 测试流程

```bash
# server 容器内
udp2raw -s -l 0.0.0.0:4096 -r 127.0.0.1:51820 -k "testpasswd" --raw-mode faketcp &

# peer 容器内
udp2raw -c -l 0.0.0.0:3333 -r 172.30.0.10:4096 -k "testpasswd" --raw-mode faketcp &
# 然后让 WireGuard 连接到本地 3333 端口
```

### 抓包验证

```bash
# 在 server 容器内抓 devnet 上的流量
docker exec openwrt-server tcpdump -i eth0 -n port 4096
```

---

## 常见问题

### 容器启动后 LuCI 无法访问

```bash
# 查看启动日志
./dev.sh log

# 检查 uhttpd 是否运行（single 或 dual/server）
docker exec openwrt-luci-devbox pidof uhttpd 2>/dev/null || docker exec openwrt-server pidof uhttpd

# 手动重启 uhttpd（single 或 dual/server）
docker exec openwrt-luci-devbox /etc/init.d/uhttpd restart 2>/dev/null || docker exec openwrt-server /etc/init.d/uhttpd restart
```

### opkg 包安装失败（网络问题）

```bash
# 检查容器是否能访问外网（single 或 dual/server）
docker exec openwrt-luci-devbox wget -q -O /dev/null https://downloads.openwrt.org 2>/dev/null || docker exec openwrt-server wget -q -O /dev/null https://downloads.openwrt.org

# 如果在中国大陆，可能需要给 Docker 配置代理
# 修改 /etc/docker/daemon.json 添加 HTTP_PROXY
```

### 修改插件代码后界面没有变化

```bash
# 清除 LuCI 缓存并重载
./dev.sh reload

# 如果还没变化，强制清除所有缓存（single 或 dual/server）
docker exec openwrt-luci-devbox rm -rf /tmp/luci-* /tmp/*.luac 2>/dev/null || docker exec openwrt-server rm -rf /tmp/luci-* /tmp/*.luac
./dev.sh reload
```

### wg0 接口创建失败

```bash
# 检查宿主机是否支持 WireGuard
modinfo wireguard

# 如果不支持，wg0 会降级为 dummy 接口，这是正常的
# LuCI 界面功能（配置读写）仍然完整可用
# 只有真实加密通讯测试需要宿主机支持 WireGuard
```

### 强制重新安装所有包

```bash
# 方式一：环境变量
FORCE_REINIT=1 docker compose up -d

# 方式二：dev.sh 命令
./dev.sh reinit
```

---

## 相关项目

- [openwrt-reyan_new](https://github.com/iHub-2020/openwrt-reyan_new) — 配套 LuCI 插件仓库，包含本开发环境对应的所有插件源码

---

## License

MIT
