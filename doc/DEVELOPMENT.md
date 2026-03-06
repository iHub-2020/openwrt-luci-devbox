# OpenWrt LuCI 插件开发手册

## 目录结构

```
/home/reyan/Projects/openwrt-luci-devbox/
├── doc/                          # 文档目录
│   ├── DEVELOPMENT.md            # 本开发手册
│   └── USAGE.md                  # 使用/调试手册
├── config/                       # OpenWrt UCI 配置模板 / seed
├── plugins/                      # 插件开发目录（挂载到容器 /luci-plugins）
│   ├── luci-app-phantun/
│   ├── luci-app-poweroffdevice/
│   ├── luci-app-udp-speeder/
│   └── luci-app-udp-tunnel/
├── dev.sh                        # 开发辅助脚本（重载/状态/SSH）
├── docker-init.sh                # 容器初始化脚本
├── docker-compose.yml            # 单容器模式
├── docker-compose.dual.yml       # 双容器模式（通讯类插件）
├── entrypoint.sh                 # 容器启动脚本
└── init-luci.sh                  # LuCI 就绪等待脚本
```

## 插件目录结构规范

每个 LuCI 插件应遵循以下目录结构：

```
luci-app-xxx/
├── Makefile              # OpenWrt 编译配置
├── README.md             # 插件说明
├── luasrc/               # Lua 源代码
│   ├── controller/       # 控制器（路由注册）
│   │   └── xxx.lua
│   ├── model/            # 数据模型（UCI 配置）
│   │   └── cbi/
│   │       └── xxx.lua
│   └── view/             # 视图模板
│       └── xxx/
│           └── xxx.htm
├── root/                 # 根文件系统文件
│   └── usr/
│       ├── share/
│       │   └── rpcd/
│       │       └── acl.d/
│       │           └── luci-app-xxx.json  # 权限配置
│       └── libexec/
│           └── rpcd/
│               └── luci.xxx               # RPC 脚本
└── po/                   # 国际化翻译
    └── zh-cn/
        └── xxx.po
```

## 开发环境搭建

### 前提条件

- Docker 已安装
- Portainer 已配置
- 本仓库已克隆

### 启动开发环境

1. 命令行启动（普通 LuCI/UI 插件）
   ```bash
   cd /home/reyan/Projects/openwrt-luci-devbox
   docker compose up -d
   ```

2. 命令行启动（通讯类插件：如 phantun/udp2raw）
   ```bash
   cd /home/reyan/Projects/openwrt-luci-devbox
   docker compose -f docker-compose.dual.yml up -d
   ```

3. 验证容器状态：
   ```bash
   docker ps | grep -E 'openwrt-luci-devbox|openwrt-server|openwrt-peer'
   ```

## 新建插件流程

### 1. 创建插件目录

```bash
cd /home/reyan/Projects/openwrt-luci-devbox/plugins
mkdir -p luci-app-myplugin/luasrc/controller
mkdir -p luci-app-myplugin/luasrc/view/myplugin
mkdir -p luci-app-myplugin/root/usr/share/rpcd/acl.d
mkdir -p luci-app-myplugin/po/zh-cn
```

### 2. 创建控制器

```bash
cat > luci-app-myplugin/luasrc/controller/myplugin.lua << 'EOF'
module("luci.controller.myplugin", package.seeall)

function index()
    if not nixio.fs.access("/etc/config/myplugin") then
        return
    end
    local page = entry({"admin", "services", "myplugin"},
                       cbi("myplugin"),
                       _("My Plugin"), 100)
    page.dependent = true
end
EOF
```

### 3. 自动加载插件并重载 LuCI

```bash
cd /home/reyan/Projects/openwrt-luci-devbox/
# 插件目录挂载在 /luci-plugins，启动时自动扫描加载
./dev.sh reload
```

### 4. 访问 LuCI

打开浏览器访问：http://localhost:8080（用户名：root，密码：password）

## 容器内路径映射

| 宿主机路径 | 容器内路径 | 说明 |
|-----------|-----------|------|
| `/home/reyan/Projects/openwrt-luci-devbox/plugins` | `/luci-plugins` | 插件开发目录 |
| `opkg-cache` / `opkg-cache-server` / `opkg-cache-peer` | `/var/opkg-lists` | opkg 索引缓存 |

## dev.sh 使用说明

```bash
./dev.sh list          # 列出所有插件
./dev.sh reload        # 重载 LuCI / uhttpd 使改动生效
./dev.sh status        # 查看当前模式、容器状态与 WireGuard 状态
./dev.sh log           # 查看容器日志（dual 模式会同时跟随 server/peer）
./dev.sh ssh           # SSH 登录 server
./dev.sh ssh peer      # 双容器模式下 SSH 登录 peer
```

## 热重载开发流程

1. 修改插件 Lua/HTML 代码
2. 执行 `./dev.sh reload`
3. 刷新浏览器查看效果

> 无需重启容器，uhttpd 重启后改动立即生效。

## 更新插件仓库

```bash
cd /home/reyan/Projects/openwrt-luci-devbox/plugins
git pull
cd ..
./dev.sh reload
```
