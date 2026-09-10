#!/usr/bin/env bash
# build-firmware.sh
# =============================================================================
# 一键构建 Seeed reComputer / reServer 的固件镜像 (mfi) 或直接刷机。
#
# 板卡参数表来自 Seeed-Studio/Linux_for_Tegra/.gitlab-ci.yml。
# 每个型号有多个 SKU 变体 (对应 16G/8G 等模组), 用 --sku 选择:
#   recomputer-orin-j401  : 0000 | 0001 | 0003 | 0004
#   recomputer-orin-j40mini/super/robotics: 同上
#   reserver-agx-orin-j501x: 0004 | 0005 (BOARDID 3701)
#
# 用法:
#   ./build-firmware.sh list
#   ./build-firmware.sh mfi   <型号> [--sku 0000] [--ver R36.4.3] [--out DIR]
#   ./build-firmware.sh flash <型号> [--sku 0000] [--ver R36.4.3]
#
#   mfi   只生成固件镜像包 (不刷机, 可分发/备份)
#   flash 刷入已连接并处于 Recovery 模式的板子 (需要 USB)
#
# 产物: mfi_<型号>.tar.gz (完整可刷镜像, 拷到任何机器 flash.sh 烧入)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSD_ROOT="$(dirname "${SCRIPT_DIR}")"

# 型号参数表: 型号|BOARDID|BOARDSKU|FAB|BOARDREV|CHIP_SKU
# (多个 SKU 变体都列出, 按 BOARDSKU 区分)
BOARD_TABLE=(
    "recomputer-orin-j401|3767|0000|300|G.3|00:00:00:D3"
    "recomputer-orin-j401|3767|0001|300|M.3|00:00:00:D4"
    "recomputer-orin-j401|3767|0003|300|N.2|00:00:00:D6"
    "recomputer-orin-j401|3767|0004|300|N.2|00:00:00:D6"
    "recomputer-industrial-orin-j401|3767|0000|300|G.3|00:00:00:D3"
    "recomputer-industrial-orin-j401|3767|0001|300|M.3|00:00:00:D4"
    "recomputer-industrial-orin-j401|3767|0003|300|N.2|00:00:00:D6"
    "recomputer-industrial-orin-j401|3767|0004|300|N.2|00:00:00:D6"
    "recomputer-orin-j40mini|3767|0000|300|G.3|00:00:00:D3"
    "recomputer-orin-j40mini|3767|0001|300|M.3|00:00:00:D4"
    "recomputer-orin-j40mini|3767|0003|300|N.2|00:00:00:D6"
    "recomputer-orin-j40mini|3767|0004|300|N.2|00:00:00:D6"
    "recomputer-orin-super-j401|3767|0000|300|G.3|00:00:00:D3"
    "recomputer-orin-super-j401|3767|0001|300|M.3|00:00:00:D4"
    "recomputer-orin-super-j401|3767|0003|300|N.2|00:00:00:D6"
    "recomputer-orin-super-j401|3767|0004|300|N.2|00:00:00:D6"
    "recomputer-orin-robotics-j401|3767|0000|300|G.3|00:00:00:D3"
    "recomputer-orin-robotics-j401|3767|0001|300|M.3|00:00:00:D4"
    "recomputer-orin-robotics-j401|3767|0003|300|N.2|00:00:00:D6"
    "recomputer-orin-robotics-j401|3767|0004|300|N.2|00:00:00:D6"
    "recomputer-orin-robotics-j401-gmsl|3767|0000|300|G.3|00:00:00:D3"
    "recomputer-orin-robotics-j401-gmsl|3767|0001|300|M.3|00:00:00:D4"
    "recomputer-orin-robotics-j401-gmsl|3767|0003|300|N.2|00:00:00:D6"
    "recomputer-orin-robotics-j401-gmsl|3767|0004|300|N.2|00:00:00:D6"
    "reserver-industrial-orin-j401|3767|0000|300|G.3|00:00:00:D3"
    "reserver-industrial-orin-j401|3767|0001|300|M.3|00:00:00:D4"
    "reserver-industrial-orin-j401|3767|0003|300|N.2|00:00:00:D6"
    "reserver-industrial-orin-j401|3767|0004|300|N.2|00:00:00:D6"
    "reserver-agx-orin-j501x|3701|0004|500|J.0|00:00:00:D2"
    "reserver-agx-orin-j501x|3701|0005|500|M.0|00:00:00:D0"
    "reserver-agx-orin-j501x-gmsl|3701|0004|500|J.0|00:00:00:D2"
    "reserver-agx-orin-j501x-gmsl|3701|0005|500|M.0|00:00:00:D0"
)

C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_BOLD=$'\e[1m'; C_RESET=$'\e[0m'
ok()   { printf '%s✓%s %s\n' "${C_GREEN}" "${C_RESET}" "$1"; }
warn() { printf '%s!%s %s\n' "${C_YELLOW}" "${C_RESET}" "$1"; }
err()  { printf '%s✗%s %s\n' "${C_RED}" "${C_RESET}" "$1"; }
hr()   { printf '%s\n' '------------------------------------------------------------'; }

# ---------- 参数 ----------
CMD="${1:-}"
shift || true
BOARD=""
VER="R36.4.3"
SKU=""
OUT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sku)   SKU="$2"; shift 2 ;;
        --ver)   VER="R${2#R}"; shift 2 ;;
        --out)   OUT="$2"; shift 2 ;;
        -*)      err "未知参数: $1"; exit 2 ;;
        *)       BOARD="$1"; shift ;;
    esac
