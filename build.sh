#!/usr/bin/env bash
# 将 src/ 下的模块按文件名顺序合并为单文件 snell.sh（一键安装与 self-update 都依赖单文件）
#   ./build.sh          重新生成 snell.sh
#   ./build.sh --check  检查 snell.sh 是否与 src/ 一致（不一致时返回 1）
set -euo pipefail
cd "$(dirname "$0")"

build() {
    local f first=1
    for f in src/*.sh; do
        (( first )) || echo
        # 去掉每个模块首行的 shellcheck 指令；在 shebang 后插入生成说明
        awk -v first="$first" '
            FNR == 1 && $0 == "# shellcheck shell=bash" { next }
            { print }
            first && FNR == 2 && /^#!/ { print "# 此文件由 build.sh 从 src/ 下的模块生成，请修改 src/ 后运行 ./build.sh，不要直接编辑" }
        ' "$f"
        first=0
    done
}

case "${1:-}" in
    --check)
        if ! diff -u snell.sh <(build); then
            echo "snell.sh 与 src/ 不一致，请运行 ./build.sh" >&2
            exit 1
        fi
        echo "snell.sh 与 src/ 一致"
        ;;
    "")
        tmp="$(mktemp snell.sh.XXXXXX)"
        build >"$tmp"
        chmod 755 "$tmp"
        mv -f "$tmp" snell.sh
        echo "已生成 snell.sh"
        ;;
    *)
        echo "用法: ./build.sh [--check]" >&2
        exit 2
        ;;
esac
