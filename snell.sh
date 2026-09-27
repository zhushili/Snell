#!/usr/bin/env bash
# =============================================================================
#  Snell v6 服务端一键安装 / 管理脚本
#  项目主页 : https://github.com/zhushili/Snell（MIT License）
#
#  基于版本 : Snell Server v6.0.0rc2（v6 Release Candidate 2）
#  核实日期 : 2026-09-27
#  核实来源 : https://kb.nssurge.com/surge-knowledge-base/release-notes/snell
#             https://manual.nssurge.com/policies/snell.html
#
#  重要提示 :
#    * Snell v6 目前仍处于 beta / RC 阶段，官方说明协议可能出现不兼容变更。
#    * 服务端与客户端版本必须匹配：Surge 端需 version=6，且 mode 与服务端一致；
#      需要 Surge iOS 5.20.0+ / Surge Mac 6.7.0+，并请随服务端同步更新客户端。
#    * v6 不再支持 obfs，也移除了 v5 的 QUIC Proxy Mode（UDP 走 UDP over TCP，
#      因此服务端只需放行 TCP 端口）。
#
#  支持系统 : Debian 11/12/13, Ubuntu 22.04/24.04/26.04, CentOS Stream/Rocky/Alma 8/9
#  支持架构 : x86_64 (amd64), aarch64 (arm64)
#
#  用法     : bash snell.sh                 # 交互式菜单
#             bash snell.sh install --port 12345 --psk xxx --mode default
#             bash snell.sh --help          # 查看全部命令与参数
#
#  脚本更新 : 运行 self-update（或菜单「检查脚本更新」）手动检查 GitHub 上的新版本，
#             确认后才更新；启动时不联网检查。
# =============================================================================

set -Eeuo pipefail
# 让 $(...) 内部继承 set -e（bash >= 4.4）；旧 bash 不支持时忽略，关键步骤另有显式错误处理
shopt -s inherit_errexit 2>/dev/null || true
umask 022

# ------------------------------- 常量 ----------------------------------------
readonly SCRIPT_VERSION="1.3.0"
readonly SCRIPT_URL="https://raw.githubusercontent.com/zhushili/Snell/main/snell.sh"
readonly DEFAULT_SNELL_VERSION="v6.0.0rc2"
readonly DOWNLOAD_BASE="https://dl.nssurge.com/snell"

readonly BIN_PATH="/usr/local/bin/snell-server"
readonly CONF_DIR="/etc/snell"
readonly CONF_FILE="${CONF_DIR}/snell-server.conf"
readonly META_FILE="${CONF_DIR}/.install-meta"
readonly BACKUP_DIR="/var/backups/snell"
readonly SERVICE_NAME="snell"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
readonly SNELL_USER="snell"
# 旧版本脚本开启 BBR 时写入的文件（BBR 已移出本脚本，仅卸载时询问是否清理）
readonly BBR_SYSCTL_FILE="/etc/sysctl.d/99-snell-bbr.conf"
readonly BBR_MODULE_FILE="/etc/modules-load.d/snell-bbr.conf"
readonly FW_COMMENT="snell-server"
readonly LOCK_FILE="/run/snell-sh.lock"
readonly PORT_MIN=10000
readonly PORT_MAX=60000
readonly KEEP_BACKUPS=3

# ------------------------------- 运行时变量 ----------------------------------
SNELL_VERSION="${SNELL_VERSION:-$DEFAULT_SNELL_VERSION}"
ARCH=""
PKG_MGR=""
TMP_DIR=""
INTERACTIVE=1

# 命令行参数
COMMAND=""
OPT_PORT=""
OPT_PSK=""
OPT_PSK_FILE=""
OPT_MODE=""
OPT_DNS_PREF=""
OPT_IPV6=""
OPT_EGRESS=""
OPT_DNS=""
OPT_NAME="Snell-v6"
OPT_FOLLOW=0
OPT_LINES=100
ASSUME_YES=0
HAS_CFG_OPTS=0

# 当前配置（由 load_config 或用户输入填充）
CFG_PORT=""
CFG_PSK=""
CFG_MODE="default"
CFG_DNS_PREF="default"
CFG_IPV6="false"
CFG_EGRESS=""
CFG_DNS=""

# ------------------------------- 输出 ----------------------------------------
setup_colors() {
    C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_BOLD="" C_RESET=""
    E_RED="" E_YELLOW="" E_RESET=""
    if [[ -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
        if [[ -t 1 ]]; then
            C_RED=$'\033[31m' C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m'
            C_BLUE=$'\033[36m' C_BOLD=$'\033[1m' C_RESET=$'\033[0m'
        fi
        if [[ -t 2 ]]; then
            E_RED=$'\033[31m' E_YELLOW=$'\033[33m' E_RESET=$'\033[0m'
        fi
    fi
}

info()  { printf '%s[信息]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()    { printf '%s[成功]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '%s[警告]%s %s\n' "$E_YELLOW" "$E_RESET" "$*" >&2; }
error() { printf '%s[错误]%s %s\n' "$E_RED" "$E_RESET" "$*" >&2; }
die()   { error "$*"; exit 1; }

on_err() {
    local line="$1" cmd="$2"
    error "脚本第 ${line} 行执行失败：${cmd}"
    error "操作已中止，未完成的步骤不会继续执行。"
}

cleanup() {
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf -- "$TMP_DIR"
    fi
}

set_err_trap() {
    trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR
}

set_err_trap
trap cleanup EXIT

# ------------------------------- 交互工具 ------------------------------------
to_lower() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# ask_yes_no <提示> <默认 y|n>；非交互模式下 --yes 视为同意，否则取默认值
ask_yes_no() {
    local prompt="$1" def="${2:-n}" ans hint
    if (( ! INTERACTIVE )); then
        if (( ASSUME_YES )) || [[ "$def" == "y" ]]; then return 0; fi
        return 1
    fi
    if [[ "$def" == "y" ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
    while true; do
        read -r -p "${prompt} ${hint}: " ans || return 1
        ans="$(to_lower "${ans:-$def}")"
        case "$ans" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *)     warn "请输入 y 或 n" ;;
        esac
    done
}

pause() {
    if (( INTERACTIVE )); then
        read -r -p "按回车键返回菜单..." _ || true
    fi
}

# ------------------------------- 校验函数 ------------------------------------
is_valid_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

# PSK：16–255 字符（脚本策略，官方建议 32 位随机串）；
# 禁止逗号 / 空白 / 引号 / # 等会破坏配置文件或 Surge 配置行的字符
is_valid_psk() {
    local re='^[A-Za-z0-9._~+/=@-]{16,255}$'
    [[ "$1" =~ $re ]]
}

is_valid_mode() {
    case "$1" in default|unshaped|unsafe-raw) return 0 ;; *) return 1 ;; esac
}

is_valid_dns_pref() {
    case "$1" in default|prefer-ipv4|prefer-ipv6|ipv4-only|ipv6-only) return 0 ;; *) return 1 ;; esac
}

is_valid_version() {
    local re='^v6\.[0-9]+\.[0-9]+[a-z0-9]*$'
    [[ "$1" =~ $re ]]
}

# 把版本号转成可按字典序比较的键：主.次.修订.阶段.序号
# 阶段：b/beta=1 < rc=2 < 正式版=3；不带序号的 b / rc 视为 1（官方同时发布过 rc 与 rc2）
# 例：v6.0.0b1 < v6.0.0b4 < v6.0.0rc < v6.0.0rc2 < v6.0.0 < v6.0.1b1
version_key() {
    local re='^v?([0-9]+)\.([0-9]+)\.([0-9]+)([a-z]*)([0-9]*)$' maj min pat suf num stage
    [[ "$1" =~ $re ]] || return 1
    maj="${BASH_REMATCH[1]}" min="${BASH_REMATCH[2]}" pat="${BASH_REMATCH[3]}"
    suf="${BASH_REMATCH[4]}" num="${BASH_REMATCH[5]}"
    case "$suf" in
        "")     stage=3; num=0 ;;
        rc)     stage=2 ;;
        b|beta) stage=1 ;;
        *)      return 1 ;;
    esac
    printf '%05d.%05d.%05d.%d.%05d' "$((10#$maj))" "$((10#$min))" "$((10#$pat))" "$stage" "$((10#${num:-1}))"
}

# version_compare A B：A<B 输出 -1，相等输出 0，A>B 输出 1；无法解析时返回非 0
version_compare() {
    local a b
    a="$(version_key "$1")" || return 1
    b="$(version_key "$2")" || return 1
    if [[ "$a" < "$b" ]]; then
        echo "-1"
    elif [[ "$a" > "$b" ]]; then
        echo "1"
    else
        echo "0"
    fi
}

is_valid_dns_list() {
    local re='^[0-9A-Fa-f.:, ]+$'
    [[ "$1" =~ $re ]]
}

# 归一化布尔 / auto 输入
normalize_ipv6_opt() {
    case "$(to_lower "$1")" in
        auto)                 echo "auto" ;;
        true|yes|on|1)        echo "true" ;;
        false|no|off|0)       echo "false" ;;
        *)                    return 1 ;;
    esac
}

# ------------------------------- 环境检测 ------------------------------------
check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        die "请使用 root 用户运行本脚本（例如：sudo bash snell.sh）"
    fi
}

check_systemd() {
    if [[ ! -d /run/systemd/system ]] || ! command -v systemctl >/dev/null 2>&1; then
        die "未检测到 systemd，本脚本仅支持以 systemd 为 init 的系统"
    fi
}

