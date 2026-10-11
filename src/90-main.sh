# shellcheck shell=bash
# ------------------------------- 加锁 / 参数解析 / 入口 -----------------------
# 对会修改系统的操作加锁，防止多个实例同时运行；系统没有 flock 时跳过加锁
acquire_lock() {
    command -v flock >/dev/null 2>&1 || return 0
    if ! { exec 9>"$LOCK_FILE"; } 2>/dev/null; then
        warn "无法创建锁文件 ${LOCK_FILE}，跳过加锁"
        return 0
    fi
    flock -n 9 || die "另一个 snell.sh 实例正在运行，请等待其结束后再试"
}

need_arg() {
    [[ $# -ge 2 && -n "$2" ]] || die "选项 $1 需要一个值"
}

set_command() {
    [[ -z "$COMMAND" ]] || die "只能指定一个命令（已指定 ${COMMAND}，又收到 $1）"
    COMMAND="$1"
}

parse_args() {
    while (( $# > 0 )); do
        # 支持 --opt=value 写法
        if [[ "$1" == --*=* ]]; then
            set -- "${1%%=*}" "${1#*=}" "${@:2}"
        fi
        case "$1" in
            install|i)            set_command install ;;
            update|upgrade)       set_command update ;;
            uninstall|remove)     set_command uninstall ;;
            show|info)            set_command show ;;
            config|modify)        set_command config ;;
            log|logs)             set_command log ;;
            restart)              set_command restart ;;
            status)               set_command status ;;
            self-update)          set_command self-update ;;
            menu)                 set_command menu ;;
            help)                 set_command help ;;
            --port)               need_arg "$@"; OPT_PORT="$2"; HAS_CFG_OPTS=1; shift ;;
            --psk)                need_arg "$@"; OPT_PSK="$2"; HAS_CFG_OPTS=1; shift ;;
            --psk-file)           need_arg "$@"; OPT_PSK_FILE="$2"; HAS_CFG_OPTS=1; shift ;;
            --mode)               need_arg "$@"; OPT_MODE="$2"; HAS_CFG_OPTS=1; shift ;;
            --dns-ip-preference)  need_arg "$@"; OPT_DNS_PREF="$2"; HAS_CFG_OPTS=1; shift ;;
            --ipv6)               need_arg "$@"; OPT_IPV6="$2"; HAS_CFG_OPTS=1; shift ;;
            --egress-interface)   need_arg "$@"; OPT_EGRESS="$2"; HAS_CFG_OPTS=1; shift ;;
            --dns)                need_arg "$@"; OPT_DNS="$2"; HAS_CFG_OPTS=1; shift ;;
            --bbr|--no-bbr)       # 已删除的选项：提示后忽略（仍按配置参数处理，保持原来的非交互行为）
                                  info "BBR 已移出本脚本，已忽略 $1"; HAS_CFG_OPTS=1 ;;
            --snell-version)      need_arg "$@"; SNELL_VERSION="$2"; shift ;;
            --sha256)             need_arg "$@"; OPT_SHA256="$2"; shift ;;
            --name)               need_arg "$@"; OPT_NAME="$2"; shift ;;
            -y|--yes)             ASSUME_YES=1 ;;
            --no-update-check)    ;;   # 已删除的选项，为兼容旧脚本 / alias 静默忽略
            -f|--follow)          OPT_FOLLOW=1 ;;
            -n|--lines)           need_arg "$@"; OPT_LINES="$2"; shift ;;
            -h|--help)            usage; exit 0 ;;
            *)                    die "未知参数：$1（使用 --help 查看帮助）" ;;
        esac
        shift
    done
    [[ "$OPT_LINES" =~ ^[0-9]+$ ]] || die "--lines 需要为数字"
    [[ "$OPT_NAME" =~ ^[^,=]+$ ]] || die "--name 不能包含逗号或等号"
    if [[ -n "$OPT_SHA256" && ! "$OPT_SHA256" =~ ^[0-9A-Fa-f]{64}$ ]]; then
        die "--sha256 需要为 64 位十六进制字符串"
    fi
}

# 非 root 运行时：脚本是磁盘上的文件且有 sudo，则自动通过 sudo 重新执行
ensure_root() {
    local self="${BASH_SOURCE[0]:-}" psk_tmp=""
    if [[ "$(id -u)" -eq 0 ]]; then
        return 0
    fi
    if [[ -n "$self" && -f "$self" && -r "$self" ]] && command -v sudo >/dev/null 2>&1; then
        # sudo 会清除 SNELL_PSK；写入仅当前用户可读的临时文件转交，避免 PSK 出现在进程参数中
        if [[ -n "${SNELL_PSK:-}" ]]; then
            psk_tmp="$(umask 077 && mktemp "${TMPDIR:-/tmp}/snell-psk.XXXXXX")" || die "无法创建临时文件转交 SNELL_PSK"
            printf '%s\n' "$SNELL_PSK" >"$psk_tmp" || die "无法写入临时文件：${psk_tmp}"
        fi
        info "需要 root 权限，正在通过 sudo 重新运行..."
        exec sudo -- env SNELL_VERSION="$SNELL_VERSION" SNELL_SHA256="$OPT_SHA256" SNELL_PSK_TMPFILE="$psk_tmp" bash "$self" "$@"
    fi
    die "请使用 root 用户运行本脚本（例如：sudo bash snell.sh）"
}

main() {
    local tty_in=0
    setup_colors
    parse_args "$@"
    if [[ "$COMMAND" == "help" ]]; then
        usage
        return 0
    fi
    # -y 与配置选项会切换到非交互模式，菜单无法提问，必须配合命令使用
    if [[ -z "$COMMAND" || "$COMMAND" == "menu" ]] && (( ASSUME_YES || HAS_CFG_OPTS )); then
        die "-y 和配置选项需要配合命令使用，例如：bash snell.sh install -y（使用 --help 查看全部命令）"
    fi
    ensure_root "$@"
    resolve_psk_source

    # 通过管道运行（curl | bash）时标准输入不是终端，菜单改从控制终端 /dev/tty 读取
    if [[ -z "$COMMAND" || "$COMMAND" == "menu" ]] && [[ ! -t 0 ]] && { : </dev/tty; } 2>/dev/null; then
        tty_in=1
    fi

    # 无终端 / 指定了配置参数 / -y 时进入非交互模式
    if [[ ! -t 0 ]] && (( ! tty_in )); then
        INTERACTIVE=0
    fi
    if (( ASSUME_YES || HAS_CFG_OPTS )); then
        INTERACTIVE=0
    fi

    case "${COMMAND:-menu}" in
        install|update|uninstall|config|restart|self-update|menu) acquire_lock ;;
    esac

    case "${COMMAND:-menu}" in
        install|update|menu) ensure_tmp_dir ;;
    esac

    case "${COMMAND:-menu}" in
        install)   cmd_install ;;
        update)    cmd_update ;;
        uninstall) cmd_uninstall ;;
        show)      cmd_show ;;
        config)    cmd_config ;;
        log)       cmd_log ;;
        restart)   cmd_restart ;;
        status)    cmd_status ;;
        self-update) cmd_self_update ;;
        menu)
            if (( tty_in )); then
                show_menu </dev/tty
            elif [[ -t 0 ]]; then
                show_menu
            else
                usage
                die "没有可用的终端，无法显示菜单；请指定命令，例如：bash snell.sh install -y"
            fi
            ;;
    esac
}

main "$@"
