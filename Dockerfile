# ==============================================================
#  Dockerfile — OpenWrt 24.10.3 x86_64 开发镜像
#
#  从 OpenWrt 官方下载 rootfs.tar.gz，先在构建阶段解包，
#  再复制到 scratch 目标镜像，确保得到真正可启动的 rootfs。
# ============================================================== 

FROM alpine:3.20 AS fetch-rootfs

ARG OPENWRT_ROOTFS_URL="https://downloads.openwrt.org/releases/24.10.3/targets/x86/64/openwrt-24.10.3-x86-64-rootfs.tar.gz"

RUN apk add --no-cache ca-certificates curl tar gzip
RUN mkdir -p /rootfs \
    && curl -fsSL "$OPENWRT_ROOTFS_URL" -o /tmp/rootfs.tar.gz \
    && tar -xzf /tmp/rootfs.tar.gz -C /rootfs \
    && rm -f /tmp/rootfs.tar.gz

FROM scratch

COPY --from=fetch-rootfs /rootfs/ /

LABEL org.opencontainers.image.title="OpenWrt DevBox"
LABEL org.opencontainers.image.version="24.10.3"
LABEL org.opencontainers.image.description="OpenWrt 24.10.3 x86_64 LuCI plugin development environment"

CMD ["/bin/ash"]
