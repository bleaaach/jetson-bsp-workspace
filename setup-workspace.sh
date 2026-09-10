#!/usr/bin/env bash
# setup-workspace.sh
# =============================================================================
# 从 git clone 的干净状态一键重建 Jetson BSP 工作区素材。
#
# bsp-workspace 的 GitHub 仓库只含脚本/web/文档(~134 文件)。以下素材不在
# git 里，clone 后必须重建:
#   Downloads/<ver>/      —— NVIDIA 官方 BSP 包 (public_sources/rootfs/Jetson_Linux)
#   Source/<ver>/kernel/  —— 内核源码
#   toolchain/            —— 交叉编译工具链
#   repos/Linux_for_Tegra —— Seeed BSP git 仓库
#   bsp/<ver>/Linux_for_Tegra —— 完整可刷机包 (NVIDIA base + Seeed 覆盖 + rootfs)
#
# 用法:
#   ./setup-workspace.sh [R36.4.3] [--skip-download] [--no-proxy]
#
# 环境变量:
#   SEED_BRANCH    Seeed 仓库分支 (默认 r36.4.3)
#   TOOLCHAIN_URL  工具链下载地址 (默认 NVIDIA 官方 aarch64--glibc--stable-2022.08-1)
# =============================================================================
set -euo pipefail

WORKSPACE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSD_ROOT="$(dirname "${WORKSPACE}")"          # /media/seeed/bsp-ssd1
REPOS_DIR="${SSD_ROOT}/repos"
BSP_DIR="${SSD_ROOT}/bsp"
DOWNLOADS="${WORKSPACE}/Downloads"
SOURCE_DIR="${WORKSPACE}/Source"
TOOLCHAIN_DIR="${WORKSPACE}/toolchain"

VERSION="${1:-R36.4.3}"
VERSION="R${VERSION#R}"
SKIP_DOWNLOAD=0
USE_PROXY=1

for a in "$@"; do
    case "$a" in
        --skip-download) SKIP_DOWNLOAD=1 ;;
        --no-proxy)      USE_PROXY=0 ;;
    esac
done

# ---------- 代理 ----------
detect_proxy() {
    (( USE_PROXY )) || return 0
    local p
    for p in "http://127.0.0.1:7897" "http://127.0.0.1:7890" "http://127.0.0.1:1080"; do
        if timeout 3 curl -sI -x "$p" https://github.com >/dev/null 2>&1; then
            echo "$p"
            return 0
        fi
    done
    echo ""
}

C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_RESET=$'\e[0m'
ok()   { printf '%s✓%s %s\n' "${C_GREEN}" "${C_RESET}" "$1"; }
warn() { printf '%s!%s %s\n' "${C_YELLOW}" "${C_RESET}" "$1"; }
err()  { printf '%s✗%s %s\n' "${C_RED}" "${C_RESET}" "$1"; }
section() { printf '\n========== %s ==========\n' "$1"; }

PROXY="$(detect_proxy)"
[[ -n "$PROXY" ]] && ok "检测到代理: $PROXY" || warn "无可用代理 (需要访问 github.com / developer.nvidia.com)"

# ---------- 1. 目录骨架 ----------
section "创建目录骨架"
mkdir -p "${REPOS_DIR}" "${BSP_DIR}" "${DOWNLOADS}/${VERSION}" "${SOURCE_DIR}/${VERSION}"
ok "repos/ bsp/ Downloads/${VERSION} Source/${VERSION} 就绪"
[[ -d "${SSD_ROOT}/builds" ]] || mkdir -p "${SSD_ROOT}/builds"

# ---------- 2. NVIDIA 官方包 ----------
if (( SKIP_DOWNLOAD )); then
    warn "跳过下载 (--skip-download)"
