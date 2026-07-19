# archi.sh

`archi.sh` 是面向云主机的 Arch Linux 整盘网络重装脚本。临时安装环境使用 Alpine `latest-stable` 的官方 `vmlinuz-virt`、`initramfs-virt` 和 `modloop-virt`；启动后只从所选 Alpine 镜像安装官方 APK，最终通过 `pacstrap` 把 Arch 官方仓库包直接安装到目标分区。

脚本不下载 `airootfs.sfs`，不写入预制系统镜像，也不需要自行编译 initrd。除了脚本本体，下载内容都来自配置的 Alpine 或 Arch 镜像。

设计上只参考了 [`bin456789/reinstall`](https://github.com/bin456789/reinstall) 的一次性引导、网络继承和救援环境思路，以及 [`bohanwood/debi`](https://github.com/bohanwood/debi) 的参数组织方式；没有复制、调用或依赖它们的代码，GRUB staging、Alpine apkovl/PID 1 和 Arch 安装流程均为独立实现。

## 默认结果

- 临时环境主机名 `alpine`，最终主机名 `arch`。
- Arch `linux-lts` 内核；默认不安装 `linux-firmware`。
- 安装并启用 `qemu-guest-agent`。
- 默认安装 `inetutils`、`coreutils`、`bash-completion`、`wget`、`curl`、`vim` 和 `nano`，并保留脚本再次 staging 所需的 `cpio`。
- root 密码锁定，仅允许指定公钥登录，SSH 端口 22。
- 自动继承当前默认网卡的 IPv4、网关、DNS 和 MAC；信息不完整时回退 DHCP。
- 最终网络使用 `systemd-networkd`、`systemd-resolved` 和 `systemd-timesyncd`。
- 默认采用 eth0 风格命名，按官方方式创建 `/etc/udev/rules.d/80-net-setup-link.rules -> /dev/null`。
- GPT + ext4 + GRUB；默认不创建 swap。

## 支持范围

- x86_64，GRUB 2，有线 IPv4 网络。
- BIOS 或 UEFI，单块整盘安装，ext4 根分区。
- 至少 8 GiB 磁盘；建议临时环境至少 512 MiB 内存。
- staging 主机需提供 Bash、curl、cpio、gzip、GRUB 工具和常见磁盘/网络命令。

安装会清空 `--disk` 指定的整块磁盘。建议先运行 `--dry-run`，并确认控制台或 SSH 公钥可用。

## 快速使用

先检查计划，不修改启动配置：

```bash
chmod +x archi.sh
./archi.sh \
  --dry-run \
  --authorized-key-file /root/.ssh/authorized_keys \
  --disk /dev/vda
```

准备下一次启动，但暂不自动重启：

```bash
./archi.sh \
  --authorized-key-file /root/.ssh/authorized_keys \
  --disk /dev/vda

reboot
```

确认擦盘并直接 staging、重启、安装：

```bash
./archi.sh \
  --authorized-key-file /root/.ssh/authorized_keys \
  --disk /dev/vda \
  --reboot --yes
```

## 受限出口与中国大陆镜像

预设会同时切换 Alpine、Arch、DNS 和 NTP：

```bash
./archi.sh \
  --tuna \
  --authorized-key-file /root/.ssh/authorized_keys \
  --disk /dev/vda \
  --timezone Asia/Shanghai \
  --reboot --yes
```

可选预设：

- `--tuna`：清华 TUNA。
- `--ustc` 或 `--china`：中科大 USTC。
- `--aliyun`：阿里云。
- `--cloudflare`：官方镜像配 Cloudflare DNS/NTP。

也可分别使用 `--alpine-mirror URL` 和 `--package-mirror URL`。前者应是包含 `latest-stable` 的 Alpine 镜像根地址，后者应包含 Arch 的 `$repo/os/$arch`。

## 安装期间 SSH 查看进度

Alpine 启动后会立即恢复网络、生成临时主机密钥并启动 key-only SSH，主机名为 `alpine`。使用 staging 时提供的 root 公钥登录：

```bash
ssh root@SERVER_IP
tail -f /tmp/archi-install.log
```

若使用 `--hold`，Alpine 只验证计划并保持在线，不擦盘：

```bash
./archi.sh \
  --hold \
  --authorized-key-file /root/.ssh/authorized_keys \
  --disk /dev/vda
reboot
```

检查无误后在 Alpine 中继续：

```bash
ARCHI_FORCE_INSTALL=1 /root/archi.sh
```

失败时 Alpine 不会自动重启，可继续通过 SSH 查看日志和诊断。成功日志会复制到最终系统的 `/root/archi-install.log`。

## debi 风格常用选项

| 选项 | 行为 |
|---|---|
| `--hostname NAME` | 最终主机名；默认 `arch` |
| `--timezone ZONE` | 最终时区；默认 `UTC` |
| `--ip CIDR` / `--netmask` / `--gateway` / `--interface` | 覆盖自动探测的静态网络 |
| `--dns "ADDR ..."` / `--ntp HOST` | 覆盖 DNS 和 NTP |
| `--authorized-keys-url URL` | staging 时下载并嵌入 root 公钥 |
| `--ssh-port PORT` | 同时设置 Alpine 和最终 Arch 的 SSH 端口 |
| `--cloud-kernel` | 恢复默认云配置：`linux-lts` 且不装 firmware |
| `--kernel linux` | 改用 Arch 滚动主线内核 |
| `--firmware` | 安装 `linux-firmware` |
| `--install "PKG ..."` | 安装额外 Arch 官方仓库包 |
| `--bbr` | 启用 fq + TCP BBR |
| `--ethx` | eth0 风格命名，默认开启 |
| `--predictable-names` | 保留 systemd 可预测网卡名 |
| `--swap-mib N` | 显式创建 N MiB swap；默认 0 |
| `--bios` / `--efi` | 覆盖自动检测的启动模式 |
| `--power-off` | 安装成功后关机而非重启 |

完整列表请运行 `./archi.sh --help`。

## 网络与 DNS 探测

脚本以 `ip route get` 和实时地址/路由为准，并从以下常见网络配置器或运行态文件收集 IPv4 DNS：

- systemd-resolved (`resolvectl`)
- NetworkManager (`nmcli` 及 `/run/NetworkManager/*`)
- resolvconf
- ConnMan
- `/etc/resolv.conf`

DNS 会去重并排除 loopback stub 地址。完整的 IPv4、网关和 MAC 被写进 Alpine 启动参数，并在最终 Arch 中按 MAC 恢复；无法形成完整静态配置时使用 DHCP。

## 启动文件与来源

staging 只下载约 12 MiB 的 Alpine virt kernel 和约 9 MiB 的 initramfs。Alpine 启动后再从同一 `latest-stable` 镜像获取约 22 MiB 的 modloop 和所需官方 APK；最终系统包只从所选 Arch 镜像获取。

构建的 overlay 内仅包含配置、SSH 公钥和当前脚本。payload SHA-256 被写入内核参数，Alpine 执行前会校验脚本完整性。

## 容错与失败处理

- staging 会在写入 GRUB 前检查 Alpine kernel、initramfs、modloop、main/community APKINDEX，以及 Arch core/extra 仓库。
- kernel/initramfs 使用临时文件下载，通过最小体积检查后才原子替换正式文件；curl 会重试连接失败。
- Alpine 必需 APK 最多尝试 3 次，modloop 下载最多尝试 5 次。
- 分区完成后最多等待 10 秒让 virtio、SCSI、NVMe 等块设备节点出现。
- `pacstrap` 遇到临时仓库或连接故障时最多尝试 3 次，并清理失效的数据库锁和临时 GPG agent。
- 安装完成后先等待临时 GPG agent 确实退出，超时则强制终止；随后对 EFI 和根挂载点分别重试卸载，避免后台进程竞态。
- 任一步失败都不会盲目重启；Alpine 和 key-only SSH 会保持在线，日志位于 `/tmp/archi-install.log`。

## 撤销 staging

尚未重启进入 Alpine 时可以撤销 GRUB 项和下载文件：

```bash
./archi.sh --cleanup
```

## 已知边界

- 当前不支持多磁盘布局、LVM、RAID、加密根分区或无线网络。
- `--extra-packages` 只适用于所选 Arch 官方仓库中存在的包。
- 这是独立项目，不是 Alpine 或 Arch 官方安装器；滚动仓库或 netboot 介质变化后应重新执行 dry-run 和虚拟机测试。
