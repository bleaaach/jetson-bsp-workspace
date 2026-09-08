# J401 GMSL JP7.2 / R39.2.0 MCP2518FD CAN1 问题

> **摘要**：J401 GMSL 在 JetPack 7.2 / L4T R39.2.0 (kernel 6.8.12-1021-tegra) 下使用 MCP2518FD CAN 控制器时，出现 CAN1 TX 无法完成和 PY.04 IRQ storm 两个问题。经分析确认为 NVIDIA 官方内核 SPI 驱动的已知 bug，截至 2026-08-14 仍未集成到官方源码。本文档提供根因分析、官方证据及修复方案。

---

## 1. 问题描述

### 问题 1：MCP2518FD TX 无法完成

- SPI trace 显示 TX 请求已正确发送，但 TX 永远不完成
- `candump can1` 看不到任何帧
- MCP2518FD TXIF 中断未触发

### 问题 2：PY.04 IRQ storm

- dmesg 出现大量 IRQ storm：
  ```
  IRQ 151: nobody cared (Probably hardware interrupt problem)
  handlers: IRQ 151: tegra_gpio_isr
  ```
- GPIO 引脚 PY.04（SPI3_CS1）停留在 SFIO 模式，GPIO 控制器读不到真实电平

---

## 2. 根因分析

### 问题 1 根因：CS 在 multi-xfer 间错误释放

MCP2518FD 每次 TX 发送两条 SPI xfer：

1. **xfer[0]**：`LOAD TX FIFO` 对象，`cs_change=1`
2. **xfer[1]**：`TXREQ + UINC` 对象

驱动在处理 `cs_change=1` 时调用 `tegra_spi_transfer_end()` 释放 CS，但 xfer[1] 开始时 `tspi->cs_control == NULL`，驱动未重新 assert CS，导致 TXREQ 在 CS=high 时发出，MCP2518FD 收不到。

**关键代码位置**：`drivers/spi/spi-tegra114.c` 的 `tegra_spi_transfer_one_message()`

### 问题 2 根因：6.8 内核 GPIO 启动时序变化

设备树中 PY.04 配置为 SFIO 模式（rsvd1）。R36.4.3（5.15 内核）启动时 GPIO 子系统会先将引脚切到 GPIO 模式；但 R39.2.0（6.8 内核）GPIO 启动时序有变化，PINMUX 停留在 SFIO 模式，导致 GPIO IRQ 风暴。

---

## 3. NVIDIA 官方确认

