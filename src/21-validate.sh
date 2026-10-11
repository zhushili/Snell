# shellcheck shell=bash
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
