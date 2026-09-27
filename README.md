# Snell v6 一键安装脚本

一键安装、更新和管理 **Snell v6 服务端**的 Linux 脚本。

> [!WARNING]
> Snell v6 仍是 beta（默认版本 `v6.0.0rc2`）。Surge 客户端需 iOS 5.20.0+ / Mac 6.7.0+，并与服务端同步更新。

## 安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/zhushili/Snell/main/snell.sh)
```

以 root 运行，进入菜单后选 `1`。普通用户或无人值守安装：

```bash
curl -fsSLo snell.sh https://raw.githubusercontent.com/zhushili/Snell/main/snell.sh && sudo bash snell.sh   # sudo 用户
curl -fsSL https://raw.githubusercontent.com/zhushili/Snell/main/snell.sh | sudo bash -s -- install -y     # 全部默认，不提问
```

> [!IMPORTANT]
> 云服务器还需在控制台**安全组**放行所用的 **TCP** 端口（无需 UDP）。

## 支持

| 系统 | Debian 11 / 12 / 13、Ubuntu 22.04 / 24.04 / 26.04、CentOS Stream / Rocky / AlmaLinux 8 / 9 |
|---|---|
| 架构 | x86_64、aarch64 |
| 要求 | systemd，root 或 sudo（缺少的依赖会自动安装） |

## 管理

运行 `sudo bash snell.sh` 打开菜单：安装、更新、卸载、查看配置、修改配置、查看日志、重启、检查脚本更新。

也可以直接用命令：

```bash
sudo bash snell.sh show                 # 查看配置和 Surge 配置行
sudo bash snell.sh config --port 23456  # 修改配置（端口 / --psk / --mode 等）
sudo bash snell.sh update               # 更新 Snell（保留配置，失败自动回滚）
sudo bash snell.sh log -f               # 实时日志
sudo bash snell.sh self-update          # 更新本脚本
bash snell.sh --help                    # 全部命令和选项
```

修改端口、PSK 或 mode 后，记得同步修改 Surge 里的配置。

## 卸载

```bash
sudo bash snell.sh uninstall
```

删除服务、程序、`/etc/snell/`（含 PSK）、备份、`snell` 用户和本脚本添加的防火墙规则。

<details>
<summary>更多说明</summary>

**mode**（服务端与客户端必须一致）

| mode | 说明 |
|---|---|
| `default` | 加密 + 流量整形，推荐 |
| `unshaped` | 仅加密，吞吐约 +10% |
| `unsafe-raw` | 明文转发，仅限内网或已有安全隧道 |

**更安全地传入 PSK**：`--psk` 会留在 shell 历史和进程列表里，建议用 `--psk-file /root/snell.psk`（读取第一行）或环境变量 `SNELL_PSK`。优先级：`--psk` > `--psk-file` > `SNELL_PSK`。

**安装的文件**：`/usr/local/bin/snell-server`、`/etc/snell/snell-server.conf`（root:snell 0640）、`/etc/systemd/system/snell.service`、`/var/backups/snell/`（每类保留最近 3 份备份）。

**进不去菜单**：非 root 且无法自动 sudo 时，改用 `sudo bash snell.sh`；没有终端时（cron、CI）请直接指定命令，如 `install -y`；出现 `$'\r': command not found` 说明文件被存成了 Windows 换行，请在服务器上重新用 `curl` 下载。

</details>

## 参考

[Snell 发布说明](https://kb.nssurge.com/surge-knowledge-base/release-notes/snell) · [Surge 手册：Snell](https://manual.nssurge.com/policies/snell.html) · 社区脚本，与 Surge 官方无关 · [MIT](LICENSE)
