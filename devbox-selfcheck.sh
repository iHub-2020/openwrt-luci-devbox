#!/bin/sh
# ==============================================================
#  标题: devbox-selfcheck.sh
#  作者: reyan
#  日期: 2026-03-08
#  版本: 1.1.0
#  描述: DevBox 启动后自检脚本，用于验证 LuCI、WireGuard 页面、phantun 页面及 firewall 运行态。
#  最近三次更新:
#    - 2026-03-08: 增加 firewall 运行态检查，防止 LuCI 页面存在隐性告警。
#    - 2026-03-08: 保留 phantun 配置页与状态页的 RPCError / Promise 异常检查。
#    - 2026-03-08: 继续用于 single / dual 模式统一健康探测。
# ==============================================================
set -eu

MODE="${1:---health}"
BASE_URL="http://127.0.0.1/cgi-bin/luci"
TMPDIR="${TMPDIR:-/tmp}/devbox-selfcheck"
COOKIE="$TMPDIR/luci.cookie"

mkdir -p "$TMPDIR"
rm -f "$TMPDIR"/*.hdr "$TMPDIR"/*.body "$COOKIE" 2>/dev/null || true

log() {
    printf '%s\n' "$*"
}

fail() {
    log "[selfcheck] ERROR: $*" >&2
    exit 1
}

is_installed() {
    opkg list-installed | grep -qE "^$1 -"
}

require_pkg() {
    local pkg
    for pkg in "$@"; do
        is_installed "$pkg" || fail "required package missing: $pkg"
    done
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "required command missing: $1"
}

call_ubus() {
    local object method key out
    object="$1"
    method="$2"
    key="$(printf '%s' "$object" | tr '.' '_')"
    out="$TMPDIR/ubus-$key-$method.json"
    ubus call "$object" "$method" >"$out" 2>"$out.err" || {
        cat "$out.err" >&2 || true
        fail "ubus call failed: $object $method"
    }
    [ -s "$out" ] || fail "empty ubus response: $object $method"
}

login_luci() {
    curl --max-time 10 -sS -c "$COOKIE" -b "$COOKIE" \
        -D "$TMPDIR/login.hdr" -o "$TMPDIR/login.body" \
        -d 'luci_username=root&luci_password=password' \
        "$BASE_URL/" >/dev/null || fail "failed to post LuCI login"

    grep -Eq 'HTTP/[0-9.]+ (200|302)' "$TMPDIR/login.hdr" || fail "unexpected LuCI login status"
}

fetch_page() {
    local key="$1" path="$2"
    curl --max-time 10 -sS -b "$COOKIE" \
        -D "$TMPDIR/$key.hdr" -o "$TMPDIR/$key.body" \
        "$BASE_URL/$path" >/dev/null || fail "failed to fetch LuCI page: $path"

    grep -Eq 'HTTP/[0-9.]+ 200' "$TMPDIR/$key.hdr" || fail "unexpected HTTP status for $path"
}

check_branding() {
    grep -q '<title>OpenWrt' "$TMPDIR/overview.body" || fail 'LuCI title does not contain OpenWrt'
    grep -q 'class="brand" href="/">OpenWrt<' "$TMPDIR/overview.body" || fail 'LuCI brand is not OpenWrt'
    if grep -q '? - LuCI' "$TMPDIR/overview.body"; then
        fail 'LuCI title still shows ?'
    fi
}

check_no_rpcerror() {
    if grep -q 'RPCError' "$TMPDIR/overview.body"; then
        fail 'System overview still shows RPCError'
    fi
    if grep -q 'Object not found' "$TMPDIR/overview.body"; then
        fail 'System overview still shows Object not found'
    fi
}

check_firewall_state() {
    /etc/init.d/firewall status >"$TMPDIR/firewall.status" 2>&1 || true
    grep -q '^active' "$TMPDIR/firewall.status" || fail 'firewall service is not active'
}

check_scope() {
    for path in \
        /usr/share/luci/menu.d/luci-app-poweroffdevice.json \
        /usr/share/rpcd/acl.d/luci-app-poweroffdevice.json \
        /usr/share/luci/menu.d/luci-app-udp2raw.json \
        /usr/share/rpcd/acl.d/luci-app-udp2raw.json \
        /www/luci-static/resources/view/udp2raw; do
        [ ! -e "$path" ] || fail "out-of-scope runtime artifact still exposed: $path"
    done
}

check_phantun_runtime() {
    [ -f /etc/config/phantun ] || fail 'phantun config file missing: /etc/config/phantun'

    if grep -q 'RPCError' "$TMPDIR/phantun-config.body"; then
        fail 'phantun config page still shows RPCError'
    fi
    if grep -q 'RPCError' "$TMPDIR/phantun-status.body"; then
        fail 'phantun status page still shows RPCError'
    fi
    if grep -q 'Object not found' "$TMPDIR/phantun-config.body"; then
        fail 'phantun config page still shows Object not found'
    fi
    if grep -q 'Object not found' "$TMPDIR/phantun-status.body"; then
        fail 'phantun status page still shows Object not found'
    fi
}

main() {
    require_cmd wg
    require_cmd curl
    require_pkg wireguard-tools luci-proto-wireguard qrencode

    call_ubus system info
    call_ubus system board

    login_luci
    fetch_page overview admin/status/overview
    fetch_page wg0 admin/network/network/wg0
    fetch_page phantun-config admin/services/phantun/config
    fetch_page phantun-status admin/services/phantun/status

    check_no_rpcerror
    check_branding
    check_firewall_state
    check_scope
    check_phantun_runtime

    if grep -q '\[object Promise\]' "$TMPDIR/phantun-config.body"; then
        fail 'phantun config still contains [object Promise]'
    fi
    if grep -q '\[object Promise\]' "$TMPDIR/phantun-status.body"; then
        fail 'phantun status still contains [object Promise]'
    fi

    case "$MODE" in
        --startup|--health)
            log "[selfcheck] OK"
            ;;
        --evidence)
            log "[selfcheck] command -v wg => $(command -v wg)"
            log "[selfcheck] installed packages:"
            opkg list-installed | grep -Ei 'wireguard|qrencode' | sort
            log "[selfcheck] ubus call system info =>"
            cat "$TMPDIR/ubus-system-info.json"
            log "[selfcheck] ubus call system board =>"
            cat "$TMPDIR/ubus-system-board.json"
            log "[selfcheck] title => $(grep -o '<title>[^<]*</title>' "$TMPDIR/overview.body" | head -1)"
            log "[selfcheck] brand => $(grep -o 'class="brand" href="/">[^<]*<' "$TMPDIR/overview.body" | head -1)"
            ;;
        *)
            fail "unknown mode: $MODE"
            ;;
    esac
}

main
