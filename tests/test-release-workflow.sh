#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW="${SCRIPT_DIR}/../jetson-bsp-release-workflow.sh"
TEST_ROOT="$(mktemp -d)"
TEST_LOG="${TEST_ROOT}/commands.log"

cleanup() {
    [[ -n "${TEST_ROOT}" && -d "${TEST_ROOT}" ]] && rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    [[ -f "${TEST_LOG}" ]] && sed 's/^/  /' "${TEST_LOG}" >&2
    exit 1
}

make_tool() {
    local path="$1"
    mkdir -p "$(dirname "${path}")"
    printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$0 $*" >> "${TEST_LOG}"' > "${path}"
    chmod +x "${path}"
}

L4T_ROOT="${TEST_ROOT}/Linux_for_Tegra"
TOOLCHAIN="${TEST_ROOT}/toolchain/aarch64-linux-gnu-"
FAKE_BIN="${TEST_ROOT}/bin"

mkdir -p "${L4T_ROOT}/rootfs/etc" "${L4T_ROOT}/source" \
    "${L4T_ROOT}/tools/kernel_flash" "${L4T_ROOT}/tools/backup_restore" \
    "${FAKE_BIN}" "$(dirname "${TOOLCHAIN}")"
touch "${L4T_ROOT}/rootfs/etc/os-release" "${L4T_ROOT}/recomputer-orin-j401.conf" \
    "${TOOLCHAIN}gcc"
chmod +x "${TOOLCHAIN}gcc"
make_tool "${L4T_ROOT}/apply_binaries.sh"
make_tool "${L4T_ROOT}/source/nvbuild.sh"
make_tool "${L4T_ROOT}/source/do_copy.sh"
make_tool "${L4T_ROOT}/tools/kernel_flash/l4t_initrd_flash.sh"
make_tool "${L4T_ROOT}/tools/backup_restore/l4t_backup_restore.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exec "$@"' > "${FAKE_BIN}/sudo"
chmod +x "${FAKE_BIN}/sudo"

run() {
    TEST_LOG="${TEST_LOG}" PATH="${FAKE_BIN}:${PATH}" CROSS_COMPILE="${TOOLCHAIN}" \
        "${WORKFLOW}" "$@" --l4t-root "${L4T_ROOT}" --board recomputer-orin-j401
}

run validate
if run flash; then
    fail 'flash ran without --yes'
fi
run prepare
run build
run flash --yes
run backup --yes
run package --yes --massflash 5

grep -q 'apply_binaries.sh' "${TEST_LOG}" || fail 'prepare did not invoke apply_binaries.sh'
[[ "$(grep -c 'nvbuild.sh' "${TEST_LOG}")" -eq 2 ]] || fail 'build did not invoke nvbuild.sh twice'
grep -q 'do_copy.sh' "${TEST_LOG}" || fail 'build did not invoke do_copy.sh'
grep -q -- '--external-device nvme0n1p1' "${TEST_LOG}" || fail 'flash device argument missing'
grep -q -- '-e nvme0n1 -b -c recomputer-orin-j401' "${TEST_LOG}" || fail 'backup arguments missing'
grep -q -- '--use-backup-image --no-flash --showlogs --network usb0 --massflash 5 recomputer-orin-j401 internal' "${TEST_LOG}" || fail 'package arguments missing'

printf 'PASS: release workflow orchestration test\n'
