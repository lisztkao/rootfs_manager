#!/bin/bash

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

MOUNT_DIR="/mnt/ubuntu_rootfs"
OEMINFO_FILE="/etc/OEMInfo.ini"

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { error "$*"; exit 1; }

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

# 准备chroot环境
setup_chroot() {
    log_info "Preparing chroot environment..."
    local img="$ISO"
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
    log_info "Chroot environment prepared ok"
}

# 替换LOGO
replace_logo() {
    [[ -z "$LOGO" ]] && return 0
    log_info "Replace LOGO..."
    log_warn "LOGO replacement is not implemented yet, skipping this step"
    log_info "Replace LOGO done"
}

# 添加软件包
add_packages() {
    [[ -z "$PACKAGE" ]] && return 0

    log_info "Add packages..."

    local deb_file deb_name
    deb_file="$(realpath "$PACKAGE")"

   [[ -f "$deb_file" ]] || die ".deb package not found: $deb_file"
    deb_name="$(basename "$deb_file")"

    command -v dpkg &>/dev/null || die "dpkg is required for add-deb but was not found on host."

    # Record ID
    #if ! update_oeminfo "add_packages" "$deb_name"; then
    #    success "Package installation already recorded. Skipping."
    #    exit 0
    #fi

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
        log_info "Installed packages done, all $total_count files added"
        # Show installed package info
        local pkg_name
        pkg_name=$(dpkg-deb -f "$deb_file" Package 2>/dev/null || true)
        if [[ -n "$pkg_name" ]]; then
            info "Verifying installation of package '${pkg_name}' …"
            run_in_chroot "dpkg -s '${pkg_name}' 2>/dev/null | grep -E '^(Package|Version|Status):' || true"
        fi
    else
        #error "dpkg exited with code $exit_code."
        #exit $exit_code
        log_error "dpkg exited with code $exit_code."
    fi
}

# 添加驱动
add_drivers() {
    [[ -z "$DRIVER" ]] && return 0

    log_info "Add drivers..."
    local module_path kernel_version
    module_path="$(realpath "$DRIVER")"
    [[ -f "$module_path" ]] || die "Kernel module not found: $module_path"

    # kernel_version: auto-detect from rootfs if not specified
    kernel_version="${2:-}"

    filename=$(basename "$module_path")
    # Record ID
    #if ! update_oeminfo "add_drivers" "$filename"; then
    #    success "Module addition already recorded. Skipping."
    #    exit 0
    #fi

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
    log_info "Installed drivers done, all $count files added"
}

# 添加其他配置
add_other_config() {
    [[ -z "$CONFIG" ]] && return 0
    log_info "Add other config..."

    install_file="$CONFIG/install.sh"
    if [[ ! -f "$install_file" ]];then
        log_error "No $install_file not found"
        exit 1
    fi

    log_info "Executing $install_file configuration file..."

    local install_filename=$(basename "$install_file")

    # Record ID
    #if ! update_oeminfo "add_other_config" "$install_file"; then
    #    log_warn "Service addition already recorded. Skipping."
    #    exit 0
    #fi

    if ! cp "$install_file" "$MOUNT_DIR/tmp/$install_filename"; then
        log_error "Copy $install_file failed"
        exit 1
    fi

    if ! run_in_chroot "/tmp/$install_filename"; then
        log_error "Execute $install_file failed"
        exit 1
    fi

    if ! run_in_chroot "rm /tmp/$install_filename"; then
        log_error "Remove $install_file failed"
        exit 1
    fi

    log_info "Execute configuration file done"
}

# 只有当需要更新initramfs时才添加boot服务脚本
add_boot_service() {
    log_info "Add boot service..."
    local run_file_name="bootservice_install.run"

    # Record ID
    #if ! update_oeminfo "add_boot_service" "$install_file"; then
    #    log_warn "Service addition already recorded. Skipping."
    #    exit 0
    #fi

    cp "$WORK_DIR/tools/${run_file_name}" "$MOUNT_DIR/tmp/${run_file_name}" ||{
        log_error "Copy ${run_file_name} failed"
        exit 1
    }
    if ! run_in_chroot "chmod +x /tmp/${run_file_name}" ;then
        log_error "chmod ${run_file_name} failed"
        exit 1
    fi
    if ! run_in_chroot "/tmp/${run_file_name}" ;then
        log_error "Run ${run_file_name} failed"
        exit 1
    fi
    if ! run_in_chroot "rm -f /tmp/*run" ;then
        log_error "Remove run files failed"
        exit 1
    fi

    log_info "Add boot service done"
}