else
    section "下载 NVIDIA 官方包: ${VERSION}"
    rel="${VERSION#R}"
    arch=${VERSION}_aarch64
    dl() { # name url
        local name="$1" url="$2" dest="${DOWNLOADS}/${VERSION}/${name}"
        if [[ -f "${dest}" ]]; then ok "已存在: ${name}"; return; fi
        echo "下载 ${name} ..."
        curl -fL --retry 3 --retry-delay 5 -o "${dest}.part" "${url}"
        mv "${dest}.part" "${dest}"
        ok "${name}"
    }
    dl "public_sources.tbz2" "https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.3/release/public_sources.tbz2"
    dl "Jetson_Linux_r36.4.3_aarch64.tbz2" "https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.3/release/Jetson_Linux_r36.4.3_aarch64.tbz2"
    dl "Tegra_Linux_Sample-Root-Filesystem_r36.4.3_aarch64.tbz2" "https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.3/release/Tegra_Linux_Sample-Root-Filesystem_r36.4.3_aarch64.tbz2"
fi

# ---------- 3. 工具链 ----------
section "工具链"
TC_TARGET="${TOOLCHAIN_DIR}/aarch64--glibc--stable-2022.08-1"
if [[ -x "${TC_TARGET}/bin/aarch64-buildroot-linux-gnu-gcc" ]]; then
    ok "已存在: toolchain/${TC_TARGET##*/}"
else
    TC_SRC="${DOWNLOADS}/${VERSION}/aarch64--glibc--stable-2022.08-1.tar.bz2"
    if [[ ! -f "${TC_SRC}" ]]; then
        TC_URL="${TOOLCHAIN_URL:-https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v3.0/toolchain/aarch64--glibc--stable-2022.08-1.tar.bz2}"
        echo "下载工具链 ..."
        curl -fL --retry 3 -o "${TC_SRC}.part" "${TC_URL}"
        mv "${TC_SRC}.part" "${TC_SRC}"
    fi
    mkdir -p "${TOOLCHAIN_DIR}"
    tar -xjf "${TC_SRC}" -C "${TOOLCHAIN_DIR}/"
    ok "工具链就绪: ${TC_TARGET}"
fi

# ---------- 4. 内核源码 (Source/<ver>/kernel) ----------
section "内核源码"
KSRC="${SOURCE_DIR}/${VERSION}/kernel"
if [[ -f "${KSRC}/kernel-jammy-src/Makefile" ]]; then
    ok "已存在: ${KSRC}/kernel-jammy-src"
else
    ARCHIVE="${DOWNLOADS}/${VERSION}/public_sources.tbz2"
    mkdir -p "${KSRC}"
    echo "解压 public_sources.tbz2 中的 kernel_src.tbz2 ..."
    tar -xjf "${ARCHIVE}" -C "${KSRC}" Linux_for_Tegra/source/kernel_src.tbz2
    tar -xjf "${KSRC}/Linux_for_Tegra/source/kernel_src.tbz2" -C "${KSRC}/"
    rm -rf "${KSRC}/Linux_for_Tegra"
    # kernel_src.tbz2 解出顶层可能是 kernel/ 或 kernel-jammy-src/
    if [[ -d "${KSRC}/kernel/kernel-jammy-src" ]]; then
        : # 已是 kernel/kernel-jammy-src 布局
    elif [[ -d "${KSRC}/kernel-jammy-src" ]]; then
        mv "${KSRC}/kernel-jammy-src" "${KSRC}/kernel/"
    fi
    ok "内核源码就绪: ${KSRC}"
fi

# ---------- 5. Seeed 仓库 (repos/Linux_for_Tegra) ----------
section "Seeed BSP 仓库"
BRANCH="${SEED_BRANCH:-${VERSION,,}}"
if [[ -d "${REPOS_DIR}/Linux_for_Tegra/.git" ]] && git -C "${REPOS_DIR}/Linux_for_Tegra" rev-parse --verify HEAD >/dev/null 2>&1; then
    ok "已存在: repos/Linux_for_Tegra"
    git -C "${REPOS_DIR}/Linux_for_Tegra" config http.proxy "${PROXY}" 2>/dev/null || true
