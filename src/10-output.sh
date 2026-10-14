# shellcheck shell=bash
# ------------------------------- 输出 ----------------------------------------
setup_colors() {
    C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_BOLD="" C_RESET=""
    E_RED="" E_YELLOW="" E_RESET=""
    if [[ -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
        if [[ -t 1 ]]; then
            C_RED=$'\033[31m' C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m'
            C_BLUE=$'\033[36m' C_BOLD=$'\033[1m' C_RESET=$'\033[0m'
        fi
        if [[ -t 2 ]]; then
            E_RED=$'\033[31m' E_YELLOW=$'\033[33m' E_RESET=$'\033[0m'
        fi
    fi
}

info()  { printf '%s[信息]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()    { printf '%s[成功]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '%s[警告]%s %s\n' "$E_YELLOW" "$E_RESET" "$*" >&2; }
error() { printf '%s[错误]%s %s\n' "$E_RED" "$E_RESET" "$*" >&2; }
die()   { error "$*"; exit 1; }

on_err() {
    local line="$1" cmd="$2"
    error "脚本第 ${line} 行执行失败：${cmd}"
    error "操作已中止，未完成的步骤不会继续执行。"
}

cleanup() {
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf -- "$TMP_DIR"
    fi
}

set_err_trap() {
    trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR
}

set_err_trap
trap cleanup EXIT
