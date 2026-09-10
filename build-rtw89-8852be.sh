#!/usr/bin/env bash
# build-rtw89-8852be.sh
# =============================================================================
#   JP7.2  (L4T R39.2.0, 6.8.12-tegra, kernel-noble)   → in-tree 编译
#   JP6.2  (L4T R36.4.x, 5.15.148-tegra, kernel-jammy) → out-of-tree (lwfinger/rtw89)
#   JP5.1.3(L4T R35.5.0, 5.10.x-tegra, kernel_src)     → out-of-tree (lwfinger/rtw89)
#
# 符号表策略 (关键): 模块的 modpost 需要该内核的 Module.symvers (含内核导出
# 符号 CRC), 否则产物带 unresolved, 板上 modprobe 会失败。
#   - 有官方 kernel_headers.tbz2 → 解压其 Module.symvers (最快, CRC 权威)
#   - 没有 → 编译 make Image 生成 (自洽, 较慢)
#
# 用法:
#   ./build-rtw89-8852be.sh <jp7.2|jp6.2|jp5.1.3> [--bsp R36.4.3] [--outdir DIR]
#                            [--lw-src DIR] [--headers FILE.tbz2] [--no-clean]
#
#   --bsp      覆盖默认 BSP 版本 (jp6.2 默认 R36.4.4; jp5.1.3 默认 R35.5.0; jp7.2 固定 R39.2.0)
#   --outdir   产物输出目录 (默认 Build/<BSP>-rtw89-8852be/deploy)
#   --lw-src   rtw89 外部源码目录 (jp6.2/jp5.1.3; 默认 $HOME/rtw89-src)
#   --headers  NVIDIA kernel_headers.tbz2 路径 (指明后用其 Module.symvers)
#   --no-clean 跳过 mrproper / M= 清理 (增量重编)
#
# 前置:
#   - 内核源码树: Source/<BSP>/kernel/kernel-jammy-src (jp6.2)
#                 Source/R39.2.0/kernel/kernel-noble  (jp7.2)
#                 Source/<BSP>/kernel/kernel_src      (jp5.1.3)
#   - 工具链: toolchain/aarch64--glibc--stable-2022.08-1
#   - host: tools/host/bin (flex/bison/m4)
# =============================================================================

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${SCRIPT_DIR}"
TOOLCHAIN="${WORKSPACE}/toolchain/aarch64--glibc--stable-2022.08-1/bin/aarch64-buildroot-linux-gnu-"
HOST_TOOLS="${WORKSPACE}/tools/host/bin"

C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_RESET=$'\e[0m'
ok()   { printf '%s✓%s %s\n' "${C_GREEN}" "${C_RESET}" "$1"; }
warn() { printf '%s!%s %s\n' "${C_YELLOW}" "${C_RESET}" "$1"; }
err()  { printf '%s✗%s %s\n' "${C_RED}" "${C_RESET}" "$1"; }
usage() { sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ---------- 参数 ----------
[[ $# -lt 1 ]] && { usage; exit 1; }
TARGET="${1,,}"; shift
BSP_OVERRIDE=""; OUTDIR_OVERRIDE=""
LW_SRC="${HOME}/rtw89-src"; HEADERS_TBZ=""; DO_CLEAN=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --bsp)      BSP_OVERRIDE="${2:-}"; shift 2 ;;
        --outdir)   OUTDIR_OVERRIDE="${2:-}"; shift 2 ;;
        --lw-src)   LW_SRC="${2:-}"; shift 2 ;;
        --headers)  HEADERS_TBZ="${2:-}"; shift 2 ;;
        --no-clean) DO_CLEAN=0; shift ;;
        -h|--help)  usage; exit 0 ;;
        *) warn "未知参数: $1"; shift ;;
    esac
done

case "${TARGET}" in
    jp7.2|7.2|39.2.0|r39.2.0)
        MODE="in-tree"; BSP="R39.2.0"
        KDIR="${WORKSPACE}/Source/R39.2.0/kernel/kernel-noble"
        MODKO=(rtw89_core rtw89_pci rtw89_8852b rtw89_8852be)
        ;;
    jp6.2|6.2|36.4.*|r36.4*)
        MODE="out-of-tree"; BSP="${BSP_OVERRIDE:-R36.4.4}"; BSP="R${BSP#R}"
        KDIR="${WORKSPACE}/Source/${BSP}/kernel/kernel-jammy-src"
        MODKO=(rtw89core rtw89pci rtw_8852b rtw_8852be)
        ;;
    jp5.1.3|5.1.3|35.5.*|r35.5*)
        # JP5.1.3 (L4T R35.5.0, 5.10.x-tegra): 树内无 rtw89 → 同样走 lwfinger 外挂
        MODE="out-of-tree"; BSP="${BSP_OVERRIDE:-R35.5.0}"; BSP="R${BSP#R}"
        KDIR="${WORKSPACE}/Source/${BSP}/kernel/kernel_src/kernel-5.10"
        MODKO=(rtw89core rtw89pci rtw_8852b rtw_8852be)
        ;;
    *) err "未知目标: ${TARGET} (jp7.2 / jp6.2 / jp5.1.3)"; exit 1 ;;