# Not yet started
# 创建或更新 release notes 文件
create_release_notes() {
    local all_files=("$@")
    local BUILD_DIR="$MOUNT_DIR/etc/"
    local changelog_pattern="$BUILD_DIR/changelog_*.txt"
    local changelog_files=()
    local next_number=1

    if ls $changelog_pattern >/dev/null 2>&1; then
        while IFS= read -r -d '' file; do
            changelog_files+=("$file")
        done < <(find "$BUILD_DIR" -maxdepth 1 -name "changelog_*.txt" -print0 2>/dev/null)

        mapfile -t sorted_changelogs < <(printf '%s\n' "${changelog_files[@]}" | sort -V)

        if [[ ${#sorted_changelogs[@]} -gt 0 ]]; then
            local latest_file="${sorted_changelogs[-1]}"
            local current_num=$(basename "$latest_file" | grep -o '[0-9]\+' | head -1)
            next_number=$((current_num + 1))
        fi
    fi

    local new_changelog="$BUILD_DIR/changelog_${next_number}.txt"
    log_info "Creating changelog file: $(basename "$new_changelog")"

    local current_date=$(date '+%Y-%m-%d %H:%M:%S')
    local host_info=$(uname -a)

    {
        #echo "Image version: $ISOVERSION"
        echo "Packaging time: $current_date"
        echo "Added files:"
        for file in "${all_files[@]}"; do
            echo "  $(basename "$file")"
        done

        if [[ ${#sorted_changelogs[@]} -gt 0 ]]; then
            echo "Previous versions:"
            echo "=========================================="
            for old_file in "${sorted_changelogs[@]}"; do
                [[ -f "$old_file" ]] && echo "  $(basename "$old_file")"
            done
            for old_file in "${sorted_changelogs[@]}"; do
                rm -f "$old_file"
            done
        fi
    } > "$new_changelog"
    cat "$new_changelog" > "$MOUNT_DIR/etc/release_notes"

    local rootfs_oeminfo="${MOUNT_DIR}${OEMINFO_FILE}"
    cat "$new_changelog" >> "$rootfs_oeminfo" || warn "Could not append changelog to OEMInfo.ini"

    log_info "Release_notes file created"
}

# Collect added files from a directory if the corresponding variable is set
# This eliminates repetitive code for collecting files from packages, drivers, and logos directories
collect_added_files() {
    local function_name="$1"
    local file_path="$2"
    local file_name="$(basename "$file_path")"
    local array_name="${3}"
    
    # Use indirect expansion to get the value of the variable
    log_info "function_name: $function_name"
    log_info "file_name: $file_name"
    # Only collect if variable is set and directory exists
    if [[ -f "$file_path" ]]; then
        # Use nameref to append files to the specified array
        declare -n arr_ref="$array_name"
        arr_ref+=("$file_name")
    fi
}

# Not yet started
# IMG 处理主函数 - 被 main.sh 调用
do_build() {

    if [[ ! -z "$LOGO$DRIVER$CONFIG$PACKAGE" ]];then
        setup_chroot
    fi
    # 开始添加组件
    #replace_logo
    #add_packages
    #add_drivers
    #add_other_config

    #记录所有文件并创建新的release notes
    local added_files=()

    # Collect all added files from different directories
    collect_added_files "packages" "$PACKAGE" "added_files"
    collect_added_files "drivers" "$DRIVER" "added_files"
    collect_added_files "logos" "$LOGO" "added_files"
    collect_added_files "configs" "$CONFIG" "added_files"

echo "${added_files[@]}"

    if [[ ${#added_files[@]} -gt 0 ]];then
        create_release_notes "${added_files[@]}"
    else
        log_info "No release notes added, skipping creation"
    fi

    cleanup
}
