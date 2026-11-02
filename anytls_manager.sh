#!/bin/bash
# =====================================================================
# anytls_manager.sh - AnyTLS-Go 服务端一键安装与管理脚本（UUID 密码 + 二维码）
# 上游项目: https://github.com/anytls/anytls-go
# 用法: sudo bash anytls_manager.sh install
# 安装后可使用: anytls {install|update|start|stop|restart|status|log|qr|passwd|uninstall|help}
# 支持架构: amd64 / arm64；支持 systemd 与 OpenRC
# =====================================================================

set -u

SCRIPT_VERSION="2026.11.02-alpine-qr"     # 脚本版本标记，安装时会打印，用于确认是否为最新脚本
VERSION="${ANYTLS_VERSION:-0.0.8}"       # 目标程序版本，可用环境变量 ANYTLS_VERSION 覆盖
REPO="anytls/anytls-go"
BIN_PATH="/usr/local/bin/anytls-server"
CONF_DIR="/etc/anytls"
CONF_FILE="${CONF_DIR}/config.env"
QR_PNG="${CONF_DIR}/anytls-qr.png"
ALPINE_QR_HELPER="/usr/local/libexec/anytls-qrgen.py"
SERVICE="anytls"
SCRIPT_DST="/usr/local/sbin/anytls"
SCRIPT_BIN="/usr/local/bin/anytls"
SYSTEMD_UNIT="/etc/systemd/system/${SERVICE}.service"
OPENRC_INIT="/etc/init.d/${SERVICE}"
OPENRC_RUNNER="/usr/local/libexec/${SERVICE}-runner"
OPENRC_LOG="/var/log/${SERVICE}.log"
OPENRC_ERR_LOG="/var/log/${SERVICE}.err"
OPENRC_PID="/run/${SERVICE}.pid"
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"
FIREWALL_MARKER=""

OS_ID="unknown"
OS_ID_LIKE=""
OS_PRETTY_NAME="未知 Linux"
PKG_MGR="unknown"
INIT_SYSTEM="unknown"
QR_ENCODE_ATTEMPTED=0

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

need_root()      { [[ $EUID -eq 0 ]] || err "请使用 root 或 sudo 运行"; }
need_installed() { [[ -f "$BIN_PATH" && -f "$CONF_FILE" ]] || err "未安装，请先执行 install"; }

# ---------- 发行版、包管理器与 init 系统 ----------
detect_platform() {
    if [[ -r "$OS_RELEASE_FILE" ]]; then
        local ID ID_LIKE PRETTY_NAME VERSION
        # shellcheck disable=SC1091
        . "$OS_RELEASE_FILE"
        OS_ID=${ID:-unknown}
        OS_ID=${OS_ID,,}
        OS_ID_LIKE=${ID_LIKE:-}
        OS_ID_LIKE=${OS_ID_LIKE,,}
        OS_PRETTY_NAME=${PRETTY_NAME:-${ID:-unknown}}
    fi

    case " $OS_ID $OS_ID_LIKE " in
        *" debian "*|*" ubuntu "*) PKG_MGR=apt ;;
        *" centos "*|*" rhel "*|*" rocky "*|*" almalinux "*|*" fedora "*)
            if command -v dnf >/dev/null 2>&1; then PKG_MGR=dnf
            elif command -v yum >/dev/null 2>&1; then PKG_MGR=yum
            fi ;;
        *" arch "*|*" manjaro "*) PKG_MGR=pacman ;;
        *" alpine "*) PKG_MGR=apk ;;
    esac

    case "$PKG_MGR" in
        apt) command -v apt-get >/dev/null 2>&1 || PKG_MGR=unknown ;;
        dnf) command -v dnf >/dev/null 2>&1 || PKG_MGR=unknown ;;
        yum) command -v yum >/dev/null 2>&1 || PKG_MGR=unknown ;;
        pacman) command -v pacman >/dev/null 2>&1 || PKG_MGR=unknown ;;
        apk) command -v apk >/dev/null 2>&1 || PKG_MGR=unknown ;;
    esac

    if [[ "$OS_ID" == "alpine" ]]; then
        INIT_SYSTEM=openrc
    elif command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        INIT_SYSTEM=systemd
    elif command -v rc-service >/dev/null 2>&1; then
        INIT_SYSTEM=openrc
    else
        INIT_SYSTEM=unknown
    fi
}

require_platform() {
    [[ "$INIT_SYSTEM" != unknown ]] || err "无法识别受支持的 init 系统（发行版: ${OS_PRETTY_NAME}）；需要运行中的 systemd 或 OpenRC"
}

