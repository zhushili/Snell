# shellcheck shell=bash
# ------------------------------- 脚本自更新 ----------------------------------
# 校验下载的脚本完整可用：shebang、末行入口、版本常量、语法检查
script_file_valid() {
    local f="$1" first last
    [[ -s "$f" ]] || return 1
    first="$(head -n 1 "$f")"
    last="$(tail -n 1 "$f")"
    [[ "$first" == "#!/usr/bin/env bash" ]] || return 1
    [[ "$last" == 'main "$@"' ]] || return 1
    grep -q '^readonly SCRIPT_VERSION=' "$f" || return 1
    bash -n "$f" 2>/dev/null
}

# self-update：下载 → 校验 → 显示版本 → 确认（或 -y）后原子替换（保留原权限与属主）
cmd_self_update() {
    local self="${BASH_SOURCE[0]:-}" new remote staged
    if [[ -z "$self" || ! -f "$self" ]]; then
        info "当前通过管道 / 进程替换运行，内容即为 GitHub 上的最新版本"
        return 0
    fi
    command -v curl >/dev/null 2>&1 || die "缺少 curl，无法检查脚本更新"
    # 下载到 TMP_DIR：由主进程退出时统一清理（菜单子 shell 中运行也不会残留）
    ensure_tmp_dir
    new="${TMP_DIR}/snell.sh.new"
    curl -fsSL --proto '=https' --connect-timeout 5 --max-time 30 -o "$new" "$SCRIPT_URL" 2>/dev/null ||
        die "下载失败（无法访问 GitHub）：${SCRIPT_URL}"
    script_file_valid "$new" || die "下载的脚本不完整或未通过校验，已放弃更新"
    if cmp -s "$new" "$self"; then
        ok "脚本已是最新版本（${SCRIPT_VERSION}）"
        return 0
    fi

    remote="$(awk -F'"' '/^readonly SCRIPT_VERSION=/ { print $2; exit }' "$new")"
    info "当前版本：${SCRIPT_VERSION}，远程版本：${remote:-未知}"
    info "更新记录：https://github.com/zhushili/Snell/commits/main/snell.sh"
    if (( ! INTERACTIVE && ! ASSUME_YES )); then
        info "非交互模式下请加 -y 确认更新：sudo bash snell.sh self-update -y"
        return 0
    fi
    if ! ask_yes_no "是否更新脚本？" n; then
        info "已取消，继续使用当前版本 ${SCRIPT_VERSION}"
        return 0
    fi

    staged="$(mktemp "$(dirname "$self")/.snell.sh.XXXXXX")" || die "脚本所在目录不可写，无法更新"
    cp -- "$new" "$staged" || { rm -f -- "$staged"; die "写入临时文件失败，未做任何改动"; }
    chmod --reference="$self" "$staged" 2>/dev/null || chmod 755 "$staged"
    chown --reference="$self" "$staged" 2>/dev/null || true
    mv -f -- "$staged" "$self" || { rm -f -- "$staged"; die "替换脚本失败，继续使用当前版本"; }
    ok "脚本已更新：${SCRIPT_VERSION} → ${remote:-未知版本}，请重新运行脚本以使用新版本"
}
