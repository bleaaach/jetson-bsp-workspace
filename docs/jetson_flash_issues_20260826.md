# Jetson Orin J401 固件架构与刷机分析

**日期**: 2026-08-26  
**设备**: Seeed Recomputer Orin J401 (SKU: 0001)  
**SoC**: NVIDIA Tegra 234 (Orin)  
**BSP**: L4T R36.4.3  
**环境**: WSL2 (Ubuntu)  

---

## 1. Boot Flow 概览

### 1.1 冷启动顺序

```
ROM Bootloader (On-chip)
    │
    ▼
MB1 (Bootloader Stage 1) ──► PMC/PINMUX/BCT 初始化
    │                           - 设置 PLL/时钟
    │                           - 配置 GPIO/Pinmux
    │                           - 内存初始化
    ▼
MB2 (Bootloader Stage 2) ──► MP RF/CCD/DP 初始化
    │                           - DCE (Display Controller)
    │                           - XUSB (USB Controller)
    │                           - 加载更多固件组件
    ▼
Cboot ──► UEFI Bootloader
    │         - 设备树加载
    │         - 启动选择
    ▼
Kernel Boot
```

### 1.2 RCM (Recovery Mode) 流程

```
设备上电 + REC 按住
    │
    ▼
ROM Bootloader 检测 REC 信号
    │
    ▼
进入 RCM 模式 (USB ID: 0955:7423)
    │
    ▼
等待主机发送 bootable image via USB
    │
    ▼
tegrarcm_v2 --cmd "rcmboot"
    │
    ▼
执行下载的 blob (MB1 + MB2 + kernel + DTB)
    │
    ▼
Initrd Flash Kernel 启动
    │
    ▼
执行实际烧录操作
```

---

## 2. 固件组件详解

### 2.1 BCT (Boot Configuration Table)

| 文件 | 路径 | 说明 |
|------|------|------|
| `br_bct_BR.bct` | bootloader/ | BootROM BCT |
| `mb1_bct_MB1.bct` | bootloader/ | MB1 配置 |
| `mem_coldboot.bct` | bootloader/ | 内存配置 |

**关键配置**:
- `tegra234-mb1-bct-pinmux-p3767-hdmi-a03.dtsi` - PINMUX
- `tegra234-mb1-bct-padvoltage-p3767-hdmi-a03.dtsi` - 电源管理

### 2.2 Bootloader 阶段

| 组件 | 文件 | 功能 |
|------|------|------|
| MB1 | `mb1_t234_prod.bin` | 初始引导、时钟/内存初始化 |
| PSC BL1 | `psc_bl1_t234_prod_aligned.bin` | Power Sequence Controller |
| MB2 | `mb2_t234_with_mb2_cold_boot_bct_MB2.bin` | 第二阶段引导 |
| Cboot | `uefi_jetson_minimal_with_dtb.bin` | UEFI 启动管理器 |

### 2.3 固件镜像 (Firmware Binaries)

```
Bootloader 目录: /media/seeed/bsp-ssd1/bsp-workspace/Linux_for_Tegra/bootloader/
```

| 组件 | 文件 | 大小 | 说明 |
|------|------|------|------|
| BPMP FW | `bpmp_t234-TE980M-A1_prod.bin` | ~1MB | Carmel CPU 固件 |
| BPMP DTB | `tegra234-bpmp-3767-0001-3768-super.dtb` | ~263KB | J401 专用 |
| TOS | `tos-optee_t234.img` | ~1.8MB | Trusted OS |
| EKS | `eks_t234.img` | ~9KB | Encryption Key Store |
| XUSB FW | `xusb_t234_prod.bin` | ~160KB | USB 控制器固件 |
| DCE FW | `display-t234-dce.bin` | ~12MB | Display 输出固件 |
| SPE FW | `spe_t234.bin` | ~270KB | Sensor Processing Engine |
| RCE FW | `camera-rtcpu-t234-rce.bin` | ~458KB | Camera ISP |
| PVA FW | `nvpva_020.fw` | ~2.1MB | PVA (Vision Accelerator) |
| NVDEC | `nvdec_t234_prod.bin` | ~295KB | Video Decoder |

### 2.4 Kernel 镜像

| 文件 | 路径 | 说明 |
|------|------|------|
| `boot0.img` | bootloader/ | 合并的 kernel + DTB (76MB) |
| `Image` | source/out/kernel/.../ | 原始 kernel Image |

---

## 3. 设备树覆盖 (DTB Overlay)

### 3.1 Recomputer J401 DTB 选择逻辑

基于 SKU 选择不同的 DTB：

```bash
# recomputer-orin-j401.conf 中的 p3767_super_overlay()

SKU 0000/0002: tegra234-j401-p3768-0000+p3767-0000-recomputer.dtb
SKU 0001:      tegra234-j401-p3768-0000+p3767-0001-recomputer.dtb  ← 当前使用
SKU 0003:      tegra234-j401-p3768-0000+p3767-0003-recomputer.dtb
SKU 0004:      tegra234-j401-p3768-0000+p3767-0004-recomputer.dtb
SKU 0005:      tegra234-p3768-0000+p3767-0005-nv-super.dtb
```

### 3.2 动态覆盖

