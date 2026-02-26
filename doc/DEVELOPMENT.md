# OpenWrt LuCI 插件开发手册

## 目录结构

```
/home/reyan/Projects/openwrt-dev/
├── doc/                          # 文档目录
│   ├── DEVELOPMENT.md            # 本开发手册
│   └── USAGE.md                  # 使用/调试手册
├── config/                       # OpenWrt UCI 配置模板
├── packages/                     # IPK 包目录（挂载到容器 /packages）
├── plugins/                      # 插件开发目录（挂载到容器 /luci-plugins）
│   └── openwrt-reyan_new/        # 插件仓库
│       ├── luci-app-lucky/
│       ├── luci-app-phantun/
│       ├── luci-app-poweroffdevice/
│       ├── luci-app-udp-speeder/
│       └── luci-app-udp-tunnel/
├── dev.sh                        # 开发辅助脚本（插件链接/重载）
├── docker-init.sh                # Docker 初始化脚本
└── init-luci.sh                  # LuCI 初始化脚本

/opt/openwrt-dev/                 # 容器持久化配置
├── docker-compose.yml            # Docker Compose 配置
└── entrypoint.sh                 # 容器启动脚本
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

1. 通过 Portainer Stack 部署：
   - 将 `/opt/openwrt-dev/docker-compose.yml` 作为 stack 文件
   - 容器会自动启动并安装依赖（首次约需 30 秒）

2. 或命令行启动：
   ```bash
   cd /opt/openwrt-dev
   docker compose up -d
   ```

3. 验证容器状态：
   ```bash
   docker ps --filter "name=openwrt-dev"
   # 状态应为 (healthy)
   ```

## 新建插件流程

### 1. 创建插件目录

```bash
cd /home/reyan/Projects/openwrt-dev/plugins/openwrt-reyan_new/
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

### 3. 链接插件到容器

```bash
cd /home/reyan/Projects/openwrt-dev/
./dev.sh link luci-app-myplugin
./dev.sh reload
```

### 4. 访问 LuCI

打开浏览器访问：http://localhost:8080（用户名：root，密码：password）

## 容器内路径映射

| 宿主机路径 | 容器内路径 | 说明 |
|-----------|-----------|------|
| `/home/reyan/Projects/openwrt-dev/plugins` | `/luci-plugins` | 插件开发目录 |
| `/home/reyan/Projects/openwrt-dev/packages` | `/packages` | IPK 包目录 |
| `openwrt-overlay` (Docker Volume) | `/overlay` | 系统持久化 |

## dev.sh 使用说明

```bash
./dev.sh list                          # 列出所有插件
./dev.sh link luci-app-poweroffdevice  # 链接插件到容器
./dev.sh reload                        # 重启 uhttpd 使改动生效
./dev.sh status                        # 查看容器状态
./dev.sh log                           # 查看容器日志
./dev.sh ssh                           # SSH 登录容器
```

## 热重载开发流程

1. 修改插件 Lua/HTML 代码
2. 执行 `./dev.sh reload`
3. 刷新浏览器查看效果

> 无需重启容器，uhttpd 重启后改动立即生效。

## 更新插件仓库

```bash
cd /home/reyan/Projects/openwrt-dev/plugins/openwrt-reyan_new/
git pull
./dev.sh reload
```
