"""
firmware_build.py - Jetson 固件编译/烧录核心逻辑

支持两种工作流:
1. Seeed reComputer BSP: 使用 l4t_initrd_flash.sh 烧录
2. DIY Hybrid BSP: DevKit → reComputer 混合固件

所有路径相对于 workspace 根目录。
"""

from __future__ import annotations
import subprocess
import os
import re
import time
import json
import shutil
from pathlib import Path
from typing import Optional, Callable, Dict, List, Tuple
from dataclasses import dataclass, field
from enum import Enum

WORKSPACE = Path("/media/seeed/bsp-ssd1/bsp-workspace")
DOWNLOAD_DIR = WORKSPACE / "Downloads"
SOURCE_DIR = WORKSPACE / "Source"
FLASH_WS_DIR = WORKSPACE / "FlashWorkspace"


# =============================================================================
# Data Models
# =============================================================================

class BuildStage(str, Enum):
    """编译阶段"""
    IDLE = "idle"
    PREPARE = "prepare"
    BUILD = "build"
    FLASH = "flash"
    CLEANUP = "cleanup"
    BACKUP = "backup"
    ASSEMBLE = "assemble"


@dataclass
class FlashDevice:
    """烧录设备信息"""
    vendor_id: str
    product_id: str
    description: str
    connected: bool = True


@dataclass
class BuildProgress:
    """构建进度"""
    stage: BuildStage
    message: str
    percentage: int = 0
    details: Dict = field(default_factory=dict)
    error: Optional[str] = None
    done: bool = False


@dataclass
class BoardConfig:
    """板子配置"""
    name: str
    board_id: str
    board_sku: str
    fab: str
    board_rev: str
    chip_sku: str
    flash_type: str = "internal"  # internal / nvme0n1p1
    pinmux: str = ""
    camera_overlay: str = ""
    notes: str = ""


# Seeed reComputer Orin 板子配置
KNOWN_BOARDS = {
    "recomputer-thor-carrier-j601": BoardConfig(
        name="recomputer-thor-carrier-j601",
        board_id="3767",
        board_sku="0005",
        fab="300",
        board_rev="V.2",
        chip_sku="00:00:00:D5",
        flash_type="nvme0n1p1",
        pinmux="tegra234-mb1-bct-pinmux-p3767-hdmi-a03.dtsi",
        notes="Thor 载板 (J601)",
    ),
    "recomputer-orin-j401": BoardConfig(
        name="recomputer-orin-j401",
        board_id="3767",
        board_sku="0005",
        fab="300",
        board_rev="V.2",
        chip_sku="00:00:00:D5",
        flash_type="nvme0n1p1",
        pinmux="tegra234-mb1-bct-pinmux-p3767-hdmi-a03.dtsi",
        camera_overlay="tegra234-p3767-camera-p3768-imx219-dual-seeed.dtbo",
        notes="reComputer Classic (J4011/J4012)",
    ),
    "recomputer-orin-super-j401": BoardConfig(
        name="recomputer-orin-super-j401",
        board_id="3767",
        board_sku="0005",
        fab="300",
        board_rev="V.2",
        chip_sku="00:00:00:D5",
        flash_type="nvme0n1p1",
        pinmux="tegra234-mb1-bct-pinmux-p3767-hdmi-a03.dtsi",
        camera_overlay="tegra234-p3767-camera-p3768-imx219-quad-seeed.dtbo",
        notes="reComputer Super (J401)",
    ),
    "jetson-orin-nano-devkit-nvme": BoardConfig(
        name="jetson-orin-nano-devkit-nvme",
        board_id="3767",
        board_sku="0005",
        fab="300",
        board_rev="V.2",
        chip_sku="00:00:00:D5",
        flash_type="nvme0n1p1",
        notes="Orin Nano Developer Kit",
    ),
    "jetson-agx-thor-devkit": BoardConfig(
        name="jetson-agx-thor-devkit",
        board_id="3834",
        board_sku="0008",
        fab="400",
        board_rev="G.5",
        chip_sku="00:00:00:A0",
        flash_type="internal",
        notes="NVIDIA Jetson AGX Thor Developer Kit",
    ),
}


# =============================================================================
# Shell Helpers
# =============================================================================

