# shellcheck shell=bash
# ------------------------------- 用户 / 配置 / 服务 --------------------------
ensure_user() {
    if id -u "$SNELL_USER" >/dev/null 2>&1; then
        return 0
    fi
    local nologin
    nologin="$(command -v nologin || echo /usr/sbin/nologin)"
    useradd --system --user-group --no-create-home --home-dir /nonexistent \
        --shell "$nologin" "$SNELL_USER" || die "创建系统用户 ${SNELL_USER} 失败"
    info "已创建低权限系统用户：${SNELL_USER}"
}

load_config() {
    local listen first ipv6
    listen="$(kv_get "$CONF_FILE" listen)"
    first="${listen%%,*}"
    CFG_PORT="${first##*:}"
    CFG_PSK="$(kv_get "$CONF_FILE" psk)"
    CFG_MODE="$(kv_get "$CONF_FILE" mode)"
    CFG_MODE="${CFG_MODE:-default}"
    CFG_DNS_PREF="$(kv_get "$CONF_FILE" dns-ip-preference)"
    CFG_DNS_PREF="${CFG_DNS_PREF:-default}"
    CFG_EGRESS="$(kv_get "$CONF_FILE" egress-interface)"
    CFG_DNS="$(kv_get "$CONF_FILE" dns)"
    ipv6="$(kv_get "$CONF_FILE" ipv6)"
    if [[ -n "$ipv6" ]]; then
        CFG_IPV6="$ipv6"
    elif [[ "$listen" == *"::"* ]]; then
        CFG_IPV6="true"
    else
        CFG_IPV6="false"
    fi
}

build_listen() {
    if [[ "$CFG_IPV6" == "true" ]]; then
        echo "0.0.0.0:${CFG_PORT},[::]:${CFG_PORT}"
    else
        echo "0.0.0.0:${CFG_PORT}"
    fi
}

# 配置目录 root:snell 0750、配置文件 root:snell 0640：服务进程只能读、不能改
# 并实际以 snell 用户确认可读（没有 runuser 时跳过这一步验证）
secure_conf_perms() {
    chown root:"$SNELL_USER" "$CONF_DIR" || die "设置 ${CONF_DIR} 属主失败"
    chmod 750 "$CONF_DIR" || die "设置 ${CONF_DIR} 权限失败"
    [[ -f "$CONF_FILE" ]] || return 0
    chown root:"$SNELL_USER" "$CONF_FILE" || die "设置 ${CONF_FILE} 属主失败"
    chmod 640 "$CONF_FILE" || die "设置 ${CONF_FILE} 权限失败"
    if command -v runuser >/dev/null 2>&1; then
        runuser -u "$SNELL_USER" -- test -r "$CONF_FILE" ||
            die "${SNELL_USER} 用户无法读取 ${CONF_FILE}，服务将无法启动，请检查目录权限"
    fi
}

# 写入配置文件（先写临时文件再原子替换），属主 root:snell，权限 0640
write_config() {
    local tmp
    mkdir -p "$CONF_DIR"
    chown root:"$SNELL_USER" "$CONF_DIR"
    chmod 750 "$CONF_DIR"
    tmp="$(mktemp "${CONF_DIR}/.snell-server.conf.XXXXXX")"
    {
        echo "[snell-server]"
        echo "listen = $(build_listen)"
        echo "psk = ${CFG_PSK}"
        echo "mode = ${CFG_MODE}"
        echo "ipv6 = ${CFG_IPV6}"
        echo "dns-ip-preference = ${CFG_DNS_PREF}"
        if [[ -n "$CFG_EGRESS" ]]; then echo "egress-interface = ${CFG_EGRESS}"; fi
        if [[ -n "$CFG_DNS" ]]; then echo "dns = ${CFG_DNS}"; fi
    } >"$tmp"
    chown root:"$SNELL_USER" "$tmp" || die "设置配置文件属主失败"
    chmod 640 "$tmp" || die "设置配置文件权限失败"
    mv -f "$tmp" "$CONF_FILE" || die "写入 ${CONF_FILE} 失败"
    secure_conf_perms
}

write_service() {
    local caps="CAP_NET_BIND_SERVICE"
    # egress-interface 需要 CAP_NET_RAW / CAP_NET_ADMIN（官方 v5 说明）
    if [[ -n "$CFG_EGRESS" ]]; then
        caps="CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_NET_ADMIN"
    fi
    cat >"$SERVICE_FILE" <<EOF
# 由 snell.sh ${SCRIPT_VERSION} 生成
[Unit]
Description=Snell Proxy Server (v6)
Documentation=${RELEASE_NOTES_URL}
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=${SNELL_USER}
Group=${SNELL_USER}
ExecStart=${BIN_PATH} -c ${CONF_FILE}
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
AmbientCapabilities=${caps}
CapabilityBoundingSet=${caps}
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
ProtectClock=true
ProtectHostname=true
ProtectKernelLogs=true
SystemCallArchitectures=native
UMask=0077
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
StandardOutput=journal
StandardError=journal
SyslogIdentifier=snell

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$SERVICE_FILE"
    systemctl daemon-reload
}

# 重启服务并确认：进程存活且端口在监听；失败时打印日志并返回非 0
service_start_verify() {
    local port="$1" i
    systemctl daemon-reload
    systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || true
    for (( i = 0; i < 10; i++ )); do
        sleep 1
        if service_active && port_in_use "$port"; then
            sleep 1
            service_active && return 0
        fi
    done
    error "Snell 服务启动失败，最近日志如下："
    journalctl -u "$SERVICE_NAME" -n 30 --no-pager >&2 || true
    if [[ "$CFG_IPV6" == "true" ]]; then
        warn "若日志提示地址占用 / IPv6 相关错误，可尝试：bash snell.sh config --ipv6 false"
    fi
    return 1
}

# save_meta <防火墙后端> <本脚本新增的放行规则，见 fw_open>
save_meta() {
    local fw="$1" added="${2:--}"
    mkdir -p "$CONF_DIR"
    {
        echo "VERSION=${SNELL_VERSION}"
        echo "PORT=${CFG_PORT}"
        echo "FIREWALL=${fw}"
        echo "FW_ADDED=${added}"
        echo "SCRIPT_VERSION=${SCRIPT_VERSION}"
        echo "UPDATED_AT=$(date '+%F %T')"
    } >"$META_FILE"
    chown root:root "$META_FILE"
    chmod 600 "$META_FILE"
}

# 备份文件并输出备份路径；任何一步失败或备份为空都返回非 0（调用方须检查）
backup_file() {
    local src="$1" prefix="$2" ts dest
    ts="$(date +%Y%m%d-%H%M%S)" || return 1
    dest="${BACKUP_DIR}/${prefix}-${ts}"
    mkdir -p "$BACKUP_DIR" || return 1
    chmod 700 "$BACKUP_DIR" || return 1
    cp -a -- "$src" "$dest" || return 1
    [[ -s "$dest" ]] || return 1
    echo "$dest"
}

# 每类备份仅保留最近 KEEP_BACKUPS 份
prune_backups() {
    local prefix files i n
    for prefix in bin conf svc; do
        shopt -s nullglob
        files=("${BACKUP_DIR}/${prefix}-"*)
        shopt -u nullglob
        n=${#files[@]}
        for (( i = 0; i < n - KEEP_BACKUPS; i++ )); do
            rm -f -- "${files[$i]}"
        done
    done
}
