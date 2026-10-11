# shellcheck shell=bash
# ------------------------------- 帮助 -----------------------------------------
usage() {
    cat <<EOF
Snell v6 服务端管理脚本 ${SCRIPT_VERSION}（默认 Snell 版本 ${DEFAULT_SNELL_VERSION}）

用法: bash snell.sh [命令] [选项]

命令:
  (无)          进入交互式菜单
  install       安装（已有配置时默认保留，加 -y 覆盖）
  update        更新二进制（保留配置，失败自动回滚）
  uninstall     卸载
  show          查看配置与 Surge 配置行
  config        修改配置（无参数时进入交互式修改）
  log           查看日志（-f 实时跟踪，-n 行数）
  restart       重启服务
  status        systemctl 状态
  self-update   检查脚本更新，确认后更新（加 -y 免确认）

配置选项（install / config）:
  --port N|random              监听端口，默认随机 ${PORT_MIN}-${PORT_MAX}
  --psk STR|random             PSK，16-255 位，默认随机 32 位（会留在 shell 历史和进程列表中）
  --psk-file PATH              从文件第一行读取 PSK（推荐，PSK 不出现在命令行）
  --mode M                     default | unshaped | unsafe-raw（默认 default）
  --dns-ip-preference P        default | prefer-ipv4 | prefer-ipv6 | ipv4-only | ipv6-only
  --ipv6 auto|true|false       同时监听 IPv6 并允许 IPv6 出站（默认 auto）
  --egress-interface IF|none   指定出口网卡（高级）
  --dns IP[,IP]|none           自定义 DNS 服务器（高级）

其他选项:
  --snell-version V            指定 Snell 版本（默认 ${DEFAULT_SNELL_VERSION}，也可用环境变量 SNELL_VERSION）
  --sha256 HEX                 校验下载压缩包的 SHA256（也可用环境变量 SNELL_SHA256；
                               未指定时使用脚本内置值，未收录的版本只警告）
  --name NAME                  Surge 配置行中的节点名（默认 ${OPT_NAME}）
  -y, --yes                    自动确认（覆盖配置 / 卸载 / unsafe-raw）
  -f, --follow                 log 命令实时跟踪
  -n, --lines N                log 命令显示行数（默认 100）
  -h, --help                   显示帮助

说明: 命令行中给出任意配置选项或 -y 时进入非交互模式，未给出的项使用默认值。
      脚本更新需手动运行 self-update（或菜单「检查脚本更新」），确认后才会更新。
      PSK 来源优先级：--psk > --psk-file > 环境变量 SNELL_PSK（用于 install 与非交互 config）。

示例:
  bash snell.sh install --port 12345 --psk 'YourStrongPSK_1234567890' --mode default
  bash snell.sh install -y --mode unshaped
  bash snell.sh config --port 23456
  SNELL_VERSION=v6.0.0 bash snell.sh update
EOF
}