def _run_shell(
    cmd: str,
    cwd: str = None,
    timeout: int = 300,
    env: Dict = None,
    on_line: Callable[[str], None] = None,
) -> Tuple[str, str, int]:
    """
    执行 shell 命令，返回 (stdout, stderr, returncode)。
    如果提供 on_line 回调，每行输出实时回调。
    """
    merge_env = os.environ.copy()
    if env:
        merge_env.update(env)

    try:
        proc = subprocess.Popen(
            cmd,
            shell=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            cwd=cwd or str(WORKSPACE),
            env=merge_env,
            text=True,
        )

        stdout_lines = []
        for line in iter(proc.stdout.readline, ""):
            if not line:
                break
            line = line.rstrip()
            stdout_lines.append(line)
            if on_line:
                on_line(line)

        proc.wait()
        return "\n".join(stdout_lines), "", proc.returncode

    except subprocess.TimeoutExpired:
        proc.kill()
        return "", "Command timed out", 124
    except Exception as e:
        return "", str(e), 1


def _run_sudo(
    cmd: str,
    cwd: str = None,
    timeout: int = 300,
    env: Dict = None,
    on_line: Callable[[str], None] = None,
) -> Tuple[str, str, int]:
    """带 sudo 执行命令"""
    sudo_cmd = f"sudo {cmd}"
    return _run_shell(sudo_cmd, cwd, timeout, env, on_line)


def _check_lsusb(vendor_id: str) -> List[str]:
    """检查 lsusb 是否有指定 VID 的设备，返回匹配的设备列表"""
    out, _, rc = _run_shell("lsusb", timeout=5)
    if rc != 0:
        return []
    return [line for line in out.splitlines() if vendor_id in line]


# =============================================================================
# L4T Workspace Detection
# =============================================================================

_KERNEL_SRC_DIR_NAMES = ("kernel-noble", "kernel-jammy-src", "kernel_src", "kernel")


def find_kernel_src_dir(l4t_root: Path) -> Optional[str]:
    """探测 L4T 目录中实际存在的内核源码目录名 (kernel-noble / kernel-jammy-src / kernel_src / kernel)。

    不同 L4T 分支的内核目录名不同: R39.x 用 kernel-noble, R36.x 及更早用
    kernel-jammy-src (或 kernel_src)。按优先级探测, 返回第一个含 Makefile 的。
    """
    kernel_root = l4t_root / "source" / "kernel"
    if not kernel_root.is_dir():
        return None
    for name in _KERNEL_SRC_DIR_NAMES:
        if (kernel_root / name / "Makefile").is_file():
            return name
    return None


def get_l4t_branch(l4t_root: Path) -> str:
    """返回 L4T 目录当前检出的 git 分支名; 非 git 仓库或失败时返回空串"""
    out, _, rc = _run_shell(f"git -C {l4t_root} rev-parse --abbrev-ref HEAD 2>/dev/null", timeout=5)
    if rc != 0:
        return ""
    return out.strip().splitlines()[-1] if out.strip() else ""


def _is_l4t_workspace(p: Path) -> bool:
    """判断是否为完整的 Linux_for_Tegra 工作目录 (跨分支)。

    - R39.x 分支: 根目录有 apply_binaries.sh
    - R36.x 及更早分支: 无 apply_binaries.sh, 但有 source/ 与 bootloader/
    """
    if not p.exists():
        return False
    if (p / "apply_binaries.sh").is_file():
        return True
    return (p / "source").is_dir() and (p / "bootloader").is_dir()


def find_l4t_workspace() -> Optional[Path]:
    """查找 Linux_for_Tegra 工作目录"""
    candidates = [
        WORKSPACE / "Linux_for_Tegra",
        FLASH_WS_DIR / "linux_for_tegra",
        DOWNLOAD_DIR / "Linux_for_Tegra",
        SOURCE_DIR / "Linux_for_Tegra",
    ]
    for p in candidates:
        if _is_l4t_workspace(p):
            return p
    return None


def get_available_boards(l4t_root: Path) -> List[str]:
    """获取 L4T 目录中可用的板子配置"""
    if not l4t_root:
        return []
    configs = []
    for f in l4t_root.glob("*.conf"):
        configs.append(f.stem)
    return sorted(configs)


# =============================================================================
# Recovery Mode Detection
# =============================================================================

def check_recovery_mode() -> Dict[str, FlashDevice]:
    """
    检测所有可能的 Jetson Recovery 设备。

    常见 VID:PID:
    - 0955:7045 - Jetson AGX Thor
    - 0955:7523 - Jetson Orin Nano/NX
    - 0955:7c19 - Jetson AGX Orin
    - 0955:7145 - Jetson TX2 NX
    """
    known_devices = {
        "0955:7045": ("NVIDIA Jetson AGX Thor", "thor"),
        "0955:7523": ("NVIDIA Jetson Orin Nano/NX", "orin"),
        "0955:7c19": ("NVIDIA Jetson AGX Orin", "orin_agx"),
        "0955:7145": ("NVIDIA Jetson TX2 NX", "tx2"),
    }

    result = {}
    for vid_pid, (desc, dev_type) in known_devices.items():
        matches = _check_lsusb(vid_pid)
        if matches:
            for match in matches:
                device = FlashDevice(
                    vendor_id=vid_pid.split(":")[0],
                    product_id=vid_pid.split(":")[1],
                    description=desc,
                    connected=True,
                )
                result[dev_type] = device

    return result


