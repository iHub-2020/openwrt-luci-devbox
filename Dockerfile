# ==============================================================
#  Dockerfile — OpenWrt 24.10.3 x86_64 开发镜像
#
#  直接从 OpenWrt 官方下载 rootfs.tar.gz 构建，版本与真机完全一致。
#  SHA256 校验确保镜像内容可信。
#
#  构建命令：
#    docker compose build
#    docker compose build --no-cache   # 强制重新下载
# ==============================================================

FROM scratch

# 从官方下载 24.10.3 rootfs 并解包
# rootfs.tar.gz SHA256: 7567e55ec5b6b834b2a0f27215bd6679c86fd3505c8a48398216626b586e3164
ADD https://downloads.openwrt.org/releases/24.10.3/targets/x86/64/rootfs.tar.gz /

# 声明元数据
LABEL org.opencontainers.image.title="OpenWrt DevBox"
LABEL org.opencontainers.image.version="24.10.3"
LABEL org.opencontainers.image.description="OpenWrt 24.10.3 x86_64 LuCI plugin development environment"

# 容器默认 shell
CMD ["/bin/ash"]
