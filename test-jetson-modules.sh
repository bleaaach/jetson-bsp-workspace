#!/usr/bin/env bash
# test-jetson-modules.sh
# ---------------------------------------------------------------------------
# 把本地 Build/R36.4.4-* 编出的所有 .ko 一次性推到 Jetson, 然后 SSH 上去
# 探测模块存在情况, 给出可读报告。
#
# 适用: Jetson 192.168.137.137 (seeed 用户)
# sudo 步骤需要手动输入密码
# ---------------------------------------------------------------------------
set -u

JETSON_HOST="${JETSON_HOST:-seeed@192.168.137.137}"
WORKSPACE="/media/seeed/bsp-ssd1/bsp-workspace"
BUILD="${WORKSPACE}/Build"

declare -A MODULES=(
    ["pl2303"]="drivers/usb/serial/pl2303.ko drivers/usb/serial/usbserial.ko"
    ["qmi_wwan"]="drivers/net/usb/qmi_wwan.ko drivers/net/usb/usbnet.ko drivers/usb/class/cdc-wdm.ko"
    ["iptable_raw"]="net/ipv4/netfilter/iptable_raw.ko"
)

# ========== 1. scp 把 .ko 推到 Jetson ==========
section() {
    printf '\n=== %s ===\n' "$1"
}

section "Step 1: scp .ko -> ${JETSON_HOST}"

# 探测本地哪些 build 目录有产物
local_ok=()
for d in "${BUILD}"/R36.4.4-*/; do
    [[ -d "${d}" ]] || continue
    name=$(basename "${d}")
    # 至少有一个 .ko
    if find "${d}" -name '*.ko' -quit 2>/dev/null; then
        local_ok+=("${name}")
        printf '  [本地] %s\n' "${name}"
    fi
done

if [[ ${#local_ok[@]} -eq 0 ]]; then
    echo "✗ 本地没有任何 R36.4.4-* 编译产物"
    exit 1
fi

# 推送到 /tmp/ 命名成 <dir>-<basename>.ko 避免重名
mkdir -p /tmp/jetson-push
for d in "${local_ok[@]}"; do
    while IFS= read -r ko; do
        bn=$(basename "${ko}")
        remote="/tmp/${d}/${bn}"
        printf '  scp %s -> %s:%s\n' "${ko}" "${JETSON_HOST}" "${remote}"
        ssh "${JETSON_HOST}" "mkdir -p /tmp/${d}" 2>&1 | sed 's/^/    /'
        scp "${ko}" "${JETSON_HOST}:${remote}" 2>&1 | sed 's/^/    /'
    done < <(find "${BUILD}/${d}" -name '*.ko')
done

# ========== 2. 在 Jetson 上探测现状 ==========
section "Step 2: 探测 Jetson 当前模块状态"

# 让用户手动跑 sudo 部分 (Jetson 要密码)
read -rp "  现在要 SSH 上 Jetson 做模块检查, 继续? [Y/n] " ans
ans="${ans:-Y}"
[[ "${ans}" =~ ^[Yy] ]] || { echo "退出"; exit 0; }

REMOTE_INSPECT='
echo "== Jetson: $(uname -r) =="
echo ""
echo "[A] 已加载的相关模块:"
lsmod | grep -E "^(pl2303|usbserial|qmi_wwan|usbnet|cdc_wdm|iptable_raw|ip_tables|x_tables)\b" || echo "    (无)"
echo ""
echo "[B] /lib/modules/$(uname -r) 内已有的 .ko:"
for m in pl2303 usbserial qmi_wwan usbnet cdc_wdm iptable_raw ip_tables x_tables; do
    hit=$(find /lib/modules/$(uname -r) -name "${m}.ko" 2>/dev/null | head -1)
    if [[ -n "$hit" ]]; then
        echo "    [已安装] $m -> $hit"
    else
        echo "    [缺失]   $m"
    fi
done
echo ""
echo "[C] 内核 CONFIG 状态 (需要 root):"
echo "    跳过 (sudo 步骤下面单独跑)"
echo ""
echo "[D] /tmp 下本地推送的 .ko:"
ls -la /tmp/R36.4.4-*/*.ko 2>/dev/null || echo "    (无)"
'

printf '\nSSH 上 Jetson 跑下面命令:\n\n'
printf '   ssh %s\n' "${JETSON_HOST}"
printf '%s\n' "${REMOTE_INSPECT}"
printf '\n# 看完了告诉我输出, 我帮你决定怎么 install + modprobe\n'

# ========== 3. 提供 install + modprobe 命令模板 ==========
section "Step 3: install + modprobe 命令模板"

# Jetson 上跑的 install 流程 (用户复制粘贴)
REMOTE_INSTALL='
# Jetson 上: 安装到 /lib/modules/$(uname -r)/extra/ 然后 depmod
KVER=$(uname -r)
KDIR=/lib/modules/${KVER}
DEST=${KDIR}/extra

sudo mkdir -p ${DEST}
sudo mkdir -p ${DEST}/drivers/usb/serial
sudo mkdir -p ${DEST}/drivers/net/usb
sudo mkdir -p ${DEST}/drivers/usb/class
sudo mkdir -p ${DEST}/net/ipv4/netfilter

# 安装每个 .ko 到对应子目录
sudo install -m 644 /tmp/R36.4.4-pl2303/pl2303.ko       ${DEST}/drivers/usb/serial/
sudo install -m 644 /tmp/R36.4.4-pl2303/usbserial.ko    ${DEST}/drivers/usb/serial/
sudo install -m 644 /tmp/R36.4.4-qmi_wwan/qmi_wwan.ko    ${DEST}/drivers/net/usb/
sudo install -m 644 /tmp/R36.4.4-qmi_wwan/usbnet.ko     ${DEST}/drivers/net/usb/
sudo install -m 644 /tmp/R36.4.4-qmi_wwan/cdc-wdm.ko     ${DEST}/drivers/usb/class/
sudo install -m 644 /tmp/R36.4.4-iptable_raw/iptable_raw.ko ${DEST}/net/ipv4/netfilter/

sudo depmod -a

# 校验
echo "== 安装结果 =="
find ${DEST} -name "*.ko" -newer /tmp/R36.4.4-pl2303/pl2303.ko -o -name "*.ko" | sort | uniq | head -20
echo ""
echo "== modprobe 测试 =="

# 一个一个试, 失败不影响下一个
for m in pl2303 qmi_wwan iptable_raw; do
    printf "  modprobe -v %s ... " "$m"
    if sudo modprobe -v "$m" 2>&1 | tail -2; then
        printf "    \033[32m✓\033[0m %s\n" "$m"
    else
        printf "    \033[31m✗\033[0m %s\n" "$m"
        sudo dmesg -T | tail -10 | sed "s/^/      /"
        sudo modprobe -r "$m" 2>/dev/null
    fi
done

echo ""
echo "== 最终 lsmod =="
lsmod | grep -E "^(pl2303|usbserial|qmi_wwan|usbnet|cdc_wdm|iptable_raw)\b"

echo ""
echo "== 卸载 (如要重测) =="
echo "  sudo modprobe -r iptable_raw qmi_wwan pl2303 2>/dev/null || true"
'

printf '%s\n' "${REMOTE_INSTALL}"
printf '\n# 跑完后告诉我输出, 我们根据实际效果调!\n'