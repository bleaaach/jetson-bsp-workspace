#!/usr/bin/env bash
# jetson-module-info.sh
# ---------------------------------------------------------------------------
# 智能查询 Jetson Linux 内核源码中模块的可用性、配置状态、依赖关系。
#
# 用法:
#   ./jetson-module-info.sh                          # 交互式菜单
#   ./jetson-module-info.sh <module_name>            # 直接查询单个模块
#   ./jetson-module-info.sh <module_name> <config>   # 同时检查 .config 状态
#
# 支持的输入形式:
#   - 模块源文件名 (不写后缀):  pl2303, iptable_raw, ftdi_sio
#   - 完整 .ko 文件名:          pl2303.ko
#   - 内核配置项:               CONFIG_USB_SERIAL_PL2303, IP_NF_RAW
#
# 查询内容:
#   1. 源码文件 (.c / .h) 是否存在
#   2. 对应的 Kconfig 配置项及位置
#   3. 对应的 Makefile 编译规则
#   4. 当前 .config 中的状态 (y/m/n/not set)
#   5. 模块依赖 (depends)
#   6. 之前编译好的 .ko 是否还在
# ---------------------------------------------------------------------------

set -u

# ========== 路径定义 ==========
workspace_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
kernel_source="${workspace_dir}/Source/R36.4.4/kernel-jammy-src"
build_root="${workspace_dir}/Build"

# 默认 .config 路径（取最新一次编译的）
default_config="${build_root}/R36.4.4-iptable-raw/.config"

# ========== 版本切换 ==========
# 自动检测可用的 BSP 版本
detect_bsp_versions() {
    local versions=()
    for d in "${workspace_dir}"/Source/R*/; do
        if [[ -d "${d}" ]]; then
            versions+=("$(basename "${d}")")
        fi
    done
    printf '%s\n' "${versions[@]}"
}

# 自动检测可用的 .config
detect_configs() {
    local configs=()
    for d in "${build_root}"/R*/; do
        if [[ -d "${d}" ]] && [[ -f "${d}/.config" ]]; then
            configs+=("$(basename "${d}")")
        fi
    done
    printf '%s\n' "${configs[@]}"
}

