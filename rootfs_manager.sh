#!/bin/bash
# =============================================================================
# rootfs_manager.sh
# Mount an Ubuntu rootfs .img and perform various install/configuration tasks:
#   - Run install.sh from a tarball (original)
#   - Add arbitrary files into the rootfs
#   - Install a kernel module (.ko) into the rootfs
#   - Add and enable a systemd service
#   - Install a .deb package
#   - Run a .run self-extracting installer inside the rootfs
#
# Requires: root / sudo, losetup, mount, chroot, tar, dpkg
#
# Usage:
#   sudo ./rootfs_manager.sh <command> <rootfs.img> [options...]
#
# Commands:
#   install    <rootfs.img> <package.tar.gz> [mount_point]
#              Mount rootfs, extract tarball to /opt/installer, run install.sh
#
#   add-file   <rootfs.img> <src_path> <dest_path_in_rootfs> [mount_point]
#              Copy a file (or directory) into the rootfs at dest_path
#
#   add-module <rootfs.img> <module.ko> [kernel_version] [mount_point]
#              Install a .ko kernel module and run depmod inside the rootfs
#
#   add-service <rootfs.img> <service.service> [mount_point]
#              Copy a systemd unit file and enable it via systemctl enable
#
#   add-deb    <rootfs.img> <package.deb> [mount_point]
#              Install a .deb package inside the rootfs using dpkg -i
#
#   add-run    <rootfs.img> <installer.run> [mount_point] [-- <installer-args>...]
#              Stage a .run self-extracting installer inside the rootfs,
#              execute it in a chroot, then remove the staged file.
#              Arguments after -- are passed verbatim to the installer.
#
# =============================================================================
# set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { error "$*"; exit 1; }

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
    echo -e "${BOLD}Usage:${NC}"
    echo "  sudo $0 install     <rootfs.img> <package.tar.gz> [mount_point]"
    echo "  sudo $0 add-file    <rootfs.img> <src_path> <dest_path_in_rootfs> [mount_point]"
    echo "  sudo $0 add-module  <rootfs.img> <module.ko> [kernel_version] [mount_point]"
    echo "  sudo $0 add-service <rootfs.img> <service.service> [mount_point]"
    echo "  sudo $0 add-deb     <rootfs.img> <package.deb> [mount_point]"
    echo "  sudo $0 add-run     <rootfs.img> <installer.run> [mount_point] [-- <installer-args>...]"
    echo "  sudo $0 remove-oeminfo-section     <rootfs.img> <section_key>"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo "  sudo $0 install     ubuntu.img myapp.tar.gz"
    echo "  sudo $0 add-file    ubuntu.img ./configs/99-custom.conf /etc/sysctl.d/99-custom.conf"
    echo "  sudo $0 add-module  ubuntu.img mydriver.ko 5.15.0-1023-nvidia"
    echo "  sudo $0 add-service ubuntu.img myapp.service"
    echo "  sudo $0 add-deb     ubuntu.img libfoo_1.0_arm64.deb"
    echo "  sudo $0 add-run     ubuntu.img cuda_12.3_installer.run"
    echo "  sudo $0 add-run     ubuntu.img cuda_12.3_installer.run /mnt/rootfs -- --silent --toolkit"
    exit 1
}

