# shellcheck shell=bash
# ------------------------------- 二进制下载与校验 ----------------------------
# 校验 ELF 魔数、64 位、以及机器架构与当前系统一致
verify_elf() {
    local f="$1" magic class machine expect
    [[ -s "$f" ]] || die "文件为空：${f}"
    magic="$(od -An -tx1 -N4 "$f" | tr -d ' \n')"
    [[ "$magic" == "7f454c46" ]] || die "下载的文件不是有效的 ELF 可执行文件，已中止"
    class="$(od -An -tx1 -j4 -N1 "$f" | tr -d ' \n')"
    machine="$(od -An -tx1 -j18 -N2 "$f" | tr -d ' \n')"
    case "$ARCH" in
        amd64)   expect="3e00" ;;   # EM_X86_64
        aarch64) expect="b700" ;;   # EM_AARCH64
    esac
    if [[ "$class" != "02" || "$machine" != "$expect" ]]; then
        die "ELF 架构与本机（${ARCH}）不匹配，已中止"
    fi
}

# 内置的官方压缩包 SHA256：known_sha256 <版本> <架构>，未收录时返回非 0
# 新增版本时，用两个不同网络下载同一文件并核对哈希一致后再写入
known_sha256() {
    case "$1-$2" in
        v6.0.0rc2-amd64)   echo "8a9c4463ca87cfa5eaa37c6af0d37ab93ea275aa12391985bb2a375ca3abd7f2" ;;
        v6.0.0rc2-aarch64) echo "a0b2915cbc77dc3baf8fa069e741c20808d8a10c3a8a93e709a0a580645c3bd7" ;;
        *) return 1 ;;
    esac
}

file_sha256() {
    local f="$1" out
    if command -v sha256sum >/dev/null 2>&1; then
        out="$(sha256sum -- "$f")" || return 1
    elif command -v openssl >/dev/null 2>&1; then
        out="$(openssl dgst -sha256 -r "$f")" || return 1
    else
        return 1
    fi
    printf '%s' "${out%% *}"
}

# 校验压缩包 SHA256：优先使用 --sha256 / SNELL_SHA256，其次使用内置值；
# 不匹配时中止；两者都没有时警告并打印实际哈希，供用户自行核对
verify_sha256() {
    local f="$1" version="$2" expect actual source
    actual="$(file_sha256 "$f")" || die "无法计算 SHA256（缺少 sha256sum 与 openssl）"
    actual="$(to_lower "$actual")"
    if [[ -n "$OPT_SHA256" ]]; then
        expect="$OPT_SHA256" source="--sha256"
    elif expect="$(known_sha256 "$version" "$ARCH")"; then
        source="脚本内置"
    else
        warn "脚本未收录 ${version}（${ARCH}）的 SHA256，无法校验文件完整性"
        warn "本次下载的 SHA256：${actual}"
        warn "如需校验，请用 --sha256 指定官方或可信来源提供的哈希"
        return 0
    fi
    expect="$(to_lower "$expect")"
    if [[ "$actual" != "$expect" ]]; then
        rm -f -- "$f"
        error "期望（${source}）：${expect}"
        error "实际：            ${actual}"
        die "SHA256 校验失败，文件可能被篡改或下载不完整，已中止"
    fi
    ok "SHA256 校验通过（${source}）" >&2
}

# 下载并解压指定版本，成功后输出二进制路径
fetch_binary() {
    local version="$1" url zip dir bin
    [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] || die "内部错误：临时目录未初始化"
    url="${DOWNLOAD_BASE}/snell-server-${version}-linux-${ARCH}.zip"
    zip="${TMP_DIR}/snell-${version}.zip"
    dir="${TMP_DIR}/extract-${version}"

    info "下载 ${url}" >&2
    if ! curl -fL --proto '=https' --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 300 \
            -sS -o "$zip" "$url"; then
        die "下载失败：${url}（请检查网络，或确认版本号 ${version} 是否存在）"
    fi
    verify_sha256 "$zip" "$version"
    unzip -tq "$zip" >/dev/null 2>&1 || die "压缩包校验失败（文件可能损坏或下载不完整）"
    rm -rf -- "$dir" || die "无法清理解压目录：${dir}"
    mkdir -p "$dir" || die "无法创建解压目录：${dir}"
    unzip -oq "$zip" -d "$dir" || die "解压失败：${zip}"

    bin="$(find "$dir" -type f -name 'snell-server' -print -quit)" || die "查找解压文件失败"
    [[ -n "$bin" ]] || die "压缩包中未找到 snell-server 可执行文件"
    verify_elf "$bin"
    chmod 755 "$bin" || die "无法设置可执行权限：${bin}"
    echo "$bin"
}

# 原子替换二进制
install_binary() {
    local src="$1"
    install -m 755 -o root -g root "$src" "${BIN_PATH}.new" || die "写入 ${BIN_PATH} 失败"
    mv -f "${BIN_PATH}.new" "$BIN_PATH" || die "替换 ${BIN_PATH} 失败"
}
