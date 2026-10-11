# shellcheck shell=bash
# ------------------------------- 交互工具 ------------------------------------
to_lower() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# ask_yes_no <提示> <默认 y|n>；非交互模式下 --yes 视为同意，否则取默认值
ask_yes_no() {
    local prompt="$1" def="${2:-n}" ans hint
    if (( ! INTERACTIVE )); then
        if (( ASSUME_YES )) || [[ "$def" == "y" ]]; then return 0; fi
        return 1
    fi
    if [[ "$def" == "y" ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
    while true; do
        read -r -p "${prompt} ${hint}: " ans || return 1
        ans="$(to_lower "${ans:-$def}")"
        case "$ans" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *)     warn "请输入 y 或 n" ;;
        esac
    done
}

pause() {
    if (( INTERACTIVE )); then
        read -r -p "按回车键返回菜单..." _ || true
    fi
}
