#!/bin/bash
# =====================================================================
# anytls_manager.sh - AnyTLS-Go 服务端一键安装与管理脚本（UUID 密码 + 二维码）
# 上游项目: https://github.com/anytls/anytls-go
# 用法: sudo bash anytls_manager.sh install
# 安装后可使用: anytls {install|update|start|stop|restart|status|log|qr|passwd|uninstall|help}
# 支持架构: amd64 / arm64；需要 systemd
# =====================================================================

set -u

SCRIPT_VERSION="2026.10.28-uuid"        # 脚本版本标记，安装时会打印，用于确认是否为最新脚本
VERSION="${ANYTLS_VERSION:-0.0.8}"       # 目标程序版本，可用环境变量 ANYTLS_VERSION 覆盖
REPO="anytls/anytls-go"
BIN_PATH="/usr/local/bin/anytls-server"
CONF_DIR="/etc/anytls"
CONF_FILE="${CONF_DIR}/config.env"
QR_PNG="${CONF_DIR}/anytls-qr.png"
SERVICE="anytls"
UNIT_FILE="/etc/systemd/system/${SERVICE}.service"
SCRIPT_DST="/usr/local/sbin/anytls"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

need_root()      { [[ $EUID -eq 0 ]] || err "请使用 root 或 sudo 运行"; }
need_systemd()   { [[ -d /run/systemd/system ]] || err "当前系统不支持 systemd"; }
need_installed() { [[ -f "$BIN_PATH" && -f "$CONF_FILE" ]] || err "未安装，请先执行 install"; }

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
    info "安装 qrencode（二维码工具）..."
    if command -v apt-get &>/dev/null; then
        apt-get install -y qrencode
    elif command -v dnf &>/dev/null; then
        dnf install -y qrencode
    elif command -v yum &>/dev/null; then
        if ! yum install -y qrencode; then
            warn "yum 未找到 qrencode，CentOS / RHEL 系通常需要先启用 EPEL："
            warn "  sudo yum install -y epel-release"
            yum install -y qrencode
        fi
    elif command -v pacman &>/dev/null; then
        pacman -S --noconfirm --needed qrencode
    else
        warn "未识别的包管理器，无法自动安装 qrencode"
    fi
    command -v qrencode &>/dev/null
}

install_deps() {
    info "安装基础依赖（wget / unzip / curl / iproute）..."
    if command -v apt-get &>/dev/null; then
        apt-get update -y >/dev/null
        apt-get install -y wget unzip curl iproute2 >/dev/null
    elif command -v dnf &>/dev/null; then
        dnf install -y wget unzip curl iproute >/dev/null
    elif command -v yum &>/dev/null; then
        yum install -y wget unzip curl iproute >/dev/null
    elif command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm --needed wget unzip curl iproute2 >/dev/null
    else
        warn "未识别的包管理器，请确保已安装 wget、unzip、curl"
    fi
    for c in curl unzip; do
        command -v "$c" &>/dev/null || err "缺少依赖: $c"
    done
    install_qrencode || warn "qrencode 安装失败，二维码将无法显示，但连接链接仍会输出"
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

    install -m 755 "$found" "$BIN_PATH"
    rm -rf "$tmp"
}

# 每次 install 都同步管理脚本本体，保证 anytls 命令与最新脚本一致
sync_self() {
    local self; self=$(readlink -f "$0")
    if [[ -f "$self" && "$self" != "$SCRIPT_DST" ]]; then
        install -m 755 "$self" "$SCRIPT_DST"
    fi
}

# ---------- 防火墙 ----------
open_firewall() {
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        ufw allow "$1/tcp" >/dev/null
    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port="$1/tcp" >/dev/null
        firewall-cmd --reload >/dev/null
    else
        warn "未检测到活动防火墙，请确认端口 $1 已放行（云服务器需检查安全组）"
    fi
}

close_firewall() {
    local p=$1
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        ufw delete allow "$p/tcp" >/dev/null 2>&1
    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --remove-port="$p/tcp" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
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
    cat > "$UNIT_FILE" <<EOF
[Unit]
Description=AnyTLS-Go server
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=${BIN_PATH} -l 0.0.0.0:${PORT} -p ${PASSWORD}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

restart_and_check() {
    systemctl enable "$SERVICE" >/dev/null 2>&1
    systemctl restart "$SERVICE"
    sleep 2
    systemctl is-active --quiet "$SERVICE" || err "服务启动失败，请执行: anytls log"
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

    if ! command -v qrencode &>/dev/null; then
        warn "qrencode 未安装，尝试重新安装..."
        install_qrencode || {
            warn "仍无法安装 qrencode，二维码未生成。请手动安装 qrencode 后运行 anytls qr"
            return 0
        }
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
    need_root; need_systemd
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
    need_root; need_systemd; need_installed
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
    need_root; need_systemd; need_installed
    systemctl "$1" "$SERVICE" || err "执行 $1 失败，请执行: anytls log"
    info "服务已 $1"
}

cmd_status() {
    need_systemd; need_installed
    load_conf
    local st="已停止"
    systemctl is-active --quiet "$SERVICE" && st="运行中"
    echo "--------------------------------------------"
    echo " 服务状态 : $st"
    echo " 程序版本 : v${INSTALLED_VERSION:-未知}"
    echo " 监听端口 : ${PORT}"
    echo " 节点名称 : ${NODE_NAME:-AnyTLS}"
    echo "--------------------------------------------"
}

cmd_log() {
    need_root
    if [[ $# -eq 0 ]]; then
        journalctl -u "$SERVICE" -n 100 --no-pager
    else
        journalctl -u "$SERVICE" --no-pager "$@"
    fi
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
    need_root; need_systemd; need_installed
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
    need_root; need_systemd
    read -rp "确认卸载 anytls-go（配置与二维码将被删除）? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消"; return; }
    load_conf 2>/dev/null
    systemctl disable --now "$SERVICE" >/dev/null 2>&1
    [[ -n "${PORT:-}" ]] && close_firewall "$PORT"
    rm -f "$UNIT_FILE"
    systemctl daemon-reload
    rm -f "$BIN_PATH" "$SCRIPT_DST"
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
  anytls log [参数]     查看日志，可附加 journalctl 参数，如 -n 200
  anytls qr             输入密码确认后，显示连接链接与二维码
  anytls passwd [密码]  重新设置密码，不填则生成 UUID 格式
  anytls uninstall      卸载
  anytls help           显示本帮助

首次安装: sudo bash anytls_manager.sh install
EOF
}

# ---------- 入口 ----------
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
