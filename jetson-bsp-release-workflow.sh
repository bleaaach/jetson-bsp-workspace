#!/usr/bin/env bash
# Build a Seeed Jetson BSP, optionally validate it on a development device,
# then capture that device into a mass-flash package.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
L4T_ROOT="${L4T_ROOT:-${SCRIPT_DIR}/Linux_for_Tegra}"
BOARD_NAME="${BOARD_NAME:-}"
EXTERNAL_DEVICE="${EXTERNAL_DEVICE:-nvme0n1p1}"
BACKUP_DEVICE="${BACKUP_DEVICE:-nvme0n1}"
NETWORK="${NETWORK:-usb0}"
MASSFLASH_COUNT="${MASSFLASH_COUNT:-1}"
YES=0

usage() {
    cat <<'EOF'
Usage:
  ./jetson-bsp-release-workflow.sh <command> --board <board-name> [options]

Commands:
  validate  Check the prepared Linux_for_Tegra workspace and toolchain.
  prepare   Run apply_binaries.sh for an extracted BSP rootfs.
  build     Build Image, DTBs, in-tree modules, and install modules to rootfs.
  flash     Flash the built BSP to a Jetson in recovery mode.
  backup    Capture the configured development Jetson into backup images.
  package   Create an mfi mass-flash package from the backup images.
  pipeline  Run prepare, build, backup, and package for an already configured
            development Jetson in recovery mode.

Options:
  --l4t-root <dir>        Linux_for_Tegra root (default: ./Linux_for_Tegra)
  --board <name>          Flash configuration name, for example recomputer-orin-j401
  --external-device <dev> Rootfs device for flash/package (default: nvme0n1p1)
  --backup-device <dev>   Device captured from the development Jetson (default: nvme0n1)
  --network <name>        Flash network interface (default: usb0)
  --massflash <count>     Number of devices in the generated package (default: 1)
  --yes                   Required for flash, backup, package, and pipeline

Examples:
  ./jetson-bsp-release-workflow.sh build --board recomputer-orin-j401
  ./jetson-bsp-release-workflow.sh flash --board recomputer-orin-j401 --yes
  ./jetson-bsp-release-workflow.sh pipeline --board recomputer-orin-j401 \
      --massflash 5 --yes
EOF
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

require_file() {
    [[ -f "$1" ]] || die "Missing required file: $1"
}

require_board() {
    [[ -n "${BOARD_NAME}" ]] || die "--board is required"
    require_file "${L4T_ROOT}/${BOARD_NAME}.conf"
}

require_confirmation() {
    [[ "${YES}" -eq 1 ]] || die "This command changes a Jetson device or creates a BSP image. Re-run with --yes."
}

validate() {
    [[ -f "${L4T_ROOT}/apply_binaries.sh" ]] || die \
        "${L4T_ROOT} is not a complete extracted Linux_for_Tegra BSP. Pass --l4t-root for the official BSP workspace."
    require_file "${L4T_ROOT}/source/nvbuild.sh"
    require_file "${L4T_ROOT}/source/do_copy.sh"
    require_file "${L4T_ROOT}/tools/kernel_flash/l4t_initrd_flash.sh"
    require_file "${L4T_ROOT}/tools/backup_restore/l4t_backup_restore.sh"
    require_file "${L4T_ROOT}/rootfs/etc/os-release"
    require_board
    [[ -n "${CROSS_COMPILE:-}" ]] || die "Set CROSS_COMPILE to the aarch64 toolchain prefix."
    [[ -x "${CROSS_COMPILE}gcc" ]] || die "Cross compiler not found: ${CROSS_COMPILE}gcc"

    printf 'Workspace: %s\n' "${L4T_ROOT}"
    printf 'Board: %s\n' "${BOARD_NAME}"
    printf 'Cross compiler: %s\n' "${CROSS_COMPILE}"
}

prepare() {
    validate
    (
        cd "${L4T_ROOT}"
        sudo ./apply_binaries.sh
    )
}

build() {
    validate
    (
        cd "${L4T_ROOT}/source"
        ./nvbuild.sh
        ./do_copy.sh
        INSTALL_MOD_PATH="${L4T_ROOT}/rootfs" ./nvbuild.sh -i
    )
}

flash() {
    validate
    require_confirmation
    (
        cd "${L4T_ROOT}"
        sudo ./tools/kernel_flash/l4t_initrd_flash.sh \
            --external-device "${EXTERNAL_DEVICE}" \
            -c tools/kernel_flash/flash_l4t_t234_nvme.xml \
            -p '-c bootloader/generic/cfg/flash_t234_qspi.xml' \
            --showlogs --network "${NETWORK}" "${BOARD_NAME}" internal
    )
}

backup() {
    validate
    require_confirmation
    (
        cd "${L4T_ROOT}"
        sudo ./tools/backup_restore/l4t_backup_restore.sh \
            -e "${BACKUP_DEVICE}" -b -c "${BOARD_NAME}"
    )
}

package() {
    validate
    require_confirmation
    (
        cd "${L4T_ROOT}"
        sudo ./tools/kernel_flash/l4t_initrd_flash.sh \
            --use-backup-image --no-flash --showlogs \
            --network "${NETWORK}" --massflash "${MASSFLASH_COUNT}" \
            "${BOARD_NAME}" internal
    )
}

COMMAND="${1:-}"
[[ -n "${COMMAND}" ]] || { usage; exit 2; }
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --l4t-root) L4T_ROOT="$2"; shift 2 ;;
        --board) BOARD_NAME="$2"; shift 2 ;;
        --external-device) EXTERNAL_DEVICE="$2"; shift 2 ;;
        --backup-device) BACKUP_DEVICE="$2"; shift 2 ;;
        --network) NETWORK="$2"; shift 2 ;;
        --massflash) MASSFLASH_COUNT="$2"; shift 2 ;;
        --yes) YES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

case "${COMMAND}" in
    validate) validate ;;
    prepare) prepare ;;
    build) build ;;
    flash) flash ;;
    backup) backup ;;
    package) package ;;
    pipeline)
        require_confirmation
        # The development device must already contain the desired runtime
        # environment and be in recovery mode before backup starts.
        prepare
        build
        backup
        package
        ;;
    -h|--help) usage ;;
    *) usage; die "Unknown command: ${COMMAND}" ;;
esac
