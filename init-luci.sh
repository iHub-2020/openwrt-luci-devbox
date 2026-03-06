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

CONTAINER_SINGLE="openwrt-luci-devbox"
CONTAINER_SERVER="openwrt-server"
CONTAINER_PEER="openwrt-peer"
TIMEOUT=180    # 最长等待秒数
INTERVAL=3

get_mode() {
    if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_SERVER"; then
        echo dual
    elif docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_SINGLE"; then
        echo single
    else
        echo none
    fi
}

get_primary_container() {
    case "$(get_mode)" in
        dual) echo "$CONTAINER_SERVER" ;;
        single) echo "$CONTAINER_SINGLE" ;;
        *) return 1 ;;
    esac
}

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
until PRIMARY_CONTAINER="$(get_primary_container 2>/dev/null)" && docker exec "$PRIMARY_CONTAINER" true 2>/dev/null; do
    sleep "$INTERVAL"
    elapsed=$((elapsed + INTERVAL))
    if [ "$elapsed" -ge "$TIMEOUT" ]; then
        echo -e "${RED}❌ 等待超时（${TIMEOUT}s），容器未启动${NC}"
        echo "  请先执行: docker compose up -d 或 docker compose -f docker-compose.dual.yml up -d"
        exit 1
    fi
done
MODE="$(get_mode)"
echo -e "${GREEN}✅ 容器已运行（模式: ${MODE}）${NC}"

# ================================================================
# 强制重新初始化（--reinit 参数）
# ================================================================
if [ "$REINIT" = "1" ]; then
    echo -e "${YELLOW}⚠️  强制重新初始化（将重新安装所有包）...${NC}"
    if [ "$MODE" = "dual" ]; then
        for c in "$CONTAINER_SERVER" "$CONTAINER_PEER"; do
            docker exec "$c" rm -f /etc/.devbox-initialized
            docker exec "$c" sh /docker-init.sh
        done
    else
        docker exec "$PRIMARY_CONTAINER" rm -f /etc/.devbox-initialized
        docker exec "$PRIMARY_CONTAINER" sh /docker-init.sh
    fi
    echo -e "${GREEN}✅ 重新初始化完成${NC}"
fi

# ================================================================
# 等待 LuCI Web 界面就绪
# ================================================================
echo -e "${YELLOW}⏳ 等待 LuCI Web 就绪...${NC}"
elapsed=0
until docker exec "$PRIMARY_CONTAINER" sh -lc "wget -S -O /dev/null http://127.0.0.1/cgi-bin/luci/ 2>&1 | grep -Eq 'HTTP/[0-9.]+ (200|302|403)'" > /dev/null 2>&1; do
    sleep "$INTERVAL"
    elapsed=$((elapsed + INTERVAL))
    printf "  已等待 %ds...\r" "$elapsed"
    if [ "$elapsed" -ge "$TIMEOUT" ]; then
        echo -e "${RED}❌ LuCI 未在 ${TIMEOUT}s 内就绪，请检查日志：${NC}"
        echo "  docker logs $PRIMARY_CONTAINER"
        exit 1
    fi
done

echo ""
echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN}✅ LuCI 开发环境已就绪！${NC}"
echo -e "   🌐 Web 界面：http://localhost:8080  (root/password)"
echo -e "   🔑 SSH(server)：ssh root@localhost -p 2222"
if [ "$MODE" = "dual" ]; then
    echo -e "   🔑 SSH(peer)  ：ssh root@localhost -p 2223"
fi
echo -e "${GREEN}======================================================${NC}"
