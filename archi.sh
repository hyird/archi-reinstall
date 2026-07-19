#!/usr/bin/env bash
# archi.sh - GRUB-staged, unattended Arch Linux network reinstall
#
# The same file has two modes:
#   1. On the existing Linux system it stages the official ArchISO kernel and
#      initramfs in /boot and creates a one-time GRUB entry.
#   2. ArchISO downloads this file through its official script=<URL> facility;
#      the script then partitions the selected disk and installs Arch Linux.

set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true
umask 077

readonly ARCHI_PAYLOAD_ID='archi-network-reinstall-v1'
readonly ARCHI_VERSION='0.1.0'
readonly DEFAULT_ISO_MIRROR='https://geo.mirror.pkgbuild.com/iso/latest'
readonly DEFAULT_PACKAGE_MIRROR='https://geo.mirror.pkgbuild.com/$repo/os/$arch'
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

Required for staging:
  --script-url URL             HTTP(S) URL from which ArchISO downloads this
                               exact script after reboot.

Stage options:
  --iso-mirror URL             Arch ISO "latest" directory.
  --package-mirror URL         Pacman mirror containing $repo/os/$arch.
  --authorized-key-file FILE   File containing the root SSH public key.
  --disk DEVICE                Whole target disk, for example /dev/vda.
  --hostname NAME              Installed hostname (default: current hostname).
  --timezone ZONE              Installed timezone (default: UTC).
  --dns "ADDR ..."             DNS servers written to systemd-networkd config.
  --kernel PACKAGE             linux or linux-lts (default: linux).
  --extra-packages "PKG ..."   Extra official repository packages.
  --swap-mib N                 Swap file size in MiB (default: 1024, 0 disables).
  --boot-mode MODE             auto, bios, or efi (default: auto).
  --install-dir DIR            Staging directory under /boot.
  --hold                       Boot ArchISO, enable key-only SSH, but do not wipe.
                               Continue there with:
                               ARCHI_FORCE_INSTALL=1 /tmp/startup_script
  --power-off                  Power off instead of reboot after installation.
  --reboot                     Reboot immediately after staging.
  --yes                        Required together with --reboot.
  --force-low-memory           Allow staging with less than 1500 MiB RAM.
  --dry-run                    Validate and print the plan without changing files.
  --cleanup                    Remove the staged GRUB entry and downloaded files.
  --help                       Show this help.
  --version                    Show script version.

