#!/usr/bin/env bash
# build-jetson-module.sh
# ---------------------------------------------------------------------------
# 在 x86_64 PC 上交叉编译任意 Jetson Linux (5.15-tegra) 内核模块，并可选地
# 推送到 Jetson 上做加载验证。
#
# 用法:
#   ./build-jetson-module.sh <module_name> [config_name] [extra_deps]
#
# 模块名 (MODULE_NAME):
#   已知会从 Makefile 自动反推 CONFIG, 这些都开箱即用:
#     - qmi_wwan   -> CONFIG_USB_NET_QMI_WWAN
#     - pl2303     -> CONFIG_USB_SERIAL_PL2303
#     - iptable_raw-> CONFIG_IP_NF_RAW  (defconfig 默认已 m, 脚本会校验)
#     - ftdi_sio   -> CONFIG_USB_SERIAL_FTDI_SIO
#     - cdc_wdm    -> CONFIG_USB_WDM
#   任何其他: 用第 2 个参数显式给 CONFIG_XXX
#
# 环境变量:
#   JETSON_BSP_VERSION   如 R36.4.3 / R36.4.4 (默认 R36.4.4)
#   JETSON_HOST          如 seeed@192.168.1.10 -> 启用自动 scp + modprobe 验证
#   JETSON_KDIR          推送到 Jetson 的模块目录 (默认 /lib/modules/$(uname -r))
#   JETSON_SKIP_DEPMOD   设为 1 跳远端 depmod
#
# 示例:
#   ./build-jetson-module.sh qmi_wwan                                       # 仅编译
#   JETSON_HOST=seeed@10.0.0.5 ./build-jetson-module.sh qmi_wwan            # 编译 + 部署
#   JETSON_BSP_VERSION=R36.4.3 ./build-jetson-module.sh pl2303               # 切版本
#   ./build-jetson-module.sh my_driver MY_DRIVER                            # 任意模块
# ---------------------------------------------------------------------------

set -u
trap '' PIPE

# ========== 默认参数 ==========
MODULE_NAME="${1:-}"
CONFIG_NAME_ARG="${2:-}"        # 例如 IP_NF_RAW (不带 CONFIG_ 前缀)
EXTRA_DEPS="${3:-}"             # 空格分隔的 .ko 路径

