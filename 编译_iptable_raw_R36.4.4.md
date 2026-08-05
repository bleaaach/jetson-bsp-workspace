# Jetson Linux R36.4.4 交叉编译与测试 `iptable_raw.ko`

> **编译环境**：我们在另一台 x86_64 Linux 设备上进行交叉编译，为 ARM64 架构的 Jetson 设备编译内核模块。
>
> **备选方式**：也可以直接在 Jetson 设备上本地编译（`make modules`），适合调试或简单模块；大量编译时推荐交叉编译，速度更快。

### 两种编译方式对比

| 方式 | 优点 | 缺点 |
|------|------|------|
| **交叉编译（PC → Jetson）** | PC 性能强，编译快 | 需要配置交叉工具链，步骤多 |
| **本地编译（Jetson 直接编译）** | 简单，直接 `make modules` | Jetson 资源有限，编译慢 |

| 场景 | 推荐方式 |
|------|----------|
| 学习/调试/简单模块 | **直接在 Jetson 编译**，省事 |
| 大量编译/完整内核 | **交叉编译**，速度快 |
| 量产/自动化流程 | **交叉编译**，可控 |

本文适用于运行 Jetson Linux R36.4.4 的 Seeed reComputer Mini AGX Orin J501。

需要启用的内核配置为：

```text
CONFIG_IP_NF_RAW=m
```

该配置生成 IPv4 raw 表模块 `iptable_raw.ko`，它依赖 `x_tables.ko` 和 `ip_tables.ko`。

## 源码与 BSP 的职责

Seeed 的 `Linux_for_Tegra` 主要用于制作和部署 Seeed 设备对应的 BSP，不是完整内核源码仓库。

它通常包含：

- J501、J401、J40 等载板的 flash 配置。
- Seeed 定制 DTB、DTBO 与设备树补丁。
- BCT、UEFI、bootloader 等启动配置。
- 内核 `Image`、DTB 等产物的放置位置。
- Seeed 特有外设配置，例如相机、网口和载板功能。
- 将自行编译的 `Image`、`.ko`、DTB 放回 BSP 后进行打包或刷机的脚本与目录结构。

两者关系如下：

```text
完整 NVIDIA kernel source
  -> 编译通用内核与 .ko

Seeed Linux_for_Tegra
  -> 适配 J501 载板、打包 BSP、刷机部署
```

例如，修改 J501 的设备树、启用 PCIe、USB 或摄像头时，通常修改 Seeed 的 BSP 配置或补丁；随后用完整 NVIDIA 源码编译内核或 DTB，最后将产物放入 Seeed `Linux_for_Tegra` 后刷入设备。

对于 `menuconfig` 或 QMI 模块这类内核配置操作，必须进入完整的 `kernel-jammy-src`。Seeed 当前的补丁树不是完整内核目录，不能直接在其中执行 `make ARCH=arm64 menuconfig`。

## 1. 确认 Jetson 系统版本

先在 J501 设备端执行：

```bash
cat /etc/nv_tegra_release
uname -r
```

本次成功验证使用的版本为：

```text
# R36 (release), REVISION: 4.4, ...
5.15.148-tegra
```

源码、配置和 `.ko` 必须与设备正在运行的内核版本一致。不要将其他 Jetson Linux 版本构建出的模块用于该设备。

## 2. 下载完整 BSP 源码

R36.4.4 官方页面：

```text
https://developer.nvidia.com/embedded/jetson-linux-r3644
```

下载页面中的 **Driver Package (BSP) Sources**，文件名为 `public_sources.tbz2`。

当前工作区提供的脚本会先从 NVIDIA Jetson Linux Archive 查找指定版本的官方页面，再从该页面获取真实下载链接：

```bash
cd /home/seeed/bsp-workspace
./download-jetson-bsp-sources.sh R36.4.4
```

下载后的文件位置：

```text
/home/seeed/bsp-workspace/Downloads/R36.4.4/public_sources.tbz2
```

检查压缩包：

```bash
file Downloads/R36.4.4/public_sources.tbz2
tar -tjf Downloads/R36.4.4/public_sources.tbz2 >/dev/null
```

