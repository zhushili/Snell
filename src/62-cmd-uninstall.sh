# shellcheck shell=bash
# ------------------------------- 命令：uninstall ------------------------------
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

    local port fw added
    port="$(kv_get "$META_FILE" PORT)"
    fw="$(meta_firewall)"
    added="$(meta_fw_added)"
    [[ -z "$port" ]] && port="$(current_conf_port)"

    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f -- "$SERVICE_FILE"
    systemctl daemon-reload
    systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true

    if [[ -n "$port" ]]; then
        fw_close "$port" "${fw:-none}" "$added"
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
