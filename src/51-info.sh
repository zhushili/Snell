# shellcheck shell=bash
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
