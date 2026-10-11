# shellcheck shell=bash
# ------------------------------- 命令：config ---------------------------------
cmd_config() {
    check_root
    check_systemd
    require_installed
    load_config

    local old_port="$CFG_PORT" old_egress="$CFG_EGRESS" old_ipv6="$CFG_IPV6"
    local new_port new_ipv6 before after bak fw fw_added fw_out old_fw old_added choice ans
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
    old_added="$(meta_fw_added)"
    fw="$old_fw" fw_added="$old_added"
    if [[ "$CFG_PORT" != "$old_port" || "$CFG_IPV6" != "$old_ipv6" ]]; then
        fw_out="$(fw_resync "$old_port" "$old_fw" "$old_added")" || die "配置防火墙放行规则失败"
        read -r fw fw_added <<<"$fw_out"
        report_firewall "$fw" "$CFG_PORT" "$fw_added"
    fi

    if service_start_verify "$CFG_PORT"; then
        save_meta "$fw" "$fw_added"
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
        fw_resync "$new_port" "$fw" "$fw_added" >/dev/null || warn "恢复防火墙规则失败，请手动检查端口 ${old_port} 的放行规则"
    fi
    if service_start_verify "$CFG_PORT"; then
        die "已恢复原配置，服务运行正常"
    fi
    die "恢复原配置后仍无法启动，请查看日志：journalctl -u ${SERVICE_NAME} -n 100"
}