The target must be x86_64, use GRUB 2, have wired DHCP during ArchISO boot,
and have enough RAM for the network live image (2 GiB minimum recommended).
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
    local script_url=''
    local iso_mirror=$DEFAULT_ISO_MIRROR
    local package_mirror=$DEFAULT_PACKAGE_MIRROR
    local authorized_key_file=''
    local disk=''
    local hostname
    local timezone='UTC'
    local dns=''
    local kernel='linux'
    local extra_packages=''
    local swap_mib=1024
    local boot_mode='auto'
    local install_dir=$DEFAULT_INSTALL_DIR
    local hold=false power_off=false reboot_now=false assume_yes=false
    local force_low_memory=false dry_run=false cleanup=false

    hostname=$(hostname -s 2>/dev/null || printf 'archlinux')
    if [[ -r /root/.ssh/authorized_keys ]]; then
        authorized_key_file=/root/.ssh/authorized_keys
    elif [[ -n ${HOME:-} && -r $HOME/.ssh/authorized_keys ]]; then
        authorized_key_file=$HOME/.ssh/authorized_keys
    fi

    while (($#)); do
        case $1 in
            --script-url) script_url=${2:?missing value}; shift 2 ;;
            --iso-mirror) iso_mirror=${2:?missing value}; shift 2 ;;
            --package-mirror) package_mirror=${2:?missing value}; shift 2 ;;
            --authorized-key-file) authorized_key_file=${2:?missing value}; shift 2 ;;
            --disk) disk=${2:?missing value}; shift 2 ;;
            --hostname) hostname=${2:?missing value}; shift 2 ;;
            --timezone) timezone=${2:?missing value}; shift 2 ;;
            --dns) dns=${2:?missing value}; shift 2 ;;
            --kernel) kernel=${2:?missing value}; shift 2 ;;
            --extra-packages) extra_packages=${2:?missing value}; shift 2 ;;
            --swap-mib) swap_mib=${2:?missing value}; shift 2 ;;
            --boot-mode) boot_mode=${2:?missing value}; shift 2 ;;
            --install-dir) install_dir=${2:?missing value}; shift 2 ;;
            --hold) hold=true; shift ;;
            --power-off) power_off=true; shift ;;
            --reboot) reboot_now=true; shift ;;
            --yes) assume_yes=true; shift ;;
            --force-low-memory) force_low_memory=true; shift ;;
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
    need_cmd lsblk
    need_cmd sha256sum
    need_cmd stat

    [[ -n $script_url ]] || die '--script-url is required'
    [[ -n $authorized_key_file ]] || die '--authorized-key-file is required'
    iso_mirror=$(trim_trailing_slash "$iso_mirror")
    package_mirror=$(trim_trailing_slash "$package_mirror")
    validate_url '--script-url' "$script_url"
    validate_url '--iso-mirror' "$iso_mirror"
    validate_url '--package-mirror' "$package_mirror"
    validate_hostname "$hostname"
    validate_packages "$extra_packages"
    [[ $kernel == linux || $kernel == linux-lts ]] || die '--kernel must be linux or linux-lts'
    [[ $swap_mib =~ ^[0-9]+$ ]] || die '--swap-mib must be a non-negative integer'
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
    if (( mem_kib < 1500000 )) && [[ $force_low_memory != true ]]; then
        die "Only $((mem_kib / 1024)) MiB RAM detected; Arch netboot needs about 2 GiB. Use --force-low-memory to override"
    elif (( mem_kib < 2000000 )); then
        warn "Only $((mem_kib / 1024)) MiB RAM detected; ArchISO network boot may run out of memory"
    fi

    local authorized_key
    authorized_key=$(first_public_key "$authorized_key_file")
    [[ -n $authorized_key ]] || die "No supported SSH public key found in $authorized_key_file"

    local payload_tmp payload_sha current_sha
    payload_tmp=$(mktemp)
    trap 'rm -f -- "${payload_tmp:-}"' RETURN
    download_file "$script_url" "$payload_tmp" 1000
    grep -Fq "ARCHI_PAYLOAD_ID='archi-network-reinstall-v1'" "$payload_tmp" ||
        die 'The script URL does not contain a compatible archi payload'
    payload_sha=$(sha256sum "$payload_tmp" | awk '{print $1}')
    current_sha=$(sha256sum "${BASH_SOURCE[0]}" | awk '{print $1}')
    if [[ $current_sha != "$payload_sha" ]]; then
        warn 'The hosted payload differs from the local staging script; the hosted copy will perform the installation'
    fi

    local kernel_url initramfs_url airootfs_url airootfs_sig_url core_url
    kernel_url="$iso_mirror/arch/boot/x86_64/vmlinuz-linux"
    initramfs_url="$iso_mirror/arch/boot/x86_64/initramfs-linux.img"
    airootfs_url="$iso_mirror/arch/x86_64/airootfs.sfs"
    airootfs_sig_url="$airootfs_url.cms.sig"
    core_url=${package_mirror//\$repo/core}
    core_url=${core_url//\$arch/x86_64}
    core_url="$core_url/core.db"

    probe_url 'ArchISO kernel' "$kernel_url"
    probe_url 'ArchISO initramfs' "$initramfs_url"
    probe_url 'ArchISO root image' "$airootfs_url"
    probe_url 'ArchISO CMS signature' "$airootfs_sig_url"
    probe_url 'pacman core repository' "$core_url"

    cat <<EOF
[archi] Installation plan
  target disk:       $disk (WILL BE ERASED AFTER REBOOT)
  boot mode:         $boot_mode
  hostname:          $hostname
  timezone:          $timezone
  ISO mirror:        $iso_mirror
  package mirror:    $package_mirror
  payload SHA-256:   $payload_sha
  root SSH key:      $(printf '%s' "$authorized_key" | awk '{print $1, $NF}')
  kernel package:    $kernel
  swap:              ${swap_mib} MiB
  extra packages:    ${extra_packages:-none}
  hold before wipe:  $hold
  stage directory:   $install_dir
EOF
    if [[ $dry_run == true ]]; then
        log 'Dry run completed; no files or boot settings were changed'
        return 0
    fi

    mkdir -p -- "$install_dir"
    download_file "$kernel_url" "$install_dir/vmlinuz-linux" 8000000
    download_file "$initramfs_url" "$install_dir/initramfs-linux.img" 30000000

    local disk_b64 hostname_b64 timezone_b64 dns_b64 key_b64 package_mirror_b64
    local extra_packages_b64 kernel_b64
    disk_b64=$(encode_b64 "$disk")
    hostname_b64=$(encode_b64 "$hostname")
    timezone_b64=$(encode_b64 "$timezone")
    dns_b64=$(encode_b64 "$dns")
    key_b64=$(encode_b64 "$authorized_key")
    package_mirror_b64=$(encode_b64 "$package_mirror")
    extra_packages_b64=$(encode_b64 "$extra_packages")
    kernel_b64=$(encode_b64 "$kernel")

    local grub_prefix grub_stage_dir grub_kernel grub_initramfs hold_flag power_flag
    if mountpoint -q /boot; then
        grub_prefix=''
    else
        grub_prefix='/boot'
    fi
    grub_stage_dir=${install_dir#/boot}
    grub_kernel="$grub_prefix$grub_stage_dir/vmlinuz-linux"
    grub_initramfs="$grub_prefix$grub_stage_dir/initramfs-linux.img"
    hold_flag=0; [[ $hold == true ]] && hold_flag=1
    power_flag=0; [[ $power_off == true ]] && power_flag=1

    cat > "$install_dir/manifest" <<EOF
ARCHI_PAYLOAD_ID=$ARCHI_PAYLOAD_ID
version=$ARCHI_VERSION
created=$(date -Is)
disk=$disk
boot_mode=$boot_mode
iso_mirror=$iso_mirror
package_mirror=$package_mirror
payload_sha256=$payload_sha
kernel_sha256=$(sha256sum "$install_dir/vmlinuz-linux" | awk '{print $1}')
initramfs_sha256=$(sha256sum "$install_dir/initramfs-linux.img" | awk '{print $1}')
EOF

    cat > "$GRUB_ENTRY_FILE" <<EOF
#!/bin/sh
# ARCHI_PAYLOAD_ID=archi-network-reinstall-v1
exec tail -n +4 \$0
menuentry 'Arch Linux network reinstall (ERASES TARGET DISK)' --id archi {
    insmod part_gpt
    insmod part_msdos
    insmod ext2
    linux $grub_kernel archisobasedir=arch archiso_http_srv=$iso_mirror ip=dhcp cms_verify=y script=$script_url archi_mode=install archi_payload_sha256=$payload_sha archi_disk_b64=$disk_b64 archi_hostname_b64=$hostname_b64 archi_timezone_b64=$timezone_b64 archi_dns_b64=$dns_b64 archi_key_b64=$key_b64 archi_package_mirror_b64=$package_mirror_b64 archi_extra_packages_b64=$extra_packages_b64 archi_kernel_b64=$kernel_b64 archi_boot_mode=$boot_mode archi_swap_mib=$swap_mib archi_hold=$hold_flag archi_poweroff=$power_flag
    initrd $grub_initramfs
}
EOF
    chmod 0755 "$GRUB_ENTRY_FILE"

    mkdir -p -- "$(dirname "$GRUB_DEFAULT_FILE")"
    cat > "$GRUB_DEFAULT_FILE" <<'EOF'
# Temporary default used by archi.sh. Remove with: archi.sh --cleanup
GRUB_DEFAULT=archi
GRUB_TIMEOUT=5
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
        log 'Rebooting into ArchISO; the selected disk will be erased'
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
    warn "Installation failed with exit code $rc. ArchISO is being left online for diagnosis."
    systemctl start sshd.service >/dev/null 2>&1 || true
    sync
    exit "$rc"
}

installer_main() {
    local log_file=/tmp/archi-install.log
    exec > >(tee -a "$log_file") 2>&1
    trap installer_failure ERR

    log "ArchISO installer mode, archi.sh $ARCHI_VERSION"
    [[ $ARCHI_PAYLOAD_ID == archi-network-reinstall-v1 ]] || die 'Internal payload marker mismatch'
    need_cmd arch-chroot
    need_cmd base64
    need_cmd blockdev
    need_cmd curl
    need_cmd genfstab
    need_cmd lsblk
    need_cmd pacstrap
    need_cmd sgdisk
    need_cmd sha256sum

    local expected_sha actual_sha
    expected_sha=$(cmdline_value archi_payload_sha256)
    actual_sha=$(sha256sum "${BASH_SOURCE[0]}" | awk '{print $1}')
    [[ $expected_sha =~ ^[0-9a-f]{64}$ && $actual_sha == "$expected_sha" ]] ||
        die "Installer payload checksum mismatch (expected $expected_sha, got $actual_sha)"

    local disk hostname timezone dns authorized_key package_mirror extra_packages kernel
    local boot_mode swap_mib hold power_off
    disk=$(decode_b64 "$(cmdline_value archi_disk_b64)")
    hostname=$(decode_b64 "$(cmdline_value archi_hostname_b64)")
    timezone=$(decode_b64 "$(cmdline_value archi_timezone_b64)")
    dns=$(decode_b64 "$(cmdline_value archi_dns_b64)")
    authorized_key=$(decode_b64 "$(cmdline_value archi_key_b64)")
    package_mirror=$(decode_b64 "$(cmdline_value archi_package_mirror_b64)")
    extra_packages=$(decode_b64 "$(cmdline_value archi_extra_packages_b64)")
    kernel=$(decode_b64 "$(cmdline_value archi_kernel_b64)")
    boot_mode=$(cmdline_value archi_boot_mode)
    swap_mib=$(cmdline_value archi_swap_mib)
    hold=$(cmdline_value archi_hold)
    power_off=$(cmdline_value archi_poweroff)

    validate_hostname "$hostname"
    validate_packages "$extra_packages"
    [[ $disk == /dev/* && -b $disk ]] || die "Target disk is unavailable: $disk"
    [[ $(lsblk -ndo TYPE "$disk") == disk ]] || die "Target is not a whole disk: $disk"
    [[ $boot_mode == bios || $boot_mode == efi ]] || die "Invalid boot mode: $boot_mode"
    [[ $swap_mib =~ ^[0-9]+$ ]] || die 'Invalid swap size'
    [[ $kernel == linux || $kernel == linux-lts ]] || die 'Invalid kernel package'
    [[ -e /usr/share/zoneinfo/$timezone ]] || die "Unknown timezone: $timezone"
    validate_url 'package mirror' "$package_mirror"

    install -d -m 0700 /root/.ssh
    printf '%s\n' "$authorized_key" > /root/.ssh/authorized_keys
    chmod 0600 /root/.ssh/authorized_keys
    install -d -m 0755 /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/60-archi-key-only.conf <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
    systemctl restart sshd.service
    cp -f -- "${BASH_SOURCE[0]}" /root/archi-installer.sh
    chmod 0700 /root/archi-installer.sh

    systemctl start pacman-init.service 2>/dev/null || true
    printf 'Server = %s\n' "$package_mirror" > /etc/pacman.d/mirrorlist
    local core_url
    core_url=${package_mirror//\$repo/core}
    core_url=${core_url//\$arch/x86_64}
    probe_url 'pacman core repository' "$core_url/core.db"

    cat <<EOF
[archi] Verified install plan inside ArchISO
  disk:             $disk (size $(numfmt --to=iec "$(blockdev --getsize64 "$disk")"))
  boot mode:        $boot_mode
  hostname:         $hostname
  package mirror:   $package_mirror
  root SSH:         key only
  swap:             ${swap_mib} MiB
EOF

    if [[ $hold == 1 && ${ARCHI_FORCE_INSTALL:-0} != 1 ]]; then
        log 'Hold mode is active; no disk changes were made.'
        log 'SSH is available with the supplied root key.'
        log 'To continue destructively: ARCHI_FORCE_INSTALL=1 /tmp/startup_script'
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
    partprobe "$disk"
    udevadm settle
    [[ -b $root_partition ]] || die "Root partition did not appear: $root_partition"

    mkfs.ext4 -F -L ArchRoot "$root_partition"
    mount "$root_partition" /mnt
    if [[ $boot_mode == efi ]]; then
        [[ -b $boot_partition ]] || die "EFI partition did not appear: $boot_partition"
        mkfs.fat -F 32 -n ARCH_EFI "$boot_partition"
        install -d /mnt/boot
        mount "$boot_partition" /mnt/boot
    fi

    local -a packages
    packages=(base "$kernel" linux-firmware grub openssh sudo)
    if [[ $boot_mode == efi ]]; then packages+=(efibootmgr); fi
    case $(awk -F: '/vendor_id/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' /proc/cpuinfo) in
        GenuineIntel) packages+=(intel-ucode) ;;
        AuthenticAMD) packages+=(amd-ucode) ;;
    esac
    local package
    for package in $extra_packages; do packages+=("$package"); done

    log "Installing packages: ${packages[*]}"
    pacstrap -K /mnt "${packages[@]}"
    genfstab -U /mnt > /mnt/etc/fstab

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

    install -d -m 0755 /mnt/etc/systemd/network
    cat > /mnt/etc/systemd/network/20-wired.network <<EOF
[Match]
Type=ether

[Network]
DHCP=yes
IPv6AcceptRA=yes
${dns:+DNS=$dns}
EOF
    ln -sf /run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf
    systemctl --root=/mnt enable systemd-networkd.service systemd-resolved.service sshd.service

    install -d -m 0700 /mnt/root/.ssh
    printf '%s\n' "$authorized_key" > /mnt/root/.ssh/authorized_keys
    chmod 0600 /mnt/root/.ssh/authorized_keys
    install -d -m 0755 /mnt/etc/ssh/sshd_config.d
    cat > /mnt/etc/ssh/sshd_config.d/60-key-only.conf <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
    arch-chroot /mnt passwd --lock root

    if [[ $boot_mode == efi ]]; then
        arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot \
            --bootloader-id=ARCH --removable --no-nvram
    else
        arch-chroot /mnt grub-install --target=i386-pc --recheck "$disk"
    fi
    arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
    arch-chroot /mnt mkinitcpio -P

    if [[ -x /mnt/usr/bin/qemu-ga ]]; then
        systemctl --root=/mnt enable qemu-guest-agent.service
    fi

    cp -f -- "$log_file" /mnt/root/archi-install.log
    cp -f -- "${BASH_SOURCE[0]}" /mnt/root/archi.sh
    chmod 0600 /mnt/root/archi-install.log
    chmod 0700 /mnt/root/archi.sh
    sync
    umount -R /mnt
    log 'Arch Linux installation completed successfully'

    trap - ERR
    if [[ $power_off == 1 ]]; then
        systemctl poweroff
    else
        systemctl reboot
    fi
}

if is_install_environment; then
    installer_main "$@"
else
    stage_main "$@"
fi
