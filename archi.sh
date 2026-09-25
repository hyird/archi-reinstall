#!/bin/sh
# archi.sh - Alpine-staged, unattended Arch Linux pacstrap reinstall
#
# The same file has two modes:
#   1. On the existing Linux system it stages Alpine's official virt netboot
#      kernel/initramfs and creates a one-time GRUB entry.
#   2. An embedded apkovl installs only official Alpine packages, starts SSH,
#      and runs this exact file to pacstrap a pure Arch system to the target.

set -eu
umask 077

# Functions use POSIX subshell bodies where variable isolation is required.

readonly ARCHI_PAYLOAD_ID='archi-network-reinstall-v1'
readonly ARCHI_VERSION='0.13.0'
readonly ARCHI_RAW_URL='https://raw.githubusercontent.com/hyird/archi-reinstall/main/archi.sh'
ARCHI_SOURCE_FILE=$0
readonly DEFAULT_ALPINE_MIRROR='https://dl-cdn.alpinelinux.org/alpine'
# The pacman placeholders must remain literal until the installer writes mirrorlist.
readonly DEFAULT_PACKAGE_MIRROR="https://geo.mirror.pkgbuild.com/\$repo/os/\$arch"
readonly TUNA_ALPINE_MIRROR='https://mirrors.tuna.tsinghua.edu.cn/alpine'
readonly TUNA_PACKAGE_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/archlinux/\$repo/os/\$arch"
readonly USTC_ALPINE_MIRROR='https://mirrors.ustc.edu.cn/alpine'
readonly USTC_PACKAGE_MIRROR="https://mirrors.ustc.edu.cn/archlinux/\$repo/os/\$arch"
readonly ALIYUN_ALPINE_MIRROR='https://mirrors.aliyun.com/alpine'
readonly ALIYUN_PACKAGE_MIRROR="https://mirrors.aliyun.com/archlinux/\$repo/os/\$arch"
readonly TENCENT_ALPINE_MIRROR='https://mirrors.cloud.tencent.com/alpine'
readonly TENCENT_PACKAGE_MIRROR="https://mirrors.cloud.tencent.com/archlinux/\$repo/os/\$arch"
readonly DEFAULT_INSTALL_DIR='/boot/archi-reinstall'
# Everything the installer needs travels inside the apkovl instead of on the
# kernel command line. x86_64 truncates /proc/cmdline at COMMAND_LINE_SIZE
# (2048 bytes) without a word of warning, and a base64 RSA-4096 authorized key
# alone pushed the old single-line form past 2200 bytes: the tail options went
# missing and the installer died in Alpine with an unrelated-looking error.
# It also keeps the root password hash out of world-readable /proc/cmdline.
readonly ARCHI_CONFIG_FILE='/etc/archi/config'
# Legacy staging paths, still removed by --cleanup so that an entry staged by an
# older version can be undone by a newer one.
readonly GRUB_ENTRY_FILE='/etc/grub.d/42_archi_reinstall'
readonly GRUB_DEFAULT_FILE='/etc/default/grub.d/zz-archi-reinstall.cfg'

log() (
    printf '[archi] %s\n' "$*"
)

warn() (
    printf '[archi] WARNING: %s\n' "$*" >&2
)

# Deliberately not a subshell body: from inside "( )" the exit would only leave
# die itself, and whether the caller then stopped depended on set -e still being
# armed -- which it is not on either side of an || list or inside a condition.
# As a brace function the exit leaves the enclosing shell, so "cmd || die msg"
# aborts in every context.
die() {
    printf '[archi] ERROR: %s\n' "$*" >&2
    exit 1
}

usage() (
    {
        printf 'Usage:\n'
        printf '  archi.sh [options]\n'
        printf '  archi.sh --cleanup\n'
        printf '\n'
        printf 'Options:\n'
        printf '  --ssh-key "ssh-ed25519 AAAA..."\n'
        printf '                               Root SSH public key, file path, or URL.\n'
        printf '  --password '\''Archi-2026!'\''     Root password.\n'
        printf '  --password-file /root/pw     Read the root password from a file instead, so\n'
        printf '                               that it stays out of the shell history and ps.\n'
        printf '  --disk /dev/vda              Whole target disk.\n'
        printf '  --hostname arch              Installed hostname (default: arch).\n'
        printf '  --timezone Asia/Shanghai     Installed timezone (default: Asia/Shanghai).\n'
        printf '  --iface eth0                 Boot interface (default: the default route).\n'
        printf '  --ip 192.0.2.10/24           Override the inherited static IPv4 address.\n'
        printf '  --gateway 192.0.2.1          Override the inherited IPv4 gateway.\n'
        printf '  --dns 1.1.1.1                DNS servers (default: inherit, else 1.1.1.1).\n'
        printf '  --ntp time.cloudflare.com    NTP host (default: time.cloudflare.com).\n'
        printf '  --port 22                    SSH port (default: 22).\n'
        printf '  --install "git htop"         Install extra official packages.\n'
        printf '  --kernel linux               Kernel package: linux (default) or linux-lts.\n'
        printf '  --firmware                   Install firmware even in a virtual machine.\n'
        printf '  --boot-mode efi              Force bios or efi instead of autodetecting.\n'
        printf '  --grub-timeout 5             Installed GRUB menu timeout in seconds.\n'
        printf '  --log-days 15                Days of systemd journal to keep (default: 0,\n'
        printf '                               0 leaves journald'\''s own defaults).\n'
        printf '  --ethx, --no-ethx            Force eth0 names or keep predictable names (default).\n'
        printf '  --bbr, --no-bbr              Enable TCP BBR or leave defaults (default).\n'
        printf '  --fail2ban, --no-fail2ban    Enable or omit the SSH jail (default).\n'
        printf '  --swap 1024                  Swap file size in MiB (default: 0, disabled).\n'
        printf '  --mirror https://mirrors.cloud.tencent.com/archlinux\n'
        printf '                               Arch mirror root; repository path is appended.\n'
        printf '  --alpine-mirror https://dl-cdn.alpinelinux.org/alpine\n'
        printf '                               Alpine mirror root for the temporary environment.\n'
        printf '  --tuna, --ustc, --aliyun     Use a regional mirror preset.\n'
        printf '  --tencent                    Use the Tencent Cloud mirror preset.\n'
        printf '  --hold 1                     Boot Alpine with SSH, but do not wipe.\n'
        printf '  --hold 2                     Install Arch, but stay in Alpine with /mnt mounted.\n'
        printf '  --dry-run                    Validate and print the plan without changing files.\n'
        printf '  --cleanup                    Remove the staged GRUB entry and downloaded files.\n'
        printf '  --help                       Show this help.\n'
        printf '  --version                    Show script version.\n'
        printf '\n'
        printf 'Requires x86_64, GRUB 2, wired IPv4 and root access. The target disk is erased.\n'
    }
)

need_cmd() (
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
)

trim_trailing_slash() (
    value=$1
    while [ "${value%/}" != "$value" ]; do value=${value%/}; done
    printf '%s' "$value"
)

validate_url() (
    name=$1 value=$2
    case $value in
        http://*|https://*) ;;
        *) die "$name must use HTTP or HTTPS" ;;
    esac
    case $value in
        *[[:space:]]*|*';'*|*'"'*|*"'"*|*\\*) die "$name contains unsafe characters" ;;
    esac
)

validate_hostname() (
    printf '%s\n' "$1" | LC_ALL=C grep -Eq \
        '^[A-Za-z0-9]([A-Za-z0-9.-]{0,61}[A-Za-z0-9])?$' ||
        die "Invalid hostname: $1"
)

validate_packages() (
    # A leading hyphen has to be rejected rather than merely allowed inside the
    # name: the list is expanded with "set --" and handed to pacstrap, where a
    # token such as -U or --noconfirm would be parsed as an option.
    printf '%s\n' "$1" | LC_ALL=C awk '
        {
            for (i = 1; i <= NF; i++) {
                if ($i !~ /^[A-Za-z0-9@._+][A-Za-z0-9@._+-]*$/) exit 1
            }
        }
    ' || die 'Extra packages contain an invalid package name'
)

is_uint() (
    case ${1-} in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
)

# Spelled out field by field rather than with an /(...){3}/ interval: mawk is
# the default awk on Debian and did not support interval expressions before
# 1.3.4-20240123, where the regex silently never matches and every address is
# rejected.
is_ipv4() (
    printf '%s\n' "$1" | LC_ALL=C awk -F. '
        NF != 4 { exit 1 }
        {
            for (i = 1; i <= 4; i++) {
                if ($i !~ /^[0-9]+$/ || length($i) > 3 || $i + 0 > 255) exit 1
            }
        }
    '
)

validate_dns_servers() (
    servers=$1 server='' count=0
    # The list was validated as whitespace-separated words by the caller.
    # shellcheck disable=SC2086
    for server in $servers; do
        is_ipv4 "$server" || die "Invalid IPv4 DNS server list: $servers"
        count=$((count + 1))
    done
    [ "$count" -gt 0 ] || die 'At least one IPv4 DNS server is required'
)

validate_port() (
    if ! is_uint "$1" || [ "${#1}" -gt 5 ] || [ "$1" -lt 1 ] || [ "$1" -gt 65535 ]; then
        die "Invalid SSH port: $1"
    fi
)

validate_ntp_host() (
    printf '%s\n' "$1" | LC_ALL=C grep -Eq \
        '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' || die "Invalid NTP host: $1"
)

validate_timezone() (
    case $1 in
        *[[:space:]]*|*"'"*|*'"'*|*\\*|*/../*|../*|*/..) die "Invalid timezone: $1" ;;
    esac
)

# Length is checked before the numeric comparison so that a caller cannot feed
# an arbitrarily long digit string into the shell's integer arithmetic.
validate_uint_range() (
    name=$1 value=$2 maximum=$3
    is_uint "$value" && [ "${#value}" -le "${#maximum}" ] && [ "$value" -le "$maximum" ] ||
        die "$name must be an integer from 0 to $maximum"
)

# Not every host has an openssl new enough for -6, and minimal cloud images may
# not have openssl at all, so fall back the way reinstall.sh does.
hash_password() (
    password=$1 hash=''
    if command -v openssl >/dev/null 2>&1 &&
        openssl passwd --help 2>&1 | LC_ALL=C grep -q -- '-6'; then
        hash=$(printf '%s' "$password" | openssl passwd -6 -stdin)
    elif command -v busybox >/dev/null 2>&1 &&
        busybox mkpasswd --help 2>&1 | LC_ALL=C grep -qw sha512; then
        hash=$(printf '%s' "$password" | busybox mkpasswd -m sha512)
    elif command -v mkpasswd >/dev/null 2>&1 &&
        mkpasswd -m help 2>&1 | LC_ALL=C grep -qw sha-512; then
        hash=$(printf '%s' "$password" | mkpasswd -m sha-512 --stdin)
    else
        die 'No usable SHA-512 password hasher found; install openssl or whois'
    fi
    case $hash in
        "\$6\$"*) printf '%s\n' "$hash" ;;
        *) die 'Could not hash the root password' ;;
    esac
)

# The same block is needed for the apkovl, for the running Alpine, and for the
# installed system; keeping one copy keeps them from drifting apart.
write_sshd_config() (
    path=$1 port=$2 permit_root_login=$3 password_auth=$4
    {
        printf 'Port %s\n' "$port"
        printf 'PermitRootLogin %s\n' "$permit_root_login"
        printf 'PasswordAuthentication %s\n' "$password_auth"
        printf 'KbdInteractiveAuthentication no\n'
        printf 'PermitEmptyPasswords no\n'
        printf 'LoginGraceTime 30\n'
        printf 'MaxAuthTries 3\n'
        printf 'MaxStartups 10:30:30\n'
        printf 'PerSourceMaxStartups 3\n'
        printf 'X11Forwarding no\n'
    } > "$path"
    chmod 0644 "$path"
)

# Root logs in by key alone whenever a key was supplied, so that a password that
# is only there for the serial console cannot also be used over the network.
sshd_auth_mode() (
    authorized_key=$1
    if [ -n "$authorized_key" ]; then
        printf 'prohibit-password no\n'
    else
        printf 'yes yes\n'
    fi
)

encode_b64() (
    printf '%s' "$1" | base64 -w 0
)

decode_b64() (
    printf '%s' "$1" | base64 -d
)

sha256_file() (
    output=''
    output=$(sha256sum "$1") || return 1
    output=${output%% *}
    [ -n "$output" ] || return 1
    printf '%s\n' "$output"
)

cmdline_value() (
    wanted=$1
    awk -v prefix="$wanted=" '
        {
            for (i = 1; i <= NF; i++) {
                if (index($i, prefix) == 1) {
                    print substr($i, length(prefix) + 1)
                    found = 1
                    exit
                }
            }
        }
        END { if (!found) exit 1 }
    ' /proc/cmdline
)

is_install_environment() (
    [ -r /proc/cmdline ] && grep -qw 'archi_mode=install' /proc/cmdline
)