# ── Argument validation ───────────────────────────────────────────────────────
[[ $# -lt 2 ]] && usage
[[ $EUID -eq 0 ]] || die "This script must be run as root (sudo)."

COMMAND="$1"
ROOTFS_IMG="$(realpath "$2")"
[[ -f "$ROOTFS_IMG" ]] || die "Rootfs image not found: $ROOTFS_IMG"

# ── Dependency check ──────────────────────────────────────────────────────────
for cmd in losetup mount umount chroot tar file; do
    command -v "$cmd" &>/dev/null || die "Required command not found: $cmd"
done

# ── State for cleanup ─────────────────────────────────────────────────────────
LOOP_DEV=""
MOUNTED_PSEUDO=()
MOUNTED_ROOT=false
MOUNT_DIR=""
OEMINFO_FILE="/etc/OEMInfo.ini"

# ── Cleanup trap ──────────────────────────────────────────────────────────────
cleanup() {
    local exit_code=$?
    info "Running cleanup …"

    # Unmount pseudo-filesystems in reverse order
    for fs in "${MOUNTED_PSEUDO[@]:-}"; do
        if mountpoint -q "$fs" 2>/dev/null; then
            umount -lf "$fs" 2>/dev/null && info "Unmounted $fs" || warn "Could not unmount $fs"
        fi
    done

    # Unmount rootfs
    if $MOUNTED_ROOT && [[ -n "$MOUNT_DIR" ]] && mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
        umount -lf "$MOUNT_DIR" 2>/dev/null && info "Unmounted $MOUNT_DIR" || warn "Could not unmount $MOUNT_DIR"
    fi

    # Detach loop device
    if [[ -n "$LOOP_DEV" ]] && losetup "$LOOP_DEV" &>/dev/null; then
        losetup -d "$LOOP_DEV" && info "Detached loop device $LOOP_DEV" || warn "Could not detach $LOOP_DEV"
    fi

    [[ $exit_code -ne 0 ]] && error "Script exited with errors (code $exit_code)."
    exit "$exit_code"
}
trap cleanup EXIT INT TERM

# =============================================================================
# ── Shared helper: mount rootfs image ────────────────────────────────────────
# =============================================================================
mount_rootfs_image() {
    local img="$1"
    # MOUNT_DIR is set by the caller before invoking this function

    echo ""
    echo -e "${BOLD}=== Mounting Ubuntu Rootfs ===${NC}"
    echo ""

    info "Inspecting image: $img"
    local img_type
    img_type=$(file -b "$img")
    info "Detected: $img_type"

    # ── Set up loop device ────────────────────────────────────────────────────
    info "Attaching image to loop device …"
    local root_part
    if echo "$img_type" | grep -qi "partition\|MBR\|GPT\|DOS/MBR"; then
        LOOP_DEV=$(losetup --find --show --sector-size 4096 --partscan "$img")
        info "Partitioned image detected. Loop device: $LOOP_DEV"
        partprobe "$LOOP_DEV"
        sleep 1
        blkid 2>&1 > /dev/null
        root_part=$(lsblk -nro NAME,SIZE,FSTYPE "$LOOP_DEV" -b | sort -nk2 | awk '$3=="ext4"{print "/dev/"$1}' | tail -n 1)
        [[ -n "$root_part" ]] || die "Could not find a partition on $LOOP_DEV"
        info "Using root partition: $root_part"
    else
        LOOP_DEV=$(losetup --find --show "$img")
        root_part="$LOOP_DEV"
        info "Raw filesystem image. Loop device: $LOOP_DEV"
    fi

    # ── Mount rootfs ──────────────────────────────────────────────────────────
    info "Creating mount point: $MOUNT_DIR"
    mkdir -p "$MOUNT_DIR"
    info "Mounting $root_part → $MOUNT_DIR"
    mount "$root_part" "$MOUNT_DIR"
    MOUNTED_ROOT=true
    success "Rootfs mounted."

    [[ -d "$MOUNT_DIR/etc" && -d "$MOUNT_DIR/usr" ]] || \
        die "Mounted filesystem does not look like a valid Linux root (missing /etc or /usr)."

    # ── Bind pseudo-filesystems ───────────────────────────────────────────────
    info "Binding pseudo-filesystems for chroot …"
    mount_pseudo() {
        local type="$1" src="$2" tgt="${MOUNT_DIR}$3"
        mkdir -p "$tgt"
        mount --bind "$src" "$tgt" 2>/dev/null \
            || mount -t "$type" "$type" "$tgt"
        MOUNTED_PSEUDO+=("$tgt")
        info "  mounted $tgt"
    }
    mount_pseudo proc     /proc      /proc
    mount_pseudo sysfs    /sys       /sys
    mount_pseudo devtmpfs /dev       /dev
    mount_pseudo devpts   /dev/pts   /dev/pts
    mount_pseudo tmpfs    /run       /run
    success "Pseudo-filesystems ready."

    # ── DNS passthrough ───────────────────────────────────────────────────────
    if [[ -f /etc/resolv.conf ]]; then
        cp --dereference /etc/resolv.conf "${MOUNT_DIR}/etc/resolv.conf" || warn "Could not copy resolv.conf"
    fi
}

# =============================================================================
# ── Shared helper: run a command inside chroot ───────────────────────────────
# =============================================================================
run_in_chroot() {
    chroot "$MOUNT_DIR" /usr/bin/env -i          \
        HOME=/root                               \
        TERM="${TERM:-xterm}"                    \
        PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        DEBIAN_FRONTEND=noninteractive          \
        /bin/bash -c "$1"
}

# ==============================================================================
# ── OEMInfo Management Functions ──
# ==============================================================================

# Updates /etc/OEMInfo.ini with a record of the operation.
# Returns 0 if new record added, 1 if record already exists.
update_oeminfo() {
    local command_name="$1"
    local extra_info="$2"
    
    # Define the record key (Section Name)
    # Format: [add-deb_package.deb] or [add-run_installer.run]
    local section_key="${command_name}:${extra_info}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Construct the full path to the file in the mounted rootfs
    local rootfs_oeminfo="${MOUNT_DIR}${OEMINFO_FILE}"

    # If the file doesn't exist in rootfs, we must ensure the directory exists
    if [[ ! -d "$(dirname "$rootfs_oeminfo")" ]]; then
        mkdir -p "$(dirname "$rootfs_oeminfo")"
    fi

    # Check if section already exists in the file
    if [[ -f "$rootfs_oeminfo" ]]; then
        if grep -q "$section_key" "$rootfs_oeminfo"; then
            warn "Operation already recorded in OEMInfo.ini: $section_key"
            warn "Skipping execution to prevent redundancy."
            cat "$rootfs_oeminfo"
            return 1
        fi
    fi

    # Append the new record
    info "Recording operation to $rootfs_oeminfo: $section_key"
    cat >> "$rootfs_oeminfo" <<EOF

[$section_key]
Function: ${command_name}
File: ${extra_info}
Timestamp: ${timestamp}
Status: Completed
EOF
    return 0
}

# Function to remove a section from OEMInfo.ini
# Usage: remove_oeminfo "<command_name>" "<extra_info>"
# Example: remove_oeminfo "add-package.deb" ".deb"

cmd_remove_oeminfo_section() {
    info "$#"
    [[ $# -ge 1 ]] || die "Usage: $0 remove-oeminfo-section <rootfs.img> <section_key> [mount_point]"

    # Define the record key (Section Name) - same format as update_oeminfo
    local section_key="$1"
    [[ -n "$section_key" ]] || die "Extra info is required to construct section key"
    
    MOUNT_DIR="${2:-/mnt/ubuntu_rootfs}"

return 0
    mount_rootfs_image "$ROOTFS_IMG"

    # Construct the full path to the file in the mounted rootfs
    local rootfs_oeminfo="${MOUNT_DIR}${OEMINFO_FILE}"
    
    # Check if file exists
    if [[ ! -f "$rootfs_oeminfo" ]]; then
        warn "OEMInfo.ini file does not exist: $rootfs_oeminfo"
        return 1
    fi
    
    # Check if section exists in the file
    if ! grep -q "$section_key" "$rootfs_oeminfo"; then
        warn "Section not found in $OEMInfo.ini: $section_key"
        return 1
    fi
    
    info "Removing section from $OEMInfo.ini: $section_key"
    
    # Create a temporary file
    local temp_file="${rootfs_oeminfo}.tmp"
    
    # Remove the section (header + 4 lines of content) using awk
    # This handles the section header and the following 4 lines (Command, Details, Timestamp, Status)
    awk -v key="$section_key" '
        $0 == key { skip=1; next }
        skip && /^[[:space:]]*$/ { skip=0 }  # Skip blank line after section
        skip && NR > 1 { next }  # Skip the 4 content lines
        { print }
    ' "$rootfs_oeminfo" > "$temp_file"
    
    # Check if the operation was successful
    if [[ $? -eq 0 ]]; then
        # Replace the original file with the temp file
        mv "$temp_file" "$rootfs_oeminfo"
        info "Successfully removed section: $section_key"
        return 0
    else
        # Cleanup temp file on error
        rm -f "$temp_file"
        error "Failed to remove section: $section_key"
        return 1
    fi
}

# =============================================================================
# ── COMMAND: install ─────────────────────────────────────────────────────────
#    Mount rootfs, extract tarball, execute install.sh inside chroot
# =============================================================================
cmd_install() {
    [[ $# -ge 2 ]] || die "Usage: $0 install <rootfs.img> <package.tar.gz> [mount_point]"
    local tarball
    tarball="$(realpath "$1")"
    MOUNT_DIR="${2:-/mnt/ubuntu_rootfs}"
    [[ -f "$tarball" ]] || die "Tarball not found: $tarball"

    mount_rootfs_image "$ROOTFS_IMG"

    if ! update_oeminfo "install" "$img_name"; then
        success "Install already performed for this image. Exiting."
        exit 0
    fi

    # ── Extract tarball ───────────────────────────────────────────────────────
    local install_dir_in_chroot="/opt/installer"
    local install_dir_host="${MOUNT_DIR}${install_dir_in_chroot}"
    info "Extracting tarball: $tarball → ${install_dir_in_chroot} (inside rootfs)"
    mkdir -p "$install_dir_host"

    local tar_flags="-xf"
    case "$tarball" in
        *.tar.gz|*.tgz)   tar_flags="-xzf" ;;
        *.tar.bz2|*.tbz2) tar_flags="-xjf" ;;
        *.tar.xz)          tar_flags="-xJf" ;;
        *.tar.zst)         tar_flags="--zstd -xf" ;;
        *.tar)             tar_flags="-xf"  ;;
        *) warn "Unknown extension; letting tar auto-detect compression." ;;
    esac
    # shellcheck disable=SC2086
    tar $tar_flags "$tarball" -C "$install_dir_host" --strip-components=0
    success "Tarball extracted."

    local install_script_host
    install_script_host="$(find "$install_dir_host" -name install.sh)"
    install_dir_in_chroot=$(dirname "${install_script_host/$MOUNT_DIR/}")
    [[ -f "$install_script_host" ]] || \
        die "install.sh not found inside tarball at ${install_dir_in_chroot}/install.sh"
    chmod +x "$install_script_host"
    info "Found and chmod +x install.sh"

    # ── Run install.sh ────────────────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}─── Running install.sh inside chroot ───${NC}"
    run_in_chroot "
        set -e
        echo '[chroot] Running: ${install_dir_in_chroot}/install.sh'
        cd '${install_dir_in_chroot}'
        echo '1' | bash install.sh
    "
    local exit_code=$?
    echo ""
    [[ $exit_code -eq 0 ]] && success "install.sh completed successfully." \
                             || { error "install.sh exited with code $exit_code."; exit $exit_code; }

    # ── Cleanup installer files ───────────────────────────────────────────────
    rm -rf "$install_dir_host"
    success "Installer files removed from rootfs."
    success "All done."
}

