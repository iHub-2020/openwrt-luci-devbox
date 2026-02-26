# OpenWrt LuCI 开发环境 使用/调试手册

## 快速开始

### 访问 LuCI Web 界面

- 地址：http://localhost:8080
- 用户名：`root`
- 密码：`password`

### SSH 登录容器

```bash
ssh -o StrictHostKeyChecking=no -p 2222 root@localhost
# 密码: password

# 或使用开发脚本
cd /home/reyan/Projects/openwrt-dev/
./dev.sh ssh
```

---

## 容器管理

### 查看容器状态

```bash
./dev.sh status
# 或
docker ps --filter "name=openwrt-dev"
```

### 查看容器日志

```bash
# 实时跟踪日志
./dev.sh log
# 或
docker logs -f openwrt-dev

# 查看最近 50 行
docker logs --tail 50 openwrt-dev
```

### 重启容器

```bash
cd /opt/openwrt-dev/
docker compose restart
```

### 停止/启动容器

```bash
cd /opt/openwrt-dev/
docker compose stop
docker compose start
```

### 完全重建（会重新安装依赖包）

```bash
cd /opt/openwrt-dev/
docker compose down
docker compose up -d
```

---

## 插件开发调试

### 第一步：链接插件到容器

```bash
cd /home/reyan/Projects/openwrt-dev/
./dev.sh list                           # 查看所有可用插件
./dev.sh link luci-app-poweroffdevice   # 链接指定插件
```

### 第二步：重载 LuCI

```bash
./dev.sh reload
```

### 第三步：在浏览器中查看效果

打开 http://localhost:8080，在"服务"菜单下查看插件

### 修改代码后刷新

1. 直接编辑 `/home/reyan/Projects/openwrt-dev/plugins/openwrt-reyan_new/luci-app-xxx/` 目录中的文件
2. 执行 `./dev.sh reload`
3. 刷新浏览器（Ctrl+F5 强制刷新）

> 因为使用符号链接，宿主机修改会即时反映到容器中，无需重启容器。

---

## 容器内调试

### 进入容器 Shell

```bash
docker exec -it openwrt-dev /bin/sh
```

### 查看 LuCI 错误日志

```bash
docker exec openwrt-dev logread | grep -i "luci\|error\|warn"
```

### 检查 uhttpd 状态

```bash
docker exec openwrt-dev /etc/init.d/uhttpd status
```

### 手动重启 uhttpd

```bash
docker exec openwrt-dev /etc/init.d/uhttpd restart
```

### 查看已安装包

```bash
docker exec openwrt-dev opkg list-installed
```

### 安装额外的包

```bash
docker exec openwrt-dev opkg update
docker exec openwrt-dev opkg install <包名>
```

---

## 健康检查说明

Docker Compose 配置了健康检查：

```yaml
healthcheck:
  test: ["CMD-SHELL", "wget -q -O /dev/null http://localhost/ || exit 1"]
  interval: 30s
  timeout: 10s
  retries: 3
  start_period: 60s
```

- 每 30 秒检查一次 uhttpd 是否响应
- 启动后 60 秒开始检查（等待首次安装依赖完成）
- 连续 3 次失败才标记为 unhealthy

### 状态说明

| 状态 | 说明 |
|------|------|
| `starting` | 容器刚启动，在 start_period 内 |
| `healthy` | uhttpd 正常响应 |
| `unhealthy` | uhttpd 无响应，需要排查 |

---

## 常见问题排查

### 问题：容器显示 unhealthy

```bash
# 查看容器日志找原因
docker logs openwrt-dev | tail -20

# 进入容器手动检查
docker exec -it openwrt-dev /bin/sh
/etc/init.d/uhttpd status
wget -q -O /dev/null http://localhost/ && echo "OK" || echo "FAIL"
```

### 问题：LuCI 页面打不开

```bash
# 检查端口是否映射正确
docker port openwrt-dev

# 检查 uhttpd 是否运行
docker exec openwrt-dev ps | grep uhttpd
```

### 问题：插件在 LuCI 菜单中不显示

1. 确认插件已正确链接：`./dev.sh link luci-app-xxx`
2. 重载 uhttpd：`./dev.sh reload`
3. 清除浏览器缓存（Ctrl+F5）
4. 检查控制器代码的 `entry()` 注册是否正确

### 问题：首次安装慢

首次启动需要从官方源下载并安装依赖包（约 30~60 秒），这是正常的。
后续重启会检测到包已存在并跳过安装。

---

## 端口说明

| 端口 | 说明 |
|------|------|
| 8080 | LuCI Web 界面（HTTP） |
| 8443 | LuCI Web 界面（HTTPS） |
| 2222 | SSH 访问 |

---

## 开发工具脚本 dev.sh

```
用法: ./dev.sh [命令] [插件名]

命令:
  link   [插件名]   将插件链接到容器 LuCI 目录
  unlink [插件名]   取消插件链接
  reload            重启 uhttpd（使改动生效）
  log               查看容器日志
  ssh               SSH 登录容器
  list              列出可用插件
  status            查看容器状态

示例:
  ./dev.sh list
  ./dev.sh link luci-app-poweroffdevice
  ./dev.sh reload
  ./dev.sh log
```