esac

OUT_BASE="${OUTDIR_OVERRIDE:-${WORKSPACE}/Build/${BSP}-rtw89-8852be}"
KOUT="${OUT_BASE}/kbuild"
mkdir -p "${OUT_BASE}"

# ---------- 前置 ----------
[[ -f "${KDIR}/Makefile" ]] || { err "内核源码缺失: ${KDIR}"; exit 1; }
[[ -x "${TOOLCHAIN}gcc" ]] || { err "交叉编译器缺失: ${TOOLCHAIN}gcc (toolchain/)"; exit 1; }
[[ -x "${HOST_TOOLS}/flex" && -x "${HOST_TOOLS}/bison" ]] || { err "host flex/bison 缺失 (tools/host)"; exit 1; }
[[ "${MODE}" == "out-of-tree" && ! -d "${LW_SRC}" ]] && { err "外部源码缺失: ${LW_SRC} (git clone https://github.com/lwfinger/rtw89)"; exit 1; }

export ARCH=arm64
export CROSS_COMPILE="${TOOLCHAIN}"
export PATH="${HOST_TOOLS}:${PATH}"

echo "=== 目标: ${BSP} (${MODE}) ==="
echo "   内核: ${KDIR}"
echo "   版本: $(grep -E '^VERSION' "${KDIR}/Makefile" | head -1 | awk '{print $3}').$(grep -E '^PATCHLEVEL' "${KDIR}/Makefile" | head -1 | awk '{print $3}').$(grep -E '^SUBLEVEL' "${KDIR}/Makefile" | head -1 | awk '{print $3}')"

# ---------- 符号表 ----------
prepare_symvers() {
    # kbuild modpost (尤其 single_modules/file-target) 只接受 vmlinux 作为
    # 内核导出符号源; 手动放置 Module.symvers 不生效。标准路径: 先编 vmlinux。
    # KCFLAGS: R35 (5.10) 需 -march 使 gcc __sync 内建内联, 否则 vmlinux 链接失败
    if [[ -f "${KOUT}/vmlinux" ]]; then
        ok "符号表已就绪 (vmlinux): $(wc -l < "${KOUT}/Module.symvers") 条"
        return 0
    fi
    warn "编译 vmlinux 生成官方级符号表 (首次约 20-40 分钟, 增量后复用) ..."
    make -C "${KDIR}" O="${KOUT}" -j"$(nproc)" ${KSYM_KCFLAGS} vmlinux || exit 1
    ok "vmlinux 完成, Module.symvers 生成"
}

# ---------- 构建 ----------
(( DO_CLEAN )) && { warn "mrproper + 清理输出目录..."; make -C "${KDIR}" mrproper >/dev/null 2>&1 || true; rm -rf "${KOUT}"; }
mkdir -p "${KOUT}"

if [[ "${MODE}" == "in-tree" ]]; then
    # ===== JP7.2: kernel-noble in-tree =====
    make -C "${KDIR}" O="${KOUT}" defconfig || exit 1
    "${KDIR}/scripts/config" --file "${KOUT}/.config" --set-str LOCALVERSION "-tegra"
    if ! grep -qE '^CONFIG_RTW89_8852BE=m' "${KOUT}/.config"; then
        "${KDIR}/scripts/config" --file "${KOUT}/.config" \
            --module RTW89_CORE --module RTW89_PCI --module RTW89_8852B --module RTW89_8852BE \
            --module CFG80211 --module MAC80211
    fi
    KSYM_KCFLAGS=""
    make -C "${KDIR}" O="${KOUT}" -j"$(nproc)" modules_prepare || exit 1
    prepare_symvers

    # 全量模块: 依赖链 (arc4/rfkill/cfg80211/mac80211/rtw89) 按序编齐,
    # 生成的 Module.symvers 完整, 后续外部模块也可引用
    warn "全量 make modules (vmlinux 符号已就绪, 约 10-25 分钟)..."
    make -C "${KDIR}" O="${KOUT}" -j"$(nproc)" modules || exit 1
    ok "modules 完成, Module.symvers 共 $(wc -l < "${KOUT}/Module.symvers") 条"

    mkdir -p "${OUT_BASE}/deploy"
    for m in "${MODKO[@]}"; do
        f=$(find "${KOUT}/drivers/net/wireless/realtek/rtw89" -name "${m}.ko" | head -1)
        [[ -n "${f}" ]] && cp "${f}" "${OUT_BASE}/deploy/" || { err "缺失 ${m}.ko"; exit 1; }
    done