# =============================================================================
# ── COMMAND: add-file ────────────────────────────────────────────────────────
#    Copy a host file (or directory tree) into the rootfs at a given path
# =============================================================================
cmd_add_file() {
    [[ $# -ge 2 ]] || die "Usage: $0 add-file <rootfs.img> <src_path> <dest_path_in_rootfs> [mount_point]"
    local src_path dest_path_in_rootfs
    src_path="$(realpath "$1")"
    dest_path_in_rootfs="$2"
    MOUNT_DIR="${3:-/mnt/ubuntu_rootfs}"

    [[ -e "$src_path" ]] || die "Source path not found: $src_path"

    # dest_path_in_rootfs must be absolute
    [[ "$dest_path_in_rootfs" == /* ]] || \
        die "Destination path must be absolute (e.g. /etc/myapp/config.conf). Got: $dest_path_in_rootfs"

    mount_rootfs_image "$ROOTFS_IMG"

    filename=$(basename "$src_path")
    if ! update_oeminfo "add-file" "$filename"; then
        success "File addition already recorded. Skipping copy."
        exit 0
    fi

    local dest_host="${MOUNT_DIR}${dest_path_in_rootfs}"
    local dest_dir_host
    dest_dir_host="$(dirname "$dest_host")"

    info "Creating parent directory: ${dest_path_in_rootfs%/*}"
    mkdir -p "$dest_dir_host"

    if [[ -d "$src_path" ]]; then
        info "Copying directory: $src_path → $dest_path_in_rootfs"
        cp -a "$src_path/." "$dest_host/"
    else
        info "Copying file: $(basename "$src_path") → $dest_path_in_rootfs"
        cp -a "$src_path" "$dest_host"
    fi

    success "File(s) added to rootfs at: $dest_path_in_rootfs"

    # Show what was placed
    echo ""
    info "Contents at destination:"
    ls -lh "$dest_host" 2>/dev/null || ls -lh "$dest_dir_host" 2>/dev/null
    success "add-file done."
}

# =============================================================================
# ── COMMAND: add-module ──────────────────────────────────────────────────────
#    Install a .ko kernel module into the rootfs and run depmod
# =============================================================================
cmd_add_module() {
    [[ $# -ge 1 ]] || die "Usage: $0 add-module <rootfs.img> <module.ko> [kernel_version] [mount_point]"
    local module_path kernel_version
    module_path="$(realpath "$1")"
    [[ -f "$module_path" ]] || die "Kernel module not found: $module_path"

    # kernel_version: auto-detect from rootfs if not specified
    kernel_version="${2:-}"
    MOUNT_DIR="${3:-/mnt/ubuntu_rootfs}"

    mount_rootfs_image "$ROOTFS_IMG"

    filename=$(basename "$module_path")
    # Record ID
    if ! update_oeminfo "add-module" "$filename"; then
        success "Module addition already recorded. Skipping."
        exit 0
    fi

    # ── Helper: validate kernel version directory integrity ────────────────────
    validate_kernel_version() {
        local kver="$1"
        local modules_base="${MOUNT_DIR}/lib/modules/${kver}"

        # Check if kernel version directory exists
        if [[ ! -d "$modules_base" ]]; then
            return 1
        fi

        # Check for required kernel files (indicates valid installation)
        if [[ ! -f "${modules_base}/kernel/arch" && \
              ! -f "${modules_base}/modules.builtin" && \
              ! -d "${modules_base}/kernel" ]]; then
            return 1
        fi

        return 0
    }

    # ── Helper: extract module magic from .ko file ────────────────────────────
    get_module_magic() {
        local kmod="$1"
        # Magic numbers indicate kernel version, architecture, and modversions requirement
        # ELF modules have signature at offset ~16 bytes; extract kernel module magic
        if command -v objdump &>/dev/null; then
            objdump -s "$kmod" 2>/dev/null | grep -A2 "^" | head -n 5 || echo "unknown"
        else
            file "$kmod"
        fi
    }

    # ── Helper: auto-detect best kernel version ──────────────────────────────
    auto_detect_kernel_version() {
        local modules_dir="${MOUNT_DIR}/lib/modules"
        local candidates=()
        local best_version=""

        if [[ ! -d "$modules_dir" ]]; then
            return 1
        fi

        # Collect all valid kernel versions
        mapfile -t candidates < <(
            ls -1 "$modules_dir" 2>/dev/null | while read -r kver; do
                if validate_kernel_version "$kver"; then
                    echo "$kver"
                fi
            done | sort -V
        )

        if [[ ${#candidates[@]} -eq 0 ]]; then
            return 1
        fi

        # Prefer newer kernels; pick the latest valid one
        best_version="${candidates[-1]}"
        echo "$best_version"
        return 0
    }

    # Auto-detect kernel version if not provided
    if [[ -z "$kernel_version" ]]; then
        info "No kernel version specified, auto-detecting from rootfs …"
        kernel_version=$(auto_detect_kernel_version)

        if [[ -z "$kernel_version" ]]; then
            error "Could not auto-detect kernel version."
            error "Available (invalid) directories in /lib/modules:"
            ls -1 "${MOUNT_DIR}/lib/modules" 2>/dev/null | sed 's/^/  /'
            die "Please specify kernel version explicitly."
        fi

        validate_kernel_version "$kernel_version" || \
            warn "Detected kernel version '$kernel_version' may not be fully valid; proceeding anyway."
        info "Auto-detected kernel version: $kernel_version"
    else
        info "Using specified kernel version: $kernel_version"
        # Validate the explicitly-provided version
        if ! validate_kernel_version "$kernel_version"; then
            warn "Kernel version '$kernel_version' directory not fully validated."
            warn "  (Missing /lib/modules/${kernel_version}/kernel or modules.builtin)"
            warn "  Proceeding anyway — module installation may fail."
        fi
    fi

    # ── Inspect module magic and warn on potential mismatches ────────────────
    echo ""
    echo -e "${BOLD}─── Validating module compatibility ───${NC}"
    info "Module file: $(basename "$module_path")"
    info "Module type: $(file -b "$module_path")"

    # Try to extract architecture from module (if objdump available)
    if command -v objdump &>/dev/null; then
        local mod_arch
        mod_arch=$(objdump -f "$module_path" 2>/dev/null | grep -i architecture | head -n 1)
        [[ -n "$mod_arch" ]] && info "Module arch: ${mod_arch#*:}" || info "Module arch: (could not determine)"
    fi

    info "Target kernel: $kernel_version"
    echo ""

    # ── Install the module ─────────────────────────────────────────────────────
    local modules_dir="${MOUNT_DIR}/lib/modules/${kernel_version}/extra"
    info "Installing module to: /lib/modules/${kernel_version}/extra/"
    mkdir -p "$modules_dir"
    cp "$module_path" "$modules_dir/"
    success "Module copied: $(basename "$module_path")"

    # Run depmod inside chroot to update module dependency files
    info "Running depmod -a inside chroot for kernel ${kernel_version} …"
    run_in_chroot "
        set -e
        if command -v depmod &>/dev/null; then
            depmod -a '${kernel_version}'
            echo '[chroot] depmod completed.'
        else
            echo '[chroot] WARNING: depmod not found, skipping.' >&2
        fi
    "
    [[ $? -eq 0 ]] && success "depmod completed." || warn "depmod reported issues (check output above)."

    # Optionally verify the module is indexed
    local modules_dep="${MOUNT_DIR}/lib/modules/${kernel_version}/modules.dep"
    if grep -q "$(basename "$module_path")" "$modules_dep" 2>/dev/null; then
        success "Module '$(basename "$module_path")' found in modules.dep."
    else
        warn "Module may not appear in modules.dep yet (this can be normal for new 'extra' modules)."
    fi

    success "add-module done."
}

# =============================================================================
# ── COMMAND: add-service ─────────────────────────────────────────────────────
#    Install a systemd .service unit file and enable it inside the rootfs.
#
#    ExecStart= handling:
#      The function parses every ExecStart= (and ExecStartPre=/ExecStartPost=)
#      line in the unit file and extracts the executable path (the first token
#      after stripping systemd prefixes like @, -, :, +, !).
#
#      For each executable path found it decides what to do:
#        CASE A – path already exists inside the rootfs  → nothing to do.
#        CASE B – a matching file exists on the HOST next to the .service file
#                 → copy it into the rootfs at the same absolute path.
#        CASE C – path is not found anywhere
#                 → warn and let the operator decide; do NOT abort.
#
#    Usage:
#      sudo ./rootfs_manager.sh add-service <rootfs.img> <service.service> [mount_point]
#
#    The .service file and any companion executables are expected to live in
#    the same directory on the host. Example layout:
#
#      ./myapp.service          ← unit file   (ExecStart=/usr/bin/myapp)
#      ./myapp                  ← companion executable to be copied
#
# =============================================================================
cmd_add_service() {
    [[ $# -ge 1 ]] || die "Usage: $0 add-service <rootfs.img> <service.service> [mount_point]"
    local service_file service_name service_dir
    service_file="$(realpath "$1")"
    MOUNT_DIR="${2:-/mnt/ubuntu_rootfs}"

    [[ -f "$service_file" ]] || die "Service file not found: $service_file"
    service_name="$(basename "$service_file")"
    service_dir="$(dirname "$service_file")"
    [[ "$service_name" == *.service ]] || warn "File does not have .service extension: $service_name"

    mount_rootfs_image "$ROOTFS_IMG"

    # Record ID
    if ! update_oeminfo "add-service" "$service_name"; then
        success "Service addition already recorded. Skipping."
        exit 0
    fi

    # ── Install the unit file ─────────────────────────────────────────────────
    local systemd_dir="${MOUNT_DIR}/etc/systemd/system"
    info "Installing service file: $service_name → /etc/systemd/system/"
    mkdir -p "$systemd_dir"
    cp "$service_file" "${systemd_dir}/${service_name}"
    chmod 644 "${systemd_dir}/${service_name}"
    success "Service file installed."

    # Display the unit file for confirmation
    echo ""
    info "Unit file contents:"
    cat "${systemd_dir}/${service_name}"
    echo ""

    # ── Parse and handle ExecStart* executables ───────────────────────────────
    # Collect all Exec*= directives (ExecStart, ExecStartPre, ExecStartPost,
    # ExecStop, ExecReload) that reference an absolute path.
    #
    # systemd allows these optional prefixes before the executable:
    #   @  (argv[0] override)   -  (ignore failure)   :  (no env subst)
    #   +  (full privileges)    !  (no new privileges) !! (ditto, strict)
    # We strip them all before taking the first whitespace-delimited token.

    echo ""
    echo -e "${BOLD}─── Checking ExecStart executables ───${NC}"

    local exec_directives
    # Grab value of every Exec*= line; skip empty/reset values (bare "=")
    mapfile -t exec_directives < <(
        grep -E '^\s*Exec(Start|StartPre|StartPost|Stop|Reload)\s*=' "$service_file" \
        | sed 's/^\s*Exec[^=]*=\s*//' \
        | grep -v '^\s*$'
    )

    if [[ ${#exec_directives[@]} -eq 0 ]]; then
        info "No Exec*= directives found in unit file – skipping executable check."
    fi

    local exec_line exec_path
    for exec_line in "${exec_directives[@]}"; do
        # Strip leading systemd modifier prefixes (@, -, :, +, !, !!)
        local stripped_line
        stripped_line="${exec_line}"
        # Remove one or more prefix chars from the set @-:+!
        while [[ "$stripped_line" =~ ^[@\-:+!] ]]; do
            stripped_line="${stripped_line#?}"
        done

        # First whitespace-delimited token is the executable path
        exec_path="${stripped_line%% *}"

        # Skip empty, built-ins, or non-absolute paths (e.g. bare command names)
        [[ -z "$exec_path" ]]      && continue
        [[ "$exec_path" != /* ]]   && { warn "Skipping non-absolute ExecStart path: '$exec_path'"; continue; }
        
        # Remove Carriage Return
        exec_path=$(echo $exec_path | tr -d '\r')

        info "Found Exec* path: $exec_path"

        local exec_in_rootfs="${MOUNT_DIR}${exec_path}"

        # ── CASE A: already present in rootfs ─────────────────────────────────
        if [[ -e "$exec_in_rootfs" ]]; then
            success "  [CASE A] Already exists in rootfs: $exec_path"
            # Ensure it is executable
            chmod +x "$exec_in_rootfs"
            continue
        fi

        # ── CASE B: companion file found next to the .service on the host ─────
        local exec_basename
        exec_basename="$(basename "$exec_path")"
        local candidate_on_host="${service_dir}/${exec_basename}"

        if [[ -f "$candidate_on_host" ]]; then
            info "  [CASE B] Found companion executable on host: $candidate_on_host"
            info "           Copying to rootfs at: $exec_path"
            local exec_parent_in_rootfs
            exec_parent_in_rootfs="$(dirname "$exec_in_rootfs")"
            mkdir -p "$exec_parent_in_rootfs"
            cp "$candidate_on_host" "$exec_in_rootfs"
            chmod +x "$exec_in_rootfs"
            success "  Executable installed: $exec_path  ($(stat -c '%s bytes' "$exec_in_rootfs"))"
            continue
        fi

        # ── CASE C: not found anywhere ────────────────────────────────────────
        warn "  [CASE C] Executable NOT found in rootfs or host directory: $exec_path"
        warn "           Expected companion at: $candidate_on_host"
        warn "           The service may fail at runtime unless the binary is"
        warn "           provided by a package installed inside the rootfs."
    done

    echo ""

    # ── Enable the service ────────────────────────────────────────────────────
    # Determine WantedBy= target (default: multi-user.target)
    local target
    target=$(grep -i "^WantedBy=" "$service_file" | head -n 1 | cut -d= -f2 | tr -d '[:space:]')
    target="${target:-multi-user.target}"
    local wants_dir="${MOUNT_DIR}/etc/systemd/system/${target}.wants"
    mkdir -p "$wants_dir"

    # Prefer chroot systemctl enable when available (handles Alias= and Also=)
    if chroot "$MOUNT_DIR" /bin/bash -c "command -v systemctl &>/dev/null" 2>/dev/null; then
        info "Enabling service via systemctl inside chroot …"
        run_in_chroot "
            set -e
            systemctl enable '${service_name}'
            echo '[chroot] Service enabled.'
        "
        [[ $? -eq 0 ]] && success "Service enabled via systemctl." \
                        || warn "systemctl enable failed; falling back to manual symlink."
    fi

    # Belt-and-suspenders: always ensure the .wants symlink exists
    local link_path="${wants_dir}/${service_name}"
    if [[ ! -L "$link_path" ]]; then
        ln -sf "/etc/systemd/system/${service_name}" "$link_path"
        success "Created enable symlink: /etc/systemd/system/${target}.wants/${service_name}"
    else
        info "Enable symlink already exists: $link_path"
    fi

    success "add-service done. Service '${service_name}' will be enabled on boot."
}

# =============================================================================
# ── COMMAND: add-deb ─────────────────────────────────────────────────────────
#    Copy a .deb package into the rootfs and install it with dpkg -i
# =============================================================================
cmd_add_deb() {
    [[ $# -ge 1 ]] || die "Usage: $0 add-deb <rootfs.img> <package.deb> [mount_point]"
    local deb_file deb_name
    deb_file="$(realpath "$1")"
    MOUNT_DIR="${2:-/mnt/ubuntu_rootfs}"

    [[ -f "$deb_file" ]] || die ".deb package not found: $deb_file"
    deb_name="$(basename "$deb_file")"

    command -v dpkg &>/dev/null || die "dpkg is required for add-deb but was not found on host."

    mount_rootfs_image "$ROOTFS_IMG"

    # Record ID
    if ! update_oeminfo "add-deb" "$deb_name"; then
        success "Package installation already recorded. Skipping."
        exit 0
    fi

    # Stage the .deb inside the rootfs at a temporary location
    local stage_dir_host="${MOUNT_DIR}/tmp/deb_install"
    local stage_dir_chroot="/tmp/deb_install"
    info "Staging .deb package inside rootfs: ${stage_dir_chroot}/${deb_name}"
    mkdir -p "$stage_dir_host"
    cp "$deb_file" "${stage_dir_host}/${deb_name}"

    # Install via dpkg -i inside the chroot
    echo ""
    echo -e "${BOLD}─── Installing .deb inside chroot ───${NC}"
    run_in_chroot "
        set -e
        echo '[chroot] Installing: ${deb_name}'

        # Try to fix any previously broken installs first
        if command -v dpkg &>/dev/null; then
            dpkg --configure -a 2>/dev/null || true
        fi

        dpkg -i '${stage_dir_chroot}/${deb_name}'
        DPKG_EXIT=\$?

        if [[ \$DPKG_EXIT -ne 0 ]]; then
            echo '[chroot] dpkg reported errors; attempting apt-get -f install to resolve deps …'
            if command -v apt-get &>/dev/null; then
                apt-get -f install -y --no-install-recommends
            fi
        fi

        echo '[chroot] Package installation complete.'
    "
    local exit_code=$?
    echo ""

    # Cleanup staged .deb from rootfs
    rm -rf "$stage_dir_host"
    info "Staged .deb removed from rootfs."

    if [[ $exit_code -eq 0 ]]; then
        success ".deb package '${deb_name}' installed successfully."

        # Show installed package info
        local pkg_name
        pkg_name=$(dpkg-deb -f "$deb_file" Package 2>/dev/null || true)
        if [[ -n "$pkg_name" ]]; then
            info "Verifying installation of package '${pkg_name}' …"
            run_in_chroot "dpkg -s '${pkg_name}' 2>/dev/null | grep -E '^(Package|Version|Status):' || true"
        fi
    else
        error "dpkg exited with code $exit_code."
        exit $exit_code
    fi

    success "add-deb done."
}

# =============================================================================
# ── COMMAND: add-run ─────────────────────────────────────────────────────────
#    Stage a .run self-extracting installer inside the rootfs and execute it
#    in a chroot environment, then remove the staged file afterwards.
#
#    .run installers (makeself-based) are single-file self-extracting archives
#    that contain a shell script payload. Common examples: CUDA, cuDNN, NVIDIA
#    drivers, vendor SDKs. They require a proper Linux environment with
#    pseudo-filesystems mounted — exactly what this chroot provides.
#
#    Argument parsing:
#      $1  installer.run    path to the .run file on the host
#      $2  [mount_point]    optional; must NOT start with '--'
#      --                   separator; everything after this is passed verbatim
#                           to the installer as its own arguments
#
#    Behaviour:
#      1. Validate the file is executable/shell (makeself check via header scan)
#      2. Copy the .run file into /tmp/run_installer/ inside the rootfs
#      3. chmod +x and execute it inside chroot, forwarding any extra args
#      4. Propagate the installer's exit code
#      5. Remove the staged file from the rootfs (regardless of exit code)
#
#    Interactive vs silent:
#      By default the installer runs with its own prompts (interactive).
#      Pass -- --silent (or the installer's own silent flag) to suppress them.
#
#    Usage:
#      sudo ./rootfs_manager.sh add-run <rootfs.img> <installer.run>
#      sudo ./rootfs_manager.sh add-run <rootfs.img> <installer.run> [mount_point]
#      sudo ./rootfs_manager.sh add-run <rootfs.img> <installer.run> [mount_point] -- --silent --toolkit
#
# =============================================================================
cmd_add_run() {
    [[ $# -ge 1 ]] || die "Usage: $0 add-run <rootfs.img> <installer.run> [mount_point] [-- <installer-args>...]"

    local run_file mount_arg installer_args=()

    # ── Parse positional args and the optional -- separator ───────────────────
    # Positional layout before '--':
    #   $1 = installer.run   (required)
    #   $2 = mount_point     (optional; skip if it starts with '--')
    run_file="$(realpath "$1")"; shift
    [[ -f "$run_file" ]] || die ".run installer not found: $run_file"

    # Check if next arg is a mount point (non-empty, doesn't start with '-')
    if [[ $# -gt 0 && "$1" != "--" && "$1" != -* ]]; then
        MOUNT_DIR="$1"; shift
    else
        MOUNT_DIR="/mnt/ubuntu_rootfs"
    fi

    # Consume the '--' separator if present; collect remaining args for installer
    if [[ $# -gt 0 && "$1" == "--" ]]; then
        shift
        installer_args=("$@")
    fi

    local run_name
    run_name="$(basename "$run_file")"

    # ── Sanity-check: confirm this looks like a shell/makeself script ─────────
    info "Inspecting installer: $run_name"
    local file_type
    file_type="$(file -b "$run_file")"
    info "Detected type: $file_type"

    # makeself archives always begin with a shell shebang; warn if not found
    if ! head -c 512 "$run_file" | grep -qE '(^#!.*sh|makeself|self.extract)'; then
        warn "File does not appear to be a makeself/shell .run installer."
        warn "Proceeding anyway — it will fail inside chroot if it is not executable shell."
    fi

    # Check execute permission on host (informational only; we chmod inside rootfs)
    [[ -x "$run_file" ]] || info "File is not yet executable on host; will chmod +x inside rootfs."

    mount_rootfs_image "$ROOTFS_IMG"

    # Record ID
    if ! update_oeminfo "add-run" "$run_name"; then
        success "Installer execution already recorded. Skipping."
        exit 0
    fi

    # ── Stage the .run file inside rootfs ─────────────────────────────────────
    local stage_dir_chroot="/tmp/run_installer"
    local stage_dir_host="${MOUNT_DIR}${stage_dir_chroot}"
    local run_path_chroot="${stage_dir_chroot}/${run_name}"
    local run_path_host="${stage_dir_host}/${run_name}"

    info "Staging installer inside rootfs: ${run_path_chroot}"
    mkdir -p "$stage_dir_host"
    cp "$run_file" "$run_path_host"
    chmod +x "$run_path_host"
    success "Installer staged ($(stat -c '%s bytes' "$run_path_host"))."

    # ── Report what will be executed ──────────────────────────────────────────
    echo ""
    echo -e "${BOLD}─── Running .run installer inside chroot ───${NC}"
    info "Installer : ${run_path_chroot}"
    if [[ ${#installer_args[@]} -gt 0 ]]; then
        info "Extra args: ${installer_args[*]}"
    else
        info "Extra args: (none — installer will run with its own defaults)"
    fi
    echo ""

    # ── Build the argument string to pass through safely ─────────────────────
    # We need to forward installer_args into the chroot bash -c string.
    # Use printf %q to shell-quote each arg, then join with spaces.
    local quoted_args=""
    if [[ ${#installer_args[@]} -gt 0 ]]; then
        quoted_args="$(printf ' %q' "${installer_args[@]}")"
    fi

    # ── Execute installer inside chroot ───────────────────────────────────────
    run_in_chroot "
        set -e
        echo '[chroot] Starting installer: ${run_path_chroot}'
        cd '${stage_dir_chroot}'

        # Some .run installers inspect \$HOME or write logs there
        export HOME=/root
        export TMPDIR=/tmp

        # Execute; append any forwarded arguments
        bash '${run_path_chroot}'${quoted_args}
        echo '[chroot] Installer exited with code '\$?
    "
    local install_exit=$?

    echo ""

    # ── Always clean up staged file, even on failure ──────────────────────────
    info "Removing staged installer from rootfs …"
    rm -rf "$stage_dir_host"
    success "Staged installer removed."

    # ── Report outcome ────────────────────────────────────────────────────────
    if [[ $install_exit -eq 0 ]]; then
        success ".run installer '${run_name}' completed successfully (exit 0)."
    else
        error ".run installer '${run_name}' exited with code ${install_exit}."
        error "Check the output above for installer-specific error messages."
        exit $install_exit
    fi

    success "add-run done."
}

# =============================================================================
# ── Command dispatcher ────────────────────────────────────────────────────────
# =============================================================================
echo ""
echo -e "${BOLD}=== Ubuntu Rootfs Manager ===${NC}"
echo -e "  Command : ${CYAN}${COMMAND}${NC}"
echo -e "  Image   : ${CYAN}${ROOTFS_IMG}${NC}"
echo ""

# Shift past <command> and <rootfs.img> — remaining args go to the sub-command
shift 2

case "$COMMAND" in
    install)     cmd_install    "$@" ;;
    add-file)    cmd_add_file   "$@" ;;
    add-module)  cmd_add_module "$@" ;;
    add-service) cmd_add_service "$@" ;;
    add-deb)     cmd_add_deb   "$@" ;;
    add-run)     cmd_add_run   "$@" ;;
    remove-oeminfo-section) cmd_remove_oeminfo_section "$@" ;;
    *)
        error "Unknown command: $COMMAND"
        echo ""
        usage
        ;;
esac