done

list_boards() {
    echo "可用型号 (与 SKU 变体):"
    echo "------------------------------------"
    for e in "${BOARD_TABLE[@]}"; do
        IFS='|' read -r b did sid fab rev chip <<<"$e"
        printf '  %-32s SKU %s  (BOARDID %s, FAB %s, REV %s, CHIP_SKU %s)\n' "$b" "$sid" "$did" "$fab" "$rev" "$chip"
    done
}

find_board() { # $1=型号 $2=SKU (空=型号第一个)
    local b="$1" sku="${2:-}"
    local first=""
    for e in "${BOARD_TABLE[@]}"; do
        IFS='|' read -r tb tid tsku tfab trev tchip <<<"$e"
        [[ "$tb" != "$b" ]] && continue
        [[ -z "$first" ]] && first="$e"
        if [[ -z "$sku" || "$tsku" == "$sku" ]]; then
            echo "$e"
            return 0
        fi
    done
    [[ -n "$first" ]] && echo "$first" && return 0
    return 1
}

# ---------- 主逻辑 ----------
case "${CMD}" in
    list)
        list_boards
        ;;
    mfi|flash)
        [[ -z "$BOARD" && "$CMD" == *"mfi"* ]] && { err "缺少型号, 用法: ./build-firmware.sh mfi <型号>"; list_boards; exit 2; }
        entry="$(find_board "${BOARD}" "${SKU}")" || { err "未知型号: ${BOARD}"; exit 2; }
        IFS='|' read -r BOARD_NAME BOARDID BOARDSKU FAB BOARDREV CHIP_SKU <<<"$entry"

        BSP_TREE="${SSD_ROOT}/bsp/${VER}/Linux_for_Tegra"
        if [[ ! -f "${BSP_TREE}/flash.sh" ]]; then
            err "完整 BSP 树不存在: ${BSP_TREE}"
            echo "先运行: ./setup-workspace.sh ${VER}"
            exit 1
        fi
        if [[ ! -f "${BSP_TREE}/${BOARD_NAME}.conf" ]]; then
            err "型号配置不存在于 BSP 树: ${BOARD_NAME}.conf"
            echo "可用: $(ls "${BSP_TREE}"/*.conf 2>/dev/null | xargs -n1 basename | tr '\n' ' ')"
            exit 1
        fi

        hr
        echo "固件构建: ${BOARD_NAME} (${VER})"
        echo "  BOARDID=${BOARDID} BOARDSKU=${BOARDSKU} FAB=${FAB} BOARDREV=${BOARDREV} CHIP_SKU=${CHIP_SKU}"
        hr

        export TMPDIR="${SSD_ROOT}/tmp"
        [[ -d "${TMPDIR}" ]] || mkdir -p "${TMPDIR}"
        cd "${BSP_TREE}"

        common_args=(-p "-c bootloader/generic/cfg/flash_t234_qspi.xml --no-systemimg")

        if [[ "${CMD}" == "mfi" ]]; then
            [[ -n "${OUT}" ]] && TAR_OUT="${OUT}/mfi_${BOARD_NAME}.tar.gz" || TAR_OUT="${BSP_TREE}/mfi_${BOARD_NAME}.tar.gz"
            [[ -e "${TAR_OUT}" ]] && warn "已存在, 覆盖: ${TAR_OUT}"
            sudo env BOARDID="${BOARDID}" BOARDSKU="${BOARDSKU}" FAB="${FAB}" BOARDREV="${BOARDREV}" CHIP_SKU="${CHIP_SKU}" \
                ./tools/kernel_flash/l4t_initrd_flash.sh "${common_args[@]}" \
                --no-flash --massflash 5 --showlogs --network usb0 \
                "${BOARD_NAME}" external
            # massflash 产物默认在 BSP_TREE 根
            local_tar="${BSP_TREE}/mfi_${BOARD_NAME}.tar.gz"
            if [[ -f "${local_tar}" && "${local_tar}" != "${TAR_OUT}" ]]; then
                mkdir -p "$(dirname "${TAR_OUT}")"
                mv -f "${local_tar}" "${TAR_OUT}"
            fi
            if [[ -f "${TAR_OUT}" ]]; then
                ok "固件镜像: ${TAR_OUT}"
                ls -lh "${TAR_OUT}"
            else
                err "未找到生成的 mfi 压缩包"
                exit 1
            fi
        else
            lsusb 2>/dev/null | grep -qi nvidia || warn "未检测到 NVIDIA 设备, 请确认板子处于 Recovery 模式"
            sudo env BOARDID="${BOARDID}" BOARDSKU="${BOARDSKU}" FAB="${FAB}" BOARDREV="${BOARDREV}" CHIP_SKU="${CHIP_SKU}" \
                ./tools/kernel_flash/l4t_initrd_flash.sh \
                --external-device nvme0n1p1 \
                -c tools/kernel_flash/flash_l4t_t234_nvme.xml \
                "${common_args[@]}" --showlogs --network usb0 \
                "${BOARD_NAME}" internal
            ok "刷机完成"
        fi
        ;;
    *)
        err "用法: ./build-firmware.sh list|mfi|flash <型号> [--sku 0000] [--ver R36.4.3] [--out DIR]"
        exit 2
        ;;
esac