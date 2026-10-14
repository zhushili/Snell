# shellcheck shell=bash
# ------------------------------- 命令：show / log / restart / status ----------
cmd_show() {
    check_root
    require_installed
    show_info
    echo
    info "配置文件内容（${CONF_FILE}）："
    sed 's/^/    /' "$CONF_FILE"
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