# =============================================================================
# L4T Build Commands
# =============================================================================

def build_firmware(
    board_name: str,
    stage: BuildStage,
    on_progress: Callable[[BuildProgress], None] = None,
    **kwargs,
) -> Tuple[bool, str]:
    """
    通用 L4T 固件编译函数。

    Args:
        board_name: 板子配置名 (如 recomputer-orin-j401)
        stage: 执行阶段
        on_progress: 进度回调
        **kwargs: 额外参数 (flash_type 等)
    """
    def emit(stage: BuildStage, message: str, pct: int = 0, details: Dict = None):
        if on_progress:
            on_progress(BuildProgress(
                stage=stage,
                message=message,
                percentage=pct,
                details=details or {},
            ))

    # 1. 定位 L4T 工作目录
    emit(stage, "查找 Linux_for_Tegra 工作目录...")
    l4t_root = find_l4t_workspace()

    if not l4t_root:
        return False, "错误: 未找到 Linux_for_Tegra 目录"

    if not _is_l4t_workspace(l4t_root):
        return False, f"错误: {l4t_root} 不是有效的 L4T 目录"

    emit(stage, f"找到 L4T 目录: {l4t_root}", 10)

    # 2. 获取板子配置
    config = KNOWN_BOARDS.get(board_name)
    if not config:
        # 尝试从配置文件中读取
        config_file = l4t_root / f"{board_name}.conf"
        if config_file.exists():
            config = BoardConfig(
                name=board_name,
                board_id=kwargs.get("board_id", "3767"),
                board_sku=kwargs.get("board_sku", "0005"),
                fab=kwargs.get("fab", "300"),
                board_rev=kwargs.get("board_rev", "V.2"),
                chip_sku=kwargs.get("chip_sku", "00:00:00:D5"),
                flash_type=kwargs.get("flash_type", "nvme0n1p1"),
            )
        else:
            return False, f"未知板子配置: {board_name}"

    # 3. 根据阶段执行
    if stage == BuildStage.PREPARE:
        return _l4t_prepare(l4t_root, config, emit)

    elif stage == BuildStage.BUILD:
        return _l4t_build(l4t_root, config, emit)

    elif stage == BuildStage.FLASH:
        return _l4t_flash(l4t_root, config, emit, **kwargs)

    elif stage == BuildStage.CLEANUP:
        return _l4t_cleanup(l4t_root, emit)

    return False, f"未知阶段: {stage}"


def _l4t_prepare(l4t_root: Path, config: BoardConfig, emit) -> Tuple[bool, str]:
    """L4T prepare: 解压 rootfs + apply_binaries"""
    emit(BuildStage.PREPARE, "检查 rootfs...", 20)

    rootfs_dir = l4t_root / "rootfs"
    if rootfs_dir.exists() and (rootfs_dir / "etc").exists():
        emit(BuildStage.PREPARE, "rootfs 已存在", 30)
    else:
        # 检查是否有 rootfs.tar.bz2
        rootfs_tar = l4t_root / "rootfs.tar.bz2"
        if rootfs_tar.exists():
            emit(BuildStage.PREPARE, "解压 rootfs...", 40)
            rc = subprocess.run(
                f"sudo tar xpf '{rootfs_tar}' -C '{l4t_root}/'",
                shell=True, cwd=str(l4t_root)
            ).returncode
            if rc != 0:
                return False, "rootfs 解压失败"
        else:
            emit(BuildStage.PREPARE, "未找到 rootfs.tar.bz2，尝试查找其他格式...", 30)
            for pattern in ["*.tar.gz", "*.tgz", "*.tbz2"]:
                tars = list(l4t_root.glob(pattern))
                if tars:
                    emit(BuildStage.PREPARE, f"找到 {tars[0].name}", 35)
                    break

    # apply_binaries
    emit(BuildStage.PREPARE, "执行 apply_binaries.sh...", 70)
    if (l4t_root / "apply_binaries.sh").exists():
        rc = subprocess.run(
            "sudo ./apply_binaries.sh",
            shell=True, cwd=str(l4t_root)
        ).returncode
        if rc != 0:
            emit(BuildStage.PREPARE, "警告: apply_binaries.sh 返回非零", 80)
        else:
            emit(BuildStage.PREPARE, "apply_binaries.sh 完成", 90)

    emit(BuildStage.PREPARE, "prepare 完成!", 100)
    return True, "prepare 完成"


