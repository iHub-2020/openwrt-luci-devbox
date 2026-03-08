# Phantun LuCI 插件生产交付文档

> 文档类型：生产级交付（可审阅版）  
> 本轮交付范围：**仅 `luci-app-phantun` + `phantun` 必要依赖**  
> 非本轮交付：`poweroffdevice` / `udp-speeder` / `udp2raw` / 其他无关插件与扩展验证  
> 适用项目：`openwrt-luci-devbox` + `luci-app-phantun` + `phantun`  
> 维护路径：`/home/reyan/Projects/openwrt-luci-devbox/doc/PHANTUN_生产交付文档.md`

---

## 0. 目标与范围

本文档用于规范以下交付内容（非临时修复记录）：

1. Deployment SOP（明确 devbox 与生产环境区别）
2. 依赖安装策略（`phantun` backend / `luci-app-phantun`）
3. 强制启动后自检项与环境达标门槛
4. 验收清单（登录、页面、`config.js`、保存配置、重启后回归）
5. 故障排查（Not Installed、403、localhost vs 宿主机 IP、缓存问题）
6. 回滚方案

**强制范围说明：**
- 当前交付与验收只覆盖 `luci-app-phantun` 与其必要依赖。
- 不得将 `poweroffdevice`、`udp-speeder`、`udp2raw` 或其他无关插件写入本轮交付范围。
- 不允许把“脚本里已经写了/仓库里已经存在”视为完成；**只有运行态实际生效并通过验收，才算完成**。

---

## 1. Deployment SOP（含 Devbox / 生产环境差异）

## 1.1 环境定义

### Devbox（开发联调环境）
- 形态：Docker 化 OpenWrt 容器（`openwrt/rootfs:x86_64-23.05.5`）
- 容器名：`openwrt-luci-devbox`
- 访问：`http://<宿主机IP>:8080`（本机可用 `http://localhost:8080`）
- 特点：
  - `plugins/` 物理目录挂载到容器 `/luci-plugins`
  - 容器启动时自动加载 `luci-app-*` 与 backend 依赖
  - 开发态支持 `./dev.sh reload` 热重载

### 生产环境（真实 OpenWrt 设备）
- 形态：实体路由器/生产 OpenWrt 系统
- 特点：
  - 不依赖宿主机 `plugins/` 挂载
  - 通过 IPK 安装（或 feed 发布）
  - 不使用 `dev.sh reload`，改为标准服务重启与 LuCI 缓存刷新

## 1.2 Devbox 部署 SOP

### 步骤 A：启动环境
```bash
cd /home/reyan/Projects/openwrt-luci-devbox/
docker compose up -d
```

### 步骤 B：确认服务健康
```bash
docker ps --filter "name=openwrt-luci-devbox"
```
期望：状态为 `healthy`。

### 步骤 C：开发改动生效（热重载）
```bash
cd /home/reyan/Projects/openwrt-luci-devbox/
./dev.sh reload
```
该命令会执行：
- JS view 映射自愈（`/www/luci-static/resources/view/*`）
- backend runtime binary 链接自愈（`/usr/bin/*` 指向 overlay）
- 清理 LuCI 缓存（`/tmp/luci-indexcache` / `luci-modulecache`）
- 重启 `rpcd` + `uhttpd`

### 步骤 D：访问验证
- LuCI 登录页：`http://<宿主机IP>:8080/cgi-bin/luci/`
- Phantun 页面：`/cgi-bin/luci/admin/services/phantun`

## 1.3 生产环境部署 SOP

### 步骤 A：发布前准备
- 锁定版本（建议按 tag 或 commit）
- 准备并校验 IPK：
  - `phantun`（backend）
  - `luci-app-phantun`（前端）
- 备份现网配置：
```bash
cp /etc/config/phantun /etc/config/phantun.bak.$(date +%F-%H%M%S) 2>/dev/null || true
```

### 步骤 B：安装顺序（必须）
> 顺序：先 backend，再 LuCI app。

```bash
opkg update
opkg install /tmp/phantun_*.ipk
opkg install /tmp/luci-app-phantun_*.ipk
```

### 步骤 C：部署后刷新
```bash
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
```

### 步骤 D：功能验收
按本文第 4 章执行全量验收。

---

## 2. 强制启动后自检项与环境达标门槛

> 以下项目属于**基础强制验收项**，不是可选检查。  
> 任何一项未通过，都不得进入 `luci-app-phantun` 页面开发、功能验收或提测。

## 2.1 启动后自检项（必须逐项确认）

1. **LuCI 可登录**
   - 登录页正常打开
   - 管理员账号可登录

2. **System 基础 RPC 正常**
   - System 页面不得出现阻塞性 `RPCError`
   - 若 System 页面异常，判定环境未达标

3. **设备名称 / 左上角品牌 / Logo 显示符合预期**
   - 不允许出现明显品牌错乱、标题异常、Logo 异常
   - 若 UI 基础识别信息异常，判定环境未达标

