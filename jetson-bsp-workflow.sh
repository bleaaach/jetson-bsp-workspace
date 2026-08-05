#!/usr/bin/env bash
# jetson-bsp-workflow.sh
# ---------------------------------------------------------------------------
# Jetson BSP 模块开发完整工作流
# 
# 整合: 下载 BSP 源码 → 查询模块信息 → 编译模块 → 推送到 Jetson
#
# 用法:
#   ./jetson-bsp-workflow.sh                    # 交互式菜单
#   ./jetson-bsp-workflow.sh <module>           # 查询并编译模块
#   ./jetson-bsp-workflow.sh download <version> # 下载 BSP 源码 (例: R36.4.4)
#   ./jetson-bsp-workflow.sh query <module>     # 查询模块信息
#   ./jetson-bsp-workflow.sh build <module>     # 编译模块
#   ./jetson-bsp-workflow.sh push [module]      # 推送模块到 Jetson
#   ./jetson-bsp-workflow.sh list               # 列出所有可用版本
#   ./jetson-bsp-workflow.sh info               # 查看版本信息
#
# 环境变量:
#   JETSON_BSP_VERSION   默认 BSP 版本 (如 R36.4.4)
#   JETSON_HOST          Jetson SSH 目标
#   SSHPASS              SSH 密码
#
# 示例:
#   ./jetson-bsp-workflow.sh download R36.4.4    # 下载 BSP
#   ./jetson-bsp-workflow.sh query qmi_wwan      # 查询模块
#   ./jetson-bsp-workflow.sh build qmi_wwan     # 编译模块
#   JETSON_HOST=seeed@10.0.0.5 ./jetson-bsp-workflow.sh push qmi_wwan  # 推送
# ---------------------------------------------------------------------------

set -u

# ========== 路径定义 ==========
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workspace_dir="${SCRIPT_DIR}"
SOURCE_DIR="${workspace_dir}/Source"
BUILD_DIR="${workspace_dir}/Build"
DOWNLOAD_DIR="${workspace_dir}/Downloads"

# ========== 默认 BSP 版本 ==========
JETSON_BSP_VERSION="${JETSON_BSP_VERSION:-R36.4.4}"
JETSON_BSP_VERSION="R${JETSON_BSP_VERSION#R}"

# ========== 部署目标 ==========
JETSON_HOST="${JETSON_HOST:-jetson}"
JETSON_SSH_PORT="${JETSON_SSH_PORT:-2222}"

# ========== 颜色输出 ==========
if [[ -t 1 ]]; then
    C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
    C_BLUE=$'\e[34m'; C_BOLD=$'\e[1m'; C_RESET=$'\e[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''; C_RESET=''
fi

ok()   { printf '%s✓%s %s\n' "${C_GREEN}" "${C_RESET}" "$1"; }
warn() { printf '%s!%s %s\n' "${C_YELLOW}" "${C_RESET}" "$1"; }
err()  { printf '%s✗%s %s\n' "${C_RED}" "${C_RESET}" "$1"; }
hr()   { printf '%s\n' '------------------------------------------------------------'; }
title() { printf '\n%s%s%s\n' "${C_BOLD}${C_BLUE}" "$1" "${C_RESET}"; hr; }

# ========== 辅助函数 ==========
# 检测可用的 BSP 版本
detect_bsp_versions() {
    local versions=()
    for d in "${SOURCE_DIR}"/R*/; do
        if [[ -d "${d}" ]] && [[ -f "${d}/Makefile" || -d "${d}/kernel"* ]]; then
            versions+=("$(basename "${d}")")
        fi
    done
    # 也检查 Download 目录中的压缩包
    for d in "${DOWNLOAD_DIR}"/R*/; do
        if [[ -d "${d}" ]]; then
            local v="$(basename "${d}")"
            if [[ ! " ${versions[*]} " =~ " ${v} " ]]; then
                versions+=("${v}")
            fi
        fi
    done
    printf '%s\n' "${versions[@]}" | sort -u
}

# 检测可用的 Build 配置
detect_build_configs() {
    local configs=()
    for d in "${BUILD_DIR}"/R*/; do
        if [[ -d "${d}" ]] && [[ -f "${d}/.config" ]]; then
            configs+=("$(basename "${d}")")
        fi
    done
    printf '%s\n' "${configs[@]}" | sort -u
}

