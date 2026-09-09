#!/bin/bash
# jetson-firmware-build.sh
# Jetson 固件编译工作流
# 支持: Thor BSP / DIY Hybrid BSP / 内核编译
#
# 用法:
#   ./jetson-firmware-build.sh status
#   ./jetson-firmware-build.sh kernel build|install|clean
#   ./jetson-firmware-build.sh thor prepare|build|flash|cleanup|all
#   ./jetson-firmware-build.sh hybrid backup|prepare-app|generate-qspi|assemble|flash|full

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${SCRIPT_DIR}"
L4T_ROOT="${WORKSPACE}/Linux_for_Tegra"
TOOLCHAIN="${WORKSPACE}/toolchain/aarch64--glibc--stable-2022.08-1"

# 颜色
if [[ -t 1 ]]; then
    C_RED='\e[31m'; C_GREEN='\e[32m'; C_YELLOW='\e[33m'
    C_BLUE='\e[34m'; C_BOLD='\e[1m'; C_RESET='\e[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''; C_RESET=''
fi

info()  { printf '%sℹ%s %s\n' "${C_BLUE}" "${C_RESET}" "$1"; }
ok()    { printf '%s✓%s %s\n' "${C_GREEN}" "${C_RESET}" "$1"; }
warn()  { printf '%s⚠%s %s\n' "${C_YELLOW}" "${C_RESET}" "$1"; }
err()   { printf '%s✗%s %s\n' "${C_RED}" "${C_RESET}" "$1"; }
hr()    { printf '%s\n' '------------------------------------------------------------'; }
title() { printf '\n%s%s%s\n' "${C_BOLD}${C_BLUE}" "$1" "${C_RESET}"; hr; }

# ============================================================================
# 环境检查
# ============================================================================

check_l4t() {
    [[ -d "${L4T_ROOT}" ]] && { \
        [[ -f "${L4T_ROOT}/apply_binaries.sh" ]] || \
        ( [[ -d "${L4T_ROOT}/source" ]] && [[ -d "${L4T_ROOT}/bootloader" ]] ); \
    }
}

check_toolchain() {
    [[ -x "${TOOLCHAIN}/bin/aarch64-buildroot-linux-gnu-gcc" ]]
}

check_recovery() {
    local vid="$1"
    lsusb 2>/dev/null | grep -q "${vid}"
}

# 探测 L4T 中实际存在的内核源码目录名 (kernel-noble / kernel-jammy-src / kernel_src / kernel)
# 不同分支命名不同: R39.x → kernel-noble, R36.x 及更早 → kernel-jammy-src
find_kernel_src_dir() {
    local d
    for d in kernel-noble kernel-jammy-src kernel_src kernel; do
        if [[ -f "${L4T_ROOT}/source/kernel/${d}/Makefile" ]]; then
            echo "${d}"
            return 0
        fi
    done
    return 1
}

# 读取 L4T git 分支名; 非 git 仓库返回空
l4t_branch() {
    git -C "${L4T_ROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null || true
}

check_kernel_source() {
    [[ -n "$(find_kernel_src_dir)" ]]
}

# ============================================================================
# 状态
# ============================================================================