4. **WireGuard 基础能力正常**
   - 至少应满足当前 devbox 设计预期（正常创建或按文档预期降级）
   - 不允许出现“脚本声明支持，但运行态完全不可用/不可验证”仍被视为通过

5. **Phantun 必要依赖已落盘并可被运行态识别**
   - `/usr/bin/phantun_client`、`/usr/bin/phantun_server` 存在
   - `/etc/init.d/phantun` 存在
   - `/etc/config/phantun` 存在

## 2.2 环境达标门槛（准入门槛）

满足以下条件，才允许进入本轮 phantun 交付开发/测试：

- LuCI 登录正常
- System 页面无阻塞性 RPC 错误
- 设备名称 / Logo / 品牌展示无明显异常
- WireGuard 基础能力符合预期
- phantun backend 运行态文件存在且可识别
- `luci-app-phantun` 页面可打开并完成最小加载

## 2.3 关键原则

- **运行态优先于脚本态**：脚本里写了、配置模板里有了、仓库里提交了，都不代表完成。
- **必须以运行态结果为准**：页面、RPC、资源加载、二进制、保存应用、重启后回归，全部以实际运行结果判定。
- **基础环境问题优先级高于插件功能**：若 WireGuard / System RPC / 品牌显示等基础问题未收敛，不得把 phantun 页面局部可用包装成交付完成。

---

## 3. 依赖安装策略（phantun backend / luci-app）

## 3.1 安装策略总则

- **强依赖关系**：`luci-app-phantun` 依赖 `phantun`（`LUCI_DEPENDS:=+phantun +luci-base`）
- **统一策略**：
  - 开发联调：由 devbox 启动脚本自动处理 backend 依赖加载与二进制落盘
  - 生产发布：使用已验证 IPK，按顺序安装

## 3.2 Devbox 中 backend 自动安装机制（已落地）

容器 `entrypoint.sh` 会自动扫描 `/luci-plugins/*/` 非 `luci-app-*` 目录并执行：
1. 安装 init 脚本（`files/<name>.init -> /etc/init.d/<name>`）
2. 安装默认配置（`files/<name>.config -> /etc/config/<name>`）
3. 根据 `Makefile` 的 `REPO_USER/REPO_NAME/PKG_VERSION` 下载 Release 二进制
4. 将二进制存储到 `/overlay/upper/usr/bin`（持久化）
5. 建立 `/usr/bin/*` 运行时链接（供 LuCI 检测）

## 3.3 生产环境推荐策略

### 推荐：固定版本 IPK 发布（首选）
- 优点：可追溯、可审计、可回滚
- 要求：发布包与验收版本一致，不在生产侧动态拉取不确定版本

### 备选：Feed 安装
- 适用：已有企业内网 feed 管控
- 要求：同样执行版本锁定与灰度发布，不直接跟随 latest

## 3.4 依赖有效性检查（部署后）

```bash
# 二进制
ls -l /usr/bin/phantun_client /usr/bin/phantun_server

# 服务脚本
ls -l /etc/init.d/phantun

# 配置文件
ls -l /etc/config/phantun
```

期望：以上文件均存在且可执行权限正确（binary/init）。

---

## 4. 验收清单（上线准入）

> 说明：以下清单覆盖“登录、页面、config.js、保存配置、重启后回归”五个必验项。  
> 本项目已有 QA 证据可用于审阅：`qa_evidence/p0_2026-03-06_1320/`。

## 4.1 必验项清单

### A. 基础环境强制项（不通过即整体验收失败）

1. **登录可用**
   - 路径：`/cgi-bin/luci/`
   - 标准：可使用管理员账号登录

2. **System 页面 RPC 正常**
   - 标准：不得出现阻塞性 `RPCError`

3. **设备名称 / 左上角品牌 / Logo 正常**
   - 标准：不得出现明显品牌异常、标题异常、Logo 异常

4. **WireGuard 基础能力符合预期**
   - 标准：正常创建或按当前文档说明的降级路径运行
   - 禁止把“脚本声明支持但运行态未生效”判定为通过

### B. Phantun 交付强制项（仅限 phantun + 必要依赖）

5. **页面可用**
   - 路径：`/cgi-bin/luci/admin/services/phantun`
   - 标准：页面正常渲染，无白屏

6. **`config.js` 加载成功**
   - 目标：`/luci-static/resources/view/phantun/config.js`
   - 标准：HTTP 200

7. **必要依赖运行态存在**
   - 标准：`phantun_client` / `phantun_server` / init 脚本 / 配置文件均可在运行态确认

8. **保存配置成功（Save & Apply）**
   - 标准：点击后无致命错误，配置写入成功

9. **重启后回归通过**
   - 场景：服务/容器重启后重复 1~8
   - 标准：仍全部通过

## 4.2 建议验收记录模板（可复制）