check_os() {
    [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release，无法识别操作系统"
    local id="" version_id="" id_like="" major
    # shellcheck disable=SC1091
    id="$(. /etc/os-release && echo "${ID:-}")"
    # shellcheck disable=SC1091
    version_id="$(. /etc/os-release && echo "${VERSION_ID:-}")"
    # shellcheck disable=SC1091
    id_like="$(. /etc/os-release && echo "${ID_LIKE:-}")"
    major="${version_id%%.*}"

    case "$id" in
        debian)
            case "$major" in
                11|12|13) ;;
                *) warn "Debian ${version_id} 未经测试，将尝试继续" ;;
            esac
            ;;
        ubuntu)
            case "$version_id" in
                22.04|24.04|26.04) ;;
                *) warn "Ubuntu ${version_id} 未经测试，将尝试继续" ;;
            esac
            ;;
        centos|rocky|almalinux|rhel)
            if [[ "$major" =~ ^[0-9]+$ ]] && (( major < 8 )); then
                die "${id} ${version_id} 过旧（glibc/systemd 版本不足），请使用 8 或更高版本"
            fi
            ;;
        *)
            if [[ " $id_like " == *" debian "* || " $id_like " == *" rhel "* || " $id_like " == *" fedora "* ]]; then
                warn "系统 ${id} ${version_id} 未经测试（兼容 ${id_like}），将尝试继续"
            else
                die "不支持的操作系统：${id:-unknown} ${version_id}"
            fi
            ;;
    esac

    if command -v apt-get >/dev/null 2>&1; then
        PKG_MGR="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MGR="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MGR="yum"
    else
        die "未找到 apt-get / dnf / yum，无法安装依赖"
    fi
}

detect_arch() {
    local m
    m="$(uname -m)"
    case "$m" in
        x86_64|amd64)  ARCH="amd64" ;;
        aarch64|arm64) ARCH="aarch64" ;;
        *) die "不支持的 CPU 架构：${m}（本脚本仅支持 x86_64 与 aarch64）" ;;
    esac
}