cmd_status() {
    title "Jetson 固件编译状态"

    # L4T
    echo "📦 Linux_for_Tegra:"
    if check_l4t; then
        ok "已就绪: ${L4T_ROOT}"
        du -sh "${L4T_ROOT}" 2>/dev/null
    else
        err "未找到，请先下载 BSP 包"
    fi

    # 工具链
    echo ""
    echo "🔧 交叉编译工具链:"
    if check_toolchain; then
        ok "已就绪: ${TOOLCHAIN}"
        "${TOOLCHAIN}/bin/aarch64-buildroot-linux-gnu-gcc" --version | head -1
    else
        err "未找到工具链"
    fi

    # 内核源码
    echo ""
    echo "🖥️ 内核源码:"
    local kdir branch
    if kdir="$(find_kernel_src_dir)"; then
        ok "已就绪 (${kdir})"
        du -sh "${L4T_ROOT}/source/kernel/${kdir}" 2>/dev/null
    else
        warn "内核源码未准备好 (需要: cp -r Source/<version>/kernel/kernel-noble|kernel-jammy-src Linux_for_Tegra/source/kernel/)"
    fi
    branch="$(l4t_branch)"
    if [[ -n "${branch}" ]]; then
        echo "  🔀 当前分支: ${branch}"
    fi

    # Recovery 设备
    echo ""
    echo "🔌 Recovery 设备:"
    check_recovery "0955:7045" && ok "Thor Recovery (0955:7045)" || info "Thor 未连接"
    check_recovery "0955:7523" && ok "Orin Recovery (0955:7523)" || info "Orin 未连接"

    # 编译产物
    echo ""
    echo "📁 编译产物:"
    if kdir="$(find_kernel_src_dir)" && [[ -f "${L4T_ROOT}/source/kernel_out/kernel/${kdir}/arch/arm64/boot/Image" ]]; then
        ok "内核镜像已编译"
    else
        info "内核镜像未编译"
    fi

    if [[ -f "${L4T_ROOT}/thor_build_flash.sh" ]]; then
        ok "Thor 脚本就绪"
    else
        info "Thor BSP 包未下载"
    fi

    # 可用板型
    echo ""
    echo "📋 可用板型:"
    ls "${L4T_ROOT}"/*.conf 2>/dev/null | head -5 | while read f; do
        echo "  - $(basename "$f" .conf)"
    done
    echo "  ... (更多见 Linux_for_Tegra/*.conf)"
}

# ============================================================================
# 内核编译
# ============================================================================

cmd_kernel_help() {
    cat <<'EOF'
用法: ./jetson-firmware-build.sh kernel <command>

命令:
  prepare   准备内核源码 (从 Source/ 复制到 Linux_for_Tegra/source/)
  build    编译内核 (需要 30+ 分钟)
  install  安装内核到 rootfs
  clean    清理编译产物
  help     显示帮助

前提条件:
  1. 工具链: toolchain/aarch64--glibc--stable-2022.08-1
  2. 源码: Source/<version>/kernel/kernel-noble 或 kernel-jammy-src (与 L4T 分支匹配)

示例:
  ./jetson-firmware-build.sh kernel prepare   # 准备源码 (自动匹配分支)
  ./jetson-firmware-build.sh kernel build     # 编译 (30分钟+)
  sudo ./jetson-firmware-build.sh kernel install  # 安装到 rootfs
EOF
}

cmd_kernel() {
    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
        prepare)
            title "内核: 准备源码"

            local kdir ver ver_upper src
            if ! kdir="$(find_kernel_src_dir)" && [[ ! -f "${L4T_ROOT}/source/kernel/kernel-noble/Makefile" ]]; then
                # L4T 中没有源码时, 从分支名推断目标目录名
                ver="$(l4t_branch)"
                case "${ver}" in
                    r39*|r4*|r5*) kdir="kernel-noble" ;;
                    *)            kdir="kernel-jammy-src" ;;
                esac
            fi
            if [[ -z "${kdir}" ]]; then
                err "无法确定内核源码目录名"
                return 1
            fi

            # 目标目录 = 当前 L4T 的 source/kernel/<kdir> (rm 只清目标, 保留同分支其它格式)
            local src_candidates=()
            if ver="$(l4t_branch)" && [[ -n "${ver}" ]]; then
                ver_upper="${ver^^}"
                src_candidates+=("${WORKSPACE}/Source/${ver_upper}/kernel/${kdir}")
            fi
            src_candidates+=("${WORKSPACE}/Source"/*/"kernel/${kdir}")

            src=""
            for c in "${src_candidates[@]}"; do
                if [[ -d "${c}" ]]; then
                    src="${c}"
                    break
                fi
            done
            if [[ -z "${src}" ]]; then
                err "源码不存在: Source/<version>/kernel/${kdir} (分支: $(l4t_branch))"
                return 1
            fi

            info "复制内核源码到 L4T..."
            rm -rf "${L4T_ROOT}/source/kernel/${kdir}" 2>/dev/null || true
            cp -r "${src}" "${L4T_ROOT}/source/kernel/"

            if check_kernel_source; then
                ok "源码准备完成"
                du -sh "${L4T_ROOT}/source/kernel/${kdir}"
            else
                err "源码准备失败"
                return 1
            fi
            ;;

        build)
            title "内核: 编译"

            local kdir
            if ! kdir="$(find_kernel_src_dir)"; then
                warn "内核源码未准备好，先执行: kernel prepare"
                read -p "是否现在准备? [Y/n] " -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                    cmd_kernel prepare
                    kdir="$(find_kernel_src_dir)"
                else
                    return 1
                fi
            fi
            if [[ -z "${kdir}" ]]; then
                err "内核源码不可用: ${L4T_ROOT}/source/kernel/"
                return 1
            fi

            if ! check_toolchain; then
                err "工具链不存在: ${TOOLCHAIN}"
                return 1
            fi

            # 设置环境
            export ARCH=arm64
            export CROSS_COMPILE="${TOOLCHAIN}/bin/aarch64-buildroot-linux-gnu-"
            export PATH="${TOOLCHAIN}/bin:$PATH"

            cd "${L4T_ROOT}/source"
            
            info "开始编译内核 (预计 30-60 分钟)..."
            info "编译日志会输出到终端"
            info "完成后内核镜像位于: source/kernel_out/kernel/${kdir}/arch/arm64/boot/Image"
            echo ""
            
            # 编译
            ./nvbuild.sh
            
            # 检查结果
            local image="${L4T_ROOT}/source/kernel_out/kernel/${kdir}/arch/arm64/boot/Image"
            if [[ -f "${image}" ]]; then
                ok "内核编译成功!"
                ls -lh "${image}"
            else
                err "编译失败，Image 未生成"
                return 1
            fi
            ;;

        install)
            title "内核: 安装到 rootfs"

            local kdir
            if ! kdir="$(find_kernel_src_dir)" || [[ ! -f "${L4T_ROOT}/source/kernel_out/kernel/${kdir}/arch/arm64/boot/Image" ]]; then
                err "内核未编译，请先: kernel build"
                return 1
            fi

            export ARCH=arm64
            export CROSS_COMPILE="${TOOLCHAIN}/bin/aarch64-buildroot-linux-gnu-"
            export PATH="${TOOLCHAIN}/bin:$PATH"
            export INSTALL_MOD_PATH="${L4T_ROOT}/rootfs/"

            cd "${L4T_ROOT}/source"

            info "安装内核到 rootfs..."
            ./do_copy.sh
            ./nvbuild.sh -i
            
            ok "内核安装完成"
            ;;

        clean)
            title "内核: 清理"
            rm -rf "${L4T_ROOT}/source/kernel_out"
            ok "清理完成"
            ;;

        help|--help|-h)
            cmd_kernel_help
            ;;

        *)
            err "未知命令: $cmd"
            cmd_kernel_help
            return 1
            ;;
    esac
}