def _l4t_build(l4t_root: Path, config: BoardConfig, emit) -> Tuple[bool, str]:
    """L4T build: 编译内核"""
    emit(BuildStage.BUILD, "检查内核源码...", 20)

    source_dir = l4t_root / "source"
    if not source_dir.exists():
        return False, "错误: source 目录不存在"

    # 检查内核编译脚本
    nvbuild = source_dir / "nvbuild.sh"
    if not nvbuild.exists():
        return False, "错误: nvbuild.sh 不存在"

    # 设置编译环境
    emit(BuildStage.BUILD, "设置交叉编译环境...", 30)

    toolchain_candidates = [
        l4t_root / "aarch64--glibc--stable-2022.08-1",
        l4t_root / "gcc-linaro-7.3.1-2018.05-x86_64_aarch64-linux-gnu",
        l4t_root / "toolchains",
    ]

    toolchain = None
    for tc in toolchain_candidates:
        if tc.exists():
            toolchain = tc
            break

    if toolchain:
        emit(BuildStage.BUILD, f"使用工具链: {toolchain.name}", 40)
    else:
        emit(BuildStage.BUILD, "警告: 未找到预编译工具链，使用系统工具链", 40)

    # 执行编译
    emit(BuildStage.BUILD, "开始编译内核...", 50)

    build_env = os.environ.copy()
    if toolchain:
        tc_bin = list(toolchain.glob("bin/*-gcc"))[0].parent if list(toolchain.glob("bin/*-gcc")) else toolchain / "bin"
        build_env["CROSS_COMPILE"] = f"{tc_bin}/aarch64-linux-gnu-"
        build_env["PATH"] = f"{tc_bin}:{build_env.get('PATH', '')}"
    build_env["ARCH"] = "arm64"

    def on_line(line):
        emit(BuildStage.BUILD, line, 60)

    rc = subprocess.run(
        "./nvbuild.sh",
        shell=True, cwd=str(source_dir), env=build_env
    ).returncode

    if rc != 0:
        return False, "内核编译失败"

    # do_copy
    do_copy = source_dir / "do_copy.sh"
    if do_copy.exists():
        emit(BuildStage.BUILD, "复制内核到 rootfs...", 90)
        subprocess.run(f"sudo ./{do_copy.name}", shell=True, cwd=str(source_dir))

    emit(BuildStage.BUILD, "内核编译完成!", 100)
    return True, "build 完成"


def _l4t_flash(
    l4t_root: Path,
    config: BoardConfig,
    emit,
    **kwargs
) -> Tuple[bool, str]:
    """L4T flash: 烧录固件"""
    emit(BuildStage.FLASH, "检查 Recovery 模式...", 10)

    devices = check_recovery_mode()
    if not devices:
        return False, (
            "错误: 未检测到 Recovery 设备\n"
            "请确保设备已进入 Recovery 模式:\n"
            "  1. 关闭设备电源\n"
            "  2. 连接 USB Type-C 到主机\n"
            "  3. 按住 Force Recovery 键\n"
            "  4. 按 Power 键开机\n"
            "  5. 运行 'lsusb' 检查设备"
        )

    # 选择设备
    device_type = "thor" if "thor" in config.name.lower() else "orin"
    device = devices.get(device_type) or devices.get(list(devices.keys())[0])

    emit(BuildStage.FLASH, f"检测到 {device.description}", 20)

    # 构建烧录命令
    flash_type = kwargs.get("flash_type", config.flash_type)
    chip_sku_clean = config.chip_sku.replace(":", "")

    env = {
        "BOARDID": config.board_id,
        "BOARDSKU": config.board_sku,
        "FAB": config.fab,
        "BOARDREV": config.board_rev,
        "CHIP_SKU": chip_sku_clean,
    }

    emit(BuildStage.FLASH, f"板子配置: {config.name}", 30)

    # 根据 flash_type 构建命令
    if flash_type == "internal":
        # Thor 等使用内部 flash
        cmd = (
            f"sudo BOARDID={env['BOARDID']} BOARDSKU={env['BOARDSKU']} "
            f"FAB={env['FAB']} BOARDREV={env['BOARDREV']} "
            f"CHIP_SKU={env['CHIP_SKU']} "
            f"./tools/kernel_flash/l4t_initrd_flash.sh "
            f"--erase-all {config.name} internal"
        )
    else:
        # Orin 等使用外部设备 (NVMe)
        cmd = (
            f"sudo BOARDID={env['BOARDID']} BOARDSKU={env['BOARDSKU']} "
            f"FAB={env['FAB']} BOARDREV={env['BOARDREV']} "
            f"CHIP_SKU={env['CHIP_SKU']} "
            f"./tools/kernel_flash/l4t_initrd_flash.sh "
            f"--external-device {flash_type} "
            f"-c tools/kernel_flash/flash_l4t_t234_nvme.xml "
            f"--erase-all {config.name} {flash_type}"
        )

    emit(BuildStage.FLASH, "开始烧录...", 50)

    def on_line(line):
        emit(BuildStage.FLASH, line, 60)
        if "RCM" in line:
            emit(BuildStage.FLASH, "设备进入 RCM 模式...", 70)
        elif "Flashing" in line or "flash" in line.lower():
            emit(BuildStage.FLASH, "正在烧录镜像...", 80)

    full_env = os.environ.copy()
    full_env.update(env)
    out, err, rc = _run_shell(cmd, cwd=str(l4t_root), env=full_env,
                                on_line=on_line, timeout=600)

    if rc != 0:
        # 检查是否有常见错误
        if "Permission denied" in out:
            return False, "权限不足，请确保以 sudo 运行"
        if "No such file" in out:
            return False, f"配置文件不存在: {config.name}.conf"
        return False, f"烧录失败 (exit {rc}): {out[-500:]}"

    emit(BuildStage.FLASH, "烧录完成!", 100)
    return True, "烧录成功! 请断开 Recovery 模式并重启设备。"