# 安装缺失的依赖：curl unzip ss(iproute) openssl
install_deps() {
    local missing=() pkg_ss="iproute2"
    [[ "$PKG_MGR" != "apt" ]] && pkg_ss="iproute"
    command -v curl    >/dev/null 2>&1 || missing+=("curl" "ca-certificates")
    command -v unzip   >/dev/null 2>&1 || missing+=("unzip")
    command -v ss      >/dev/null 2>&1 || missing+=("$pkg_ss")
    command -v openssl >/dev/null 2>&1 || missing+=("openssl")
    (( ${#missing[@]} == 0 )) && return 0

    info "安装依赖：${missing[*]}"
    case "$PKG_MGR" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq >/dev/null || die "apt-get update 失败，请检查软件源与网络"
            apt-get install -y -qq "${missing[@]}" >/dev/null || die "依赖安装失败：${missing[*]}"
            ;;
        dnf|yum)
            "$PKG_MGR" install -y -q "${missing[@]}" >/dev/null || die "依赖安装失败：${missing[*]}"
            ;;
    esac
    for c in curl unzip ss; do
        command -v "$c" >/dev/null 2>&1 || die "依赖 ${c} 安装后仍不可用"
    done
}

preflight() {
    check_root
    check_systemd
    check_os
    detect_arch
    install_deps
}

# ------------------------------- 通用工具 ------------------------------------
# 读取 key = value 形式文件中的值：kv_get <文件> <键>
kv_get() {
    local file="$1" key="$2"
    [[ -r "$file" ]] || return 0
    awk -v k="$key" '
        { line = $0; sub(/^[ \t]+/, "", line) }
        line ~ /^[#;\[]/ { next }
        {
            pos = index(line, "="); if (pos == 0) next
            name = substr(line, 1, pos - 1); sub(/[ \t]+$/, "", name)
            if (name == k) {
                val = substr(line, pos + 1)
                sub(/^[ \t]+/, "", val); sub(/[ \t\r]+$/, "", val)
                print val; exit
            }
        }' "$file"
}

is_installed() {
    [[ -x "$BIN_PATH" && -f "$CONF_FILE" ]]
}

require_installed() {
    is_installed || die "Snell 尚未安装（缺少 ${BIN_PATH} 或 ${CONF_FILE}），请先执行安装"
}

service_active() {
    systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null
}

installed_version() {
    local v
    v="$(kv_get "$META_FILE" VERSION)"
    echo "${v:-unknown}"
}

# 端口（TCP）是否被监听
port_in_use() {
    local port="$1"
    ss -Hltn 2>/dev/null | awk -v p=":${port}" '
        { a = $4; if (substr(a, length(a) - length(p) + 1) == p) found = 1 }
        END { exit !found }'
}

# 端口可用：未被占用，或被当前运行中的 snell 自己占用
port_available() {
    local port="$1" cur_port
    port_in_use "$port" || return 0
    cur_port="$(current_conf_port)"
    if [[ -n "$cur_port" && "$cur_port" == "$port" ]] && service_active; then
        return 0
    fi
    return 1
}

current_conf_port() {
    local listen first
    listen="$(kv_get "$CONF_FILE" listen)"
    [[ -z "$listen" ]] && return 0
    first="${listen%%,*}"
    echo "${first##*:}"
}

random_port() {
    local p i
    for (( i = 0; i < 200; i++ )); do
        p=$(( ( (RANDOM << 15) | RANDOM ) % (PORT_MAX - PORT_MIN + 1) + PORT_MIN ))
        if ! port_in_use "$p"; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

# 生成 32 位字母数字 PSK（约 190 bit 熵）
gen_psk() {
    local s="" chunk i
    if command -v openssl >/dev/null 2>&1; then
        s="$(openssl rand -base64 64 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9')" || s=""
    fi
    # 次数上限防止 /dev/urandom 不可读时无限循环
    for (( i = 0; i < 10 && ${#s} < 32; i++ )); do
        chunk="$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')" || return 1
        s+="$chunk"
    done
    (( ${#s} >= 32 )) || return 1
    printf '%s' "${s:0:32}"
}

# 服务器是否具备可用的全局 IPv6
has_ipv6() {
    local out
    [[ -r /proc/net/if_inet6 ]] || return 1
    [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1)" == "0" ]] || return 1
    out="$(ip -6 addr show scope global 2>/dev/null)" || return 1
    [[ "$out" == *inet6* ]] || return 1
    out="$(ip -6 route show default 2>/dev/null)" || return 1
    [[ -n "$out" ]]
}

# 获取公网 IP：get_public_ip 4|6
get_public_ip() {
    local v="$1" url ip
    local -a urls
    if [[ "$v" == "4" ]]; then
        urls=("https://api.ipify.org" "https://ipv4.icanhazip.com" "https://4.ipw.cn")
    else
        urls=("https://api6.ipify.org" "https://ipv6.icanhazip.com" "https://6.ipw.cn")
    fi
    for url in "${urls[@]}"; do
        ip="$(curl -"$v" -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')" || continue
        if [[ "$v" == "4" && "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            echo "$ip"; return 0
        fi
        if [[ "$v" == "6" && "$ip" == *:* && "$ip" =~ ^[0-9A-Fa-f:]+$ ]]; then
            echo "$ip"; return 0
        fi
    done
    return 1
}

ensure_tmp_dir() {
    if [[ -z "$TMP_DIR" ]]; then
        TMP_DIR="$(mktemp -d /tmp/snell-install.XXXXXX)" || die "无法创建临时目录"
    fi
}

# ------------------------------- 二进制下载与校验 ----------------------------
# 校验 ELF 魔数、64 位、以及机器架构与当前系统一致
verify_elf() {
    local f="$1" magic class machine expect
    [[ -s "$f" ]] || die "文件为空：${f}"
    magic="$(od -An -tx1 -N4 "$f" | tr -d ' \n')"
    [[ "$magic" == "7f454c46" ]] || die "下载的文件不是有效的 ELF 可执行文件，已中止"
    class="$(od -An -tx1 -j4 -N1 "$f" | tr -d ' \n')"
    machine="$(od -An -tx1 -j18 -N2 "$f" | tr -d ' \n')"
    case "$ARCH" in
        amd64)   expect="3e00" ;;   # EM_X86_64
        aarch64) expect="b700" ;;   # EM_AARCH64
    esac
    if [[ "$class" != "02" || "$machine" != "$expect" ]]; then
        die "ELF 架构与本机（${ARCH}）不匹配，已中止"
    fi
}

# 下载并解压指定版本，成功后输出二进制路径
fetch_binary() {
    local version="$1" url zip dir bin
    [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] || die "内部错误：临时目录未初始化"
    url="${DOWNLOAD_BASE}/snell-server-${version}-linux-${ARCH}.zip"
    zip="${TMP_DIR}/snell-${version}.zip"
    dir="${TMP_DIR}/extract-${version}"

    info "下载 ${url}" >&2
    if ! curl -fL --proto '=https' --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 300 \
            -sS -o "$zip" "$url"; then
        die "下载失败：${url}（请检查网络，或确认版本号 ${version} 是否存在）"
    fi
    unzip -tq "$zip" >/dev/null 2>&1 || die "压缩包校验失败（文件可能损坏或下载不完整）"
    rm -rf -- "$dir" || die "无法清理解压目录：${dir}"
    mkdir -p "$dir" || die "无法创建解压目录：${dir}"
    unzip -oq "$zip" -d "$dir" || die "解压失败：${zip}"

    bin="$(find "$dir" -type f -name 'snell-server' -print -quit)" || die "查找解压文件失败"
    [[ -n "$bin" ]] || die "压缩包中未找到 snell-server 可执行文件"
    verify_elf "$bin"
    chmod 755 "$bin" || die "无法设置可执行权限：${bin}"
    echo "$bin"
}

# 原子替换二进制
install_binary() {
    local src="$1"
    install -m 755 -o root -g root "$src" "${BIN_PATH}.new" || die "写入 ${BIN_PATH} 失败"
    mv -f "${BIN_PATH}.new" "$BIN_PATH" || die "替换 ${BIN_PATH} 失败"
}

# ------------------------------- 用户 / 配置 / 服务 --------------------------
ensure_user() {
    if id -u "$SNELL_USER" >/dev/null 2>&1; then
        return 0
    fi
    local nologin
    nologin="$(command -v nologin || echo /usr/sbin/nologin)"
    useradd --system --user-group --no-create-home --home-dir /nonexistent \
        --shell "$nologin" "$SNELL_USER" || die "创建系统用户 ${SNELL_USER} 失败"
    info "已创建低权限系统用户：${SNELL_USER}"
}

load_config() {
    local listen first ipv6
    listen="$(kv_get "$CONF_FILE" listen)"
    first="${listen%%,*}"
    CFG_PORT="${first##*:}"
    CFG_PSK="$(kv_get "$CONF_FILE" psk)"
    CFG_MODE="$(kv_get "$CONF_FILE" mode)"
    CFG_MODE="${CFG_MODE:-default}"
    CFG_DNS_PREF="$(kv_get "$CONF_FILE" dns-ip-preference)"
    CFG_DNS_PREF="${CFG_DNS_PREF:-default}"
    CFG_EGRESS="$(kv_get "$CONF_FILE" egress-interface)"
    CFG_DNS="$(kv_get "$CONF_FILE" dns)"
    ipv6="$(kv_get "$CONF_FILE" ipv6)"
    if [[ -n "$ipv6" ]]; then
        CFG_IPV6="$ipv6"
    elif [[ "$listen" == *"::"* ]]; then
        CFG_IPV6="true"
    else
        CFG_IPV6="false"
    fi
}

build_listen() {
    if [[ "$CFG_IPV6" == "true" ]]; then
        echo "0.0.0.0:${CFG_PORT},[::]:${CFG_PORT}"
    else
        echo "0.0.0.0:${CFG_PORT}"
    fi
}

# 配置目录 root:snell 0750、配置文件 root:snell 0640：服务进程只能读、不能改
# 并实际以 snell 用户确认可读（没有 runuser 时跳过这一步验证）
secure_conf_perms() {
    chown root:"$SNELL_USER" "$CONF_DIR" || die "设置 ${CONF_DIR} 属主失败"
    chmod 750 "$CONF_DIR" || die "设置 ${CONF_DIR} 权限失败"
    [[ -f "$CONF_FILE" ]] || return 0
    chown root:"$SNELL_USER" "$CONF_FILE" || die "设置 ${CONF_FILE} 属主失败"
    chmod 640 "$CONF_FILE" || die "设置 ${CONF_FILE} 权限失败"
    if command -v runuser >/dev/null 2>&1; then
        runuser -u "$SNELL_USER" -- test -r "$CONF_FILE" ||
            die "${SNELL_USER} 用户无法读取 ${CONF_FILE}，服务将无法启动，请检查目录权限"
    fi
}

# 写入配置文件（先写临时文件再原子替换），属主 root:snell，权限 0640
write_config() {
    local tmp
    mkdir -p "$CONF_DIR"
    chown root:"$SNELL_USER" "$CONF_DIR"
    chmod 750 "$CONF_DIR"
    tmp="$(mktemp "${CONF_DIR}/.snell-server.conf.XXXXXX")"
    {
        echo "[snell-server]"
        echo "listen = $(build_listen)"
        echo "psk = ${CFG_PSK}"
        echo "mode = ${CFG_MODE}"
        echo "ipv6 = ${CFG_IPV6}"
        echo "dns-ip-preference = ${CFG_DNS_PREF}"
        if [[ -n "$CFG_EGRESS" ]]; then echo "egress-interface = ${CFG_EGRESS}"; fi
        if [[ -n "$CFG_DNS" ]]; then echo "dns = ${CFG_DNS}"; fi
    } >"$tmp"
    chown root:"$SNELL_USER" "$tmp" || die "设置配置文件属主失败"
    chmod 640 "$tmp" || die "设置配置文件权限失败"
    mv -f "$tmp" "$CONF_FILE" || die "写入 ${CONF_FILE} 失败"
    secure_conf_perms
}

write_service() {
    local caps="CAP_NET_BIND_SERVICE"
    # egress-interface 需要 CAP_NET_RAW / CAP_NET_ADMIN（官方 v5 说明）
    if [[ -n "$CFG_EGRESS" ]]; then
        caps="CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_NET_ADMIN"
    fi
    cat >"$SERVICE_FILE" <<EOF
# 由 snell.sh ${SCRIPT_VERSION} 生成
[Unit]
Description=Snell Proxy Server (v6)
Documentation=https://kb.nssurge.com/surge-knowledge-base/release-notes/snell
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=${SNELL_USER}
Group=${SNELL_USER}
ExecStart=${BIN_PATH} -c ${CONF_FILE}
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
AmbientCapabilities=${caps}
CapabilityBoundingSet=${caps}
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
ProtectClock=true
ProtectHostname=true
ProtectKernelLogs=true
SystemCallArchitectures=native
UMask=0077
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
StandardOutput=journal
StandardError=journal
SyslogIdentifier=snell

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$SERVICE_FILE"
    systemctl daemon-reload
}

# 重启服务并确认：进程存活且端口在监听；失败时打印日志并返回非 0
service_start_verify() {
    local port="$1" i
    systemctl daemon-reload
    systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || true
    for (( i = 0; i < 10; i++ )); do
        sleep 1
        if service_active && port_in_use "$port"; then
            sleep 1
            service_active && return 0
        fi
    done
    error "Snell 服务启动失败，最近日志如下："
    journalctl -u "$SERVICE_NAME" -n 30 --no-pager >&2 || true
    if [[ "$CFG_IPV6" == "true" ]]; then
        warn "若日志提示地址占用 / IPv6 相关错误，可尝试：bash snell.sh config --ipv6 false"
    fi
    return 1
}

save_meta() {
    local fw="$1"
    mkdir -p "$CONF_DIR"
    {
        echo "VERSION=${SNELL_VERSION}"
        echo "PORT=${CFG_PORT}"
        echo "FIREWALL=${fw}"
        echo "SCRIPT_VERSION=${SCRIPT_VERSION}"
        echo "UPDATED_AT=$(date '+%F %T')"
    } >"$META_FILE"
    chown root:root "$META_FILE"
    chmod 600 "$META_FILE"
}

# 备份文件并输出备份路径；任何一步失败或备份为空都返回非 0（调用方须检查）
backup_file() {
    local src="$1" prefix="$2" ts dest
    ts="$(date +%Y%m%d-%H%M%S)" || return 1
    dest="${BACKUP_DIR}/${prefix}-${ts}"
    mkdir -p "$BACKUP_DIR" || return 1
    chmod 700 "$BACKUP_DIR" || return 1
    cp -a -- "$src" "$dest" || return 1
    [[ -s "$dest" ]] || return 1
    echo "$dest"
}

# 每类备份仅保留最近 KEEP_BACKUPS 份
prune_backups() {
    local prefix files i n
    for prefix in bin conf svc; do
        shopt -s nullglob
        files=("${BACKUP_DIR}/${prefix}-"*)
        shopt -u nullglob
        n=${#files[@]}
        for (( i = 0; i < n - KEEP_BACKUPS; i++ )); do
            rm -f -- "${files[$i]}"
        done
    done
}

# ------------------------------- 防火墙 --------------------------------------
# ipt_chain_restrictive <iptables|ip6tables>：INPUT 链是否含默认拒绝或 DROP/REJECT 规则
ipt_chain_restrictive() {
    local bin="$1" rules
    command -v "$bin" >/dev/null 2>&1 || return 1
    rules="$("$bin" -S INPUT 2>/dev/null)" || return 1
    [[ "$rules" == *"-P INPUT DROP"* || "$rules" == *"-j DROP"* || "$rules" == *"-j REJECT"* ]]
}

# IPv4 或 IPv6 任一方向有限制性规则即视为需要放行
iptables_restrictive() {
    ipt_chain_restrictive iptables || ipt_chain_restrictive ip6tables
}

detect_firewall() {
    local st
    if command -v ufw >/dev/null 2>&1; then
        st="$(ufw status 2>/dev/null || true)"
        if [[ "$st" == *"Status: active"* ]]; then echo "ufw"; return; fi
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        echo "firewalld"; return
    fi
    if iptables_restrictive; then
        echo "iptables"; return
    fi
    echo "none"
}

# 安装记录中的防火墙后端；旧版 meta 缺少该字段时改用当前检测结果
meta_firewall() {
    local fw
    fw="$(kv_get "$META_FILE" FIREWALL)"
    if [[ -z "$fw" ]]; then
        fw="$(detect_firewall)"
    fi
    echo "$fw"
}

# 仅支持 netfilter-persistent 持久化；没有时提示规则重启后会丢失
iptables_persist() {
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 || warn "netfilter-persistent 保存规则失败"
    else
        warn "iptables 规则未持久化，重启后会丢失（可安装 iptables-persistent 以自动保存）"
    fi
}

# ipt_rule add|del <端口> <iptables|ip6tables>
ipt_rule() {
    local action="$1" port="$2" bin="$3"
    command -v "$bin" >/dev/null 2>&1 || return 0
    local -a rule=(INPUT -p tcp --dport "$port" -m comment --comment "$FW_COMMENT" -j ACCEPT)
    if [[ "$action" == "add" ]]; then
        "$bin" -C "${rule[@]}" 2>/dev/null || "$bin" -I "${rule[@]}"
    else
        while "$bin" -C "${rule[@]}" 2>/dev/null; do "$bin" -D "${rule[@]}"; done
    fi
}

# 放行端口，输出实际使用的防火墙后端
fw_open() {
    local port="$1" fw
    fw="$(detect_firewall)"
    case "$fw" in
        ufw)
            ufw allow "${port}/tcp" comment "$FW_COMMENT" >/dev/null || warn "ufw 放行端口失败"
            ;;
        firewalld)
            { firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null &&
              firewall-cmd --reload >/dev/null; } || warn "firewalld 放行端口失败"
            ;;
        iptables)
            # 只在对应 INPUT 链已有 DROP/REJECT（含默认 DROP）时才插入放行规则
            if ipt_chain_restrictive iptables; then
                ipt_rule add "$port" iptables || warn "iptables 放行端口失败"
            fi
            if [[ "$CFG_IPV6" == "true" ]] && ipt_chain_restrictive ip6tables; then
                ipt_rule add "$port" ip6tables || warn "ip6tables 放行端口失败"
            fi
            iptables_persist
            ;;
        none) ;;
    esac
    echo "$fw"
}

fw_close() {
    local port="$1" fw="$2"
    [[ -z "$port" ]] && return 0
    case "$fw" in
        ufw)
            ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
            ;;
        firewalld)
            { firewall-cmd --permanent --remove-port="${port}/tcp" >/dev/null 2>&1 &&
              firewall-cmd --reload >/dev/null 2>&1; } || true
            ;;
        iptables)
            ipt_rule del "$port" iptables || true
            ipt_rule del "$port" ip6tables || true
            iptables_persist
            ;;
        *) ;;
    esac
    return 0
}

# 按当前 CFG_PORT / CFG_IPV6 重新同步放行规则：先移除旧端口的规则（含 ip6tables），
# 再按当前配置放行；输出实际使用的防火墙后端
fw_resync() {
    local old_port="$1" old_fw="$2"
    fw_close "$old_port" "$old_fw"
    fw_open "$CFG_PORT"
}

report_firewall() {
    local fw="$1" port="$2"
    case "$fw" in
        none) info "未检测到启用中的 ufw / firewalld / 限制性 iptables 规则，无需放行" ;;
        *)    ok "已通过 ${fw} 放行 TCP 端口 ${port}" ;;
    esac
    warn "如使用云服务器，请同时在云厂商控制台的安全组中放行 TCP ${port}"
}

# ------------------------------- 参数收集 ------------------------------------
confirm_unsafe_raw() {
    printf '\n' >&2
    warn "================================================================"
    warn " unsafe-raw 模式会关闭【加密】和【流量整形】，所有流量明文转发！"
    warn " 任何途经网络都可以看到并篡改你的流量内容。"
    warn " 仅适用于内网、或外层已有其他安全隧道（如 WireGuard）的场景。"
    warn "================================================================"
    if (( ! INTERACTIVE )); then
        (( ASSUME_YES )) && { warn "已通过 --yes 确认使用 unsafe-raw"; return 0; }
        die "非交互模式下使用 unsafe-raw 必须同时加 --yes 以确认风险"
    fi
    ask_yes_no "确定要使用 unsafe-raw 模式吗？" n || return 1
    local ans
    read -r -p "请再次输入 unsafe-raw 以确认: " ans || return 1
    [[ "$ans" == "unsafe-raw" ]]
}

prompt_port() {
    local ans def_hint="回车随机"
    [[ -n "$CFG_PORT" ]] && def_hint="回车保持 ${CFG_PORT}，输入 r 随机"
    while true; do
        read -r -p "请输入端口 [1-65535，${def_hint}]: " ans || die "输入中断"
        if [[ -z "$ans" && -n "$CFG_PORT" ]]; then
            return 0
        fi
        if [[ -z "$ans" || "$ans" == "r" ]]; then
            CFG_PORT="$(random_port)" || die "未能找到可用的随机端口"
            info "已随机选择端口：${CFG_PORT}"
            return 0
        fi
        if ! is_valid_port "$ans"; then
            warn "端口无效，请输入 1-65535 之间的数字"; continue
        fi
        ans=$((10#$ans))
        if ! port_available "$ans"; then
            warn "端口 ${ans} 已被占用，请更换"; continue
        fi
        (( ans < 1024 )) && warn "使用 1024 以下端口，服务将通过 CAP_NET_BIND_SERVICE 绑定"
        CFG_PORT="$ans"
        return 0
    done
}

prompt_psk() {
    local ans def_hint="回车自动生成"
    [[ -n "$CFG_PSK" ]] && def_hint="回车保持不变，输入 r 重新生成"
    while true; do
        read -r -p "请输入 PSK [16-255 位，${def_hint}]: " ans || die "输入中断"
        if [[ -z "$ans" && -n "$CFG_PSK" ]]; then
            return 0
        fi
        if [[ -z "$ans" || "$ans" == "r" ]]; then
            CFG_PSK="$(gen_psk)" || die "生成随机 PSK 失败"
            info "已生成随机 PSK"
            return 0
        fi
        if is_valid_psk "$ans"; then
            CFG_PSK="$ans"; return 0
        fi
        warn "PSK 需为 16-255 位，仅可包含字母、数字及 . _ ~ + / = @ -"
    done
}

prompt_mode() {
    local ans m
    while true; do
        echo "请选择 mode（须与 Surge 客户端一致）："
        echo "  1) default    - 加密 + PSK 派生流量整形（推荐）"
        echo "  2) unshaped   - 仅加密，关闭流量整形（吞吐约 +10%）"
        echo "  3) unsafe-raw - 无加密无整形，明文转发（危险）"
        read -r -p "请选择 [1-3，回车为 ${CFG_MODE}]: " ans || die "输入中断"
        case "$ans" in
            "")  m="$CFG_MODE" ;;
            1)   m="default" ;;
            2)   m="unshaped" ;;
            3)   m="unsafe-raw" ;;
            *)   warn "无效选择"; continue ;;
        esac
        if [[ "$m" == "unsafe-raw" && "$CFG_MODE" != "unsafe-raw" ]]; then
            if ! confirm_unsafe_raw; then
                warn "已取消 unsafe-raw，请重新选择"; continue
            fi
        fi
        CFG_MODE="$m"
        return 0
    done
}