pkg_install() {
    case "$PKG_MGR" in
        apt)    apt-get update -qq && apt-get install -y "$@" ;;
        dnf)    dnf install -y "$@" ;;
        yum)    yum install -y "$@" ;;
        pacman) pacman -Sy --noconfirm --needed "$@" ;;
        apk)    apk add --no-cache "$@" ;;
        *) err "无法为 ${OS_PRETTY_NAME} 确定可用包管理器" ;;
    esac
}

platform_command() {
    local rc
    if "$@"; then
        return 0
    else
        rc=$?
        warn "命令失败（发行版: ${OS_PRETTY_NAME}; init: ${INIT_SYSTEM}; 退出码: ${rc}）: $*"
        return "$rc"
    fi
}

# ---------- 服务管理抽象 ----------
svc_start() {
    if [[ "$INIT_SYSTEM" == openrc ]]; then platform_command rc-service "$1" start
    else platform_command systemctl start "$1"; fi
}
svc_stop() {
    if [[ "$INIT_SYSTEM" == openrc ]]; then platform_command rc-service "$1" stop
    else platform_command systemctl stop "$1"; fi
}
svc_restart() {
    if [[ "$INIT_SYSTEM" == openrc ]]; then platform_command rc-service "$1" restart
    else platform_command systemctl restart "$1"; fi
}
svc_status() {
    if [[ "$INIT_SYSTEM" == openrc ]]; then platform_command rc-service "$1" status
    else platform_command systemctl status "$1" -l --no-pager; fi
}
svc_enable() {
    if [[ "$INIT_SYSTEM" == openrc ]]; then platform_command rc-update add "$1" default
    else platform_command systemctl enable "$1"; fi
}
svc_disable() {
    if [[ "$INIT_SYSTEM" == openrc ]]; then platform_command rc-update del "$1" default
    else platform_command systemctl disable "$1"; fi
}
svc_is_active() {
    if [[ "$INIT_SYSTEM" == openrc ]]; then
        rc-service "$1" status >/dev/null 2>&1
    else
        systemctl is-active --quiet "$1"
    fi
}
svc_reload_daemon() {
    if [[ "$INIT_SYSTEM" == systemd ]]; then
        platform_command systemctl daemon-reload
    else
        return 0
    fi
}
svc_log() {
    local service=$1; shift
    if [[ "$INIT_SYSTEM" == openrc ]]; then
        local logs=()
        [[ -f "$OPENRC_LOG" ]] && logs+=("$OPENRC_LOG")
        [[ -f "$OPENRC_ERR_LOG" ]] && logs+=("$OPENRC_ERR_LOG")
        if [[ ${#logs[@]} -eq 0 ]]; then
            warn "OpenRC 日志文件尚未生成: ${OPENRC_LOG} / ${OPENRC_ERR_LOG}"
            return 0
        fi
        if [[ $# -eq 0 ]]; then platform_command tail -n 200 -f "${logs[@]}"
        else platform_command tail "$@" "${logs[@]}"; fi
    elif [[ $# -eq 0 ]]; then
        platform_command journalctl -u "$service" -n 100 --no-pager
    else
        platform_command journalctl -u "$service" --no-pager "$@"
    fi
}

iptables_firewall_active() {
    command -v iptables >/dev/null 2>&1 || return 1
    iptables -S INPUT 2>/dev/null | grep -qE '^-P INPUT (DROP|REJECT)$|^-A INPUT '
}

service_enabled_and_started() {
    svc_enable "$SERVICE" || return $?
    if svc_is_active "$SERVICE"; then
        svc_restart "$SERVICE"
    else
        svc_start "$SERVICE"
    fi
}

# ---------- 工具函数 ----------
get_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) err "不支持的架构: $(uname -m)（仅支持 amd64 / arm64）" ;;
    esac
}

# 生成 UUID 格式密码，例如 03ad5382-2cdd-4a2c-836b-535fcb64b00f
gen_pass() {
    local h
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    elif command -v uuidgen &>/dev/null; then
        uuidgen
    else
        h=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
        echo "${h:0:8}-${h:8:4}-${h:12:4}-${h:16:4}-${h:20:12}"
    fi | tr 'A-F' 'a-f'
}

valid_port()  { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
valid_pass()  { [[ "$1" =~ ^[A-Za-z0-9-]{6,64}$ ]]; }
valid_name()  { [[ "$1" =~ ^[A-Za-z0-9_-]{1,32}$ ]]; }
port_in_use() { ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1$"; }
get_ip()      { curl -s4 --max-time 5 ifconfig.me || curl -s4 --max-time 5 ip.sb || echo "服务器IP"; }
load_conf()   { [[ -f "$CONF_FILE" ]] && source "$CONF_FILE"; }

# ---------- 依赖 ----------
install_qrencode() {
    command -v qrencode &>/dev/null && return 0
    QR_ENCODE_ATTEMPTED=1
    info "安装 qrencode（二维码工具）..."
    if ! pkg_install qrencode; then
        [[ "$PKG_MGR" == yum ]] && warn "部分 CentOS / RHEL 系统需先启用 EPEL 才能安装 qrencode"
        return 1
    fi
    command -v qrencode &>/dev/null
}

write_qr_helper() {
    install -d -m 755 "$(dirname "$ALPINE_QR_HELPER")"
    cat > "$ALPINE_QR_HELPER" <<'PY'
#!/usr/bin/env python3
import struct
import sys
import zlib

DATA_WORDS = [19, 34, 55, 80, 108, 136, 156, 194, 232]
ECC_WORDS = [7, 10, 15, 20, 26, 18, 20, 24, 30]
ALIGNMENT = [[], [6, 18], [6, 22], [6, 26], [6, 30], [6, 34],
             [6, 22, 38], [6, 24, 42], [6, 26, 46]]


def multiply(x, y):
    result = 0
    while y:
        if y & 1:
            result ^= x
        x <<= 1
        if x & 0x100:
            x ^= 0x11D
        y >>= 1
    return result


def rs_divisor(degree):
    poly = [1]
    root = 1
    for _ in range(degree):
        nxt = [0] * (len(poly) + 1)
        for i, value in enumerate(poly):
            nxt[i] ^= value
            nxt[i + 1] ^= multiply(value, root)
        poly = nxt
        root = multiply(root, 2)
    return poly[1:]


def rs_remainder(data, divisor):
    result = [0] * len(divisor)
    for value in data:
        factor = value ^ result[0]
        result = result[1:] + [0]
        for i, coefficient in enumerate(divisor):
            result[i] ^= multiply(coefficient, factor)
    return result


def append_bits(out, value, count):
    for shift in range(count - 1, -1, -1):
        out.append((value >> shift) & 1)


def make_codewords(payload):
    raw = payload.encode('utf-8')
    for version, capacity in enumerate(DATA_WORDS, 1):
        if len(raw) <= (capacity * 8 - 12) // 8:
            break
    else:
        raise ValueError('连接信息过长，内置二维码生成器最多支持 9-L 版本。')

    bits = []
    append_bits(bits, 0x4, 4)  # byte mode
    append_bits(bits, len(raw), 8)
    for value in raw:
        append_bits(bits, value, 8)
    bits.extend([0] * min(4, capacity * 8 - len(bits)))
    while len(bits) % 8:
        bits.append(0)
    data = [sum(bits[i + j] << (7 - j) for j in range(8))
            for i in range(0, len(bits), 8)]
    pad = (0xEC, 0x11)
    while len(data) < capacity:
        data.append(pad[(len(data) - (len(bits) // 8)) & 1])

    block_count = 1 if version <= 5 else 2
    base, extra = divmod(capacity, block_count)
    blocks = []
    offset = 0
    divisor = rs_divisor(ECC_WORDS[version - 1])
    for block_index in range(block_count):
        length = base + (1 if block_index >= block_count - extra else 0)
        block = data[offset:offset + length]
        offset += length
        blocks.append((block, rs_remainder(block, divisor)))
    result = []
    for i in range(max(len(block[0]) for block in blocks)):
        for data_block, _ in blocks:
            if i < len(data_block):
                result.append(data_block[i])
    for i in range(ECC_WORDS[version - 1]):
        for _, ecc_block in blocks:
            result.append(ecc_block[i])
    return version, result


def bch(value, polynomial, shift):
    remainder = value << shift
    degree = polynomial.bit_length() - 1
    while remainder.bit_length() - 1 >= degree:
        remainder ^= polynomial << (remainder.bit_length() - 1 - degree)
    return (value << shift) | remainder


def build_matrix(version, codewords, mask):
    size = version * 4 + 17
    grid = [[None] * size for _ in range(size)]

    def set_module(x, y, dark):
        if 0 <= x < size and 0 <= y < size:
            grid[y][x] = bool(dark)

    def finder(cx, cy):
        for dy in range(-4, 5):
            for dx in range(-4, 5):
                distance = max(abs(dx), abs(dy))
                set_module(cx + dx, cy + dy, distance not in (2, 4))

    finder(3, 3)
    finder(size - 4, 3)
    finder(3, size - 4)

    for cy in ALIGNMENT[version - 1]:
        for cx in ALIGNMENT[version - 1]:
            if cx == 6 or cy == 6:
                continue
            for dy in range(-2, 3):
                for dx in range(-2, 3):
                    set_module(cx + dx, cy + dy,
                               max(abs(dx), abs(dy)) != 1)

    for i in range(8, size - 8):
        if grid[6][i] is None:
            set_module(i, 6, i % 2 == 0)
        if grid[i][6] is None:
            set_module(6, i, i % 2 == 0)

    if version >= 7:
        version_bits = bch(version, 0x1F25, 12)
        for i in range(18):
            bit = (version_bits >> i) & 1
            a, b = size - 11 + i % 3, i // 3
            set_module(a, b, bit)
            set_module(b, a, bit)

    def format_info():
        value = (1 << 3) | mask  # error correction level L
        return bch(value, 0x537, 10) ^ 0x5412

    fmt = format_info()
    for i in range(15):
        bit = (fmt >> i) & 1
        if i < 6:
            set_module(8, i, bit)
        elif i < 8:
            set_module(8, i + 1, bit)
        elif i == 8:
            set_module(7, 8, bit)
        else:
            set_module(14 - i, 8, bit)
        if i < 8:
            set_module(size - 1 - i, 8, bit)
        else:
            set_module(8, size - 15 + i, bit)
    set_module(8, size - 8, True)

    data = []
    for word in codewords:
        append_bits(data, word, 8)
    bit_index = 0
    right = size - 1
    upward = True
    while right >= 1:
        if right == 6:
            right = 5
        for vert in range(size):
            y = size - 1 - vert if upward else vert
            for x in (right, right - 1):
                if grid[y][x] is not None:
                    continue
                dark = data[bit_index] if bit_index < len(data) else 0
                bit_index += 1
                invert = (
                    ((x + y) % 2 == 0), y % 2 == 0, x % 3 == 0,
                    (x + y) % 3 == 0,
                    (y // 2 + x // 3) % 2 == 0,
                    (x * y) % 2 + (x * y) % 3 == 0,
                    ((x * y) % 2 + (x * y) % 3) % 2 == 0,
                    ((x + y) % 2 + (x * y) % 3) % 2 == 0,
                )[mask]
                grid[y][x] = bool(dark ^ invert)
        upward = not upward
        right -= 2
    return grid


def penalty(grid):
    size = len(grid)
    score = 0
    for lines in (grid, list(zip(*grid))):
        for line in lines:
            run_color, run_length = line[0], 1
            for cell in line[1:]:
                if cell == run_color:
                    run_length += 1
                    if run_length == 5:
                        score += 3
                    elif run_length > 5:
                        score += 1
                else:
                    run_color, run_length = cell, 1
            bits = ''.join('1' if cell else '0' for cell in line)
            score += 40 * (bits.count('10111010000') + bits.count('00001011101'))
    for y in range(size - 1):
        for x in range(size - 1):
            color = grid[y][x]
            if grid[y][x + 1] == color and grid[y + 1][x] == color and grid[y + 1][x + 1] == color:
                score += 3
    dark = sum(sum(row) for row in grid)
    score += (abs(dark * 20 - size * size * 10) // (size * size)) * 10
    return score


def png_bytes(grid, path, scale=6, border=4):
    size = len(grid)
    width = (size + border * 2) * scale
    raw = bytearray()
    for y in range(-border, size + border):
        row = bytearray([0])
        for x in range(-border, size + border):
            shade = 0 if 0 <= x < size and 0 <= y < size and grid[y][x] else 255
            row.extend((shade, shade, shade) * scale)
        for _ in range(scale):
            raw.extend(row)

    def chunk(kind, payload):
        body = kind + payload
        return struct.pack('>I', len(payload)) + body + struct.pack('>I', zlib.crc32(body) & 0xFFFFFFFF)

    with open(path, 'wb') as image:
        image.write(b'\x89PNG\r\n\x1a\n')
        image.write(chunk(b'IHDR', struct.pack('>IIBBBBB', width, width, 8, 2, 0, 0, 0)))
        image.write(chunk(b'IDAT', zlib.compress(bytes(raw), 9)))
        image.write(chunk(b'IEND', b''))


def main():
    if len(sys.argv) != 3:
        raise SystemExit('usage: qrgen.py TEXT OUTPUT.png')
    version, words = make_codewords(sys.argv[1])
    candidates = [build_matrix(version, words, mask) for mask in range(8)]
    grid = min(candidates, key=penalty)
    border = 4
    for y in range(-border, len(grid) + border):
        print(''.join('██' if 0 <= x < len(grid) and 0 <= y < len(grid) and grid[y][x] else '  '
                      for x in range(-border, len(grid) + border)))
    png_bytes(grid, sys.argv[2])


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError) as exc:
        print('qrgen: ' + str(exc), file=sys.stderr)
        raise SystemExit(1)
PY
    chmod 755 "$ALPINE_QR_HELPER"
}

install_deps() {
    local packages=(wget unzip curl tar)
    case "$PKG_MGR" in
        apt|pacman) packages+=(iproute2) ;;
        dnf|yum) packages+=(iproute) ;;
        apk) packages+=(iproute2 python3) ;;
    esac
    info "通过 ${PKG_MGR} 安装基础依赖（${packages[*]}）..."
    if [[ "$PKG_MGR" == apk ]]; then
        info "Alpine 使用 apk add --no-cache 安装 python3，由脚本内置生成器生成二维码。"
    fi
    pkg_install "${packages[@]}" || err "基础依赖安装失败（发行版: ${OS_PRETTY_NAME}; 包管理器: ${PKG_MGR}）"
    for c in curl unzip; do
        command -v "$c" &>/dev/null || err "缺少依赖: $c"
    done
    if [[ "$PKG_MGR" != apk ]]; then install_qrencode || true; fi
    if [[ "$PKG_MGR" == apk ]]; then write_qr_helper; fi
}

# ---------- 下载程序（通过 API 匹配资源文件，避免猜测文件名） ----------
download_server() {
    local arch url tmp found json
    arch=$(get_arch)
    info "目标版本: v${VERSION} (linux/${arch})"

    json=$(curl -fsSL --max-time 15 "https://api.github.com/repos/${REPO}/releases/tags/v${VERSION}") \
        || err "GitHub 上找不到版本 v${VERSION}，请确认版本号，或用 ANYTLS_VERSION=0.0.8 指定其他版本"
    url=$(grep -o "https://[^\"]*linux_${arch}[^\"]*\.zip" <<<"$json" | head -1)
    [[ -n "$url" ]] || err "版本 v${VERSION} 中没有 linux_${arch} 的压缩包"

    tmp=$(mktemp -d)
    info "下载: ${url}"
    curl -fL --retry 3 --max-time 300 -o "$tmp/pkg.zip" "$url" \
        || { rm -rf "$tmp"; err "下载失败: $url"; }
    unzip -qo "$tmp/pkg.zip" -d "$tmp/out" || { rm -rf "$tmp"; err "解压失败"; }

    found=$(find "$tmp/out" -type f -iname '*anytls*' ! -name '*.zip' ! -name '*.md' ! -name '*.txt' | grep -i 'server' | head -1)
    [[ -n "$found" ]] || found=$(find "$tmp/out" -type f -iname '*anytls*' ! -name '*.zip' ! -name '*.md' ! -name '*.txt' | head -1)
    [[ -n "$found" ]] || { rm -rf "$tmp"; err "压缩包中未找到 anytls 可执行文件"; }

    install -d -m 755 "$(dirname "$BIN_PATH")" || { rm -rf "$tmp"; err "无法创建程序目录: $(dirname "$BIN_PATH")"; }
    install -m 755 "$found" "$BIN_PATH"
    rm -rf "$tmp"
}

# 每次 install 都同步管理脚本本体，保证 anytls 命令与最新脚本一致
sync_self() {
    local self target
    self=$(readlink -f "$0")
    [[ -f "$self" ]] || return 0
    for target in "$SCRIPT_DST" "$SCRIPT_BIN"; do
        if [[ "$self" != "$target" ]]; then
            install -d -m 755 "$(dirname "$target")" || err "无法创建管理命令目录: $(dirname "$target")"
            install -m 755 "$self" "$target" || err "无法安装管理命令: ${target}"
        fi
    done
}

# ---------- 防火墙 ----------
open_firewall() {
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        FIREWALL_MARKER="${CONF_DIR}/firewall-${1}.rule"
        if ! ufw status | grep -qE "^[[:space:]]*${1}/tcp([[:space:]]|$)"; then
            if ufw allow "$1/tcp" >/dev/null; then printf 'ufw\n' > "$FIREWALL_MARKER"
            else warn "ufw 放行端口 $1 失败"; fi
        fi
    elif command -v firewall-cmd &>/dev/null && firewall-cmd --state >/dev/null 2>&1; then
        FIREWALL_MARKER="${CONF_DIR}/firewall-${1}.rule"
        if ! firewall-cmd --permanent --query-port="$1/tcp" >/dev/null 2>&1; then
            if firewall-cmd --permanent --add-port="$1/tcp" >/dev/null && firewall-cmd --reload >/dev/null; then
                printf 'firewalld\n' > "$FIREWALL_MARKER"
            else
                warn "firewalld 放行端口 $1 失败"
            fi
        fi
    elif iptables_firewall_active; then
        if ! iptables -C INPUT -p tcp --dport "$1" -j ACCEPT >/dev/null 2>&1; then
            if iptables -A INPUT -p tcp --dport "$1" -j ACCEPT; then
                FIREWALL_MARKER="${CONF_DIR}/firewall-${1}.rule"
                printf 'iptables\n' > "$FIREWALL_MARKER"
            else
                warn "iptables 放行端口 $1 失败"
            fi
        fi
        warn "iptables 规则可能不会跨重启保留，请配置系统防火墙持久化。"
    elif command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -q '^[[:space:]]*table '; then
        warn "检测到活动 nftables；脚本不会改写现有规则集，请手动放行 TCP 端口 $1。"
    else
        warn "未检测到活动防火墙，请确认端口 $1 已放行（云服务器需检查安全组）"
    fi
}

close_firewall() {
    local p=$1
    FIREWALL_MARKER="${CONF_DIR}/firewall-${p}.rule"
    if [[ -f "$FIREWALL_MARKER" ]]; then
        case "$(<"$FIREWALL_MARKER")" in
          ufw)
            ufw delete allow "$p/tcp" >/dev/null 2>&1 || warn "ufw 规则清理失败: $p/tcp"
            ;;
          firewalld)
            firewall-cmd --permanent --remove-port="$p/tcp" >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1 \
                || warn "firewalld 规则清理失败: $p/tcp"
            ;;
          iptables)
            iptables -D INPUT -p tcp --dport "$p" -j ACCEPT >/dev/null 2>&1 || true
            ;;
        esac
        rm -f "$FIREWALL_MARKER" "${CONF_DIR}/iptables-${p}.rule"
    fi
}

# ---------- 配置与服务 ----------
# 参数: 端口 密码 节点名称
save_conf() {
    mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR"
    umask 077
    printf 'PORT=%s\nPASSWORD=%s\nNODE_NAME=%s\nINSTALLED_VERSION=%s\n' \
        "$1" "$2" "$3" "$VERSION" > "$CONF_FILE"
    chmod 600 "$CONF_FILE"
}

write_unit() {
    load_conf
    chmod 755 "$BIN_PATH" || err "无法设置服务端程序可执行权限: ${BIN_PATH}"
    case "$INIT_SYSTEM" in
      systemd)
        cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=AnyTLS-Go server
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
EnvironmentFile=${CONF_FILE}
ExecStart=${BIN_PATH} -l 0.0.0.0:\$PORT -p \$PASSWORD
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        svc_reload_daemon || err "systemd 重新加载服务定义失败"
        ;;
      openrc)
        install -d -m 755 "$(dirname "$OPENRC_RUNNER")"
        cat > "$OPENRC_RUNNER" <<EOF
#!/bin/sh
set -a
. "${CONF_FILE}"
set +a
exec "${BIN_PATH}" -l "0.0.0.0:\${PORT}" -p "\${PASSWORD}"
EOF
        chmod 755 "$OPENRC_RUNNER" || err "无法设置 OpenRC 启动器可执行权限: ${OPENRC_RUNNER}"
        cat > "$OPENRC_INIT" <<EOF
#!/sbin/openrc-run
name="anytls"
description="AnyTLS-Go server"
command="${OPENRC_RUNNER}"
command_background=true
pidfile="${OPENRC_PID}"
output_log="${OPENRC_LOG}"
error_log="${OPENRC_ERR_LOG}"

depend() {
    need net
}
EOF
        chmod 755 "$OPENRC_INIT" || err "无法设置 OpenRC 服务脚本可执行权限: ${OPENRC_INIT}"
        ;;
      *) err "无法生成服务定义：未知 init 系统 ${INIT_SYSTEM}" ;;
    esac
}

restart_and_check() {
    service_enabled_and_started || err "启用或启动服务失败，请执行: anytls log"
    sleep 2
    svc_is_active "$SERVICE" || err "服务启动失败（发行版: ${OS_PRETTY_NAME}; init: ${INIT_SYSTEM}），请执行: anytls log"
}

ask_port() {
    local p
    while true; do
        read -rp "请输入监听端口 [默认 8443]: " p
        p=${p:-8443}
        valid_port "$p" || { warn "端口需为 1-65535 之间的数字"; continue; }
        port_in_use "$p" && { warn "端口 $p 已被占用，请更换"; continue; }
        echo "$p"; return
    done
}

ask_pass() {
    local pw
    while true; do
        read -rp "请输入连接密码 [直接回车自动生成 UUID 格式]: " pw
        [[ -z "$pw" ]] && pw=$(gen_pass)
        valid_pass "$pw" && { echo "$pw"; return; }
        warn "密码仅允许字母、数字和 -，长度 6-64"
    done
}

ask_name() {
    local n
    while true; do
        read -rp "请输入节点名称（客户端中显示）[默认 AnyTLS]: " n
        n=${n:-AnyTLS}
        valid_name "$n" && { echo "$n"; return; }
        warn "节点名称仅允许字母、数字、_ 和 -，1-32 位"
    done
}

# ---------- 连接信息与二维码 ----------
build_uri() {
    load_conf
    local ip; ip=$(get_ip)
    echo "anytls://${PASSWORD}@${ip}:${PORT}/?insecure=1#${NODE_NAME:-AnyTLS}"
}

print_info() {
    load_conf
    local ip; ip=$(get_ip)
    echo "--------------------------------------------"
    echo " 服务器 IP : ${ip}"
    echo " 端口      : ${PORT}"
    echo " 密码      : ${PASSWORD}"
    echo " 节点名称  : ${NODE_NAME:-AnyTLS}"
    echo " 程序版本  : v${INSTALLED_VERSION:-$VERSION}"
    echo "--------------------------------------------"
    echo " 注意：服务端使用自签名证书，客户端需开启“允许不安全连接”或“跳过证书验证”。"
}

show_qr() {
    local uri; uri=$(build_uri)
    echo
    echo "连接链接: ${uri}"
    echo

    if [[ "$OS_ID" == alpine ]]; then
        if ! command -v python3 >/dev/null 2>&1; then
            info "安装 Alpine 标准仓库中的 python3（内置二维码生成器需要）..."
            pkg_install python3 || {
                warn "python3 安装失败；连接链接仍可手动复制。"
                return 0
            }
        fi
        [[ -f "$ALPINE_QR_HELPER" ]] || write_qr_helper
        echo "使用脚本内置生成器在本机生成二维码："
        if python3 "$ALPINE_QR_HELPER" "$uri" "$QR_PNG"; then
            chmod 600 "$QR_PNG"
            info "二维码图片已保存: ${QR_PNG}"
        else
            warn "二维码生成失败；连接链接仍可手动复制。"
            return 0
        fi
        warn "若扫码无法导入，请确认客户端版本支持 AnyTLS，并开启“允许不安全连接”。"
        return 0
    fi

    if ! command -v qrencode &>/dev/null; then
        if [[ "$QR_ENCODE_ATTEMPTED" -eq 0 ]]; then
            warn "qrencode 未安装，尝试安装一次..."
            install_qrencode || {
                warn "二维码未生成，连接链接仍可手动复制；安装好 qrencode 后再次运行 anytls qr。"
                return 0
            }
        else
            warn "本次运行已尝试安装 qrencode；二维码未生成，连接链接仍可手动复制。修复软件仓库后再次运行 anytls qr。"
            return 0
        fi
    fi

    echo "请使用 NekoBox / Shadowrocket 扫描下方二维码："
    echo
    qrencode -t ANSIUTF8 -m 1 "$uri" || warn "终端二维码输出失败"
    echo

    if qrencode -o "$QR_PNG" -s 8 -m 2 "$uri" 2>/dev/null; then
        chmod 600 "$QR_PNG"
        info "二维码图片已保存: ${QR_PNG}（终端显示异常时，可用 scp 下载后扫码）"
    fi
    warn "若扫码无法导入，请确认客户端版本支持 AnyTLS，并开启“允许不安全连接”。"
}

# ---------- 子命令 ----------
cmd_install() {
    need_root; require_platform
    info "脚本版本: ${SCRIPT_VERSION}"
    install_deps
    download_server
    sync_self

    if [[ -f "$CONF_FILE" ]]; then
        info "检测到已安装，保留原端口、密码与节点名称，仅更新程序"
        load_conf
        save_conf "$PORT" "$PASSWORD" "${NODE_NAME:-AnyTLS}"
        write_unit
        restart_and_check
        info "更新完成，当前版本: v${VERSION}"
        print_info
        show_qr
        return
    fi

    local port pass name
    port=$(ask_port)
    pass=$(ask_pass)
    name=$(ask_name)
    save_conf "$port" "$pass" "$name"
    write_unit

    restart_and_check
    open_firewall "$port"
    info "安装完成！"
    print_info
    show_qr
    echo " 管理命令 : anytls {start|stop|restart|status|update|log|qr|passwd|uninstall}"
}

cmd_update() {
    need_root; require_platform; need_installed
    info "脚本版本: ${SCRIPT_VERSION}"
    load_conf
    local old=${INSTALLED_VERSION:-未知}
    install_deps
    download_server
    sync_self
    save_conf "$PORT" "$PASSWORD" "${NODE_NAME:-AnyTLS}"
    write_unit
    restart_and_check
    info "已从 v${old} 更新到 v${VERSION}"
}

cmd_ctl() {   # 参数: start | stop | restart
    need_root; require_platform; need_installed
    case "$1" in
        start) svc_start "$SERVICE" || err "启动服务失败，请执行: anytls log" ;;
        stop) svc_stop "$SERVICE" || err "停止服务失败，请执行: anytls log" ;;
        restart) svc_restart "$SERVICE" || err "重启服务失败，请执行: anytls log" ;;
        *) err "未知服务操作: $1" ;;
    esac
    info "服务已 $1"
}

