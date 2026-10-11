# shellcheck shell=bash
#!/usr/bin/env bash
# =============================================================================
#  Snell v6 服务端一键安装 / 管理脚本
#  项目主页 : https://github.com/zhushili/Snell（MIT License）
#
#  基于版本 : Snell Server v6.0.0rc2（v6 Release Candidate 2）
#  核实日期 : 2026-09-27
#  核实来源 : https://kb.nssurge.com/surge-knowledge-base/release-notes/snell
#             https://manual.nssurge.com/policies/snell.html
#
#  重要提示 :
#    * Snell v6 目前仍处于 beta / RC 阶段，官方说明协议可能出现不兼容变更。
#    * 服务端与客户端版本必须匹配：Surge 端需 version=6，且 mode 与服务端一致；
#      需要 Surge iOS 5.20.0+ / Surge Mac 6.7.0+，并请随服务端同步更新客户端。
#    * v6 不再支持 obfs，也移除了 v5 的 QUIC Proxy Mode（UDP 走 UDP over TCP，
#      因此服务端只需放行 TCP 端口）。
#
#  支持系统 : Debian 11/12/13, Ubuntu 22.04/24.04/26.04, CentOS Stream/Rocky/Alma 8/9
#  支持架构 : x86_64 (amd64), aarch64 (arm64)
#
#  用法     : bash snell.sh                 # 交互式菜单
#             bash snell.sh install --port 12345 --psk xxx --mode default
#             bash snell.sh --help          # 查看全部命令与参数
#
#  脚本更新 : 运行 self-update（或菜单「检查脚本更新」）手动检查 GitHub 上的新版本，
#             确认后才更新；启动时不联网检查。
# =============================================================================

set -Eeuo pipefail
# 让 $(...) 内部继承 set -e（bash >= 4.4）；旧 bash 不支持时忽略，关键步骤另有显式错误处理
shopt -s inherit_errexit 2>/dev/null || true
umask 022

# ------------------------------- 常量 ----------------------------------------
readonly SCRIPT_VERSION="6.0.0"
readonly SCRIPT_URL="https://raw.githubusercontent.com/zhushili/Snell/main/snell.sh"
readonly DEFAULT_SNELL_VERSION="v6.0.0rc2"
readonly DOWNLOAD_BASE="https://dl.nssurge.com/snell"
readonly RELEASE_NOTES_URL="https://kb.nssurge.com/surge-knowledge-base/release-notes/snell"

readonly BIN_PATH="/usr/local/bin/snell-server"
readonly CONF_DIR="/etc/snell"
readonly CONF_FILE="${CONF_DIR}/snell-server.conf"
readonly META_FILE="${CONF_DIR}/.install-meta"
readonly BACKUP_DIR="/var/backups/snell"
readonly SERVICE_NAME="snell"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
readonly SNELL_USER="snell"
# 旧版本脚本开启 BBR 时写入的文件（BBR 已移出本脚本，仅卸载时询问是否清理）
readonly BBR_SYSCTL_FILE="/etc/sysctl.d/99-snell-bbr.conf"
readonly BBR_MODULE_FILE="/etc/modules-load.d/snell-bbr.conf"
readonly FW_COMMENT="snell-server"
readonly LOCK_FILE="/run/snell-sh.lock"
readonly PORT_MIN=10000
readonly PORT_MAX=60000
readonly KEEP_BACKUPS=3

# ------------------------------- 运行时变量 ----------------------------------
SNELL_VERSION="${SNELL_VERSION:-$DEFAULT_SNELL_VERSION}"
ARCH=""
PKG_MGR=""
TMP_DIR=""
INTERACTIVE=1

# 命令行参数
COMMAND=""
OPT_PORT=""
OPT_PSK=""
OPT_PSK_FILE=""
OPT_MODE=""
OPT_DNS_PREF=""
OPT_IPV6=""
OPT_EGRESS=""
OPT_DNS=""
OPT_SHA256="${SNELL_SHA256:-}"
OPT_NAME="Snell-v6"
OPT_FOLLOW=0
OPT_LINES=100
ASSUME_YES=0
HAS_CFG_OPTS=0

# 当前配置（由 load_config 或用户输入填充）
CFG_PORT=""
CFG_PSK=""
CFG_MODE="default"
CFG_DNS_PREF="default"
CFG_IPV6="false"
CFG_EGRESS=""
CFG_DNS=""
