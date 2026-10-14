# shellcheck shell=bash
# ------------------------------- 命令：update ---------------------------------
# 目标版本是脚本内置的默认版本时，提示官方可能已发布更新的版本
hint_newer_version() {
    [[ "$SNELL_VERSION" == "$DEFAULT_SNELL_VERSION" ]] || return 0
    info "目标版本为本脚本内置的默认版本 ${DEFAULT_SNELL_VERSION}，官方可能已发布更新的版本"
    info "请查看发布说明：${RELEASE_NOTES_URL}"
    info "如需更新到其他版本：bash snell.sh update --snell-version <版本号>（例如 v6.0.0）"
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
    hint_newer_version
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
    if [[ -n "$bak_svc" ]] && ! files_equal "$bak_svc" "$SERVICE_FILE"; then
        info "systemd 服务文件已按新版本重新生成（旧文件已备份：${bak_svc}）"
    fi

    if service_start_verify "$CFG_PORT"; then
        fw="$(meta_firewall)"
        save_meta "$fw" "$(meta_fw_added)"
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
