# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

`rootfs_manager.sh` is a Bash script for mounting Ubuntu rootfs `.img` files and performing install/configuration tasks inside a chroot environment. It supports partitioned images (MBR/GPT) and raw filesystem images.

## Commands

| Command | Description |
|---------|-------------|
| `install` | Extract tarball to `/opt/installer`, run `install.sh` in chroot |
| `add-file` | Copy a file/directory into the rootfs at a specified path |
| `add-module` | Install a `.ko` kernel module and run `depmod` |
| `add-service` | Install a systemd unit file, handle companion executables, enable service |
| `add-deb` | Install a `.deb` package using `dpkg -i` in chroot |
| `add-run` | Execute a `.run` self-extracting installer (e.g., CUDA) in chroot |
| `remove-oeminfo-section` | Remove a section from `/etc/OEMInfo.ini` |

All commands require `sudo` and take `<rootfs.img>` as the first positional argument. An optional mount point defaults to `/mnt/ubuntu_rootfs`.

## Architecture

### Core Functions

- **`mount_rootfs_image()`** (`rootfs_manager.sh:123`): Mounts the rootfs image, sets up loop device, binds pseudo-filesystems (`/proc`, `/sys`, `/dev`, `/dev/pts`, `/run`), and copies `/etc/resolv.conf` for DNS.
- **`run_in_chroot()`** (`rootfs_manager.sh:191`): Executes commands inside the chroot with a clean environment (`HOME=/root`, `PATH`, `DEBIAN_FRONTEND=noninteractive`).
- **`update_oeminfo()`** (`rootfs_manager.sh:206`): Records operations to `/etc/OEMInfo.ini` in INI format with timestamp and status. Prevents duplicate operations by checking for existing sections.
- **`cleanup()`** (`rootfs_manager.sh:94`): Trapped on `EXIT/INT/TERM` to unmount filesystems and detach loop devices.

### OEMInfo Tracking

Every installation is recorded to `${MOUNT_DIR}/etc/OEMInfo.ini` with sections like:
```ini
[add-deb_package.deb]
Function: add-deb
File: package.deb
Timestamp: 2026-04-14 10:30:00
Status: Completed
```
This prevents redundant executions—commands skip if the section already exists.

### Service Installation Logic (`add-service`)

The `add-service` command handles three cases for executables referenced in `ExecStart*=` directives:
- **CASE A**: Executable already exists in rootfs → ensure `+x` permission
- **CASE B**: Companion executable exists next to `.service` file on host → copy to rootfs
- **CASE C**: Not found → warn but continue (may be provided by another package)

Strips systemd prefixes (`@`, `-`, `:`, `+`, `!`, `!!`) before extracting executable paths.

### Kernel Module Installation (`add-module`)

Auto-detects kernel version from `/lib/modules/` if not specified, preferring the latest valid version. Installs to `/lib/modules/<kernel>/extra/` and runs `depmod -a` in chroot.

## Important Implementation Details

- **Loop device detection**: Uses `file -b` to detect partitioned vs raw images, handles both via `losetup --partscan`.
- **Tarball extraction**: Auto-detects compression format (`.gz`, `.bz2`, `.xz`, `.zst`, plain `.tar`).
- **Error handling**: Uses `set -euo pipefail` style patterns with `die()` for fatal errors and `warn()`/`error()` helpers.
- **Colored output**: Uses ANSI escape codes for INFO/OK/WARN/ERROR messages.

## Running the Script

```bash
# Install from tarball
sudo ./rootfs_manager.sh install ubuntu.img package.tar.gz

# Add a file
sudo ./rootfs_manager.sh add-file ubuntu.img ./my.conf /etc/myapp/my.conf

# Add a kernel module
sudo ./rootfs_manager.sh add-module ubuntu.img driver.ko

# Add a systemd service
sudo ./rootfs_manager.sh add-service ubuntu.img myapp.service

# Install a .deb package
sudo ./rootfs_manager.sh add-deb ubuntu.img libfoo_1.0_arm64.deb

# Run a .run installer with custom args
sudo ./rootfs_manager.sh add-run ubuntu.img cuda_installer.run -- --silent --toolkit
```

## Dependencies

Required on host: `losetup`, `mount`, `chroot`, `tar`, `file`, `dpkg` (for `add-deb`), `depmod` (for `add-module`).
