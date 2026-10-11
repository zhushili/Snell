# shellcheck shell=bash
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