# ============================================================================
# Thor BSP
# ============================================================================

cmd_thor_help() {
    cat <<'EOF'
用法: ./jetson-firmware-build.sh thor <command>

命令:
  prepare   下载 rootfs + apply_binaries
  build    编译内核 + 更新 initrd
  flash    烧录固件 (需 Recovery 模式)
  cleanup  清理构建产物
  all      一键全流程
  help     显示帮助

前提条件:
  1. 下载 Thor BSP 包并解压到 Linux_for_Tegra/
  2. Thor 进入 Recovery 模式

示例:
  ./jetson-firmware-build.sh thor prepare
  ./jetson-firmware-build.sh thor build
  sudo -E ./jetson-firmware-build.sh thor flash
EOF
}

cmd_thor() {
    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
        prepare|build|flash|cleanup|all)
            if [[ ! -f "${L4T_ROOT}/thor_build_flash.sh" ]]; then
                err "Thor BSP 包未找到!"
                info "请先下载 JetPack 7.1 BSP 包并解压到: ${L4T_ROOT}"
                info "下载: https://seeedstudio88-my.sharepoint.com/..."
                return 1
            fi
            ;;
    esac

    case "$cmd" in
        prepare)
            title "Thor: Prepare"
            cd "${L4T_ROOT}"
            ./thor_build_flash.sh prepare
            ;;

        build)
            title "Thor: Build"
            cd "${L4T_ROOT}"
            ./thor_build_flash.sh build
            ;;

        flash)
            title "Thor: Flash"
            if ! check_recovery "0955:7045"; then
                err "Thor 未进入 Recovery 模式!"
                info "请确保:"
                info "  1. 连接 USB Type-C 到主机"
                info "  2. 按住 Force Recovery 键"
                info "  3. 按 Power 键开机"
                info "  4. 检查 lsusb 是否显示 0955:7045"
                return 1
            fi
            ok "检测到 Thor Recovery 设备"
            cd "${L4T_ROOT}"
            sudo -E ./thor_build_flash.sh flash
            ;;

        cleanup)
            title "Thor: Cleanup"
            cd "${L4T_ROOT}"
            ./thor_cleanup.sh incremental
            ;;

        all)
            title "Thor: 全流程"
            cmd_thor prepare
            cmd_thor build
            cmd_thor flash
            ;;

        help|--help|-h)
            cmd_thor_help
            ;;

        *)
            err "未知命令: $cmd"
            cmd_thor_help
            return 1
            ;;
    esac
}