# 查找内核源码路径
find_kernel_source() {
    local ver="$1"
    local candidates=(
        "${SOURCE_DIR}/${ver}/kernel-jammy-src"
        "${SOURCE_DIR}/${ver}/kernel/kernel-jammy-src"
        "${SOURCE_DIR}/${ver}/Linux_for_Tegra/source/public/kernel"
        "${DOWNLOAD_DIR}/${ver}/Linux_for_Tegra/source/kernel/kernel-jammy-src"
        "${DOWNLOAD_DIR}/${ver}/Linux_for_Tegra/source/kernel"
    )
    for c in "${candidates[@]}"; do
        if [[ -f "${c}/Makefile" ]]; then
            echo "${c}"
            return 0
        fi
    done
    return 1
}

# 获取当前内核源码路径
get_kernel_source() {
    local ver="${1:-${JETSON_BSP_VERSION}}"
    find_kernel_source "${ver}" || echo "${SOURCE_DIR}/${ver}/kernel-jammy-src"
}

# ========== 命令: 下载 BSP ==========
cmd_download() {
    local version="${1:-${JETSON_BSP_VERSION}}"
    version="R${version#R}"
    
    title "下载 BSP 源码: ${version}"
    
    # 检查是否已存在
    local download_path="${DOWNLOAD_DIR}/${version}/public_sources.tbz2"
    if [[ -f "${download_path}" ]]; then
        ok "BSP 源码已存在: ${download_path}"
        printf '是否重新下载? [y/N]: '
        read -r ans
        if [[ "${ans}" != "y" && "${ans}" != "Y" ]]; then
            echo "跳过下载"
            return 0
        fi
    fi
    
    # 执行下载
    echo "正在从 NVIDIA 下载 ${version}..."
    if [[ -x "${SCRIPT_DIR}/download-jetson-bsp-sources.sh" ]]; then
        "${SCRIPT_DIR}/download-jetson-bsp-sources.sh" "${version}"
    else
        # 内联下载逻辑
        archive_url="https://developer.nvidia.com/embedded/jetson-linux-archive"
        release_pattern="${version#R}"
        release_pattern="${release_pattern//./\\.}"
        
        archive_html="$(mktemp)"
        release_html="$(mktemp)"
        trap 'rm -f "${archive_html}" "${release_html}"' EXIT
        
        curl -fsSL --retry 3 "${archive_url}" -o "${archive_html}" || {
            err "无法访问 NVIDIA 下载页面"
            return 1
        }
        
        release_href="$(sed -nE "/>[[:space:]]*${release_pattern}[[:space:]]*&gt;/ { s/.*href=\"([^\"]+)\".*/\1/p; q; }" "${archive_html}")"
        
        if [[ -z "${release_href}" ]]; then
            err "${version} 未在官方归档中找到"
            return 1
        fi
        
        ok "找到发布页面: ${release_href}"
        
        # 下载源码包
        mkdir -p "${DOWNLOAD_DIR}/${version}"
        local source_url="https://developer.nvidia.com${release_href#/}"
        echo "开始下载源码包..."
        curl -fL --retry 3 --retry-delay 5 \
            -o "${DOWNLOAD_DIR}/${version}/public_sources.tbz2" \
            "${source_url}" || {
            err "下载失败"
            return 1
        }
    fi
    
    ok "下载完成!"
    
    # 提示提取
    printf '\n%s\n' "源码已下载到: ${DOWNLOAD_DIR}/${version}/public_sources.tbz2"
    echo ""
    echo "接下来可以:"
    echo "  1) 解压源码: tar -xf ${DOWNLOAD_DIR}/${version}/public_sources.tbz2 \\"
    echo "                  -C ${SOURCE_DIR}/${version}/"
    echo "  2) 或者使用本脚本自动提取并初始化"
    printf '\n是否自动解压并初始化? [Y/n]: '
    read -r ans
    if [[ "${ans}" != "n" && "${ans}" != "N" ]]; then
        cmd_init "${version}"
    fi
}