def _l4t_cleanup(l4t_root: Path, emit) -> Tuple[bool, str]:
    """L4T cleanup: 清理构建产物"""
    emit(BuildStage.CLEANUP, "清理构建产物...", 30)

    patterns = [
        "output", "bootloader/*.img", "bootloader/system.img*",
        "bootloader/esp.img*", "bootloader/recovery.img*",
        "bootloader/boot*.img",
    ]

    for pattern in patterns:
        subprocess.run(f"rm -rf {pattern}", shell=True, cwd=str(l4t_root))

    emit(BuildStage.CLEANUP, "清理完成!", 100)
    return True, "清理完成"


# =============================================================================
# DIY Hybrid BSP Flow (DevKit → reComputer)
# =============================================================================

def hybrid_backup(
    source_board: str,
    on_progress: Callable[[BuildProgress], None] = None,
) -> Tuple[bool, str]:
    """
    备份 DevKit 全量环境。
    """
    def emit(stage: BuildStage, message: str, pct: int = 0, details: Dict = None):
        if on_progress:
            on_progress(BuildProgress(
                stage=stage,
                message=message,
                percentage=pct,
                details=details or {},
            ))

    emit(BuildStage.BACKUP, "=== DevKit 备份流程 ===", 0)

    # 1. 查找 L4T 目录
    l4t_root = find_l4t_workspace()
    if not l4t_root:
        return False, "错误: 未找到 Linux_for_Tegra 目录"

    # 2. 检查 Recovery 模式
    emit(BuildStage.BACKUP, "检查 Recovery 模式...", 10)
    devices = check_recovery_mode()
    if not devices:
        return False, (
            "错误: 未检测到 DevKit Recovery 设备。\n"
            "请确保 DevKit 已进入 Recovery 模式:\n"
            "lsusb 应显示 0955:7523 NVIDIA Corp. APX"
        )

    emit(BuildStage.BACKUP, f"检测到 Recovery 设备: {list(devices.values())[0].description}", 20)

    # 3. 执行备份
    emit(BuildStage.BACKUP, "开始备份 (可能需要几分钟)...", 30)

    backup_script = l4t_root / "tools" / "backup_restore" / "l4t_backup_restore.sh"
    if not backup_script.exists():
        return False, f"错误: 备份脚本不存在: {backup_script}"

    # 确定外部设备
    flash_device = "nvme0n1"
    # 检查是否有 NVMe
    out, _, _ = _run_shell("lsblk -d -n -o NAME,TYPE | grep nvme", timeout=5)
    if "nvme" not in out:
        flash_device = "mmcblk0"
        emit(BuildStage.BACKUP, "未检测到 NVMe，使用 eMMC", 25)

    cmd = (
        f"./tools/backup_restore/l4t_backup_restore.sh "
        f"-e {flash_device} "
        f"-b "           # backup 模式
        f"-c {source_board}"
    )

    def on_line(line):
        emit(BuildStage.BACKUP, line, 50)
        if "Creating" in line or "备份" in line:
            emit(BuildStage.BACKUP, "正在创建备份镜像...", 70)
        elif "QSPI" in line:
            emit(BuildStage.BACKUP, "正在备份 QSPI...", 85)

    out, err, rc = _run_shell(cmd, cwd=str(l4t_root), on_line=on_line, timeout=600)

    if rc != 0:
        return False, f"备份失败: {err or out[-500:]}"

    # 4. 验证备份
    emit(BuildStage.BACKUP, "验证备份...", 90)
    images_dir = l4t_root / "tools" / "backup_restore" / "images"

    required_files = ["nvpartitionmap.txt"]
    missing = [f for f in required_files if not (images_dir / f).exists()]
    if missing:
        return False, f"备份验证失败: 缺少文件 {missing}"

    # 统计备份大小
    total_size = sum(
        f.stat().st_size for f in images_dir.rglob("*")
        if f.is_file()
    )
    size_gb = round(total_size / 1024**3, 2)

    emit(BuildStage.BACKUP, f"备份完成! 总大小: {size_gb} GB", 100)

    return True, f"备份完成，大小 {size_gb} GB"