# ============================================================================
# DIY Hybrid BSP
# ============================================================================

cmd_hybrid_help() {
    cat <<'EOF'
用法: ./jetson-firmware-build.sh hybrid <command> [options]

命令:
  backup          备份 DevKit 全量环境
  prepare-app     准备 APP-only (移除 DevKit QSPI)
  generate-qspi  生成目标板 QSPI
  assemble        组装 Hybrid mfi
  flash           烧录 Hybrid mfi 到目标板
  full           完整流程 (备份 -> 组装 -> 烧录)
  help           显示帮助

示例:
  # 备份 DevKit (需 DevKit Recovery)
  sudo ./jetson-firmware-build.sh hybrid backup -b recomputer-orin-j401

  # 生成目标板 QSPI (需目标板 Recovery)
  sudo ./jetson-firmware-build.sh hybrid generate-qspi -b recomputer-orin-j401

  # 烧录
  sudo ./jetson-firmware-build.sh hybrid flash -b recomputer-orin-j401
EOF
}

cmd_hybrid() {
    local cmd="${1:-help}"
    shift || true

    # 解析参数
    local board="recomputer-orin-j401"
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -b|--board)
                board="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    case "$cmd" in
        backup)
            title "Hybrid: 备份 DevKit"
            
            if ! check_recovery "0955:7523"; then
                err "DevKit 未进入 Recovery 模式!"
                info "请确保 DevKit 连接 USB Type-C 并进入 Recovery"
                return 1
            fi
            ok "检测到 Recovery 设备"
            
            cd "${L4T_ROOT}"
            info "执行备份..."
            sudo ./tools/backup_restore/l4t_backup_restore.sh -e nvme0n1 -b -c "${board}"
            
            if [[ -d "${L4T_ROOT}/tools/backup_restore/images" ]]; then
                ok "备份完成!"
                du -sh "${L4T_ROOT}/tools/backup_restore/images"
            fi
            ;;

        prepare-app)
            title "Hybrid: 准备 APP-only"
            
            local backup_dir="${L4T_ROOT}/tools/backup_restore/images"
            local app_only_dir="${L4T_ROOT}/tools/backup_restore/images_app_only"
            
            if [[ ! -d "${backup_dir}" ]]; then
                err "备份不存在，请先执行: hybrid backup"
                return 1
            fi
            
            info "复制备份到 APP-only..."
            rm -rf "${app_only_dir}"
            cp -a "${backup_dir}" "${app_only_dir}"
            
            info "移除 DevKit QSPI..."
            rm -f "${app_only_dir}/QSPI0.img" 2>/dev/null
            
            ok "APP-only 准备完成"
            ;;

        generate-qspi)
            title "Hybrid: 生成目标板 QSPI"
            
            if ! check_recovery "0955:7523"; then
                err "目标板未进入 Recovery 模式!"
                return 1
            fi
            ok "检测到 Recovery 设备"
            
            cd "${L4T_ROOT}"
            info "生成 QSPI..."
            
            sudo BOARDID="3767" BOARDSKU="0005" FAB="300" BOARDREV="V.2" CHIP_SKU="00:00:00:D5" \
                ./tools/kernel_flash/l4t_initrd_flash.sh \
                --external-device nvme0n1p1 \
                -c tools/kernel_flash/flash_l4t_t234_nvme.xml \
                -p "-c bootloader/generic/cfg/flash_t234_qspi.xml --no-systemimg" \
                --no-flash --massflash 5 --showlogs --network usb0 \
                "${board}" internal
            ;;

        assemble)
            title "Hybrid: 组装 mfi"
            
            local backup_dir="${L4T_ROOT}/tools/backup_restore/images_app_only"
            local internal_dir="${L4T_ROOT}/tools/kernel_flash/images/internal"
            local mfi_dir="${L4T_ROOT}/mfi_${board}"
            
            if [[ ! -d "${backup_dir}" ]]; then
                err "APP-only 不存在，请先执行: hybrid prepare-app"
                return 1
            fi
            
            if [[ ! -d "${internal_dir}" ]]; then
                err "QSPI 未生成，请先执行: hybrid generate-qspi"
                return 1
            fi
            
            info "创建 mfi 目录..."
            mkdir -p "${mfi_dir}"
            cp "${L4T_ROOT}/${board}.conf" "${mfi_dir}/" 2>/dev/null || true
            mkdir -p "${mfi_dir}/tools/kernel_flash/images/internal"
            mkdir -p "${mfi_dir}/tools/kernel_flash/images/external"
            cp -r "${internal_dir}"/* "${mfi_dir}/tools/kernel_flash/images/internal/" 2>/dev/null || true
            cp -r "${backup_dir}"/* "${mfi_dir}/tools/kernel_flash/images/external/" 2>/dev/null || true
            
            cd "${L4T_ROOT}"
            tar czf "mfi_${board}.tar.gz" --exclude="*QSPI0*" "mfi_${board}" 2>/dev/null
            
            if [[ -f "mfi_${board}.tar.gz" ]]; then
                ok "mfi 打包完成!"
                ls -lh "mfi_${board}.tar.gz"
            fi
            ;;

        flash)
            title "Hybrid: 烧录"
            
            if ! check_recovery "0955:7523"; then
                err "目标板未进入 Recovery 模式!"
                return 1
            fi
            ok "检测到 Recovery 设备"
            
            local mfi_dir="${L4T_ROOT}/mfi_${board}"
            if [[ ! -d "${mfi_dir}" ]] && [[ -f "${L4T_ROOT}/mfi_${board}.tar.gz" ]]; then
                info "解压 mfi 包..."
                tar xzf "mfi_${board}.tar.gz"
            fi
            
            if [[ ! -d "${mfi_dir}" ]]; then
                err "mfi 不存在，请先执行: hybrid assemble"
                return 1
            fi
            
            cd "${mfi_dir}"
            info "执行烧录..."
            sudo ./tools/kernel_flash/l4t_initrd_flash.sh --flash-only --massflash 1 --network usb0 --showlogs
            ;;

        full)
            title "Hybrid: 完整流程"
            info "备份 -> 准备 -> QSPI -> 组装 -> 烧录"
            echo ""
            
            info "步骤 1: 备份 DevKit (需要 DevKit Recovery)"
            cmd_hybrid backup
            
            echo ""
            info "步骤 2: 准备 APP-only"
            cmd_hybrid prepare-app
            
            echo ""
            info "步骤 3: 生成 QSPI (需要目标板 Recovery)"
            cmd_hybrid generate-qspi
            
            echo ""
            info "步骤 4: 组装 mfi"
            cmd_hybrid assemble
            
            echo ""
            read -p "是否烧录? [y/N] " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                cmd_hybrid flash
            fi
            ;;

        help|--help|-h)
            cmd_hybrid_help
            ;;

        *)
            err "未知命令: $cmd"
            cmd_hybrid_help
            return 1
            ;;
    esac
}

# ============================================================================
# 主入口
# ============================================================================

main() {
    local cmd="${1:-status}"
    shift || true

    case "$cmd" in
        status)
            cmd_status
            ;;
        kernel)
            cmd_kernel "$@"
            ;;
        thor)
            cmd_thor "$@"
            ;;
        hybrid)
            cmd_hybrid "$@"
            ;;
        help|--help|-h)
            echo "Jetson 固件编译工具"
            echo ""
            echo "用法:"
            echo "  $0 status              查看状态"
            echo "  $0 kernel <command>    内核编译"
            echo "  $0 thor <command>     Thor BSP"
            echo "  $0 hybrid <command>   DIY Hybrid BSP"
            echo ""
            echo "更多信息:"
            echo "  $0 status"
            echo "  $0 kernel help"
            echo "  $0 thor help"
            echo "  $0 hybrid help"
            ;;
        *)
            err "未知命令: $cmd"
            echo "使用 '$0 help' 查看帮助"
            return 1
            ;;
    esac
}

main "$@"