# The config file holds one key=base64 pair per line. Base64 keeps spaces,
# newlines and shell metacharacters out of the parser entirely, and splitting on
# the first '=' only means the padding of the encoded value survives intact.
config_value() (
    key=$1 value=''
    value=$(LC_ALL=C awk -v key="$key" '
        index($0, key "=") == 1 {
            print substr($0, length(key) + 2)
            found = 1
            exit
        }
        END { if (!found) exit 1 }
    ' "$ARCHI_CONFIG_FILE") || die "Missing installer configuration key: $key"
    decode_b64 "$value"
)

# Writes the staged settings that the Alpine side reads back with config_value.
write_installer_config() (
    path=$1
    shift
    : > "$path"
    chmod 0600 "$path"
    while [ "$#" -gt 0 ]; do
        printf '%s=%s\n' "$1" "$(encode_b64 "$2")" >> "$path"
        shift 2
    done
)

is_archi_install_dir() (
    install_dir=$1
    { [ -f "$install_dir/.archi-owned" ] &&
        grep -q "^$ARCHI_PAYLOAD_ID$" "$install_dir/.archi-owned"; } ||
        { [ -f "$install_dir/manifest" ] &&
        grep -q "^ARCHI_PAYLOAD_ID=$ARCHI_PAYLOAD_ID$" "$install_dir/manifest"; }
)

detect_root_disk() (
    source='' disks='' disk_count=0
    source=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    # On btrfs the source carries the subvolume, as in /dev/sda4[/root], which
    # lsblk will not accept as a device.
    source=$(printf '%s' "$source" | sed 's/\[.*$//')
    case $source in
        /dev/*)
            disks=$(lsblk -srpno NAME,TYPE "$source" 2>/dev/null |
                awk '$2 == "disk" && !seen[$1]++ { print $1 }')
            disk_count=$(printf '%s\n' "$disks" | awk 'NF { count++ } END { print count + 0 }')
            if [ "$disk_count" -eq 1 ]; then
                printf '%s\n' "$disks"
                return 0
            fi
            ;;
    esac

    # lsblk reports zram and friends as TYPE=disk, so counting them would make
    # this look ambiguous on any distribution with zram swap enabled, Fedora
    # being the common case.
    disks=$(lsblk -dpno NAME,TYPE |
        awk '$2 == "disk" && $1 !~ /^\/dev\/(zram|loop|ram|nbd|fd|dm-)[0-9]/ { print $1 }')
    disk_count=$(printf '%s\n' "$disks" | awk 'NF { count++ } END { print count + 0 }')
    [ "$disk_count" -eq 1 ] ||
        die "Could not safely determine the target disk; use --disk"
    printf '%s\n' "$disks"
)

detect_bootif() (
    requested=${1:-} interface='' interface_path='' mac='' bootif_mac=''

    if [ -n "$requested" ] && [ "$requested" != auto ]; then
        interface=$requested
    else
        interface=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '
            { for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }
        ')
    fi
    if [ -z "$interface" ]; then
        for interface_path in /sys/class/net/*; do
            [ "${interface_path##*/}" = lo ] && continue
            [ -r "$interface_path/address" ] || continue
            interface=${interface_path##*/}
            break
        done
    fi

    [ -n "$interface" ] && [ -r "/sys/class/net/$interface/address" ] ||
        die 'Could not determine the boot network interface from the default route'
    mac=$(cat "/sys/class/net/$interface/address")
    printf '%s\n' "$mac" | LC_ALL=C grep -Eq '^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$' &&
        [ "$mac" != 00:00:00:00:00:00 ] ||
        die "Invalid MAC address on boot interface $interface: $mac"
    bootif_mac=$(printf '%s' "$mac" | tr ':' '-')
    printf '%s %s\n' "$interface" "01-$bootif_mac"
)

prefix_to_netmask() (
    prefix=$1 octet='' bits='' value='' result=''
    validate_uint_range 'IPv4 prefix' "$prefix" 32
    for octet in 0 1 2 3; do
        bits=$((prefix - octet * 8))
        if [ "$bits" -ge 8 ]; then
            value=255
        elif [ "$bits" -le 0 ]; then
            value=0
        else
            case $bits in
                1) value=128 ;;
                2) value=192 ;;
                3) value=224 ;;
                4) value=240 ;;
                5) value=248 ;;
                6) value=252 ;;
                7) value=254 ;;
            esac
        fi
        result=$result${result:+.}$value
    done
    printf '%s\n' "$result"
)

detect_dns_servers() (
    interface=$1 resolver_file=''
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
            [ -r "$resolver_file" ] && awk '$1 == "nameserver" { print $2 }' "$resolver_file"
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
)

# The caller has always resolved the addressing already, first from the running
# system and then from --ip and --gateway, so this takes the result rather than
# probing a second time and re-deriving the same answer.
build_boot_network_parameter() (
    hostname=$1 dns=$2 bootif=$3 cidr=$4 gateway=$5
    address='' prefix='' netmask='' dns0='' dns1=''
    case $cidr in
        */*)
            if [ -n "$gateway" ]; then
                address=${cidr%/*}
                prefix=${cidr#*/}
                netmask=$(prefix_to_netmask "$prefix")
                # DNS was validated as space-separated IPv4 literals.
                # shellcheck disable=SC2086
                set -- $dns
                dns0=${1-}
                dns1=${2-}
                [ -n "$dns0" ] || dns0=$gateway
                # Alpine follows the kernel ip= client:server:gateway:mask:host:dev:
                # autoconf:dns0:dns1 form. BOOTIF makes this survive interface renames.
                printf 'ip=%s::%s:%s:%s::none:%s:%s BOOTIF=%s\n' \
                    "$address" "$gateway" "$netmask" "$hostname" "$dns0" "$dns1" "$bootif"
                return 0
            fi
            ;;
    esac
    printf 'ip=dhcp BOOTIF=%s\n' "$bootif"
)

