#!/usr/bin/env bash
# Build iptable_raw.ko for Jetson Linux R36.4.4 (5.15.148-tegra).
#
# 编译流程概述：
#   1. 定义路径变量（源码位置、输出位置、工具链位置）
#   2. 前置检查（确保所有需要的文件都存在）
#   3. 设置环境变量（告诉系统用 ARM64 交叉编译器）
#   4. 配置内核（生成 .config 配置文件）
#   5. 编译内核和模块
#   6. 验证编译结果

# ========== 第1步：定义路径变量 ==========
# 获取脚本所在的目录，作为所有路径的基准
#   ${BASH_SOURCE[0]}     = 脚本自己的路径（如 /home/seeed/bsp-workspace/build-iptable-raw-r36.4.4.sh）
#   dirname "..."        = 去掉文件名，只保留目录（/home/seeed/bsp-workspace/）
#   cd ... && pwd        = 进入目录，输出绝对路径
#   $(...)               = 把命令结果赋值给变量
# 结果：workspace_dir = /home/seeed/bsp-workspace/
workspace_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 内核源码目录
kernel_source="${workspace_dir}/Source/R36.4.4/kernel-jammy-src"
# 编译输出目录（编译产物放这里）
kernel_output="${workspace_dir}/Build/R36.4.4-iptable-raw"
# 交叉编译器路径前缀（用于在 x86_64 PC 上编译 ARM64 代码）
cross_compile="${workspace_dir}/toolchain/aarch64--glibc--stable-2022.08-1/bin/aarch64-buildroot-linux-gnu-"
# 主机工具目录（flex/bison 等，用于解析内核配置语言）
#   flex/bison 是用来解析 .config 文件语法的工具
#   host 意思是"在 PC 上运行的工具"，不需要交叉编译
#   对比：toolchain 里的工具是给 Jetson (ARM64) 用的
#
# 为什么需要 flex/bison？
#   内核配置里有类似这样的语法：
#     if NETFILTER
#         if IP_NF_RAW
#             CONFIG_IP_NF_RAW=m
#         endif
#     endif
#   flex/bison 就是用来"读懂"这种语法的工具
#
#   | 目录              | 工具           | 用途                        |
#   |-------------------|----------------|-----------------------------|
#   | toolchain/...     | aarch64-gcc    | 编译 ARM64 代码（给 Jetson 用）|
#   | tools/host/bin   | flex, bison    | 解析配置（在 PC 上运行）     |
host_tools="${workspace_dir}/tools/host/bin"
# 目标模块的相对路径
module_path="net/ipv4/netfilter/iptable_raw.ko"
# 要编译的模块列表（iptable_raw 依赖 x_tables 和 ip_tables，必须一起编译）
# 为什么必须一起编译？通过三层证据确认：
#
# 1. 构建失败时的 modpost 报错
#    单独编译 iptable_raw.ko 时，报出：
#      undefined: xt_register_template   # 来自 x_tables
#      undefined: xt_hook_ops_alloc     # 来自 x_tables
#      undefined: ipt_register_table   # 来自 ip_tables
#      undefined: ipt_do_table         # 来自 ip_tables
#    xt_* 明确属于 x_tables，ipt_* 属于 ip_tables。
#
# 2. 源码中的导出符号
#    搜索符号定义位置：
#      xt_register_template, xt_hook_ops_alloc   → x_tables.c
#      ipt_register_table, ipt_do_table         → ip_tables.c
#    它们的 Makefile 目标就是：
#      net/netfilter/x_tables.ko
#      net/ipv4/netfilter/ip_tables.ko
#
# 3. 最终模块自身的依赖信息
#    编译成功后查看：
#      modinfo iptable_raw.ko | grep depends
#    实际输出：
#      depends: x_tables,ip_tables
#    所以三个模块必须在同一次 make 中编译，确保 modpost 能看到依赖模块导出的符号。
module_targets=(
    "net/netfilter/x_tables.ko"           # 依赖模块1
    "net/ipv4/netfilter/ip_tables.ko"      # 依赖模块2
    "${module_path}"                        # 目标模块
)