**NVIDIA 论坛原帖**：[Missing patch in kernel sources spi-tegra114.c - JP7.2](https://forums.developer.nvidia.com/t/missing-patch-in-kernel-sources-spi-tegra114-c-jp7-2/372791/)

**NVIDIA 官方回复**（KevinFFF，2026-06-10）：

> *"Sorry that the fixes were not integrated to JP7.2. For both JP7.1 and JP7.2, you may need to apply the following 2 patches"*

**状态**：截至 2026-08-14，这两份补丁在 R39.2.0 公开源码中仍未集成。

---

## 4. 修复方案

### 4.1 补丁说明

两份补丁均来自 NVIDIA 官方，Seeed 已适配到 R39.2.0 的 6.8.12 内核版本：


| 补丁      | 文件名                                                               | 解决什么问题                                     |
| ------- | ----------------------------------------------------------------- | ------------------------------------------ |
| Patch 1 | `0001-NVIDIA-SAUCE-spi-tegra114-Force-SW-CS-for-multi-xfer.patch` | 强制多 xfer 消息使用 SW CS，避免 HW CS 在 xfer 之间错误释放 |
| Patch 2 | `0002-NVIDIA-SAUCE-spi-tegra114-Preserve-SW-CS-across-bus.patch`  | 跨多条 spi_message 保持 SW CS 状态                |


**两个补丁都需要按顺序应用，单独使用 Patch 1 不完整。**

补丁存放路径：

```
Linux_for_Tegra/patches/spi-tegra114-r39.2.0/
├── 0001-NVIDIA-SAUCE-spi-tegra114-Force-SW-CS-for-multi-xfer.patch
└── 0002-NVIDIA-SAUCE-spi-tegra114-Preserve-SW-CS-across-bus.patch
```

### 4.2 PY.04 中断引脚临时规避

在应用 SPI 补丁之前，可以使用 GPIO hog 临时规避 IRQ storm 问题：

在设备树中或运行时配置：

```bash
# 运行时配置 GPIO hog（临时生效，重启失效）
sudo gpioset GPIO=Y=4 input
```

或通过 GPIO sysfs：

```bash
echo 124 > /sys/class/gpio/export
echo "in" > /sys/class/gpio/gpio124/direction
```

---

## 5. 应用补丁步骤

### 5.1 主机端：下载源码并应用补丁

```bash
# 1. 下载 R39.2.0 / JP7.2 kernel 源码
#    地址：https://developer.nvidia.com/embedded/jetpack/downloads
#    选择 Jetson Linux R39.2.0 -> Source

# 2. 进入源码根目录，按顺序应用两个补丁
cd <kernel-source-root>

patch -p1 < 0001-NVIDIA-SAUCE-spi-tegra114-Force-SW-CS-for-multi-xfer.patch
patch -p1 < 0002-NVIDIA-SAUCE-spi-tegra114-Preserve-SW-CS-across-bus.patch

# 3. 交叉编译（主机上为 Jetson 编译），只重编 spi-tegra114 模块
#    ARCH=arm64: 目标架构
#    CROSS_COMPILE: 交叉编译器前缀（根据实际安装的 toolchain 调整）
#    M=drivers/spi: 只编译 SPI 子目录，不动其他
make -j$(nproc) ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
  M=drivers/spi modules
```

编译成功后在 `drivers/spi/` 目录下生成 `spi-tegra114.ko`。

### 5.2 目标设备：部署模块

```bash
# 1. 备份原模块
sudo cp /lib/modules/6.8.12-1021-tegra/kernel/drivers/spi/spi-tegra114.ko \
        /lib/modules/6.8.12-1021-tegra/kernel/drivers/spi/spi-tegra114.ko.bak

# 2. 拷贝新模块到目标设备
#    （用 scp 或 U 盘）

# 3. 部署
sudo cp spi-tegra114.ko \
        /lib/modules/6.8.12-1021-tegra/extra/spi-tegra114.ko

# 4. 更新模块依赖
sudo depmod -a

# 5. 更新 initramfs（如果有）
sudo update-initramfs -u

# 6. 重启
sudo reboot
```

---

## 6. 验证步骤

```bash
# 1. 确认 IRQ storm 已消失
dmesg | grep -iE "unhandled|nobody cared|IRQ.*disabled"
# 预期：无输出

# 2. 确认 GPIO 状态
cat /sys/kernel/debug/gpio | grep Y.4
# 预期：GPIO_MODE=0，物理输入正常

# 3. 启动 can1
sudo ip link set can1 up type can bitrate 500000

# 4. 回环测试
sudo ip link set can1 down
sudo ip link set can1 up type can bitrate 500000 loopback on
cansend can1 123#DEADBEEF
candump can1
# 预期：看到回环帧 123#DEADBEEF

# 5. 正常通信测试
sudo ip link set can1 down
sudo ip link set can1 up type can bitrate 500000
cansend can1 456#CAFEBABE
ip -s -d link show can1
# 预期：TX packets 计数增加
```

---

## 7. 后续行动

- Seeed 将持续跟踪 NVIDIA 官方对该 bug 的修复进展
- 一旦 NVIDIA 在 R39.2.x 或 R40.x 中集成补丁，将在下一版 BSP 镜像中包含
- 客户如有需要，可联系 Seeed 提供预编译的 `spi-tegra114.ko` 模块（针对 6.8.12-1021-tegra）

---

## 8. 参考链接

- [NVIDIA Forum: Missing patch in kernel sources spi-tegra114.c - JP7.2](https://forums.developer.nvidia.com/t/missing-patch-in-kernel-sources-spi-tegra114-c-jp7-2/372791/)
- [NVIDIA Forum: spi-tegra114 patches for JetPack 6.x](https://forums.developer.nvidia.com/t/spi-tegra114-patches-for-jetpack-6-x/320484)
- [NVIDIA Forum: MCP2518FD CAN module on Jetson Orin Nano](https://forums.developer.nvidia.com/t/mcp2518fd-can-module-on-jetson-orin-nano-8gb-devkit/324979)

