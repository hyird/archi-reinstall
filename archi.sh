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
readonly ARCHI_VERSION='0.11.0'
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
    cat <<'EOF'
Usage:
  archi.sh [options]
  archi.sh --cleanup

Options:
  --authorized-key /root/.ssh/authorized_keys
                               Root SSH public key, file path, or URL.
  --password 'Archi-2026!'     Root password.
  --password-file /root/pw     Read the root password from a file instead, so
                               that it stays out of the shell history and ps.
  --disk /dev/vda              Whole target disk.
  --hostname arch              Installed hostname (default: arch).
  --timezone Asia/Shanghai     Installed timezone (default: Asia/Shanghai).
  --interface eth0             Boot interface (default: the default route).
  --ip 192.0.2.10/24           Override the inherited static IPv4 address.
  --gateway 192.0.2.1          Override the inherited IPv4 gateway.
  --dns 1.1.1.1                DNS servers (default: inherit, else 1.1.1.1).
  --ntp time.cloudflare.com    NTP host (default: time.cloudflare.com).
  --ssh-port 22                SSH port (default: 22).
  --install "git htop"         Install extra official packages.
  --kernel linux               Kernel package: linux or linux-lts (default:
                               linux-lts).
  --firmware                   Also install the linux-firmware bundle.
  --boot-mode efi              Force bios or efi instead of autodetecting.
  --grub-timeout 5             Installed GRUB menu timeout in seconds.
  --ethx, --no-ethx            Rename interfaces to eth0 (default) or keep the
                               predictable names.
  --bbr, --no-bbr              Enable TCP BBR (default) or leave the defaults.
  --no-fail2ban                Do not install the default SSH jail.
  --swap-mib 1024              Swap file size in MiB (default: 0, disabled).
  --mirror https://mirrors.cloud.tencent.com/archlinux
                               Arch mirror root; repository path is appended.
  --alpine-mirror https://dl-cdn.alpinelinux.org/alpine
                               Alpine mirror root for the temporary environment.
  --tuna, --ustc, --aliyun     Use a regional mirror preset.
  --tencent                    Use the Tencent Cloud mirror preset.
  --hold                       Boot Alpine with SSH, but do not wipe.
  --dry-run                    Validate and print the plan without changing files.
  --cleanup                    Remove the staged GRUB entry and downloaded files.
  --help                       Show this help.
  --version                    Show script version.

Requires x86_64, GRUB 2, wired IPv4 and root access. The target disk is erased.
EOF
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
    cat > "$path" <<EOF
Port $port
PermitRootLogin $permit_root_login
PasswordAuthentication $password_auth
KbdInteractiveAuthentication no
PermitEmptyPasswords no
LoginGraceTime 30
MaxAuthTries 3
MaxStartups 10:30:30
PerSourceMaxStartups 3
X11Forwarding no
EOF
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

    # The single list archi-init hands to "apk add". An /etc/apk/world of our
    # own used to sit next to it: init=/root/archi-init means OpenRC never runs
    # and never acts on world, but "apk add" solves against it, so the two lists
    # silently had to agree -- and they no longer did. The netboot image already
    # ships a correct world, so overriding it buys nothing.
    # coreutils is listed for numfmt even though arch-install-scripts pulls it.
    cat > "$apkovl/etc/archi/apk-packages" <<'EOF'
arch-install-scripts
archlinux-keyring
bash
ca-certificates
coreutils
curl
dosfstools
e2fsprogs
findmnt
gnupg
lsblk
openssh
parted
sgdisk
tzdata
util-linux-misc
wipefs
EOF
    cp -f -- "$config_file" "$apkovl/etc/archi/config"
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
    printf 'root:%s:%s:0:99999:7:::\n' "$shadow_password" "$shadow_last_change" > "$apkovl/etc/shadow"
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
        > "$apkovl/etc/archi/modloop-url"
    cat > "$apkovl/etc/pacman.conf" <<'EOF'
