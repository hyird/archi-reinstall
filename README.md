# Arch Linux 网络重装脚本

`archi.sh` 通过 GRUB 和 Alpine 临时环境，将 x86_64 云主机或物理机重装为最小化 Arch Linux。系统使用 `pacstrap` 从 Arch 仓库直接安装，不使用预制镜像。

> [!CAUTION]
> 安装会清空目标磁盘。请确认 SSH 公钥和磁盘无误后再执行。

## 快速开始

以 root 用户执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/hyird/archi-reinstall/main/archi.sh)
```

脚本默认读取 `/root/.ssh/authorized_keys`、自动探测系统盘和当前网络，完成准备后立即重启安装。

## 默认配置

- 主机名 `arch`，时区 `Asia/Shanghai`
- `linux-lts` 内核，ext4 文件系统，不创建 swap
- 继承当前 IPv4、网关、DNS 和 MAC，失败时使用 DHCP
- root 仅允许 SSH 公钥登录，端口 `22`
- 使用系统默认网卡命名
- 安装并启用 QEMU Guest Agent
- 安装成功后自动重启

## 常用选项

| 选项 | 说明 |
|---|---|
| `--disk DEVICE` | 指定要清空的整块磁盘 |
| `--authorized-key "KEY"` | 直接传入 root SSH 公钥 |
| `--authorized-key-file FILE` | 从文件读取 root SSH 公钥 |
| `--authorized-keys-url URL` | 从 URL 下载 root SSH 公钥 |
| `--hostname NAME` | 设置主机名 |
| `--timezone ZONE` | 设置时区 |
| `--ip ADDRESS/CIDR` | 设置静态 IPv4 地址 |
| `--gateway ADDRESS` | 设置 IPv4 网关 |
| `--dns "ADDR ..."` | 设置 DNS 服务器 |
| `--ssh-port PORT` | 设置 SSH 端口 |
| `--ethx` | 使用 `eth0` 风格网卡名 |
| `--kernel linux` | 使用 Arch 主线内核 |
| `--firmware` | 安装 `linux-firmware` |
| `--install "PKG ..."` | 安装额外官方仓库软件包 |
| `--bbr` | 启用 TCP BBR |
| `--fail2ban` | 启用 SSH 防护 |
| `--swap-mib N` | 创建 N MiB swap 文件 |
| `--tuna` / `--ustc` / `--aliyun` | 使用中国大陆镜像和网络服务 |
| `--dry-run` | 只检查并显示安装计划 |
| `--no-reboot` | 准备完成后不立即重启 |
| `--hold` | 进入 Alpine 后等待手动确认，不擦盘 |
| `--power-off` | 安装成功后关机 |

查看脚本帮助：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/hyird/archi-reinstall/main/archi.sh) --help
```

## 示例

指定磁盘和公钥：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/hyird/archi-reinstall/main/archi.sh) --disk /dev/vda --authorized-keys-url https://github.com/USERNAME.keys
```

使用 TUNA 镜像并启用 BBR：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/hyird/archi-reinstall/main/archi.sh) --tuna --bbr
```

只检查配置：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/hyird/archi-reinstall/main/archi.sh) --dry-run
```

## 安装进度

重启进入 Alpine 后，可以使用原 root 公钥连接服务器并查看日志：

```bash
ssh root@SERVER_IP
tail -f /tmp/archi-install.log
```

使用 `--hold` 时不会擦盘。确认后在 Alpine 中继续：

```bash
ARCHI_FORCE_INSTALL=1 /root/archi.sh
```

安装失败时不会自动重启。成功日志保存在新系统的 `/root/archi-install.log`。

## 撤销准备

尚未重启时执行：

```bash
./archi.sh --cleanup
```

## 要求与限制

- 仅支持 x86_64、GRUB 2、有线 IPv4、BIOS 或 UEFI
- 至少 8 GiB 磁盘，建议至少 512 MiB 内存
- 仅支持单块磁盘、GPT 和 ext4
- 不支持 LVM、RAID、磁盘加密、无线网络或容器
- 重要环境请先使用 `--dry-run` 或在虚拟机中测试
