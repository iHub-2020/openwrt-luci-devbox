#!/bin/sh
# OpenWrt Docker Entrypoint

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

log "INFO: Starting OpenWrt container..."
mount -o remount,rw / 2>/dev/null
mkdir -p /var/lock /var/run /tmp

echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 8.8.4.4" >> /etc/resolv.conf
log "INFO: DNS configured"

DOCKER_IP=$(ip -4 addr show eth0 2>/dev/null | grep inet | awk '{print $2}')
DOCKER_GW=$(ip route | grep default | awk '{print $3}')
IP_ADDR="${DOCKER_IP%%/*}"
log "INFO: IP=$IP_ADDR GW=$DOCKER_GW"

cat > /etc/config/network << NETEOF
config interface 'loopback'
option device 'lo'
option proto 'static'
option ipaddr '127.0.0.1'
option netmask '255.0.0.0'
config interface 'lan'
option device 'eth0'
option proto 'static'
option ipaddr '$IP_ADDR'
option netmask '255.255.0.0'
option gateway '$DOCKER_GW'
NETEOF
log "INFO: Network configured"

: > /etc/config/firewall
/etc/init.d/firewall stop 2>/dev/null
/etc/init.d/firewall disable 2>/dev/null
/etc/init.d/dnsmasq stop 2>/dev/null
/etc/init.d/dnsmasq disable 2>/dev/null
log "INFO: Firewall/dnsmasq disabled"

echo "root:password" | chpasswd 2>/dev/null
log "INFO: Root password set"

if ! command -v curl > /dev/null 2>&1; then
  log "INFO: First boot - installing packages..."
  opkg update && opkg install curl luci-i18n-base-zh-cn
  log "INFO: Packages installed"
else
  log "INFO: Packages already installed, skipping"
fi

# ─────────────────────────────────────────────────────────────
# Auto-load LuCI plugins from /luci-plugins/luci-app-*
#
# Supported plugin structures:
# [Classic Lua]   luasrc/controller/ → /usr/lib/lua/luci/controller/
#                 luasrc/view/       → /usr/lib/lua/luci/view/
# [New JS LuCI]   htdocs/luci-static/resources/view/<name>/ → /www/luci-static/resources/view/<name>/
# [Both]          root/              → / (merged into rootfs)
# ─────────────────────────────────────────────────────────────
load_plugins() {
  mkdir -p /usr/lib/lua/luci/controller /usr/lib/lua/luci/view /www/luci-static/resources/view

  # Scan for luci-app-* directly under /luci-plugins/
  for plugin_dir in /luci-plugins/luci-app-*; do
    [ -d "$plugin_dir" ] || continue
    plugin_name=$(basename "$plugin_dir")

    # ── Classic Lua: luasrc/controller/*.lua ──────────────────
    if [ -d "$plugin_dir/luasrc/controller" ]; then
      for f in "$plugin_dir/luasrc/controller"/*.lua; do
        [ -f "$f" ] || continue
        fname=$(basename "$f")
        if [ ! -e "/usr/lib/lua/luci/controller/$fname" ]; then
          ln -sf "$f" "/usr/lib/lua/luci/controller/$fname"
          log "INFO: [classic] controller: $fname ($plugin_name)"
        fi
      done
    fi

    # ── Classic Lua: luasrc/view/<subdir> ─────────────────────
    if [ -d "$plugin_dir/luasrc/view" ]; then
      for vdir in "$plugin_dir/luasrc/view"/*/; do
        [ -d "$vdir" ] || continue
        vname=$(basename "$vdir")
        if [ ! -e "/usr/lib/lua/luci/view/$vname" ]; then
          ln -sf "$vdir" "/usr/lib/lua/luci/view/$vname"
          log "INFO: [classic] view dir: $vname ($plugin_name)"
        fi
      done
      for f in "$plugin_dir/luasrc/view"/*.htm; do
        [ -f "$f" ] || continue
        fname=$(basename "$f")
        [ ! -e "/usr/lib/lua/luci/view/$fname" ] && ln -sf "$f" "/usr/lib/lua/luci/view/$fname"
      done
    fi

    # ── New JS LuCI: htdocs/luci-static/resources/view/<name>/ ─
    if [ -d "$plugin_dir/htdocs/luci-static/resources/view" ]; then
      for vdir in "$plugin_dir/htdocs/luci-static/resources/view"/*/; do
        [ -d "$vdir" ] || continue
        vname=$(basename "$vdir")
        if [ ! -e "/www/luci-static/resources/view/$vname" ]; then
          ln -sf "$vdir" "/www/luci-static/resources/view/$vname"
          log "INFO: [js] view: $vname ($plugin_name)"
        fi
      done
    fi

    # ── Merge root/ into rootfs (file by file, no overwrite) ──
    if [ -d "$plugin_dir/root" ]; then
      find "$plugin_dir/root" -type f | while read src; do
        rel="${src#$plugin_dir/root/}"
        dest="/$rel"
        mkdir -p "$(dirname "$dest")"
        [ ! -e "$dest" ] && cp "$src" "$dest"
      done
      log "INFO: [root] merged: $plugin_name"
    fi
  done
  log "INFO: Plugin auto-load complete"
}

load_plugins

/etc/init.d/uhttpd enable 2>/dev/null
/etc/init.d/uhttpd start 2>/dev/null
log "INFO: uhttpd started"

/etc/init.d/dropbear enable 2>/dev/null
/etc/init.d/dropbear start 2>/dev/null
log "INFO: dropbear started"

chown -R 1000:1000 /luci-plugins 2>/dev/null
chown -R 1000:1000 /packages 2>/dev/null

log "INFO: === Container Ready ==="
log "INFO: LuCI: http://localhost:8080"
log "INFO: SSH:  ssh root@localhost -p 2222 (password: password)"

exec /sbin/init
