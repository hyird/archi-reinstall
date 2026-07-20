# Arch Linux 网络重装脚本

`archi.sh` 可将使用 GRUB 2 的 x86_64 云主机或物理机，通过网络重装为最小化 Arch Linux。

脚本先把 Alpine 官方 virt 内核和 initramfs 写入 GRUB 的一次性启动项；重启进入临时 Alpine 环境后，再使用 `pacstrap` 从 Arch 官方仓库或指定镜像安装系统。整个过程不使用预制系统镜像，也不需要自行编译 initrd。

> [!CAUTION]
> 安装会清空自动探测或 `--disk` 指定的整块磁盘。请先使用 `--dry-run` 检查配置，并确保 SSH 公钥和目标磁盘正确。

## 快速开始

赋予脚本执行权限：

```bash
chmod +x archi.sh
```

先检查安装计划，不修改系统：

```bash
sudo ./archi.sh \
  --dry-run \
  --authorized-key-file /root/.ssh/authorized_keys \
  --disk /dev/vda
```

确认无误后开始重装。脚本完成 staging 后会立即重启：

```bash
sudo ./archi.sh \
  --authorized-key-file /root/.ssh/authorized_keys \
  --disk /dev/vda
```

也可以直接传入公钥或从 URL 下载：

```bash
sudo ./archi.sh \
  --authorized-keys-url https://github.com/USERNAME.keys \
  --disk /dev/vda
```

如果 staging 完成后不想立即重启，添加 `--no-reboot`，准备好后再手动执行 `reboot`。

## 默认配置

| 项目 | 默认值 |
|---|---|
| 主机名 | `arch` |
| 时区 | `UTC` |
| 内核 | `linux-lts` |
| 文件系统 | GPT + ext4 |
| 网络 | 继承当前 IPv4、网关、DNS 和 MAC；信息不完整时使用 DHCP |
| 网卡命名 | `eth0` 风格 |
| SSH | root 公钥登录，端口 `22`，禁用密码登录 |
| Swap | 不创建 |
| Firmware | 不安装 `linux-firmware` |
| QEMU Guest Agent | 安装并启用 |
| 安装完成后 | 重启 |

最终系统使用 `systemd-networkd`、`systemd-resolved` 和 `systemd-timesyncd`。

## 支持范围

| 环境 | 支持情况 | 说明 |
|---|---|---|
| KVM / QEMU / 物理机 | 支持 | BIOS 或 UEFI，单块整盘安装 |
| 常见 VPS | 支持 | 需要 GRUB 2 和有线 IPv4 网络 |
| 多磁盘主机 | 有限制 | 必须使用 `--disk` 明确指定目标盘 |
| 容器 | 不支持 | 无法通过 GRUB 启动安装环境 |
| ARM | 不支持 | 当前仅支持 x86_64 |
| LVM / RAID / 加密根分区 | 不支持 | 当前仅支持 GPT + ext4 |

要求至少 8 GiB 磁盘；临时安装环境建议至少 512 MiB 内存。staging 主机需要 Bash、curl、cpio、gzip、GRUB 工具以及常见磁盘和网络命令。

## 地区预设

预设会同时设置 Alpine 镜像、Arch 镜像、DNS 和 NTP：

| 选项 | 镜像 | DNS / NTP | 适用场景 |
|---|---|---|---|
| 默认 | Alpine 官方 + Arch Geo Mirror | 自动探测 DNS + Cloudflare NTP | 全球 |
| `--cloudflare` | 官方镜像 | Cloudflare | 全球 |
| `--tuna` | 清华 TUNA | DNSPod + 中国区 NTP | 中国大陆 |
| `--ustc` / `--china` | 中科大 USTC | DNSPod + 中国区 NTP | 中国大陆 |
| `--aliyun` | 阿里云 | AliDNS + 中国区 NTP | 中国大陆 |

示例：

```bash
sudo ./archi.sh \
  --tuna \
  --timezone Asia/Shanghai \
  --authorized-key-file /root/.ssh/authorized_keys \
  --disk /dev/vda
```

也可以分别使用 `--alpine-mirror URL` 和 `--package-mirror URL` 指定镜像。Arch 镜像地址需要包含字面量 `$repo/os/$arch`。

## 完整选项

### 系统与 SSH

| 选项 | 默认值 | 说明 |
|---|---|---|
| `--hostname NAME` | `arch` | 最终系统主机名 |
| `--timezone ZONE` | `UTC` | 最终系统时区 |
| `--authorized-key "KEY"` | — | 直接传入 root SSH 公钥 |
| `--authorized-key-file FILE` | 自动检查当前用户 | 从文件读取 root SSH 公钥 |
| `--authorized-keys-url URL` | — | staging 时下载 root SSH 公钥 |
| `--ssh-port PORT` | `22` | Alpine 临时环境和最终系统的 SSH 端口 |
| `--bbr` | 关闭 | 启用 fq + TCP BBR |
| `--fail2ban` | 关闭 | 安装并启用基于 nftables 的 SSH jail |

必须提供有效 SSH 公钥；如果 `/root/.ssh/authorized_keys` 存在，脚本会自动使用。

### 网络