prompt_dns_pref() {
    local ans
    local -a opts=(default prefer-ipv4 prefer-ipv6 ipv4-only ipv6-only)
    echo "请选择 dns-ip-preference（DNS 结果的地址族偏好）："
    echo "  1) default  2) prefer-ipv4  3) prefer-ipv6  4) ipv4-only  5) ipv6-only"
    while true; do
        read -r -p "请选择 [1-5，回车为 ${CFG_DNS_PREF}]: " ans || die "输入中断"
        [[ -z "$ans" ]] && return 0
        if [[ "$ans" =~ ^[1-5]$ ]]; then
            CFG_DNS_PREF="${opts[$((ans - 1))]}"
            return 0
        fi
        warn "无效选择"
    done
}

prompt_ipv6() {
    if has_ipv6; then
        if ask_yes_no "检测到本机有 IPv6，是否同时监听 IPv6 并允许 IPv6 出站？" y; then
            CFG_IPV6="true"
        else
            CFG_IPV6="false"
        fi
    else
        info "未检测到可用的全局 IPv6，仅监听 IPv4（ipv6 = false）"
        CFG_IPV6="false"
    fi
}

# 读取 PSK 文件的第一行（去掉首尾空白与 CR），输出 PSK
read_psk_file() {
    local f="$1" line=""
    [[ -f "$f" && -r "$f" ]] || die "无法读取 PSK 文件：${f}"
    IFS= read -r line <"$f" || [[ -n "$line" ]] || die "PSK 文件为空：${f}"
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" ]] || die "PSK 文件第一行为空：${f}"
    printf '%s' "$line"
}

# PSK 来源优先级：--psk > --psk-file > 环境变量 SNELL_PSK（须在取得 root 之后调用）
resolve_psk_source() {
    local tmpf="${SNELL_PSK_TMPFILE:-}"
    # 自动 sudo 时 SNELL_PSK 经由临时文件转交（sudo 会清除环境变量），读取后立即删除
    if [[ -n "$tmpf" && "$(basename "$tmpf")" == snell-psk.* && -f "$tmpf" ]]; then
        if [[ -z "${SNELL_PSK:-}" ]]; then
            SNELL_PSK="$(read_psk_file "$tmpf")" || exit 1
        fi
        rm -f -- "$tmpf"
    fi
    if [[ -n "$OPT_PSK" ]]; then
        return 0
    fi
    if [[ -n "$OPT_PSK_FILE" ]]; then
        OPT_PSK="$(read_psk_file "$OPT_PSK_FILE")" || exit 1
    elif [[ -n "${SNELL_PSK:-}" ]]; then
        OPT_PSK="$SNELL_PSK"
    fi
}