def hybrid_prepare_app_only(
    target_board: str,
    on_progress: Callable[[BuildProgress], None] = None,
) -> Tuple[bool, str]:
    """
    准备 APP-only 备份 (移除 DevKit QSPI)。
    """
    def emit(stage: BuildStage, message: str, pct: int = 0, details: Dict = None):
        if on_progress:
            on_progress(BuildProgress(
                stage=stage,
                message=message,
                percentage=pct,
                details=details or {},
            ))

    l4t_root = find_l4t_workspace()
    if not l4t_root:
        return False, "错误: 未找到 Linux_for_Tegra 目录"

    emit(BuildStage.PREPARE, "准备 APP-only 备份...", 10)

    images_dir = l4t_root / "tools" / "backup_restore" / "images"
    app_only_dir = l4t_root / "tools" / "backup_restore" / "images_app_only"

    if not images_dir.exists():
        return False, "错误: 备份目录不存在，请先执行备份"

    # 1. 复制备份到 APP-only 目录
    if app_only_dir.exists():
        shutil.rmtree(app_only_dir)

    emit(BuildStage.PREPARE, "复制备份文件...", 30)
    shutil.copytree(images_dir, app_only_dir)

    # 2. 移除 DevKit QSPI
    emit(BuildStage.PREPARE, "移除 DevKit QSPI...", 50)
    qspi_file = app_only_dir / "QSPI0.img"
    if qspi_file.exists():
        qspi_file.unlink()
        emit(BuildStage.PREPARE, "已移除 QSPI0.img", 60)

    # 3. 编辑分区表移除 QSPI 条目
    part_map = app_only_dir / "nvpartitionmap.txt"
    if part_map.exists():
        content = part_map.read_text()
        lines = [l for l in content.splitlines() if "qspi" not in l.lower()]
        part_map.write_text("\n".join(lines))
        emit(BuildStage.PREPARE, "已更新分区表", 80)

    emit(BuildStage.PREPARE, "APP-only 准备完成!", 100)
    return True, "APP-only 备份准备完成"


def hybrid_generate_qspi(
    target_board: str,
    board_config: BoardConfig = None,
    on_progress: Callable[[BuildProgress], None] = None,
) -> Tuple[bool, str]:
    """
    生成目标板 QSPI。
    """
    def emit(stage: BuildStage, message: str, pct: int = 0, details: Dict = None):
        if on_progress:
            on_progress(BuildProgress(
                stage=stage,
                message=message,
                percentage=pct,
                details=details or {},
            ))

    l4t_root = find_l4t_workspace()
    if not l4t_root:
        return False, "错误: 未找到 Linux_for_Tegra 目录"

    # 检查 Recovery 模式
    emit(BuildStage.BUILD, "检查 Recovery 模式...", 10)
    devices = check_recovery_mode()
    if not devices:
        return False, "错误: 需要目标板进入 Recovery 模式"

    emit(BuildStage.BUILD, f"检测到 Recovery 设备", 20)

    # 获取配置
    if not board_config:
        board_config = KNOWN_BOARDS.get(target_board)
        if not board_config:
            return False, f"未知目标板: {target_board}"

    # 构建命令
    env = {
        "BOARDID": board_config.board_id,
        "BOARDSKU": board_config.board_sku,
        "FAB": board_config.fab,
        "BOARDREV": board_config.board_rev,
        "CHIP_SKU": board_config.chip_sku.replace(":", ""),
    }

    cmd = (
        f"sudo BOARDID={env['BOARDID']} BOARDSKU={env['BOARDSKU']} "
        f"FAB={env['FAB']} BOARDREV={env['BOARDREV']} "
        f"CHIP_SKU={env['CHIP_SKU']} "
        f"./tools/kernel_flash/l4t_initrd_flash.sh "
        f"--external-device nvme0n1p1 "
        f"-c tools/kernel_flash/flash_l4t_t234_nvme.xml "
        f'-p "-c bootloader/generic/cfg/flash_t234_qspi.xml --no-systemimg" '
        f"--no-flash --massflash 5 --showlogs --network usb0 "
        f"{target_board} internal"
    )

    emit(BuildStage.BUILD, "生成目标板 QSPI...", 30)

    def on_line(line):
        emit(BuildStage.BUILD, line, 50)
        if "pinmux" in line.lower():
            emit(BuildStage.BUILD, f"检测到配置: {line}", 60)
        elif "internal" in line.lower():
            emit(BuildStage.BUILD, "正在生成内部镜像...", 80)

    full_env = os.environ.copy()
    full_env.update(env)
    out, err, rc = _run_shell(cmd, cwd=str(l4t_root), env=full_env,
                               on_line=on_line, timeout=600)

    if rc != 0:
        return False, f"QSPI 生成失败: {err or out[-500:]}"

    # 验证生成的文件
    internal_dir = l4t_root / "tools" / "kernel_flash" / "images" / "internal"
    if internal_dir.exists() and any(internal_dir.glob("*")):
        emit(BuildStage.BUILD, "QSPI 生成成功!", 100)
        return True, "目标板 QSPI 生成完成"

    return False, "QSPI 生成验证失败"