```bash
OVERLAY_DTB_FILE:
  - tegra234-dcb-p3767-0000-hdmi.dtbo      # HDMI 输出
  - tegra234-p3767-camera-p3768-imx219-dual-seeed.dtbo  # Seeed IMX219 双摄
  - tegra234-p3768-0000+p3767-0000-dynamic.dtbo  # 动态配置
```

---

## 4. 刷机流程分析

### 4.1 Initrd Flash vs Traditional Flash

| 特性 | Initrd Flash | Traditional Flash |
|------|-------------|-------------------|
| 内核 | initrd 中的临时内核 | QSPI/NOR flash 中的内核 |
| 存储 | 外部设备 (NVMe/USB) | eMMC |
| 用途 | 开发/量产 | 工厂烧录 |
| 复杂度 | 较简单 | 较复杂 |

### 4.2 Initrd Flash 执行步骤

```
Step 1: Build flash environment
         - 创建 temp_initrdflash/ 目录
         - 准备加密的固件镜像

Step 2: Boot device with flash initrd
         - 通过 USB RCM 发送 blob
         - 设备启动 initrd flash kernel

Step 3: Start flashing process
         - 通过网络 (USB/RJ45) 传输镜像
         - 写入 NVMe 分区
```

### 4.3 刷机命令参数解析

```bash
./tools/kernel_flash/l4t_initrd_flash.sh \
    --flash-only \                      # 仅执行闪存操作
    recomputer-orin-j401 \              # 板级配置
    nvme0n1p1 \                         # 目标外部设备
    --network usb0 \                    # 主机通信接口
    -c "tools/kernel_flash/flash_l4t_t234_nvme.xml"  # 分区表
```

### 4.4 分区表配置

```xml
<!-- flash_l4t_t234_nvme.xml -->

<device type="external" instance="0">  <!-- NVMe 作为外部设备 -->
    <partition name="A_kernel" type="kernel">  Linux kernel
    <partition name="A_kernel-dtb" type="kernel_dtb">  Device tree
    <partition name="APP" type="data">  Rootfs 分区
    <partition name="UDA" type="data">  User data
    ...
</device>
```

---

## 5. 遇到的问题

### 5.1 EMMC_CFG 配置不匹配

**问题**: 基础配置 `p3768-0000-p3767-0000-a0.conf` 设置了 `EMMC_CFG="flash_t234_qspi_sd.xml"`，但 J401 SKU 0001 没有 SD 卡槽。

**解决**: 在 `recomputer-orin-j401.conf` 中覆盖：

```bash
update_flash_args()
{
    update_flash_args_common
    p3767_super_overlay
    EMMC_CFG="flash_t234_qspi.xml";  # 覆盖为 QSPI only 配置
}
```

### 5.2 WSL2 USB 限制

**现象**: `tegrarcm_v2` 发送文件时 USB 超时

**原因**: WSL2 USB passthrough 对 Jetson RCM 高速 USB 通信支持不稳定

**方案**: 建议使用物理 Linux 或 usbipd-win

### 5.3 tegrarcm_v2 批量下载超时

**现象**: 单个文件下载成功，批量下载时 "might be timeout in USB write"

**测试结果**:
- ✅ `tegrarcm_v2 --instance 1-1 --new_session --chip 0x23 --uid` - 成功
- ✅ `tegrarcm_v2 --instance 1-1 --new_session --chip 0x23 --download bct_br br_bct_BR.bct` - 成功 (8KB)
- ❌ `tegrarcm_v2 --instance 1-1 --new_session --chip 0x23 0 --download bct_br br_bct_BR.bct` - 失败

**关键发现**: 参数 `--chip 0x23 0` (带额外的 0 参数) 导致批量下载超时

**当前状态**:
- 设备: Bus 001 Device 030, ID 0955:7423 NVIDIA Corp. APX
- USB 速度: high-speed
- 根本原因: tegrarcm_v2 版本或 WSL2 USB 兼容性问题

---

## 6. 安全机制

### 6.1 安全启动链

```
ROM → MB1 → MB2 → Cboot → UEFI → Kernel → Rootfs
```

- **NS (Non-Secure)**: 当前配置使用非安全模式
- **PKC**: Public Key Cryptography (未启用)
- **SBK**: Secure Boot Key (未设置)

### 6.2 加密签名

所有固件镜像均使用 presigned 二进制文件：
- `*_sigheader.bin.encrypt` - 带签名头的加密镜像
- `br_bct_BR.bct` - BootROM BCT 签名

---

## 7. 关键文件路径

| 用途 | 路径 |
|------|------|
| 板级配置 | `Linux_for_Tegra/recomputer-orin-j401.conf` |
| 父级配置 | `Linux_for_Tegra/p3768-0000-p3767-0000-a0.conf` |
| 分区表 | `Linux_for_Tegra/tools/kernel_flash/flash_l4t_t234_nvme.xml` |
| Bootloader | `Linux_for_Tegra/bootloader/` |
| 内核源码 | `Linux_for_Tegra/source/out/kernel/kernel-jammy-src/` |
| 固件配置 | `Linux_for_Tegra/bootloader/generic/BCT/` |

---

## 8. 参考信息

- ECID: `0x80012344705DD3081000000001FE8080`
- Board ID: `3767`
- FAB: `300`
- SKU: `0001` (8GB Orin)
- RAM Code: `2`

---

*文档创建时间: 2026-08-26*