[options]
Architecture = auto
CheckSpace
ParallelDownloads = 5
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist
EOF
    write_sshd_config "$apkovl/etc/ssh/sshd_config.d/60-archi-root-auth.conf" \
        "$ssh_port" "$permit_root_login" "$password_auth"
    if [ -n "$authorized_key" ]; then
        printf '%s\n' "$authorized_key" > "$apkovl/root/.ssh/authorized_keys"
    fi
    cp -f -- "$source_file" "$apkovl/root/archi.sh"
    cat > "$apkovl/root/archi-init" <<'EOF'
#!/bin/sh
set +e
hostname alpine
mkdir -p /run/sshd /tmp /var/empty
ln -sfn /proc/self/fd /dev/fd
ln -sfn /proc/self/fd/0 /dev/stdin
ln -sfn /proc/self/fd/1 /dev/stdout
ln -sfn /proc/self/fd/2 /dev/stderr
ln -sfn /proc/mounts /etc/mtab
# Nothing below writes to /dev/console: the consoles belong to the getty logins
# started further down, and anything printed underneath a waiting getty makes it
# bail out and reprint its prompt. Progress lives in the log instead, and it has
# to be the same log /etc/motd and /root/.profile point at -- when setup fails
# here the installer usually dies later of an unrelated-looking symptom, so the
# cause has to be in the file the user is actually told to read.
exec >>/tmp/archi-install.log 2>&1
echo '[archi] Alpine installer init started.'
cat > /etc/motd <<'MOTD'

Arch Linux is being installed from this Alpine environment.
Follow the installation log with:

    tail -f /tmp/archi-install.log

MOTD
# init=/root/archi-init replaces Alpine's init, so /etc/inittab is never read and
# nothing spawns a getty. Start one per usable console ourselves, and do it early
# so the screen -- including a cloud VNC view of it -- offers a login even when a
# later step fails.
dmesg -n 1
for archi_tty in tty1 ttyS0 ttyAMA0; do
    [ -c "/dev/$archi_tty" ] || continue
    stty -g -F "/dev/$archi_tty" >/dev/null 2>&1 || continue
    case $archi_tty in
        ttyS0 | ttyAMA0) archi_baud=115200 ;;
        *) archi_baud=0 ;;
    esac
    setsid sh -c "while :; do /sbin/getty -L $archi_baud $archi_tty vt100; sleep 2; done" \
        </dev/null >/dev/null 2>&1 &
done
apk del alpine-base alpine-conf >/tmp/archi-apk-remove.log 2>&1
# shellcheck disable=SC2046
set -- $(cat /etc/archi/apk-packages)
apk_rc=1
apk_attempt=1
while [ "$apk_attempt" -le 3 ]; do
    if apk add --no-cache "$@" >/tmp/archi-apk.log 2>&1; then
        apk_rc=0
        break
    fi
    echo "[archi] APK attempt $apk_attempt/3 failed; retrying."
    apk_attempt=$((apk_attempt + 1))
    sleep 3
done
echo "[archi] required APK exit status: $apk_rc"
[ "$apk_rc" -eq 0 ] || cat /tmp/archi-apk.log
# Alpine mounts the modloop from an OpenRC sysinit service, which init= skips,
# so this normally has to fetch it. The guard is here so that a future Alpine
# that does mount it in the initramfs does not get a second ~130 MiB download
# and a second squashfs stacked on the same mount point.
if [ -d /.modloop/modules ]; then
    echo '[archi] modloop is already mounted; skipping the download.'
    ln -sfn /.modloop/modules /lib/modules
    modloop_rc=0
else
    mkdir -p /.modloop /lib
    curl --fail --location --retry 5 --retry-all-errors --retry-delay 2 \
        --connect-timeout 10 --output /tmp/modloop-virt \
        "$(cat /etc/archi/modloop-url)" >/tmp/archi-modloop.log 2>&1
    modloop_rc=$?
    if [ "$modloop_rc" -eq 0 ]; then
        mount -t squashfs -o loop,ro /tmp/modloop-virt /.modloop
        ln -sfn /.modloop/modules /lib/modules
    else
        echo "[archi] modloop download failed with status $modloop_rc"
        cat /tmp/archi-modloop.log
    fi