| 选项 | 默认值 | 说明 |
|---|---|---|
| `--interface DEVICE` | 默认路由网卡 | 指定来源网卡 |
| `--ip ADDRESS/CIDR` | 继承当前配置 | 指定静态 IPv4 地址 |
| `--netmask MASK` | 自动 | 当 `--ip` 不含 CIDR 时指定子网掩码 |
| `--gateway ADDRESS` | 继承当前配置 | 指定 IPv4 网关 |
| `--dns "ADDR ..."` | 自动探测 | 指定 DNS 服务器 |
| `--ntp HOST` | `time.cloudflare.com` | 指定 NTP 服务器 |
| `--ethx` | 开启 | 使用 `eth0` 风格网卡名 |
| `--predictable-names` | 关闭 | 保留 systemd 可预测网卡名 |

### 磁盘与启动

| 选项 | 默认值 | 说明 |
|---|---|---|
| `--disk DEVICE` | 自动探测 | 指定要清空的整块磁盘 |
| `--swap-mib N` | `0` | 创建 N MiB swap 文件，`0` 表示禁用 |
| `--boot-mode MODE` | `auto` | `auto`、`bios` 或 `efi` |
| `--bios` / `--efi` | 自动检测 | 强制使用 BIOS 或 UEFI |
| `--grub-timeout N` | `5` | 最终系统 GRUB 等待秒数 |
| `--install-dir DIR` | `/boot/archi-reinstall` | staging 文件目录 |

### 内核与软件包

| 选项 | 默认值 | 说明 |
|---|---|---|
| `--kernel PACKAGE` | `linux-lts` | 可选 `linux` 或 `linux-lts` |
| `--cloud-kernel` | 已启用 | 恢复 `linux-lts` 且不安装 firmware |
| `--firmware` | 关闭 | 安装 `linux-firmware` |
| `--install "PKG ..."` | — | 安装额外的 Arch 官方仓库软件包 |
| `--extra-packages "PKG ..."` | — | `--install` 的同义选项 |

### 安装流程

| 选项 | 说明 |
|---|---|
| `--dry-run` | 验证配置并输出计划，不修改文件 |
| `--no-reboot` | 完成 staging 后等待手动重启 |
| `--hold` | 启动 Alpine 并开放 SSH，但不擦盘 |
| `--power-off` | 安装成功后关机 |
| `--force-low-memory` | 允许在低于 384 MiB 内存时 staging |
| `--cleanup` | 重启前撤销 staging |
| `--help` | 查看脚本内置帮助 |

## 常用示例

安装主线内核、firmware 和额外软件包：

```bash
sudo ./archi.sh \
  --kernel linux \
  --firmware \
  --install "git htop tmux" \
  --authorized-key-file /root/.ssh/authorized_keys \
  --disk /dev/nvme0n1
```

手动指定静态网络：

```bash
sudo ./archi.sh \
  --ip 192.0.2.10/24 \
  --gateway 192.0.2.1 \
  --dns "1.1.1.1 1.0.0.1" \
  --authorized-key-file /root/.ssh/authorized_keys \
  --disk /dev/vda
```

启用 BBR、Fail2ban，并修改 SSH 端口：

```bash
sudo ./archi.sh \
  --bbr \
  --fail2ban \
  --ssh-port 2222 \
  --authorized-key-file /root/.ssh/authorized_keys \
  --disk /dev/vda
```

## 查看安装进度

重启进入 Alpine 后，脚本会恢复网络并启动仅允许公钥登录的 SSH。临时环境主机名为 `alpine`：

```bash
ssh -p 22 root@SERVER_IP
tail -f /tmp/archi-install.log
```

如果使用 `--hold`，Alpine 只验证安装计划并保持在线，不会擦盘。确认无误后执行：

```bash
ARCHI_FORCE_INSTALL=1 /root/archi.sh
```

安装失败时不会自动重启，可以继续通过 SSH 排查。安装成功后，日志会复制到最终系统的 `/root/archi-install.log`。

## 撤销 staging

只要尚未重启进入 Alpine，就可以移除临时 GRUB 启动项和下载文件：

```bash
sudo ./archi.sh --cleanup
```

## 工作原理

1. 检查主机架构、内存、目标磁盘、网络、SSH 公钥和软件源。
2. 下载 Alpine 官方 `vmlinuz-virt` 与 `initramfs-virt`，生成只包含配置、公钥和当前脚本的 overlay。
3. 创建一次性 GRUB 启动项，并把 payload 的 SHA-256 写入内核参数。
4. 重启进入 Alpine，下载官方 `modloop-virt` 和 APK，启动 SSH 后校验并执行脚本。
5. 清空目标磁盘，创建 GPT 分区，通过 `pacstrap` 安装 Arch Linux。
6. 写入网络、SSH、时区和 GRUB 配置，卸载文件系统后重启进入新系统。

下载内容均来自所选 Alpine 或 Arch 镜像，安装流程由脚本独立完成。

## 故障排查

**无法自动识别目标磁盘**

```bash
lsblk
sudo ./archi.sh --disk /dev/vda ...
```

**当前网络配置无法完整继承**

使用 `--ip`、`--gateway`、`--dns` 和 `--interface` 明确指定网络；否则脚本会回退到 DHCP。

**内存低于 384 MiB**

可以使用 `--force-low-memory` 跳过检查，但安装过程仍可能因内存不足失败。

**需要检查所有可用参数**

```bash
./archi.sh --help
```

## 已知限制

- 不支持多磁盘布局、LVM、RAID、加密根分区或无线网络。
- 额外软件包必须存在于所选 Arch 官方仓库。
- Arch 是滚动发行版，Alpine netboot 和软件仓库也会持续更新；正式执行前应重新运行 `--dry-run`，重要环境建议先在虚拟机测试。
- 本项目不是 Arch Linux 或 Alpine Linux 官方安装器。