cmd_status() {
    require_platform; need_installed
    load_conf
    local st="已停止"
    svc_is_active "$SERVICE" && st="运行中"
    echo "--------------------------------------------"
    echo " 服务状态 : $st"
    echo " 程序版本 : v${INSTALLED_VERSION:-未知}"
    echo " 监听端口 : ${PORT}"
    echo " 节点名称 : ${NODE_NAME:-AnyTLS}"
    echo "--------------------------------------------"
}

cmd_log() {
    need_root; require_platform
    svc_log "$SERVICE" "$@"
}

cmd_qr() {
    need_root; need_installed
    load_conf
    read -rsp "请输入连接密码以确认身份: " input; echo
    [[ "$input" == "$PASSWORD" ]] || err "密码错误"
    show_qr
}

# 重新生成密码（不传参则生成 UUID），并同步配置与服务
cmd_passwd() {
    need_root; require_platform; need_installed
    load_conf
    local pw=${1:-}
    [[ -z "$pw" ]] && pw=$(gen_pass)
    valid_pass "$pw" || err "密码仅允许字母、数字和 -，长度 6-64"
    save_conf "$PORT" "$pw" "${NODE_NAME:-AnyTLS}"
    write_unit
    restart_and_check
    info "密码已更新"
    print_info
    show_qr
}

