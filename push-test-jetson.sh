#!/usr/bin/env bash
# push-test-jetson.sh
# ---------------------------------------------------------------------------
# 一键测试: 本地编译好的 pl2303 / qmi_wwan / iptable_raw 三个模块
#           推到 Jetson 192.168.137.137, 自动 install + modprobe + 校验
#
# 用法:
#   ./push-test-jetson.sh
#
# 环境变量:
#   JETSON_HOST=seeed@192.168.137.137    默认
#   JETSON_PASSWORD=xxx                  ssh 登录密码 (仅首次推送 ssh-key 用)
#   SUDO_PASSWORD=xxx                    sudo 密码 (如已配 NOPASSWD 可不设)
#
# 流程:
#   1. ssh-copy-id (推送免密, 之后不要再密码)
#   2. scp 所有 .ko -> /tmp/
#   3. SSH 上去自动 sudo 安装到 /lib/modules/.../extra/
#   4. 自动 depmod + modprobe 测试 + 校验 lsmod
#   5. 输出可读报告
# ---------------------------------------------------------------------------
set -u

JETSON_HOST="${JETSON_HOST:-seeed@192.168.137.137}"

WORKSPACE="/home/seeed/bsp-workspace"
BUILD="${WORKSPACE}/Build"
LOCAL_SCRATCH="/tmp/jetson-push"

