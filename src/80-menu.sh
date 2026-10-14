# shellcheck shell=bash
# ------------------------------- 菜单 ----------------------------------------
# 在子 shell 中执行，使 die 只结束当前操作而不退出菜单
# 注意：子 shell 不能放在 || / if 中执行，否则其内部的 set -e 会失效
run_action() {
    local rc
    trap - ERR
    set +e
    (
        set -e
        set_err_trap
        dispatch_action "$@"
    )
    rc=$?
    set -e
    set_err_trap
    if (( rc != 0 )); then
        warn "操作未成功完成（退出码 ${rc}）"
    fi
}

menu_status_line() {
    local st="未安装" run=""
    if is_installed; then
        st="已安装 $(installed_version)，端口 $(current_conf_port)"
        if service_active; then run="${C_GREEN}运行中${C_RESET}"; else run="${C_RED}未运行${C_RESET}"; fi
    fi
    echo "  状态: ${st} ${run}"
}

show_menu() {
    local choice
    while true; do
        echo
        echo "${C_BOLD}============ Snell v6 管理脚本 ${SCRIPT_VERSION} ============${C_RESET}"
        echo "  目标版本: ${C_YELLOW}${SNELL_VERSION}${C_RESET}（beta/RC，客户端需同步）"
        menu_status_line
        echo "----------------------------------------------------"
        echo "  1) 安装 Snell"
        echo "  2) 更新 Snell（保留配置）"
        echo "  3) 卸载 Snell"
        echo "  4) 查看配置"
        echo "  5) 修改配置"
        echo "  6) 查看日志"
        echo "  7) 重启服务"
        echo "  8) 检查脚本更新"
        echo "  0) 退出"
        echo "----------------------------------------------------"
        read -r -p "请选择 [0-8]: " choice || exit 0
        case "$choice" in
            1) run_action cmd_install ;;
            2) run_action cmd_update ;;
            3) run_action cmd_uninstall ;;
            4) run_action cmd_show ;;
            5) run_action cmd_config ;;
            6) run_action cmd_log ;;
            7) run_action cmd_restart ;;
            8) run_action cmd_self_update ;;
            0) exit 0 ;;
            *) warn "无效选择"; continue ;;
        esac
        pause
    done
}
