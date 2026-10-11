# shellcheck shell=bash
# ------------------------------- 防火墙 --------------------------------------
# ipt_chain_restrictive <iptables|ip6tables>：INPUT 链是否含默认拒绝或 DROP/REJECT 规则
ipt_chain_restrictive() {
    local bin="$1" rules
    command -v "$bin" >/dev/null 2>&1 || return 1
    rules="$("$bin" -S INPUT 2>/dev/null)" || return 1
    [[ "$rules" == *"-P INPUT DROP"* || "$rules" == *"-j DROP"* || "$rules" == *"-j REJECT"* ]]
}

# IPv4 或 IPv6 任一方向有限制性规则即视为需要放行
iptables_restrictive() {
    ipt_chain_restrictive iptables || ipt_chain_restrictive ip6tables
}

detect_firewall() {
    local st
    if command -v ufw >/dev/null 2>&1; then
        st="$(ufw status 2>/dev/null || true)"
        if [[ "$st" == *"Status: active"* ]]; then echo "ufw"; return; fi
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        echo "firewalld"; return
    fi
    if iptables_restrictive; then
        echo "iptables"; return
    fi
    echo "none"
}

# 安装记录中的防火墙后端；旧版 meta 缺少该字段时改用当前检测结果
meta_firewall() {
    local fw
    fw="$(kv_get "$META_FILE" FIREWALL)"
    if [[ -z "$fw" ]]; then
        fw="$(detect_firewall)"
    fi
    echo "$fw"
}

# 安装记录中本脚本新增的放行规则；旧版 meta 没有该字段时输出 ?（未知）
meta_fw_added() {
    local added
    added="$(kv_get "$META_FILE" FW_ADDED)"
    echo "${added:-?}"
}

# 仅支持 netfilter-persistent 持久化；没有时提示规则重启后会丢失
iptables_persist() {
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 || warn "netfilter-persistent 保存规则失败"
    else
        warn "iptables 规则未持久化，重启后会丢失（可安装 iptables-persistent 以自动保存）"
    fi
}

# 输出放行规则在 INPUT 链中的插入位置（规则序号）：第一条"兜底"拒绝规则
# （不限来源、端口的 DROP / REJECT）之前；没有兜底规则时输出空，表示追加到链尾。
# 这样放行规则排在用户的封禁规则（按 IP 拒绝、fail2ban 等）之后，不会绕过它们
ipt_insert_pos() {
    local bin="$1" line n=0
    local re='^-A INPUT( -p (tcp|all))? -j (DROP|REJECT)( --reject-with [a-z0-9-]+)?$'
    while IFS= read -r line; do
        [[ "$line" == "-A INPUT "* ]] || continue
        n=$((n + 1))
        if [[ "$line" =~ $re ]]; then
            echo "$n"
            return 0
        fi
    done < <("$bin" -S INPUT 2>/dev/null)
}

# ipt_rule add|del <端口> <iptables|ip6tables>
# 规则带 snell-server 注释，删除时只会匹配本脚本添加的规则
ipt_rule() {
    local action="$1" port="$2" bin="$3" pos
    command -v "$bin" >/dev/null 2>&1 || return 0
    local -a rule=(-p tcp --dport "$port" -m comment --comment "$FW_COMMENT" -j ACCEPT)
    if [[ "$action" == "add" ]]; then
        "$bin" -C INPUT "${rule[@]}" 2>/dev/null && return 0
        pos="$(ipt_insert_pos "$bin")"
        if [[ -n "$pos" ]]; then
            "$bin" -I INPUT "$pos" "${rule[@]}"
        else
            "$bin" -A INPUT "${rule[@]}"
        fi
    else
        while "$bin" -C INPUT "${rule[@]}" 2>/dev/null; do "$bin" -D INPUT "${rule[@]}"; done
    fi
}

# ufw 中是否已有放行该端口 TCP 的规则（含不限协议的规则）
ufw_has_rule() {
    local port="$1"
    ufw show added 2>/dev/null | grep -Eq "^ufw allow ${port}(/tcp)?( |\$)"
}

# ufw 中是否有本脚本添加（带 snell-server 注释）的规则
ufw_has_own_rule() {
    local port="$1"
    ufw show added 2>/dev/null | grep -Fxq "ufw allow ${port}/tcp comment '${FW_COMMENT}'"
}