def hybrid_assemble_mfi(
    target_board: str,
    on_progress: Callable[[BuildProgress], None] = None,
) -> Tuple[bool, str]:
    """
    组装混合 BSP mfi 包。
    """
    def emit(stage: BuildStage, message: str, pct: int = 0, details: Dict = None):
        if on_progress:
            on_progress(BuildProgress(
                stage=stage,
                message=message,
                percentage=pct,
                details=details or {},
            ))

    l4t_root = find_l4t_workspace()
    if not l4t_root:
        return False, "错误: 未找到 Linux_for_Tegra 目录"

    emit(BuildStage.ASSEMBLE, "组装 Hybrid mfi...", 10)

    mfi_dir = l4t_root / f"mfi_{target_board}"
    internal_dir = l4t_root / "tools" / "kernel_flash" / "images" / "internal"
    external_dir = l4t_root / "tools" / "backup_restore" / "images_app_only"

    # 1. 创建 mfi 目录结构
    mfi_dir.mkdir(parents=True, exist_ok=True)

    # 2. 复制目标板配置
    emit(BuildStage.ASSEMBLE, "复制目标板配置...", 30)
    target_conf = l4t_root / f"{target_board}.conf"
    if target_conf.exists():
        shutil.copy(target_conf, mfi_dir / f"{target_board}.conf")
    else:
        return False, f"错误: 未找到 {target_board}.conf"

    # 3. 复制 QSPI (新生成的目标板 QSPI)
    emit(BuildStage.ASSEMBLE, "复制 QSPI...", 50)
    mfi_internal = mfi_dir / "tools" / "kernel_flash" / "images" / "internal"
    mfi_internal.mkdir(parents=True, exist_ok=True)
    if internal_dir.exists():
        for f in internal_dir.glob("*"):
            if f.is_file():
                shutil.copy(f, mfi_internal / f.name)
    else:
        return False, "错误: 未找到生成的 QSPI，请先执行 '生成 QSPI'"

    # 4. 复制 APP (DevKit 备份的 APP-only)
    emit(BuildStage.ASSEMBLE, "复制 APP...", 70)
    mfi_external = mfi_dir / "tools" / "kernel_flash" / "images" / "external"
    mfi_external.mkdir(parents=True, exist_ok=True)
    if external_dir.exists():
        for f in external_dir.glob("*"):
            if f.is_file() and "QSPI" not in f.name:
                shutil.copy(f, mfi_external / f.name)
    else:
        return False, "错误: 未找到 APP-only 备份，请先执行 '准备 APP'"

    # 5. 打包
    emit(BuildStage.ASSEMBLE, "打包 mfi...", 90)
    archive_path = l4t_root / f"mfi_{target_board}.tar.gz"

    result = subprocess.run(
        f"tar czf '{archive_path}' {mfi_dir.name}",
        shell=True, cwd=str(l4t_root)
    )

    if result.returncode != 0:
        return False, "打包失败"

    size_mb = round(archive_path.stat().st_size / 1024**2, 1)
    emit(BuildStage.ASSEMBLE, f"打包完成: {archive_path.name} ({size_mb} MB)", 100)

    return True, f"Hybrid mfi 打包完成: {archive_path}"


