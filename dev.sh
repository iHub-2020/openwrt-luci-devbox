#!/bin/sh
# ============================================================
# OpenWrt LuCI 插件开发辅助脚本
# 用法: ./dev.sh [命令] [插件名]
# ============================================================

CONTAINER="openwrt-dev"
PLUGINS_DIR="/luci-plugins/openwrt-reyan_new"

usage() {
  echo "用法: $0 [命令] [插件名]"
  echo ""
  echo "命令:"
  echo "  link   [插件名]   将插件链接到容器 LuCI 目录（开始开发）"
  echo "  unlink [插件名]   取消插件链接"
  echo "  reload            重启 uhttpd（使改动生效）"
  echo "  log               查看容器日志"
  echo "  ssh               SSH 登录容器"
  echo "  list              列出可用插件"
  echo "  status            查看容器状态"
  echo ""
  echo "示例:"
  echo "  $0 link luci-app-poweroffdevice"
  echo "  $0 reload"
  exit 0
}

check_container() {
  if ! docker ps --filter "name=$CONTAINER" --filter "status=running" -q | grep -q .; then
    echo "[ERROR] 容器 $CONTAINER 未运行！"
    exit 1
  fi
}

cmd_link() {
  PLUGIN="$1"
  if [ -z "$PLUGIN" ]; then
    echo "[ERROR] 请指定插件名"
    exit 1
  fi
  check_container
  PLUGIN_PATH="$PLUGINS_DIR/$PLUGIN"

  # 检查插件是否存在
  docker exec "$CONTAINER" test -d "$PLUGIN_PATH" || {
    echo "[ERROR] 插件 $PLUGIN 不存在于 $PLUGIN_PATH"
    exit 1
  }

  echo "[INFO] 链接插件: $PLUGIN"

  # 链接 luasrc -> /usr/lib/lua/luci/
  if docker exec "$CONTAINER" test -d "$PLUGIN_PATH/luasrc"; then
    docker exec "$CONTAINER" sh -c "
      find $PLUGIN_PATH/luasrc -mindepth 1 -maxdepth 1 -type d | while read src; do
        name=\$(basename \$src)
        target=/usr/lib/lua/luci/\$name
        mkdir -p \$target
        for f in \$src/*; do
          ln -sf \$f \$target/ 2>/dev/null && echo \"  [LINK] \$f -> \$target/\"
        done
      done
    "
  fi

  # 链接 root/ -> /
  if docker exec "$CONTAINER" test -d "$PLUGIN_PATH/root"; then
    docker exec "$CONTAINER" sh -c "
      cd $PLUGIN_PATH/root && find . -type f | while read f; do
        target=\"/\${f#./}\"
        mkdir -p \"\$(dirname \$target)\"
        ln -sf \"$PLUGIN_PATH/root/\${f#./}\" \"\$target\" 2>/dev/null && echo \"  [LINK] \$target\"
      done
    "
  fi

  echo "[INFO] 插件 $PLUGIN 链接完成"
  echo "[INFO] 执行 '$0 reload' 使改动生效"
}

cmd_unlink() {
  PLUGIN="$1"
  if [ -z "$PLUGIN" ]; then
    echo "[ERROR] 请指定插件名"
    exit 1
  fi
  check_container
  echo "[INFO] 取消链接: $PLUGIN (需要手动清理符号链接)"
  docker exec "$CONTAINER" find /usr/lib/lua/luci -type l 2>/dev/null | \
    xargs -I{} docker exec "$CONTAINER" sh -c "readlink {} | grep -q '$PLUGIN' && rm -f {}"
  echo "[INFO] 完成"
}

cmd_reload() {
  check_container
  echo "[INFO] 重启 uhttpd..."
  docker exec "$CONTAINER" /etc/init.d/uhttpd restart 2>/dev/null
  echo "[INFO] uhttpd 已重启，LuCI 已刷新"
}

cmd_log() {
  docker logs -f "$CONTAINER"
}

cmd_ssh() {
  echo "[INFO] SSH 登录容器 (密码: password)"
  ssh -o StrictHostKeyChecking=no -p 2222 root@localhost
}

cmd_list() {
  echo "[INFO] 可用插件列表:"
  ls /home/reyan/Projects/openwrt-dev/plugins/openwrt-reyan_new/ | grep "luci-app-"
}

cmd_status() {
  docker ps --filter "name=$CONTAINER" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

# 主逻辑
case "$1" in
  link)   cmd_link "$2" ;;
  unlink) cmd_unlink "$2" ;;
  reload) cmd_reload ;;
  log)    cmd_log ;;
  ssh)    cmd_ssh ;;
  list)   cmd_list ;;
  status) cmd_status ;;
  *)      usage ;;
esac