# 将命令行参数覆盖到 CFG_*（仅覆盖提供了的项）
apply_opts() {
    local v
    if [[ -n "$OPT_PORT" ]]; then
        if [[ "$OPT_PORT" == "random" ]]; then
            CFG_PORT="$(random_port)" || die "未能找到可用的随机端口"
        else
            is_valid_port "$OPT_PORT" || die "端口无效：${OPT_PORT}"
            CFG_PORT="$((10#$OPT_PORT))"
            port_available "$CFG_PORT" || die "端口 ${CFG_PORT} 已被占用"
        fi
    fi
    if [[ -n "$OPT_PSK" ]]; then
        if [[ "$OPT_PSK" == "random" ]]; then
            CFG_PSK="$(gen_psk)" || die "生成随机 PSK 失败"
        else
            is_valid_psk "$OPT_PSK" || die "PSK 无效：需 16-255 位，仅可包含字母、数字及 . _ ~ + / = @ -"
            CFG_PSK="$OPT_PSK"
        fi
    fi
    if [[ -n "$OPT_MODE" ]]; then
        is_valid_mode "$OPT_MODE" || die "mode 无效：${OPT_MODE}（可选 default / unshaped / unsafe-raw）"
        if [[ "$OPT_MODE" == "unsafe-raw" && "$CFG_MODE" != "unsafe-raw" ]]; then
            confirm_unsafe_raw || die "已取消"
        fi
        CFG_MODE="$OPT_MODE"
    fi
    if [[ -n "$OPT_DNS_PREF" ]]; then
        is_valid_dns_pref "$OPT_DNS_PREF" ||
            die "dns-ip-preference 无效：${OPT_DNS_PREF}（可选 default / prefer-ipv4 / prefer-ipv6 / ipv4-only / ipv6-only）"
        CFG_DNS_PREF="$OPT_DNS_PREF"
    fi
    if [[ -n "$OPT_IPV6" ]]; then
        v="$(normalize_ipv6_opt "$OPT_IPV6")" || die "--ipv6 取值无效：${OPT_IPV6}（可选 auto / true / false）"
        if [[ "$v" == "auto" ]]; then
            if has_ipv6; then CFG_IPV6="true"; else CFG_IPV6="false"; fi
        else
            CFG_IPV6="$v"
        fi
    fi
    if [[ -n "$OPT_EGRESS" ]]; then
        if [[ "$OPT_EGRESS" == "none" ]]; then
            CFG_EGRESS=""
        else
            ip link show dev "$OPT_EGRESS" >/dev/null 2>&1 || die "网卡不存在：${OPT_EGRESS}"
            CFG_EGRESS="$OPT_EGRESS"
        fi
    fi
    if [[ -n "$OPT_DNS" ]]; then
        if [[ "$OPT_DNS" == "none" ]]; then
            CFG_DNS=""
        else
            is_valid_dns_list "$OPT_DNS" || die "--dns 格式无效，应为逗号分隔的 IP 地址"
            CFG_DNS="$OPT_DNS"
        fi
    fi
}

validate_cfg() {
    is_valid_port "$CFG_PORT" || die "内部错误：端口未设置"
    [[ -n "$CFG_PSK" ]] || die "内部错误：PSK 未设置"
    is_valid_mode "$CFG_MODE" || die "mode 无效：${CFG_MODE}"
    is_valid_dns_pref "$CFG_DNS_PREF" || die "dns-ip-preference 无效：${CFG_DNS_PREF}"
    if [[ "$CFG_IPV6" == "false" ]]; then
        case "$CFG_DNS_PREF" in
            ipv6-only)   die "ipv6 = false 时不能使用 dns-ip-preference = ipv6-only" ;;
            prefer-ipv6) warn "ipv6 = false 时 prefer-ipv6 实际等同于只用 IPv4" ;;
        esac
    fi
}

# ------------------------------- 信息输出 ------------------------------------
surge_line() {
    local name="$1" host="$2"
    echo "${name} = snell, ${host}, ${CFG_PORT}, psk=${CFG_PSK}, version=6, mode=${CFG_MODE}"
}

show_info() {
    local ip4="" ip6="" status
    load_config
    info "正在获取公网 IP..."
    ip4="$(get_public_ip 4)" || ip4=""
    if [[ "$CFG_IPV6" == "true" ]] || has_ipv6; then
        ip6="$(get_public_ip 6)" || ip6=""
    fi
    if service_active; then status="${C_GREEN}运行中${C_RESET}"; else status="${C_RED}未运行${C_RESET}"; fi

    echo
    echo "${C_BOLD}==================== Snell 服务端信息 ====================${C_RESET}"
    printf '  %-20s %s\n' "Snell 版本:" "$(installed_version)（v6 beta/RC）"
    printf '  %-20s %s\n' "服务状态:" "$status"
    printf '  %-20s %s\n' "公网 IPv4:" "${ip4:-未获取到}"
    printf '  %-20s %s\n' "公网 IPv6:" "${ip6:-无}"
    printf '  %-20s %s\n' "端口 (TCP):" "$CFG_PORT"
    printf '  %-20s %s\n' "PSK:" "$CFG_PSK"
    printf '  %-20s %s\n' "mode:" "$CFG_MODE"
    printf '  %-20s %s\n' "ipv6:" "$CFG_IPV6"
    printf '  %-20s %s\n' "dns-ip-preference:" "$CFG_DNS_PREF"
    if [[ -n "$CFG_EGRESS" ]]; then printf '  %-20s %s\n' "egress-interface:" "$CFG_EGRESS"; fi
    if [[ -n "$CFG_DNS" ]]; then printf '  %-20s %s\n' "dns:" "$CFG_DNS"; fi
    printf '  %-20s %s\n' "配置文件:" "$CONF_FILE"
    echo
    echo "${C_BOLD}---------- Surge 配置（粘贴到 [Proxy] 段）----------${C_RESET}"
    if [[ -n "$ip4" ]]; then
        echo "${C_GREEN}$(surge_line "$OPT_NAME" "$ip4")${C_RESET}"
    fi
    if [[ -n "$ip6" && "$CFG_IPV6" == "true" ]]; then
        echo "${C_GREEN}$(surge_line "${OPT_NAME}-IPv6" "$ip6")${C_RESET}"
    fi
    if [[ -z "$ip4" && -z "$ip6" ]]; then
        echo "${C_GREEN}$(surge_line "$OPT_NAME" "<服务器IP>")${C_RESET}"
    fi
    echo
    echo "  需要 Surge iOS 5.20.0+ / Mac 6.7.0+；v6 仍为 beta，客户端与服务端请同步更新。"
    if [[ "$CFG_MODE" == "unsafe-raw" ]]; then warn "当前为 unsafe-raw 模式：流量未加密！"; fi
    echo "${C_BOLD}==========================================================${C_RESET}"
}

# ------------------------------- 命令实现 ------------------------------------
cmd_install() {
    preflight
    is_valid_version "$SNELL_VERSION" || die "版本号格式无效或不是 v6：${SNELL_VERSION}"

    local keep_config=0 bin fw old_obfs bak old_port old_fw
    old_port="$(kv_get "$META_FILE" PORT)"
    old_fw="$(meta_firewall)"
    if [[ -f "$CONF_FILE" ]]; then
        warn "检测到已有配置文件：${CONF_FILE}"
        if (( INTERACTIVE )); then
            if ! ask_yes_no "是否覆盖现有配置？（选 N 将保留原配置，仅重装程序与服务）" n; then
                keep_config=1
            fi
        elif (( ASSUME_YES )); then
            info "已指定 --yes，将覆盖现有配置"
        else
            keep_config=1
            if (( HAS_CFG_OPTS )) || [[ -n "$OPT_PSK" ]]; then
                warn "未指定 --yes，保留原配置并忽略命令行中的配置参数（修改请用 config 命令）"
            fi
        fi
    fi

    if (( keep_config )); then
        load_config
        old_obfs="$(kv_get "$CONF_FILE" obfs)"
        if [[ -n "$old_obfs" ]]; then
            warn "原配置含 obfs = ${old_obfs}，Snell v6 已不支持 obfs，建议覆盖配置"
        fi
        info "保留原配置（端口 ${CFG_PORT}）"
    else
        if [[ -f "$CONF_FILE" ]]; then
            bak="$(backup_file "$CONF_FILE" conf)" || die "备份原配置失败，已中止安装（尚未做任何改动）"
            info "原配置已备份到：${bak}"
        fi
        CFG_PORT="" CFG_PSK="" CFG_MODE="default" CFG_DNS_PREF="default" CFG_EGRESS="" CFG_DNS=""
        if has_ipv6; then CFG_IPV6="true"; else CFG_IPV6="false"; fi
        if (( INTERACTIVE )); then
            prompt_port
            if [[ -n "$OPT_PSK" ]]; then
                info "使用环境变量 SNELL_PSK 提供的 PSK"
            else
                prompt_psk
            fi
            prompt_mode
            prompt_dns_pref
            prompt_ipv6
        fi
        apply_opts
        if [[ -z "$CFG_PORT" ]]; then
            CFG_PORT="$(random_port)" || die "未能找到可用的随机端口"
        fi
        if [[ -z "$CFG_PSK" ]]; then
            CFG_PSK="$(gen_psk)" || die "生成随机 PSK 失败"
        fi
    fi
    validate_cfg

    # 下载与校验在改动系统之前完成，失败不会留下半成品
    ensure_tmp_dir
    bin="$(fetch_binary "$SNELL_VERSION")" || exit 1
    ensure_user
    install_binary "$bin"
    ok "已安装 ${BIN_PATH}（${SNELL_VERSION}）"

    if (( ! keep_config )); then
        write_config
        ok "配置已写入 ${CONF_FILE}（root:${SNELL_USER}，权限 0640）"
    else
        # 保留的旧配置可能是早期版本的 snell:snell 0600，统一收紧
        secure_conf_perms
    fi

    write_service
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || die "设置开机自启失败"

    # 覆盖安装且端口变化时，移除旧端口的放行规则
    if [[ -n "$old_port" && "$old_port" != "$CFG_PORT" ]]; then
        fw_close "$old_port" "$old_fw"
    fi
    fw="$(fw_open "$CFG_PORT")" || die "配置防火墙放行规则失败"
    report_firewall "$fw" "$CFG_PORT"
    save_meta "$fw"

    info "启动 Snell 服务..."
    service_start_verify "$CFG_PORT" || die "服务启动失败，请根据上方日志排查（配置与程序均已保留）"
    ok "Snell 服务已启动并设为开机自启"

    show_info
}