## 3. 解压完整内核源码

`public_sources.tbz2` 内部包含 `kernel_src.tbz2`，需要进行两层解压：

```bash
mkdir -p /tmp/r3644-source
tar -xjf Downloads/R36.4.4/public_sources.tbz2 \
  -C /tmp/r3644-source Linux_for_Tegra/source/kernel_src.tbz2

mkdir -p Source/R36.4.4
tar -xjf /tmp/r3644-source/Linux_for_Tegra/source/kernel_src.tbz2 \
  -C Source/R36.4.4
```

常规解压后的内核源码路径为：

```text
Source/R36.4.4/kernel/kernel-jammy-src
```

本次已经准备好的工作区使用：

```text
Source/R36.4.4/kernel-jammy-src
```

确认配置和模块构建规则：

> **作用**：这两条命令用于检查内核是否已启用 `iptable_raw` 模块配置。`rg` 是 ripgrep（快速文本搜索工具），可以类比为更强大的 grep。
>
> - **第一条**：在 arm64 默认配置文件中查找 `CONFIG_IP_NF_RAW=m`，确认 RAW 模块被编译为可加载模块（=m）。
> - **第二条**：在 IPv4 netfilter 的 Makefile 中查找相关构建规则，确认模块可以正确编译。
>
> 你可以用类似的方法查询任意内核版本的配置，例如：`rg 'CONFIG_XXX' Source/R36.4.4/kernel-jammy-src/arch/arm64/configs/defconfig`

### 内核模块编译流程（理解为什么要查这两个文件）

把编译内核模块想象成"做菜"：

| 步骤 | 做菜 | 内核编译 |
|------|------|----------|
| **第1步** | 决定要做什么菜（配置菜单） | **defconfig** - 决定启用哪些功能 |
| **第2步** | 写菜谱（怎么切、怎么炒） | **Makefile** - 定义编译规则 |
| **第3步** | 按菜谱做菜 | **make** - 执行编译 |
| **第4步** | 上桌 | **.ko 模块** - 成品 |

**完整流程**：

```
NVIDIA 提供内核源码 (kernel-jammy-src/)
        ↓
启用配置 (defconfig)：CONFIG_IP_NF_RAW=m
  └── 告诉内核"我需要这个功能"
        ↓
编译 (Makefile 定义规则)
        ↓
生成模块：iptable_raw.ko
        ↓
传到 Jetson 设备：scp
        ↓
加载模块：modprobe iptable_raw
```

**为什么要查那两个文件？**

| 文件 | 作用 | 如果没有这行配置 |
|------|------|-----------------|
| `defconfig` 有 `CONFIG_IP_NF_RAW=m` | 启用了这个功能 | 功能根本不存在，编译不出模块 |
| `Makefile` 有编译规则 | 定义如何编译 | 编译会失败 |

所以查这两个文件是**先检查"能不能做"，再决定"怎么做"**。

```bash
rg -n 'CONFIG_IP_NF_RAW=m' \
  Source/R36.4.4/kernel-jammy-src/arch/arm64/configs/defconfig
rg -n 'CONFIG_IP_NF_RAW' \
  Source/R36.4.4/kernel-jammy-src/net/ipv4/netfilter/Makefile
```

R36.4.4 的 arm64 `defconfig` 已默认启用 `CONFIG_IP_NF_RAW=m`，无需手动改为 `y` 或重新添加该配置行。

## 4. 准备交叉工具链与主机构建依赖

> **为什么需要交叉编译工具链？** 因为我们的编译机器（x86_64 PC）和目标机器（Jetson ARM64）架构不同。交叉编译工具链在 PC 上编译出能在 Jetson 上运行的代码。
>
> | 场景 | 编译机器 | 目标机器 |
> |------|----------|----------|
> | 我们现在 | x86_64 PC | ARM64 Jetson |
> | 工具链 | `aarch64-linux-gnu-gcc` | 运行在 ARM64 上 |
>
> **工具链前缀解释**：`aarch64-buildroot-linux-gnu-gcc`
>
> | 部分 | 含义 |
> |------|------|
> | `aarch64` | 目标架构（ARM64） |
> | `buildroot` | 构建系统 |
> | `linux-gnu` | Linux 系统 + GNU C 库 |
> | `gcc` | C 编译器 |
>
> **简单理解**：用 `gcc` 在 PC 上编译，给 PC 用；用 `aarch64-linux-gnu-gcc` 在 PC 上编译，给 Jetson 用。