else
    # ===== JP6.2: kernel-jammy out-of-tree (lwfinger) =====
    # R35 (5.10): gcc __sync 原子内建在无 -march 时会生成 libgcc outline 调用
    # (__aarch64_cas4 等), 内核态无 libgcc → vmlinux 链接失败。
    # 显式 -march=armv8.4-a (与内核 asm-arch 一致) 使其内联为 LSE/LLSC 指令。
    # 该标志只影响本脚本触发的编译, 不改内核源码。
    ARCH_FLAGS=""
    # -Wno-error=...: gcc 11 对 NVIDIA 旧代码报 misleading-indentation (官方 gcc 9 无), 降为警告
    [[ "${TARGET}" == "jp5.1.3" || "${BSP}" == R35* ]] && ARCH_FLAGS='-march=armv8.4-a -Wno-error=misleading-indentation'
    make -C "${KDIR}" O="${KOUT}" defconfig || exit 1
    "${KDIR}/scripts/config" --file "${KOUT}/.config" --set-str LOCALVERSION "-tegra"
    grep -qE '^CONFIG_CFG80211=m|^CONFIG_MAC80211=m' "${KOUT}/.config" || { err "defconfig 无 CFG80211/MAC80211"; exit 1; }
    make -C "${KDIR}" O="${KOUT}" -j"$(nproc)" KCFLAGS="${ARCH_FLAGS}" modules_prepare || exit 1
    KSYM_KCFLAGS="KCFLAGS=${ARCH_FLAGS}"
    prepare_symvers

    warn "编译 cfg80211/mac80211 等 (全量 modules, 符号进 Module.symvers)..."
    make -C "${KDIR}" O="${KOUT}" -j"$(nproc)" KCFLAGS="${ARCH_FLAGS}" modules || exit 1

    (( DO_CLEAN )) && make -C "${LW_SRC}" clean >/dev/null 2>&1 || true
    make -C "${KDIR}" O="${KOUT}" -j"$(nproc)" M="${LW_SRC}" modules || exit 1

    mkdir -p "${OUT_BASE}/deploy"
    for m in "${MODKO[@]}"; do
        cp "${LW_SRC}/${m}.ko" "${OUT_BASE}/deploy/" 2>/dev/null || { err "缺失 ${m}.ko"; exit 1; }
    done
fi

# ---------- 验证 ----------
echo; echo "=== 产物 & vermagic ==="
for ko in "${OUT_BASE}/deploy/"*.ko; do
    base=$(basename "${ko}")
    vm=$(modinfo "${ko}" 2>/dev/null | awk '/^vermagic/{print $2}')
    dp=$(modinfo "${ko}" 2>/dev/null | awk '/^depends/{sub(/^depends:[ \t]*/,""); print}')
    printf '  %-18s %s  (depends: %s)\n' "${base}" "${vm:-?}" "${dp:-无}"
done

echo; echo "=== 符号自洽核对 (未定义须能在符号表/组内找到) ==="
    # 收集内核符号表 (Module.symvers 第2列) + 组内模块导出符号
    have_syms="${KOUT}/.check_syms"
    awk '{print $2}' "${KOUT}/Module.symvers" 2>/dev/null > "${have_syms}"
    for ko in "${OUT_BASE}/deploy/"*.ko; do
        nm -g --defined-only "${ko}" 2>/dev/null | awk '{print $3}' >> "${have_syms}"
    done
    sort -u "${have_syms}" -o "${have_syms}"
    allok=1
    for ko in "${OUT_BASE}/deploy/"*.ko; do
        miss=$(nm "${ko}" 2>/dev/null | awk '$1=="U"{print $2}' | grep -vxF -f "${have_syms}" | wc -l)
        if [[ "${miss}" -gt 0 ]]; then
            warn "$(basename "${ko}"): ${miss} 个符号无来源 (真正的 unresolved)"
            allok=0
        else
            ok "$(basename "${ko}"): 所有引用符号均有来源"
        fi
    done
    rm -f "${have_syms}"
    [[ "${allok}" -eq 1 ]] || exit 1

echo; ok "完成: ${OUT_BASE}/deploy/"
echo "  安装: sudo install -m 644 ${OUT_BASE}/deploy/*.ko /lib/modules/\$(uname -r)/updates/ && sudo depmod -a && sudo modprobe ${MODKO[3]}"
echo "  要求板子 vermagic 匹配, 且 /lib/firmware/rtw89/rtw8852b_fw.bin 存在"