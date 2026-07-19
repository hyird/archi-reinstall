# archi.sh

`archi.sh` 是一个参考 `debi.sh` 工作方式的 Arch Linux 网络重装脚本。它先在现有 Linux 中下载官方 ArchISO 的内核与 initramfs、写入临时 GRUB 项；重启进入 ArchISO 后，再由 ArchISO 官方支持的 `script=<URL>` 机制下载同一个脚本并执行无人值守安装。

## 前提

- x86_64 KVM/物理机，使用 GRUB 2。
- 有线网络可以通过 DHCP 联网。
- 脚本会记录当前默认路由网卡的 MAC，并通过 `BOOTIF` 交给 ArchISO；不依赖重启前后的网卡名称保持一致。
- 建议至少 2 GiB 内存、8 GiB 磁盘。
- 必须把 `archi.sh` 放到安装环境能够访问的 HTTP(S) 地址。脚本会在重启前下载该地址并计算 SHA-256，ArchISO 执行时再次校验。
- 安装会完整清空 `--disk` 指定的磁盘。

## 先做 dry-run

```bash
chmod +x archi.sh

./archi.sh \
  --dry-run \
  --script-url 'https://your-reachable-host/archi.sh' \
  --authorized-key-file /root/.ssh/authorized_keys \
  --disk /dev/vda
```

`--dry-run` 会检查脚本 URL、ArchISO 内核/initramfs、`airootfs.sfs`、CMS 签名和 pacman `core.db`，但不会下载启动文件或修改 GRUB。

## 中国大陆或受限出口示例

镜像地址只是示例，执行前必须以 `--dry-run` 的探测结果为准：

```bash
./archi.sh \
  --script-url 'http://10.0.0.10:18080/archi.sh' \
  --iso-mirror 'https://mirrors.tuna.tsinghua.edu.cn/archlinux/iso/latest' \
  --package-mirror 'https://mirrors.tuna.tsinghua.edu.cn/archlinux/$repo/os/$arch' \
  --authorized-key-file /root/.ssh/authorized_keys \
  --disk /dev/vda \
  --hostname arch-gz \
  --timezone Asia/Shanghai \
  --dns '119.29.29.29 223.5.5.5' \
  --extra-packages 'qemu-guest-agent curl nftables' \
  --dry-run
```

## 安全地进入安装环境

加 `--hold` 后，首次重启只会进入 ArchISO、写入 root SSH 公钥并启动 sshd，不会擦盘：

```bash
./archi.sh \
  --script-url 'https://your-reachable-host/archi.sh' \
  --authorized-key-file /root/.ssh/authorized_keys \
  --disk /dev/vda \
  --hold

reboot
```

SSH 进入 ArchISO 后确认磁盘和网络，再执行：

```bash
ARCHI_FORCE_INSTALL=1 /tmp/startup_script
```

## 直接自动安装

```bash
./archi.sh \
  --script-url 'https://your-reachable-host/archi.sh' \
  --authorized-key-file /root/.ssh/authorized_keys \
  --disk /dev/vda \
  --hostname archlinux \
  --timezone Asia/Shanghai \
  --extra-packages 'qemu-guest-agent curl nftables' \
  --reboot --yes
```

安装结果默认使用：

- GPT + ext4；BIOS 创建 `bios_grub` 分区，UEFI 创建 512 MiB ESP。
- `systemd-networkd` + DHCP、`systemd-resolved`。
- GRUB、OpenSSH。
- root 只允许指定公钥登录，密码处于锁定状态。
- 默认创建 1024 MiB swap 文件，可用 `--swap-mib 0` 关闭。

## 重启前撤销

在尚未重启进入 ArchISO 时，可以撤销启动项：

```bash
./archi.sh --cleanup
```

如果安装失败，脚本不会自动重启；ArchISO 会保留在线并启动 key-only SSH，日志位于 `/tmp/archi-install.log`。安装成功后的日志复制到 `/root/archi-install.log`。

## 已知边界

- 当前仅支持 x86_64、单磁盘整盘安装、ext4 和 DHCP 启动。
- `script=<URL>` 是 ArchISO 官方机制，因此脚本 URL 必须在安装期间持续可访问。
- 这不是 Arch 官方项目；滚动发行版介质变化后应重新执行 dry-run 和虚拟机测试。