build_alpine_initramfs() (
    original=$1 destination=$2 authorized_key=$3 hostname=$4 ssh_port=$5 dns=$6
    alpine_mirror=$7 password_hash=$8 source_file=$9 config_file=${10}
    work='' apkovl='' overlay='' apkovl_archive='' overlay_archive='' overlay_cpio='' archive_list=''
    apk_index='' apk_package='' apk_version='' package_root='' early_password_hash=''
    dns_server='' shadow_last_change=''
    permit_root_login='' password_auth='' shadow_password='*'
    # sshd_auth_mode emits exactly two whitespace-free fields.
    # shellcheck disable=SC2046
    set -- $(sshd_auth_mode "$authorized_key")
    permit_root_login=$1 password_auth=$2
    [ -z "$password_hash" ] || shadow_password=$password_hash
    work=$(mktemp -d)
    trap 'rm -rf -- "$work"' 0
    trap 'exit 129' 1
    trap 'exit 130' 2
    trap 'exit 143' 15
    shadow_last_change=$(($(date +%s) / 86400))
    apkovl=$work/apkovl
    overlay=$work/overlay
    apkovl_archive=$overlay/archi.apkovl.tar.gz
    overlay_archive=$work/archi-overlay.img
    overlay_cpio=$work/archi-overlay.cpio
    archive_list=$work/archi-overlay.list
    mkdir -p -- "$overlay" "$apkovl/etc/apk" "$apkovl/etc/ssh/sshd_config.d" \
        "$apkovl/etc/archi" "$apkovl/root/.ssh"

    # The regular sshd starts as soon as Alpine switches to archi-init. Keep a
    # small SSH server in the initramfs too: if Alpine fails before switch_root,
    # there must still be a way to read its diagnostics remotely.
    apk_index=$work/APKINDEX.tar.gz
    package_root=$work/early-ssh-packages
    mkdir -p -- "$package_root" "$overlay/usr/bin" "$overlay/usr/sbin" \
        "$overlay/usr/lib" "$overlay/archi-early-auth" "$overlay/root/.ssh"
    download_file "$alpine_mirror/latest-stable/main/x86_64/APKINDEX.tar.gz" "$apk_index" 1000
    for apk_package in dropbear utmps-libs skalibs-libs; do
        apk_version=$(tar -xzOf "$apk_index" APKINDEX | awk -v pkg="$apk_package" \
            '$0 == "P:" pkg { found=1; next } found && /^V:/ { print substr($0, 3); exit }')
        [ -n "$apk_version" ] || die "Alpine package not found: $apk_package"
        download_file "$alpine_mirror/latest-stable/main/x86_64/$apk_package-$apk_version.apk" \
            "$work/$apk_package.apk" 1000
        tar -xzf "$work/$apk_package.apk" -C "$package_root"
    done
    cp -a -- "$package_root/usr/bin/dropbearkey" "$overlay/usr/bin/"
    cp -a -- "$package_root/usr/sbin/dropbear" "$overlay/usr/sbin/"
    cp -a -- "$package_root/usr/lib"/libutmps.so.* "$overlay/usr/lib/"
    cp -a -- "$package_root/usr/lib"/libskarnet.so.* "$overlay/usr/lib/"
    gzip -dc "$original" | cpio --quiet -i --to-stdout init > "$work/official-init"
    [ -s "$work/official-init" ] || die 'Could not read Alpine initramfs init'
    grep -q '^# early console?$' "$work/official-init" ||
        die 'Alpine initramfs network hook changed; refusing an unsafe patch'
    grep -q '^# switch over to new root$' "$work/official-init" ||
        die 'Alpine initramfs switch_root hook changed; refusing an unsafe patch'
    grep -q '^exec switch_root ' "$work/official-init" ||
        die 'Alpine initramfs switch_root command changed; refusing an unsafe patch'
    awk '
        /^# early console\?$/ {
            print "# Keep PID 1 alive if Alpine setup fails before switch_root."
            print "trap '\''archi_rc=$?; trap - EXIT; echo \"[archi] initramfs setup failed (exit $archi_rc); early SSH remains available.\" > /dev/console; while :; do sleep 60; done'\'' EXIT"
            print "[ ! -x /archi-early-ssh ] || /archi-early-ssh"
        }
        /^# switch over to new root$/ {
            print "# The old initramfs account files disappear at switch_root. Stop"
            print "# its listener before the new root starts OpenSSH on the same port."
            print "if [ -f /run/archi-early-ssh.pid ]; then"
            print "    kill \"$(cat /run/archi-early-ssh.pid)\" 2>/dev/null || true"
            print "fi"
            print "if [ -f /tmp/archi-early-ssh.log ]; then"
            print "    mkdir -p \"$sysroot/tmp\""
            print "    cp /tmp/archi-early-ssh.log \"$sysroot/tmp/archi-early-ssh.log\""
            print "fi"
        }
        /^exec switch_root / { after_switch=1 }
        after_switch && /^\[ "\$KOPT_splash" != "no" \]/ {
            print "# switch_root failed; restore early SSH for remote diagnosis."
            print "[ ! -x /archi-early-ssh ] || /archi-early-ssh"
            after_switch=0
        }
        { print }
        END {
            print "# Never let PID 1 exit after a failed switch_root or recovery shell."
            print "echo \"[archi] switch_root failed; initramfs SSH remains available.\""
            print "while :; do sleep 60; done"
        }
    ' \
        "$work/official-init" > "$overlay/init"
    chmod 0755 "$overlay/init"

    # The single list archi-init hands to "apk add". An /etc/apk/world of our
    # own used to sit next to it: init=/root/archi-init means OpenRC never runs
    # and never acts on world, but "apk add" solves against it, so the two lists
    # silently had to agree -- and they no longer did. The netboot image already
    # ships a correct world, so overriding it buys nothing.
    # coreutils is listed for numfmt even though arch-install-scripts pulls it.
    {
        printf 'arch-install-scripts\n'
        printf 'archlinux-keyring\n'
        printf 'bash\n'
        printf 'ca-certificates\n'
        printf 'coreutils\n'
        printf 'curl\n'
        printf 'dosfstools\n'
        printf 'e2fsprogs\n'
        printf 'findmnt\n'
        printf 'gnupg\n'
        printf 'grub\n'
        printf 'lsblk\n'
        printf 'mount\n'
        printf 'openssh\n'
        printf 'parted\n'
        printf 'tzdata\n'
        printf 'util-linux-misc\n'
        printf 'umount\n'
        printf 'virt-what\n'
        printf 'wipefs\n'
    } > "$apkovl/etc/archi/apk-packages"
    cp -f -- "$config_file" "$apkovl/etc/archi/config"
    : > "$apkovl/etc/.default_boot_services"
    printf '%s\n' "$hostname" > "$apkovl/etc/hostname"
    {
        printf 'root:x:0:0:root:/root:/bin/ash\n'
        printf 'sshd:x:22:22:sshd:/var/empty:/sbin/nologin\n'
    } > "$apkovl/etc/passwd"
    {
        printf 'root:x:0:root\n'
        printf 'wheel:x:10:root\n'
        printf 'sshd:x:22:\n'
    } > "$apkovl/etc/group"
    printf 'root:%s:%s:0:99999:7:::\n' "$shadow_password" "$shadow_last_change" > "$apkovl/etc/shadow"
    printf 'root:x:0:0:root:/root:/bin/sh\n' > "$overlay/archi-early-auth/passwd"
    cp -f -- "$apkovl/etc/group" "$overlay/archi-early-auth/group"
    early_password_hash=$shadow_password
    if [ "$early_password_hash" = '*' ]; then
        # Dropbear refuses even public-key login to a locked account. Give its
        # temporary root account an unknown password hash and disable password
        # authentication below when a key was supplied.
        early_password_hash=$(hash_password "$(head -c 32 /dev/urandom | base64)")
    fi
    printf 'root:%s:%s:0:99999:7:::\n' "$early_password_hash" "$shadow_last_change" \
        > "$overlay/archi-early-auth/shadow"
    chmod 0700 "$overlay/archi-early-auth"
    chmod 0600 "$overlay/archi-early-auth/shadow"
    # Alpine 3.24 installs alpine-base's default fstab late in initramfs-init.
    # Without our own fstab it then tries to relocate the already-consumed
    # embedded apkovl and emits misleading df/stat warnings on the console.
    : > "$apkovl/etc/fstab"
    : > "$apkovl/etc/resolv.conf"
    for dns_server in $dns; do
        printf 'nameserver %s\n' "$dns_server" >> "$apkovl/etc/resolv.conf"
    done
    {
        printf '%s/latest-stable/main\n' "$alpine_mirror"
        printf '%s/latest-stable/community\n' "$alpine_mirror"
    } > "$apkovl/etc/apk/repositories"
    printf '%s\n' \
        "$alpine_mirror/latest-stable/releases/x86_64/netboot/modloop-virt" \
        > "$apkovl/etc/archi/modloop-url"
    {
        printf '[options]\n'
        printf 'Architecture = auto\n'
        printf 'CheckSpace\n'
        printf 'ParallelDownloads = 5\n'
        printf 'SigLevel = Required DatabaseOptional\n'
        printf 'LocalFileSigLevel = Optional\n'
        printf '\n'
        printf '[core]\n'
        printf 'Include = /etc/pacman.d/mirrorlist\n'
        printf '\n'
        printf '[extra]\n'
        printf 'Include = /etc/pacman.d/mirrorlist\n'
    } > "$apkovl/etc/pacman.conf"
    write_sshd_config "$apkovl/etc/ssh/sshd_config.d/60-archi-root-auth.conf" \
        "$ssh_port" "$permit_root_login" "$password_auth"
    if [ -n "$authorized_key" ]; then
        printf '%s\n' "$authorized_key" > "$apkovl/root/.ssh/authorized_keys"
        cp -f -- "$apkovl/root/.ssh/authorized_keys" "$overlay/archi-early-auth/authorized_keys"
    fi
    {
        printf '#!/bin/sh\n'
        printf 'mkdir -p /run /etc/dropbear /root/.ssh\n'
        printf 'cp /archi-early-auth/passwd /etc/passwd\n'
        printf 'cp /archi-early-auth/group /etc/group\n'
        printf 'cp /archi-early-auth/shadow /etc/shadow\n'
        printf 'printf "/bin/sh\\n" > /etc/shells\n'
        printf 'chmod 0600 /etc/shadow\n'
        printf 'if [ -f /archi-early-auth/authorized_keys ]; then\n'
        printf '    cp /archi-early-auth/authorized_keys /root/.ssh/authorized_keys\n'
        printf '    chmod 0700 /root /root/.ssh\n'
        printf '    chmod 0600 /root/.ssh/authorized_keys\n'
        printf 'fi\n'
        if [ -n "$authorized_key" ]; then
            printf '/usr/sbin/dropbear -F -s -R -E -p %s >> /tmp/archi-early-ssh.log 2>&1 &\n' "$ssh_port"
        else
            printf '/usr/sbin/dropbear -F -R -E -p %s >> /tmp/archi-early-ssh.log 2>&1 &\n' "$ssh_port"
        fi
        printf 'echo $! > /run/archi-early-ssh.pid\n'
        printf 'echo "[archi] Early SSH listener started on port %s" > /dev/console\n' "$ssh_port"
    } > "$overlay/archi-early-ssh"
    chmod 0700 "$overlay/archi-early-ssh"
    cp -f -- "$source_file" "$apkovl/root/archi.sh"
    {
        printf '#!/bin/sh\n'
        printf 'set +e\n'
        printf 'hostname alpine\n'
        printf 'mkdir -p /run/sshd /tmp /var/empty\n'
        printf 'ln -sfn /proc/self/fd /dev/fd\n'
        printf 'ln -sfn /proc/self/fd/0 /dev/stdin\n'
        printf 'ln -sfn /proc/self/fd/1 /dev/stdout\n'
        printf 'ln -sfn /proc/self/fd/2 /dev/stderr\n'
        printf 'ln -sfn /proc/mounts /etc/mtab\n'
        printf '# Nothing below writes to /dev/console: the consoles belong to the getty logins\n'
        printf '# started further down, and anything printed underneath a waiting getty makes it\n'
        printf '# bail out and reprint its prompt. Progress lives in the log instead, and it has\n'
        printf '# to be the same log /etc/motd and /root/.profile point at -- when setup fails\n'
        printf '# here the installer usually dies later of an unrelated-looking symptom, so the\n'
        printf '# cause has to be in the file the user is actually told to read.\n'
        printf 'exec >>/tmp/archi-install.log 2>&1\n'
        printf 'echo '\''[archi] Alpine installer init started.'\''\n'
        printf 'cat > /etc/motd <<'\''MOTD'\''\n'
        printf '\n'
        printf 'Arch Linux is being installed from this Alpine environment.\n'
        printf 'Follow the installation log with:\n'
        printf '\n'
        printf '    tail -f /tmp/archi-install.log\n'
        printf '\n'
        printf 'MOTD\n'
        printf '# init=/root/archi-init replaces Alpine'\''s init, so /etc/inittab is never read and\n'
        printf '# nothing spawns a getty. Start one per usable console ourselves, and do it early\n'
        printf '# so the screen -- including a cloud VNC view of it -- offers a login even when a\n'
        printf '# later step fails.\n'
        printf 'dmesg -n 1\n'
        printf 'for archi_tty in tty1 ttyS0 ttyAMA0; do\n'
        printf '    [ -c "/dev/$archi_tty" ] || continue\n'
        printf '    stty -g -F "/dev/$archi_tty" >/dev/null 2>&1 || continue\n'
        printf '    case $archi_tty in\n'
        printf '        ttyS0 | ttyAMA0) archi_baud=115200 ;;\n'
        printf '        *) archi_baud=0 ;;\n'
        printf '    esac\n'
        printf '    setsid sh -c "while :; do /sbin/getty -L $archi_baud $archi_tty vt100; sleep 2; done" \\\n'
        printf '        </dev/null >/dev/null 2>&1 &\n'
        printf 'done\n'
        printf '# Bring up SSH before the larger installer toolset. If a later package is\n'
        printf '# renamed or temporarily unavailable, the operator can still collect logs.\n'
        printf 'ssh_apk_rc=1\n'
        printf 'ssh_apk_attempt=1\n'
        printf 'while [ "$ssh_apk_attempt" -le 3 ]; do\n'
        printf '    if apk add --no-cache ca-certificates openssh >/tmp/archi-ssh-apk.log 2>&1; then\n'
        printf '        ssh_apk_rc=0\n'
        printf '        break\n'
        printf '    fi\n'
        printf '    echo "[archi] SSH APK attempt $ssh_apk_attempt/3 failed; retrying."\n'
        printf '    ssh_apk_attempt=$((ssh_apk_attempt + 1))\n'
        printf '    sleep 3\n'
        printf 'done\n'
        printf 'echo "[archi] SSH APK exit status: $ssh_apk_rc"\n'
        printf '[ "$ssh_apk_rc" -eq 0 ] || cat /tmp/archi-ssh-apk.log\n'
        printf 'sshd_rc=1\n'
        printf 'if [ "$ssh_apk_rc" -eq 0 ]; then\n'
        printf '    ssh-keygen -A >/tmp/archi-ssh-keygen.log 2>&1\n'
        printf '    ssh_keygen_rc=$?\n'
        printf '    echo "[archi] ssh-keygen exit status: $ssh_keygen_rc"\n'
        printf '    [ "$ssh_keygen_rc" -eq 0 ] || cat /tmp/archi-ssh-keygen.log\n'
        printf '    /usr/sbin/sshd -E /tmp/archi-sshd.log\n'
        printf '    sshd_rc=$?\n'
        printf '    echo "[archi] sshd exit status: $sshd_rc"\n'
        printf '    [ "$sshd_rc" -eq 0 ] || cat /tmp/archi-sshd.log\n'
        printf 'fi\n'
        printf 'echo '\''[archi] SSH bootstrap finished. Installing the remaining tools.'\''\n'
        printf '# apk-tools 3 prunes dependencies when alpine-base is removed. Pin the\n'
        printf '# live runtime explicitly, then remove alpine-conf so its genfstab does not\n'
        printf '# conflict with the one from Arch'\''s arch-install-scripts package.\n'
        printf 'runtime_apk_rc=1\n'
        printf 'if apk add --no-cache alpine-baselayout alpine-keys alpine-release apk-tools busybox musl openssl \\\n'
        printf '        >/tmp/archi-runtime-apk.log 2>&1; then\n'
        printf '    apk del alpine-base alpine-conf >/tmp/archi-apk-remove.log 2>&1\n'
        printf '    runtime_apk_rc=$?\n'
        printf 'fi\n'
        printf 'echo "[archi] runtime package transition exit status: $runtime_apk_rc"\n'
        printf 'if [ "$runtime_apk_rc" -ne 0 ]; then\n'
        printf '    cat /tmp/archi-runtime-apk.log /tmp/archi-apk-remove.log 2>/dev/null\n'
        printf 'fi\n'
        printf '# shellcheck disable=SC2046\n'
        printf 'set -- $(cat /etc/archi/apk-packages)\n'
        printf 'apk_rc=1\n'
        printf 'apk_attempt=1\n'
        printf 'while [ "$apk_attempt" -le 3 ]; do\n'
        printf '    if apk add --no-cache "$@" >/tmp/archi-apk.log 2>&1; then\n'
        printf '        apk_rc=0\n'
        printf '        break\n'
        printf '    fi\n'
        printf '    echo "[archi] APK attempt $apk_attempt/3 failed; retrying."\n'
        printf '    apk_attempt=$((apk_attempt + 1))\n'
        printf '    sleep 3\n'
        printf 'done\n'
        printf 'echo "[archi] required APK exit status: $apk_rc"\n'
        printf '[ "$apk_rc" -eq 0 ] || cat /tmp/archi-apk.log\n'
        printf '# Alpine mounts the modloop from an OpenRC sysinit service, which init= skips,\n'
        printf '# so this normally has to fetch it. The guard is here so that a future Alpine\n'
        printf '# that does mount it in the initramfs does not get a second ~130 MiB download\n'
        printf '# and a second squashfs stacked on the same mount point.\n'
        printf 'if [ -d /.modloop/modules ]; then\n'
        printf '    echo '\''[archi] modloop is already mounted; skipping the download.'\''\n'
        printf '    ln -sfn /.modloop/modules /lib/modules\n'
        printf '    modloop_rc=0\n'
        printf 'else\n'
        printf '    mkdir -p /.modloop /lib\n'
        printf '    curl --fail --location --retry 5 --retry-all-errors --retry-delay 2 \\\n'
        printf '        --speed-limit 1024 --speed-time 60 --max-time 900 --retry-max-time 1800 \\\n'
        printf '        --connect-timeout 10 --output /tmp/modloop-virt \\\n'
        printf '        "$(cat /etc/archi/modloop-url)" >/tmp/archi-modloop.log 2>&1\n'
        printf '    modloop_rc=$?\n'
        printf '    if [ "$modloop_rc" -eq 0 ]; then\n'
        printf '        mount -t squashfs -o loop,ro /tmp/modloop-virt /.modloop\n'
        printf '        ln -sfn /.modloop/modules /lib/modules\n'
        printf '    else\n'
        printf '        echo "[archi] modloop download failed with status $modloop_rc"\n'
        printf '        cat /tmp/archi-modloop.log\n'
        printf '        rm -f /tmp/modloop-virt\n'
        printf '    fi\n'
        printf 'fi\n'
        printf 'if [ "$modloop_rc" -eq 0 ]; then\n'
        printf '    for module in virtio_scsi virtio_blk sd_mod ahci nvme ext4 vfat; do\n'
        printf '        modprobe "$module" >/dev/null 2>&1 || true\n'
        printf '    done\n'
        printf '    mdev -s >/dev/null 2>&1 || true\n'
        printf 'fi\n'
        printf '# Retry sshd after the full package pass if the minimal bootstrap failed.\n'
        printf 'if [ "$sshd_rc" -ne 0 ] && command -v sshd >/dev/null 2>&1; then\n'
        printf '    ssh-keygen -A >/tmp/archi-ssh-keygen.log 2>&1\n'
        printf '    /usr/sbin/sshd -E /tmp/archi-sshd.log\n'
        printf '    sshd_rc=$?\n'
        printf '    echo "[archi] delayed sshd exit status: $sshd_rc"\n'
        printf '    [ "$sshd_rc" -eq 0 ] || cat /tmp/archi-sshd.log\n'
        printf 'fi\n'
        printf 'echo '\''[archi] SSH should be ready. Follow installation with: tail -f /tmp/archi-install.log'\''\n'
        printf 'if [ "$runtime_apk_rc" -eq 0 ] && [ "$apk_rc" -eq 0 ] && [ "$modloop_rc" -eq 0 ]; then\n'
        printf '    /root/archi.sh </dev/null >>/tmp/archi-install.log 2>&1 &\n'
        printf '    installer_pid=$!\n'
        printf '    installer_running=1\n'
        printf 'else\n'
        printf '    echo '\''[archi] Installer was not started because the Alpine toolset is incomplete.'\''\n'
        printf '    installer_pid=\n'
        printf '    installer_running=0\n'
        printf 'fi\n'
        printf '# This is PID 1, so it must never exit, and the sleep is spelled as a background\n'
        printf '# job plus wait so that ash reaps whatever got reparented onto it. The guard is\n'
        printf '# an explicit flag rather than installer_pid=0: kill -0 0 signals the whole\n'
        printf '# process group and always succeeds, which only looked like it worked.\n'
        printf 'while :; do\n'
        printf '    if [ "$installer_running" = 1 ] && ! kill -0 "$installer_pid" 2>/dev/null; then\n'
        printf '        wait "$installer_pid"\n'
        printf '        installer_rc=$?\n'
        printf '        echo "[archi] Installer exited with status $installer_rc; Alpine remains online."\n'
        printf '        installer_running=0\n'
        printf '    fi\n'
        printf '    sleep 5 &\n'
        printf '    wait $!\n'
        printf 'done\n'
    } > "$apkovl/root/archi-init"
    {
        printf 'if [ -n "${SSH_CONNECTION-}" ] && [ -t 1 ]; then\n'
        printf '    echo\n'
        printf '    echo '\''[archi] Logged in to Alpine installer as root.'\''\n'
        printf '    echo '\''[archi] Installation progress follows /tmp/archi-install.log.'\''\n'
        printf '    echo '\''[archi] Press Ctrl-C to get a shell.'\''\n'
        printf '    install_wait=0\n'
        printf '    while [ ! -f /tmp/archi-install.log ] && [ "$install_wait" -lt 15 ]; do\n'
        printf '        sleep 1\n'
        printf '        install_wait=$((install_wait + 1))\n'
        printf '    done\n'
        printf '\n'
        printf '    if [ -f /tmp/archi-install.log ]; then\n'
        printf '        tail -n 80 -f /tmp/archi-install.log\n'
        printf '    else\n'
        printf '        echo "[archi] Waiting for installer log. Run: tail -f /tmp/archi-install.log"\n'
        printf '    fi\n'
        printf '    echo\n'
        printf 'fi\n'
    } > "$apkovl/root/.profile"
    chmod 0700 "$apkovl/root/archi-init"
    find "$apkovl" -type d -exec chmod 0755 {} +
    chmod 0700 "$apkovl/root" "$apkovl/root/.ssh" "$apkovl/root/archi.sh" \
        "$apkovl/root/archi-init"
    if [ -e "$apkovl/root/.ssh/authorized_keys" ]; then
        chmod 0600 "$apkovl/root/.ssh/authorized_keys"
    fi
    chmod 0600 "$apkovl/root/.profile"
    chmod 0600 "$apkovl/etc/shadow"
    # The config carries the root password hash, so it stays root-only.
    chmod 0700 "$apkovl/etc/archi"
    chmod 0600 "$apkovl/etc/archi/config"
    chmod 0644 "$apkovl/etc/hostname" "$apkovl/etc/fstab" "$apkovl/etc/resolv.conf" \
        "$apkovl/etc/passwd" "$apkovl/etc/group" "$apkovl/etc/apk/repositories" \
        "$apkovl/etc/archi/modloop-url" "$apkovl/etc/archi/apk-packages" \
        "$apkovl/etc/pacman.conf" \
        "$apkovl/etc/ssh/sshd_config.d/60-archi-root-auth.conf"

    (cd "$apkovl" && tar --numeric-owner --owner=0 --group=0 -czf "$apkovl_archive" .)

    (cd "$overlay" && find . -print > "$archive_list")
    (cd "$overlay" && cpio --quiet -o -H newc < "$archive_list" > "$overlay_cpio")
    gzip -9c < "$overlay_cpio" > "$overlay_archive"
    cat "$original" "$overlay_archive" > "${destination}.part"
    mv -f -- "${destination}.part" "$destination"
    rm -rf -- "$work"
    trap - 0 1 2 15
)

