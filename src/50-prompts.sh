# shellcheck shell=bash
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