R36.4.4 官方页面提供 Bootlin gcc 11.3 工具链：

```bash
mkdir -p toolchain
curl -fL --retry 3 --retry-delay 5 \
  -o toolchain/aarch64--glibc--stable-2022.08-1.tar.bz2 \
  https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v3.0/toolchain/aarch64--glibc--stable-2022.08-1.tar.bz2
tar -xjf toolchain/aarch64--glibc--stable-2022.08-1.tar.bz2 -C toolchain
```

工具链前缀为：

```text
/home/seeed/bsp-workspace/toolchain/aarch64--glibc--stable-2022.08-1/bin/aarch64-buildroot-linux-gnu-
```

内核配置程序需要 `flex`、`bison` 和 `m4`。PC 可以使用 sudo 时，安装方式如下：

```bash
sudo apt update
sudo apt install -y flex bison m4 libssl-dev bc
```

本工作区的构建脚本还支持使用 `tools/host/` 下的本地 `flex`、`bison`、`m4`，因此在无 sudo 环境中也可构建。

## 5. 编译模块

执行构建脚本：

```bash
cd /home/seeed/bsp-workspace
./build-iptable-raw-r36.4.4.sh
```

脚本会执行以下工作：

1. 生成 R36.4.4 的 arm64 默认内核配置。
2. 校验 `CONFIG_IP_NF_RAW=m`。
3. 设置 `CONFIG_LOCALVERSION="-tegra"`，使模块版本与 Jetson 内核匹配。
4. 编译 `Image`，生成 `vmlinux` 和模块版本符号表。
5. 同时编译 `x_tables.ko`、`ip_tables.ko`、`iptable_raw.ko`，确保模块间符号可由 `modpost` 正确解析。

目标模块输出路径：

```text
/home/seeed/bsp-workspace/Build/R36.4.4-iptable-raw/net/ipv4/netfilter/iptable_raw.ko
```

在 PC 上验证模块：

```bash
modinfo Build/R36.4.4-iptable-raw/net/ipv4/netfilter/iptable_raw.ko \
  | grep -E '^(depends|vermagic):'
```

本次构建的正确输出：

```text
depends:        x_tables,ip_tables
vermagic:       5.15.148-tegra SMP preempt mod_unload modversions aarch64
```

## 6. 上传并安装到 J501

将模块上传到 Jetson，替换 `<JETSON_IP>`：

```bash
scp Build/R36.4.4-iptable-raw/net/ipv4/netfilter/iptable_raw.ko \
  seeed@<JETSON_IP>:/tmp/
```

在 J501 设备端安装并加载：

```bash
sudo install -D -m 644 /tmp/iptable_raw.ko \
  /lib/modules/$(uname -r)/kernel/net/ipv4/netfilter/iptable_raw.ko
sudo depmod -a
sudo modprobe -v iptable_raw
```

NVIDIA 镜像通常已经带有 `x_tables.ko` 和 `ip_tables.ko`，`modprobe` 会自动加载它们。除非设备上确实缺少依赖模块，否则不应覆盖这两个系统模块。

## 7. 验证安装与加载成功

在 J501 执行：

```bash
lsmod | grep -E 'iptable_raw|ip_tables|x_tables'
sudo iptables -t raw -L -n -v
```

成功时至少应看到：

```text
iptable_raw            16384  0
```

本次 J501 的实际加载结果：

```text
iptable_raw            16384  0
ip_tables              32768  3 iptable_filter,iptable_raw,iptable_nat
x_tables               49152  11 ... iptable_raw,ip_tables ...
```

若加载失败，立即查看内核日志：