# ========== 第2步：前置检查（确保文件都存在） ==========
# 检查内核源码是否存在（必须有 Makefile）
[[ -f "${kernel_source}/Makefile" ]] || { echo "Kernel source is missing: ${kernel_source}" >&2; exit 1; }
# 检查交叉编译器是否存在（必须有 gcc）
[[ -x "${cross_compile}gcc" ]] || { echo "Cross compiler is missing: ${cross_compile}gcc" >&2; exit 1; }
# 检查主机工具 flex 和 bison 是否存在
[[ -x "${host_tools}/flex" && -x "${host_tools}/bison" ]] || { echo "Host flex/bison are missing: ${host_tools}" >&2; exit 1; }
# 检查 m4（宏处理器）是否存在
[[ -x "${workspace_dir}/tools/host/usr/bin/m4" ]] || { echo "Host m4 is missing." >&2; exit 1; }
# 检查 bison 支持文件是否存在
[[ -d "${workspace_dir}/tools/host/usr/share/bison" ]] || { echo "Bison support files are missing." >&2; exit 1; }

# ========== 第3步：设置环境变量 ==========
# ARCH=arm64：告诉内核构建系统，目标架构是 ARM64
export ARCH=arm64
# CROSS_COMPILE=...：指定交叉编译器前缀，让 make 能调用正确的 gcc
export CROSS_COMPILE="${cross_compile}"
# PATH：把主机工具目录加到 PATH 前面，确保优先使用
export PATH="${host_tools}:${PATH}"
# M4：指定 m4 宏处理器的路径
export M4="${workspace_dir}/tools/host/usr/bin/m4"
# BISON_PKGDATADIR：指定 bison 的数据目录（包含语法定义文件）
export BISON_PKGDATADIR="${workspace_dir}/tools/host/usr/share/bison"
# 创建输出目录
mkdir -p "${kernel_output}"