first_public_key_text() (
    printf '%s\n' "$1" | awk '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        /(^|[[:space:]])(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521))[[:space:]]/ {
            print
            exit
        }
    '
)

first_public_key() (
    file=$1
    [ -r "$file" ] || die "SSH public key file is not readable: $file"
    first_public_key_text "$(cat "$file")"
)

# Silent unless something is wrong: a passing check tells the reader nothing
# they need, and seven URLs scrolling past buries the plan that follows. The
# label and the URL are printed only for whichever source actually failed.
probe_url() (
    label=$1 url=$2
    if ! curl --fail --location --silent --show-error \
        --retry 3 --retry-connrefused --connect-timeout 10 --max-time 45 \
        --range 0-0 --output /dev/null "$url" 2>/dev/null; then
        warn "Unreachable $label: $url"
        return 1
    fi
)

probe_install_sources() (
    probe_pids='' probe_failed=false
    log 'Checking the Alpine and Arch installation sources'
    probe_url 'Alpine virt kernel' "$1" & probe_pids="$probe_pids $!"
    probe_url 'Alpine virt initramfs' "$2" & probe_pids="$probe_pids $!"
    probe_url 'Alpine virt modloop' "$3" & probe_pids="$probe_pids $!"
    probe_url 'Alpine main APKINDEX' "$4" & probe_pids="$probe_pids $!"
    probe_url 'Alpine community APKINDEX' "$5" & probe_pids="$probe_pids $!"
    probe_url 'pacman core repository' "$6" & probe_pids="$probe_pids $!"
    probe_url 'pacman extra repository' "$7" & probe_pids="$probe_pids $!"
    for probe_pid in $probe_pids; do
        if ! wait "$probe_pid"; then probe_failed=true; fi
    done
    [ "$probe_failed" = false ] || die 'One or more installation sources are unavailable'
    log 'All installation sources are reachable'
)

download_file() (
    download_file_worker "$@"
)

# Background callers invoke the brace function directly: wrapping a subshell
# function in another asynchronous shell can hide its PID from signal cleanup.
download_file_worker() {
    url=$1 destination=$2 minimum_bytes=$3 temporary='' size='' download_pid=''
    temporary="${destination}.part"
    trap 'download_status=$?; trap - 0
        if [ -n "$download_pid" ]; then
            kill "$download_pid" 2>/dev/null || true
            wait "$download_pid" 2>/dev/null || true
        fi
        rm -f -- "$temporary"
        exit "$download_status"' 0
    trap 'exit 129' 1
    trap 'exit 130' 2
    trap 'exit 143' 15
    rm -f -- "$temporary"
    log "Downloading $url"
    curl --fail --location --show-error \
        --retry 5 --retry-connrefused --connect-timeout 10 \
        --speed-limit 1024 --speed-time 60 --max-time 900 --retry-max-time 1800 \
        --output "$temporary" "$url" &
    download_pid=$!
    wait "$download_pid" || die "Download failed: $url"
    download_pid=''
    size=$(stat -c '%s' "$temporary")
    [ "$size" -ge "$minimum_bytes" ] || die "Downloaded file is unexpectedly small: $url ($size bytes)"
    mv -f -- "$temporary" "$destination"
}

# Use an empty local database so the Alpine host cannot satisfy dependencies
# that will be missing on the freshly formatted Arch root.
preflight_packages() (
    database=$(mktemp -d)
    trap 'rm -rf -- "$database"' 0
    trap 'exit 129' 1
    trap 'exit 130' 2
    trap 'exit 143' 15
    mkdir -p "$database/local"
    pacman --dbpath "$database" --logfile "$database/pacman.log" -Sy --noconfirm ||
        die 'Could not refresh package databases before erasing the disk'
    pacman --dbpath "$database" --logfile "$database/pacman.log" \
        -Sp --noconfirm --print-format '%n %v' "$@" ||
        die 'Package resolution failed; the target disk has not been erased'
)

ensure_target_initramfs() (
    target_root=$1 target_kernel=$2
    if [ ! -s "$target_root/boot/initramfs-$target_kernel.img" ]; then
        warn "Missing initramfs for $target_kernel; building it now"
        arch-chroot "$target_root" mkinitcpio -P || die 'Could not generate initramfs'
    fi
    [ -s "$target_root/boot/initramfs-$target_kernel.img" ] ||
        die "Initramfs for $target_kernel is still missing or empty"
)

# Expands the literal $repo/$arch placeholders a pacman mirror carries, which
# is how a mirror root becomes a URL that can actually be fetched.
repo_db_url() (
    mirror=$1 repo=$2
    # The placeholders stay literal until exactly here.
    # shellcheck disable=SC2016
    printf '%s\n' "$mirror" |
        sed 's|\$repo|'"$repo"'|g; s|\$arch|x86_64|g; s|$|/'"$repo"'.db|'
)

# Red Hat derivatives ship every GRUB 2 utility under a grub2- prefix, so each
# one has to be looked up rather than assumed.
grub_tool() (
    name=$1
    for candidate in "grub-$name" "grub2-$name"; do
        if command -v "$candidate" >/dev/null 2>&1; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
)