else
    if [[ -d "${REPOS_DIR}/Linux_for_Tegra" ]] && [[ -z "$(ls -A "${REPOS_DIR}/Linux_for_Tegra" 2>/dev/null)" ]]; then
        rmdir "${REPOS_DIR}/Linux_for_Tegra"
    fi
    echo "克隆 Seeed-Studio/Linux_for_Tegra (分支 ${BRANCH}) ..."
    git_clone() {
        git clone --depth=1 --filter=blob:none -b "${BRANCH}" \
            https://github.com/Seeed-Studio/Linux_for_Tegra.git "$1"
    }
    if [[ -n "${PROXY}" ]] && ! git_clone "${REPOS_DIR}/Linux_for_Tegra" 2>/dev/null; then
        echo "直连失败，走代理 ..."
        git -c http.proxy="${PROXY}" clone --depth=1 --filter=blob:none -b "${BRANCH}" \
            https://github.com/Seeed-Studio/Linux_for_Tegra.git "${REPOS_DIR}/Linux_for_Tegra"
    else
        git_clone "${REPOS_DIR}/Linux_for_Tegra"
    fi
    git -C "${REPOS_DIR}/Linux_for_Tegra" config http.proxy "${PROXY}" 2>/dev/null || true
    ok "Seeed 仓库就绪"
fi

# ---------- 6. 完整刷机包 (bsp/<ver>/Linux_for_Tegra) ----------
section "完整刷机包 bsp/${VERSION}/Linux_for_Tegra"
BSP_TREE="${BSP_DIR}/${VERSION}/Linux_for_Tegra"
if [[ -f "${BSP_TREE}/flash.sh" ]]; then
    ok "已存在: ${BSP_TREE}"
else
    L4T_BASE="${DOWNLOADS}/${VERSION}/Linux_for_Tegra"
    if [[ ! -f "${L4T_BASE}/flash.sh" ]]; then
        echo "解压 NVIDIA 底包 ..."
        mkdir -p "${DOWNLOADS}/${VERSION}/l4t_tmp"
        tar -xjf "${DOWNLOADS}/${VERSION}/Jetson_Linux_r36.4.3_aarch64.tbz2" -C "${DOWNLOADS}/${VERSION}/l4t_tmp/"
        mv "${DOWNLOADS}/${VERSION}/l4t_tmp/Linux_for_Tegra" "${L4T_BASE}"
        rmdir "${DOWNLOADS}/${VERSION}/l4t_tmp"
        ok "NVIDIA 底包: ${L4T_BASE}"
    fi
    echo "覆盖 Seeed 配置 ..."
    mkdir -p "${BSP_TREE}"
    shopt -s dotglob
    cp -a "${L4T_BASE}/". "${BSP_TREE}/"
    cp -a "${REPOS_DIR}/Linux_for_Tegra/". "${BSP_TREE}/"
    shopt -u dotglob
    echo "解压 rootfs ..."
    sudo tar -xpf "${DOWNLOADS}/${VERSION}/Tegra_Linux_Sample-Root-Filesystem_r36.4.3_aarch64.tbz2" -C "${BSP_TREE}/rootfs/"
    echo "运行 apply_binaries.sh ..."
    cd "${BSP_TREE}"
    sudo -E ./apply_binaries.sh
    cd "${WORKSPACE}"
    ok "完整刷机包就绪: ${BSP_TREE}"
fi

# ---------- 7. 兼容软链接 ----------
section "兼容软链接"
if [[ ! -e "${DOWNLOADS}/${VERSION}/Linux_for_Tegra" ]]; then
    ln -s "${REPOS_DIR}/Linux_for_Tegra" "${DOWNLOADS}/${VERSION}/Linux_for_Tegra"
    ok "Downloads/${VERSION}/Linux_for_Tegra -> repos/"
fi
if [[ ! -e "${WORKSPACE}/Linux_for_Tegra" ]]; then
    ln -s "${REPOS_DIR}/Linux_for_Tegra" "${WORKSPACE}/Linux_for_Tegra"
    ok "bsp-workspace/Linux_for_Tegra -> repos/"
fi

echo
section "完成"
echo "  工作区:   ${WORKSPACE}"
echo "  Seeed:    ${REPOS_DIR}/Linux_for_Tegra  (分支 ${BRANCH})"
echo "  刷机包:   ${BSP_TREE}"
echo "  内核源码: ${KSRC}"
echo
echo "下一步:"
echo "  cd ${WORKSPACE}"
echo "  ./jetson-bsp-workflow.sh query iptable_raw"