fi
if [ "$modloop_rc" -eq 0 ]; then
    for module in virtio_scsi virtio_blk sd_mod ahci nvme ext4 vfat; do
        modprobe "$module" >/dev/null 2>&1 || true
    done
    mdev -s >/dev/null 2>&1 || true
fi
ssh-keygen -A >/tmp/archi-ssh-keygen.log 2>&1
ssh_keygen_rc=$?
echo "[archi] ssh-keygen exit status: $ssh_keygen_rc"
[ "$ssh_keygen_rc" -eq 0 ] || cat /tmp/archi-ssh-keygen.log
/usr/sbin/sshd -E /tmp/archi-sshd.log
sshd_rc=$?
echo "[archi] sshd exit status: $sshd_rc"
[ "$sshd_rc" -eq 0 ] || cat /tmp/archi-sshd.log
echo '[archi] SSH should be ready. Follow installation with: tail -f /tmp/archi-install.log'
/root/archi.sh </dev/null >>/tmp/archi-install.log 2>&1 &
installer_pid=$!
installer_running=1
# This is PID 1, so it must never exit, and the sleep is spelled as a background
# job plus wait so that ash reaps whatever got reparented onto it. The guard is
# an explicit flag rather than installer_pid=0: kill -0 0 signals the whole
# process group and always succeeds, which only looked like it worked.
while :; do
    if [ "$installer_running" = 1 ] && ! kill -0 "$installer_pid" 2>/dev/null; then
        wait "$installer_pid"
        installer_rc=$?
        echo "[archi] Installer exited with status $installer_rc; Alpine remains online."
        installer_running=0
    fi
    sleep 5 &
    wait $!
done
EOF
    cat > "$apkovl/root/.profile" <<'EOF'
if [ -n "${SSH_CONNECTION-}" ] && [ -t 1 ]; then
    echo
    echo '[archi] Logged in to Alpine installer as root.'
    echo '[archi] Installation progress follows /tmp/archi-install.log.'
    echo '[archi] Press Ctrl-C to get a shell.'
    install_wait=0
    while [ ! -f /tmp/archi-install.log ] && [ "$install_wait" -lt 15 ]; do
        sleep 1
        install_wait=$((install_wait + 1))
    done

    if [ -f /tmp/archi-install.log ]; then
        tail -n 80 -f /tmp/archi-install.log
    else
        echo "[archi] Waiting for installer log. Run: tail -f /tmp/archi-install.log"
    fi
    echo
fi
EOF
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
    chmod 0644 "$apkovl/etc/hostname" "$apkovl/etc/resolv.conf" \
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

probe_url() (
    label=$1 url=$2
    log "Checking $label: $url"
    curl --fail --location --silent --show-error \
        --retry 3 --retry-connrefused --connect-timeout 10 --max-time 45 \
        --range 0-0 --output /dev/null "$url"
)

probe_install_sources() (
    probe_pids='' probe_failed=false
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
)