def hybrid_flash(
    target_board: str,
    on_progress: Callable[[BuildProgress], None] = None,
) -> Tuple[bool, str]:
    """
    烧录 Hybrid mfi 到目标板。
    """
    def emit(stage: BuildStage, message: str, pct: int = 0, details: Dict = None):
        if on_progress:
            on_progress(BuildProgress(
                stage=stage,
                message=message,
                percentage=pct,
                details=details or {},
            ))

    l4t_root = find_l4t_workspace()
    if not l4t_root:
        return False, "错误: 未找到 Linux_for_Tegra 目录"

    # 检查 Recovery
    emit(BuildStage.FLASH, "检查 Recovery 模式...", 10)
    devices = check_recovery_mode()
    if not devices:
        return False, "错误: 目标板未进入 Recovery 模式"

    emit(BuildStage.FLASH, f"检测到 Recovery 设备", 20)

    # 执行 flash
    mfi_dir = l4t_root / f"mfi_{target_board}"
    if not mfi_dir.exists():
        return False, f"错误: 未找到 mfi 目录: {mfi_dir}"

    emit(BuildStage.FLASH, "开始烧录...", 30)

    cmd = (
        f"sudo ./tools/kernel_flash/l4t_initrd_flash.sh "
        f"--flash-only --massflash 1 --network usb0 --showlogs"
    )

    def on_line(line):
        emit(BuildStage.FLASH, line, 50)
        if "QSPI" in line:
            emit(BuildStage.FLASH, "正在烧录 QSPI...", 70)
        elif "nvme" in line.lower():
            emit(BuildStage.FLASH, "正在烧录 APP...", 85)
        elif "Success" in line or "成功" in line:
            emit(BuildStage.FLASH, "烧录成功!", 95)

    out, err, rc = _run_shell(cmd, cwd=str(mfi_dir), on_line=on_line, timeout=600)

    if rc != 0:
        return False, f"烧录失败: {err or out[-500:]}"

    emit(BuildStage.FLASH, "烧录完成!", 100)
    return True, "烧录成功! 请断开 Recovery 模式并重启设备。"


# =============================================================================
# 状态查询
# =============================================================================

def get_firmware_status() -> Dict:
    """获取固件编译状态"""
    l4t_root = find_l4t_workspace()

    status = {
        "l4t_ready": False,
        "l4t_path": "",
        "l4t_branch": "",
        "kernel_dir": "",
        "available_boards": [],
        "recovery_devices": {},
        "rootfs_ready": False,
        "kernel_built": False,
    }

    if l4t_root:
        status["l4t_ready"] = True
        status["l4t_path"] = str(l4t_root)
        status["l4t_branch"] = get_l4t_branch(l4t_root)
        status["available_boards"] = get_available_boards(l4t_root)
        status["kernel_dir"] = find_kernel_src_dir(l4t_root) or ""

        # 检查 rootfs
        rootfs_dir = l4t_root / "rootfs"
        status["rootfs_ready"] = rootfs_dir.exists() and (rootfs_dir / "etc").exists()

        # 检查内核是否已编译
        kernel_out = l4t_root / "source" / "kernel_out"
        status["kernel_built"] = kernel_out.exists()

    # 检查设备
    status["recovery_devices"] = {
        dev_type: {
            "description": dev.description,
            "connected": dev.connected,
        }
        for dev_type, dev in check_recovery_mode().items()
    }

    return status


def get_hybrid_status() -> Dict:
    """获取 Hybrid BSP 状态"""
    l4t_root = find_l4t_workspace()

    status = {
        "l4t_ready": False,
        "backup_exists": False,
        "app_only_exists": False,
        "qspi_generated": False,
        "mfi_exists": False,
        "backup_size_gb": 0,
    }

    if not l4t_root:
        return status

    status["l4t_ready"] = True

    # 检查备份
    backup_dir = l4t_root / "tools" / "backup_restore" / "images"
    if backup_dir.exists():
        status["backup_exists"] = True
        total = sum(f.stat().st_size for f in backup_dir.rglob("*") if f.is_file())
        status["backup_size_gb"] = round(total / 1024**3, 2)

    # 检查 APP-only
    app_only = l4t_root / "tools" / "backup_restore" / "images_app_only"
    status["app_only_exists"] = app_only.exists()

    # 检查 QSPI
    internal = l4t_root / "tools" / "kernel_flash" / "images" / "internal"
    status["qspi_generated"] = internal.exists() and any(internal.glob("*"))

    # 检查 mfi
    mfi_dirs = list(l4t_root.glob("mfi_*"))
    if mfi_dirs:
        status["mfi_exists"] = True
        status["mfi_name"] = mfi_dirs[0].name

    return status