```bash
dmesg -T | tail -50
```

测试结束后可卸载模块：

```bash
sudo modprobe -r iptable_raw
```

## 8. 额外示例：编译 PL2303 USB 转串口模块

PL2303 是常见的 USB 转串口芯片。对应的内核配置和模块为：

```text
CONFIG_USB_SERIAL_PL2303=m
pl2303.ko
```

### 8.1 检查默认配置

在完整内核源码目录中执行：

```bash
rg -n '^CONFIG_USB_SERIAL_PL2303=|^# CONFIG_USB_SERIAL_PL2303' \
  Source/R36.4.4/kernel-jammy-src/arch/arm64/configs/defconfig

rg -n 'USB_SERIAL_PL2303|pl2303' \
  Source/R36.4.4/kernel-jammy-src/drivers/usb/serial/Kconfig \
  Source/R36.4.4/kernel-jammy-src/drivers/usb/serial/Makefile
```

本次检查结果如下：

```text
R36.4.4：CONFIG_USB_SERIAL=m，但未设置 CONFIG_USB_SERIAL_PL2303
R36.4.3：CONFIG_USB_SERIAL=m，但未设置 CONFIG_USB_SERIAL_PL2303
```

两版源码都包含 `drivers/usb/serial/pl2303.c`，且 Makefile 中有：

```text
obj-$(CONFIG_USB_SERIAL_PL2303) += pl2303.o
```

因此，这两个版本默认不会生成 `pl2303.ko`；需要将该选项设置为模块。

### 8.2 在 menuconfig 中开启

使用完整内核源码和与目标版本对应的构建输出目录：

```bash
make -C Source/R36.4.4-pl2303/kernel/kernel-jammy-src \
  O=Build/R36.4.4-pl2303 ARCH=arm64 menuconfig
```

按 `/`，搜索：

```text
CONFIG_USB_SERIAL_PL2303
```

在搜索结果页面按 `1` 跳转到配置项，再按空格将它设置为 `M`。保存后应得到：

```text
CONFIG_USB_SERIAL=m
CONFIG_USB_SERIAL_PL2303=m
```

也可在自动化脚本中使用内核提供的 `scripts/config`：

```bash
Source/R36.4.4-pl2303/kernel/kernel-jammy-src/scripts/config \
  --file Build/R36.4.4-pl2303/.config \
  --module USB_SERIAL_PL2303
```

### 8.3 编译 PL2303 模块

本工作区提供了已配置 R36.4.4 工具链的脚本：

```bash
cd /home/seeed/bsp-workspace
./build-pl2303-r36.4.4.sh
```

脚本会同时构建：

```text
drivers/usb/serial/usbserial.ko
drivers/usb/serial/pl2303.ko
```

`pl2303.ko` 依赖 `usbserial.ko`。构建完成后的目标文件为：

```text
/home/seeed/bsp-workspace/Build/R36.4.4-pl2303/drivers/usb/serial/pl2303.ko
```

本次实际构建已验证：

```text
CONFIG_USB_SERIAL=m
CONFIG_USB_SERIAL_PL2303=m
depends:        usbserial
vermagic:       5.15.148-tegra SMP preempt mod_unload modversions aarch64
```

### 8.4 安装和测试

将模块上传到 Jetson：

```bash
scp Build/R36.4.4-pl2303/drivers/usb/serial/pl2303.ko \
  seeed@<JETSON_IP>:/tmp/
```

如果系统中已有 `usbserial.ko`，仅安装 `pl2303.ko`：

```bash
sudo install -D -m 644 /tmp/pl2303.ko \
  /lib/modules/$(uname -r)/kernel/drivers/usb/serial/pl2303.ko
sudo depmod -a
sudo modprobe pl2303
```

插入 PL2303 设备后验证：

```bash
lsmod | grep -E 'pl2303|usbserial'
dmesg -T | tail -50
ls -l /dev/ttyUSB*
```

通常会看到 `pl2303`、`usbserial` 已加载，并出现 `/dev/ttyUSB0` 或其他 `/dev/ttyUSB*` 设备节点。
