#!/usr/bin/env bash
# archi.sh - Alpine-staged, unattended Arch Linux pacstrap reinstall
#
# The same file has two modes:
#   1. On the existing Linux system it stages Alpine's official virt netboot
#      kernel/initramfs and creates a one-time GRUB entry.
#   2. An embedded apkovl installs only official Alpine packages, starts SSH,
#      and runs this exact file to pacstrap a pure Arch system to the target.

set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true
umask 077

readonly ARCHI_PAYLOAD_ID='archi-network-reinstall-v1'
readonly ARCHI_VERSION='0.8.0'
readonly DEFAULT_ALPINE_MIRROR='https://dl-cdn.alpinelinux.org/alpine'
# The pacman placeholders must remain literal until the installer writes mirrorlist.
readonly DEFAULT_PACKAGE_MIRROR="https://geo.mirror.pkgbuild.com/\$repo/os/\$arch"
readonly TUNA_ALPINE_MIRROR='https://mirrors.tuna.tsinghua.edu.cn/alpine'
readonly TUNA_PACKAGE_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/archlinux/\$repo/os/\$arch"
readonly USTC_ALPINE_MIRROR='https://mirrors.ustc.edu.cn/alpine'
readonly USTC_PACKAGE_MIRROR="https://mirrors.ustc.edu.cn/archlinux/\$repo/os/\$arch"
readonly ALIYUN_ALPINE_MIRROR='https://mirrors.aliyun.com/alpine'
readonly ALIYUN_PACKAGE_MIRROR="https://mirrors.aliyun.com/archlinux/\$repo/os/\$arch"
readonly DEFAULT_INSTALL_DIR='/boot/archi-reinstall'
readonly GRUB_ENTRY_FILE='/etc/grub.d/42_archi_reinstall'
readonly GRUB_DEFAULT_FILE='/etc/default/grub.d/zz-archi-reinstall.cfg'

log() {
    printf '[archi] %s\n' "$*"
}

warn() {
    printf '[archi] WARNING: %s\n' "$*" >&2
}

die() {
    printf '[archi] ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  archi.sh [stage options]
  archi.sh --cleanup [--install-dir DIR]

Stage options:
  --cloudflare                 Use Cloudflare DNS/NTP with official mirrors.
  --aliyun                    Use Aliyun Arch mirrors, AliDNS and China NTP.
  --ustc, --china             Use USTC Arch mirrors, DNSPod and China NTP.
  --tuna                      Use TUNA Arch mirrors, DNSPod and China NTP.
  --alpine-mirror URL          Alpine mirror root containing latest-stable.
  --iso-mirror URL             Deprecated alias for --alpine-mirror.
  --package-mirror URL         Pacman mirror containing $repo/os/$arch.
  --authorized-key "KEY"       Use a literal root SSH public key.
  --authorized-key-file FILE   File containing the root SSH public key.
  --authorized-keys-url URL    Download the root SSH public key before staging.
  --disk DEVICE                Whole target disk, for example /dev/vda.
  --hostname NAME              Installed hostname (default: arch).
  --timezone ZONE              Installed timezone (default: UTC).
  --interface DEVICE           Source interface (default: current default route).
  --ip ADDRESS/CIDR            Override the inherited static IPv4 address.
  --netmask MASK               Netmask used when --ip has no CIDR prefix.
  --gateway ADDRESS            Override the inherited IPv4 gateway.
  --static-ipv4                Explicitly request the default inherit-current mode.
  --dns "ADDR ..."             DNS servers written to systemd-networkd config.
  --ntp HOST                  NTP server (default: time.cloudflare.com).
  --ssh-port PORT             SSH port in Alpine and installed Arch (default: 22).
  --bbr                       Enable fq + TCP BBR in the installed system.
  --fail2ban                  Install an nftables-backed SSH jail (off by default).
  --firmware                  Install linux-firmware (off by default for cloud VMs).
  --cloud-kernel              Re-apply the default cloud kernel/profile.
  --ethx                      Use eth0-style names (default, official udev method).
  --predictable-names         Keep systemd predictable interface names.
  --network-console           Compatibility alias; Alpine SSH is always enabled.
  --kernel PACKAGE             linux or linux-lts (default: linux-lts).
  --extra-packages "PKG ..."   Extra official repository packages.
  --install "PKG ..."          debi-compatible alias for --extra-packages.
  --swap-mib N                 Swap file size in MiB (default: 0, disabled).
  --boot-mode MODE             auto, bios, or efi (default: auto).
  --bios, --efi                debi-compatible boot-mode aliases.
  --grub-timeout N            GRUB menu timeout after installation (default: 5).
  --install-dir DIR            Staging directory under /boot.
  --hold                       Boot Alpine, enable key-only SSH, but do not wipe.
                               Continue there with:
                               ARCHI_FORCE_INSTALL=1 /root/archi.sh
  --power-off                  Power off instead of reboot after installation.
  --reboot                     Compatibility option; reboot is already the default.
  --yes                        Compatibility option; destructive run is already confirmed.
  --no-reboot                  Stage GRUB but wait for a manual reboot.
  --force-low-memory           Allow staging with less than 384 MiB RAM.
  --dry-run                    Validate and print the plan without changing files.
  --cleanup                    Remove the staged GRUB entry and downloaded files.
  --help                       Show this help.
  --version                    Show script version.

The target must be x86_64, use GRUB 2, and have wired IPv4 connectivity.
512 MiB RAM is recommended for the Alpine installer. Defaults are
cloud-first: hostname arch, linux-lts, eth0-style naming, QEMU guest agent,
key-only root SSH, static-network inheritance, and no large firmware bundle. The official
Alpine kernel/initramfs, modloop and APK repositories are used directly; the
final operating system is installed with pacstrap from the selected Arch mirror.
EOF
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

trim_trailing_slash() {
    local value=$1
    while [[ $value == */ ]]; do value=${value%/}; done
    printf '%s' "$value"
}

validate_url() {
    local name=$1 value=$2
    [[ $value =~ ^https?:// ]] || die "$name must use HTTP or HTTPS"
    [[ $value != *[[:space:]\;\"\'\\]* ]] || die "$name contains unsafe characters"
}

validate_hostname() {
    [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,61}[A-Za-z0-9])?$ ]] ||
        die "Invalid hostname: $1"
}

validate_packages() {
    local package
    for package in $1; do
        [[ $package =~ ^[A-Za-z0-9@._+-]+$ ]] || die "Invalid package name: $package"
    done
}

is_ipv4() {
    local value=$1 octet
    local -a octets
    [[ $value =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r -a octets <<< "$value"
    for octet in "${octets[@]}"; do
        ((10#$octet <= 255)) || return 1
    done
}

validate_dns_servers() {
    local server
    for server in $1; do
        is_ipv4 "$server" || die "Invalid IPv4 DNS server: $server"
    done
}

validate_port() {
    if ! [[ $1 =~ ^[0-9]+$ ]] || ! ((10#$1 >= 1 && 10#$1 <= 65535)); then
        die "Invalid SSH port: $1"
    fi
}

encode_b64() {
    printf '%s' "$1" | base64 -w 0
}

decode_b64() {
    printf '%s' "$1" | base64 -d
}

cmdline_value() {
    local wanted=$1 token
    for token in $(</proc/cmdline); do
        case $token in
            "$wanted"=*) printf '%s' "${token#*=}"; return 0 ;;
        esac
    done
    return 1
}

is_install_environment() {
    [[ -r /proc/cmdline ]] && grep -qw 'archi_mode=install' /proc/cmdline
}

detect_root_disk() {
    local source parent
    source=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    if [[ $source == /dev/* ]]; then
        parent=$(lsblk -ndo PKNAME "$source" 2>/dev/null | tail -n 1 || true)
        if [[ -n $parent ]]; then
            printf '/dev/%s\n' "$parent"
            return 0
        fi
        if [[ $(lsblk -ndo TYPE "$source" 2>/dev/null || true) == disk ]]; then
            printf '%s\n' "$source"
            return 0
        fi
    fi

    mapfile -t disks < <(lsblk -dpno NAME,TYPE | awk '$2 == "disk" {print $1}')
    [[ ${#disks[@]} -eq 1 ]] ||
        die "Could not safely determine the target disk; use --disk"
    printf '%s\n' "${disks[0]}"
}

detect_bootif() {
    local requested=${1:-} interface='' interface_path mac=''

    if [[ -n $requested && $requested != auto ]]; then
        interface=$requested
    else
        interface=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '
            { for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }
        ')
    fi
    if [[ -z $interface ]]; then
        for interface_path in /sys/class/net/*; do
            [[ ${interface_path##*/} == lo ]] && continue
            [[ -r $interface_path/address ]] || continue
            interface=${interface_path##*/}
            break
        done
    fi

    [[ -n $interface && -r /sys/class/net/$interface/address ]] ||
        die 'Could not determine the boot network interface from the default route'
    mac=$(<"/sys/class/net/$interface/address")
    [[ $mac =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ && $mac != 00:00:00:00:00:00 ]] ||
        die "Invalid MAC address on boot interface $interface: $mac"
    printf '%s %s\n' "$interface" "01-${mac//:/-}"
}

prefix_to_netmask() {
    local prefix=$1 octet bits value result=''
    if [[ ! $prefix =~ ^[0-9]+$ ]] || (( prefix > 32 )); then
        die "Invalid IPv4 prefix: $prefix"
    fi
    for octet in 0 1 2 3; do
        bits=$((prefix - octet * 8))
        if (( bits >= 8 )); then
            value=255
        elif (( bits <= 0 )); then
            value=0
        else
            value=$((256 - 2 ** (8 - bits)))
        fi
        result+="${result:+.}$value"
    done
    printf '%s\n' "$result"
}

netmask_to_prefix() {
    local netmask=$1 octet prefix=0 partial=false bits
    local -a octets
    is_ipv4 "$netmask" || die "Invalid IPv4 netmask: $netmask"
    IFS=. read -r -a octets <<< "$netmask"
    for octet in "${octets[@]}"; do
        case $octet in
            255) bits=8 ;;
            254) bits=7 ;;
            252) bits=6 ;;
            248) bits=5 ;;
            240) bits=4 ;;
            224) bits=3 ;;
            192) bits=2 ;;
            128) bits=1 ;;
            0) bits=0 ;;
            *) die "Non-contiguous IPv4 netmask: $netmask" ;;
        esac
        if [[ $partial == true && $bits != 0 ]]; then
            die "Non-contiguous IPv4 netmask: $netmask"
        fi
        (( bits < 8 )) && partial=true
        prefix=$((prefix + bits))
    done
    printf '%s\n' "$prefix"
}