# The grub.cfg GRUB actually reads is the one carrying the boot entries. Copies
# under the EFI directory are stubs that chain to it, and Debian keeps its under
# /boot/grub while Red Hat derivatives use /boot/grub2.
find_grub_cfg() (
    for candidate in /boot/grub/grub.cfg /boot/grub2/grub.cfg /boot/efi/EFI/*/grub.cfg; do
        [ -f "$candidate" ] || continue
        LC_ALL=C grep -qE '^[[:space:]]*(menuentry|blscfg)' "$candidate" || continue
        printf '%s\n' "$candidate"
        return 0
    done
    return 1
)

# Every grub.cfg grub-mkconfig produces ends by sourcing custom.cfg from its own
# directory, which is how the entry gets added without regenerating anything.
grub_cfg_reads_custom() (
    LC_ALL=C grep -q 'custom\.cfg' "$1"
)

# "search --file" has to read the filesystem holding the staged kernel, so the
# matching GRUB module must be loaded first. Only ext2 used to be inserted,
# which left every machine with an xfs or btrfs /boot -- the Red Hat default --
# unable to find its own boot entry.
grub_fs_module() (
    fstype=$1
    case $fstype in
        ext2|ext3|ext4) printf 'ext2\n' ;;
        xfs|btrfs|f2fs|jfs|reiserfs|zfs) printf '%s\n' "$fstype" ;;
        vfat|msdos) printf 'fat\n' ;;
        # Unknown or undetectable: offer the plausible ones and let GRUB skip
        # whichever modules it does not have.
        *) printf 'ext2\nxfs\nbtrfs\nfat\n' ;;
    esac
)

update_grub_config() (
    if command -v update-grub >/dev/null 2>&1; then
        update-grub
    elif mkconfig=$(grub_tool mkconfig); then
        output=''
        if [ -e /boot/grub2/grub.cfg ]; then
            output=/boot/grub2/grub.cfg
        else
            output=/boot/grub/grub.cfg
        fi
        "$mkconfig" -o "$output"
    else
        die 'Neither update-grub nor grub-mkconfig is available'
    fi
)

safe_install_dir() (
    candidate=$1 resolved_parent=''
    case $candidate in
        /boot/archi-*|/boot/archi/*) ;;
        *) die "Install directory must be a dedicated path under /boot named archi-*: $candidate" ;;
    esac
    [ ! -L "$candidate" ] || die "Install directory must not be a symbolic link: $candidate"
    resolved_parent=$(readlink -f "$(dirname "$candidate")")
    case $resolved_parent in
        /boot|/boot/*) ;;
        *) die "Install directory resolves outside /boot: $candidate" ;;
    esac
)

cleanup_stage() (
    install_dir=$1 changed=false regenerate=false grub_cfg='' custom_cfg='' editenv=''
    [ "$(id -u)" -eq 0 ] || die '--cleanup requires root'
    safe_install_dir "$install_dir"

    if grub_cfg=$(find_grub_cfg); then
        custom_cfg="$(dirname "$grub_cfg")/custom.cfg"
        if [ -e "$custom_cfg" ] &&
            LC_ALL=C grep -q "ARCHI_PAYLOAD_ID=$ARCHI_PAYLOAD_ID" "$custom_cfg"; then
            if [ -e "$custom_cfg.archi-orig" ]; then
                mv -f -- "$custom_cfg.archi-orig" "$custom_cfg"
                log "Restored the previous $custom_cfg"
            else
                rm -f -- "$custom_cfg"
            fi
            changed=true
        fi
    fi

    # Written by versions that staged through /etc/grub.d; removing those does
    # require a regeneration, unlike custom.cfg.
    if [ -e "$GRUB_ENTRY_FILE" ]; then
        grep -q 'ARCHI_PAYLOAD_ID=archi-network-reinstall-v1' "$GRUB_ENTRY_FILE" ||
            die "Refusing to remove an unrecognized file: $GRUB_ENTRY_FILE"
        rm -f -- "$GRUB_ENTRY_FILE"
        changed=true regenerate=true
    fi
    if [ -e "$GRUB_DEFAULT_FILE" ]; then
        grep -q 'archi' "$GRUB_DEFAULT_FILE" ||
            die "Refusing to remove an unrecognized file: $GRUB_DEFAULT_FILE"
        rm -f -- "$GRUB_DEFAULT_FILE"
        changed=true regenerate=true
    fi
    if [ -e "$install_dir" ]; then
        is_archi_install_dir "$install_dir" ||
            die "Refusing to remove an unrecognized install directory: $install_dir"
        rm -rf -- "$install_dir"
        changed=true
    fi
    # Drop the one-shot selection too, otherwise grubenv keeps pointing at an
    # entry that no longer exists.
    if editenv=$(grub_tool editenv); then
        "$editenv" - unset next_entry >/dev/null 2>&1 || true
    fi

    if [ "$regenerate" = true ]; then
        update_grub_config
        log 'Arch reinstall staging files were removed and GRUB was regenerated'
    elif [ "$changed" = true ]; then
        sync
        log 'Arch reinstall staging files were removed'
    else
        log 'No Arch reinstall staging files were present'
    fi
)

# Roll back ordinary staging failures, including a failed grub-reboot call.
# Backups are retained if restoring them fails, for manual recovery.
stage_exit() {
    stage_status=$?
    trap - 0 1 2 15
    for stage_pid in ${kernel_download_pid:-} ${initramfs_download_pid:-}; do
        kill "$stage_pid" 2>/dev/null || true
        wait "$stage_pid" 2>/dev/null || true
    done
    if [ "${stage_committed:-false}" != true ]; then
        if [ "${custom_changed:-false}" = true ]; then
            if [ -f "$stage_backup/custom.cfg" ]; then
                mv -f -- "$stage_backup/custom.cfg" "$custom_cfg" || {
                    warn "Could not restore custom.cfg; backup: $stage_backup"
                    exit 1
                }
            else
                rm -f -- "$custom_cfg"
            fi
        fi
        if [ -n "${stage_backup:-}" ] && [ -d "$stage_backup/payload" ]; then
            rm -rf -- "$install_dir"
            mv -- "$stage_backup/payload" "$install_dir" || {
                warn "Could not restore boot files; backup: $stage_backup"
                exit 1
            }
        elif [ "${stage_published:-false}" = true ]; then
            rm -rf -- "$install_dir"
        fi
    fi
    [ -z "${stage_work:-}" ] || rm -rf -- "$stage_work"
    [ -z "${stage_backup:-}" ] || rm -rf -- "$stage_backup"
    rm -f -- "${custom_tmp:-}" "${authorized_key_tmp:-}" "${source_tmp:-}" "${config_tmp:-}"
    exit "$stage_status"
}

stage_main() (
    alpine_mirror=$DEFAULT_ALPINE_MIRROR
    package_mirror=$DEFAULT_PACKAGE_MIRROR
    authorized_key_input='' authorized_key_literal='' password=''
    authorized_key_file=''
    disk=''
    hostname='arch'
    timezone='Asia/Shanghai'
    # Empty means inherit the resolvers of the running system, the same way --ip
    # and --gateway inherit the current addressing.
    dns=''
    ntp='time.cloudflare.com'
    requested_interface='auto'
    requested_ip=''
    requested_gateway=''
    ssh_port=22
    bbr=false fail2ban=false firmware=auto ethx=false
    kernel='linux'
    extra_packages=''
    swap_mib=0
    boot_mode='auto'
    grub_timeout=5
    log_days=0
    install_dir=$DEFAULT_INSTALL_DIR
    hold=0
    dry_run=false cleanup=false
    source_tmp='' authorized_key_tmp='' config_tmp='' password_file=''
    source_file=$ARCHI_SOURCE_FILE
    stage_work='' stage_backup='' custom_tmp=''
    stage_committed=false stage_published=false custom_changed=false

    while [ "$#" -gt 0 ]; do
        case $1 in
            --aliyun) alpine_mirror=$ALIYUN_ALPINE_MIRROR; package_mirror=$ALIYUN_PACKAGE_MIRROR; dns='223.5.5.5 223.6.6.6'; ntp='time.amazonaws.cn'; shift ;;
            --ustc) alpine_mirror=$USTC_ALPINE_MIRROR; package_mirror=$USTC_PACKAGE_MIRROR; dns='119.29.29.29 223.5.5.5'; ntp='time.amazonaws.cn'; shift ;;
            --tuna) alpine_mirror=$TUNA_ALPINE_MIRROR; package_mirror=$TUNA_PACKAGE_MIRROR; dns='119.29.29.29 223.5.5.5'; ntp='time.amazonaws.cn'; shift ;;
            --tencent) alpine_mirror=$TENCENT_ALPINE_MIRROR; package_mirror=$TENCENT_PACKAGE_MIRROR; dns=''; ntp='time.amazonaws.cn'; shift ;;
            --mirror) package_mirror="$(trim_trailing_slash "${2:?missing value}")/\$repo/os/\$arch"; shift 2 ;;
            --alpine-mirror) alpine_mirror=${2:?missing value}; shift 2 ;;
            # The long spellings stay accepted so that commands written against
            # earlier versions keep working; only the short ones are documented.
            --ssh-key|--authorized-key) authorized_key_input=${2:?missing value}; shift 2 ;;
            --password) password=${2:?missing value}; shift 2 ;;
            --password-file)
                password_file=${2:?missing value}
                [ -r "$password_file" ] || die "Password file is not readable: $password_file"
                # Only the first line, without its newline, so that an editor's
                # trailing newline does not become part of the password.
                password=$(LC_ALL=C awk 'NR == 1 { printf "%s", $0 }' "$password_file")
                [ -n "$password" ] || die "Password file is empty: $password_file"
                shift 2
                ;;
            --disk) disk=${2:?missing value}; shift 2 ;;
            --hostname) hostname=${2:?missing value}; shift 2 ;;
            --timezone) timezone=${2:?missing value}; shift 2 ;;
            --iface|--interface) requested_interface=${2:?missing value}; shift 2 ;;
            --ip) requested_ip=${2:?missing value}; shift 2 ;;
            --gateway) requested_gateway=${2:?missing value}; shift 2 ;;
            --dns) dns=${2:?missing value}; shift 2 ;;
            --ntp) ntp=${2:?missing value}; shift 2 ;;
            --port|--ssh-port) ssh_port=${2:?missing value}; shift 2 ;;
            --bbr) bbr=true; shift ;;
            --no-bbr) bbr=false; shift ;;
            --fail2ban) fail2ban=true; shift ;;
            --no-fail2ban) fail2ban=false; shift ;;
            --firmware) firmware=true; shift ;;
            --no-firmware) firmware=false; shift ;;
            --ethx) ethx=true; shift ;;
            --no-ethx) ethx=false; shift ;;
            --kernel) kernel=${2:?missing value}; shift 2 ;;
            --boot-mode) boot_mode=${2:?missing value}; shift 2 ;;
            --grub-timeout) grub_timeout=${2:?missing value}; shift 2 ;;
            --log-days) log_days=${2:?missing value}; shift 2 ;;
            --install) extra_packages=${2:?missing value}; shift 2 ;;
            --swap|--swap-mib) swap_mib=${2:?missing value}; shift 2 ;;
            --hold)
                case ${2-} in
                    1|2) hold=$2; shift 2 ;;
                    *) hold=1; shift ;;
                esac
                ;;
            --dry-run) dry_run=true; shift ;;
            --cleanup) cleanup=true; shift ;;
            --version) printf '%s\n' "$ARCHI_VERSION"; return 0 ;;
            --help|-h) usage; return 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    if [ "$cleanup" = true ]; then
        cleanup_stage "$install_dir"
        return 0
    fi

    [ "$(id -u)" -eq 0 ] || die 'Staging requires root'
    [ "$(uname -m)" = x86_64 ] || die 'Only x86_64 is currently supported'
    need_cmd base64
    need_cmd curl
    need_cmd findmnt
    # What staging actually depends on: the entry is added through custom.cfg
    # and selected for one boot with grub-reboot. Nothing is regenerated, so
    # grub-install and grub-mkconfig are not needed here.
    grub_tool reboot >/dev/null ||
        die 'Required command not found: grub-reboot (or grub2-reboot)'
    need_cmd ip
    need_cmd lsblk
    need_cmd mountpoint
    need_cmd sha256sum
    need_cmd stat
    # systemctl is deliberately not required: the reboot at the end already
    # falls back to reboot(8) and then to reboot -f, and demanding systemd here
    # would reject exactly the minimal images that fallback exists for.

    alpine_mirror=$(trim_trailing_slash "$alpine_mirror")
    package_mirror=$(trim_trailing_slash "$package_mirror")
    validate_url '--alpine-mirror' "$alpine_mirror"
    validate_url '--package-mirror' "$package_mirror"
    # Armed before the first mktemp, otherwise a failed download leaks the
    # temporary file it was writing into.
    trap stage_exit 0
    trap 'exit 129' 1
    trap 'exit 130' 2
    trap 'exit 143' 15
    case $source_file in
        /dev/fd/*|/proc/self/fd/*)
            source_tmp=$(mktemp)
            download_file "$ARCHI_RAW_URL" "$source_tmp" 10000
            source_file=$source_tmp
            ;;
    esac
    if [ -n "$authorized_key_input" ]; then
        case $authorized_key_input in
            http://*|https://*)
                validate_url '--ssh-key' "$authorized_key_input"
                authorized_key_tmp=$(mktemp)
                download_file "$authorized_key_input" "$authorized_key_tmp" 40
                authorized_key_file=$authorized_key_tmp
                ;;
            *)
                if [ -r "$authorized_key_input" ]; then
                    authorized_key_file=$authorized_key_input
                else
                    authorized_key_literal=$authorized_key_input
                fi
                ;;
        esac
    fi
    [ -n "$authorized_key_literal" ] || [ -n "$authorized_key_file" ] || [ -n "$password" ] ||
        die 'Provide --ssh-key or --password'
    if printf '%s' "$password" | LC_ALL=C grep -q '[[:cntrl:]:]'; then
        die 'Password contains an unsupported character'
    fi
    validate_hostname "$hostname"
    validate_packages "$extra_packages"
    validate_port "$ssh_port"
    validate_ntp_host "$ntp"
    [ "$requested_interface" = auto ] || printf '%s\n' "$requested_interface" |
        LC_ALL=C grep -Eq '^[A-Za-z0-9_.:-]+$' || die "Invalid interface name: $requested_interface"
    validate_uint_range '--swap' "$swap_mib" 1048576
    validate_uint_range '--grub-timeout' "$grub_timeout" 60
    validate_uint_range '--log-days' "$log_days" 3650
    case $boot_mode in auto|bios|efi) ;; *) die '--boot-mode must be auto, bios, or efi' ;; esac
    case $kernel in linux|linux-lts) ;; *) die '--kernel must be linux or linux-lts' ;; esac
    validate_timezone "$timezone"
    safe_install_dir "$install_dir"

    if [ -z "$disk" ]; then disk=$(detect_root_disk); fi
    case $disk in /dev/*) ;; *) die 'Target disk must be under /dev' ;; esac
    [ -b "$disk" ] || die "Target disk is not a block device: $disk"
    [ "$(lsblk -ndo TYPE "$disk")" = disk ] || die "Target is not a whole disk: $disk"
    disk_ptuuid=$(lsblk -ndo PTUUID "$disk" | tr -d '[:space:]')
    [ -n "$disk_ptuuid" ] || die "Target disk has no partition-table UUID: $disk"

    if [ "$boot_mode" = auto ]; then
        if [ -d /sys/firmware/efi ]; then boot_mode=efi; else boot_mode=bios; fi
    fi

    mem_kib=''
    mem_kib=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    if [ "$mem_kib" -lt 384000 ]; then
        die "Only $((mem_kib / 1024)) MiB RAM detected; the Alpine installer needs about 384 MiB"
    elif [ "$mem_kib" -lt 524288 ]; then
        warn "Only $((mem_kib / 1024)) MiB RAM detected; the Alpine installer may run out of memory"
    fi

    authorized_key='' password_hash=''
    if [ -n "$authorized_key_literal" ]; then
        authorized_key=$(first_public_key_text "$authorized_key_literal")
        [ -n "$authorized_key" ] || die 'No supported SSH public key found in --ssh-key'
    elif [ -n "$authorized_key_file" ]; then
        authorized_key=$(first_public_key "$authorized_key_file")
        [ -n "$authorized_key" ] || die "No supported SSH public key found in $authorized_key_file"
    fi
    if [ -n "$password" ]; then
        password_hash=$(hash_password "$password")
    fi

    boot_interface='' bootif='' boot_interface_details=''
    boot_interface_details=$(detect_bootif "$requested_interface")
    # The detector emits exactly two whitespace-free fields.
    # shellcheck disable=SC2086
    set -- $boot_interface_details
    [ "$#" -eq 2 ] || die 'Could not parse the boot network interface'
    boot_interface=$1
    bootif=$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')
    if [ -z "$dns" ]; then
        dns=$(detect_dns_servers "$boot_interface")
        printf '%s' "$dns" | grep -q '[^[:space:]]' || dns='1.1.1.1 1.0.0.1'
    fi
    dns=$(printf '%s\n' "$dns" | awk '{$1=$1; print}')
    validate_dns_servers "$dns"

    boot_cidr='' boot_gateway=''
    boot_cidr=$(ip -4 -o address show dev "$boot_interface" scope global 2>/dev/null |
        awk 'NR == 1 { print $4 }')
    boot_gateway=$(ip -4 route show default dev "$boot_interface" 2>/dev/null | awk '
        { for (i = 1; i <= NF; i++) if ($i == "via") { print $(i + 1); exit } }
    ')
    if [ -n "$requested_ip" ]; then
        case $requested_ip in */*) ;; *) die '--ip requires ADDRESS/CIDR' ;; esac
        requested_address=${requested_ip%/*} requested_prefix=${requested_ip#*/}
        is_ipv4 "$requested_address" || die "Invalid static IPv4 address: $requested_address"
        validate_uint_range 'IPv4 prefix' "$requested_prefix" 32
        boot_cidr=$requested_ip
    fi
    if [ -n "$requested_gateway" ]; then
        is_ipv4 "$requested_gateway" || die "Invalid IPv4 gateway: $requested_gateway"
        boot_gateway=$requested_gateway
    fi
    case $boot_cidr in
        */*) [ -n "$boot_gateway" ] || warn 'A complete static IPv4 configuration was not found; Alpine will use DHCP' ;;
        *) warn 'A complete static IPv4 configuration was not found; Alpine will use DHCP' ;;
    esac
    boot_network=''
    boot_network=$(build_boot_network_parameter 'alpine' "$dns" "$bootif" \
        "$boot_cidr" "$boot_gateway")

    payload_sha=''
    payload_sha=$(sha256_file "$source_file")

    netboot_url='' kernel_url='' initramfs_url='' modloop_url='' apk_main_url='' apk_community_url='' core_url='' extra_url=''
    netboot_url="$alpine_mirror/latest-stable/releases/x86_64/netboot"
    kernel_url="$netboot_url/vmlinuz-virt"
    initramfs_url="$netboot_url/initramfs-virt"
    modloop_url="$netboot_url/modloop-virt"
    apk_main_url="$alpine_mirror/latest-stable/main/x86_64/APKINDEX.tar.gz"
    apk_community_url="$alpine_mirror/latest-stable/community/x86_64/APKINDEX.tar.gz"
    core_url=$(repo_db_url "$package_mirror" core)
    extra_url=$(repo_db_url "$package_mirror" extra)

    probe_install_sources "$kernel_url" "$initramfs_url" "$modloop_url" \
        "$apk_main_url" "$apk_community_url" "$core_url" "$extra_url"

    root_authentication=''
    if [ -n "$authorized_key" ] && [ -n "$password_hash" ]; then
        root_authentication='SSH key (password login disabled)'
    elif [ -n "$authorized_key" ]; then
        root_authentication='SSH key'
    else
        root_authentication='password'
    fi

    printf '[archi] Installation plan\n'
    if [ "$hold" = 1 ]; then
        printf '  target disk:       %s (HOLD: NO WIPE)\n' "$disk"
    else
        printf '  target disk:       %s (WILL BE ERASED AFTER REBOOT)\n' "$disk"
    fi
    printf '  disk PTUUID:       %s\n' "$disk_ptuuid"
    printf '  boot mode:         %s\n' "$boot_mode"
    printf '  hostname:          %s\n' "$hostname"
    printf '  installer hostname: alpine\n'
    printf '  timezone:          %s\n' "$timezone"
    printf '  NTP:               %s\n' "$ntp"
    printf '  Alpine mirror:     %s\n' "$alpine_mirror"
    printf '  package mirror:    %s\n' "$package_mirror"
    printf '  boot interface:    %s (%s)\n' "$boot_interface" "${bootif#01-}"
    printf '  boot network:      %s\n' "$boot_network"
    printf '  DNS servers:       %s\n' "$dns"
    printf '  payload SHA-256:   %s\n' "$payload_sha"
    printf '  root authentication: %s\n' "$root_authentication"
    printf '  SSH port:          %s\n' "$ssh_port"
    printf '  kernel package:    %s\n' "$kernel"
    printf '  firmware bundle:   %s\n' "$firmware"
    printf '  TCP BBR:           %s\n' "$bbr"
    printf '  Fail2ban:          %s\n' "$fail2ban"
    printf '  eth0 naming:       %s\n' "$ethx"
    printf '  swap:              %s MiB\n' "$swap_mib"
    printf '  GRUB timeout:      %ss\n' "$grub_timeout"
    printf '  journal retention: %s days\n' "$log_days"
    printf '  extra packages:    %s\n' "${extra_packages:-none}"
    printf '  hold mode:         %s\n' "$hold"
    printf '  stage directory:   %s\n' "$install_dir"
    if [ "$dry_run" = true ]; then
        log 'Dry run completed; no files or boot settings were changed'
        return 0
    fi

    grub_cfg=$(find_grub_cfg) ||
        die 'Could not find a grub.cfg containing boot entries'
    grub_cfg_reads_custom "$grub_cfg" ||
        die "This GRUB configuration does not source custom.cfg: $grub_cfg"
    custom_cfg="$(dirname "$grub_cfg")/custom.cfg"
    grubenv_path="$(dirname "$grub_cfg")/grubenv"
    grubenv_mount=$(findmnt -n -o TARGET --target "$grub_cfg") ||
        die 'Could not find the filesystem containing GRUB'
    grubenv_uuid=$(findmnt -n -o UUID --target "$grub_cfg") ||
        die 'Could not identify the GRUB filesystem'
    grubenv_fstype=$(findmnt -n -o FSTYPE --target "$grub_cfg") ||
        die 'Could not identify the GRUB filesystem type'
    grubenv_fsroot=$(findmnt -n -o FSROOT --target "$grub_cfg") ||
        die 'Could not identify the GRUB filesystem root'
    [ -n "$grubenv_uuid" ] || die 'GRUB filesystem has no UUID'
    case $grubenv_mount in
        /) grubenv_relative=${grubenv_path#/} ;;
        *) grubenv_relative=${grubenv_path#"$grubenv_mount"/} ;;
    esac
    [ "$grubenv_relative" != "$grubenv_path" ] || die 'Could not map grubenv into its filesystem'
    grubenv_disk_path="${grubenv_fsroot%/}/$grubenv_relative"

    need_cmd cpio
    need_cmd find
    need_cmd gzip
    need_cmd tar
    if [ -e "$install_dir" ]; then
        is_archi_install_dir "$install_dir" ||
            die "Refusing to replace an unrecognized install directory: $install_dir"
    fi
    # Build beside the destination so publishing uses same-filesystem renames.
    stage_work=$(mktemp -d "${install_dir}.new.XXXXXX")
    printf '%s\n' "$ARCHI_PAYLOAD_ID" > "$stage_work/.archi-owned"
    download_failed=false
    download_file_worker "$kernel_url" "$stage_work/vmlinuz-virt" 5000000 &
    kernel_download_pid=$!
    download_file_worker "$initramfs_url" "$stage_work/initramfs-virt.official" 3000000 &
    initramfs_download_pid=$!
    if ! wait "$kernel_download_pid"; then download_failed=true; fi
    kernel_download_pid=''
    if ! wait "$initramfs_download_pid"; then download_failed=true; fi
    initramfs_download_pid=''
    [ "$download_failed" = false ] || die 'Could not download the Alpine boot files'

    boot_mac=''
    boot_mac=${bootif#01-}
    boot_mac=$(printf '%s' "$boot_mac" | tr '[:upper:]-' '[:lower:]:')
    case $boot_cidr in
        */*) [ -n "$boot_gateway" ] || { boot_cidr=''; boot_gateway=''; } ;;
        *) boot_cidr=''; boot_gateway='' ;;
    esac
    console_args=$(tr ' ' '\n' </proc/cmdline | grep '^console=' | tr '\n' ' ' || true)
    printf '%s' "$console_args" | LC_ALL=C grep -Eq '^[A-Za-z0-9_=,./:+ -]*$' ||
        die 'Invalid console argument in source kernel command line'

    # Everything the Alpine side needs, carried inside the apkovl. See the
    # ARCHI_CONFIG_FILE comment for why none of this belongs on the cmdline.
    config_tmp=$(mktemp)
    write_installer_config "$config_tmp" \
        version "$ARCHI_VERSION" \
        disk "$disk" \
        disk_ptuuid "$disk_ptuuid" \
        grubenv_uuid "$grubenv_uuid" \
        grubenv_fstype "$grubenv_fstype" \
        grubenv_disk_path "$grubenv_disk_path" \
        hostname "$hostname" \
        timezone "$timezone" \
        dns "$dns" \
        authorized_key "$authorized_key" \
        password_hash "$password_hash" \
        package_mirror "$package_mirror" \
        extra_packages "$extra_packages" \
        kernel "$kernel" \
        ntp "$ntp" \
        boot_mode "$boot_mode" \
        swap_mib "$swap_mib" \
        hold "$hold" \
        boot_cidr "$boot_cidr" \
        gateway "$boot_gateway" \
        boot_mac "$boot_mac" \
        console_args "$console_args" \
        ssh_port "$ssh_port" \
        bbr "$bbr" \
        fail2ban "$fail2ban" \
        firmware "$firmware" \
        ethx "$ethx" \
        grub_timeout "$grub_timeout" \
        log_days "$log_days"

    build_alpine_initramfs "$stage_work/initramfs-virt.official" \
        "$stage_work/initramfs-virt" "$authorized_key" 'alpine' "$ssh_port" "$dns" \
        "$alpine_mirror" "$password_hash" "$source_file" "$config_tmp"
    rm -f -- "$stage_work/initramfs-virt.official" "$config_tmp"
    config_tmp=''
    # The apkovl inside it holds the root password hash and the authorized key.
    # Non-fatal: /boot is sometimes the vfat ESP, which rejects chmod outright.
    chmod 0600 "$stage_work/initramfs-virt" 2>/dev/null || true

    grub_prefix='' grub_stage_dir='' grub_kernel='' grub_initramfs=''
    grub_fsroot=''
    if mountpoint -q /boot; then
        grub_prefix=''
    else
        grub_prefix='/boot'
    fi
    grub_stage_dir=${install_dir#/boot}
    # GRUB resolves paths from the filesystem root when btrfs_relative_path=n.
    # A Linux /boot inside a Btrfs subvolume therefore needs its FSROOT prefix
    # (for example /@rootfs/boot), even though Linux sees /boot directly.
    boot_fstype=$(findmnt -n -o FSTYPE --target "$stage_work" 2>/dev/null || true)
    if [ "$boot_fstype" = btrfs ]; then
        grub_fsroot=$(findmnt -n -o FSROOT --target "$stage_work") ||
            die 'Could not find the Btrfs subvolume containing the staged kernel'
        case $grub_fsroot in
            /) grub_fsroot='' ;;
            /*) ;;
            *) die "Unexpected Btrfs filesystem root: $grub_fsroot" ;;
        esac
    fi
    grub_kernel="$grub_fsroot$grub_prefix$grub_stage_dir/vmlinuz-virt"
    grub_initramfs="$grub_fsroot$grub_prefix$grub_stage_dir/initramfs-virt"

    {
        printf 'ARCHI_PAYLOAD_ID=%s\n' "$ARCHI_PAYLOAD_ID"
        printf 'version=%s\n' "$ARCHI_VERSION"
        printf 'created=%s\n' "$(date -Is)"
        printf 'disk=%s\n' "$disk"
        printf 'boot_mode=%s\n' "$boot_mode"
        printf 'boot_interface=%s\n' "$boot_interface"
        printf 'bootif=%s\n' "$bootif"
        printf 'boot_network=%s\n' "$boot_network"
        printf 'alpine_mirror=%s\n' "$alpine_mirror"
        printf 'package_mirror=%s\n' "$package_mirror"
        printf 'hostname=%s\n' "$hostname"
        printf 'timezone=%s\n' "$timezone"
        printf 'ntp=%s\n' "$ntp"
        printf 'ssh_port=%s\n' "$ssh_port"
        printf 'kernel=%s\n' "$kernel"
        printf 'firmware=%s\n' "$firmware"
        printf 'bbr=%s\n' "$bbr"
        printf 'fail2ban=%s\n' "$fail2ban"
        printf 'ethx=%s\n' "$ethx"
        printf 'grub_timeout=%s\n' "$grub_timeout"
        printf 'log_days=%s\n' "$log_days"
        printf 'payload_sha256=%s\n' "$payload_sha"
        printf 'kernel_sha256=%s\n' "$(sha256_file "$stage_work/vmlinuz-virt")"
        printf 'initramfs_sha256=%s\n' "$(sha256_file "$stage_work/initramfs-virt")"
    } > "$stage_work/manifest"

    # Append the entry through custom.cfg instead of adding a /etc/grub.d script
    # and regenerating. Regeneration rewrites the whole boot configuration of a
    # machine that is still in service, picking up every unrelated change made
    # since it was last run, and it fails outright when something like os-prober
    # errors out. Sourcing custom.cfg is part of the grub.cfg already on disk, so
    # nothing else has to be touched.
    stage_backup=$(mktemp -d "${install_dir}.backup.XXXXXX")
    if [ -e "$custom_cfg" ]; then
        cp -p -- "$custom_cfg" "$stage_backup/custom.cfg"
    fi
    custom_tmp=$(mktemp "${custom_cfg}.new.XXXXXX")
    # Keep whatever the administrator already had there; --cleanup puts it back.
    if [ -e "$custom_cfg" ] &&
        ! LC_ALL=C grep -q "ARCHI_PAYLOAD_ID=$ARCHI_PAYLOAD_ID" "$custom_cfg"; then
        [ -e "$custom_cfg.archi-orig" ] ||
            cp -p -- "$custom_cfg" "$custom_cfg.archi-orig"
        log "Existing custom.cfg saved as $custom_cfg.archi-orig"
    fi

    boot_fstype='' grub_insmod='' grub_btrfs_path=''
    for grub_fs in $(grub_fs_module "$boot_fstype"); do
        grub_insmod="$grub_insmod    insmod $grub_fs
"
    done
    if [ "$boot_fstype" = btrfs ]; then
        # Paths under a btrfs subvolume are otherwise resolved relative to the
        # subvolume root rather than to the filesystem root.
        grub_btrfs_path='    set btrfs_relative_path=n
'
    fi

    # grub-reboot stores the one-shot choice in grubenv, and grub.cfg only acts
    # on it when it managed to load that file. Where GRUB's prefix sits on the
    # EFI partition but grubenv lives under /boot, it silently does not, and the
    # machine quietly boots the old system instead. Borrowed from reinstall.sh.
    # Single-quoted printf formats, so the $ of every GRUB variable below is
    # already literal and needs no shell escaping of its own.
    {
        printf '# ARCHI_PAYLOAD_ID=%s\n' "$ARCHI_PAYLOAD_ID"
        printf '# Written by archi.sh. Remove with: archi.sh --cleanup\n'
        printf 'if ! [ -s $prefix/grubenv ]; then\n'
        printf '    for archi_dir in /boot/grub /boot/grub2 /grub /grub2; do\n'
        printf '        set archi_grubenv="($root)$archi_dir/grubenv"\n'
        printf '        if [ -s $archi_grubenv ]; then\n'
        printf '            load_env --file $archi_grubenv\n'
        printf '            if [ "${next_entry}" ]; then\n'
        printf '                set default="${next_entry}"\n'
        printf '                set next_entry=\n'
        printf '                save_env --file $archi_grubenv next_entry\n'
        printf '            fi\n'
        printf '        fi\n'
        printf '    done\n'
        printf 'fi\n'
        printf '# --unrestricted so that the entry still boots under a password-protected menu.\n'
        printf 'menuentry '\''Arch Linux network reinstall (ERASES TARGET DISK)'\'' --id archi --unrestricted {\n'
        printf '    insmod part_gpt\n'
        printf '    insmod part_msdos\n'
        printf '    insmod lvm\n'
        printf '    insmod all_video\n'
        printf '%s%s    search --no-floppy --file --set=root %s\n' \
            "$grub_insmod" "$grub_btrfs_path" "$grub_kernel"
        printf '    linux %s modules=loop,squashfs,sd_mod,usb_storage,virtio_scsi,virtio_blk alpine_repo=%s/latest-stable/main,%s/latest-stable/community apkovl=/archi.apkovl.tar.gz init=/root/archi-init %s archi_mode=install archi_payload_sha256=%s\n' \
            "$grub_kernel" "$alpine_mirror" "$alpine_mirror" "$boot_network" "$payload_sha"
        printf '    initrd %s\n' "$grub_initramfs"
        printf '}\n'
    } > "$custom_tmp"
    # GRUB reads the filesystem directly and ignores these bits, so tightening
    # them costs nothing; on a vfat ESP the chmod simply cannot take effect.
    chmod 0600 "$custom_tmp" 2>/dev/null || true
    if [ -e "$install_dir" ]; then
        mv -- "$install_dir" "$stage_backup/payload"
    fi
    stage_published=true
    mv -- "$stage_work" "$install_dir"
    custom_changed=true
    mv -f -- "$custom_tmp" "$custom_cfg"
    log "Reinstall entry written to $custom_cfg"

    # Select the entry for the next boot only. As a persistent GRUB_DEFAULT it
    # would keep winning after a failed or held run, so every later reboot would
    # re-enter Alpine and erase the disk again; one-shot falls back to the
    # system that is already installed.
    grub_reboot=$(grub_tool reboot) ||
        die 'Required command not found: grub-reboot (or grub2-reboot)'
    "$grub_reboot" archi >/dev/null 2>&1 ||
        die "Could not select the reinstall entry for the next boot: $grub_reboot archi"
    stage_committed=true
    rm -rf -- "$stage_backup"
    stage_backup=''
    log "Reinstall entry selected for the next boot only, via $grub_reboot"

    sync
    log 'Arch reinstall entry is staged successfully'
    log 'It remains reversible until reboot: archi.sh --cleanup'
    if [ "$hold" = 1 ]; then
        log 'Rebooting into Alpine hold mode; target partitions will not be changed'
    else
        log 'Rebooting into Alpine; the selected disk will be erased'
    fi
    # systemd denies the request while logind is still starting up, and some
    # minimal images do not run systemd at all. Falling back matters here: by
    # this point everything is staged, so giving up would strand the machine
    # one reboot short of the install with set -e reporting a bare failure.
    # A successful request takes the machine down during the wait, so a generous
    # window costs nothing here and avoids forcing a reboot underneath a clean
    # shutdown that is merely slow.
    if systemctl reboot 2>/dev/null; then
        sleep 120
    fi
    log 'Reboot request did not take effect; retrying with reboot(8)'
    if reboot 2>/dev/null; then
        sleep 30
    fi
    log 'Still running; forcing an immediate reboot'
    sync
    reboot -f
)

partition_path() (
    disk=$1 number=$2
    case $disk in
        *[0-9]) printf '%sp%s' "$disk" "$number" ;;
        *) printf '%s%s' "$disk" "$number" ;;
    esac
)

setup_installer_logging() {
    INSTALLER_LOG_FILE=$1
    INSTALLER_LOG_PIPE=''
    INSTALLER_TEE_PID=''
    # Mirroring through tee only earns its keep when someone is watching a
    # terminal. Started from archi-init stdout is already the log file, and
    # teeing would then write every line to it twice.
    if [ ! -t 1 ]; then
        exec >>"$INSTALLER_LOG_FILE" 2>&1
        return 0
    fi
    INSTALLER_LOG_PIPE=/tmp/archi-install-log.$$
    rm -f -- "$INSTALLER_LOG_PIPE"
    mkfifo "$INSTALLER_LOG_PIPE"
    exec 3>&1 4>&2
    tee -a "$INSTALLER_LOG_FILE" < "$INSTALLER_LOG_PIPE" >&3 &
    INSTALLER_TEE_PID=$!
    exec > "$INSTALLER_LOG_PIPE" 2>&1
    rm -f -- "$INSTALLER_LOG_PIPE"
}

installer_exit() {
    INSTALLER_EXIT_STATUS=$?
    trap - 0 1 2 15
    if [ "$INSTALLER_EXIT_STATUS" -ne 0 ]; then
        warn "Installation failed with exit code $INSTALLER_EXIT_STATUS. Alpine is being left online for diagnosis."
        # archi-init normally has sshd running already; this only covers the
        # case where it died, or where the installer was started by hand.
        pidof sshd >/dev/null 2>&1 || /usr/sbin/sshd >/dev/null 2>&1 || true
        sync
    fi
    if [ -n "${INSTALLER_TEE_PID:-}" ]; then
        exec 1>&3 2>&4 3>&- 4>&-
        wait "$INSTALLER_TEE_PID" || true
    fi
    rm -f -- "${INSTALLER_LOG_PIPE:-}"
    exit "$INSTALLER_EXIT_STATUS"
}

# GRUB cannot reliably save an updated grubenv on Btrfs. Clear the one-shot
# choice from Linux before any destructive work, so a held or failed run boots
# the original system next time. The path is stored relative to the filesystem
# root because /boot may live inside a Btrfs subvolume.
clear_one_shot_boot() (
    uuid=$1 fstype=$2 env_path=$3
    case $uuid in ''|*[!A-Fa-f0-9-]*) die 'Invalid GRUB filesystem UUID' ;; esac
    case $env_path in /*) ;; *) die 'Invalid GRUB environment path' ;; esac
    case $env_path in *'/../'*|*'/./'*|*'//'*) die 'Invalid GRUB environment path' ;; esac
    mount_dir=$(mktemp -d /tmp/archi-grubenv.XXXXXX)
    trap 'umount "$mount_dir" 2>/dev/null || true; rmdir "$mount_dir" 2>/dev/null || true' 0
    if [ "$fstype" = btrfs ]; then
        mount -t btrfs -o rw,subvolid=5 "UUID=$uuid" "$mount_dir" ||
            die 'Could not mount the original Btrfs boot filesystem'
    else
        mount -t "$fstype" -o rw "UUID=$uuid" "$mount_dir" ||
            die 'Could not mount the original GRUB filesystem'
    fi
    [ -f "$mount_dir$env_path" ] || die "GRUB environment file is missing: $env_path"
    grub-editenv "$mount_dir$env_path" unset next_entry ||
        die 'Could not clear the one-shot GRUB selection'
    if grub-editenv "$mount_dir$env_path" list | grep -q '^next_entry='; then
        die 'One-shot GRUB selection is still present'
    fi
    log 'Cleared the one-shot GRUB selection on the original system'
)

installer_main() (
    log_file=/tmp/archi-install.log
    setup_installer_logging "$log_file"
    trap installer_exit 0
    trap 'exit 129' 1
    trap 'exit 130' 2
    trap 'exit 143' 15

    log "Alpine installer mode, archi.sh $ARCHI_VERSION"
    [ "$ARCHI_PAYLOAD_ID" = archi-network-reinstall-v1 ] || die 'Internal payload marker mismatch'
    need_cmd arch-chroot
    need_cmd base64
    need_cmd blockdev
    need_cmd curl
    need_cmd dd
    need_cmd genfstab
    need_cmd grub-editenv
    need_cmd killall
    need_cmd lsblk
    need_cmd mdev
    need_cmd mkfs.ext4
    need_cmd mkswap
    need_cmd mount
    need_cmd numfmt
    need_cmd pacman
    need_cmd pacman-key
    need_cmd pacstrap
    need_cmd parted
    need_cmd partprobe
    need_cmd pidof
    need_cmd reboot
    need_cmd sha256sum
    need_cmd swapoff
    need_cmd swapon
    need_cmd umount
    need_cmd virt-what
    need_cmd wipefs
    need_cmd yes

    expected_sha='' actual_sha=''
    expected_sha=$(cmdline_value archi_payload_sha256)
    actual_sha=$(sha256_file "$ARCHI_SOURCE_FILE")
    printf '%s\n' "$expected_sha" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$' &&
        [ "$actual_sha" = "$expected_sha" ] ||
        die "Installer payload checksum mismatch (expected $expected_sha, got $actual_sha)"

    disk='' disk_ptuuid='' grubenv_uuid='' grubenv_fstype='' grubenv_disk_path=''
    hostname='' timezone='' dns='' authorized_key='' password_hash='' package_mirror='' extra_packages='' kernel='' ntp=''
    boot_mode='' swap_mib='' hold='' boot_cidr='' boot_gateway='' boot_mac='' console_args=''
    ssh_port='' bbr='' fail2ban='' firmware='' ethx='' grub_timeout='' log_days=''
    [ -r "$ARCHI_CONFIG_FILE" ] ||
        die "Installer configuration is missing: $ARCHI_CONFIG_FILE"
    disk=$(config_value disk)
    disk_ptuuid=$(config_value disk_ptuuid)
    grubenv_uuid=$(config_value grubenv_uuid)
    grubenv_fstype=$(config_value grubenv_fstype)
    grubenv_disk_path=$(config_value grubenv_disk_path)
    hostname=$(config_value hostname)
    timezone=$(config_value timezone)
    dns=$(config_value dns)
    authorized_key=$(config_value authorized_key)
    password_hash=$(config_value password_hash)
    package_mirror=$(config_value package_mirror)
    extra_packages=$(config_value extra_packages)
    kernel=$(config_value kernel)
    ntp=$(config_value ntp)
    boot_mode=$(config_value boot_mode)
    swap_mib=$(config_value swap_mib)
    hold=$(config_value hold)
    boot_cidr=$(config_value boot_cidr)
    boot_gateway=$(config_value gateway)
    boot_mac=$(config_value boot_mac)
    console_args=$(config_value console_args)
    ssh_port=$(config_value ssh_port)
    bbr=$(config_value bbr)
    fail2ban=$(config_value fail2ban)
    firmware=$(config_value firmware)
    ethx=$(config_value ethx)
    grub_timeout=$(config_value grub_timeout)
    log_days=$(config_value log_days)

    validate_hostname "$hostname"
    validate_packages "$extra_packages"
    validate_dns_servers "$dns"
    case $disk in /dev/*) [ -b "$disk" ] || die "Target disk is unavailable: $disk" ;; *) die "Target disk is unavailable: $disk" ;; esac
    [ "$(lsblk -ndo TYPE "$disk")" = disk ] || die "Target is not a whole disk: $disk"
    actual_ptuuid=$(lsblk -ndo PTUUID "$disk" | tr -d '[:space:]')
    [ -n "$disk_ptuuid" ] && [ "$actual_ptuuid" = "$disk_ptuuid" ] ||
        die "Target disk identity changed across reboot: $disk"
    case $boot_mode in bios|efi) ;; *) die "Invalid boot mode: $boot_mode" ;; esac
    [ "$boot_mode" != efi ] || need_cmd mkfs.fat
    validate_uint_range 'swap size' "$swap_mib" 1048576
    if [ "$swap_mib" -gt 0 ]; then
        need_cmd dd
        need_cmd mkswap
    fi
    case $kernel in linux|linux-lts) ;; *) die 'Invalid kernel package' ;; esac
    validate_port "$ssh_port"
    case $bbr in true|false) ;; *) die 'Invalid BBR setting' ;; esac
    case $fail2ban in true|false) ;; *) die 'Invalid Fail2ban setting' ;; esac
    case $firmware in auto|true|false) ;; *) die 'Invalid firmware setting' ;; esac
    case $ethx in true|false) ;; *) die 'Invalid ethx setting' ;; esac
    case $hold in 0|1|2) ;; *) die 'Invalid hold setting' ;; esac
    validate_uint_range 'GRUB timeout' "$grub_timeout" 60
    validate_uint_range 'journal retention' "$log_days" 3650
    validate_ntp_host "$ntp"
    validate_timezone "$timezone"
    [ -e "/usr/share/zoneinfo/$timezone" ] || die "Unknown timezone: $timezone"
    if [ -n "$authorized_key" ]; then
        authorized_key=$(first_public_key_text "$authorized_key")
        [ -n "$authorized_key" ] || die 'Invalid root SSH public key'
    fi
    if [ -n "$password_hash" ]; then
        case $password_hash in "\$6\$"*) ;; *) die 'Invalid root password hash' ;; esac
        if printf '%s' "$password_hash" | LC_ALL=C grep -q '[[:cntrl:]:]'; then
            die 'Invalid root password hash'
        fi
    fi
    [ -n "$authorized_key" ] || [ -n "$password_hash" ] || die 'No valid root authentication was supplied'
    if [ -n "$boot_cidr" ]; then
        case $boot_cidr in
            */*)
                is_ipv4 "${boot_cidr%/*}" || die 'Invalid inherited static IPv4 address'
                validate_uint_range 'inherited IPv4 prefix' "${boot_cidr#*/}" 32
                ;;
            *) die 'Invalid inherited static IPv4 configuration' ;;
        esac
    fi
    [ -z "$boot_gateway" ] || is_ipv4 "$boot_gateway" || die 'Invalid inherited IPv4 gateway'
    if [ -n "$boot_mac" ]; then
        printf '%s\n' "$boot_mac" | LC_ALL=C grep -Eq '^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$' ||
            die 'Invalid inherited network MAC address'
    fi
    printf '%s' "$console_args" | LC_ALL=C grep -Eq '^[A-Za-z0-9_=,./:+ -]*$' ||
        die 'Invalid console argument'
    validate_url 'package mirror' "$package_mirror"

    # Staging uses umask 077, but the installed operating system must inherit
    # normal Arch directory modes. Sensitive SSH keys and logs are chmod'd
    # explicitly below.
    umask 022

    # The Alpine hostname, /root/.ssh/authorized_keys and the sshd drop-in all
    # came out of the apkovl before archi-init started sshd with them, so there
    # is nothing left to set up here. Only the installed system is built below.
    permit_root_login='' password_auth=''
    # sshd_auth_mode emits exactly two whitespace-free fields.
    # shellcheck disable=SC2046
    set -- $(sshd_auth_mode "$authorized_key")
    permit_root_login=$1 password_auth=$2

    install -d -m 0755 /etc/pacman.d
    printf 'Server = %s\n' "$package_mirror" > /etc/pacman.d/mirrorlist
    probe_url 'pacman core repository' "$(repo_db_url "$package_mirror" core)" ||
        die 'The Arch package mirror is unreachable from Alpine'

    root_ssh_authentication=password
    [ -n "$authorized_key" ] && root_ssh_authentication='key only'
    printf '[archi] Verified install plan inside Alpine\n'
    printf '  disk:             %s (size %s)\n' \
        "$disk" "$(numfmt --to=iec "$(blockdev --getsize64 "$disk")")"
    printf '  boot mode:        %s\n' "$boot_mode"
    printf '  hostname:         %s\n' "$hostname"
    printf '  package mirror:   %s\n' "$package_mirror"
    printf '  root SSH:         %s\n' "$root_ssh_authentication"
    printf '  SSH port:         %s\n' "$ssh_port"
    printf '  NTP:              %s\n' "$ntp"
    printf '  firmware bundle:  %s\n' "$firmware"
    printf '  TCP BBR:          %s\n' "$bbr"
    printf '  Fail2ban:         %s\n' "$fail2ban"
    printf '  swap:             %s MiB\n' "$swap_mib"

    clear_one_shot_boot "$grubenv_uuid" "$grubenv_fstype" "$grubenv_disk_path"

    if [ "$hold" = 1 ] && [ "${ARCHI_FORCE_INSTALL:-0}" != 1 ]; then
        log 'Hold mode is active; target partitions were not changed.'
        log 'SSH is available with the configured root authentication.'
        log 'To continue destructively: ARCHI_FORCE_INSTALL=1 /root/archi.sh'
        return 0
    fi

    disk_size=''
    disk_size=$(blockdev --getsize64 "$disk")
    [ "$disk_size" -ge 5368709120 ] || die 'Target disk must be at least 5 GiB'
    maximum_swap_mib=$((disk_size / 1048576 - 4096))
    [ "$swap_mib" -le "$maximum_swap_mib" ] ||
        die 'Swap size leaves less than 4 GiB for the installed system'
    if lsblk -nrpo MOUNTPOINT "$disk" | grep -qE '^/'; then
        die "A partition on $disk is mounted; refusing to erase it"
    fi

    [ -r /usr/share/pacman/keyrings/archlinux.gpg ] ||
        die 'The Arch Linux package-signing keyring is unavailable'
    if command -v ntpd >/dev/null 2>&1; then
        ntpd -q -p "$ntp" || warn "Could not synchronize time with $ntp; using the current system clock"
    fi
    # Match reinstall's Arch package order: bootstrap the minimal userland,
    # generate C.UTF-8, then install firmware (on bare metal) and the kernel.
    base_packages="base grub openssh e2fsprogs $extra_packages"
    if [ "$boot_mode" = efi ]; then base_packages="$base_packages efibootmgr dosfstools"; fi
    [ "$fail2ban" = true ] && base_packages="$base_packages fail2ban nftables"
    firmware_packages=''
    if [ "$firmware" != false ]; then
        virtual_machine=false
        if [ -n "$(virt-what 2>/dev/null)" ] ||
            ls /sys/bus/virtio/devices/* >/dev/null 2>&1; then
            virtual_machine=true
        fi
        if [ "$firmware" = true ] || [ "$virtual_machine" = false ]; then
            firmware_packages=linux-firmware
            case $(awk -F: '/vendor_id/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' /proc/cpuinfo) in
                GenuineIntel) firmware_packages="$firmware_packages intel-ucode" ;;
                AuthenticAMD) firmware_packages="$firmware_packages amd-ucode" ;;
            esac
        fi
    fi
    packages="$base_packages $firmware_packages $kernel"
    # Every package token was validated before it reached this point.
    # shellcheck disable=SC2086
    set -- $packages

    log 'Initializing the Arch Linux package-signing keyring'
    if ! { pacman-key --init && pacman-key --populate archlinux; } >/tmp/archi-keyring.log 2>&1; then
        cat /tmp/archi-keyring.log
        die 'Could not build the Arch package-signing keyring'
    fi
    log 'Checking all packages and dependencies before erasing the disk'
    preflight_packages "$@"

    log "ERASING and partitioning $disk"
    swapoff -a 2>/dev/null || true
    wipefs --all --force "$disk"
    boot_partition='' root_partition='' root_partition_number=1
    if [ "$boot_mode" = efi ]; then
        parted -s "$disk" -- mklabel gpt \
            mkpart ESP fat32 1MiB 101MiB \
            mkpart ROOT ext4 101MiB 100% \
            set 1 esp on
        root_partition_number=2
    elif [ "$disk_size" -gt 2199023255552 ]; then
        parted -s "$disk" -- mklabel gpt \
            mkpart BIOSBOOT ext4 1MiB 2MiB \
            mkpart ROOT ext4 2MiB 100% \
            set 1 bios_grub on
        root_partition_number=2
    else
        parted -s "$disk" -- mklabel msdos \
            mkpart primary ext4 1MiB 100% \
            set 1 boot on
    fi
    boot_partition=$(partition_path "$disk" 1)
    root_partition=$(partition_path "$disk" "$root_partition_number")
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        partprobe "$disk" 2>/dev/null || true
        mdev -s 2>/dev/null || true
        if [ -b "$root_partition" ] && { [ "$boot_mode" != efi ] || [ -b "$boot_partition" ]; }; then
            break
        fi
        sleep 1
    done
    [ -b "$root_partition" ] || die "Root partition did not appear: $root_partition"

    mkfs.ext4 -F -L ArchRoot "$root_partition"
    install -d /mnt
    mount "$root_partition" /mnt
    if [ "$boot_mode" = efi ]; then
        [ -b "$boot_partition" ] || die "EFI partition did not appear: $boot_partition"
        mkfs.fat -F 32 -n ARCH_EFI "$boot_partition"
        install -d /mnt/efi
        mount "$boot_partition" /mnt/efi
    fi

    # reinstall temporarily raises available memory to 1 GiB for pacstrap,
    # then removes the swap file rather than keeping it in the new system.
    temporary_swap_mib=0
    mem_mib=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
    if [ "$mem_mib" -lt 1024 ]; then
        temporary_swap_mib=$((1024 - mem_mib))
        log "Creating ${temporary_swap_mib} MiB temporary installation swap"
        dd if=/dev/zero of=/mnt/.archi-install-swap bs=1M count="$temporary_swap_mib" status=none
        chmod 0600 /mnt/.archi-install-swap
        mkswap /mnt/.archi-install-swap
        swapon /mnt/.archi-install-swap
    fi

    install -d -m 0755 /mnt/etc
    printf 'KEYMAP=us\n' > /mnt/etc/vconsole.conf
    chmod 0644 /mnt/etc/vconsole.conf

    # Only the base package set is installed before the locale is generated.
    # mkinitcpio's kernel hook then runs under a configured C.UTF-8 locale.
    # shellcheck disable=SC2086
    set -- $base_packages
    log "Installing base packages: $*"
    # Keep pacstrap's default target cache (/mnt/var/cache/pacman/pkg).
    # -c would use Alpine's RAM-backed host cache and exhaust small machines.
    # Leave downloaded packages in place so retries can reuse them.
    pacstrap_ok=false
    for _ in 1 2 3; do
        if yes | pacstrap -K /mnt "$@"; then
            pacstrap_ok=true
            break
        fi
        warn 'pacstrap failed; cleaning transient state before retry'
        killall gpg-agent 2>/dev/null || true
        rm -f -- /mnt/var/lib/pacman/db.lck
        sleep 5
    done
    [ "$pacstrap_ok" = true ] || die 'pacstrap failed after three attempts'
    chmod 0755 /mnt/etc
    genfstab -U /mnt | sed '/\.archi-install-swap/d' > /mnt/etc/fstab
    chmod 0644 /mnt/etc/fstab
    cp -Lf /etc/resolv.conf /mnt/etc/resolv.conf
    chmod 0644 /mnt/etc/resolv.conf

    if [ "$swap_mib" -gt 0 ]; then
        # Written out rather than fallocate'd: a preallocated file is made of
        # unwritten extents, and swapon refuses those, which would only surface
        # as a missing swap after the installed system has already booted.
        log "Creating a ${swap_mib} MiB swap file"
        dd if=/dev/zero of=/mnt/swapfile bs=1M count="$swap_mib" status=none
        chmod 0600 /mnt/swapfile
        mkswap /mnt/swapfile
        printf '/swapfile none swap defaults 0 0\n' >> /mnt/etc/fstab
    fi

    ln -sf "/usr/share/zoneinfo/$timezone" /mnt/etc/localtime
    printf 'C.UTF-8 UTF-8\n' >> /mnt/etc/locale.gen
    arch-chroot /mnt locale-gen
    printf 'LANG=C.UTF-8\n' > /mnt/etc/locale.conf
    # Booted images should get a fresh machine identity on first start.
    : > /mnt/etc/machine-id
    if [ -n "$firmware_packages" ]; then
        # shellcheck disable=SC2086
        arch-chroot /mnt pacman -Syu --noconfirm $firmware_packages
    fi
    arch-chroot /mnt pacman -Syu --noconfirm "$kernel"
    arch-chroot /mnt ssh-keygen -A
    printf '%s\n' "$hostname" > /mnt/etc/hostname
    {
        printf '127.0.0.1 localhost\n'
        printf '::1 localhost\n'
        printf '127.0.1.1 %s\n' "$hostname"
    } > /mnt/etc/hosts
    chmod 0644 /mnt/etc/locale.conf /mnt/etc/hostname /mnt/etc/hosts

    if [ "$log_days" -gt 0 ]; then
        install -d -m 0755 /mnt/etc/systemd/journald.conf.d
        # Arch's systemd package ships /var/log/journal, so Storage=auto already
        # means a persistent journal; all that is missing is an age limit.
        # MaxRetentionSec alone would not give one: journald only drops whole
        # files, and with the default MaxFileSec of one month the active file
        # holds far more than the retention window before it is ever rotated.
        {
            printf '[Journal]\n'
            printf 'MaxRetentionSec=%sday\n' "$log_days"
            printf 'MaxFileSec=1day\n'
        } > /mnt/etc/systemd/journald.conf.d/60-archi-retention.conf
        chmod 0644 /mnt/etc/systemd/journald.conf.d/60-archi-retention.conf
    fi

    install -d -m 0755 /mnt/etc/systemd/timesyncd.conf.d
    {
        printf '[Time]\n'
        printf 'NTP=%s\n' "$ntp"
        printf 'FallbackNTP=time.cloudflare.com time.google.com\n'
    } > /mnt/etc/systemd/timesyncd.conf.d/60-archi-cloud.conf
    chmod 0644 /mnt/etc/systemd/timesyncd.conf.d/60-archi-cloud.conf

    if [ "$bbr" = true ]; then
        install -d -m 0755 /mnt/etc/sysctl.d
        {
            printf 'net.core.default_qdisc = fq\n'
            printf 'net.core.somaxconn = 16384\n'
            printf 'net.ipv4.ip_local_port_range = 10240 65535\n'
            printf 'net.ipv4.tcp_congestion_control = bbr\n'
            printf 'net.ipv4.tcp_max_syn_backlog = 16384\n'
            printf 'net.ipv4.tcp_mtu_probing = 1\n'
            printf 'net.ipv4.tcp_rfc1337 = 1\n'
            printf 'net.ipv4.tcp_slow_start_after_idle = 0\n'
            printf 'net.ipv4.tcp_syncookies = 1\n'
        } > /mnt/etc/sysctl.d/99-archi-bbr.conf
        chmod 0644 /mnt/etc/sysctl.d/99-archi-bbr.conf
    fi

    install -d -m 0755 /mnt/etc/systemd/network
    if [ -n "$boot_cidr" ] && [ -n "$boot_gateway" ] && [ -n "$boot_mac" ]; then
        {
            printf '[Match]\n'
            printf 'MACAddress=%s\n' "$boot_mac"
            printf '\n'
            printf '[Network]\n'
            printf 'Address=%s\n' "$boot_cidr"
            printf 'IPv6AcceptRA=yes\n'
            printf '%s\n' "${dns:+DNS=$dns}"
            printf '\n[Route]\n'
            printf 'Destination=0.0.0.0/0\n'
            printf 'Gateway=%s\n' "$boot_gateway"
            printf 'GatewayOnLink=yes\n'
        } > /mnt/etc/systemd/network/20-wired.network
    else
        {
            printf '[Match]\n'
            printf 'Type=ether\n'
            printf '\n'
            printf '[Network]\n'
            printf 'DHCP=yes\n'
            printf 'IPv6AcceptRA=yes\n'
            printf '%s\n' "${dns:+DNS=$dns}"
        } > /mnt/etc/systemd/network/20-wired.network
    fi
    chmod 0644 /mnt/etc/systemd/network/20-wired.network
    arch-chroot /mnt systemctl enable systemd-networkd.service systemd-resolved.service \
        systemd-timesyncd.service sshd.service
    rm -f -- /mnt/etc/resolv.conf
    ln -s /run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf

    if [ -n "$authorized_key" ]; then
        install -d -m 0700 /mnt/root/.ssh
        printf '%s\n' "$authorized_key" > /mnt/root/.ssh/authorized_keys
        chmod 0600 /mnt/root/.ssh/authorized_keys
    fi
    install -d -m 0755 /mnt/etc/ssh/sshd_config.d
    write_sshd_config /mnt/etc/ssh/sshd_config.d/60-root-auth.conf \
        "$ssh_port" "$permit_root_login" "$password_auth"
    if [ -n "$password_hash" ]; then
        printf 'root:%s\n' "$password_hash" | arch-chroot /mnt chpasswd -e
    else
        arch-chroot /mnt passwd --lock root
    fi

    if [ "$fail2ban" = true ]; then
        install -d -m 0755 /mnt/etc/fail2ban/jail.d
        {
            printf '[DEFAULT]\n'
            printf 'backend = systemd\n'
            printf 'banaction = nftables\n'
            printf 'banaction_allports = nftables[type=allports]\n'
            printf 'bantime = 1h\n'
            printf 'findtime = 10m\n'
            printf 'maxretry = 5\n'
            printf '\n'
            printf '[sshd]\n'
            printf 'enabled = true\n'
            printf 'port = %s\n' "$ssh_port"
            printf 'mode = aggressive\n'
        } > /mnt/etc/fail2ban/jail.d/sshd.local
        chmod 0644 /mnt/etc/fail2ban/jail.d/sshd.local
        arch-chroot /mnt fail2ban-client -t
        arch-chroot /mnt systemctl enable fail2ban.service
    fi

    if [ "$boot_mode" = efi ]; then
        arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/efi \
            --bootloader-id=ARCH
        arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/efi \
            --bootloader-id=ARCH --removable
    else
        arch-chroot /mnt grub-install --target=i386-pc --recheck "$disk"
    fi
    sed -i -E \
        -e "s/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=$grub_timeout/" \
        -e 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' \
        /mnt/etc/default/grub
    if [ -n "$console_args" ]; then
        printf 'GRUB_CMDLINE_LINUX="$GRUB_CMDLINE_LINUX %s"\n' "$console_args" \
            >> /mnt/etc/default/grub
    fi
    if grep -qE '^#?GRUB_DISABLE_OS_PROBER=' /mnt/etc/default/grub; then
        sed -i -E 's/^#?GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=true/' \
            /mnt/etc/default/grub
    else
        printf '\nGRUB_DISABLE_OS_PROBER=true\n' >> /mnt/etc/default/grub
    fi
    if [ "$ethx" = true ]; then
        install -d -m 0755 /mnt/etc/udev/rules.d
        ln -sfn /dev/null /mnt/etc/udev/rules.d/80-net-setup-link.rules
    fi
    # GRUB must see the selected kernel's nonempty initramfs when generating
    # its entries, including when pacstrap's hook did not produce the image.
    ensure_target_initramfs /mnt "$kernel"
    arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

    if [ "$temporary_swap_mib" -gt 0 ]; then
        swapoff /mnt/.archi-install-swap
        rm -f -- /mnt/.archi-install-swap
    fi

    if [ -x /mnt/usr/bin/qemu-ga ]; then
        arch-chroot /mnt systemctl enable qemu-guest-agent.service
    fi

    cp -f -- "$log_file" /mnt/root/archi-install.log
    cp -f -- "$ARCHI_SOURCE_FILE" /mnt/root/archi.sh
    chmod 0600 /mnt/root/archi-install.log
    chmod 0700 /mnt/root/archi.sh
    killall gpg-agent 2>/dev/null || true
    agents_stopped=false
    for _ in 1 2 3 4 5; do
        if ! pidof gpg-agent >/dev/null 2>&1; then
            agents_stopped=true
            break
        fi
        sleep 1
    done
    if [ "$agents_stopped" != true ]; then
        warn 'Temporary gpg-agent did not stop after SIGTERM; sending SIGKILL'
        killall -9 gpg-agent 2>/dev/null || true
        sleep 1
    fi
    pidof gpg-agent >/dev/null 2>&1 && die 'Temporary gpg-agent is still running'
    if [ "$hold" = 2 ]; then
        sync
        log 'Arch Linux installation completed; hold mode keeps /mnt mounted and Alpine online'
        return 0
    fi
    sync
    target='' unmounted=''
    for target in /mnt/efi /mnt; do
        grep -qsE "[[:space:]]${target}[[:space:]]" /proc/mounts || continue
        unmounted=false
        for _ in 1 2 3 4 5; do
            if umount "$target"; then
                unmounted=true
                break
            fi
            sleep 1
        done
        [ "$unmounted" = true ] || die "$target remained busy after five unmount attempts"
    done
    log 'Arch Linux installation completed successfully'

    reboot -f
)

if is_install_environment; then
    installer_main "$@"
else
    stage_main "$@"
fi