# ========== 命令: 初始化 BSP ==========
cmd_init() {
    local version="${1:-${JETSON_BSP_VERSION}}"
    version="R${version#R}"
    
    title "初始化 BSP: ${version}"
    
    local archive="${DOWNLOAD_DIR}/${version}/public_sources.tbz2"
    if [[ ! -f "${archive}" ]]; then
        err "BSP 压缩包不存在: ${archive}"
        echo "请先下载: ./jetson-bsp-workflow.sh download ${version}"
        return 1
    fi
    
    # 创建源码目录
    mkdir -p "${SOURCE_DIR}/${version}"
    
    # 解压
    echo "解压 BSP 源码..."
    tar -xf "${archive}" -C "${SOURCE_DIR}/${version}/" || {
        err "解压失败"
        return 1
    }
    
    # 查找并解压 kernel_src.tbz2
    local kernel_tar
    kernel_tar=$(find "${SOURCE_DIR}/${version}" -name "kernel_src.tbz2" -o -name "kernel_src.tar*" 2>/dev/null | head -1)
    
    if [[ -n "${kernel_tar}" ]]; then
        ok "找到内核源码: ${kernel_tar}"
        
        # 检查是否已解压
        local ksrc
        ksrc=$(find_kernel_source "${version}")
        if [[ -n "${ksrc}" ]] && [[ -f "${ksrc}/Makefile" ]]; then
            ok "内核源码已解压"
        else
            echo "解压内核源码..."
            local tmp_dir="${SOURCE_DIR}/${version}/_tmp_kernel"
            mkdir -p "${tmp_dir}"
            tar -xf "${kernel_tar}" -C "${tmp_dir}/"
            
            # 移动到正确位置
            if [[ -d "${tmp_dir}/kernel" ]]; then
                mv "${tmp_dir}/kernel" "${SOURCE_DIR}/${version}/kernel-jammy-src"
            elif [[ -d "${tmp_dir}" ]]; then
                local first_dir
                first_dir=$(find "${tmp_dir}" -maxdepth 1 -type d | head -1)
                if [[ -n "${first_dir}" ]] && [[ -f "${first_dir}/Makefile" ]]; then
                    mv "${first_dir}" "${SOURCE_DIR}/${version}/kernel-jammy-src"
                fi
            fi
            rm -rf "${tmp_dir}"
        fi
    fi
    
    local ksrc
    ksrc=$(find_kernel_source "${version}")
    if [[ -n "${ksrc}" ]]; then
        ok "内核源码就绪: ${ksrc}"
        JETSON_BSP_VERSION="${version}"
    else
        warn "未找到内核源码，可能需要手动解压"
    fi
}