- 验收时间：
- 环境：devbox / staging / production
- 访问地址：
- 执行人：
- 结果：PASS / FAIL
- 失败项与日志：
- 附件：截图、网络 HAR、summary JSON

## 4.3 当前已采集证据（可给老板审阅）

- `qa_evidence/p0_2026-03-06_1320/pre_summary.json`
  - `config.js` 命中 200
  - 无关键 console/network 错误
  - Save & Apply 已触发
- `qa_evidence/p0_2026-03-06_1320/post_restart_summary.json`
  - 重启后再次命中 `config.js` 200
  - 无关键 console/network 错误
  - Save & Apply 已触发

---

## 4. 故障排查手册

## 4.1 问题：页面显示 “Phantun Not Installed”

### 现象
- 进入配置页出现 “Phantun Not Installed” 警告

### 根因
- `/usr/bin/phantun_client` 与 `/usr/bin/phantun_server` 缺失或不可执行

### 排查命令
```bash
ls -l /usr/bin/phantun_client /usr/bin/phantun_server
ls -l /overlay/upper/usr/bin/phantun_client /overlay/upper/usr/bin/phantun_server
```

### 处理
- Devbox：
  1. `docker compose restart`
  2. `./dev.sh reload`
  3. 复检上述二进制路径
- 生产：
  1. 重新安装 backend IPK：`opkg install --force-reinstall /tmp/phantun_*.ipk`
  2. 重启 `rpcd` / `uhttpd`

## 4.2 问题：403 错误

### 情况 A（可忽略）
- 少量未授权资源请求（如登录前或会话过期）出现 403
- 若主页面功能正常，且关键接口可用，可判定为非阻塞

### 情况 B（阻塞）
- 登录后访问配置页仍 403

### 排查命令
```bash
ls -l /usr/share/rpcd/acl.d/luci-app-phantun.json
/etc/init.d/rpcd restart
```

### 处理
- 确认 ACL 文件存在
- 重启 `rpcd`
- 清理 LuCI 缓存后重试

## 4.3 问题：localhost 可访问，其他设备不可访问

### 根因
- `localhost` 仅对当前机器有效

### 处理
- 局域网访问请使用宿主机 IP：
  - 例如：`http://192.168.1.157:8080`
- 确认防火墙/安全组放通 8080 端口

## 4.4 问题：页面仍是旧版本（缓存）

### 处理顺序
1. 浏览器强制刷新：`Ctrl+F5`
2. 使用无痕窗口复测
3. 服务端执行：
```bash
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
```
4. Devbox 再执行一次：`./dev.sh reload`

---

## 5. 回滚方案（可执行）

## 5.1 回滚触发条件
- 上线后出现高优先级故障：
  - 无法登录 / 页面不可用
  - 配置无法保存
  - 重启后功能失效
  - 关键错误持续且 15 分钟内无法恢复

## 5.2 Devbox 回滚

### 代码回滚
```bash
cd /home/reyan/Projects/openwrt-luci-devbox/plugins
git log --oneline
# 回到已知稳定版本
git checkout <stable_commit_or_tag>
cd /home/reyan/Projects/openwrt-luci-devbox
./dev.sh reload
```

### 环境回滚（必要时）
```bash
docker compose down
docker compose up -d
```

> 若确认是 overlay 持久层污染，再执行 volume 清理（会丢失容器持久化状态，需审批后操作）：
```bash
docker compose down
docker volume rm openwrt-overlay
docker compose up -d
```

## 5.3 生产回滚

### 步骤
1. 停止服务
```bash
/etc/init.d/phantun stop
```
2. 卸载当前版本
```bash
opkg remove luci-app-phantun phantun
```
3. 安装上一稳定版本 IPK
```bash
opkg install /tmp/rollback/phantun_<stable>.ipk
opkg install /tmp/rollback/luci-app-phantun_<stable>.ipk
```
4. 恢复配置（如需要）
```bash
cp /etc/config/phantun.bak.<timestamp> /etc/config/phantun
```
5. 刷新服务
```bash
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
/etc/init.d/phantun restart
```
6. 按第 3 章做最小回归验证

## 5.4 回滚后准出标准
- 登录正常
- 配置页正常
- `config.js` 200
- Save & Apply 可执行
- 重启后不回退

---

## 6. 交付建议（管理层视角）

1. 将本文件纳入发布包（与版本号绑定）。
2. 每次发版附 1 份验收 summary（JSON + 截图）作为客观证据。
3. 发布审批必须包含：
   - 版本锁定信息
   - 安装顺序确认（backend → luci-app）
   - 回滚包可用性确认

---

## 7. 附录：常用命令速查

```bash
# 启动/检查
cd /home/reyan/Projects/openwrt-luci-devbox
docker compose up -d
docker ps --filter "name=openwrt-luci-devbox"

# 热重载
./dev.sh reload

# 容器日志
./dev.sh log

# 进入容器
./dev.sh ssh

# LuCI 缓存与服务刷新（容器内或生产机）
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
```
