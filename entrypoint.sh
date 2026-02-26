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

  # ── Clean up dangling symlinks from previous deployments ──────
  for link_dir in /usr/lib/lua/luci/controller /usr/lib/lua/luci/view /www/luci-static/resources/view; do
    [ -d "$link_dir" ] || continue
    for link in "$link_dir"/*; do
      [ -L "$link" ] && [ ! -e "$link" ] && rm -f "$link" && log "INFO: Removed dangling symlink: $link"
    done
  done

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

# ─────────────────────────────────────────────────────────────
# Auto-load backend dependency packages from /luci-plugins/<name>/
#
# Automatically detects any non-luci-app-* subdirectory that has a Makefile.
# For each detected backend package:
#   1. Installs init script: files/<name>.init → /etc/init.d/<name>
#   2. Installs default config: files/<name>.config → /etc/config/<name> (if missing)
#   3. Installs any other files into /usr/share/<name>/
#   4. Downloads pre-compiled binary from GitHub Releases (parsed from Makefile)
#      - Supports ZIP format (e.g. phantun: phantun_x86_64.zip)
#      - Supports single binary (e.g. udp2raw: udp2raw_x86_64)
#      - Gracefully skips if release not available (no crash)
#      - Skips download if binary already installed (overlay persistence)
# ─────────────────────────────────────────────────────────────
load_deps() {
  # Detect container architecture for binary filename mapping
  local arch_tag
  case "$(uname -m)" in
    x86_64)  arch_tag="x86_64" ;;
    aarch64) arch_tag="aarch64" ;;
    armv7*)  arch_tag="armv7" ;;
    *)       arch_tag="$(uname -m)" ;;
  esac
  log "INFO: [dep] Container arch: $arch_tag"

  for dep_dir in /luci-plugins/*/; do
    [ -d "$dep_dir" ] || continue
    dep_name=$(basename "$dep_dir")

    # Skip front-end plugins (handled by load_plugins)
    case "$dep_name" in luci-app-*) continue ;; esac

    # Must have a Makefile to be treated as a backend package
    [ -f "$dep_dir/Makefile" ] || continue

    log "INFO: [dep] Processing backend package: $dep_name"

    # ── 1. Install init script ─────────────────────────────
    if [ -f "$dep_dir/files/$dep_name.init" ]; then
      if [ ! -f "/etc/init.d/$dep_name" ]; then
        cp "$dep_dir/files/$dep_name.init" "/etc/init.d/$dep_name"
        chmod +x "/etc/init.d/$dep_name"
        log "INFO: [dep] Installed init: /etc/init.d/$dep_name"
      else
        log "INFO: [dep] Init already exists: /etc/init.d/$dep_name"
      fi
    fi

    # ── 2. Install default config (only if missing or empty) ─
    if [ -f "$dep_dir/files/$dep_name.config" ]; then
      if [ ! -s "/etc/config/$dep_name" ]; then
        cp "$dep_dir/files/$dep_name.config" "/etc/config/$dep_name"
        log "INFO: [dep] Installed config: /etc/config/$dep_name"
      else
        log "INFO: [dep] Config already exists: /etc/config/$dep_name"
      fi
    fi

    # ── 3. Install supplementary files (e.g. .upgrade) ───────
    if [ -d "$dep_dir/files" ]; then
      find "$dep_dir/files" -type f ! -name "*.init" ! -name "*.config" | while read src; do
        fname=$(basename "$src")
        dest_dir="/usr/share/$dep_name"
        mkdir -p "$dest_dir"
        if [ ! -e "$dest_dir/$fname" ]; then
          cp "$src" "$dest_dir/$fname"
          log "INFO: [dep] Installed extra file: $dest_dir/$fname"
        fi
      done
    fi

    # ── 4. Download pre-compiled binary from GitHub Releases ──
    local makefile="$dep_dir/Makefile"

    # Parse repo info from Makefile (REPO_USER:= and REPO_NAME:= lines)
    repo_user=$(grep '^REPO_USER:=' "$makefile" 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' \t\r')
    repo_name=$(grep '^REPO_NAME:=' "$makefile" 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' \t\r')

    if [ -z "$repo_user" ] || [ -z "$repo_name" ]; then
      log "WARN: [dep] No REPO_USER/REPO_NAME in Makefile for $dep_name, skipping binary download"
      continue
    fi

    # Parse static PKG_VERSION (PKG_VERSION:=X.X.X, not shell command lines)
    pkg_version=$(grep '^PKG_VERSION:=[0-9]' "$makefile" 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' \t\r')

    # If no static version, try GitHub API
    if [ -z "$pkg_version" ]; then
      pkg_version=$(curl -sf --connect-timeout 8 \
        "https://api.github.com/repos/$repo_user/$repo_name/releases/latest" 2>/dev/null \
        | grep '"tag_name"' | cut -d'"' -f4 | sed 's/^v//')
    fi

    if [ -z "$pkg_version" ]; then
      log "WARN: [dep] Cannot determine version for $dep_name (no static PKG_VERSION and no GitHub release), skipping binary download"
      continue
    fi

    base_url="https://github.com/$repo_user/$repo_name/releases/download/v$pkg_version"
    log "INFO: [dep] Release URL base: $base_url"

    # Detect format: ZIP (phantun uses phantun_x86_64.zip) vs single binary
    if grep -q '\.zip' "$makefile" 2>/dev/null; then
      # ── ZIP format ─────────────────────────────────────────
      zip_file="${dep_name}_${arch_tag}.zip"
      download_url="$base_url/$zip_file"

      # Check if any binary already installed (overlay persistence)
      already_installed=0
      for candidate in "/usr/bin/${dep_name}" "/usr/bin/${dep_name}_client" "/usr/bin/${dep_name}_server"; do
        [ -x "$candidate" ] && already_installed=1 && break
      done
      if [ "$already_installed" = "1" ]; then
        log "INFO: [dep] Binary already installed for $dep_name, skipping download"
        continue
      fi

      log "INFO: [dep] Downloading ZIP: $download_url"
      tmp_zip="/tmp/${dep_name}_${arch_tag}.zip"
      if curl -sfL --connect-timeout 30 --retry 2 -o "$tmp_zip" "$download_url" 2>/dev/null \
         && [ -s "$tmp_zip" ]; then
        extract_dir="/tmp/${dep_name}_extract"
        mkdir -p "$extract_dir"
        unzip -o "$tmp_zip" -d "$extract_dir" 2>/dev/null
        for bin in "$extract_dir"/*; do
          [ -f "$bin" ] || continue
          bname=$(basename "$bin")
          cp "$bin" "/usr/bin/$bname" && chmod +x "/usr/bin/$bname"
          log "INFO: [dep] Installed binary: /usr/bin/$bname"
        done
        rm -f "$tmp_zip"
        rm -rf "$extract_dir"
      else
        rm -f "$tmp_zip"
        log "WARN: [dep] ZIP download failed for $dep_name v$pkg_version (release may not be published yet) - LuCI UI still works"
      fi

    else
      # ── Single binary format ────────────────────────────────
      dest_bin="/usr/bin/$dep_name"

      if [ -x "$dest_bin" ]; then
        log "INFO: [dep] Binary already installed: $dest_bin, skipping download"
        continue
      fi

      bin_file="${dep_name}_${arch_tag}"
      download_url="$base_url/$bin_file"

      log "INFO: [dep] Downloading binary: $download_url"
      tmp_bin="/tmp/${dep_name}_dl"
      if curl -sfL --connect-timeout 30 --retry 2 -o "$tmp_bin" "$download_url" 2>/dev/null \
         && [ -s "$tmp_bin" ]; then
        cp "$tmp_bin" "$dest_bin" && chmod +x "$dest_bin"
        rm -f "$tmp_bin"
        log "INFO: [dep] Installed binary: $dest_bin"
      else
        rm -f "$tmp_bin"
        log "WARN: [dep] Binary download failed for $dep_name v$pkg_version (release may not be published yet) - LuCI UI still works"
      fi
    fi
  done

  log "INFO: Backend dependency auto-load complete"
}

load_plugins
load_deps

# ─────────────────────────────────────────────────────────────
# Post-load: run uci-defaults, init UCI configs, clear LuCI cache
# ─────────────────────────────────────────────────────────────

# 1. Run uci-defaults scripts from all plugins
#    Scan both standard path (/etc/uci-defaults/) and non-standard paths
#    that plugins may have placed under root/usr/share/etc/uci-defaults/
for defaults_dir in /etc/uci-defaults /usr/share/etc/uci-defaults; do
  [ -d "$defaults_dir" ] || continue
  for script in "$defaults_dir"/*; do
    [ -f "$script" ] || continue
    [ -x "$script" ] || chmod +x "$script"
    sh "$script" 2>/dev/null && rm -f "$script" && log "INFO: uci-default executed: $(basename $script)"
  done
done
log "INFO: uci-defaults executed"

# 2. Auto-create missing UCI config files required by menu.d depends.uci
#    Creates a valid UCI section (not just empty touch) so LuCI menu.d depends check passes
for menu_json in /usr/share/luci/menu.d/luci-app-*.json; do
  [ -f "$menu_json" ] || continue
  # Extract UCI config names from "uci": { "<name>": true }
  uci_names=$(grep -o '"uci"[[:space:]]*:[[:space:]]*{[^}]*}' "$menu_json" 2>/dev/null | grep -o '"[a-z0-9_-]*"[[:space:]]*:[[:space:]]*true' | sed 's/[" ]//g' | cut -d: -f1)
  for cfg in $uci_names; do
    [ -z "$cfg" ] && continue
    # Only create if file missing or empty (uci-defaults may have already created it)
    if [ ! -s "/etc/config/$cfg" ]; then
      # Write a minimal valid UCI section so LuCI depends.uci check passes
      printf "config globals 'globals'\n\toption enabled '0'\n" > "/etc/config/$cfg"
      log "INFO: Created UCI config with valid section: /etc/config/$cfg"
    fi
  done
done

# 3. Clear LuCI module/index cache so new menus are picked up
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null
log "INFO: LuCI cache cleared"

# 4. Reload rpcd so ACL entries take effect
/etc/init.d/rpcd restart 2>/dev/null
log "INFO: rpcd reloaded"

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