# ========== 版本选择 ==========
JETSON_BSP_VERSION="${JETSON_BSP_VERSION:-R36.4.4}"
# 去掉可能的 R 前缀
JETSON_BSP_VERSION="R${JETSON_BSP_VERSION#R}"
# 校验格式
if [[ ! "${JETSON_BSP_VERSION}" =~ ^R[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "JETSON_BSP_VERSION 格式错误: ${JETSON_BSP_VERSION} (需要 R36.4.4 形式)" >&2
    exit 2
fi

# ========== 部署目标 ==========
JETSON_HOST="${JETSON_HOST:-}"
JETSON_KDIR="${JETSON_KDIR:-}"   # 留空 -> 在 Jetson 上 uname -r 决定
JETSON_SKIP_DEPMOD="${JETSON_SKIP_DEPMOD:-}"
JETSON_CONFIG_SEED="${JETSON_CONFIG_SEED:-}"   # 可选: 复用指定 .config 作种子

# ========== 路径 ==========
workspace_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 探测源码路径 (兼容多种布局):
#   Source/R36.4.4/kernel-jammy-src        (通用 build-jetson-module.sh 产出)
#   Source/R36.4.4/kernel/kernel-jammy-src (模块独立包)
#   Downloads/R36.4.4/Linux_for_Tegra/source/kernel/kernel-jammy-src (NVIDIA 官方源码)
find_kernel_source() {
    local ver="$1"
    local candidates=(
        "${workspace_dir}/Source/${ver}/kernel-jammy-src"
        "${workspace_dir}/Source/${ver}/kernel/kernel-jammy-src"
        "${workspace_dir}/Source/${ver}-${MODULE_NAME}/kernel/kernel-jammy-src"
        "${workspace_dir}/Downloads/${ver}/Linux_for_Tegra/source/kernel/kernel-jammy-src"
        "${workspace_dir}/Downloads/${ver}/Linux_for_Tegra/source/kernel"
    )
    for c in "${candidates[@]}"; do
        if [[ -f "${c}/Makefile" ]]; then
            echo "${c}"
            return 0
        fi
    done
    return 1
}

kernel_source="$(find_kernel_source "${JETSON_BSP_VERSION}")" || {
    echo "✗ 未找到 ${JETSON_BSP_VERSION} 源码" >&2
    echo "  尝试过的路径:" >&2
    echo "    Source/${JETSON_BSP_VERSION}/kernel-jammy-src" >&2
    echo "    Source/${JETSON_BSP_VERSION}/kernel/kernel-jammy-src" >&2
    echo "    Source/${JETSON_BSP_VERSION}-${MODULE_NAME}/kernel/kernel-jammy-src" >&2
    echo "" >&2
    echo "  请先下载: ./download-jetson-bsp-sources.sh ${JETSON_BSP_VERSION}" >&2
    echo "  然后提取: tar -xf Downloads/${JETSON_BSP_VERSION}/public_sources.tbz2 \\" >&2
    echo "              kernel_src.tbz2 -C Source/${JETSON_BSP_VERSION}/ && \\" >&2
    echo "              tar -xf Source/${JETSON_BSP_VERSION}/kernel_src.tbz2 -C Source/${JETSON_BSP_VERSION}/" >&2
    exit 1
}

build_root="${workspace_dir}/Build"
cross_compile="${workspace_dir}/toolchain/aarch64--glibc--stable-2022.08-1/bin/aarch64-buildroot-linux-gnu-"
host_tools="${workspace_dir}/tools/host/bin"

# ========== 颜色 ==========
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
section() { printf '\n%s%s%s\n' "${C_BOLD}${C_BLUE}" "$1" "${C_RESET}"; hr; }

# ========== 辅助：从 Makefile 找 CONFIG 名 ==========
find_config_name() {
    local module="$1"
    (cd "${kernel_source}" && \
        grep -rEh 'obj-\$\(CONFIG_[A-Z0-9_]+\)[[:space:]]*\+=[[:space:]]*'"${module}"'\.o' \
        --include="Makefile" 2>/dev/null | \
        grep -oE 'CONFIG_[A-Z0-9_]+' | head -1)
}

# ========== 辅助：从 Kconfig 找依赖模块 ==========
# Kconfig 语法:
#   config FOO
#       depends on BAR        <- BAR 必须也 =m
#       select BAZ            <- BAZ 自动 =m (但要看 BAR 是否 m)
find_kconfig_depends() {
    local config_no_prefix="$1"
    local kconfig_file
    kconfig_file=$(cd "${kernel_source}" && \
        grep -rlnE "^(menu)?config ${config_no_prefix}\b" --include="Kconfig*" 2>/dev/null | head -1)
    if [[ -z "${kconfig_file}" ]]; then
        return 0
    fi
    (cd "${kernel_source}" && awk -v cfg="${config_no_prefix}" '
        $0 ~ "^(menu)?config "cfg"[[:space:]]*$" {p=1; next}
        p && /^(menu)?config / {p=0}
        p {
            if (match($0, /[[:space:]]*(depends on|select)[[:space:]]+/)) {
                line = substr($0, RSTART + RLENGTH)
                n = split(line, parts, /[ ()\|&#?!]+/)
                for (i = 1; i <= n; i++) {
                    if (parts[i] ~ /^CONFIG_/) {
                        print parts[i]
                    } else if (parts[i] ~ /^[A-Z][A-Z0-9_]+$/) {
                        print "CONFIG_" parts[i]
                    }
                }
            }
        }
    ' "${kconfig_file}")
}

# ========== 辅助：Kconfig 符号类型 (tristate/bool) ==========
kconfig_type() {
    local cfg="$1"
    local kf
    kf=$(cd "${kernel_source}" && grep -rlnE "^(menu)?config ${cfg}\b" --include="Kconfig*" 2>/dev/null | head -1)
    [[ -z "${kf}" ]] && { echo "tristate"; return; }
    local t
    t=$(cd "${kernel_source}" && awk -v c="${cfg}" '
        $0 ~ "^(menu)?config " c "[[:space:]]*$" {p=1; next}
        p && /^(menu)?config / {exit}
        p && /^[[:space:]]*(tristate|bool)\b/ {print $1; exit}
    ' "${kf}")
    [[ -z "${t}" ]] && echo "tristate" || echo "${t}"
}

# ========== 辅助：找包裹 config 的最近外层 menuconfig ==========
find_parent_menuconfig() {
    local cfg="$1"
    local kf
    kf=$(cd "${kernel_source}" && grep -rlnE "^(menu)?config ${cfg}\b" --include="Kconfig*" 2>/dev/null | head -1)
    [[ -z "${kf}" ]] && return 1
    local cfg_line indent
    cfg_line=$(cd "${kernel_source}" && grep -nE "^(menu)?config ${cfg}\b" "${kf}" | head -1 | cut -d: -f1)
    indent=$(cd "${kernel_source}" && sed -n "${cfg_line}p" "${kf}" | awk '{print index($0,$1)-1}')
    local ln depth=0
    for (( ln = cfg_line - 1; ln >= 1; ln-- )); do
        local l
        l=$(cd "${kernel_source}" && sed -n "${ln}p" "${kf}")
        [[ -z "${l//[[:space:]]/}" ]] && continue
        # 外层 menuconfig (缩进式嵌套)
        if [[ "${l}" =~ ^([[:space:]]*)menuconfig[[:space:]]+([A-Z0-9_]+) ]]; then
            local l_indent=${#BASH_REMATCH[1]}
            if (( l_indent < indent )) && (( depth == 0 )); then
                echo "${BASH_REMATCH[2]}"
                return 0
            fi
            continue
        fi
        # if / endif 条件块 (顶格 config 常见, 如: if USB_SERIAL ... endif)
        if [[ "${l}" =~ ^[[:space:]]*endif[[:space:]]*([#].*)?$ ]]; then
            ((depth++))
            continue
        fi
        if [[ "${l}" =~ ^[[:space:]]*if[[:space:]]+([A-Za-z0-9_]+)[[:space:]]*([#].*)?$ ]]; then
            if (( depth == 0 )); then
                echo "${BASH_REMATCH[1]}"
                return 0
            fi
            ((depth--))
            continue
        fi
    done
    return 1
}

# ========== 辅助：启用 config 及其父 menuconfig 链 + depends 链 ==========
# tristate → =m (模块), bool → =y; 避免把依赖编进 vmlinux 造成重复导出
enable_cfg_tree() {
    local start_cfg="${1#CONFIG_}"
    local -a queue=("${start_cfg}")
    declare -A seen_cfg=()
    local scan_i=0
    while (( scan_i < ${#queue[@]} )); do
        local cur="${queue[${scan_i}]}"
        ((scan_i++))
        [[ -n "${seen_cfg[${cur}]:-}" ]] && continue
        seen_cfg["${cur}"]=1

        local cur_state
        cur_state=$(grep -E "^CONFIG_${cur}=|^# CONFIG_${cur} is not set" "${build_dir}/.config" | head -1)
        case "${cur_state}" in
            CONFIG_${cur}=y|CONFIG_${cur}=m) ;;
            *)
                if [[ "$(kconfig_type "${cur}")" == "bool" ]]; then
                    "${kernel_source}/scripts/config" --file "${build_dir}/.config" --enable "${cur}"
                    ok "启用依赖: CONFIG_${cur}=y (bool)"
                else
                    "${kernel_source}/scripts/config" --file "${build_dir}/.config" --module "${cur}"
                    ok "启用依赖: CONFIG_${cur}=m"
                fi
                ;;
        esac

        local parent
        if parent=$(find_parent_menuconfig "${cur}") && [[ -z "${seen_cfg[${parent}]:-}" ]]; then
            queue+=("${parent}")
        fi
        while IFS= read -r dep; do
            [[ -z "${dep}" ]] && continue
            dep="${dep#CONFIG_}"
            [[ -z "${seen_cfg[${dep}]:-}" ]] && queue+=("${dep}")
        done < <(find_kconfig_depends "${cur}")
    done
}

# ========== 辅助：CONFIG 名 → 对应 .ko 路径 ==========
config_to_module_path() {
    local config="$1"
    local line
    # 优先匹配 obj-$(CONFIG_X) += name.o
    line=$(cd "${kernel_source}" && \
        grep -rnE 'obj-\$\('"${config}"'\)[[:space:]]*\+=[[:space:]]*[a-zA-Z0-9_-]+\.o' \
        --include="Makefile" 2>/dev/null | head -1)
    if [[ -z "${line}" ]]; then
        # menuconfig 模式: 找所有以 CONFIG_<NAME>_ 开头的子模块
        # 例如 CONFIG_RTW89 -> 找 CONFIG_RTW89_CORE, CONFIG_RTW89_PCI 等
        local cfg_name="${config#CONFIG_}"
        local chip_line
        chip_line=$(cd "${kernel_source}" && \
            grep -rnE 'obj-\$\(CONFIG_'"${cfg_name}"'_[A-Z]+' \
            --include="Makefile" 2>/dev/null | grep -v "_DEBUG\|_m " | head -1)
        if [[ -n "${chip_line}" ]]; then
            line="${chip_line}"
        fi
    fi
    if [[ -z "${line}" ]]; then
        return 0
    fi
    local makefile_path="${line%%:*}"
    local module_o
    module_o=$(echo "${line}" | grep -oE '[a-zA-Z0-9_-]+\.o' | head -1)
    local module_dir
    module_dir=$(dirname "${makefile_path}")
    echo "${module_dir}/${module_o%.o}.ko"
}

# ========== SSH 远程执行 ==========
ssh_run() {
    # 用法: ssh_run "command"
    if [[ -z "${JETSON_HOST}" ]]; then
        return 99   # 标记不可用
    fi
    if ! command -v sshpass >/dev/null 2>&1; then
        warn "sshpass 未安装, 无法自动登录 (apt-get install sshpass)"
        return 2
    fi
    local sshpass_args=()
    if [[ -n "${SSHPASS:-}" ]]; then
        sshpass_args=(-o)
    fi
    sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "${JETSON_HOST}" "$1" 2>&1
}

scp_send() {
    # 用法: scp_send <local_file> <remote_path>
    if [[ -z "${JETSON_HOST}" ]]; then
        return 99
    fi
    if ! command -v sshpass >/dev/null 2>&1; then
        return 2
    fi
    sshpass -e scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$1" "${JETSON_HOST}:$2" 2>&1
}

deploy_to_jetson() {
    # 用法: deploy_to_jetson <相对 .ko 路径数组...>  (相对于 build_dir)
    local rel_kos=("$@")

    # 拼绝对路径用于推送
    local abs_kos=()
    for r in "${rel_kos[@]}"; do
        abs_kos+=("${build_dir}/${r}")
    done

    if [[ -z "${JETSON_HOST}" ]]; then
        # 模式 A: 仅打印手动步骤
        print_manual_steps "${rel_kos[@]}"
        return 0
    fi

    section "部署到 Jetson: ${JETSON_HOST}"

    # 检查 sshpass
    if ! command -v sshpass >/dev/null 2>&1; then
        err "sshpass 未安装, 无法自动部署"
        echo "  手动操作步骤如下:" >&2
        print_manual_steps "${rel_kos[@]}"
        return 1
    fi

    # 探测 Jetson 上内核版本对应的 modules 目录
    local kdir
    if [[ -n "${JETSON_KDIR}" ]]; then
        kdir="${JETSON_KDIR}"
    else
        kdir=$(ssh_run "uname -r" | tr -d '\r')
        if [[ -z "${kdir}" ]]; then
            err "无法 SSH 到 ${JETSON_HOST}, 检查网络/凭证 (SSHPASS=...)"
            print_manual_steps "${rel_kos[@]}"
            return 1
        fi
        kdir="/lib/modules/${kdir}"
    fi
    ok "Jetson modules 目录: ${kdir}"

    # 拷贝每个 .ko (用相对路径决定 Jetson 上的子目录)
    for i in "${!abs_kos[@]}"; do
        local ko="${abs_kos[$i]}"
        local rel="${rel_kos[$i]}"
        local remote_dir="${kdir}/$(dirname "${rel}")"
        local tmp_remote="/tmp/$(basename "${rel}")"

        printf '  scp %s -> %s:%s\n' "${ko}" "${JETSON_HOST}" "${tmp_remote}"
        if ! scp_send "${ko}" "${tmp_remote}"; then
            err "scp ${ko} 失败"
            print_manual_steps "${rel_kos[@]}"
            return 1
        fi
        ok "已传: ${rel}"

        # 安装 (需要 sudo)
        printf '  install -D -m 644 %s %s\n' "${tmp_remote}" "${remote_dir}/$(basename "${rel}")"
        if ! ssh_run "sudo install -D -m 644 '${tmp_remote}' '${remote_dir}/$(basename "${rel}")'"; then
            err "安装 ${rel} 到 ${remote_dir} 失败 (需要 sudo 免密?)"
            print_manual_steps "${rel_kos[@]}"
            return 1
        fi
        ok "已安装: ${remote_dir}/$(basename "${rel}")"
    done

    # depmod
    if [[ -z "${JETSON_SKIP_DEPMOD}" ]]; then
        if ssh_run "sudo depmod -a" >/dev/null; then
            ok "depmod -a 完成"
        else
            warn "depmod -a 失败 (继续尝试 modprobe)"
        fi
    fi

    # 加载测试
    section "加载测试: ${MODULE_NAME}"
    if ssh_run "sudo modprobe -v ${MODULE_NAME} 2>&1"; then
        ok "modprobe ${MODULE_NAME} 成功"
    else
        err "modprobe 失败, dmesg:"
        ssh_run "sudo dmesg -T | tail -30" | sed 's/^/    /'
        return 1
    fi

    # 验证 lsmod
    if ssh_run "lsmod | grep -E '^${MODULE_NAME}\\b'"; then
        ok "${MODULE_NAME} 已加载"
    else
        warn "lsmod 未显示 ${MODULE_NAME} (可能是 build-in 或被自动卸载)"
    fi

    # 模块信息
    section "${MODULE_NAME} 远端 modinfo"
    ssh_run "modinfo ${MODULE_NAME} | head -20" | sed 's/^/    /'

    return 0
}

print_manual_steps() {
    local rel_kos=("$@")
    section "手动部署到 Jetson (未设 JETSON_HOST)"
    cat <<EOF
将以下 .ko 拷贝到 Jetson, 然后安装并加载:

EOF
    for r in "${rel_kos[@]}"; do
        cat <<EOF
  scp ${build_dir}/${r} \${USER}@<JETSON_IP>:/tmp/
  ssh \${USER}@<JETSON_IP> -- sudo install -D -m 644 \\
      /tmp/$(basename "${r}") \\
      /lib/modules/\$(uname -r)/${r}
EOF
    done

    cat <<EOF

# 在 Jetson 上:
ssh \${USER}@<JETSON_IP>

sudo depmod -a
sudo modprobe -v ${MODULE_NAME}

# 校验
lsmod | grep '^${MODULE_NAME}\\b'
modinfo ${MODULE_NAME} | head -5
sudo iptables -t raw -L -n -v 2>/dev/null   # 仅 iptable_raw
dmesg -T | tail -20

# 失败排查
sudo dmesg -T | tail -50

# 卸载
sudo modprobe -r ${MODULE_NAME}

# 自动模式 (一气呵成):
#   export JETSON_HOST=\${USER}@<JETSON_IP>     # 或在命令行 inline
#   export SSHPASS=<你的 sudo 密码>
#   ./build-jetson-module.sh ${MODULE_NAME}
EOF
}

# ========== 已知模块名 → 友好别名 / 默认 CONFIG / 默认 deps ==========
# 让常见模块直接 ./build.sh <name> 就能跑
known_modules() {
    case "$1" in
        qmi_wwan)
            echo "qmi_wwan|CONFIG_USB_NET_QMI_WWAN||"
            ;;
        pl2303)
            echo "pl2303|CONFIG_USB_SERIAL_PL2303||drivers/usb/serial/usbserial.ko"
            ;;
        ftdi_sio)
            echo "ftdi_sio|CONFIG_USB_SERIAL_FTDI_SIO||drivers/usb/serial/usbserial.ko"
            ;;
        cdc_wdm)
            echo "cdc_wdm|CONFIG_USB_WDM||"
            ;;
        iptable_raw)
            echo "iptable_raw|CONFIG_IP_NF_RAW||net/ipv4/netfilter/ip_tables.ko net/netfilter/x_tables.ko"
            ;;
        ip_tables)
            echo "ip_tables|CONFIG_IP_TABLES||"
            ;;
        # Wi-Fi drivers - 用 menuconfig (RTW89, IWLWIFI) 启用
        iwlwifi)
            echo "iwlwifi|CONFIG_IWLWIFI||"
            ;;
        iwlmvm)
            # IWLMVM 需要父级 IWLWIFI 启用
            echo "iwlmvm|CONFIG_IWLMVM|CONFIG_IWLWIFI|"
            ;;
        iwldvm)
            echo "iwldvm|CONFIG_IWLDVM|CONFIG_IWLWIFI|"
            ;;
        rtw89)
            echo "rtw89|CONFIG_RTW89||"
            ;;
        rtw89_core)
            echo "rtw89_core|CONFIG_RTW89_CORE|CONFIG_RTW89|"
            ;;
        rtw89_pci)
            echo "rtw89_pci|CONFIG_RTW89_PCI|CONFIG_RTW89|"
            ;;
        rtw89_8852be)
            echo "rtw89_8852be|CONFIG_RTW89_8852BE|CONFIG_RTW89|"
            ;;
        rtw89_8852ce)
            echo "rtw89_8852ce|CONFIG_RTW89_8852CE|CONFIG_RTW89|"
            ;;
        *)
            return 1
            ;;
    esac
}

# ========== 主流程 ==========
main() {
    if [[ -z "${MODULE_NAME}" ]]; then
        cat <<EOF
用法:
  $0 <module_name> [config_name] [extra_deps_空间分隔]

模块 (开箱即用):
  qmi_wwan, pl2303, ftdi_sio, cdc_wdm, iptable_raw, ip_tables

环境变量:
  JETSON_BSP_VERSION  例 R36.4.3 (默认 R36.4.4)
  JETSON_HOST         例 seeed@192.168.1.10 (自动 SCP+modprobe)
  JETSON_KDIR         默认 /lib/modules/\$(uname -r)
  SSHPASS             Jetson sudo 密码 (用于自动模式)

示例:
  $0 qmi_wwan
  JETSON_BSP_VERSION=R36.4.3 $0 pl2303
  JETSON_HOST=seeed@10.0.0.5 SSHPASS=nv $0 qmi_wwan
EOF
        exit 0
    fi

    section "Jetson 模块交叉编译: ${MODULE_NAME}"
    printf '  BSP 版本:    %s\n' "${JETSON_BSP_VERSION}"
    printf '  源码路径:    %s\n' "${kernel_source}"
    printf '  交叉编译器:  %s\n' "${cross_compile}"
    [[ -n "${JETSON_HOST}" ]] && printf '  部署目标:    %s\n' "${JETSON_HOST}"

    # 1. 前置检查
    [[ -f "${kernel_source}/Makefile" ]] || { err "内核源码缺失"; exit 1; }
    [[ -x "${cross_compile}gcc" ]] || { err "交叉编译器缺失"; exit 1; }
    [[ -x "${host_tools}/flex" ]] || { err "host flex 缺失"; exit 1; }
    [[ -x "${host_tools}/bison" ]] || { err "host bison 缺失"; exit 1; }

    # 1a. 清理源码树脏状态 (kernel Makefile 强制要求)
    warn "执行 make mrproper 清理源码树 (kernel 标准要求)"
    pushd "${kernel_source}" >/dev/null
    make mrproper >/dev/null 2>&1 || true
    popd >/dev/null

    # 2. 确定 CONFIG 名 (优先级: 命令行 > 已知别名 > 自动反推)
    if [[ -n "${CONFIG_NAME_ARG}" ]]; then
        # 转大写以匹配 CONFIG_<UPPER>
        local _cfg_upper
        _cfg_upper=$(echo "${CONFIG_NAME_ARG}" | tr '[:lower:]' '[:upper:]')
        CONFIG_NAME="CONFIG_${_cfg_upper#CONFIG_}"
    else
        # 试试已知别名
        local alias
        if alias=$(known_modules "${MODULE_NAME}"); then
            local _mod _alias_cfg _alias_parent _alias_deps
            # 格式: module|CONFIG|PARENT|DEPS (4字段)
            IFS='|' read -r _mod _alias_cfg _alias_parent _alias_deps <<<"${alias}"
            CONFIG_NAME="${_alias_cfg}"
            # 如果有父级依赖, 先启用父级 (父级不加入 EXTRA_DEPS)
            if [[ -n "${_alias_parent}" && "${_alias_parent}" != "${CONFIG_NAME}" ]]; then
                echo "${_alias_parent}" > "${build_root}/.${MODULE_NAME}.parent"
                ok "检测到父级依赖: ${_alias_parent} (将在配置阶段启用)"
            fi
            # EXTRA_DEPS 只接收第4字段，不包含父级
            if [[ -z "${EXTRA_DEPS}" && -n "${_alias_deps}" ]]; then
                EXTRA_DEPS="${_alias_deps}"
                ok "应用已知模块默认 deps: ${EXTRA_DEPS}"
            fi
        else
            CONFIG_NAME=$(find_config_name "${MODULE_NAME}")
            # 如果没找到, 尝试去掉 _xxx 后缀再找 (menuconfig 模式)
            # 例如 CONFIG_RTW89_CORE -> CONFIG_RTW89
            if [[ -z "${CONFIG_NAME}" ]]; then
                local _base="${MODULE_NAME}"
                local _cfg_try="CONFIG_${_base^^}"
                # 检查是否存在 menuconfig
                if grep -rqE "^menuconfig ${_base^^}\b" "${kernel_source}" --include="Kconfig*" 2>/dev/null; then
                    CONFIG_NAME="CONFIG_${_base^^}"
                fi
            fi
        fi
    fi
    # 显式传入 CONFIG 时也要保留已知模块的运行时依赖。
    if [[ -z "${EXTRA_DEPS}" ]]; then
        local known_alias
        if known_alias=$(known_modules "${MODULE_NAME}"); then
            local _known_mod _known_cfg _known_parent _known_deps
            IFS='|' read -r _known_mod _known_cfg _known_parent _known_deps <<<"${known_alias}"
            if [[ -n "${_known_parent}" && "${_known_parent}" != "${CONFIG_NAME}" ]]; then
                echo "${_known_parent}" > "${build_root}/.${MODULE_NAME}.parent"
                ok "检测到父级依赖: ${_known_parent} (将在配置阶段启用)"
            fi
            if [[ -z "${EXTRA_DEPS}" && -n "${_known_deps}" ]]; then
                EXTRA_DEPS="${_known_deps}"
                ok "应用已知模块默认 deps: ${EXTRA_DEPS}"
            fi
        fi
    fi
    if [[ -z "${CONFIG_NAME}" ]]; then
        err "无法从 Makefile 找到 ${MODULE_NAME} 对应的 CONFIG_xxx"
        err "请显式指定: $0 ${MODULE_NAME} <CONFIG_NAME>"
        exit 1
    fi
    ok "CONFIG 名: ${CONFIG_NAME}"
    CONFIG_NO_PREFIX="${CONFIG_NAME#CONFIG_}"

    # 3. 计算 .ko 路径
    module_ko_path=$(config_to_module_path "${CONFIG_NAME}")
    if [[ -z "${module_ko_path}" ]]; then
        err "无法从 ${CONFIG_NAME} 推断 .ko 路径"
        exit 1
    fi
    ok "目标 .ko: ${module_ko_path}"

    # 4. 准备 build 目录 (按 BSP 版本 + 模块命名)
    build_dir="${build_root}/${JETSON_BSP_VERSION}-${MODULE_NAME}"
    mkdir -p "${build_dir}"

    # 5. 准备 .config
    section "配置内核"
    if [[ -f "${build_dir}/.config" ]]; then
        ok "复用已有 .config: ${build_dir}/.config"
    elif [[ -n "${JETSON_CONFIG_SEED}" && -f "${JETSON_CONFIG_SEED}" ]]; then
        cp "${JETSON_CONFIG_SEED}" "${build_dir}/.config"
        ok "从种子 .config 复制为起点: ${JETSON_CONFIG_SEED}"
    else
        # 用同 BSP 版本下任意已编模块的 .config 作为种子, 保证 vermagic 一致
        local seed_config=""
        for d in "${build_root}/${JETSON_BSP_VERSION}"-*; do
            if [[ -f "${d}/.config" ]]; then
                seed_config="${d}/.config"
                break
            fi
        done
        if [[ -n "${seed_config}" ]]; then
            cp "${seed_config}" "${build_dir}/.config"
            ok "从 ${seed_config} 复制作为起点"
        else
            make -C "${kernel_source}" O="${build_dir}" defconfig
            ok "生成新 defconfig"
        fi
        "${kernel_source}/scripts/config" --file "${build_dir}/.config" \
            --set-str LOCALVERSION "-tegra"
    fi

    # 5b. 如果有父级依赖文件，启用父级
    local parent_file="${build_root}/.${MODULE_NAME}.parent"
    if [[ -f "${parent_file}" ]]; then
        local parent_cfg
        parent_cfg=$(cat "${parent_file}")
        if [[ -n "${parent_cfg}" ]]; then
            "${kernel_source}/scripts/config" --file "${build_dir}/.config" \
                --module "${parent_cfg}" 2>/dev/null
            ok "已启用父级: ${parent_cfg}"
        fi
        rm -f "${parent_file}"
    fi

    # 6. 启用目标 CONFIG
    # 6a. 对于 menuconfig 形式的复杂驱动（如 RTW89, IWLWIFI），需要启用顶级 menuconfig
    # 6b. 如果已经 =m 或 =y (iptable_raw 在 defconfig 就是 m), 就不要重复开关
    if ! grep -qE "^${CONFIG_NAME}=(m|y)" "${build_dir}/.config" 2>/dev/null; then
        # 检查是否为 menuconfig (RTW89) 或子模块 (RTW89_CORE)
        local base_cfg="${CONFIG_NAME#CONFIG_}"
        local base_root="${base_cfg%%_*}"
        local is_menuconfig=0
        if grep -rqE "^menuconfig ${base_root}\b" "${kernel_source}" --include="Kconfig*" 2>/dev/null; then
            is_menuconfig=1
        fi

        if [[ ${is_menuconfig} -eq 1 ]]; then
            # 是 menuconfig (RTW89) 或其子项 (RTW89_CORE, RTW89_8852AE)
            "${kernel_source}/scripts/config" --file "${build_dir}/.config" \
                --module "${base_root}"
            ok "已启用 menuconfig: ${base_root}=m"

            if [[ "${base_root}" != "${base_cfg}" ]]; then
                "${kernel_source}/scripts/config" --file "${build_dir}/.config" \
                    --module "${CONFIG_NAME}"
                ok "已启用子模块: ${CONFIG_NAME}=m"
            fi

            # 查找 menuconfig 内的所有 config 声明 (chip 子项)
            # 例如 RTW89 的 8852AE, 8852CE 等
            local chip_cfgs
            chip_cfgs=$(cd "${kernel_source}" && grep -rE "^config ${base_root}_[0-9]" \
                --include="Kconfig*" 2>/dev/null | awk '{print $2}')
            for chip_cfg in ${chip_cfgs}; do
                if [[ "${chip_cfg}" == *"_DEBUG"* ]] || [[ "${chip_cfg}" == *"_DEBUGMSG"* ]]; then
                    continue  # 跳过调试选项
                fi
                "${kernel_source}/scripts/config" --file "${build_dir}/.config" \
                    --module "CONFIG_${chip_cfg}"
                if grep -qE "^CONFIG_${chip_cfg}=m" "${build_dir}/.config" 2>/dev/null; then
                    ok "已启用芯片: ${chip_cfg}=m"
                fi
            done
        else
            "${kernel_source}/scripts/config" --file "${build_dir}/.config" \
                --module "${CONFIG_NAME}"
            ok "已启用 ${CONFIG_NAME}=m"
        fi
    else
        ok "${CONFIG_NAME} 已在 .config (保持现有值)"
    fi

    # 6c. 启用父级 menuconfig 链 + depends 链，防止 olddefconfig 清掉目标
    #     (例: qmi_wwan depends on USB_NET_DRIVERS/USB;
    #      pl2303/ftdi_sio 在 menuconfig USB_SERIAL 下, 隐式依赖父级)
    #     tristate 依赖置 =m, bool 置 =y — 避免把依赖编进 vmlinux 重复导出
    enable_cfg_tree "${CONFIG_NAME}"

    # 复杂驱动需要功能模块；只启用总开关会生成不可用的半套驱动。
    local companion_configs=()
    case "${MODULE_NAME}" in
        iwlwifi)
            companion_configs+=("CONFIG_IWLMVM")
            ;;
        rtw89)
            while IFS= read -r chip_cfg; do
                [[ -n "${chip_cfg}" ]] && companion_configs+=("CONFIG_${chip_cfg}")
            done < <(sed -nE 's/^config (RTW89_[0-9][0-9A-Z]*)[[:space:]]*$/\1/p' \
                "${kernel_source}/drivers/net/wireless/realtek/rtw89/Kconfig")
            ;;
    esac
    for companion_cfg in "${companion_configs[@]}"; do
        "${kernel_source}/scripts/config" --file "${build_dir}/.config" \
            --module "${companion_cfg}"
        ok "已启用功能模块: ${companion_cfg}=m"
    done

    # 6b. 设置交叉编译环境 (必须在 olddefconfig 之前!)
    export ARCH=arm64
    export CROSS_COMPILE="${cross_compile}"
    export PATH="${host_tools}:${PATH}"
    export M4="${workspace_dir}/tools/host/usr/bin/m4"
    export BISON_PKGDATADIR="${workspace_dir}/tools/host/usr/share/bison"

    # 7. 展开依赖
    make -C "${kernel_source}" O="${build_dir}" olddefconfig
    ok "依赖已展开"

    # 8. 验证
    local line
    line=$(grep -E "^${CONFIG_NAME}=" "${build_dir}/.config" | head -1)
    if [[ -z "${line}" ]]; then
        err "${CONFIG_NAME} 未出现在 .config 中"
        exit 1
    fi
    if [[ "${line}" != "${CONFIG_NAME}=m" ]]; then
        warn "${CONFIG_NAME} 不是 =m (当前: ${line})"
    else
        ok "当前状态: ${line}"
    fi
    for companion_cfg in "${companion_configs[@]}"; do
        line=$(grep -E "^${companion_cfg}=" "${build_dir}/.config" | head -1)
        if [[ "${line}" != "${companion_cfg}=m" ]]; then
            err "功能模块未启用为模块: ${companion_cfg} (当前: ${line:-未设置})"
            exit 1
        fi
    done

    # 9. 收集所有模块
    section "收集依赖模块"
    module_targets=("${module_ko_path}")

    for companion_cfg in "${companion_configs[@]}"; do
        local companion_path
        companion_path=$(config_to_module_path "${companion_cfg}")
        if [[ -n "${companion_path}" ]]; then
            ok "功能模块: ${companion_cfg} → ${companion_path}"
            module_targets+=("${companion_path}")
        fi
    done

    local configs_to_scan=("${CONFIG_NAME}" "${companion_configs[@]}")
    local scan_index=0
    declare -A scanned_configs=()
    while (( scan_index < ${#configs_to_scan[@]} )); do
        local scan_config="${configs_to_scan[${scan_index}]}"
        ((scan_index++))
        [[ -n "${scanned_configs[${scan_config}]:-}" ]] && continue
        scanned_configs["${scan_config}"]=1
        while IFS= read -r dep_config; do
            [[ -z "${dep_config}" ]] && continue
            local dep_state
            dep_state=$(grep -E "^${dep_config}=" "${build_dir}/.config" | head -1)
            if [[ "${dep_state}" != "${dep_config}=m" ]]; then
                [[ "${dep_state}" == "${dep_config}=y" ]] && \
                    ok "Kconfig 依赖已内建: ${dep_config}=y"
                continue
            fi
            configs_to_scan+=("${dep_config}")
            local dep_path
            dep_path=$(config_to_module_path "${dep_config}")
            if [[ -n "${dep_path}" ]] && [[ "${dep_path}" != "${module_ko_path}" ]]; then
                ok "Kconfig 模块依赖: ${dep_config} → ${dep_path}"
                module_targets+=("${dep_path}")
            fi
        done < <(find_kconfig_depends "${scan_config#CONFIG_}")
    done

    if [[ -n "${EXTRA_DEPS}" ]]; then
        for dep in ${EXTRA_DEPS}; do
            # 依赖若已内建 (=y, defconfig 常见如 IP_NF_IPTABLES), 跳过模块化 —
            # 否则把 vmlinux 已有符号重复导出, modpost 报 exported twice
            local dep_base dep_cfg=""
            dep_base=$(basename "${dep}" .ko)
            while IFS= read -r _dline; do
                if [[ "${_dline}" =~ obj-\$\(CONFIG_[A-Z0-9_]+\)[[:space:]]*\+=[[:space:]]*${dep_base}\.o ]]; then
                    dep_cfg=$(grep -oE 'CONFIG_[A-Z0-9_]+' <<<"${_dline}" | head -1)
                    break
                fi
            done < <(cd "${kernel_source}" && grep -rhF 'obj-$(CONFIG_' --include="Makefile" . 2>/dev/null)
            if [[ -n "${dep_cfg}" ]] && grep -qE "^${dep_cfg}=y" "${build_dir}/.config" 2>/dev/null; then
                ok "依赖已内建, 跳过模块化: ${dep} (${dep_cfg}=y)"
                continue
            fi
            ok "用户指定依赖: ${dep}"
            module_targets+=("${dep}")
        done
    fi

    local unique_targets
    unique_targets=$(printf '%s\n' "${module_targets[@]}" | sort -u)
    module_targets=( ${unique_targets} )

    section "将编译以下模块"
    for m in "${module_targets[@]}"; do
        printf '    %s\n' "${m}"
    done

    # 11. modules_prepare
    section "准备模块编译环境"
    make -C "${kernel_source}" O="${build_dir}" -j"$(nproc)" modules_prepare
    ok "modules_prepare 完成"

    # 12. 确保 vmlinux.symvers 存在 (模块编译必须的符号表)
    shared_dir="${build_root}/${JETSON_BSP_VERSION}-shared"
    mkdir -p "${shared_dir}"
    symvers_src="${shared_dir}/vmlinux.symvers"

    section "准备 vmlinux.symvers (符号表)"
    local source_symvers=""
    if [[ -f "${build_dir}/vmlinux.symvers" ]]; then
        source_symvers="${build_dir}/vmlinux.symvers"
    elif [[ -f "${symvers_src}" ]]; then
        source_symvers="${symvers_src}"
    else
        # 找同一个 BSP 版本下其他模块编出的 .symvers
        for d in "${build_root}/${JETSON_BSP_VERSION}"-*/vmlinux.symvers; do
            if [[ -f "${d}" ]]; then
                source_symvers="${d}"
                break
            fi
        done
    fi

    if [[ -n "${source_symvers}" && -s "${source_symvers}" ]]; then
        [[ "${source_symvers}" == "${build_dir}/vmlinux.symvers" ]] || \
            cp -f "${source_symvers}" "${build_dir}/vmlinux.symvers"
        [[ "${source_symvers}" == "${symvers_src}" ]] || \
            cp -f "${source_symvers}" "${symvers_src}"
        ok "复用 vmlinux.symvers: ${source_symvers}"
    else
        # 没有就编译一次 Image 生成
        section "编译内核 Image (生成 vmlinux.symvers, 一次性)"
        make -C "${kernel_source}" O="${build_dir}" -j"$(nproc)" Image
        cp -f "${build_dir}/vmlinux.symvers" "${symvers_src}"
        ok "Image 编译完成, .symvers 已缓存到 ${symvers_src}"
    fi

    # 13. 编译目标模块。它们都是内核树内目标，必须在同一次 kbuild
    # 调用中完成，modpost 才能解析模块之间的符号依赖。
    section "编译目标模块"
    printf '  → %s\n' "${module_targets[@]}"
    make -C "${kernel_source}" O="${build_dir}" -j"$(nproc)" KBUILD_BUILTIN= \
        "${module_targets[@]}"

    # 14. 验证
    section "验证结果"
    local all_ok=1
    for m in "${module_targets[@]}"; do
        local p="${build_dir}/${m}"
        if [[ -f "${p}" ]]; then
            ok "生成: ${p} ($(du -h "${p}" | cut -f1))"
        else
            err "未生成: ${p}"
            all_ok=0
        fi
    done
    (( all_ok == 0 )) && exit 1

    echo
    ok "主模块 modinfo:"
    modinfo "${build_dir}/${module_ko_path}" | grep -E '^(filename|license|description|depends|vermagic):' | sed 's/^/    /'

    # 15. 部署
    if [[ -n "${JETSON_HOST}" || "${MODULE_NAME}" != "" ]]; then
        # 传相对路径 (相对 build_dir), 让部署函数知道 modules 子目录
        local rel_targets=()
        for m in "${module_targets[@]}"; do
            rel_targets+=("${m}")   # 已经是 drivers/xxx/yyy.ko 形式
        done
        deploy_to_jetson "${rel_targets[@]}"
    fi
}

main "$@"