# ========== 第4步：配置内核 ==========
# make defconfig：根据 arm64 默认配置生成 .config 文件
#   什么是 .config？
#     内核源码里有成千上万个功能，但大部分不需要。
#     .config 文件用来告诉内核："我要用哪些功能，禁用哪些功能"。
#     比如：
#       CONFIG_IP_NF_RAW=m    # 启用 iptables raw 表（编译成模块）
#       CONFIG_NET=y           # 启用网络功能（编译进内核）
#       CONFIG_BLUETOOTH=n    # 禁用蓝牙（不编译）
#
#   为什么用 -C 和 O=？
#     -C = 进入这个目录（源码目录）
#     O= = 输出到这个目录（结果目录）
#     这样源码和输出分开，源码保持干净
#
#     实际过程：
#       源码目录（source）              输出目录（output）
#       ┌─────────────────┐     ┌─────────────────────────┐
#       │                 │     │  .config 文件            │
#       │   内核源码       │     │  .o 目标文件             │
#       │   （不改动）     │     │  .ko 模块文件            │
#       │                 │     │  vmlinux 内核镜像        │
#       └─────────────────┘     └─────────────────────────┘
#              ↑                          ↑
#        -C 进入这里                O= 输出到这里
#        编译过程在这里进行          编译产物在这里
#
#     简单说：
#       | 东西        | 在哪里                          |
#       |-------------|--------------------------------|
#       | 源码        | source（只读，不改动）           |
#       | .config     | output                         |
#       | .ko 模块文件 | output                         |
#       | 中间编译文件 | output                         |
#
#     打个比方：
#       source = 图书馆（书不能涂改）
#       output = 你的笔记本（可以写写画画）
#       -C = 让你去图书馆看书
#       O= = 把你的笔记写在笔记本上
#       你去图书馆看书（-C），但不在书上涂改，而是在笔记本（O=）上做记录
#
#   完整流程：
#     内核源码（几千个功能）
#           ↓ make defconfig
#     生成 .config（只启用默认需要的）
#           ↓ make olddefconfig
#     展开依赖（如果启用了 A，自动启用 A 依赖的 B）
#           ↓
#     最终 .config
#           ↓ make
#     编译内核/模块
make -C "${kernel_source}" O="${kernel_output}" defconfig
# scripts/config：修改 .config，把 LOCALVERSION 设为 "-tegra"
#   为什么要改？因为 Jetson 内核版本是 5.15.148-tegra
#   模块版本必须和内核版本匹配，否则加载会失败
#
# scripts/config 命令拆解：
#   | 部分                                       | 意思                                    |
#   |-------------------------------------------|----------------------------------------|
#   | ${kernel_source}/scripts/config          | 内核自带的配置工具（命令行版 menuconfig） |
#   | --file ${kernel_output}/.config          | 要修改哪个文件                           |
#   | --set-str LOCALVERSION "-tegra"          | 把 LOCALVERSION 设置成字符串 "-tegra"    |
#
# --set-str 是设置字符串类型的配置项
#  类似的还有：
#    --set-val  设置数字（如 CONFIG_NR_CPUS=4）
#    --set-hex  设置十六进制（如 CONFIG_FRAME_POINTER=0x1）
#    --enable   启用布尔值（如 CONFIG_NET=y）
#    --disable  禁用布尔值（如 CONFIG_BLUETOOTH=n）
"${kernel_source}/scripts/config" --file "${kernel_output}/.config" --set-str LOCALVERSION "-tegra"
# make olddefconfig：展开配置中的依赖项（如果 A 依赖 B，自动启用 B）
make -C "${kernel_source}" O="${kernel_output}" olddefconfig
# 验证配置：确保 CONFIG_IP_NF_RAW=m 被启用（=m 表示编译成模块）
grep -qx 'CONFIG_IP_NF_RAW=m' "${kernel_output}/.config" || {
    echo "R36.4.4 defconfig did not enable CONFIG_IP_NF_RAW=m." >&2
    exit 1
}
# 验证配置：确保 LOCALVERSION 是 "-tegra"
grep -qx 'CONFIG_LOCALVERSION="-tegra"' "${kernel_output}/.config" || {
    echo "Kernel local version is not set to -tegra." >&2
    exit 1
}

# ========== 第5步：编译内核和模块 ==========
# 这步的目的是把 .c 源码文件变成 .ko 模块文件
#
# 整体流程：
#   菜谱（.c 源码）
#        ↓ 编译器（gcc）
#   半成品（.o 目标文件）
#        ↓ 连接器（ld）
#   成品（.ko 模块文件）  ← 就是这个！
#
# ------------------------------------------------------------
# 5.1 准备编译环境
# ------------------------------------------------------------
# make modules_prepare
#
# 打个比方：
#   编译模块就像"做一道菜"
#   做菜之前要先把厨房准备好：
#   - 打开煤气灶
#   - 准备好锅碗瓢盆
#   - 调味料摆好
#
# modules_prepare 就是"打开厨房"：
#   - 生成编译模块需要的中间文件
#   - 不实际编译，只是准备工作
#
# 为什么必须先做这步？
#   因为后面编译模块时，需要用到内核的一些符号表文件
#   （vmlinux.symvers），这些文件在 modules_prepare 时生成
make -C "${kernel_source}" O="${kernel_output}" -j"$(nproc)" modules_prepare