# 切换内核源码版本
switch_kernel_version() {
    local versions
    mapfile -t versions < <(detect_bsp_versions)

    if [[ ${#versions[@]} -eq 0 ]]; then
        err "未找到可用的内核源码版本"
        return 1
    fi

    echo
    title "切换内核源码版本"
    echo "当前: ${kernel_source}"
    echo ""
    echo "可用版本:"
    local i=1
    for v in "${versions[@]}"; do
        echo "  $i) ${v}"
        ((i++))
    done
    echo ""
    printf '选择版本 [1-%d] (直接回车取消): ' "${#versions[@]}"
    read -r choice

    if [[ -z "${choice}" ]]; then
        echo "已取消"
        return
    fi

    if [[ "${choice}" =~ ^[0-9]+$ ]] && [[ "${choice}" -ge 1 ]] && [[ "${choice}" -le ${#versions[@]} ]]; then
        local selected="${versions[$((choice - 1))]}"
        kernel_source="${workspace_dir}/Source/${selected}/kernel-jammy-src"
        if [[ -d "${kernel_source}" ]]; then
            ok "已切换到: ${kernel_source}"
        else
            warn "目录不存在，尝试查找其他结构..."
            # 尝试找其他内核目录
            local alt_dir
            alt_dir=$(find "${workspace_dir}/Source/${selected}" -type d -name "*kernel*" | head -1)
            if [[ -n "${alt_dir}" ]]; then
                kernel_source="${alt_dir}"
                ok "已切换到: ${kernel_source}"
            else
                err "未找到内核目录"
            fi
        fi
    else
        err "无效选择"
    fi
}

# 切换 .config 版本
switch_config_version() {
    local configs
    mapfile -t configs < <(detect_configs)

    if [[ ${#configs[@]} -eq 0 ]]; then
        err "未找到可用的 .config"
        return 1
    fi

    echo
    title "切换 .config 版本"
    echo "当前: ${default_config}"
    echo ""
    echo "可用配置:"
    local i=1
    for c in "${configs[@]}"; do
        echo "  $i) ${c}"
        ((i++))
    done
    echo ""
    printf '选择配置 [1-%d] (直接回车取消): ' "${#configs[@]}"
    read -r choice

    if [[ -z "${choice}" ]]; then
        echo "已取消"
        return
    fi

    if [[ "${choice}" =~ ^[0-9]+$ ]] && [[ "${choice}" -ge 1 ]] && [[ "${choice}" -le ${#configs[@]} ]]; then
        local selected="${configs[$((choice - 1))]}"
        default_config="${build_root}/${selected}/.config"
        ok "已切换到: ${default_config}"
    else
        err "无效选择"
    fi
}

# 显示当前版本
show_version_info() {
    echo
    echo "=== 当前版本信息 ==="
    echo "内核源码: ${kernel_source}"
    echo ".config:   ${default_config}"
    echo ""
    echo "可用源码版本:"
    local versions
    mapfile -t versions < <(detect_bsp_versions)
    for v in "${versions[@]}"; do
        echo "  - ${v}"
    done
    echo ""
    echo "可用配置版本:"
    local configs
    mapfile -t configs < <(detect_configs)
    for c in "${configs[@]}"; do
        echo "  - ${c}"
    done
}

# ========== 颜色输出 ==========
if [[ -t 1 ]]; then
    C_RED=$'\e[31m'
    C_GREEN=$'\e[32m'
    C_YELLOW=$'\e[33m'
    C_BLUE=$'\e[34m'
    C_BOLD=$'\e[1m'
    C_RESET=$'\e[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''; C_RESET=''
fi

# ========== 辅助函数 ==========
hr() { printf '%s\n' '------------------------------------------------------------'; }
ok()   { printf '%s✓%s %s\n' "${C_GREEN}" "${C_RESET}" "$1"; }
warn() { printf '%s!%s %s\n' "${C_YELLOW}" "${C_RESET}" "$1"; }
err()  { printf '%s✗%s %s\n' "${C_RED}" "${C_RESET}" "$1"; }
title() { printf '\n%s%s%s\n' "${C_BOLD}${C_BLUE}" "$1" "${C_RESET}"; hr; }

# ========== 输入解析 ==========
# 把用户输入归一化为模块基础名（去掉 .ko, .o, CONFIG_ 前缀等）
# 输入示例:
#   "pl2303"              -> pl2303
#   "pl2303.ko"           -> pl2303
#   "CONFIG_USB_SERIAL_PL2303" -> USB_SERIAL_PL2303
#   "IP_NF_RAW"           -> IP_NF_RAW (CONFIG_ 前缀去掉即可)
normalize_name() {
    local raw="$1"
    # 去掉 .ko / .o 后缀
    raw="${raw%.ko}"
    raw="${raw%.o}"
    # 去掉 CONFIG_ 前缀
    raw="${raw#CONFIG_}"
    printf '%s' "${raw}"
}

# ========== 查询函数 ==========

# 1. 查找源码文件 (返回所有匹配的 .c/.h)
find_source_files() {
    local module="$1"
    title "1) 源码文件"
    # 在 drivers/、net/、fs/、sound/ 等常见目录下找
    local matches
    matches=$(cd "${kernel_source}" && \
        find drivers net fs sound crypto block -type f \( -name "${module}.c" -o -name "${module}.h" \) 2>/dev/null | sort)
    if [[ -n "${matches}" ]]; then
        while IFS= read -r f; do
            ok "${f}"
        done <<<"${matches}"
        return 0
    else
        err "未找到 ${module}.c 或 ${module}.h"
        return 1
    fi
}

# 2. 查找 Kconfig 配置项
#    思路：grep "config XXX$" 找配置项声明，再 grep "tristate XXX" 找 type
find_kconfig() {
    local module="$1"
    title "2) Kconfig 配置项"

    # 自动从 Makefile 反推 CONFIG 名（最准确）
    local config_name
    config_name=$(cd "${kernel_source}" && \
        grep -rEh 'obj-\$\(CONFIG_[A-Z0-9_]+\)[[:space:]]*\+=[[:space:]]*'"${module}"'\.o' \
        --include="Makefile" 2>/dev/null | \
        grep -oE 'CONFIG_[A-Z0-9_]+' | head -1)

    if [[ -z "${config_name}" ]]; then
        # 回退：搜 config 块内 help 文本包含 module 名
        local kconfig_hits
        kconfig_hits=$(cd "${kernel_source}" && \
            grep -rln -- "${module}" --include="Kconfig*" 2>/dev/null | head -10)
        if [[ -n "${kconfig_hits}" ]]; then
            warn "未从 Makefile 自动匹配 CONFIG_xxx，候选 Kconfig 文件:"
            while IFS= read -r f; do
                [[ -n "${f}" ]] && printf '    %s\n' "${f}"
            done <<<"${kconfig_hits}"
            echo
            warn "请手动确认 CONFIG 名称（例如 CONFIG_USB_SERIAL_PL2303）"
            return 1
        else
            err "未在任何 Kconfig 中找到 ${module}"
            return 1
        fi
    fi

    ok "CONFIG 名: ${config_name}"

    # 在 Kconfig 里找这个 config 的定义
    local kconfig_file
    kconfig_file=$(cd "${kernel_source}" && \
        grep -rln "^config ${config_name#CONFIG_}\b" --include="Kconfig*" 2>/dev/null | head -1)
    if [[ -n "${kconfig_file}" ]]; then
        # 去掉 ./ 前缀
        kconfig_file="${kconfig_file#./}"
        ok "Kconfig 位置: ${kconfig_file}"
        # 打印 config 块的前 12 行
        echo
        echo "    ┌── Kconfig 片段 ──"
        cd "${kernel_source}"
        awk -v cfg="${config_name#CONFIG_}" '
            $0 ~ "^config "cfg"[[:space:]]*$" {p=1; print "    │ " $0; next}
            p && /^config / {p=0}
            p {print "    │ " $0}
        ' "${kconfig_file}" | head -12
        echo "    └────────────────────"
    else
        warn "未找到 config ${config_name#CONFIG_} 的 Kconfig 定义"
    fi
}

# 3. 查看 Makefile 中的编译规则
find_makefile_rule() {
    local module="$1"
    title "3) Makefile 编译规则"
    local hits
    hits=$(cd "${kernel_source}" && \
        grep -rnE "obj-\\\$\\(CONFIG_[A-Z0-9_]+\\)[[:space:]]*\+=[[:space:]]*${module}\\.o" \
        --include="Makefile" 2>/dev/null | head -10)
    if [[ -n "${hits}" ]]; then
        while IFS= read -r line; do
            ok "${line}"
        done <<<"${hits}"
    else
        err "未在任何 Makefile 中找到 ${module}.o 的编译规则"
    fi
}

# 4. 查询 .config 中的状态
#    状态类型:
#      CONFIG_X=y       -> 内建
#      CONFIG_X=m       -> 模块
#      CONFIG_X=n       -> 显式禁用
#      # CONFIG_X is not set -> 默认禁用
check_config_status() {
    local module="$1"
    local config_file="${2:-${default_config}}"
    title "4) .config 当前状态 (${config_file})"

    if [[ ! -f "${config_file}" ]]; then
        warn ".config 不存在，跳过（先跑 build 脚本生成）"
        return 1
    fi

    # 自动找到对应的 CONFIG 名
    local config_name
    config_name=$(cd "${kernel_source}" && \
        grep -rEh "obj-\\\$\\(CONFIG_[A-Z0-9_]+\\)[[:space:]]*\+=[[:space:]]*${module}\\.o" \
        --include="Makefile" 2>/dev/null | \
        sed -nE 's/.*obj-\$\((CONFIG_[A-Z0-9_]+)\).*/\1/p' | head -1)

    # 兜底：用户可能直接输入 CONFIG 名
    if [[ -z "${config_name}" ]] && [[ "${module}" == *_* ]]; then
        # 尝试把它当 CONFIG 名的后缀
        config_name="CONFIG_${module}"
    fi

    if [[ -z "${config_name}" ]]; then
        warn "无法自动确定 CONFIG 名，跳过"
        return 1
    fi

    # 在 .config 里查
    local line
    line=$(grep -E "^${config_name}=" "${config_file}" || \
           grep -E "^# ${config_name} is not set" "${config_file}")

    if [[ -z "${line}" ]]; then
        err "${config_name} 在 .config 中未定义（不存在的选项）"
        return 1
    fi

    # 解析状态
    case "${line}" in
        "${config_name}=y")
            ok "${config_name}=y  (内建到内核，编译时会进 vmlinux/Image)"
            ;;
        "${config_name}=m")
            ok "${config_name}=m  (编译为 .ko 模块，可独立加载)"
            ;;
        "${config_name}=n")
            warn "${config_name}=n  (显式禁用，不会编译)"
            ;;
        "# ${config_name} is not set")
            warn "${config_name} is not set  (默认禁用，不会编译)"
            ;;
        *)
            warn "${config_name}=${line#*=}  (其他值)"
            ;;
    esac

    printf '%s\n' "${line}" > /dev/null  # 保留原始行
    echo "    原文: ${line}"
}

# 5. 检查模块依赖 (从源码静态分析 + modinfo 双向确认)
#    输入: 一个 .ko 文件路径或模块名
check_dependencies() {
    local module="$1"
    title "5) 模块依赖"

    # 5a. 静态分析: 找 EXPORT_SYMBOL 里的依赖
    local src
    src=$(cd "${kernel_source}" && \
        find . -name "${module}.c" -type f 2>/dev/null | head -1)
    if [[ -n "${src}" ]]; then
        # 找源文件里的 MODULE_DEPENDS 字符串（有的驱动直接定义了）
        local modinfo_depends
        modinfo_depends=$(grep -oE 'MODULE_INFO\(depends,[[:space:]]*"[^"]+"' "${src}" 2>/dev/null | \
                          sed -nE 's/.*"([^"]+)".*/\1/p')
        if [[ -n "${modinfo_depends}" ]]; then
            ok "源码声明的依赖: ${modinfo_depends}"
        else
            warn "源码未声明 MODULE_INFO(depends)，依赖需运行时由 modinfo 给出"
        fi
        cd "${kernel_source}"
        # 找用到的 EXPORT_SYMBOL 函数
        local used_exports
        used_exports=$(grep -oE '^\s*(?:[a-z][a-z0-9_]*[*\s]+)+[a-zA-Z_][a-zA-Z0-9_]*\s*\(' "${src#./}" 2>/dev/null | \
                       grep -oE '[a-zA-Z_][a-zA-Z0-9_]*\s*\(' | \
                       tr -d ' (' | \
                       sort -u | head -30)
        if [[ -n "${used_exports}" ]]; then
            echo "    候选外部符号 (需 modinfo 二次确认):"
            echo "${used_exports}" | sed 's/^/      /'
        fi
    fi

    # 5b. 如果有现成的 .ko，跑 modinfo 看 depends 字段
    local ko_path
    ko_path=$(find "${build_root}" -name "${module}.ko" -type f 2>/dev/null | head -1)
    if [[ -n "${ko_path}" ]]; then
        echo
        ok "已编译 .ko: ${ko_path}"
        local depends
        depends=$(modinfo -F depends "${ko_path}" 2>/dev/null)
        if [[ -n "${depends}" ]]; then
            ok "运行时依赖: ${depends}"
        else
            warn "modinfo 未返回依赖 (可能模块尚未加载或被剥离)"
        fi
    else
        warn "尚未编译 ${module}.ko，无法验证运行时依赖"
    fi
}

# 6. 查找已编译的 .ko 文件
find_compiled_ko() {
    local module="$1"
    title "6) 已编译的 .ko 文件"

    local hits
    hits=$(find "${build_root}" -name "${module}.ko" -type f 2>/dev/null | sort)
    if [[ -n "${hits}" ]]; then
        while IFS= read -r f; do
            local size
            size=$(du -h "${f}" 2>/dev/null | cut -f1)
            ok "${f}  (${size})"
            local vermagic
            vermagic=$(modinfo -F vermagic "${f}" 2>/dev/null)
            [[ -n "${vermagic}" ]] && echo "      vermagic: ${vermagic}"
        done <<<"${hits}"
    else
        warn "未找到已编译的 ${module}.ko"
    fi
}

# ========== 主流程 ==========
run_query() {
    local module="$1"
    local config_file="${2:-}"

    printf '%s%s%s\n' "${C_BOLD}" "========== Jetson 模块查询: ${module} ==========" "${C_RESET}"
    printf '源码根: %s\n' "${kernel_source}"
    [[ -n "${config_file}" ]] && printf '.config: %s\n' "${config_file}" || \
        printf '.config: %s (默认)\n' "${default_config}"

    if [[ ! -d "${kernel_source}" ]]; then
        err "内核源码不存在: ${kernel_source}"
        exit 1
    fi

    find_source_files         "${module}"
    find_kconfig              "${module}"
    find_makefile_rule        "${module}"
    check_config_status       "${module}" "${config_file}"
    check_dependencies        "${module}"
    find_compiled_ko          "${module}"

    title "结论"
    printf '%s\n' "根据以上信息决定下一步:"
    printf '%s\n' "  - 源码有 + .config=m  -> 可直接 make <module>.ko"
    printf '%s\n' "  - 源码有 + .config=n  -> 需先 set CONFIG=...=m 再编译"
    printf '%s\n' "  - 源码无             -> 该模块不在 $(basename "${kernel_source}") 内核树中"
}

# ========== 菜单模式 ==========
show_menu() {
    printf '%s\n' "============================================================"
    printf '%s%s%s\n' "${C_BOLD}" "  Jetson Linux 内核模块智能查询工具" "${C_RESET}"
    printf '%s\n' "============================================================"
    echo ""
    echo "当前版本:"
    echo "  内核源码: ${kernel_source}"
    echo "  .config:   $(basename "${default_config}")"
    echo ""
    printf '%s\n' "请选择操作:"
    printf '%s\n' "  1) 查询单个模块"
    printf '%s\n' "  2) 查询 USB 串口模块 (pl2303, ftdi_sio, ch341, cp210x, option)"
    printf '%s\n' "  3) 查询网络/移动模块 (qmi_wwan, cdc_ether, rndis_host, usbnet)"
    printf '%s\n' "  4) 查询 USB 网卡模块 (r8152, asix, smsc95xx, lan78xx)"
    printf '%s\n' "  5) 查询 iptables 防火墙模块"
    printf '%s\n' "  6) 列出所有可编译模块 (obj-m)"
    printf '%s\n' "  v) 切换内核源码版本"
    printf '%s\n' "  c) 切换 .config 版本"
    printf '%s\n' "  i) 版本信息"
    printf '%s\n' "  7) 推送 .ko 文件到 Jetson"
    printf '%s\n' "  8) 列出 Jetson 已安装的模块"
    printf '%s\n' "  9) 测试 SSH 连接"
    printf '%s\n' " 10) 退出"
    printf '%s\n' ""
    printf '选择 [1-10, v, c, i]: '
}

list_all_modules() {
    title "$(basename "${kernel_source}") 中所有可编译的模块 (来自 Makefile 的 obj-m)"
    local total
    total=$(cd "${kernel_source}" && \
        grep -rhE "^obj-m[[:space:]]*\+=" --include="Makefile" 2>/dev/null | \
        sed -nE 's/.*[[:space:]]\+=[[:space:]]*([a-zA-Z0-9_-]+)\.o.*/\1/p' | \
        sort -u | wc -l)
    ok "总计: ${total} 个 obj-m 模块"
    echo
    cd "${kernel_source}"
    grep -rhE "^obj-m[[:space:]]*\+=" --include="Makefile" 2>/dev/null | \
        sed -nE 's/.*[[:space:]]\+=[[:space:]]*([a-zA-Z0-9_-]+)\.o.*/\1/p' | \
        sort -u | head -100
    if [[ ${total} -gt 100 ]]; then
        printf '%s\n' "... 仅显示前 100 个，请用 ./jetson-module-info.sh <module> 查询特定模块"
    fi
}

interactive_mode() {
    while true; do
        show_menu
        read -r choice
        case "${choice}" in
            1)
                printf '输入模块名 (例: pl2303, iptable_raw, CONFIG_USB_SERIAL_PL2303): '
                read -r raw
                [[ -z "${raw}" ]] && continue
                local module
                module=$(normalize_name "${raw}")
                run_query "${module}" ""
                printf '\n按回车继续...'; read -r
                ;;
            2)
                title "=== USB 串口模块 ==="
                local usb_serial=(pl2303 ftdi_sio ch341 cp210x option usbserial)
                for m in "${usb_serial[@]}"; do
                    run_query "${m}" ""
                    hr
                done
                printf '\n按回车继续...'; read -r
                ;;
            3)
                title "=== 网络/移动模块 ==="
                local network=(qmi_wwan cdc_ether rndis_host usbnet cdc_ncm)
                for m in "${network[@]}"; do
                    run_query "${m}" ""
                    hr
                done
                printf '\n按回车继续...'; read -r
                ;;
            4)
                title "=== USB 网卡模块 ==="
                local usb_net=(r8152 asix smsc95xx lan78xx ax88179_178a rtl8150)
                for m in "${usb_net[@]}"; do
                    run_query "${m}" ""
                    hr
                done
                printf '\n按回车继续...'; read -r
                ;;
            5)
                title "=== iptables 防火墙模块 ==="
                local iptables=(iptable_raw iptable_filter iptable_nat iptable_mangle ip_tables x_tables nf_reject_ipv4)
                for m in "${iptables[@]}"; do
                    run_query "${m}" ""
                    hr
                done
                printf '\n按回车继续...'; read -r
                ;;
            6)
                list_all_modules
                printf '\n按回车继续...'; read -r
                ;;
            v|V)
                switch_kernel_version
                printf '\n按回车继续...'; read -r
                ;;
            c|C)
                switch_config_version
                printf '\n按回车继续...'; read -r
                ;;
            i|I)
                show_version_info
                printf '\n按回车继续...'; read -r
                ;;
            7)
                push_ko_files "${build_root}"
                printf '\n按回车继续...'; read -r
                ;;
            8)
                list_jetson_modules
                printf '\n按回车继续...'; read -r
                ;;
            9)
                check_ssh_connection
                printf '\n按回车继续...'; read -r
                ;;
            10|q|Q)
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
            i|I)
                show_version_info
                ;;
            v|V)
                switch_kernel_version
                ;;
            c|C)
                switch_config_version
                ;;
            *)
                local module
                module=$(normalize_name "$1")
                local config="${2:-}"
                run_query "${module}" "${config}"
                ;;
        esac
    fi
}

main "$@"
