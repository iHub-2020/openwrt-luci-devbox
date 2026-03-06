#!/bin/bash
# ==============================================================
#  init-luci.sh — 宿主机侧辅助脚本
#
#  原来的职责（在容器外通过 docker exec 安装包）已迁移到
#  docker-init.sh（容器内自动执行）。
#
#  现在的职责：
#    1. 等待容器就绪并验证 LuCI 健康状态
#    2. 可手动触发重新初始化（强制重装包）
#    3. 可用于 CI/CD 流水线的启动等待
#
#  用法：
#    bash init-luci.sh          # 等待容器就绪
#    bash init-luci.sh --reinit # 强制重新安装所有包
# ==============================================================

set -e

CONTAINER="openwrt-luci-devbox"
TIMEOUT=180    # 最长等待秒数
INTERVAL=3

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# ================================================================
# 参数解析
# ================================================================
REINIT=0
[ "${1}" = "--reinit" ] && REINIT=1

# ================================================================
# 等待容器运行
# ================================================================
echo -e "${YELLOW}⏳ 等待容器启动...${NC}"
elapsed=0
until docker exec "$CONTAINER" true 2>/dev/null; do
    sleep "$INTERVAL"
    elapsed=$((elapsed + INTERVAL))
    if [ "$elapsed" -ge "$TIMEOUT" ]; then
        echo -e "${RED}❌ 等待超时（${TIMEOUT}s），容器未启动${NC}"
        exit 1
    fi
done
echo -e "${GREEN}✅ 容器已运行${NC}"

# ================================================================
# 强制重新初始化（--reinit 参数）
# ================================================================
if [ "$REINIT" = "1" ]; then
    echo -e "${YELLOW}⚠️  强制重新初始化（将重新安装所有包）...${NC}"
    docker exec "$CONTAINER" rm -f /etc/.devbox-initialized
    docker exec "$CONTAINER" sh /docker-init.sh
    echo -e "${GREEN}✅ 重新初始化完成${NC}"
fi

# ================================================================
# 等待 LuCI Web 界面就绪
# ================================================================
echo -e "${YELLOW}⏳ 等待 LuCI Web 就绪...${NC}"
elapsed=0
until docker exec "$CONTAINER" curl -sf http://127.0.0.1/cgi-bin/luci/ > /dev/null 2>&1; do
    sleep "$INTERVAL"
    elapsed=$((elapsed + INTERVAL))
    printf "  已等待 %ds...\r" "$elapsed"
    if [ "$elapsed" -ge "$TIMEOUT" ]; then
        echo -e "${RED}❌ LuCI 未在 ${TIMEOUT}s 内就绪，请检查日志：${NC}"
        echo "  docker logs $CONTAINER"
        exit 1
    fi
done

echo ""
echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN}✅ LuCI 开发环境已就绪！${NC}"
echo -e "   🌐 Web 界面：http://localhost:8080  (root/password)"
echo -e "   🔑 SSH     ：ssh root@localhost -p 2222"
echo -e "${GREEN}======================================================${NC}"