download_file() (
    url=$1 destination=$2 minimum_bytes=$3 temporary='' size=''
    temporary="${destination}.part"
    rm -f -- "$temporary"
    log "Downloading $url"
    curl --fail --location --show-error \
        --retry 5 --retry-connrefused --connect-timeout 10 \
        --output "$temporary" "$url"
    size=$(stat -c '%s' "$temporary")
    [ "$size" -ge "$minimum_bytes" ] || die "Downloaded file is unexpectedly small: $url ($size bytes)"
    mv -f -- "$temporary" "$destination"
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
    bbr=true fail2ban=true firmware=false ethx=true
    kernel='linux-lts'
    extra_packages=''
    swap_mib=0
    boot_mode='auto'
    grub_timeout=5
    install_dir=$DEFAULT_INSTALL_DIR
    hold=false
    dry_run=false cleanup=false
    source_tmp='' authorized_key_tmp='' config_tmp='' password_file=''
    source_file=$ARCHI_SOURCE_FILE

    while [ "$#" -gt 0 ]; do
        case $1 in
            --aliyun) alpine_mirror=$ALIYUN_ALPINE_MIRROR; package_mirror=$ALIYUN_PACKAGE_MIRROR; dns='223.5.5.5 223.6.6.6'; ntp='time.amazonaws.cn'; shift ;;
            --ustc) alpine_mirror=$USTC_ALPINE_MIRROR; package_mirror=$USTC_PACKAGE_MIRROR; dns='119.29.29.29 223.5.5.5'; ntp='time.amazonaws.cn'; shift ;;
            --tuna) alpine_mirror=$TUNA_ALPINE_MIRROR; package_mirror=$TUNA_PACKAGE_MIRROR; dns='119.29.29.29 223.5.5.5'; ntp='time.amazonaws.cn'; shift ;;
            --tencent) alpine_mirror=$TENCENT_ALPINE_MIRROR; package_mirror=$TENCENT_PACKAGE_MIRROR; dns='119.29.29.29'; ntp='time.amazonaws.cn'; shift ;;
            --mirror) package_mirror="$(trim_trailing_slash "${2:?missing value}")/\$repo/os/\$arch"; shift 2 ;;
            --alpine-mirror) alpine_mirror=${2:?missing value}; shift 2 ;;
            --authorized-key) authorized_key_input=${2:?missing value}; shift 2 ;;
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
            --interface) requested_interface=${2:?missing value}; shift 2 ;;
            --ip) requested_ip=${2:?missing value}; shift 2 ;;
            --gateway) requested_gateway=${2:?missing value}; shift 2 ;;
            --dns) dns=${2:?missing value}; shift 2 ;;
            --ntp) ntp=${2:?missing value}; shift 2 ;;
            --ssh-port) ssh_port=${2:?missing value}; shift 2 ;;
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
            --install) extra_packages=${2:?missing value}; shift 2 ;;
            --swap-mib) swap_mib=${2:?missing value}; shift 2 ;;
            --hold) hold=true; shift ;;
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
    trap 'rm -f -- "${authorized_key_tmp:-}" "${source_tmp:-}" "${config_tmp:-}"' 0
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
                validate_url '--authorized-key' "$authorized_key_input"
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
        die 'Provide --authorized-key or --password'
    if printf '%s' "$password" | LC_ALL=C grep -q '[[:cntrl:]:]'; then
        die 'Password contains an unsupported character'
    fi
    validate_hostname "$hostname"
    validate_packages "$extra_packages"
    validate_port "$ssh_port"
    validate_ntp_host "$ntp"
    [ "$requested_interface" = auto ] || printf '%s\n' "$requested_interface" |
        LC_ALL=C grep -Eq '^[A-Za-z0-9_.:-]+$' || die "Invalid interface name: $requested_interface"
    validate_uint_range '--swap-mib' "$swap_mib" 1048576
    validate_uint_range '--grub-timeout' "$grub_timeout" 60
    case $boot_mode in auto|bios|efi) ;; *) die '--boot-mode must be auto, bios, or efi' ;; esac
    case $kernel in linux|linux-lts) ;; *) die '--kernel must be linux or linux-lts' ;; esac
    validate_timezone "$timezone"
    safe_install_dir "$install_dir"

    if [ -z "$disk" ]; then disk=$(detect_root_disk); fi
    case $disk in /dev/*) ;; *) die 'Target disk must be under /dev' ;; esac
    [ -b "$disk" ] || die "Target disk is not a block device: $disk"
    [ "$(lsblk -ndo TYPE "$disk")" = disk ] || die "Target is not a whole disk: $disk"

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
        [ -n "$authorized_key" ] || die 'No supported SSH public key found in --authorized-key'
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
  root authentication: $root_authentication
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
  stage directory:   $install_dir
EOF
    if [ "$dry_run" = true ]; then
        log 'Dry run completed; no files or boot settings were changed'
        return 0
    fi

    need_cmd cpio
    need_cmd find
    need_cmd gzip
    need_cmd tar
    if [ -e "$install_dir" ]; then
        is_archi_install_dir "$install_dir" ||
            die "Refusing to replace an unrecognized install directory: $install_dir"
        rm -rf -- "$install_dir"
    fi
    mkdir -p -- "$install_dir"
    printf '%s\n' "$ARCHI_PAYLOAD_ID" > "$install_dir/.archi-owned"
    download_failed=false
    download_file "$kernel_url" "$install_dir/vmlinuz-virt" 5000000 &
    kernel_download_pid=$!
    download_file "$initramfs_url" "$install_dir/initramfs-virt.official" 3000000 &
    initramfs_download_pid=$!
    if ! wait "$kernel_download_pid"; then download_failed=true; fi
    if ! wait "$initramfs_download_pid"; then download_failed=true; fi
    [ "$download_failed" = false ] || die 'Could not download the Alpine boot files'

    boot_mac=''
    boot_mac=${bootif#01-}
    boot_mac=$(printf '%s' "$boot_mac" | tr '[:upper:]-' '[:lower:]:')
    case $boot_cidr in
        */*) [ -n "$boot_gateway" ] || { boot_cidr=''; boot_gateway=''; } ;;
        *) boot_cidr=''; boot_gateway='' ;;
    esac
    hold_flag=0
    [ "$hold" = true ] && hold_flag=1

    # Everything the Alpine side needs, carried inside the apkovl. See the
    # ARCHI_CONFIG_FILE comment for why none of this belongs on the cmdline.
    config_tmp=$(mktemp)
    write_installer_config "$config_tmp" \
        version "$ARCHI_VERSION" \
        disk "$disk" \
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
        hold "$hold_flag" \
        boot_cidr "$boot_cidr" \
        gateway "$boot_gateway" \
        boot_mac "$boot_mac" \
        ssh_port "$ssh_port" \
        bbr "$bbr" \
        fail2ban "$fail2ban" \
        firmware "$firmware" \
        ethx "$ethx" \
        grub_timeout "$grub_timeout"

    build_alpine_initramfs "$install_dir/initramfs-virt.official" \
        "$install_dir/initramfs-virt" "$authorized_key" 'alpine' "$ssh_port" "$dns" \
        "$alpine_mirror" "$password_hash" "$source_file" "$config_tmp"
    rm -f -- "$install_dir/initramfs-virt.official" "$config_tmp"
    config_tmp=''
    # The apkovl inside it holds the root password hash and the authorized key.
    # Non-fatal: /boot is sometimes the vfat ESP, which rejects chmod outright.
    chmod 0600 "$install_dir/initramfs-virt" 2>/dev/null || true

    grub_prefix='' grub_stage_dir='' grub_kernel='' grub_initramfs=''
    if mountpoint -q /boot; then
        grub_prefix=''
    else
        grub_prefix='/boot'
    fi
    grub_stage_dir=${install_dir#/boot}
    grub_kernel="$grub_prefix$grub_stage_dir/vmlinuz-virt"
    grub_initramfs="$grub_prefix$grub_stage_dir/initramfs-virt"

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
kernel_sha256=$(sha256_file "$install_dir/vmlinuz-virt")
initramfs_sha256=$(sha256_file "$install_dir/initramfs-virt")
EOF

    # Append the entry through custom.cfg instead of adding a /etc/grub.d script
    # and regenerating. Regeneration rewrites the whole boot configuration of a
    # machine that is still in service, picking up every unrelated change made
    # since it was last run, and it fails outright when something like os-prober
    # errors out. Sourcing custom.cfg is part of the grub.cfg already on disk, so
    # nothing else has to be touched.
    grub_cfg=$(find_grub_cfg) ||
        die 'Could not find a grub.cfg containing boot entries'
    grub_cfg_reads_custom "$grub_cfg" ||
        die "This GRUB configuration does not source custom.cfg: $grub_cfg"
    custom_cfg="$(dirname "$grub_cfg")/custom.cfg"
    # Keep whatever the administrator already had there; --cleanup puts it back.
    if [ -e "$custom_cfg" ] &&
        ! LC_ALL=C grep -q "ARCHI_PAYLOAD_ID=$ARCHI_PAYLOAD_ID" "$custom_cfg"; then
        [ -e "$custom_cfg.archi-orig" ] ||
            cp -p -- "$custom_cfg" "$custom_cfg.archi-orig"
        log "Existing custom.cfg saved as $custom_cfg.archi-orig"
    fi

    boot_fstype='' grub_insmod='' grub_btrfs_path=''
    boot_fstype=$(findmnt -n -o FSTYPE --target "$install_dir" 2>/dev/null || true)
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
cat > "$custom_cfg" <<EOF
# ARCHI_PAYLOAD_ID=$ARCHI_PAYLOAD_ID
# Written by archi.sh. Remove with: archi.sh --cleanup
if ! [ -s \$prefix/grubenv ]; then
    for archi_dir in /boot/grub /boot/grub2 /grub /grub2; do
        set archi_grubenv="(\$root)\$archi_dir/grubenv"
        if [ -s \$archi_grubenv ]; then
            load_env --file \$archi_grubenv
            if [ "\${next_entry}" ]; then
                set default="\${next_entry}"
                set next_entry=
                save_env --file \$archi_grubenv next_entry
            fi
        fi
    done
fi
# --unrestricted so that the entry still boots under a password-protected menu.
menuentry 'Arch Linux network reinstall (ERASES TARGET DISK)' --id archi --unrestricted {
    insmod part_gpt
    insmod part_msdos
    insmod lvm
    insmod all_video
$grub_insmod$grub_btrfs_path    search --no-floppy --file --set=root $grub_kernel
    linux $grub_kernel modules=loop,squashfs,sd_mod,usb_storage,virtio_scsi,virtio_blk alpine_repo=$alpine_mirror/latest-stable/main,$alpine_mirror/latest-stable/community apkovl=/archi.apkovl.tar.gz init=/root/archi-init $boot_network archi_mode=install archi_payload_sha256=$payload_sha
    initrd $grub_initramfs
}
EOF
    # GRUB reads the filesystem directly and ignores these bits, so tightening
    # them costs nothing; on a vfat ESP the chmod simply cannot take effect.
    chmod 0600 "$custom_cfg" 2>/dev/null || true
    log "Reinstall entry written to $custom_cfg"

    # Select the entry for the next boot only. As a persistent GRUB_DEFAULT it
    # would keep winning after a failed or held run, so every later reboot would
    # re-enter Alpine and erase the disk again; one-shot falls back to the
    # system that is already installed.
    grub_reboot=$(grub_tool reboot) ||
        die 'Required command not found: grub-reboot (or grub2-reboot)'
    "$grub_reboot" archi >/dev/null 2>&1 ||
        die "Could not select the reinstall entry for the next boot: $grub_reboot archi"
    log "Reinstall entry selected for the next boot only, via $grub_reboot"

    sync
    log 'Arch reinstall entry is staged successfully'
    log 'It remains reversible until reboot: archi.sh --cleanup'
    log 'Rebooting into Alpine; the selected disk will be erased'
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
    need_cmd genfstab
    need_cmd killall
    need_cmd lsblk
    need_cmd mdev
    need_cmd mkfs.ext4
    need_cmd mount
    need_cmd numfmt
    need_cmd pacman-key
    need_cmd pacstrap
    need_cmd partprobe
    need_cmd pidof
    need_cmd reboot
    need_cmd sgdisk
    need_cmd sha256sum
    need_cmd swapoff
    need_cmd umount
    need_cmd wipefs
    need_cmd yes

    expected_sha='' actual_sha=''
    expected_sha=$(cmdline_value archi_payload_sha256)
    actual_sha=$(sha256_file "$ARCHI_SOURCE_FILE")
    printf '%s\n' "$expected_sha" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$' &&
        [ "$actual_sha" = "$expected_sha" ] ||
        die "Installer payload checksum mismatch (expected $expected_sha, got $actual_sha)"

    disk='' hostname='' timezone='' dns='' authorized_key='' password_hash='' package_mirror='' extra_packages='' kernel='' ntp=''
    boot_mode='' swap_mib='' hold='' boot_cidr='' boot_gateway='' boot_mac=''
    ssh_port='' bbr='' fail2ban='' firmware='' ethx='' grub_timeout=''
    [ -r "$ARCHI_CONFIG_FILE" ] ||
        die "Installer configuration is missing: $ARCHI_CONFIG_FILE"
    disk=$(config_value disk)
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
    ssh_port=$(config_value ssh_port)
    bbr=$(config_value bbr)
    fail2ban=$(config_value fail2ban)
    firmware=$(config_value firmware)
    ethx=$(config_value ethx)
    grub_timeout=$(config_value grub_timeout)

    validate_hostname "$hostname"
    validate_packages "$extra_packages"
    validate_dns_servers "$dns"
    case $disk in /dev/*) [ -b "$disk" ] || die "Target disk is unavailable: $disk" ;; *) die "Target disk is unavailable: $disk" ;; esac
    [ "$(lsblk -ndo TYPE "$disk")" = disk ] || die "Target is not a whole disk: $disk"
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
    case $firmware in true|false) ;; *) die 'Invalid firmware setting' ;; esac
    case $ethx in true|false) ;; *) die 'Invalid ethx setting' ;; esac
    case $hold in 0|1) ;; *) die 'Invalid hold setting' ;; esac
    validate_uint_range 'GRUB timeout' "$grub_timeout" 60
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
    probe_url 'pacman core repository' "$(repo_db_url "$package_mirror" core)"

    root_ssh_authentication=password
    [ -n "$authorized_key" ] && root_ssh_authentication='key only'
    cat <<EOF
[archi] Verified install plan inside Alpine
  disk:             $disk (size $(numfmt --to=iec "$(blockdev --getsize64 "$disk")"))
  boot mode:        $boot_mode
  hostname:         $hostname
  package mirror:   $package_mirror
  root SSH:         $root_ssh_authentication
  SSH port:         $ssh_port
  NTP:              $ntp
  firmware bundle:  $firmware
  TCP BBR:          $bbr
  Fail2ban:         $fail2ban
  swap:             ${swap_mib} MiB
EOF

    if [ "$hold" = 1 ] && [ "${ARCHI_FORCE_INSTALL:-0}" != 1 ]; then
        log 'Hold mode is active; no disk changes were made.'
        log 'SSH is available with the configured root authentication.'
        log 'To continue destructively: ARCHI_FORCE_INSTALL=1 /root/archi.sh'
        return 0
    fi

    disk_size=''
    disk_size=$(blockdev --getsize64 "$disk")
    [ "$disk_size" -ge 8589934592 ] || die 'Target disk must be at least 8 GiB'
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
    # Building the keyring is tens of seconds of gpg work in the Alpine tmpfs and
    # touches nothing on the target, so it overlaps with the wipe, the
    # partitioning and the mkfs. It is waited for before pacstrap needs it.
    log 'Initializing the Arch Linux package-signing keyring'
    { pacman-key --init && pacman-key --populate archlinux; } >/tmp/archi-keyring.log 2>&1 &
    keyring_pid=$!

    log "ERASING and partitioning $disk"
    swapoff -a 2>/dev/null || true
    wipefs --all --force "$disk"
    sgdisk --zap-all "$disk"

    boot_partition='' root_partition=''
    boot_partition=$(partition_path "$disk" 1)
    root_partition=$(partition_path "$disk" 2)
    if [ "$boot_mode" = efi ]; then
        sgdisk --new=1:1MiB:+512MiB --typecode=1:ef00 --change-name=1:EFI \
            --new=2:0:0 --typecode=2:8304 --change-name=2:ROOT "$disk"
    else
        sgdisk --new=1:1MiB:+2MiB --typecode=1:ef02 --change-name=1:BIOSBOOT \
            --new=2:0:0 --typecode=2:8304 --change-name=2:ROOT "$disk"
    fi
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
        install -d /mnt/boot
        mount "$boot_partition" /mnt/boot
    fi

    packages=''
    # coreutils comes with base, and mkinitcpio uses libarchive rather than cpio.
    packages="base $kernel grub openssh sudo qemu-guest-agent
        inetutils bash-completion wget curl vim nano"
    [ "$fail2ban" = true ] && packages="$packages fail2ban nftables"
    [ "$firmware" = true ] && packages="$packages linux-firmware"
    if [ "$boot_mode" = efi ]; then packages="$packages efibootmgr"; fi
    case $(awk -F: '/vendor_id/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' /proc/cpuinfo) in
        GenuineIntel) packages="$packages intel-ucode" ;;
        AuthenticAMD) packages="$packages amd-ucode" ;;
    esac
    packages="$packages $extra_packages"
    # Every package token was validated before it reached this point.
    # shellcheck disable=SC2086
    set -- $packages

    install -d -m 0755 /mnt/etc
    printf 'KEYMAP=us\n' > /mnt/etc/vconsole.conf
    chmod 0644 /mnt/etc/vconsole.conf

    wait "$keyring_pid" || { cat /tmp/archi-keyring.log; die 'Could not build the Arch package-signing keyring'; }
    log 'Arch Linux package-signing keyring is ready'

    log "Installing packages: $*"
    pacstrap_ok=false
    for _ in 1 2 3; do
        if yes | pacstrap -c /mnt "$@"; then
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
    genfstab -U /mnt > /mnt/etc/fstab
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

    if [ "$bbr" = true ]; then
        install -d -m 0755 /mnt/etc/sysctl.d
        cat > /mnt/etc/sysctl.d/99-archi-bbr.conf <<EOF
net.core.default_qdisc = fq
net.core.somaxconn = 16384
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_syncookies = 1
EOF
        chmod 0644 /mnt/etc/sysctl.d/99-archi-bbr.conf
    fi

    install -d -m 0755 /mnt/etc/systemd/network
    if [ -n "$boot_cidr" ] && [ -n "$boot_gateway" ] && [ -n "$boot_mac" ]; then
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
        cat > /mnt/etc/fail2ban/jail.d/sshd.local <<EOF
[DEFAULT]
backend = systemd
banaction = nftables
banaction_allports = nftables[type=allports]
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

    if [ "$boot_mode" = efi ]; then
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
    if [ "$ethx" = true ]; then
        install -d -m 0755 /mnt/etc/udev/rules.d
        ln -sfn /dev/null /mnt/etc/udev/rules.d/80-net-setup-link.rules
    fi
    arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
    # pacstrap's mkinitcpio hook already built these, and /etc/vconsole.conf was
    # in place before pacstrap ran so that build is complete. Rebuilding costs
    # another half minute, but skipping it blindly would leave an unbootable
    # system if the hook ever did not fire, so check instead of assuming.
    if ! ls /mnt/boot/initramfs-*.img >/dev/null 2>&1; then
        warn 'No initramfs was generated during pacstrap; building it now'
        arch-chroot /mnt mkinitcpio -P
    fi

    if [ -x /mnt/usr/bin/qemu-ga ]; then
        arch-chroot /mnt systemctl enable qemu-guest-agent.service
    fi
    ln -sfn /run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf

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
    sync
    target='' unmounted=''
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
