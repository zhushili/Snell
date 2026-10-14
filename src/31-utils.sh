# shellcheck shell=bash
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

# 两个文件内容是否相同：优先用 cmp（diffutils），没有时比较 SHA256
files_equal() {
    if command -v cmp >/dev/null 2>&1; then
        cmp -s -- "$1" "$2"
    else
        local a b
        a="$(file_sha256 "$1")" || return 1
        b="$(file_sha256 "$2")" || return 1
        [[ "$a" == "$b" ]]
    fi
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