detect_dns_servers() {
    local interface=$1 resolver_file
    {
        if command -v resolvectl >/dev/null 2>&1; then
            resolvectl dns "$interface" || true
        fi
        if command -v nmcli >/dev/null 2>&1; then
            nmcli --get-values IP4.DNS device show "$interface" || true
        fi
        for resolver_file in \
            /run/systemd/resolve/resolv.conf \
            /run/NetworkManager/no-stub-resolv.conf \
            /run/NetworkManager/resolv.conf \
            /run/resolvconf/resolv.conf \
            /var/run/connman/resolv.conf \
            /etc/resolv.conf; do
            [[ -r $resolver_file ]] && awk '$1 == "nameserver" { print $2 }' "$resolver_file"
        done
    } 2>/dev/null | awk '
        {
            for (i = 1; i <= NF; i++) {
                value = $i
                gsub(/[,;]/, "", value)
                if (value ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && value !~ /^127\./ && !seen[value]++) {
                    printf "%s%s", separator, value
                    separator = " "
                }
            }
        }
        END { print "" }
    '
}

build_boot_network_parameter() {
    local interface=$1 hostname=$2 dns=$3 bootif=$4
    local requested_cidr=${5:-} requested_gateway=${6:-}
    local cidr address prefix gateway netmask dns0='' dns1=''
    if [[ -n $requested_cidr ]]; then
        cidr=$requested_cidr
    else
        cidr=$(ip -4 -o address show dev "$interface" scope global 2>/dev/null |
            awk 'NR == 1 { print $4 }')
    fi
    if [[ -n $requested_gateway ]]; then
        gateway=$requested_gateway
    else
        gateway=$(ip -4 route show default dev "$interface" 2>/dev/null | awk '
            { for (i = 1; i <= NF; i++) if ($i == "via") { print $(i + 1); exit } }
        ')
    fi
    if [[ $cidr == */* && -n $gateway ]]; then
        address=${cidr%/*}
        prefix=${cidr#*/}
        netmask=$(prefix_to_netmask "$prefix")
        read -r dns0 dns1 _ <<< "$dns"
        [[ -n $dns0 ]] || dns0=$gateway
        # Alpine follows the kernel ip= client:server:gateway:mask:host:dev:
        # autoconf:dns0:dns1 form. BOOTIF makes this survive interface renames.
        printf 'ip=%s::%s:%s:%s::none:%s:%s BOOTIF=%s\n' \
            "$address" "$gateway" "$netmask" "$hostname" "$dns0" "$dns1" "$bootif"
    else
        printf 'ip=dhcp BOOTIF=%s\n' "$bootif"
    fi
}

build_alpine_initramfs() {
    local original=$1 destination=$2 authorized_key=$3 hostname=$4 ssh_port=$5 dns=$6
    local alpine_mirror=$7
    local work apkovl overlay apkovl_archive overlay_archive dns_server
    work=$(mktemp -d)
    apkovl=$work/apkovl
    overlay=$work/overlay
    apkovl_archive=$overlay/archi.apkovl.tar.gz
    overlay_archive=$work/archi-overlay.img
    mkdir -p -- "$overlay" "$apkovl/etc/apk" "$apkovl/etc/ssh/sshd_config.d" \
        "$apkovl/root/.ssh"

    cat > "$apkovl/etc/apk/world" <<'EOF'
alpine-base
apk-tools
arch-install-scripts
bash
ca-certificates
curl
dosfstools
e2fsprogs
findmnt
gptfdisk
lsblk
openssh
parted
sgdisk
tzdata
util-linux-misc
wipefs
EOF
    : > "$apkovl/etc/.default_boot_services"
    printf '%s\n' "$hostname" > "$apkovl/etc/hostname"
    cat > "$apkovl/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/ash
sshd:x:22:22:sshd:/var/empty:/sbin/nologin
EOF
    cat > "$apkovl/etc/group" <<'EOF'
root:x:0:root
wheel:x:10:root
sshd:x:22:
EOF
    cat > "$apkovl/etc/shadow" <<'EOF'
root:*:0:0:99999:7:::
EOF
    : > "$apkovl/etc/resolv.conf"
    for dns_server in $dns; do
        printf 'nameserver %s\n' "$dns_server" >> "$apkovl/etc/resolv.conf"
    done
    cat > "$apkovl/etc/apk/repositories" <<EOF
$alpine_mirror/latest-stable/main
$alpine_mirror/latest-stable/community
EOF
    printf '%s\n' \
        "$alpine_mirror/latest-stable/releases/x86_64/netboot/modloop-virt" \
        > "$apkovl/etc/archi-modloop-url"
    cat > "$apkovl/etc/pacman.conf" <<'EOF'
[options]
Architecture = auto
CheckSpace
ParallelDownloads = 5
SigLevel = Never
LocalFileSigLevel = Optional

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist
EOF
    cat > "$apkovl/etc/ssh/sshd_config.d/60-archi-key-only.conf" <<EOF
Port $ssh_port
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
LoginGraceTime 30
MaxAuthTries 3
MaxStartups 10:30:30
PerSourceMaxStartups 3
X11Forwarding no
EOF
    printf '%s\n' "$authorized_key" > "$apkovl/root/.ssh/authorized_keys"
    cp -f -- "${BASH_SOURCE[0]}" "$apkovl/root/archi.sh"
    cat > "$apkovl/root/archi-init" <<'EOF'
#!/bin/sh
set +e
echo '[archi] Alpine installer init started.' >/dev/console
hostname alpine
mkdir -p /run/sshd /tmp /var/empty
ln -sfn /proc/self/fd /dev/fd
ln -sfn /proc/self/fd/0 /dev/stdin
ln -sfn /proc/self/fd/1 /dev/stdout
ln -sfn /proc/self/fd/2 /dev/stderr
ln -sfn /proc/mounts /etc/mtab
apk del alpine-base alpine-conf >/tmp/archi-apk-remove.log 2>&1
apk_rc=1
apk_attempt=1
while [ "$apk_attempt" -le 3 ]; do
    if apk add --no-cache arch-install-scripts bash ca-certificates curl dosfstools \
        e2fsprogs findmnt lsblk openssh parted sgdisk tzdata wipefs \
        >/tmp/archi-apk.log 2>&1; then
        apk_rc=0
        break
    fi
    echo "[archi] APK attempt $apk_attempt/3 failed; retrying." >/dev/console
    apk_attempt=$((apk_attempt + 1))
    sleep 3
done
echo "[archi] required APK exit status: $apk_rc" >/dev/console
[ "$apk_rc" -eq 0 ] || cat /tmp/archi-apk.log >/dev/console
mkdir -p /.modloop /lib
curl --fail --location --retry 5 --retry-all-errors --retry-delay 2 \
    --connect-timeout 10 --output /tmp/modloop-virt \
    "$(cat /etc/archi-modloop-url)" >/tmp/archi-modloop.log 2>&1
modloop_rc=$?
if [ "$modloop_rc" -eq 0 ]; then
    mount -t squashfs -o loop,ro /tmp/modloop-virt /.modloop
    ln -sfn /.modloop/modules /lib/modules
    for module in virtio_scsi virtio_blk sd_mod ahci nvme ext4 vfat; do
        modprobe "$module" >/dev/null 2>&1 || true
    done
    mdev -s >/dev/null 2>&1 || true
else
    echo "[archi] modloop download failed with status $modloop_rc" >/dev/console
    cat /tmp/archi-modloop.log >/dev/console
fi
ssh-keygen -A >/tmp/archi-ssh-keygen.log 2>&1
ssh_keygen_rc=$?
echo "[archi] ssh-keygen exit status: $ssh_keygen_rc" >/dev/console
[ "$ssh_keygen_rc" -eq 0 ] || cat /tmp/archi-ssh-keygen.log >/dev/console
/usr/sbin/sshd -E /tmp/archi-sshd.log
sshd_rc=$?
echo "[archi] sshd exit status: $sshd_rc" >/dev/console
[ "$sshd_rc" -eq 0 ] || cat /tmp/archi-sshd.log >/dev/console
echo '[archi] SSH should be ready. Follow installation with: tail -f /tmp/archi-install.log' >/dev/console
/root/archi.sh </dev/console >/dev/console 2>&1 &
installer_pid=$!
while :; do
    if ! kill -0 "$installer_pid" 2>/dev/null; then
        wait "$installer_pid"
        installer_rc=$?
        echo "[archi] Installer exited with status $installer_rc; Alpine remains online." >/dev/console
        installer_pid=0
    fi
    sleep 5 &
    wait $!
done
EOF
    chmod 0700 "$apkovl/root/archi-init"
    find "$apkovl" -type d -exec chmod 0755 {} +
    chmod 0700 "$apkovl/root" "$apkovl/root/.ssh" "$apkovl/root/archi.sh" \
        "$apkovl/root/archi-init"
    chmod 0600 "$apkovl/root/.ssh/authorized_keys"
    chmod 0600 "$apkovl/etc/shadow"
    chmod 0644 "$apkovl/etc/hostname" "$apkovl/etc/resolv.conf" \
        "$apkovl/etc/passwd" "$apkovl/etc/group" "$apkovl/etc/apk/repositories" \
        "$apkovl/etc/archi-modloop-url" \
        "$apkovl/etc/pacman.conf" \
        "$apkovl/etc/ssh/sshd_config.d/60-archi-key-only.conf"

    (cd "$apkovl" && tar --numeric-owner --owner=0 --group=0 -czf "$apkovl_archive" .)

    (cd "$overlay" && find . -print0 | cpio --null --quiet -o -H newc | gzip -9) > "$overlay_archive"
    cat "$original" "$overlay_archive" > "${destination}.part"
    mv -f -- "${destination}.part" "$destination"
    rm -rf -- "$work"
}

first_public_key() {
    local file=$1
    [[ -r $file ]] || die "SSH public key file is not readable: $file"
    awk '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        /(^|[[:space:]])(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521))[[:space:]]/ {
            print
            exit
        }
    ' "$file"
}

first_public_key_text() {
    printf '%s\n' "$1" | awk '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        /(^|[[:space:]])(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521))[[:space:]]/ {
            print
            exit
        }
    '
}