cmd_uninstall() {
    need_root; require_platform
    read -rp "确认卸载 anytls-go（配置与二维码将被删除）? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消"; return; }
    load_conf 2>/dev/null
    svc_stop "$SERVICE" >/dev/null 2>&1 || true
    svc_disable "$SERVICE" >/dev/null 2>&1 || true
    [[ -n "${PORT:-}" ]] && close_firewall "$PORT"
    if [[ "$INIT_SYSTEM" == systemd ]]; then
        rm -f "$SYSTEMD_UNIT"
        svc_reload_daemon || warn "systemd 重新加载服务定义失败"
    else
        rm -f "$OPENRC_INIT" "$OPENRC_RUNNER" "$OPENRC_PID" "$OPENRC_LOG" "$OPENRC_ERR_LOG"
    fi
    rm -f "$ALPINE_QR_HELPER"
    rm -f "$BIN_PATH" "$SCRIPT_DST" "$SCRIPT_BIN"
    rm -rf "$CONF_DIR"
    info "anytls-go 已卸载"
}

usage() {
    cat <<EOF
anytls - AnyTLS-Go 服务端管理脚本（${SCRIPT_VERSION}）

用法:
  anytls install        安装（已安装则仅更新程序，保留配置）
  anytls update         更新程序（目标版本 v${VERSION}）
  anytls start          启动服务
  anytls stop           停止服务
  anytls restart        重启服务
  anytls status         查看状态
  anytls log [参数]     查看服务日志，可附加 journalctl/tail 参数，如 -n 200
  anytls qr             输入密码确认后，显示连接链接与二维码
  anytls passwd [密码]  重新设置密码，不填则生成 UUID 格式
  anytls uninstall      卸载
  anytls help           显示本帮助

首次安装: sudo bash anytls_manager.sh install
EOF
}

# ---------- 入口 ----------
detect_platform
case "${1:-help}" in
    install)   cmd_install ;;
    update)    cmd_update ;;
    start)     cmd_ctl start ;;
    stop)      cmd_ctl stop ;;
    restart)   cmd_ctl restart ;;
    status)    cmd_status ;;
    log)       shift; cmd_log "$@" ;;
    qr)        cmd_qr ;;
    passwd)    shift; cmd_passwd "$@" ;;
    uninstall) cmd_uninstall ;;
    help|-h|--help) usage ;;
    *)         usage; exit 1 ;;
esac