cmd_update() {
    check_root
    check_systemd
    detect_arch
    require_installed
    if ! command -v curl >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1; then
        check_os
        install_deps
    fi
    is_valid_version "$SNELL_VERSION" || die "版本号格式无效或不是 v6：${SNELL_VERSION}"

    local cur bin bak_bin bak_conf bak_svc="" fw order
    cur="$(installed_version)"
    load_config
    info "当前版本：${cur}，目标版本：${SNELL_VERSION}"
    if [[ "$cur" == "$SNELL_VERSION" ]]; then
        if ! ask_yes_no "已是目标版本，是否仍然重新安装？" n; then
            info "无需更新"
            return 0
        fi
    elif [[ "$cur" != "unknown" ]] && order="$(version_compare "$cur" "$SNELL_VERSION")" && [[ "$order" == "1" ]]; then
        # 已安装版本更新：降级需要明确确认（版本未知或无法解析时按正常更新处理）
        warn "已安装版本 ${cur} 比目标版本 ${SNELL_VERSION} 新，继续将会降级"
        if (( INTERACTIVE )); then
            if ! ask_yes_no "确定要降级到 ${SNELL_VERSION} 吗？" n; then
                info "已取消，保持当前版本 ${cur}"
                return 0
            fi
        elif (( ASSUME_YES )); then
            warn "已通过 -y 确认降级"
        else
            die "非交互模式下降级需要加 -y 确认（或用 --snell-version 指定不低于 ${cur} 的版本）"
        fi
    fi

    ensure_tmp_dir
    bin="$(fetch_binary "$SNELL_VERSION")" || exit 1
    # 备份必须在停服务之前完成，任何失败都直接中止，服务保持原状
    bak_bin="$(backup_file "$BIN_PATH" "bin")" || die "备份当前程序失败，已中止更新（服务未受影响）"
    bak_conf="$(backup_file "$CONF_FILE" "conf")" || die "备份配置失败，已中止更新（服务未受影响）"
    if [[ -f "$SERVICE_FILE" ]]; then
        bak_svc="$(backup_file "$SERVICE_FILE" "svc")" || die "备份服务文件失败，已中止更新（服务未受影响）"
    fi
    info "已备份旧程序：${bak_bin}"
    info "已备份配置：${bak_conf}"

    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    install_binary "$bin"
    # 重新生成服务文件，让老安装也获得新的安全加固；与新程序一起经过启动检查
    write_service
    if [[ -n "$bak_svc" ]] && ! cmp -s "$bak_svc" "$SERVICE_FILE"; then
        info "systemd 服务文件已按新版本重新生成（旧文件已备份：${bak_svc}）"
    fi

    if service_start_verify "$CFG_PORT"; then
        fw="$(meta_firewall)"
        save_meta "$fw"
        prune_backups
        ok "已更新到 ${SNELL_VERSION}，配置保持不变"
        warn "请确认 Surge 客户端也已更新到与 ${SNELL_VERSION} 兼容的版本"
        return 0
    fi

    error "新版本启动失败，正在回滚到 ${cur} ..."
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    # 先恢复旧的服务文件，再恢复旧程序
    if [[ -n "$bak_svc" ]]; then
        install -m 644 -o root -g root "$bak_svc" "$SERVICE_FILE" || error "恢复服务文件失败：${bak_svc}"
        systemctl daemon-reload || true
    fi
    install_binary "$bak_bin"
    if service_start_verify "$CFG_PORT"; then
        die "更新失败，已回滚到原版本 ${cur}，服务运行正常"
    fi
    die "更新失败且回滚后仍无法启动，请查看日志：journalctl -u ${SERVICE_NAME} -n 100"
}

cmd_uninstall() {
    check_root
    check_systemd
    if [[ ! -e "$BIN_PATH" && ! -e "$CONF_DIR" && ! -e "$SERVICE_FILE" ]]; then
        info "未检测到 Snell 安装，无需卸载"
        return 0
    fi
    warn "即将卸载 Snell，并删除以下内容："
    echo "  - systemd 服务：${SERVICE_FILE}"
    echo "  - 程序：${BIN_PATH}"
    echo "  - 配置目录：${CONF_DIR}（含配置文件与 PSK）"
    echo "  - 备份目录：${BACKUP_DIR}"
    echo "  - 系统用户：${SNELL_USER}"
    echo "  - 本脚本添加的防火墙放行规则"
    if (( ! INTERACTIVE && ! ASSUME_YES )); then
        die "非交互模式下卸载需要加 --yes 确认"
    fi
    ask_yes_no "确认卸载？" n || { info "已取消"; return 0; }

    local port fw
    port="$(kv_get "$META_FILE" PORT)"
    fw="$(meta_firewall)"
    [[ -z "$port" ]] && port="$(current_conf_port)"

    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f -- "$SERVICE_FILE"
    systemctl daemon-reload
    systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true

    if [[ -n "$port" ]]; then
        fw_close "$port" "${fw:-none}"
        if [[ "${fw:-none}" != "none" ]]; then
            info "已移除 ${fw} 中 TCP ${port} 的放行规则"
        fi
    fi

    rm -f -- "$BIN_PATH" "${BIN_PATH}.new"
    rm -rf -- "$CONF_DIR" "$BACKUP_DIR"
    if id -u "$SNELL_USER" >/dev/null 2>&1; then
        userdel "$SNELL_USER" >/dev/null 2>&1 || warn "删除用户 ${SNELL_USER} 失败"
    fi
    if getent group "$SNELL_USER" >/dev/null 2>&1; then
        groupdel "$SNELL_USER" >/dev/null 2>&1 || true
    fi

    if [[ -f "$BBR_SYSCTL_FILE" || -f "$BBR_MODULE_FILE" ]]; then
        if (( INTERACTIVE )) && ask_yes_no "是否同时移除旧版本脚本写入的 BBR 配置（重启后恢复系统默认）？" n; then
            rm -f -- "$BBR_SYSCTL_FILE" "$BBR_MODULE_FILE"
            info "已移除 BBR 配置文件"
        else
            info "保留 BBR 配置：${BBR_SYSCTL_FILE} ${BBR_MODULE_FILE}"
        fi
    fi
    ok "Snell 已卸载"
}

cmd_show() {
    check_root
    require_installed
    show_info
    echo
    info "配置文件内容（${CONF_FILE}）："
    sed 's/^/    /' "$CONF_FILE"
}

