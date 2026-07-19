# archi.sh

`archi.sh` 是一个独立实现的 Arch Linux 网络重装脚本。它在现有 Linux 中下载官方 ArchISO kernel/initramfs，并向官方 initramfs 追加一个很小的 cpio overlay，内含当前脚本、SSH 公钥、网络配置和 systemd 安装服务；不使用 Alpine，也不要求重启后再次下载脚本。

设计上只参考了 [`bin456789/reinstall`](https://github.com/bin456789/reinstall) 的一次性启动、网络继承和 hold/rescue 思路；本项目不包装、不调用也不依赖该项目，ArchISO overlay、GRUB staging 与 pacstrap 安装流程均为独立实现。

## 前提

- x86_64 KVM/物理机，使用 GRUB 2。
- 有线网络具备 IPv4 联网能力；脚本优先继承当前地址、网关和 DNS，探测不到时才回退 DHCP。
- 脚本会记录当前 IPv4 地址、网关、DNS 和默认路由网卡 MAC，在 ArchISO 与安装后的系统中恢复静态网络；探测不到完整静态参数时回退 DHCP。
- 建议至少 2 GiB 内存、8 GiB 磁盘。
- 构建 overlay 需要 `cpio`、`gzip`，以及 `unmkinitramfs`（Debian/Ubuntu 的 `initramfs-tools-core`）或 Arch 的 `lsinitcpio`。
- 安装会完整清空 `--disk` 指定的磁盘。

## 先做 dry-run

```bash
chmod +x archi.sh

./archi.sh \
  --dry-run \
  --authorized-key-file /root/.ssh/authorized_keys \
  --disk /dev/vda
```

`--dry-run` 会检查 ArchISO kernel/initramfs、`airootfs.sfs`、CMS 签名和 pacman `core.db`，但不会下载启动文件或修改 GRUB。正式 staging 下载 initramfs 后，还会检查当前 ArchISO 的 `archiso_pxe_common` 接口，接口不兼容时停止而不是写入启动项。

## 中国大陆或受限出口示例

镜像地址只是示例，执行前必须以 `--dry-run` 的探测结果为准：

```bash
./archi.sh \
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
  --authorized-key-file /root/.ssh/authorized_keys \
  --disk /dev/vda \
  --hold

reboot
```

SSH 进入 ArchISO 后确认磁盘和网络，再执行：

```bash
ARCHI_FORCE_INSTALL=1 /root/archi.sh
```

## 直接自动安装

```bash
./archi.sh \
  --authorized-key-file /root/.ssh/authorized_keys \
  --disk /dev/vda \
  --hostname archlinux \
  --timezone Asia/Shanghai \
  --extra-packages 'qemu-guest-agent curl nftables' \
  --reboot --yes
```

安装结果默认使用：

- GPT + ext4；BIOS 创建 `bios_grub` 分区，UEFI 创建 512 MiB ESP。
- 默认安装 Arch 官方 `linux-lts` 内核；可用 `--kernel linux` 改为滚动主线内核。
- `systemd-networkd` + `systemd-resolved`；优先保留 staging 时的静态 IPv4，无法探测时使用 DHCP。
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

- 当前仅支持 x86_64、GRUB 2、单磁盘整盘安装和 ext4。
- staging 主机当前需要能提取 initramfs；正式安装期间仍需访问 ArchISO root image 与 pacman 镜像。
- 这不是 Arch 官方项目；滚动发行版介质变化后应重新执行 dry-run 和虚拟机测试。