# 放行端口，输出"<防火墙后端> <本脚本新增的规则>"，例如 "ufw rule"、"firewalld runtime,permanent"。
# 端口原本就已放行时不重复添加，新增部分记为 -；卸载 / 改端口时只移除新增的部分
fw_open() {
    local port="$1" fw added="-" fd=""
    fw="$(detect_firewall)"
    case "$fw" in
        ufw)
            if ufw_has_rule "$port"; then
                # 本脚本之前加的规则仍算作自己的；用户原有的规则保持不动
                ufw_has_own_rule "$port" && added="rule"
            elif ufw allow "${port}/tcp" comment "$FW_COMMENT" >/dev/null; then
                added="rule"
            else
                warn "ufw 放行端口失败"
            fi
            ;;
        firewalld)
            # 运行时与永久配置分别添加，不执行 --reload（reload 会丢弃用户的运行时规则）
            if ! firewall-cmd --query-port="${port}/tcp" >/dev/null 2>&1; then
                if firewall-cmd --add-port="${port}/tcp" >/dev/null; then
                    fd="runtime"
                else
                    warn "firewalld 放行端口（运行时）失败"
                fi
            fi
            if ! firewall-cmd --permanent --query-port="${port}/tcp" >/dev/null 2>&1; then
                if firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null; then
                    fd="${fd:+${fd},}permanent"
                else
                    warn "firewalld 放行端口（永久）失败"
                fi
            fi
            added="${fd:--}"
            ;;
        iptables)
            # 只在对应 INPUT 链已有 DROP/REJECT（含默认 DROP）时才添加放行规则
            if ipt_chain_restrictive iptables; then
                ipt_rule add "$port" iptables || warn "iptables 放行端口失败"
            fi
            if [[ "$CFG_IPV6" == "true" ]] && ipt_chain_restrictive ip6tables; then
                ipt_rule add "$port" ip6tables || warn "ip6tables 放行端口失败"
            fi
            iptables_persist
            added="rule"
            ;;
        none) ;;
    esac
    echo "$fw $added"
}

# fw_close <端口> <防火墙后端> <本脚本新增的规则>：只移除本脚本添加的放行规则（提示输出到 stderr）
fw_close() {
    local port="$1" fw="$2" added="${3:-?}"
    [[ -z "$port" ]] && return 0
    case "$fw" in
        ufw)
            # 旧版本安装未记录时，按注释识别是否为本脚本添加
            if [[ "$added" == "?" ]] && ufw_has_own_rule "$port"; then
                added="rule"
            fi
            if [[ "$added" == *rule* ]]; then
                ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
                info "已移除 ufw 中 TCP ${port} 的放行规则" >&2
            elif ufw_has_rule "$port"; then
                info "ufw 中 TCP ${port} 的放行规则不是本脚本添加的，已保留" >&2
            fi
            ;;
        firewalld)
            if [[ "$added" == "?" ]]; then
                if firewall-cmd --permanent --query-port="${port}/tcp" >/dev/null 2>&1; then
                    warn "无法确认 firewalld 中 TCP ${port} 的放行规则是否由本脚本添加，已保留；如不再需要请手动移除："
                    warn "  firewall-cmd --remove-port=${port}/tcp && firewall-cmd --permanent --remove-port=${port}/tcp"
                fi
                return 0
            fi
            if [[ "$added" == *runtime* ]]; then
                firewall-cmd --remove-port="${port}/tcp" >/dev/null 2>&1 || true
            fi
            if [[ "$added" == *permanent* ]]; then
                firewall-cmd --permanent --remove-port="${port}/tcp" >/dev/null 2>&1 || true
            fi
            if [[ "$added" == "-" ]]; then
                info "firewalld 中 TCP ${port} 的放行规则不是本脚本添加的，已保留" >&2
            else
                info "已移除 firewalld 中 TCP ${port} 的放行规则" >&2
            fi
            ;;
        iptables)
            ipt_rule del "$port" iptables || true
            ipt_rule del "$port" ip6tables || true
            iptables_persist
            info "已移除 iptables 中 TCP ${port} 的放行规则" >&2
            ;;
        *) ;;
    esac
    return 0
}

# 按当前 CFG_PORT / CFG_IPV6 重新同步放行规则：先移除旧端口上本脚本添加的规则（含 ip6tables），
# 再按当前配置放行；输出同 fw_open
fw_resync() {
    local old_port="$1" old_fw="$2" old_added="$3"
    fw_close "$old_port" "$old_fw" "$old_added"
    fw_open "$CFG_PORT"
}

report_firewall() {
    local fw="$1" port="$2" added="${3:-}"
    case "$fw" in
        none) info "未检测到启用中的 ufw / firewalld / 限制性 iptables 规则，无需放行" ;;
        *)
            if [[ "$added" == "-" ]]; then
                ok "${fw} 中已有 TCP 端口 ${port} 的放行规则，沿用原有规则"
            else
                ok "已通过 ${fw} 放行 TCP 端口 ${port}"
            fi
            ;;
    esac
    warn "如使用云服务器，请同时在云厂商控制台的安全组中放行 TCP ${port}"
}