cmd_config() {
    check_root
    check_systemd
    require_installed
    load_config

    local old_port="$CFG_PORT" old_egress="$CFG_EGRESS" old_ipv6="$CFG_IPV6"
    local new_port new_ipv6 before after bak fw old_fw choice ans
    before="$(printf '%s|' "$CFG_PORT" "$CFG_PSK" "$CFG_MODE" "$CFG_IPV6" "$CFG_DNS_PREF" "$CFG_EGRESS" "$CFG_DNS")"

    if (( INTERACTIVE )); then
        while true; do
            echo
            echo "${C_BOLD}当前配置${C_RESET}"
            echo "  1) 端口               : ${CFG_PORT}"
            echo "  2) PSK                : ${CFG_PSK}"
            echo "  3) mode               : ${CFG_MODE}"
            echo "  4) dns-ip-preference  : ${CFG_DNS_PREF}"
            echo "  5) IPv6 监听/出站     : ${CFG_IPV6}"
            echo "  6) egress-interface   : ${CFG_EGRESS:-（未设置）}"
            echo "  7) dns                : ${CFG_DNS:-（系统默认）}"
            echo "  8) 保存并重启服务"
            echo "  0) 放弃修改并返回"
            read -r -p "请选择要修改的项 [0-8]: " choice || return 0
            case "$choice" in
                1) prompt_port ;;
                2) prompt_psk ;;
                3) prompt_mode ;;
                4) prompt_dns_pref ;;
                5) prompt_ipv6 ;;
                6)
                    read -r -p "出口网卡名（回车不变，输入 none 清除）: " ans || ans=""
                    if [[ "$ans" == "none" ]]; then
                        CFG_EGRESS=""
                    elif [[ -n "$ans" ]]; then
                        if ip link show dev "$ans" >/dev/null 2>&1; then
                            CFG_EGRESS="$ans"
                        else
                            warn "网卡不存在：${ans}"
                        fi
                    fi
                    ;;
                7)
                    read -r -p "DNS 服务器，逗号分隔（回车不变，输入 none 清除）: " ans || ans=""
                    if [[ "$ans" == "none" ]]; then
                        CFG_DNS=""
                    elif [[ -n "$ans" ]]; then
                        if is_valid_dns_list "$ans"; then CFG_DNS="$ans"; else warn "格式无效"; fi
                    fi
                    ;;
                8) break ;;
                0) info "未做任何修改"; return 0 ;;
                *) warn "无效选择" ;;
            esac
        done
    else
        if (( ! HAS_CFG_OPTS )) && [[ -z "$OPT_PSK" ]]; then
            die "请通过参数指定要修改的项，例如：bash snell.sh config --port 23456 --mode unshaped"
        fi
        apply_opts
    fi
    validate_cfg

    after="$(printf '%s|' "$CFG_PORT" "$CFG_PSK" "$CFG_MODE" "$CFG_IPV6" "$CFG_DNS_PREF" "$CFG_EGRESS" "$CFG_DNS")"
    if [[ "$before" == "$after" ]]; then
        info "配置未发生变化"
        return 0
    fi

    bak="$(backup_file "$CONF_FILE" conf)" || die "备份原配置失败，已中止修改（配置未改动）"
    info "原配置已备份：${bak}"
    write_config
    if [[ "$CFG_EGRESS" != "$old_egress" ]]; then
        write_service
    fi

    # 端口或 IPv6 任一变化都要同步放行规则（iptables 后端需增删 ip6tables 规则）
    old_fw="$(meta_firewall)"
    fw="$old_fw"
    if [[ "$CFG_PORT" != "$old_port" || "$CFG_IPV6" != "$old_ipv6" ]]; then
        fw="$(fw_resync "$old_port" "$old_fw")" || die "配置防火墙放行规则失败"
        report_firewall "$fw" "$CFG_PORT"
    fi

    if service_start_verify "$CFG_PORT"; then
        save_meta "$fw"
        prune_backups
        ok "配置已更新并重启服务"
        warn "请同步修改 Surge 客户端配置（端口 / PSK / mode 需与服务端一致）"
        show_info
        return 0
    fi

    # 回滚：恢复配置文件、服务单元与防火墙规则
    error "新配置启动失败，正在恢复原配置..."
    new_port="$CFG_PORT" new_ipv6="$CFG_IPV6"
    cp -a "$bak" "$CONF_FILE"
    # 备份可能保留了旧权限；在子 shell 中执行，失败只警告，不打断后续恢复
    ( secure_conf_perms ) || warn "恢复配置文件权限失败，请手动检查 ${CONF_FILE}"
    load_config
    write_service
    if [[ "$new_port" != "$old_port" || "$new_ipv6" != "$old_ipv6" ]]; then
        fw_resync "$new_port" "$fw" >/dev/null || warn "恢复防火墙规则失败，请手动检查端口 ${old_port} 的放行规则"
    fi
    if service_start_verify "$CFG_PORT"; then
        die "已恢复原配置，服务运行正常"
    fi
    die "恢复原配置后仍无法启动，请查看日志：journalctl -u ${SERVICE_NAME} -n 100"
}

cmd_log() {
    check_root
    if (( OPT_FOLLOW )); then
        journalctl -u "$SERVICE_NAME" -f
        return 0
    fi
    journalctl -u "$SERVICE_NAME" -n "$OPT_LINES" --no-pager || true
    if (( INTERACTIVE )) && ask_yes_no "是否实时跟踪日志（Ctrl+C 退出）？" n; then
        # 捕获（而非忽略）SIGINT，使 Ctrl+C 只结束 journalctl
        trap 'true' INT
        journalctl -u "$SERVICE_NAME" -f -n 0 || true
        trap - INT
    fi
}

cmd_restart() {
    check_root
    check_systemd
    require_installed
    load_config
    info "重启 Snell 服务..."
    service_start_verify "$CFG_PORT" || die "重启失败"
    ok "服务已重启，正在监听 TCP ${CFG_PORT}"
}

cmd_status() {
    check_root
    systemctl status "$SERVICE_NAME" --no-pager || true
}

usage() {
    cat <<EOF
Snell v6 服务端管理脚本 ${SCRIPT_VERSION}（默认 Snell 版本 ${DEFAULT_SNELL_VERSION}）

用法: bash snell.sh [命令] [选项]

命令:
  (无)          进入交互式菜单
  install       安装（已有配置时默认保留，加 -y 覆盖）
  update        更新二进制（保留配置，失败自动回滚）
  uninstall     卸载
  show          查看配置与 Surge 配置行
  config        修改配置（无参数时进入交互式修改）
  log           查看日志（-f 实时跟踪，-n 行数）
  restart       重启服务
  status        systemctl 状态
  self-update   检查脚本更新，确认后更新（加 -y 免确认）

配置选项（install / config）:
  --port N|random              监听端口，默认随机 ${PORT_MIN}-${PORT_MAX}
  --psk STR|random             PSK，16-255 位，默认随机 32 位（会留在 shell 历史和进程列表中）
  --psk-file PATH              从文件第一行读取 PSK（推荐，PSK 不出现在命令行）
  --mode M                     default | unshaped | unsafe-raw（默认 default）
  --dns-ip-preference P        default | prefer-ipv4 | prefer-ipv6 | ipv4-only | ipv6-only
  --ipv6 auto|true|false       同时监听 IPv6 并允许 IPv6 出站（默认 auto）
  --egress-interface IF|none   指定出口网卡（高级）
  --dns IP[,IP]|none           自定义 DNS 服务器（高级）

其他选项:
  --snell-version V            指定 Snell 版本（默认 ${DEFAULT_SNELL_VERSION}，也可用环境变量 SNELL_VERSION）
  --name NAME                  Surge 配置行中的节点名（默认 ${OPT_NAME}）
  -y, --yes                    自动确认（覆盖配置 / 卸载 / unsafe-raw）
  -f, --follow                 log 命令实时跟踪
  -n, --lines N                log 命令显示行数（默认 100）
  -h, --help                   显示帮助

说明: 命令行中给出任意配置选项或 -y 时进入非交互模式，未给出的项使用默认值。
      脚本更新需手动运行 self-update（或菜单「检查脚本更新」），确认后才会更新。
      PSK 来源优先级：--psk > --psk-file > 环境变量 SNELL_PSK（用于 install 与非交互 config）。

示例:
  bash snell.sh install --port 12345 --psk 'YourStrongPSK_1234567890' --mode default
  bash snell.sh install -y --mode unshaped
  bash snell.sh config --port 23456
  SNELL_VERSION=v6.0.0 bash snell.sh update
EOF
}

# ------------------------------- 脚本自更新 ----------------------------------
# 校验下载的脚本完整可用：shebang、末行入口、版本常量、语法检查
script_file_valid() {
    local f="$1" first last
    [[ -s "$f" ]] || return 1
    first="$(head -n 1 "$f")"
    last="$(tail -n 1 "$f")"
    [[ "$first" == "#!/usr/bin/env bash" ]] || return 1
    [[ "$last" == 'main "$@"' ]] || return 1
    grep -q '^readonly SCRIPT_VERSION=' "$f" || return 1
    bash -n "$f" 2>/dev/null
}

# self-update：下载 → 校验 → 显示版本 → 确认（或 -y）后原子替换（保留原权限与属主）
cmd_self_update() {
    local self="${BASH_SOURCE[0]:-}" new remote staged
    if [[ -z "$self" || ! -f "$self" ]]; then
        info "当前通过管道 / 进程替换运行，内容即为 GitHub 上的最新版本"
        return 0
    fi
    command -v curl >/dev/null 2>&1 || die "缺少 curl，无法检查脚本更新"
    # 下载到 TMP_DIR：由主进程退出时统一清理（菜单子 shell 中运行也不会残留）
    ensure_tmp_dir
    new="${TMP_DIR}/snell.sh.new"
    curl -fsSL --proto '=https' --connect-timeout 5 --max-time 30 -o "$new" "$SCRIPT_URL" 2>/dev/null ||
        die "下载失败（无法访问 GitHub）：${SCRIPT_URL}"
    script_file_valid "$new" || die "下载的脚本不完整或未通过校验，已放弃更新"
    if cmp -s "$new" "$self"; then
        ok "脚本已是最新版本（${SCRIPT_VERSION}）"
        return 0
    fi

    remote="$(awk -F'"' '/^readonly SCRIPT_VERSION=/ { print $2; exit }' "$new")"
    info "当前版本：${SCRIPT_VERSION}，远程版本：${remote:-未知}"
    info "更新记录：https://github.com/zhushili/Snell/commits/main/snell.sh"
    if (( ! INTERACTIVE && ! ASSUME_YES )); then
        info "非交互模式下请加 -y 确认更新：sudo bash snell.sh self-update -y"
        return 0
    fi
    if ! ask_yes_no "是否更新脚本？" n; then
        info "已取消，继续使用当前版本 ${SCRIPT_VERSION}"
        return 0
    fi

    staged="$(mktemp "$(dirname "$self")/.snell.sh.XXXXXX")" || die "脚本所在目录不可写，无法更新"
    cp -- "$new" "$staged" || { rm -f -- "$staged"; die "写入临时文件失败，未做任何改动"; }
    chmod --reference="$self" "$staged" 2>/dev/null || chmod 755 "$staged"
    chown --reference="$self" "$staged" 2>/dev/null || true
    mv -f -- "$staged" "$self" || { rm -f -- "$staged"; die "替换脚本失败，继续使用当前版本"; }
    ok "脚本已更新：${SCRIPT_VERSION} → ${remote:-未知版本}，请重新运行脚本以使用新版本"
}