probe_url() {
    local label=$1 url=$2
    log "Checking $label: $url"
    curl --fail --location --silent --show-error \
        --retry 3 --retry-connrefused --connect-timeout 10 --max-time 45 \
        --range 0-0 --output /dev/null "$url"
}

download_file() {
    local url=$1 destination=$2 minimum_bytes=$3 temporary size
    temporary="${destination}.part"
    rm -f -- "$temporary"
    log "Downloading $url"
    curl --fail --location --show-error \
        --retry 5 --retry-connrefused --connect-timeout 10 \
        --output "$temporary" "$url"
    size=$(stat -c '%s' "$temporary")
    (( size >= minimum_bytes )) || die "Downloaded file is unexpectedly small: $url ($size bytes)"
    mv -f -- "$temporary" "$destination"
}

update_grub_config() {
    if command -v update-grub >/dev/null 2>&1; then
        update-grub
    elif command -v grub-mkconfig >/dev/null 2>&1; then
        local output
        if [[ -e /boot/grub2/grub.cfg ]]; then
            output=/boot/grub2/grub.cfg
        else
            output=/boot/grub/grub.cfg
        fi
        grub-mkconfig -o "$output"
    else
        die 'Neither update-grub nor grub-mkconfig is available'
    fi
}

safe_install_dir() {
    local candidate=$1 resolved_parent
    [[ $candidate == /boot/archi-* || $candidate == /boot/archi/* ]] ||
        die "Install directory must be a dedicated path under /boot named archi-*: $candidate"
    resolved_parent=$(readlink -f "$(dirname "$candidate")")
    [[ $resolved_parent == /boot || $resolved_parent == /boot/* ]] ||
        die "Install directory resolves outside /boot: $candidate"
}

cleanup_stage() {
    local install_dir=$1 changed=false
    [[ $(id -u) -eq 0 ]] || die '--cleanup requires root'
    safe_install_dir "$install_dir"

    if [[ -e $GRUB_ENTRY_FILE ]]; then
        grep -q 'ARCHI_PAYLOAD_ID=archi-network-reinstall-v1' "$GRUB_ENTRY_FILE" ||
            die "Refusing to remove an unrecognized file: $GRUB_ENTRY_FILE"
        rm -f -- "$GRUB_ENTRY_FILE"
        changed=true
    fi
    if [[ -e $GRUB_DEFAULT_FILE ]]; then
        grep -q 'archi' "$GRUB_DEFAULT_FILE" ||
            die "Refusing to remove an unrecognized file: $GRUB_DEFAULT_FILE"
        rm -f -- "$GRUB_DEFAULT_FILE"
        changed=true
    fi
    if [[ -e $install_dir ]]; then
        rm -rf -- "$install_dir"
        changed=true
    fi
    if [[ $changed == true ]]; then
        update_grub_config
        log 'Arch reinstall staging files were removed and GRUB was regenerated'
    else
        log 'No Arch reinstall staging files were present'
    fi
}

stage_main() {
    local alpine_mirror=$DEFAULT_ALPINE_MIRROR
    local package_mirror=$DEFAULT_PACKAGE_MIRROR
    local authorized_key_literal=''
    local authorized_key_file=''
    local authorized_keys_url=''
    local disk=''
    local hostname='arch'
    local timezone='UTC'
    local dns=''
    local ntp='time.cloudflare.com'
    local requested_interface='auto'
    local requested_ip=''
    local requested_netmask=''
    local requested_gateway=''
    local ssh_port=22
    local bbr=false fail2ban=false firmware=false ethx=true
    local kernel='linux-lts'
    local extra_packages=''
    local swap_mib=0
    local boot_mode='auto'
    local grub_timeout=5
    local install_dir=$DEFAULT_INSTALL_DIR
    local hold=false power_off=false reboot_now=true assume_yes=true
    local force_low_memory=false dry_run=false cleanup=false

    if [[ -r /root/.ssh/authorized_keys ]]; then
        authorized_key_file=/root/.ssh/authorized_keys
    elif [[ -n ${HOME:-} && -r $HOME/.ssh/authorized_keys ]]; then
        authorized_key_file=$HOME/.ssh/authorized_keys
    fi

    while (($#)); do
        case $1 in
            --cloudflare) dns='1.1.1.1 1.0.0.1'; ntp='time.cloudflare.com'; shift ;;
            --aliyun) alpine_mirror=$ALIYUN_ALPINE_MIRROR; package_mirror=$ALIYUN_PACKAGE_MIRROR; dns='223.5.5.5 223.6.6.6'; ntp='time.amazonaws.cn'; shift ;;
            --ustc|--china) alpine_mirror=$USTC_ALPINE_MIRROR; package_mirror=$USTC_PACKAGE_MIRROR; dns='119.29.29.29 223.5.5.5'; ntp='time.amazonaws.cn'; shift ;;
            --tuna) alpine_mirror=$TUNA_ALPINE_MIRROR; package_mirror=$TUNA_PACKAGE_MIRROR; dns='119.29.29.29 223.5.5.5'; ntp='time.amazonaws.cn'; shift ;;
            --alpine-mirror|--iso-mirror) alpine_mirror=${2:?missing value}; shift 2 ;;
            --package-mirror) package_mirror=${2:?missing value}; shift 2 ;;
            --authorized-key|--ssh-key) authorized_key_literal=${2:?missing value}; shift 2 ;;
            --authorized-key-file) authorized_key_file=${2:?missing value}; shift 2 ;;
            --authorized-keys-url) authorized_keys_url=${2:?missing value}; shift 2 ;;
            --disk) disk=${2:?missing value}; shift 2 ;;
            --hostname) hostname=${2:?missing value}; shift 2 ;;
            --timezone) timezone=${2:?missing value}; shift 2 ;;
            --interface) requested_interface=${2:?missing value}; shift 2 ;;
            --ip) requested_ip=${2:?missing value}; shift 2 ;;
            --netmask) requested_netmask=${2:?missing value}; shift 2 ;;
            --gateway) requested_gateway=${2:?missing value}; shift 2 ;;
            --static-ipv4) shift ;;
            --dns) dns=${2:?missing value}; shift 2 ;;
            --ntp) ntp=${2:?missing value}; shift 2 ;;
            --ssh-port) ssh_port=${2:?missing value}; shift 2 ;;
            --bbr) bbr=true; shift ;;
            --fail2ban) fail2ban=true; shift ;;
            --no-fail2ban) fail2ban=false; shift ;;
            --firmware) firmware=true; shift ;;
            --no-firmware) firmware=false; shift ;;
            --cloud-kernel) kernel=linux-lts; firmware=false; shift ;;
            --ethx) ethx=true; shift ;;
            --predictable-names|--no-ethx) ethx=false; shift ;;
            --network-console) shift ;;
            --kernel) kernel=${2:?missing value}; shift 2 ;;
            --extra-packages|--install) extra_packages=${2:?missing value}; shift 2 ;;
            --swap-mib) swap_mib=${2:?missing value}; shift 2 ;;
            --boot-mode) boot_mode=${2:?missing value}; shift 2 ;;
            --bios) boot_mode=bios; shift ;;
            --efi) boot_mode=efi; shift ;;
            --grub-timeout) grub_timeout=${2:?missing value}; shift 2 ;;
            --install-dir) install_dir=${2:?missing value}; shift 2 ;;
            --hold) hold=true; shift ;;
            --power-off) power_off=true; shift ;;
            --reboot) reboot_now=true; shift ;;
            --yes) assume_yes=true; shift ;;
            --no-reboot) reboot_now=false; shift ;;
            --force-low-memory) force_low_memory=true; shift ;;
            --force-lowmem)
                [[ ${2:-} == 0 || ${2:-} == 1 || ${2:-} == 2 ]] ||
                    die '--force-lowmem must be 0, 1, or 2'
                [[ $2 != 0 ]] && force_low_memory=true
                shift 2
                ;;
            --dry-run) dry_run=true; shift ;;
            --cleanup) cleanup=true; shift ;;
            --version) printf '%s\n' "$ARCHI_VERSION"; return 0 ;;
            --help|-h) usage; return 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    if [[ $cleanup == true ]]; then
        cleanup_stage "$install_dir"
        return 0
    fi

    [[ $(id -u) -eq 0 ]] || die 'Staging requires root'
    [[ $(uname -m) == x86_64 ]] || die 'Only x86_64 is currently supported'
    need_cmd base64
    need_cmd curl
    need_cmd findmnt
    need_cmd grub-install
    need_cmd ip
    need_cmd lsblk
    need_cmd sha256sum
    need_cmd stat

    alpine_mirror=$(trim_trailing_slash "$alpine_mirror")
    package_mirror=$(trim_trailing_slash "$package_mirror")
    validate_url '--alpine-mirror' "$alpine_mirror"
    validate_url '--package-mirror' "$package_mirror"
    local authorized_key_tmp=''
    if [[ -z $authorized_key_literal && -n $authorized_keys_url ]]; then
        validate_url '--authorized-keys-url' "$authorized_keys_url"
        authorized_key_tmp=$(mktemp)
        trap 'rm -f -- "${authorized_key_tmp:-}"' EXIT
        download_file "$authorized_keys_url" "$authorized_key_tmp" 40
        authorized_key_file=$authorized_key_tmp
    fi
    [[ -n $authorized_key_literal || -n $authorized_key_file ]] ||
        die 'Provide --authorized-key, --authorized-key-file, or --authorized-keys-url'
    validate_hostname "$hostname"
    validate_packages "$extra_packages"
    validate_port "$ssh_port"
    [[ $ntp =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || die "Invalid NTP host: $ntp"
    [[ $requested_interface == auto || $requested_interface =~ ^[A-Za-z0-9_.:-]+$ ]] ||
        die "Invalid interface name: $requested_interface"
    [[ $kernel == linux || $kernel == linux-lts ]] || die '--kernel must be linux or linux-lts'
    [[ $swap_mib =~ ^[0-9]+$ ]] || die '--swap-mib must be a non-negative integer'
    [[ $grub_timeout =~ ^[0-9]+$ && $grub_timeout -le 60 ]] ||
        die '--grub-timeout must be an integer from 0 to 60'
    [[ $boot_mode == auto || $boot_mode == bios || $boot_mode == efi ]] ||
        die '--boot-mode must be auto, bios, or efi'
    [[ $timezone != *[[:space:]\'\"\\]* ]] || die 'Invalid timezone'
    safe_install_dir "$install_dir"

    if [[ -z $disk ]]; then disk=$(detect_root_disk); fi
    [[ $disk == /dev/* ]] || die 'Target disk must be under /dev'
    [[ -b $disk ]] || die "Target disk is not a block device: $disk"
    [[ $(lsblk -ndo TYPE "$disk") == disk ]] || die "Target is not a whole disk: $disk"

    if [[ $boot_mode == auto ]]; then
        if [[ -d /sys/firmware/efi ]]; then boot_mode=efi; else boot_mode=bios; fi
    fi

    local mem_kib
    mem_kib=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    if (( mem_kib < 384000 )) && [[ $force_low_memory != true ]]; then
        die "Only $((mem_kib / 1024)) MiB RAM detected; the Alpine installer needs about 384 MiB. Use --force-low-memory to override"
    elif (( mem_kib < 524288 )); then
        warn "Only $((mem_kib / 1024)) MiB RAM detected; the Alpine installer may run out of memory"
    fi

    local authorized_key
    if [[ -n $authorized_key_literal ]]; then
        authorized_key=$(first_public_key_text "$authorized_key_literal")
        [[ -n $authorized_key ]] || die 'No supported SSH public key found in --authorized-key'
    else
        authorized_key=$(first_public_key "$authorized_key_file")
        [[ -n $authorized_key ]] || die "No supported SSH public key found in $authorized_key_file"
    fi

    local boot_interface bootif
    read -r boot_interface bootif < <(detect_bootif "$requested_interface")
    bootif=${bootif^^}
    if [[ -z $dns ]]; then
        dns=$(detect_dns_servers "$boot_interface")
        [[ -n ${dns//[[:space:]]/} ]] || dns='1.1.1.1 1.0.0.1'
    fi
    dns=$(awk '{$1=$1; print}' <<< "$dns")
    validate_dns_servers "$dns"

    local boot_cidr boot_gateway
    boot_cidr=$(ip -4 -o address show dev "$boot_interface" scope global 2>/dev/null |
        awk 'NR == 1 { print $4 }')
    boot_gateway=$(ip -4 route show default dev "$boot_interface" 2>/dev/null | awk '
        { for (i = 1; i <= NF; i++) if ($i == "via") { print $(i + 1); exit } }
    ')
    if [[ -n $requested_ip ]]; then
        if [[ $requested_ip == */* ]]; then
            local requested_address=${requested_ip%/*} requested_prefix=${requested_ip#*/}
            is_ipv4 "$requested_address" || die "Invalid static IPv4 address: $requested_address"
            if ! [[ $requested_prefix =~ ^[0-9]+$ ]] || ! (( 10#$requested_prefix <= 32 )); then
                die "Invalid IPv4 prefix: $requested_prefix"
            fi
            boot_cidr=$requested_ip
        else
            is_ipv4 "$requested_ip" || die "Invalid static IPv4 address: $requested_ip"
            [[ -n $requested_netmask ]] || die '--ip without CIDR requires --netmask'
            boot_cidr="$requested_ip/$(netmask_to_prefix "$requested_netmask")"
        fi
    elif [[ -n $requested_netmask ]]; then
        die '--netmask requires --ip'
    fi
    if [[ -n $requested_gateway ]]; then
        is_ipv4 "$requested_gateway" || die "Invalid IPv4 gateway: $requested_gateway"
        boot_gateway=$requested_gateway
    fi
    [[ $boot_cidr == */* && -n $boot_gateway ]] ||
        warn 'A complete static IPv4 configuration was not found; Alpine will use DHCP'
    local boot_network
    boot_network=$(build_boot_network_parameter "$boot_interface" 'alpine' "$dns" "$bootif" \
        "$boot_cidr" "$boot_gateway")

    local payload_sha
    payload_sha=$(sha256sum "${BASH_SOURCE[0]}" | awk '{print $1}')

    local netboot_url kernel_url initramfs_url modloop_url apk_main_url apk_community_url core_url extra_url
    netboot_url="$alpine_mirror/latest-stable/releases/x86_64/netboot"
    kernel_url="$netboot_url/vmlinuz-virt"
    initramfs_url="$netboot_url/initramfs-virt"
    modloop_url="$netboot_url/modloop-virt"
    apk_main_url="$alpine_mirror/latest-stable/main/x86_64/APKINDEX.tar.gz"
    apk_community_url="$alpine_mirror/latest-stable/community/x86_64/APKINDEX.tar.gz"
    core_url=${package_mirror//\$repo/core}
    core_url=${core_url//\$arch/x86_64}
    core_url="$core_url/core.db"
    extra_url=${package_mirror//\$repo/extra}
    extra_url=${extra_url//\$arch/x86_64}
    extra_url="$extra_url/extra.db"

    probe_url 'Alpine virt kernel' "$kernel_url"
    probe_url 'Alpine virt initramfs' "$initramfs_url"
    probe_url 'Alpine virt modloop' "$modloop_url"
    probe_url 'Alpine main APKINDEX' "$apk_main_url"
    probe_url 'Alpine community APKINDEX' "$apk_community_url"
    probe_url 'pacman core repository' "$core_url"
    probe_url 'pacman extra repository' "$extra_url"

    cat <<EOF
[archi] Installation plan
  target disk:       $disk (WILL BE ERASED AFTER REBOOT)
  boot mode:         $boot_mode
  hostname:          $hostname
  installer hostname: alpine
  timezone:          $timezone
  NTP:               $ntp
  Alpine mirror:     $alpine_mirror
  package mirror:    $package_mirror
  boot interface:    $boot_interface (${bootif#01-})
  boot network:      $boot_network
  DNS servers:       $dns
  payload SHA-256:   $payload_sha
  root SSH key:      $(printf '%s' "$authorized_key" | awk '{if (NF >= 3) print $1, $3; else print $1, "(no comment)"}')
  SSH port:          $ssh_port
  kernel package:    $kernel
  firmware bundle:   $firmware
  TCP BBR:           $bbr
  Fail2ban:          $fail2ban
  eth0 naming:       $ethx
  swap:              ${swap_mib} MiB
  GRUB timeout:      ${grub_timeout}s
  extra packages:    ${extra_packages:-none}
  hold before wipe:  $hold
  reboot after stage: $reboot_now
  stage directory:   $install_dir
EOF
    if [[ $dry_run == true ]]; then
        log 'Dry run completed; no files or boot settings were changed'
        return 0
    fi

    need_cmd cpio
    need_cmd find
    need_cmd gzip
    mkdir -p -- "$install_dir"
    need_cmd tar
    download_file "$kernel_url" "$install_dir/vmlinuz-virt" 5000000
    download_file "$initramfs_url" "$install_dir/initramfs-virt.official" 3000000
    build_alpine_initramfs "$install_dir/initramfs-virt.official" \
        "$install_dir/initramfs-virt" "$authorized_key" 'alpine' "$ssh_port" "$dns" \
        "$alpine_mirror"
    rm -f -- "$install_dir/initramfs-virt.official"

    local disk_b64 hostname_b64 timezone_b64 dns_b64 key_b64 package_mirror_b64
    local extra_packages_b64 kernel_b64 ntp_b64
    disk_b64=$(encode_b64 "$disk")
    hostname_b64=$(encode_b64 "$hostname")
    timezone_b64=$(encode_b64 "$timezone")
    dns_b64=$(encode_b64 "$dns")
    key_b64=$(encode_b64 "$authorized_key")
    package_mirror_b64=$(encode_b64 "$package_mirror")
    extra_packages_b64=$(encode_b64 "$extra_packages")
    kernel_b64=$(encode_b64 "$kernel")
    ntp_b64=$(encode_b64 "$ntp")

    local boot_mac dns_csv
    boot_mac=${bootif#01-}
    boot_mac=${boot_mac//-/:}
    boot_mac=${boot_mac,,}
    dns_csv=${dns// /,}
    if [[ $boot_cidr != */* || -z $boot_gateway ]]; then
        boot_cidr=''
        boot_gateway=''
    fi

    local grub_prefix grub_stage_dir grub_kernel grub_initramfs hold_flag power_flag
    if mountpoint -q /boot; then
        grub_prefix=''
    else
        grub_prefix='/boot'
    fi
    grub_stage_dir=${install_dir#/boot}
    grub_kernel="$grub_prefix$grub_stage_dir/vmlinuz-virt"
    grub_initramfs="$grub_prefix$grub_stage_dir/initramfs-virt"
    hold_flag=0; [[ $hold == true ]] && hold_flag=1
    power_flag=0; [[ $power_off == true ]] && power_flag=1

    cat > "$install_dir/manifest" <<EOF
ARCHI_PAYLOAD_ID=$ARCHI_PAYLOAD_ID
version=$ARCHI_VERSION
created=$(date -Is)
disk=$disk
boot_mode=$boot_mode
boot_interface=$boot_interface
bootif=$bootif
boot_network=$boot_network
alpine_mirror=$alpine_mirror
package_mirror=$package_mirror
hostname=$hostname
timezone=$timezone
ntp=$ntp
ssh_port=$ssh_port
kernel=$kernel
firmware=$firmware
bbr=$bbr
fail2ban=$fail2ban
ethx=$ethx
grub_timeout=$grub_timeout
payload_sha256=$payload_sha
kernel_sha256=$(sha256sum "$install_dir/vmlinuz-virt" | awk '{print $1}')
initramfs_sha256=$(sha256sum "$install_dir/initramfs-virt" | awk '{print $1}')
EOF

    cat > "$GRUB_ENTRY_FILE" <<EOF
#!/bin/sh
# ARCHI_PAYLOAD_ID=archi-network-reinstall-v1
exec tail -n +4 \$0
menuentry 'Arch Linux network reinstall (ERASES TARGET DISK)' --id archi {
    insmod part_gpt
    insmod part_msdos
    insmod ext2
    linux $grub_kernel modules=loop,squashfs,sd_mod,usb_storage,virtio_scsi,virtio_blk alpine_repo=$alpine_mirror/latest-stable/main,$alpine_mirror/latest-stable/community apkovl=/archi.apkovl.tar.gz init=/root/archi-init $boot_network archi_mode=install archi_payload_sha256=$payload_sha archi_disk_b64=$disk_b64 archi_hostname_b64=$hostname_b64 archi_timezone_b64=$timezone_b64 archi_dns_b64=$dns_b64 archi_key_b64=$key_b64 archi_package_mirror_b64=$package_mirror_b64 archi_extra_packages_b64=$extra_packages_b64 archi_kernel_b64=$kernel_b64 archi_ntp_b64=$ntp_b64 archi_boot_mode=$boot_mode archi_swap_mib=$swap_mib archi_hold=$hold_flag archi_poweroff=$power_flag archi_boot_cidr=$boot_cidr archi_gateway=$boot_gateway archi_boot_mac=$boot_mac archi_dns_csv=$dns_csv archi_ssh_port=$ssh_port archi_bbr=$bbr archi_fail2ban=$fail2ban archi_firmware=$firmware archi_ethx=$ethx archi_grub_timeout=$grub_timeout
    initrd $grub_initramfs
}
EOF
    chmod 0755 "$GRUB_ENTRY_FILE"

    mkdir -p -- "$(dirname "$GRUB_DEFAULT_FILE")"
cat > "$GRUB_DEFAULT_FILE" <<EOF
# Temporary default used by archi.sh. Remove with: archi.sh --cleanup
GRUB_DEFAULT=archi
GRUB_TIMEOUT=$grub_timeout
GRUB_TIMEOUT_STYLE=menu
EOF

    update_grub_config
    local generated_grub
    if [[ -e /boot/grub2/grub.cfg ]]; then generated_grub=/boot/grub2/grub.cfg; else generated_grub=/boot/grub/grub.cfg; fi
    grep -q "menuentry 'Arch Linux network reinstall" "$generated_grub" ||
        die 'GRUB regeneration completed but the Arch reinstall entry is missing'

    sync
    log 'Arch reinstall entry is staged successfully'
    log "It remains reversible until reboot: ${BASH_SOURCE[0]} --cleanup --install-dir $install_dir"
    if [[ $reboot_now == true ]]; then
        [[ $assume_yes == true ]] || die '--reboot requires --yes because the next boot erases the target disk'
        log 'Rebooting into Alpine; the selected disk will be erased'
        systemctl reboot
    else
        log 'Run reboot when ready. The next boot will start the Arch installer.'
    fi
}

partition_path() {
    local disk=$1 number=$2
    if [[ $disk =~ [0-9]$ ]]; then printf '%sp%s' "$disk" "$number"; else printf '%s%s' "$disk" "$number"; fi
}

installer_failure() {
    local rc=$?
    trap - ERR
    warn "Installation failed with exit code $rc. Alpine is being left online for diagnosis."
    /usr/sbin/sshd >/dev/null 2>&1 || true
    sync
    exit "$rc"
}

installer_main() {
    local log_file=/tmp/archi-install.log
    exec > >(tee -a "$log_file") 2>&1
    trap installer_failure ERR

    log "Alpine installer mode, archi.sh $ARCHI_VERSION"
    [[ $ARCHI_PAYLOAD_ID == archi-network-reinstall-v1 ]] || die 'Internal payload marker mismatch'
    need_cmd arch-chroot
    need_cmd base64
    need_cmd blockdev
    need_cmd curl
    need_cmd genfstab
    need_cmd killall
    need_cmd lsblk
    need_cmd mdev
    need_cmd mkfs.ext4
    need_cmd mount
    need_cmd numfmt
    need_cmd pacstrap
    need_cmd partprobe
    need_cmd pidof
    need_cmd sgdisk
    need_cmd sha256sum
    need_cmd wipefs

    local expected_sha actual_sha
    expected_sha=$(cmdline_value archi_payload_sha256)
    actual_sha=$(sha256sum "${BASH_SOURCE[0]}" | awk '{print $1}')
    [[ $expected_sha =~ ^[0-9a-f]{64}$ && $actual_sha == "$expected_sha" ]] ||
        die "Installer payload checksum mismatch (expected $expected_sha, got $actual_sha)"

    local disk hostname timezone dns authorized_key package_mirror extra_packages kernel ntp
    local boot_mode swap_mib hold power_off boot_cidr boot_gateway boot_mac
    local ssh_port bbr fail2ban firmware ethx grub_timeout
    disk=$(decode_b64 "$(cmdline_value archi_disk_b64)")
    hostname=$(decode_b64 "$(cmdline_value archi_hostname_b64)")
    timezone=$(decode_b64 "$(cmdline_value archi_timezone_b64)")
    dns=$(decode_b64 "$(cmdline_value archi_dns_b64)")
    authorized_key=$(decode_b64 "$(cmdline_value archi_key_b64)")
    package_mirror=$(decode_b64 "$(cmdline_value archi_package_mirror_b64)")
    extra_packages=$(decode_b64 "$(cmdline_value archi_extra_packages_b64)")
    kernel=$(decode_b64 "$(cmdline_value archi_kernel_b64)")
    ntp=$(decode_b64 "$(cmdline_value archi_ntp_b64)")
    boot_mode=$(cmdline_value archi_boot_mode)
    swap_mib=$(cmdline_value archi_swap_mib)
    hold=$(cmdline_value archi_hold)
    power_off=$(cmdline_value archi_poweroff)
    boot_cidr=$(cmdline_value archi_boot_cidr || true)
    boot_gateway=$(cmdline_value archi_gateway || true)
    boot_mac=$(cmdline_value archi_boot_mac || true)
    ssh_port=$(cmdline_value archi_ssh_port)
    bbr=$(cmdline_value archi_bbr)
    fail2ban=$(cmdline_value archi_fail2ban)
    firmware=$(cmdline_value archi_firmware)
    ethx=$(cmdline_value archi_ethx)
    grub_timeout=$(cmdline_value archi_grub_timeout)

    validate_hostname "$hostname"
    validate_packages "$extra_packages"
    [[ $disk == /dev/* && -b $disk ]] || die "Target disk is unavailable: $disk"
    [[ $(lsblk -ndo TYPE "$disk") == disk ]] || die "Target is not a whole disk: $disk"
    [[ $boot_mode == bios || $boot_mode == efi ]] || die "Invalid boot mode: $boot_mode"
    [[ $boot_mode != efi ]] || need_cmd mkfs.fat
    [[ $swap_mib =~ ^[0-9]+$ ]] || die 'Invalid swap size'
    [[ $kernel == linux || $kernel == linux-lts ]] || die 'Invalid kernel package'
    validate_port "$ssh_port"
    [[ $bbr == true || $bbr == false ]] || die 'Invalid BBR setting'
    [[ $fail2ban == true || $fail2ban == false ]] || die 'Invalid Fail2ban setting'
    [[ $firmware == true || $firmware == false ]] || die 'Invalid firmware setting'
    [[ $ethx == true || $ethx == false ]] || die 'Invalid ethx setting'
    [[ $grub_timeout =~ ^[0-9]+$ && $grub_timeout -le 60 ]] || die 'Invalid GRUB timeout'
    [[ $ntp =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || die 'Invalid NTP host'
    [[ -e /usr/share/zoneinfo/$timezone ]] || die "Unknown timezone: $timezone"
    validate_url 'package mirror' "$package_mirror"

    # Staging uses umask 077, but the installed operating system must inherit
    # normal Arch directory modes. Sensitive SSH keys and logs are chmod'd
    # explicitly below.
    umask 022

    printf '%s\n' 'alpine' > /etc/hostname
    chmod 0644 /etc/hostname
    hostname alpine

    install -d -m 0700 /root/.ssh
    printf '%s\n' "$authorized_key" > /root/.ssh/authorized_keys
    chmod 0600 /root/.ssh/authorized_keys
    install -d -m 0755 /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/60-archi-key-only.conf <<EOF
Port $ssh_port
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
LoginGraceTime 30
MaxAuthTries 3
MaxStartups 10:30:30
PerSourceMaxStartups 3
X11Forwarding no
EOF
    chmod 0644 /etc/ssh/sshd_config.d/60-archi-key-only.conf
    cp -f -- "${BASH_SOURCE[0]}" /root/archi-installer.sh
    chmod 0700 /root/archi-installer.sh

    install -d -m 0755 /etc/pacman.d
    printf 'Server = %s\n' "$package_mirror" > /etc/pacman.d/mirrorlist
    local core_url
    core_url=${package_mirror//\$repo/core}
    core_url=${core_url//\$arch/x86_64}
    probe_url 'pacman core repository' "$core_url/core.db"

    cat <<EOF
[archi] Verified install plan inside Alpine
  disk:             $disk (size $(numfmt --to=iec "$(blockdev --getsize64 "$disk")"))
  boot mode:        $boot_mode
  hostname:         $hostname
  package mirror:   $package_mirror
  root SSH:         key only
  SSH port:         $ssh_port
  NTP:              $ntp
  firmware bundle:  $firmware
  TCP BBR:          $bbr
  Fail2ban:         $fail2ban
  swap:             ${swap_mib} MiB
EOF

    if [[ $hold == 1 && ${ARCHI_FORCE_INSTALL:-0} != 1 ]]; then
        log 'Hold mode is active; no disk changes were made.'
        log 'SSH is available with the supplied root key.'
        log 'To continue destructively: ARCHI_FORCE_INSTALL=1 /root/archi.sh'
        return 0
    fi

    local disk_size
    disk_size=$(blockdev --getsize64 "$disk")
    (( disk_size >= 8 * 1024 * 1024 * 1024 )) || die 'Target disk must be at least 8 GiB'
    if lsblk -nrpo MOUNTPOINT "$disk" | grep -qE '^/'; then
        die "A partition on $disk is mounted; refusing to erase it"
    fi

    log "ERASING and partitioning $disk"
    swapoff -a 2>/dev/null || true
    wipefs --all --force "$disk"
    sgdisk --zap-all "$disk"

    local boot_partition root_partition
    boot_partition=$(partition_path "$disk" 1)
    root_partition=$(partition_path "$disk" 2)
    if [[ $boot_mode == efi ]]; then
        sgdisk --new=1:1MiB:+512MiB --typecode=1:ef00 --change-name=1:EFI \
            --new=2:0:0 --typecode=2:8304 --change-name=2:ROOT "$disk"
    else
        sgdisk --new=1:1MiB:+2MiB --typecode=1:ef02 --change-name=1:BIOSBOOT \
            --new=2:0:0 --typecode=2:8304 --change-name=2:ROOT "$disk"
    fi
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        partprobe "$disk" 2>/dev/null || true
        mdev -s 2>/dev/null || true
        if [[ -b $root_partition ]] && { [[ $boot_mode != efi ]] || [[ -b $boot_partition ]]; }; then
            break
        fi
        sleep 1
    done
    [[ -b $root_partition ]] || die "Root partition did not appear: $root_partition"

    mkfs.ext4 -F -L ArchRoot "$root_partition"
    install -d /mnt
    mount "$root_partition" /mnt
    if [[ $boot_mode == efi ]]; then
        [[ -b $boot_partition ]] || die "EFI partition did not appear: $boot_partition"
        mkfs.fat -F 32 -n ARCH_EFI "$boot_partition"
        install -d /mnt/boot
        mount "$boot_partition" /mnt/boot
    fi

    local -a packages
    packages=(
        base "$kernel" grub openssh sudo qemu-guest-agent
        inetutils coreutils bash-completion wget curl vim nano cpio
    )
    [[ $fail2ban == true ]] && packages+=(fail2ban)
    [[ $firmware == true ]] && packages+=(linux-firmware)
    if [[ $boot_mode == efi ]]; then packages+=(efibootmgr); fi
    case $(awk -F: '/vendor_id/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' /proc/cpuinfo) in
        GenuineIntel) packages+=(intel-ucode) ;;
        AuthenticAMD) packages+=(amd-ucode) ;;
    esac
    local package
    for package in $extra_packages; do packages+=("$package"); done

    install -d -m 0755 /mnt/etc
    printf 'KEYMAP=us\n' > /mnt/etc/vconsole.conf
    chmod 0644 /mnt/etc/vconsole.conf

    log "Installing packages: ${packages[*]}"
    local pacstrap_ok=false
    for _ in 1 2 3; do
        if pacstrap -K -c /mnt "${packages[@]}"; then
            pacstrap_ok=true
            break
        fi
        warn 'pacstrap failed; cleaning transient state before retry'
        killall gpg-agent 2>/dev/null || true
        rm -f -- /mnt/var/lib/pacman/db.lck
        sleep 5
    done
    [[ $pacstrap_ok == true ]] || die 'pacstrap failed after three attempts'
    chmod 0755 /mnt/etc
    genfstab -U /mnt > /mnt/etc/fstab
    chmod 0644 /mnt/etc/fstab
    cp -Lf /etc/resolv.conf /mnt/etc/resolv.conf
    chmod 0644 /mnt/etc/resolv.conf

    if (( swap_mib > 0 )); then
        fallocate -l "${swap_mib}M" /mnt/swapfile
        chmod 0600 /mnt/swapfile
        mkswap /mnt/swapfile
        printf '/swapfile none swap defaults 0 0\n' >> /mnt/etc/fstab
    fi

    ln -sf "/usr/share/zoneinfo/$timezone" /mnt/etc/localtime
    arch-chroot /mnt hwclock --systohc
    sed -i -E 's/^#(en_US\.UTF-8 UTF-8)/\1/' /mnt/etc/locale.gen
    arch-chroot /mnt locale-gen
    printf 'LANG=en_US.UTF-8\n' > /mnt/etc/locale.conf
    printf '%s\n' "$hostname" > /mnt/etc/hostname
    cat > /mnt/etc/hosts <<EOF
127.0.0.1 localhost
::1 localhost
127.0.1.1 $hostname
EOF
    chmod 0644 /mnt/etc/locale.conf /mnt/etc/hostname /mnt/etc/hosts

    install -d -m 0755 /mnt/etc/modprobe.d
    cat > /mnt/etc/modprobe.d/60-archi-cloud.conf <<'EOF'
# archi.sh supports wired cloud networking only. Avoid loading the wireless
# regulatory stack and its firmware database on machines without Wi-Fi.
blacklist cfg80211
EOF
    chmod 0644 /mnt/etc/modprobe.d/60-archi-cloud.conf

    install -d -m 0755 /mnt/etc/systemd/timesyncd.conf.d
    cat > /mnt/etc/systemd/timesyncd.conf.d/60-archi-cloud.conf <<EOF
[Time]
NTP=$ntp
FallbackNTP=time.cloudflare.com time.google.com
EOF
    chmod 0644 /mnt/etc/systemd/timesyncd.conf.d/60-archi-cloud.conf

    if [[ $bbr == true ]]; then
        install -d -m 0755 /mnt/etc/sysctl.d
        cat > /mnt/etc/sysctl.d/60-archi-cloud.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
        chmod 0644 /mnt/etc/sysctl.d/60-archi-cloud.conf
    fi

    install -d -m 0755 /mnt/etc/systemd/network
    if [[ -n $boot_cidr && -n $boot_gateway && -n $boot_mac ]]; then
        cat > /mnt/etc/systemd/network/20-wired.network <<EOF
[Match]
MACAddress=$boot_mac

[Network]
Address=$boot_cidr
Gateway=$boot_gateway
IPv6AcceptRA=yes
${dns:+DNS=$dns}
EOF
    else
        cat > /mnt/etc/systemd/network/20-wired.network <<EOF
[Match]
Type=ether

[Network]
DHCP=yes
IPv6AcceptRA=yes
${dns:+DNS=$dns}
EOF
    fi
    chmod 0644 /mnt/etc/systemd/network/20-wired.network
    arch-chroot /mnt systemctl enable systemd-networkd.service systemd-resolved.service \
        systemd-timesyncd.service sshd.service

    install -d -m 0700 /mnt/root/.ssh
    printf '%s\n' "$authorized_key" > /mnt/root/.ssh/authorized_keys
    chmod 0600 /mnt/root/.ssh/authorized_keys
    install -d -m 0755 /mnt/etc/ssh/sshd_config.d
    cat > /mnt/etc/ssh/sshd_config.d/60-key-only.conf <<EOF
Port $ssh_port
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
LoginGraceTime 30
MaxAuthTries 3
MaxStartups 10:30:30
PerSourceMaxStartups 3
X11Forwarding no
EOF
    chmod 0644 /mnt/etc/ssh/sshd_config.d/60-key-only.conf
    arch-chroot /mnt passwd --lock root

    if [[ $fail2ban == true ]]; then
        install -d -m 0755 /mnt/etc/fail2ban/jail.d
        cat > /mnt/etc/fail2ban/jail.d/sshd.local <<EOF
[DEFAULT]
backend = systemd
banaction = nftables-multiport
banaction_allports = nftables-allports
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port = $ssh_port
mode = aggressive
EOF
        chmod 0644 /mnt/etc/fail2ban/jail.d/sshd.local
        arch-chroot /mnt fail2ban-client -t
        arch-chroot /mnt systemctl enable fail2ban.service
    fi

    if [[ $boot_mode == efi ]]; then
        arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot \
            --bootloader-id=ARCH --removable --no-nvram
    else
        arch-chroot /mnt grub-install --target=i386-pc --recheck "$disk"
    fi
    sed -i -E \
        -e "s/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=$grub_timeout/" \
        -e 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' \
        /mnt/etc/default/grub
    if grep -qE '^#?GRUB_DISABLE_OS_PROBER=' /mnt/etc/default/grub; then
        sed -i -E 's/^#?GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=true/' \
            /mnt/etc/default/grub
    else
        printf '\nGRUB_DISABLE_OS_PROBER=true\n' >> /mnt/etc/default/grub
    fi
    if [[ $ethx == true ]]; then
        install -d -m 0755 /mnt/etc/udev/rules.d
        ln -sfn /dev/null /mnt/etc/udev/rules.d/80-net-setup-link.rules
    fi
    arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
    arch-chroot /mnt mkinitcpio -P

    if [[ -x /mnt/usr/bin/qemu-ga ]]; then
        arch-chroot /mnt systemctl enable qemu-guest-agent.service
    fi
    ln -sfn /run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf

    cp -f -- "$log_file" /mnt/root/archi-install.log
    cp -f -- "${BASH_SOURCE[0]}" /mnt/root/archi.sh
    chmod 0600 /mnt/root/archi-install.log
    chmod 0700 /mnt/root/archi.sh
    killall gpg-agent 2>/dev/null || true
    local agents_stopped=false
    for _ in 1 2 3 4 5; do
        if ! pidof gpg-agent >/dev/null 2>&1; then
            agents_stopped=true
            break
        fi
        sleep 1
    done
    if [[ $agents_stopped != true ]]; then
        warn 'Temporary gpg-agent did not stop after SIGTERM; sending SIGKILL'
        killall -9 gpg-agent 2>/dev/null || true
        sleep 1
    fi
    pidof gpg-agent >/dev/null 2>&1 && die 'Temporary gpg-agent is still running'
    sync
    local target unmounted
    for target in /mnt/boot /mnt; do
        grep -qsE "[[:space:]]${target}[[:space:]]" /proc/mounts || continue
        unmounted=false
        for _ in 1 2 3 4 5; do
            if umount "$target"; then
                unmounted=true
                break
            fi
            sleep 1
        done
        [[ $unmounted == true ]] || die "$target remained busy after five unmount attempts"
    done
    log 'Arch Linux installation completed successfully'

    trap - ERR
    if [[ $power_off == 1 ]]; then
        poweroff -f
    else
        reboot -f
    fi
}

if is_install_environment; then
    installer_main "$@"
else
    stage_main "$@"
fi
