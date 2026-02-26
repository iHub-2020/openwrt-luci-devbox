#!/bin/sh
# ============================================================
# OpenWrt LuCI 插件开发辅助脚本
# 用法: ./dev.sh [命令] [插件名]
# ============================================================

CONTAINER="openwrt-luci-devbox"
PLUGINS_DIR="/luci-plugins"
LOCAL_PLUGINS_DIR="/home/reyan/Projects/openwrt-luci-devbox/plugins"

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
  echo "  push   [插件名]   模拟验证后将插件推送到 GitHub"
  echo "  push-all          推送所有有改动的插件到 GitHub"
  echo ""
  echo "开发流程:"
  echo "  1. 在 $LOCAL_PLUGINS_DIR/<插件名>/ 中开发插件"
  echo "  2. ./dev.sh reload      （容器已自动挂载，刷新 LuCI 即可）"
  echo "  3. 在浏览器 http://localhost:8080 验证功能"
  echo "  4. ./dev.sh push <插件名>   （验证成功后推送到 GitHub）"
  echo ""
  echo "示例:"
  echo "  $0 link luci-app-poweroffdevice"
  echo "  $0 reload"
  echo "  $0 push luci-app-poweroffdevice"
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
  echo "[INFO] 取消链接: $PLUGIN"
  docker exec "$CONTAINER" find /usr/lib/lua/luci -type l 2>/dev/null | \
    xargs -I{} docker exec "$CONTAINER" sh -c "readlink {} | grep -q '$PLUGIN' && rm -f {}"
  echo "[INFO] 完成"
}

cmd_reload() {
  check_container
  echo "[INFO] 重启 uhttpd..."
  docker exec "$CONTAINER" /etc/init.d/uhttpd restart 2>/dev/null
  echo "[INFO] uhttpd 已重启，刷新浏览器即可看到改动"
}

cmd_log() {
  docker logs -f "$CONTAINER"
}

cmd_ssh() {
  echo "[INFO] SSH 登录容器 (密码: password)"
  ssh -o StrictHostKeyChecking=no -p 2222 root@localhost
}

cmd_list() {
  echo "[INFO] 可用插件列表 ($LOCAL_PLUGINS_DIR):"
  ls "$LOCAL_PLUGINS_DIR" | grep "luci-app-"
}

cmd_status() {
  docker ps --filter "name=$CONTAINER" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

cmd_push() {
  PLUGIN="$1"
  if [ -z "$PLUGIN" ]; then
    echo "[ERROR] 请指定插件名，例如: $0 push luci-app-poweroffdevice"
    exit 1
  fi
  PLUGIN_PATH="$LOCAL_PLUGINS_DIR/$PLUGIN"
  if [ ! -d "$PLUGIN_PATH" ]; then
    echo "[ERROR] 插件目录不存在: $PLUGIN_PATH"
    exit 1
  fi

  echo "[INFO] 推送插件 $PLUGIN 到 GitHub..."
  cd "$LOCAL_PLUGINS_DIR" || exit 1

  # 检查是否有改动
  CHANGES=$(git status --short "$PLUGIN" 2>/dev/null)
  if [ -z "$CHANGES" ]; then
    echo "[INFO] $PLUGIN 没有改动，无需推送"
    exit 0
  fi

  echo "[INFO] 改动内容:"
  git diff --stat "$PLUGIN" 2>/dev/null

  git add "$PLUGIN"
  git commit -m "feat($PLUGIN): update plugin after container validation"
  git push origin main

  if [ $? -eq 0 ]; then
    echo "[SUCCESS] $PLUGIN 已成功推送到 GitHub"
    echo "[INFO] 仓库: https://github.com/iHub-2020/openwrt-reyan_new"
  else
    echo "[ERROR] 推送失败，请检查 git 配置"
    exit 1
  fi
}

cmd_push_all() {
  echo "[INFO] 检查 openwrt-reyan_new 所有改动..."
  cd "$LOCAL_PLUGINS_DIR" || exit 1

  CHANGES=$(git status --short 2>/dev/null)
  if [ -z "$CHANGES" ]; then
    echo "[INFO] 没有任何改动，无需推送"
    exit 0
  fi

  echo "[INFO] 改动内容:"
  git status --short

  echo ""
  printf "[CONFIRM] 确认推送所有改动到 GitHub? (y/N): "
  read confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo "[INFO] 已取消"
    exit 0
  fi

  git add -A
  git commit -m "feat: update plugins after container validation"
  git push origin main

  if [ $? -eq 0 ]; then
    echo "[SUCCESS] 所有改动已推送到 GitHub"
    echo "[INFO] 仓库: https://github.com/iHub-2020/openwrt-reyan_new"
  else
    echo "[ERROR] 推送失败"
    exit 1
  fi
}

# 主逻辑
case "$1" in
  link)     cmd_link "$2" ;;
  unlink)   cmd_unlink "$2" ;;
  reload)   cmd_reload ;;
  log)      cmd_log ;;
  ssh)      cmd_ssh ;;
  list)     cmd_list ;;
  status)   cmd_status ;;
  push)     cmd_push "$2" ;;
  push-all) cmd_push_all ;;
  *)        usage ;;
esac