# ------------------------------- 菜单 ----------------------------------------
# 在子 shell 中执行，使 die 只结束当前操作而不退出菜单
# 注意：子 shell 不能放在 || / if 中执行，否则其内部的 set -e 会失效
run_action() {
    local rc
    trap - ERR
    set +e
    (
        set -e
        set_err_trap
        "$@"
    )
    rc=$?
    set -e
    set_err_trap
    if (( rc != 0 )); then
        warn "操作未成功完成（退出码 ${rc}）"
    fi
}

menu_status_line() {
    local st="未安装" run=""
    if is_installed; then
        st="已安装 $(installed_version)，端口 $(current_conf_port)"
        if service_active; then run="${C_GREEN}运行中${C_RESET}"; else run="${C_RED}未运行${C_RESET}"; fi
    fi
    echo "  状态: ${st} ${run}"
}

show_menu() {
    local choice
    while true; do
        echo
        echo "${C_BOLD}============ Snell v6 管理脚本 ${SCRIPT_VERSION} ============${C_RESET}"
        echo "  目标版本: ${C_YELLOW}${SNELL_VERSION}${C_RESET}（beta/RC，客户端需同步）"
        menu_status_line
        echo "----------------------------------------------------"
        echo "  1) 安装 Snell"
        echo "  2) 更新 Snell（保留配置）"
        echo "  3) 卸载 Snell"
        echo "  4) 查看配置"
        echo "  5) 修改配置"
        echo "  6) 查看日志"
        echo "  7) 重启服务"
        echo "  8) 检查脚本更新"
        echo "  0) 退出"
        echo "----------------------------------------------------"
        read -r -p "请选择 [0-8]: " choice || exit 0
        case "$choice" in
            1) run_action cmd_install ;;
            2) run_action cmd_update ;;
            3) run_action cmd_uninstall ;;
            4) run_action cmd_show ;;
            5) run_action cmd_config ;;
            6) run_action cmd_log ;;
            7) run_action cmd_restart ;;
            8) run_action cmd_self_update ;;
            0) exit 0 ;;
            *) warn "无效选择"; continue ;;
        esac
        pause
    done
}

# 对会修改系统的操作加锁，防止多个实例同时运行；系统没有 flock 时跳过加锁
acquire_lock() {
    command -v flock >/dev/null 2>&1 || return 0
    if ! { exec 9>"$LOCK_FILE"; } 2>/dev/null; then
        warn "无法创建锁文件 ${LOCK_FILE}，跳过加锁"
        return 0
    fi
    flock -n 9 || die "另一个 snell.sh 实例正在运行，请等待其结束后再试"
}

# ------------------------------- 参数解析 / 入口 -----------------------------
need_arg() {
    [[ $# -ge 2 && -n "$2" ]] || die "选项 $1 需要一个值"
}

set_command() {
    [[ -z "$COMMAND" ]] || die "只能指定一个命令（已指定 ${COMMAND}，又收到 $1）"
    COMMAND="$1"
}

parse_args() {
    while (( $# > 0 )); do
        # 支持 --opt=value 写法
        if [[ "$1" == --*=* ]]; then
            set -- "${1%%=*}" "${1#*=}" "${@:2}"
        fi
        case "$1" in
            install|i)            set_command install ;;
            update|upgrade)       set_command update ;;
            uninstall|remove)     set_command uninstall ;;
            show|info)            set_command show ;;
            config|modify)        set_command config ;;
            log|logs)             set_command log ;;
            restart)              set_command restart ;;
            status)               set_command status ;;
            self-update)          set_command self-update ;;
            menu)                 set_command menu ;;
            help)                 set_command help ;;
            --port)               need_arg "$@"; OPT_PORT="$2"; HAS_CFG_OPTS=1; shift ;;
            --psk)                need_arg "$@"; OPT_PSK="$2"; HAS_CFG_OPTS=1; shift ;;
            --psk-file)           need_arg "$@"; OPT_PSK_FILE="$2"; HAS_CFG_OPTS=1; shift ;;
            --mode)               need_arg "$@"; OPT_MODE="$2"; HAS_CFG_OPTS=1; shift ;;
            --dns-ip-preference)  need_arg "$@"; OPT_DNS_PREF="$2"; HAS_CFG_OPTS=1; shift ;;
            --ipv6)               need_arg "$@"; OPT_IPV6="$2"; HAS_CFG_OPTS=1; shift ;;
            --egress-interface)   need_arg "$@"; OPT_EGRESS="$2"; HAS_CFG_OPTS=1; shift ;;
            --dns)                need_arg "$@"; OPT_DNS="$2"; HAS_CFG_OPTS=1; shift ;;
            --bbr|--no-bbr)       # 已删除的选项：提示后忽略（仍按配置参数处理，保持原来的非交互行为）
                                  info "BBR 已移出本脚本，已忽略 $1"; HAS_CFG_OPTS=1 ;;
            --snell-version)      need_arg "$@"; SNELL_VERSION="$2"; shift ;;
            --name)               need_arg "$@"; OPT_NAME="$2"; shift ;;
            -y|--yes)             ASSUME_YES=1 ;;
            --no-update-check)    ;;   # 已删除的选项，为兼容旧脚本 / alias 静默忽略
            -f|--follow)          OPT_FOLLOW=1 ;;
            -n|--lines)           need_arg "$@"; OPT_LINES="$2"; shift ;;
            -h|--help)            usage; exit 0 ;;
            *)                    die "未知参数：$1（使用 --help 查看帮助）" ;;
        esac
        shift
    done
    [[ "$OPT_LINES" =~ ^[0-9]+$ ]] || die "--lines 需要为数字"
    [[ "$OPT_NAME" =~ ^[^,=]+$ ]] || die "--name 不能包含逗号或等号"
}

# 非 root 运行时：脚本是磁盘上的文件且有 sudo，则自动通过 sudo 重新执行
ensure_root() {
    local self="${BASH_SOURCE[0]:-}" psk_tmp=""
    if [[ "$(id -u)" -eq 0 ]]; then
        return 0
    fi
    if [[ -n "$self" && -f "$self" && -r "$self" ]] && command -v sudo >/dev/null 2>&1; then
        # sudo 会清除 SNELL_PSK；写入仅当前用户可读的临时文件转交，避免 PSK 出现在进程参数中
        if [[ -n "${SNELL_PSK:-}" ]]; then
            psk_tmp="$(umask 077 && mktemp "${TMPDIR:-/tmp}/snell-psk.XXXXXX")" || die "无法创建临时文件转交 SNELL_PSK"
            printf '%s\n' "$SNELL_PSK" >"$psk_tmp" || die "无法写入临时文件：${psk_tmp}"
        fi
        info "需要 root 权限，正在通过 sudo 重新运行..."
        exec sudo -- env SNELL_VERSION="$SNELL_VERSION" SNELL_PSK_TMPFILE="$psk_tmp" bash "$self" "$@"
    fi
    die "请使用 root 用户运行本脚本（例如：sudo bash snell.sh）"
}

main() {
    local tty_in=0
    setup_colors
    parse_args "$@"
    if [[ "$COMMAND" == "help" ]]; then
        usage
        return 0
    fi
    ensure_root "$@"
    resolve_psk_source

    # 通过管道运行（curl | bash）时标准输入不是终端，菜单改从控制终端 /dev/tty 读取
    if [[ -z "$COMMAND" || "$COMMAND" == "menu" ]] && [[ ! -t 0 ]] && { : </dev/tty; } 2>/dev/null; then
        tty_in=1
    fi

    # 无终端 / 指定了配置参数 / -y 时进入非交互模式
    if [[ ! -t 0 ]] && (( ! tty_in )); then
        INTERACTIVE=0
    fi
    if (( ASSUME_YES || HAS_CFG_OPTS )); then
        INTERACTIVE=0
    fi

    case "${COMMAND:-menu}" in
        install|update|uninstall|config|restart|self-update|menu) acquire_lock ;;
    esac

    case "${COMMAND:-menu}" in
        install|update|menu) ensure_tmp_dir ;;
    esac

    case "${COMMAND:-menu}" in
        install)   cmd_install ;;
        update)    cmd_update ;;
        uninstall) cmd_uninstall ;;
        show)      cmd_show ;;
        config)    cmd_config ;;
        log)       cmd_log ;;
        restart)   cmd_restart ;;
        status)    cmd_status ;;
        self-update) cmd_self_update ;;
        menu)
            if (( tty_in )); then
                show_menu </dev/tty
            elif [[ -t 0 ]]; then
                show_menu
            else
                usage
                die "没有可用的终端，无法显示菜单；请指定命令，例如：bash snell.sh install -y"
            fi
            ;;
    esac
}

main "$@"