# ------------------------------------------------------------
# 5.2 编译内核镜像 Image
# ------------------------------------------------------------
# make Image
#
# 什么是 Image？
#   Image = Linux 内核本身（就像 Windows 的 ntoskrnl.exe）
#   编译成功后会在输出目录生成 vmlinux 文件
#
# 打个比方：
#   Image = 主菜（比如红烧肉）
#   modules = 配菜（比如凉拌黄瓜、酸辣土豆丝）
#   必须先做好主菜，因为配菜要摆盘在主菜旁边
#
# 为什么必须先编译 Image？
#   编译模块时需要检查"模块和内核是否匹配"
#   检查的依据是 Image 里的符号表（vmlinux.symvers）
#   这个符号表记录了内核提供了哪些函数
#
#   模块（比如 iptable_raw）会调用内核函数
#   必须确保模块调用的函数在内核里存在
#   所以必须先有 Image，才能编译模块
make -C "${kernel_source}" O="${kernel_output}" -j"$(nproc)" Image

# ------------------------------------------------------------
# 5.3 编译模块
# ------------------------------------------------------------
# make <模块路径>
#
# 什么是模块？
#   模块 = 可加载的内核扩展
#   平时在内核外，需要时加载进去
#   比如 iptable_raw 就是这样一个模块
#
# 编译的是什么？
#   module_targets 数组里定义的三个模块：
#     1. x_tables.ko       # iptables 的底层框架
#     2. ip_tables.ko      # IPv4 防火墙表
#     3. iptable_raw.ko    # 我们的目标模块
#
# -j"$(nproc)" 是什么意思？
#   -j = jobs，并行编译
#   $(nproc) = 你的 CPU 核心数
#   -j8 表示用8个核心同时编译，速度更快
#
# 为什么要三个模块一起编译？
#   因为 iptable_raw 依赖另外两个模块
#   如果分开编译，后面的模块找不到前面的符号会报错
#   一起编译的话，编译器能看到所有模块的符号，不会报错
make -C "${kernel_source}" O="${kernel_output}" -j"$(nproc)" "${module_targets[@]}"

# ========== 第6步：验证编译结果 ==========
# 拼接完整路径
result="${kernel_output}/${module_path}"
# 检查模块文件是否生成
[[ -f "${result}" ]] || { echo "Build did not produce ${result}" >&2; exit 1; }
# file：查看文件类型（应该是 ELF 64-bit LSB relocatable）
file "${result}"
# modinfo：显示模块信息（依赖、许可证、版本等）
modinfo "${result}" | rg '^(filename|license|description|depends|vermagic):'
# 打印成功信息
echo "Built module: ${result}"

# ========== 附录：为什么必须 modules_prepare？ ==========
#
# 正常编译流程（不需要 modules_prepare）：
#   cd /path/to/kernel-source
#   make defconfig
#   make Image              # ← Image 和符号表一起出来
#   make modules            # ← 直接编译模块
#
# 我们的流程（用了 O= 分离）：
#   make modules_prepare     # ← 先准备
#   make Image              # ← 再编译
#   make xxx.ko             # ← 最后模块
#
# 为什么必须 modules_prepare？
#   因为我们用了 O= 把输出目录和源码分开
#   编译系统需要知道"要编译模块了"，才会生成模块需要的文件
#   modules_prepare 就是那个"通知"
#
# 生成的文件：
#   | 文件               | 什么时候生成       | 干什么用                           |
#   |--------------------|-------------------|-----------------------------------|
#   | vmlinux.symvers   | 编译 Image 时      | 内核导出的符号（给模块用）          |
#   | Module.symvers    | modules_prepare 时  | 模块需要的符号（检查依赖）           |
#
# 简单说：
#   modules_prepare = "通知编译器：我要编译模块了，请准备好"
#   然后 make Image = 编译内核，顺便生成符号表
#   最后 make xxx.ko = 编译模块
#
# 如果不用 O= 分离源码和输出？
#   cd ${kernel_source}
#   make defconfig
#   make Image              # vmlinux.symvers 马上就有
#   make modules            # 直接编译，不需要 modules_prepare！
#
# 总结：
#   不用 O= → 直接 make Image → make modules（不需要 modules_prepare）
#   用 O=   → 必须先 modules_prepare → make Image → make modules
#                       ↑
#               因为 O= 分离了输出目录
#               需要单独"通知"编译系统要编译模块
