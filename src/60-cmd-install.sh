# shellcheck shell=bash
# ------------------------------- 命令：install --------------------------------
cmd_install() {
    preflight
    is_valid_version "$SNELL_VERSION" || die "版本号格式无效或不是 v6：${SNELL_VERSION}"

    local keep_config=0 bin fw fw_added fw_out old_obfs bak old_port old_fw old_added
    old_port="$(kv_get "$META_FILE" PORT)"
    old_fw="$(meta_firewall)"
    old_added="$(meta_fw_added)"
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

    # 覆盖安装时先移除旧端口上本脚本添加的规则，再按新配置放行
    if [[ -n "$old_port" ]]; then
        fw_close "$old_port" "$old_fw" "$old_added"
    fi
    fw_out="$(fw_open "$CFG_PORT")" || die "配置防火墙放行规则失败"
    read -r fw fw_added <<<"$fw_out"
    report_firewall "$fw" "$CFG_PORT" "$fw_added"
    save_meta "$fw" "$fw_added"

    info "启动 Snell 服务..."
    service_start_verify "$CFG_PORT" || die "服务启动失败，请根据上方日志排查（配置与程序均已保留）"
    ok "Snell 服务已启动并设为开机自启"

    show_info
}