# ========== 颜色 ==========
if [[ -t 1 ]]; then
    C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'; C_BOLD=$'\e[1m'; C_RESET=$'\e[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''; C_RESET=''
fi
ok()   { printf '%s✓%s %s\n' "${C_GREEN}" "${C_RESET}" "$1"; }
warn() { printf '%s!%s %s\n' "${C_YELLOW}" "${C_RESET}" "$1"; }
err()  { printf '%s✗%s %s\n' "${C_RED}" "${C_RESET}" "$1"; }
section() { printf '\n%s%s%s\n' "${C_BOLD}${C_BLUE}" "$1" "${C_RESET}"; printf -- '------------------------------------------------------------\n'; }

# ========== 0. 用 sshpass ==========
if ! command -v sshpass >/dev/null 2>&1; then
    err "需要 sshpass: sudo apt-get install -y sshpass"
    exit 1
fi

# ========== 拿密码 (不会明文展示) ==========
ask_password() {
    local var="$1" prompt="$2"
    if [[ -n "${!var:-}" ]]; then
        return 0
    fi
    read -rsp "${prompt}: " "${var}" < /dev/tty
    printf '\n'
}

# 拿 ssh 密码 (仅首次 ssh-copy-id 用)
ask_password JETSON_PASSWORD "Jetson ssh 密码 (推送公钥用, 见 ${JETSON_HOST})"
ask_password SUDO_PASSWORD  "Jetson sudo 密码 (如已 NOPASSWD 直接回车)"

# 验证
if [[ -z "${JETSON_PASSWORD}" ]]; then
    err "未提供 ssh 密码, 无法继续"
    exit 1
fi

# ========== 1. ssh-copy-id 一次性免密 ==========
section "Step 1: 推送免密 ssh 公钥 (一次性)"

if ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${JETSON_HOST}" 'echo ok' >/dev/null 2>&1; then
    ok "已免密登录 (无需推公钥)"
else
    # 生成密钥 (无 passphrase, 一次性)
    if [[ ! -f "${HOME}/.ssh/id_ed25519" && ! -f "${HOME}/.ssh/id_rsa" ]]; then
        echo "  生成 ssh 密钥对 (ed25519, 无密码)..."
        mkdir -p "${HOME}/.ssh"
        chmod 700 "${HOME}/.ssh"
        ssh-keygen -t ed25519 -N '' -f "${HOME}/.ssh/id_ed25519" -C "push-test-jetson@$(hostname)" >/dev/null 2>&1
    fi
    echo "  ssh-copy-id ${JETSON_HOST} ..."
    SSHPASS="${JETSON_PASSWORD}" sshpass -e ssh-copy-id \
        -o StrictHostKeyChecking=no -o ConnectTimeout=10 "${JETSON_HOST}" 2>&1 | sed 's/^/    /'
    if ssh -o BatchMode=yes -o StrictHostKeyChecking=no "${JETSON_HOST}" 'echo ok' >/dev/null 2>&1; then
        ok "公钥推送成功"
    else
        err "公钥推送失败, 检查密码或网络"
        exit 1
    fi
fi

# ========== 2. 探测 Jetson 现状 ==========
section "Step 2: 探测 Jetson 当前模块状态"

ssh_remote() {
    # sudo_password 通过 stdin 传入 sudo (避免 ps 看)
    if [[ -n "${SUDO_PASSWORD:-}" ]]; then
        # -S: stdin 读密码; -k: 清除旧的 sudo 时间戳
        echo "${SUDO_PASSWORD}" | ssh -o StrictHostKeyChecking=no "${JETSON_HOST}" \
            "sudo -S -p '' $1" 2>&1
    else
        ssh -o StrictHostKeyChecking=no "${JETSON_HOST}" "$1" 2>&1
    fi
}

printf '  Jetson 内核: '
ssh_remote 'uname -r' | head -1

printf '\n[已加载] 相关模块:\n'
ssh_remote 'lsmod 2>/dev/null | grep -E "^(pl2303|usbserial|qmi_wwan|usbnet|cdc_wdm|iptable_raw|ip_tables|x_tables)\b" || echo "  (无)"' | sed 's/^/  /'

printf '\n[/lib/modules 内已有 .ko]:\n'
ssh_remote 'kver=$(uname -r); for m in pl2303 usbserial qmi_wwan usbnet cdc_wdm iptable_raw ip_tables x_tables; do hit=$(find /lib/modules/$kver -name "${m}.ko" 2>/dev/null | grep -v extra | head -1); if [[ -n "$hit" ]]; then echo "  [已内置] $m"; else echo "  [缺失]   $m"; fi; done'

# ========== 3. scp 推 .ko ==========
section "Step 3: 推送 .ko 到 Jetson /tmp/"

# 列出本地产物
declare -A KO_BUNDLES
KO_BUNDLES["pl2303"]=(
    "${BUILD}/R36.4.4-pl2303/drivers/usb/serial/pl2303.ko"
    "${BUILD}/R36.4.4-pl2303/drivers/usb/serial/usbserial.ko"
)
KO_BUNDLES["qmi_wwan"]=(
    "${BUILD}/R36.4.4-qmi_wwan/drivers/net/usb/qmi_wwan.ko"
    "${BUILD}/R36.4.4-qmi_wwan/drivers/net/usb/usbnet.ko"
    "${BUILD}/R36.4.4-qmi_wwan/drivers/usb/class/cdc-wdm.ko"
)
KO_BUNDLES["iptable_raw"]=(
    "${BUILD}/R36.4.4-iptable_raw/net/ipv4/netfilter/iptable_raw.ko"
)

local_pushed=()
for mod_name in "${!KO_BUNDLES[@]}"; do
    printf '\n  [%s]\n' "${mod_name}"
    for ko in "${KO_BUNDLES[$mod_name]}"; do
        if [[ ! -f "${ko}" ]]; then
            warn "本地缺失: ${ko}"
            continue
        fi
        local_name="${mod_name}-$(basename "${ko}")"
        printf '    scp %s -> %s:/tmp/%s\n' "${ko}" "${JETSON_HOST}" "${local_name}"
        if scp -o StrictHostKeyChecking=no "${ko}" "${JETSON_HOST}:/tmp/${local_name}" 2>&1 | sed 's/^/      /'; then
            local_pushed+=("${local_name}")
            ok "传好: ${local_name}"
        else
            err "scp 失败: ${ko}"
        fi
    done
done

[[ ${#local_pushed[@]} -gt 0 ]] || { err "没东西推上去"; exit 1; }

# ========== 4. install 到 /lib/modules ==========
section "Step 4: 安装到 /lib/modules/\$(uname -r)/extra/"

# 在 Jetson 上批量安装
install_cmd=$(cat <<'EOF'
kver=$(uname -r)
KDIR="/lib/modules/${kver}/extra"
mkdir -p "${KDIR}/drivers/usb/serial" \
         "${KDIR}/drivers/net/usb" \
         "${KDIR}/drivers/usb/class" \
         "${KDIR}/net/ipv4/netfilter"

# pl2303
install -m 644 /tmp/pl2303-pl2303.ko    "${KDIR}/drivers/usb/serial/pl2303.ko"
install -m 644 /tmp/pl2303-usbserial.ko "${KDIR}/drivers/usb/serial/usbserial.ko"

# qmi_wwan
install -m 644 /tmp/qmi_wwan-qmi_wwan.ko    "${KDIR}/drivers/net/usb/qmi_wwan.ko"
install -m 644 /tmp/qmi_wwan-usbnet.ko      "${KDIR}/drivers/net/usb/usbnet.ko"
install -m 644 /tmp/qmi_wwan-cdc-wdm.ko     "${KDIR}/drivers/usb/class/cdc-wdm.ko"

# iptable_raw
install -m 644 /tmp/iptable_raw-iptable_raw.ko "${KDIR}/net/ipv4/netfilter/iptable_raw.ko"

depmod -a
echo "INSTALL_OK"
EOF
)

if out=$(echo "${SUDO_PASSWORD}" | ssh -o StrictHostKeyChecking=no "${JETSON_HOST}" \
    "sudo -S -p '' bash -c $(printf '%q' "${install_cmd}")" 2>&1); then
    if grep -q "INSTALL_OK" <<<"${out}"; then
        ok "所有 .ko 已安装到 ${JETSON_HOST}:/lib/modules/\$(uname -r)/extra/"
    else
        err "安装报错:"
        printf '%s\n' "${out}" | sed 's/^/    /'
        exit 1
    fi
else
    err "sudo 失败 (密码错?), 调试:"
    printf '%s\n' "${out}" | sed 's/^/    /'
    exit 1
fi

# ========== 5. modprobe 测试 ==========
section "Step 5: modprobe 测试"

probe_cmd='
for m in iptable_raw qmi_wwan pl2303; do
    printf "  === modprobe %s ===\n" "$m"
    if modprobe -v "$m" 2>&1; then
        echo "    RESULT: OK"
    else
        echo "    RESULT: FAILED"
        dmesg -T 2>/dev/null | tail -10 | sed "s/^/      /"
        modprobe -r "$m" 2>/dev/null
    fi
done
echo ""
echo "== lsmod (3 个目标模块) =="
lsmod | grep -E "^(pl2303|usbserial|qmi_wwan|usbnet|cdc_wdm|iptable_raw)\b" || echo "  (无)"
echo ""
echo "== iptables -t raw 校验 (仅 iptable_raw) =="
iptables -t raw -L -n -v 2>&1 || echo "  (跳过)"
'

probe_out=$(echo "${SUDO_PASSWORD}" | ssh -o StrictHostKeyChecking=no "${JETSON_HOST}" \
    "sudo -S -p '' bash -c $(printf '%q' "${probe_cmd}")" 2>&1)

printf '%s\n' "${probe_out}" | sed 's/^/  /'

# ========== 6. 总结 ==========
section "总结报告"

if grep -q "^.*iptable_raw" <<<"${probe_out}"; then
    ok "iptable_raw: 已加载"
else
    err "iptable_raw: 未加载"
fi
if grep -q "^.*qmi_wwan" <<<"${probe_out}"; then
    ok "qmi_wwan: 已加载"
else
    err "qmi_wwan: 未加载"
fi
if grep -q "^.*pl2303" <<<"${probe_out}"; then
    ok "pl2303: 已加载"
else
    err "pl2303: 未加载"
fi

printf '\n== 手动卸载 (Jetson 上) ==\n'
printf '  sudo modprobe -r iptable_raw qmi_wwan pl2303 2>/dev/null || true\n'

printf '\n脚本完毕.\n'