# ========== 命令: 查询模块 ==========
cmd_query() {
    local module="${1:-}"
    
    if [[ -z "${module}" ]]; then
        printf '输入模块名: '
        read -r module
    fi
    [[ -z "${module}" ]] && return 1
    
    # 规范化模块名
    module="${module%.ko}"
    module="${module%.o}"
    module="${module#CONFIG_}"
    
    local ksrc
    ksrc=$(get_kernel_source)
    
    title "查询模块: ${module} (${JETSON_BSP_VERSION})"
    
    if [[ ! -d "${ksrc}" ]]; then
        err "内核源码不存在: ${ksrc}"
        echo "请先下载并初始化 BSP: ./jetson-bsp-workflow.sh download ${JETSON_BSP_VERSION}"
        return 1
    fi
    
    # 1. 查找源码
    echo ""
    title "1) 源码文件"
    local matches
    local match_count=0
    
    # 先尝试直接搜索文件（简单驱动）
    matches=$(cd "${ksrc}" && find drivers net fs sound crypto block -type f \( -name "${module}.c" -o -name "${module}.h" \) 2>/dev/null | sort)
    if [[ -n "${matches}" ]]; then
        while IFS= read -r f; do
            [[ -n "${f}" ]] && ok "${f}" && ((match_count++))
        done <<<"${matches}"
    fi
    
    # 再尝试搜索包含该模块名的目录（复杂驱动如 iwlwifi, rtw89）
    if [[ ${match_count} -eq 0 ]]; then
        local dir_matches
        dir_matches=$(cd "${ksrc}" && find drivers net fs sound crypto block -type d -name "${module}" 2>/dev/null | sort)
        if [[ -n "${dir_matches}" ]]; then
            while IFS= read -r d; do
                [[ -n "${d}" ]] && ok "${d}/ (目录)" && ((match_count++))
                # 列出该目录下的 .c 文件
                local sub_files
                sub_files=$(find "${d}" -maxdepth 2 -name "*.c" 2>/dev/null | head -5)
                while IFS= read -r f; do
                    [[ -n "${f}" ]] && ok "  └─ ${f}"
                done <<<"${sub_files}"
            done <<<"${dir_matches}"
        fi
    fi
    
    if [[ ${match_count} -eq 0 ]]; then
        err "未找到 ${module}.c 或 ${module}.h"
    fi
    
    # 2. 查找 CONFIG
    echo ""
    title "2) Kconfig 配置项"
    local config_names=()
    local config_name=""
    
    # 方法1: 直接匹配 obj-${CONFIG} += ${module}.o（简单驱动）
    config_name=$(cd "${ksrc}" && \
        grep -rEh 'obj-\$\(CONFIG_[A-Z0-9_]+\)[[:space:]]*\+=[[:space:]]*'"${module}"'\.o' \
        --include="Makefile" 2>/dev/null | \
        grep -oE 'CONFIG_[A-Z0-9_]+' | head -1)
    [[ -n "${config_name}" ]] && config_names+=("${config_name}")
    
    # 方法2: 匹配 obj-${CONFIG} += ${module}_xxx.o（复杂驱动如 rtw89）
    if [[ -z "${config_name}" ]]; then
        config_name=$(cd "${ksrc}" && \
            grep -rEh 'obj-\$\(CONFIG_[A-Z0-9_]+\)[[:space:]]*\+=[[:space:]]*'"${module}"'_[a-z0-9]*\.o' \
            --include="Makefile" 2>/dev/null | \
            grep -oE 'CONFIG_[A-Z0-9_]+' | head -1)
        [[ -n "${config_name}" ]] && config_names+=("${config_name}")
    fi
    
    # 方法3: 匹配目录下的 Makefile
    if [[ -z "${config_name}" ]]; then
        config_name=$(cd "${ksrc}" && \
            grep -rEh 'obj-\$\(CONFIG_[A-Z0-9_]+\)[[:space:]]*\+=[[:space:]]*\+' \
            "drivers/net/wireless/${module}" --include="Makefile" 2>/dev/null | \
            grep -oE 'CONFIG_[A-Z0-9_]+' | head -1)
        [[ -n "${config_name}" ]] && config_names+=("${config_name}")
    fi
    
    if [[ ${#config_names[@]} -gt 0 ]]; then
        for cn in "${config_names[@]}"; do
            ok "CONFIG 名: ${cn}"
            local kconfig_file
            kconfig_file=$(cd "${ksrc}" && grep -rln "^config ${cn#CONFIG_}\b" --include="Kconfig*" 2>/dev/null | head -1)
            if [[ -n "${kconfig_file}" ]]; then
                ok "Kconfig 位置: ${kconfig_file}"
            fi
        done
    else
        warn "未找到 CONFIG 名"
    fi
    
    # 3. 查看 .config 状态
    echo ""
    title "3) .config 状态"
    local configs
    mapfile -t configs < <(detect_build_configs)
    if [[ ${#configs[@]} -gt 0 ]]; then
        local i=1
        for cfg in "${configs[@]}"; do
            local cfg_path="${BUILD_DIR}/${cfg}/.config"
            if [[ -f "${cfg_path}" ]] && [[ -n "${config_name}" ]]; then
                local line
                line=$(grep -E "^${config_name}=" "${cfg_path}" 2>/dev/null || \
                       grep -E "^# ${config_name} is not set" "${cfg_path}")
                if [[ -n "${line}" ]]; then
                    ok "${cfg}: ${line}"
                fi
            fi
            ((i++))
        done
    else
        warn "没有可用的 Build 配置"
    fi
    
    # 4. 已编译的 .ko
    echo ""
    title "4) 已编译的 .ko"
    local ko_hits
    ko_hits=$(find "${BUILD_DIR}" -name "${module}.ko" -type f 2>/dev/null)
    if [[ -n "${ko_hits}" ]]; then
        while IFS= read -r f; do
            [[ -n "${f}" ]] && ok "${f} ($(du -h "${f}" | cut -f1))"
        done <<<"${ko_hits}"
    else
        warn "未找到已编译的 ${module}.ko"
    fi
    
    echo ""
    printf '%s\n' "下一步操作:"
    printf '%s\n' "  编译: ./jetson-bsp-workflow.sh build ${module}"
    printf '%s\n' "  推送: ./jetson-bsp-workflow.sh push ${module}"
}

# ========== 命令: 编译模块 ==========
cmd_build() {
    local module="${1:-}"
    
    if [[ -z "${module}" ]]; then
        printf '输入模块名: '
        read -r module
    fi
    [[ -z "${module}" ]] && return 1
    
    # CONFIG_FOO 也可作为输入，先从 Makefile 解析实际模块名。
    local requested_config=""
    if [[ "${module}" == CONFIG_* ]]; then
        requested_config="${module}"
    fi

    # 规范化模块名
    module="${module%.ko}"
    module="${module%.o}"
    module="${module#CONFIG_}"
    
    title "编译模块: ${module} (${JETSON_BSP_VERSION})"
    
    # 检查源码
    local ksrc
    ksrc=$(get_kernel_source)
    if [[ ! -d "${ksrc}" ]]; then
        err "内核源码不存在: ${ksrc}"
        echo "请先初始化 BSP"
        printf '是否下载并初始化? [Y/n]: '
        read -r ans
        if [[ "${ans}" != "n" && "${ans}" != "N" ]]; then
            cmd_download "${JETSON_BSP_VERSION}"
            ksrc=$(get_kernel_source)
        fi
        [[ ! -d "${ksrc}" ]] && return 1
    fi

    if [[ -n "${requested_config}" ]]; then
        local config_line
        config_line=$(cd "${ksrc}" && \
            grep -rnE 'obj-\$\('"${requested_config}"'\)[[:space:]]*\+=[[:space:]]*[a-zA-Z0-9_-]+\.o' \
            --include="Makefile" 2>/dev/null | head -1)
        if [[ -z "${config_line}" ]]; then
            err "无法从 ${requested_config} 找到对应模块"
            return 1
        fi
        module=$(echo "${config_line}" | grep -oE '[a-zA-Z0-9_-]+\.o' | head -1)
        module="${module%.o}"
        ok "${requested_config} 对应模块: ${module}.ko"
    fi
    
    # ========== 自动检测并启用 CONFIG ==========
    local config_name=""
    local build_config="${BUILD_DIR}/${JETSON_BSP_VERSION}-default"
    local extra_configs=()  # 复杂驱动可能需要多个 CONFIG

    # 检测 CONFIG 名称（复用 query 模块的逻辑）
    config_name=$(cd "${ksrc}" && \
        grep -rEh 'obj-\$\(CONFIG_[A-Z0-9_]+\)[[:space:]]*\+=[[:space:]]*'"${module}"'\.o' \
        --include="Makefile" 2>/dev/null | \
        grep -oE 'CONFIG_[A-Z0-9_]+' | head -1)

    if [[ -z "${config_name}" ]]; then
        config_name=$(cd "${ksrc}" && \
            grep -rEh 'obj-\$\(CONFIG_[A-Z0-9_]+\)[[:space:]]*\+=[[:space:]]*'"${module}"'_[a-z0-9]*\.o' \
            --include="Makefile" 2>/dev/null | \
            grep -oE 'CONFIG_[A-Z0-9_]+' | head -1)
    fi

    if [[ -z "${config_name}" ]]; then
        config_name=$(cd "${ksrc}" && \
            grep -rEh 'obj-\$\(CONFIG_[A-Z0-9_]+\)[[:space:]]*\+=[[:space:]]*\+' \
            "drivers/net/wireless/${module}" --include="Makefile" 2>/dev/null | \
            grep -oE 'CONFIG_[A-Z0-9_]+' | head -1)
    fi

    # 对于 rtw89 / rtw88 等复杂驱动, 找到 menuconfig 名称
    local menuconfig=""
    if [[ -n "${config_name}" ]]; then
        # CONFIG_RTW89_CORE -> RTW89
        # CONFIG_RTW89_8852AE -> RTW89_8852AE
        # 提取不带 _XXX 的根 CONFIG
        local base_name="${config_name#CONFIG_}"
        # 查找 menuconfig (Kconfig 中的 menuconfig 块)
        menuconfig=$(cd "${ksrc}" && grep -lE "^menuconfig ${base_name%%_*}\b" \
            "drivers/net/wireless/${module}/Kconfig" 2>/dev/null)
        if [[ -n "${menuconfig}" ]]; then
            config_name="CONFIG_${base_name%%_*}"
            # 还需要 enable 对应的子配置 (例如 RTW89_8852AE)
            for cfg in RTW89_8852AE RTW89_8852CE RTW89_8851B; do
                if grep -q "^config ${cfg} " "drivers/net/wireless/${module}/Kconfig" 2>/dev/null; then
                    extra_configs+=("CONFIG_${cfg}")
                fi
            done
        fi
    fi

    if [[ -n "${config_name}" ]]; then
        ok "检测到 CONFIG: ${config_name}"
        if [[ ${#extra_configs[@]} -gt 0 ]]; then
            for ec in "${extra_configs[@]}"; do
                ok "额外依赖: ${ec}"
            done
        fi

        # 检查并创建默认 build 配置
        mkdir -p "${build_config}"

        # 如果没有 .config，从源码复制
        if [[ ! -f "${build_config}/.config" ]] && [[ -f "${ksrc}/.config" ]]; then
            cp "${ksrc}/.config" "${build_config}/.config"
            ok "复制 .config 到构建目录"
        fi

        # 检查并启用 CONFIG
        if [[ -f "${build_config}/.config" ]]; then
            enable_config() {
                local cn="$1"
                if grep -q "^# ${cn} is not set" "${build_config}/.config"; then
                    sed -i "s|^# ${cn} is not set|${cn}=m|" "${build_config}/.config"
                    ok "已启用 ${cn}=m"
                elif grep -q "^${cn}=m" "${build_config}/.config"; then
                    ok "${cn} 已启用 (模块模式)"
                elif grep -q "^${cn}=y" "${build_config}/.config"; then
                    warn "${cn} 已启用 (内置模式)"
                else
                    echo "${cn}=m" >> "${build_config}/.config"
                    ok "已添加 ${cn}=m"
                fi
            }

            enable_config "${config_name}"
            for ec in "${extra_configs[@]}"; do
                enable_config "${ec}"
            done
        fi
    else
        warn "无法自动检测 CONFIG，请手动确认"
    fi

    # 调用原有的编译脚本（传递 CONFIG 名）
    if [[ -x "${SCRIPT_DIR}/build-jetson-module.sh" ]]; then
        local config_suffix=""
        # 对于复杂驱动，使用 module 名作为 config_suffix（让 known_modules 解析）
        if [[ -n "${requested_config}" ]]; then
            config_suffix="${requested_config#CONFIG_}"
        elif [[ "${module}" == "rtw89" || "${module}" == "iwlwifi" ]]; then
            # 留空，交给 build-jetson-module.sh 的已知驱动栈逻辑。
            config_suffix=""
        elif [[ -n "${config_name}" ]]; then
            config_suffix="${config_name#CONFIG_}"
        fi

        JETSON_BSP_VERSION="${JETSON_BSP_VERSION}" \
            JETSON_HOST="" \
            "${SCRIPT_DIR}/build-jetson-module.sh" "${module}" "${config_suffix}"
    else
        err "编译脚本不存在: ${SCRIPT_DIR}/build-jetson-module.sh"
        return 1
    fi
}

# ========== 命令: 推送模块 ==========
cmd_push() {
    local module="${1:-}"
    
    if [[ -z "${module}" ]]; then
        printf '输入模块名 (留空推送全部): '
        read -r module
    fi
    
    title "推送模块到 Jetson: ${module:-全部}"
    
    if [[ -z "${JETSON_HOST}" ]]; then
        err "未设置 JETSON_HOST"
        printf '输入 Jetson SSH 主机 [默认 jetson]: '
        read -r JETSON_HOST
        JETSON_HOST="${JETSON_HOST:-jetson}"
    fi
    
    ok "目标: ${JETSON_HOST}"
    
    # 检查 SSH 连接
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "${JETSON_HOST}" "echo OK" &>/dev/null; then
        err "无法连接到 ${JETSON_HOST}"
        return 1
    fi
    
    # 收集 .ko 文件
    local ko_files
    if [[ -n "${module}" ]]; then
        ko_files=$(find "${BUILD_DIR}" -name "${module}.ko" -type f 2>/dev/null)
    else
        ko_files=$(find "${BUILD_DIR}" -name "*.ko" -type f 2>/dev/null)
    fi
    
    local ko_count
    ko_count=$(echo "${ko_files}" | grep -c . || echo 0)
    
    if [[ "${ko_count}" -eq 0 ]]; then
        err "未找到 .ko 文件，请先编译"
        return 1
    fi
    
    ok "找到 ${ko_count} 个 .ko 文件"
    
    # 打包
    local tarfile="/tmp/jetson_ko_$$.tar.gz"
    tar -czf "${tarfile}" $(echo "${ko_files}" | while IFS= read -r f; do [[ -n "${f}" ]] && echo "-C $(dirname "${f}") $(basename "${f}")"; done) 2>/dev/null || \
    tar -czf "${tarfile}" -C "${BUILD_DIR}" $(find . -name "${module:-*}*.ko" -printf "%P " 2>/dev/null)
    
    ok "打包完成: $(du -h "${tarfile}" | cut -f1)"
    
    # 传输
    echo "传输到 Jetson..."
    ssh -o BatchMode=yes "${JETSON_HOST}" "sudo mkdir -p /lib/modules/\$(uname -r)/extra && cat > ${tarfile}" < "${tarfile}"
    
    # 解压
    echo "解压并安装..."
    ssh -o BatchMode=yes "${JETSON_HOST}" << 'REMOTE'
EXTRA=/lib/modules/$(uname -r)/extra
cd "${EXTRA}"
sudo tar -xzf /tmp/jetson_ko_$$.tar.gz 2>/dev/null || true

# 扁平化目录
for f in $(find . -maxdepth 10 -name "*.ko"); do
    sudo mv -f "$f" "./$(basename "$f")" 2>/dev/null || true
done
sudo find . -maxdepth 1 -type d ! -name "." -exec rmdir {} \; 2>/dev/null || true

# 更新依赖
sudo depmod -a

# 统计
KO_COUNT=$(ls *.ko 2>/dev/null | wc -l)
echo ""
echo "=== 安装完成 ==="
echo "ko 数量: ${KO_COUNT}"
ls -lh *.ko 2>/dev/null | head -20
REMOTE

    # 清理
    rm -f "${tarfile}"
    ssh -o BatchMode=yes "${JETSON_HOST}" "rm -f /tmp/jetson_ko_$$.tar.gz" 2>/dev/null
    
    ok "推送完成!"
    
    if [[ -n "${module}" ]]; then
        printf '\n%s\n' "测试加载:"
        printf '%s\n' "  ssh ${JETSON_HOST} 'sudo modprobe ${module}'"
    fi
}

# ========== 命令: 列出版本 ==========
cmd_list() {
    title "可用的 BSP 版本"
    
    echo "源码版本:"
    local versions
    mapfile -t versions < <(detect_bsp_versions)
    if [[ ${#versions[@]} -gt 0 ]]; then
        for v in "${versions[@]}"; do
            local ksrc
            ksrc=$(find_kernel_source "${v}")
            if [[ -n "${ksrc}" ]] && [[ -f "${ksrc}/Makefile" ]]; then
                ok "${v} (已就绪)"
            else
                warn "${v} (未解压)"
            fi
        done
    else
        warn "没有已下载的 BSP"
    fi
    
    echo ""
    echo "Build 配置:"
    local configs
    mapfile -t configs < <(detect_build_configs)
    if [[ ${#configs[@]} -gt 0 ]]; then
        for c in "${configs[@]}"; do
            ok "${c}"
        done
    else
        warn "没有 Build 配置"
    fi
}

# ========== 命令: 版本信息 ==========
cmd_info() {
    title "BSP 工作流信息"
    
    echo "当前版本: ${JETSON_BSP_VERSION}"
    echo ""
    echo "路径:"
    echo "  工作目录: ${workspace_dir}"
    echo "  源码目录: ${SOURCE_DIR}"
    echo "  Build 目录: ${BUILD_DIR}"
    echo "  下载目录: ${DOWNLOAD_DIR}"
    echo ""
    echo "部署目标: ${JETSON_HOST}"
    
    echo ""
    echo "可用版本:"
    cmd_list
}

# ========== 命令: 交互式菜单 ==========
show_menu() {
    printf '%s\n' "============================================================"
    printf '%s%s%s\n' "${C_BOLD}" "  Jetson BSP 模块开发工作流" "${C_RESET}"
    printf '%s\n' "============================================================"
    echo ""
    echo "当前 BSP 版本: ${JETSON_BSP_VERSION}"
    echo "部署目标: ${JETSON_HOST}"
    echo ""
    printf '%s\n' "请选择操作:"
    printf '%s\n' "  1) 下载 BSP 源码"
    printf '%s\n' "  2) 初始化 BSP"
    printf '%s\n' "  3) 查询模块信息"
    printf '%s\n' "  4) 编译模块"
    printf '%s\n' "  5) 推送模块到 Jetson"
    printf '%s\n' "  6) 列出可用版本"
    printf '%s\n' "  v) 切换 BSP 版本"
    printf '%s\n' "  i) 版本信息"
    printf '%s\n' "  7) 退出"
    printf '%s\n' ""
    printf '选择 [1-7, v, i]: '
}

interactive_mode() {
    while true; do
        show_menu
        read -r choice
        case "${choice}" in
            1)
                printf '输入 BSP 版本 [默认 %s]: ' "${JETSON_BSP_VERSION}"
                read -r ver
                ver="${ver:-${JETSON_BSP_VERSION}}"
                cmd_download "${ver}"
                printf '\n按回车继续...'; read -r
                ;;
            2)
                printf '输入 BSP 版本 [默认 %s]: ' "${JETSON_BSP_VERSION}"
                read -r ver
                ver="${ver:-${JETSON_BSP_VERSION}}"
                cmd_init "${ver}"
                printf '\n按回车继续...'; read -r
                ;;
            3)
                cmd_query
                printf '\n按回车继续...'; read -r
                ;;
            4)
                cmd_build
                printf '\n按回车继续...'; read -r
                ;;
            5)
                cmd_push
                printf '\n按回车继续...'; read -r
                ;;
            6)
                cmd_list
                printf '\n按回车继续...'; read -r
                ;;
            v|V)
                echo ""
                echo "当前版本: ${JETSON_BSP_VERSION}"
                echo "可用版本:"
                local versions
                mapfile -t versions < <(detect_bsp_versions)
                local i=1
                for v in "${versions[@]}"; do
                    echo "  $i) ${v}"
                    ((i++))
                done
                printf '选择版本 [1-%d]: ' "${#versions[@]}"
                read -r idx
                if [[ "${idx}" =~ ^[0-9]+$ ]] && [[ "${idx}" -ge 1 ]] && [[ "${idx}" -le ${#versions[@]} ]]; then
                    JETSON_BSP_VERSION="${versions[$((idx - 1))]}"
                    ok "已切换到: ${JETSON_BSP_VERSION}"
                fi
                printf '\n按回车继续...'; read -r
                ;;
            i|I)
                cmd_info
                printf '\n按回车继续...'; read -r
                ;;
            7|q|Q)
                printf '%s\n' "Bye."
                exit 0
                ;;
            *)
                warn "无效选择"
                ;;
        esac
    done
}

# ========== 入口 ==========
main() {
    if [[ $# -eq 0 ]]; then
        interactive_mode
    else
        case "$1" in
            download|dl|d)
                shift
                cmd_download "$@"
                ;;
            init|i)
                shift
                cmd_init "$@"
                ;;
            query|q|info)
                shift
                cmd_query "$@"
                ;;
            build|b|make)
                shift
                cmd_build "$@"
                ;;
            push|p|deploy)
                shift
                cmd_push "$@"
                ;;
            list|ls)
                cmd_list
                ;;
            info)
                cmd_info
                ;;
            version|ver|v)
                echo "BSP 版本: ${JETSON_BSP_VERSION}"
                ;;
            *)
                # 默认当作模块名查询
                cmd_query "$1"
                ;;
        esac
    fi
}

main "$@"
