"""
bsp.py - Core BSP logic wrapping the existing shell scripts.
All paths are relative to the workspace root.
"""

from __future__ import annotations
import subprocess
import json
import os
import re
import time
from pathlib import Path
from typing import Optional, List, Dict
from dataclasses import dataclass, field
from concurrent.futures import ThreadPoolExecutor
import threading

WORKSPACE = Path("/home/seeed/bsp-workspace")
SOURCE_DIR = WORKSPACE / "Source"
BUILD_DIR = WORKSPACE / "Build"
DOWNLOAD_DIR = WORKSPACE / "Downloads"


# =============================================================================
# Data Models
# =============================================================================

@dataclass
class BSPVersion:
    version: str          # e.g. "R36.4.4"
    ready: bool           # kernel source exists
    kernel_path: str       # absolute path to kernel source
    build_configs: list[str] = field(default_factory=list)
    total_size: str = ""

    @property
    def display_name(self) -> str:
        return self.version

    @property
    def short_version(self) -> str:
        return self.version.replace("R", "")


@dataclass
class ModuleSource:
    files: list[str]       # e.g. ["drivers/usb/serial/pl2303.c"]
    kconfig_name: str     # e.g. "CONFIG_USB_SERIAL_PL2303"
    kconfig_file: str     # path within kernel source
    kconfig_help: str = ""
    makefile_rules: list[str] = field(default_factory=list)
    extra_configs: list[str] = field(default_factory=list)  # sub-configs


@dataclass
class ModuleConfigStatus:
    config_name: str
    value: str            # "y" / "m" / "n" / "not set"
    build_config: str     # e.g. "R36.4.4-default"
    raw_line: str = ""

    @property
    def status_label(self) -> str:
        return {"y": "built-in", "m": "module", "n": "disabled"}.get(
            self.value, self.value
        )

    @property
    def status_color(self) -> str:
        return {"y": "green", "m": "blue", "n": "red", "not set": "red"}.get(
            self.value, "gray"
        )


@dataclass
class CompiledKO:
    path: str
    size: str             # human-readable
    vermagic: str = ""
    build_config: str = ""


@dataclass
class ModuleQueryResult:
    module: str
    bsp_version: str
    source: Optional[ModuleSource]
    config_status: Optional[ModuleConfigStatus]
    compiled_kos: list[CompiledKO] = field(default_factory=list)
    available: bool = True
    summary: str = ""     # human-readable conclusion


# =============================================================================
# BSP Version Detection
# =============================================================================


def get_bsp_versions() -> list[BSPVersion]:
    """Detect all BSP versions visible to the user.

    Merges three sources, in order of preference:
      1.  BSP_URL_TABLE         — every version that NVIDIA publishes (online catalog)
      2.  Source/<ver>          — fully extracted / initialized (ready=True)
      3.  Downloads/<ver>       — tarball present but not yet extracted

    Each resulting entry has:
      ready        — kernel source exists in Source/
      downloaded   — archive or extracted tree present on disk
      in_catalog   — appears in BSP_URL_TABLE (i.e. can be downloaded)
    """
    found: dict[str, dict] = {}

    # 1) Seed with the online catalog so every supported BSP is listed
    for key in BSP_URL_TABLE.keys():
        url_rel, label = BSP_URL_TABLE[key]
        major = key.lstrip("R").split(".")[0]
        platform_map = {
            "39": "Thor (T5000/T4000)", "38": "Thor",
            "36": "Orin (AGX/NX/Nano)", "35": "Orin/Xavier NX",
            "34": "Orin/Xavier NX", "32": "TX2/Nano/Xavier",
        }
        found[key] = {
            "version": key,
            "ready": False,
            "downloaded": False,
            "in_catalog": True,
            "kernel_path": "",
            "build_configs": [],
            "total_size": "",
            "jetpack": label,
            "platform": platform_map.get(major, ""),
            "url_sub_path": url_rel,
            "archive_name": BSP_ARCHIVE_NAMES.get(key, "public_sources.tbz2"),
        }

    # 2) Walk local Source/<ver>/ to mark ready versions
    if SOURCE_DIR.exists():
        for d in SOURCE_DIR.iterdir():
            if not d.is_dir() or not d.name.startswith("R"):
                continue
            entry = found.setdefault(d.name, {
                "version": d.name,
                "ready": False, "downloaded": False, "in_catalog": False,
                "kernel_path": "", "build_configs": [], "total_size": "",
                "jetpack": get_bsp_jetpack_version(d.name), "platform": "",
                "url_sub_path": "", "archive_name": "public_sources.tbz2",
            })
            ksrc = _find_kernel_source(d.name)
            if ksrc:
                entry["ready"] = True
                entry["downloaded"] = True
                entry["kernel_path"] = ksrc
                try:
                    kb = sum(f.stat().st_size for f in Path(ksrc).rglob("*") if f.is_file())
                    entry["total_size"] = _human_size(kb)
                except Exception:
                    pass

    # 3) Walk local Downloads/<ver>/ to mark tarball-only or extracted versions
    if DOWNLOAD_DIR.exists():
        for d in DOWNLOAD_DIR.iterdir():
            if not d.is_dir() or not d.name.startswith("R"):
                continue
            entry = found.setdefault(d.name, {
                "version": d.name,
                "ready": False, "downloaded": False, "in_catalog": False,
                "kernel_path": "", "build_configs": [], "total_size": "",
                "jetpack": get_bsp_jetpack_version(d.name), "platform": "",
                "url_sub_path": "", "archive_name": "public_sources.tbz2",
            })
            if _is_downloaded(d.name):
                entry["downloaded"] = True
            # If a kernel source lurks under Downloads/, surface it as ready
            if not entry["ready"]:
                ksrc = _find_kernel_source(d.name)
                if ksrc:
                    entry["ready"] = True
                    entry["kernel_path"] = ksrc

    # 4) Collect build configs for every version (in BUILD_DIR)
    for ver, entry in found.items():
        cfg_dir = BUILD_DIR / ver
        if cfg_dir.exists():
            entry["build_configs"] = sorted(
                sub.name for sub in cfg_dir.iterdir()
                if sub.is_dir() and (sub / ".config").exists()
            )

    versions = [
        BSPVersion(
            version=v["version"],
            ready=v["ready"],
            kernel_path=v["kernel_path"],
            build_configs=v["build_configs"],
            total_size=v["total_size"],
        )
        for v in found.values()
    ]
    # Sort: ready first, then downloaded, then catalog-only; alphabetical within group
    def _sort_key(v: BSPVersion):
        e = found[v.version]
        rank = (0 if e["ready"] else 1 if e["downloaded"] else 2)
        return (rank, v.version)

    versions.sort(key=_sort_key)
    # Stash the full metadata so the API layer can include it without recomputing
    get_bsp_versions._last_meta = {
        v.version: found[v.version] for v in versions
    }
    return versions


def get_bsp_catalog() -> list[dict]:
    """Return the static BSP catalog (no network). Each entry includes
    the JetPack label, the URL sub-path, and the archive filename."""
    out = []
    for key in sorted(BSP_URL_TABLE.keys()):
        url_rel, label = BSP_URL_TABLE[key]
        major = key.lstrip("R").split(".")[0]
        platform_map = {
            "39": "Thor (T5000/T4000)", "38": "Thor",
            "36": "Orin (AGX/NX/Nano)", "35": "Orin/Xavier NX",
            "34": "Orin/Xavier NX", "32": "TX2/Nano/Xavier",
        }
        out.append({
            "version": key,
            "label": label,
            "platform": platform_map.get(major, ""),
            "url_sub_path": url_rel,
            "archive_name": BSP_ARCHIVE_NAMES.get(key, "public_sources.tbz2"),
        })
    return out


def _find_kernel_source(version: str) -> str:
    """Find kernel source directory for a given BSP version.

    Looks for a directory containing a Makefile under any of the conventional
    shapes used in Source/<ver>/ and Downloads/<ver>/.
    """
    candidates = [
        SOURCE_DIR / version / "kernel-jammy-src",
        SOURCE_DIR / version / "kernel_src",
        SOURCE_DIR / version / "kernel" / "kernel-jammy-src",
        SOURCE_DIR / version / "kernel" / "kernel_src",
        SOURCE_DIR / version / "kernel" / "kernel-noble",      # R39 style
        SOURCE_DIR / version / "kernel_src" / "kernel",         # R39 style
        DOWNLOAD_DIR / version / "Linux_for_Tegra" / "source" / "kernel" / "kernel-jammy-src",
        DOWNLOAD_DIR / version / "Linux_for_Tegra" / "source" / "kernel" / "kernel_src",
        DOWNLOAD_DIR / version / "Linux_for_Tegra" / "source" / "kernel" / "kernel-noble",
        DOWNLOAD_DIR / version / "Linux_for_Tegra" / "source" / "kernel",
        DOWNLOAD_DIR / version / "kernel_src",
    ]
    for c in candidates:
        if (c / "Makefile").exists():
            return str(c)

    # Fallback: recursive search for any Makefile under Source/<ver>/,
    # skipping build-script dirs. Handles new directory layouts.
    source_root = SOURCE_DIR / version
    if source_root.exists():
        for root, dirs, files in os.walk(source_root):
            # Skip directories that only contain build scripts, not kernel source
            skip = {"kernel_src", "scripts", "tools", "BUILD", "build"}
            dirs[:] = [d for d in dirs if d not in skip]
            if "Makefile" in files:
                return root

    return ""


def bsp_status(version: str) -> dict:
    """Compact status snapshot for a BSP version.

    Returned to the frontend so it can show tailored UX (download button,
    extraction progress, etc.) instead of generic "no results" messages.
    """
    ksrc = _find_kernel_source(version)
    if ksrc:
        return {"state": "ready", "kernel_path": ksrc}
    if _is_downloaded(version):
        return {"state": "downloaded", "kernel_path": ""}
    if version in BSP_URL_TABLE:
        return {"state": "catalog", "kernel_path": ""}
    return {"state": "unknown", "kernel_path": ""}


def _is_downloaded(version: str) -> bool:
    """True if any artifact (tarball or extracted tree) exists for this version."""
    d = DOWNLOAD_DIR / version
    if not d.exists():
        return False
    # Tarballs
    if any(d.glob("*sources*.tbz2")) or any(d.glob("*kernel*.tbz2")):
        return True
    # Already-extracted BSP tree (Source/<ver> aside, LfT under Downloads)
    if (d / "Linux_for_Tegra").is_dir():
        return True
    return False


def _human_size(n: int) -> str:
    for unit in ["B", "KB", "MB", "GB"]:
        if n < 1024:
            return f"{n:.1f}{unit}"
        n /= 1024
    return f"{n:.1f}TB"


# =============================================================================
# Module Query
# =============================================================================

def _run_shell(cmd: str, cwd: str = None, timeout: int = 30) -> tuple[str, str, int]:
    """Run a shell command, return (stdout, stderr, returncode)."""
    try:
        result = subprocess.run(
            cmd, shell=True, capture_output=True, text=True,
            cwd=cwd or str(WORKSPACE), timeout=timeout,
        )
        return result.stdout, result.stderr, result.returncode
    except subprocess.TimeoutExpired:
        return "", "Command timed out", 124


def _run_script(script: str, *args, timeout: int = 60) -> tuple[str, str, int]:
    """Run one of the existing shell scripts."""
    cmd_parts = [script] + list(args)
    cmd = " ".join(f'"{a}"' if " " in str(a) else str(a) for a in cmd_parts)
    return _run_shell(cmd, timeout=timeout)


def normalize_module_name(raw: str) -> str:
    """Strip .ko, .o, CONFIG_ prefix from user input."""
    name = raw.strip()
    name = re.sub(r'\.ko$', '', name)
    name = re.sub(r'\.o$', '', name)
    name = re.sub(r'^CONFIG_', '', name)
    return name


def _grep_kernel(ksrc: str, pattern: str, **kwargs) -> list[str]:
    """Run grep inside the kernel source tree."""
    cmd = f'cd "{ksrc}" && {pattern}'
    out, _, rc = _run_shell(cmd, timeout=kwargs.get("timeout", 30))
    if rc == 0:
        return [l for l in out.strip().splitlines() if l]
    return []


def query_module(module: str, bsp_version: str = "R36.4.4") -> ModuleQueryResult:
    """
    Query module information across 4 dimensions:
    1. Source files
    2. Kconfig / CONFIG name
    3. .config status
    4. Compiled .ko files
    """
    result = ModuleQueryResult(
        module=module,
        bsp_version=bsp_version,
        source=None,
        config_status=None,
    )

    ksrc = _find_kernel_source(bsp_version)
    if not ksrc:
        result.available = False
        result.summary = f"BSP {bsp_version} 内核源码未找到"
        return result

    # -------------------------------------------------------------------------
    # 1. Find source files
    # -------------------------------------------------------------------------
    source_files = []
    config_name = ""
    for subdir in ["drivers", "net", "fs", "sound", "crypto", "block"]:
        out, _, _ = _run_shell(
            f'cd "{ksrc}" && find {subdir} -type f \\( -name "{module}.c" -o -name "{module}.h" \\) 2>/dev/null',
            timeout=15,
        )
        source_files.extend(l for l in out.strip().splitlines() if l)

    # Also search for directory-style drivers (rtw89, iwlwifi, etc.)
    dir_matches = []
    for subdir in ["drivers", "net"]:
        out, _, _ = _run_shell(
            f'cd "{ksrc}" && find {subdir} -type d -name "{module}" 2>/dev/null',
            timeout=15,
        )
        dir_matches.extend(l for l in out.strip().splitlines() if l)

    if not source_files and not dir_matches:
        # Fallback: module name may differ from source filename.
        # e.g. rtw89_8852be -> CONFIG_RTW89_8852BE -> obj-$(...) += rtw89_8852be.o
        #      -> rtw89_8852be-objs := rtw8852be.o  → 源文件 rtw8852be.c
        # grep -F 固定字符串避免 shell/ERE 转义 $(...) 的坑
        cfg_upper = module.upper().replace("-", "_")
        out, _, _ = _run_shell(
            f'cd "{ksrc}" && grep -rhF "obj-\\$(CONFIG_{cfg_upper})" --include="Makefile" . 2>/dev/null | head -10',
            timeout=30,
        )
        config_name = "" if not config_name else config_name
        seen = set()
        for line in out.splitlines():
            m = re.search(r'obj-\$\(CONFIG_[A-Z0-9_]+\)\s*\+=\s*([a-zA-Z0-9_/-]+)\.o', line)
            if not m:
                continue
            obj_base = m.group(1).split("/")[-1]
            cm = re.search(r'CONFIG_[A-Z0-9_]+', line)
            if cm and not config_name:
                config_name = cm.group(0)
            candidates = [obj_base]
            # 解析 MOD-objs/-y 组件（可能重定向到真正的源文件基名）
            comp_out, _, _ = _run_shell(
                f'cd "{ksrc}" && grep -rhE "^{re.escape(obj_base)}-(objs|y)[[:space:]]*[:=]" --include="Makefile" . 2>/dev/null | head -3',
                timeout=15,
            )
            for cline in comp_out.splitlines():
                candidates.extend(re.findall(r'([a-zA-Z0-9_-]+)\.o', cline))
            for base in candidates:
                if base in seen:
                    continue
                seen.add(base)
                src_out, _, _ = _run_shell(
                    f'cd "{ksrc}" && find drivers net -type f -name "{base}.c" 2>/dev/null | head -3',
                    timeout=15,
                )
                source_files.extend(x for x in src_out.splitlines() if x)

    if not source_files and not dir_matches:
        result.available = False
        result.summary = f"在内核树中未找到 {module} 源码"
        return result

    # -------------------------------------------------------------------------
    # 2. Find Kconfig / CONFIG name
    # -------------------------------------------------------------------------
    # config_name 可能已由 fallback (CONFIG 反查) 解出, 保留; 否则 Method 1-3 填充
    kconfig_file = ""
    kconfig_help = ""
    extra_configs = []
    makefile_rules = []

    # Method 1: obj-${CONFIG} += ${module}.o
    pattern = f'grep -rhE "obj-\\$\\(CONFIG_[A-Z0-9_]+\\)[[:space:]]*\\+=[[:space:]]*{re.escape(module)}\\.o" --include="Makefile" 2>/dev/null'
    for line in _grep_kernel(ksrc, pattern, timeout=20):
        m = re.search(r'CONFIG_[A-Z0-9_]+', line)
        if m and not config_name:
            config_name = m.group(0)
        makefile_rules.append(line.strip())

    # Method 2: obj-${CONFIG} += ${module}_xxx.o (complex drivers)
    if not config_name:
        pattern = f'grep -rhE "obj-\\$\\(CONFIG_[A-Z0-9_]+\\)[[:space:]]*\\+=[[:space:]]*{re.escape(module)}_[a-z0-9]*\\.o" --include="Makefile" 2>/dev/null'
        for line in _grep_kernel(ksrc, pattern, timeout=20):
            m = re.search(r'CONFIG_[A-Z0-9_]+', line)
            if m and not config_name:
                config_name = m.group(0)
            makefile_rules.append(line.strip())

    # Method 3: directory-style (rtw89, iwlwifi)
    if not config_name:
        for subdir in ["drivers/net/wireless", "drivers"]:
            pattern = f'grep -rhE "obj-\\$\\(CONFIG_[A-Z0-9_]+\\)[[:space:]]*\\+=" "{module}" --include="Makefile" 2>/dev/null'
            for line in _grep_kernel(ksrc, pattern, timeout=20):
                m = re.search(r'CONFIG_[A-Z0-9_]+', line)
                if m and not config_name:
                    config_name = m.group(0)
                makefile_rules.append(line.strip())

    # Try to extract menuconfig base name
    menuconfig_base = ""
    if config_name:
        base = config_name.replace("CONFIG_", "")
        # e.g. CONFIG_RTW89_8852AE -> RTW89 (base without _8852AE suffix)
        parts = base.split("_")
        if len(parts) > 1:
            # Try to find menuconfig RTW89 (first part)
            kf = _grep_kernel(
                ksrc,
                f'grep -rln "^menuconfig {parts[0]}[[:space:]]" --include="Kconfig*" 2>/dev/null | head -1',
                timeout=15,
            )
            if kf:
                menuconfig_base = parts[0]

        # Find Kconfig file
        cfg_short = config_name.replace("CONFIG_", "")
        kf = _grep_kernel(
            ksrc,
            f'grep -rln "^config {cfg_short}[[:space:]]" --include="Kconfig*" 2>/dev/null | head -1',
            timeout=15,
        )
        if kf:
            kconfig_file = kf[0] if kf else ""

    source = ModuleSource(
        files=source_files,
        kconfig_name=config_name,
        kconfig_file=kconfig_file,
        kconfig_help=kconfig_help,
        makefile_rules=makefile_rules,
        extra_configs=extra_configs,
    )
    result.source = source

    # -------------------------------------------------------------------------
    # 3. Check .config status
    # -------------------------------------------------------------------------
    if config_name:
        config_dir = BUILD_DIR / bsp_version
        config_files = (
            list(config_dir.glob("*/.config")) if config_dir.exists() else []
        )
        # Also check default config
        default_cfg = config_dir / "default" / ".config"
        if default_cfg.exists():
            config_files.insert(0, default_cfg)

        if config_files:
            cfg_path = config_files[0]
            out, _, _ = _run_shell(
                f'grep -E "^CONFIG_{cfg_short}=" "{cfg_path}" 2>/dev/null || '
                f'grep -E "^# CONFIG_{cfg_short} is not set" "{cfg_path}" 2>/dev/null',
                timeout=10,
            )
            line = out.strip()
            if line:
                if "is not set" in line:
                    value = "not set"
                elif "=" in line:
                    value = line.split("=")[1].strip()
                else:
                    value = "unknown"

                result.config_status = ModuleConfigStatus(
                    config_name=config_name,
                    value=value,
                    build_config=str(cfg_path.parent.name),
                    raw_line=line,
                )

    # -------------------------------------------------------------------------
    # 4. Find compiled .ko files
    # -------------------------------------------------------------------------
    ko_files = []
    for ko in BUILD_DIR.rglob(f"{module}.ko"):
        size = _human_size(ko.stat().st_size)
        vermagic = ""
        out, _, _ = _run_shell(f"modinfo -F vermagic '{ko}' 2>/dev/null", timeout=5)
        if out.strip():
            vermagic = out.strip().splitlines()[0]
        ko_files.append(CompiledKO(
            path=str(ko.relative_to(WORKSPACE)),
            size=size,
            vermagic=vermagic,
            build_config=str(ko.parent.parent.name),
        ))
    result.compiled_kos = ko_files

    # -------------------------------------------------------------------------
    # 5. Summary
    # -------------------------------------------------------------------------
    parts = []
    if source_files or dir_matches:
        parts.append("内核源码存在")
    if config_name:
        parts.append(f"CONFIG={config_name}")
    if result.config_status:
        status = result.config_status
        label = {"y": "已内置", "m": "可编译为模块", "n": "已禁用", "not set": "未启用"}.get(
            status.value, status.value
        )
        parts.append(label)
    if ko_files:
        parts.append(f"已有 {len(ko_files)} 个 .ko")

    result.summary = " | ".join(parts) if parts else "未找到任何信息"
    return result


# =============================================================================
# BSP Download & Init
# =============================================================================

def get_available_bsp_versions_online() -> list[dict]:
    """
    Return available BSP versions that have downloadable BSP sources.
    Source: https://developer.nvidia.com/embedded/jetpack-archive
    """
    results = []
    for key in sorted(BSP_URL_TABLE.keys()):
        url_rel_path, label = BSP_URL_TABLE[key]
        archive_name = BSP_ARCHIVE_NAMES.get(key, "public_sources.tbz2")
        url = f"{_NVIDIA_DOWNLOAD_BASE}/{url_rel_path}{archive_name}"

        # Quick HEAD check
        out, err, rc = _run_shell(
            f'curl -fsIL --max-time 6 "{url}" 2>/dev/null | grep -q "HTTP/[12]"',
            timeout=10,
        )
        reachable = rc == 0

        # Derive platform group from major version
        major = key.lstrip("R").split(".")[0]
        platform_map = {
            "39": "Thor (T5000/T4000)", "38": "Thor",
            "36": "Orin (AGX/NX/Nano)", "35": "Orin/Xavier NX",
            "34": "Orin/Xavier NX", "32": "TX2/Nano/Xavier",
        }
        platform = platform_map.get(major, "")

        results.append({
            "version": key,
            "label": label,
            "platform": platform,
            "url_sub_path": url_rel_path,
            "archive_name": archive_name,
            "available": reachable,
        })

    return results


def _resolve_bsp_url(version: str) -> tuple[str, str, str]:
    """
    Look up BSP version in BSP_URL_TABLE.
    Returns (url_rel_path, version_display, archive_name).
      url_rel_path  — ends with "source/" or "sources/"
      archive_name   — "public_sources.tbz2" or per-version kernel src tarball
    Raises ValueError if the version is not in the table.
    """
    normalized = version.strip().lstrip("rR")
    key = f"R{normalized}"

    if key not in BSP_URL_TABLE:
        raise ValueError(
            f"'{version}' 不在已知版本列表中。"
            f" 支持: {', '.join(sorted(BSP_URL_TABLE.keys()))}"
        )

    url_rel_path, label = BSP_URL_TABLE[key]
    archive_name = BSP_ARCHIVE_NAMES.get(key, "public_sources.tbz2")
    return url_rel_path, key, archive_name



def download_bsp(version: str, progress_callback=None) -> str:
    """Download BSP sources for given version. Returns status message."""
    try:
        url_rel_path, version_display, archive_name = _resolve_bsp_url(version)
    except ValueError as e:
        return f"版本格式错误: {e}"

    if progress_callback:
        progress_callback(f"开始下载 BSP {version_display}...")

    archive_path = DOWNLOAD_DIR / version_display / archive_name

    # Check if already downloaded
    if archive_path.exists():
        if progress_callback:
            progress_callback(f"BSP 源码已存在: {archive_path.name}")
        return f"已存在: {archive_path.name}"

    source_url = f"{_NVIDIA_DOWNLOAD_BASE}/{url_rel_path}{archive_name}"

    if progress_callback:
        progress_callback(f"下载地址: {source_url}")

    # Check availability
    out, err, rc = _run_shell(
        f'curl -fsIL --noproxy "*" --max-time 10 "{source_url}" 2>/dev/null | grep -q "HTTP/[12]"',
        timeout=15,
    )
    if rc != 0:
        return (
            f"BSP {version_display} 源码不可下载，可能是未发布版本。"
            f"\nURL: {source_url}"
        )

    # Disk space check — estimate from actual archive name
    est_kb = {
        "ubuntu_focal-l4t_aarch64_src.tbz2": 7_200_000,   # ~6.9 GB kernel src
    }.get(archive_name, 2_000_000)  # default ~2 GB for public_sources.tbz2
    out_space, _, _ = _run_shell(
        f'df -PB1 "{WORKSPACE}" 2>/dev/null | awk "NR==2{{print $4}}"',
        timeout=5,
    )
    try:
        avail_kb = int(out_space.strip())
        if avail_kb < est_kb * 1.3:
            est_gb = round(est_kb / 1024 / 1024, 1)
            avail_gb = round(avail_kb / 1024 / 1024, 1)
            return f"磁盘空间不足（需要约 {est_gb} GB，可用 {avail_gb} GB）"
    except ValueError:
        pass

    # Download
    if progress_callback:
        progress_callback(f"正在下载 (~{round(est_kb/1024/1024,1)} GB)，请稍候...")

    mkdir_result, _, _ = _run_shell(
        f'mkdir -p "{DOWNLOAD_DIR / version_display}"',
        timeout=5,
    )

    cmd = (
        f'curl -fL --noproxy "*" --retry 3 --retry-delay 5 '
        f'-o "{archive_path}" '
        f'"{source_url}"'
    )
    out, err, rc = _run_shell(cmd, timeout=600)

    if rc != 0:
        return f"下载失败: {err or out}"

    # Validate tar
    out_check, err_check, rc_check = _run_shell(
        f'tar -tjf "{archive_path}" >/dev/null 2>&1 && echo OK',
        timeout=30,
    )
    if "OK" not in out_check:
        return f"下载文件校验失败，不是有效的 tar.bz2 压缩包"

    if progress_callback:
        progress_callback("下载并校验完成!")

    return f"下载完成: {archive_path.name}"


def init_bsp(version: str, progress_callback=None) -> str:
    """Extract and initialize BSP sources."""
    version = f"R{version.lstrip('R')}"

    if progress_callback:
        progress_callback(f"初始化 BSP {version}...")

    # Find the archive — try multiple naming patterns across BSP versions
    archive = DOWNLOAD_DIR / version / "public_sources.tbz2"
    if not archive.exists():
        candidates = list(DOWNLOAD_DIR.glob(f"{version}/*src*.tbz2")) + \
                     list(DOWNLOAD_DIR.glob(f"{version}/*src*.tar*"))
        for c in candidates:
            if c.name.endswith((".tbz2", ".tar.bz2")) and c.is_file():
                archive = c
                break

    if not archive.exists():
        return "error:未找到 BSP 压缩包，请确认已下载: " + version

    target_dir = SOURCE_DIR / version
    target_dir.mkdir(parents=True, exist_ok=True)

    if progress_callback:
        progress_callback(f"解压: {archive.name} ...")

    out, err, rc = _run_shell(
        f'tar -xf "{archive}" -C "{target_dir}/"',
        timeout=300,
    )
    if rc != 0:
        return "error:解压失败: " + (err or "未知错误")

    # Find and extract kernel source
    kernel_tar = _run_shell(
        f'find "{target_dir}" -name "kernel_src.tbz2" -o -name "kernel_src.tar*" 2>/dev/null | head -1',
        timeout=10,
    )[0].strip()

    if kernel_tar and progress_callback:
        progress_callback(f"解压内核源码: {os.path.basename(kernel_tar)}")
        _run_shell(f'tar -xf "{kernel_tar}" -C "{target_dir}/"', timeout=300)

    # Check result
    ksrc = _find_kernel_source(version)
    if ksrc:
        return f"就绪: {ksrc}"
    return "内核源码路径未找到，请手动检查"


# =============================================================================
# Module Build
# =============================================================================

_executor = ThreadPoolExecutor(max_workers=2)
_build_lock = threading.Lock()


def build_module(
    module: str,
    bsp_version: str = "R36.4.4",
    config_suffix: str = "",
    on_output: callable = None,
    seed_config: str = "",
) -> str:
    """
    Build a kernel module using the existing build-jetson-module.sh.
    on_output: callback(line: str) for streaming stdout/stderr.
    seed_config: optional absolute path to a .config to use as the build seed
        (the web .config editor writes into a chosen Build/<ver>-<suffix>/).
    Returns: status message string.
    """
    module = normalize_module_name(module)
    bsp_version = f"R{bsp_version.lstrip('R')}"

    if on_output:
        on_output(f"[{bsp_version}] 开始编译模块: {module}")

    build_script = WORKSPACE / "build-jetson-module.sh"
    if not build_script.exists():
        return "错误: build-jetson-module.sh 不存在"

    env = os.environ.copy()
    env["JETSON_BSP_VERSION"] = bsp_version
    env["JETSON_HOST"] = ""  # Don't auto-push
    env["JETSON_CONFIG_SEED"] = seed_config or ""

    args = [str(build_script), module]
    if config_suffix:
        args.append(config_suffix)

    cmd = " ".join(args)
    if on_output:
        on_output(f"执行: {cmd}")

    try:
        proc = subprocess.Popen(
            cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            cwd=str(WORKSPACE), env=env, text=True,
        )
        output_lines = []
        for line in iter(proc.stdout.readline, ""):
            if not line:
                break
            output_lines.append(line.rstrip())
            if on_output:
                on_output(line.rstrip())

        proc.wait()
        if proc.returncode == 0:
            if on_output:
                on_output("✅ 编译成功!")
            # Find output .ko
            for ko in BUILD_DIR.rglob(f"{module}.ko"):
                if on_output:
                    on_output(f"   输出: {ko.relative_to(WORKSPACE)} ({_human_size(ko.stat().st_size)})")
            return "编译成功"
        else:
            if on_output:
                on_output(f"❌ 编译失败 (exit {proc.returncode})")
            return f"编译失败 (exit {proc.returncode})"

    except Exception as e:
        return f"编译异常: {str(e)}"


# =============================================================================
# SSH / Push
# =============================================================================

@dataclass
class JetsonConnection:
    host: str
    port: int
    user: str
    password: str = ""
    online: bool = False
    kernel_version: str = ""
    os_version: str = ""
    loaded_modules: list[str] = field(default_factory=list)
    error: str = ""

    @property
    def display_name(self) -> str:
        return f"{self.user}@{self.host}"


def test_connection(host: str, port: int = 22, user: str = "nvidia",
                    password: str = "", timeout: int = 8) -> JetsonConnection:
    """Test SSH connection to a Jetson device."""
    conn = JetsonConnection(host=host, port=port, user=user, password=password)

    # Build SSH command
    identity_file = WORKSPACE / "jetson_key" if (WORKSPACE / "jetson_key").exists() else None
    ssh_base = ["ssh"]
    if identity_file:
        ssh_base += ["-i", str(identity_file)]
    if port != 22:
        ssh_base += ["-p", str(port)]
    ssh_base += [
        "-o", "StrictHostKeyChecking=no",
        "-o", "ConnectTimeout=5",
        "-o", "BatchMode=yes",
    ]
    ssh_str = " ".join(ssh_base + [f"{user}@{host}"])

    # Test basic connectivity
    out, err, rc = _run_shell(
        f"{ssh_str} 'echo OK && uname -r && cat /etc/os-release | grep PRETTY' 2>&1",
        timeout=timeout,
    )

    if rc == 0:
        conn.online = True
        lines = out.strip().splitlines()
        if lines:
            conn.kernel_version = lines[0] if len(lines) > 0 else ""
            for line in lines[1:]:
                if "PRETTY_NAME" in line:
                    conn.os_version = line.split("=")[-1].strip('"')
                    break
        # Get loaded modules
        out_mod, _, _ = _run_shell(f"{ssh_str} 'lsmod' 2>/dev/null | tail -n +2 2>/dev/null", timeout=timeout)
        conn.loaded_modules = [l.split()[0] for l in out_mod.strip().splitlines() if l]
    else:
        conn.error = err.strip() if err else "连接失败"

    return conn


def push_module(
    module: str,
    target: JetsonConnection,
    ko_path: str = "",
    on_output: callable = None,
) -> str:
    """Push compiled .ko to Jetson and optionally load it."""
    module = normalize_module_name(module)

    if not ko_path:
        candidates = list(BUILD_DIR.rglob(f"{module}.ko"))
        if candidates:
            ko_path = str(candidates[0])
        else:
            return f"未找到 {module}.ko，请先编译"

    ko_path = str(BUILD_DIR / ko_path) if not ko_path.startswith("/") else ko_path

    if on_output:
        on_output(f"推送 {module}.ko -> {target.display_name}...")

    identity_file = f"-i {WORKSPACE}/jetson_key" if (WORKSPACE / "jetson_key").exists() else ""
    ssh_opts = f"-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes"
    ssh_base = f"ssh {identity_file} {ssh_opts} -p {target.port} {target.user}@{target.host}"
    scp_base = f"scp {identity_file} {ssh_opts} -P {target.port}"

    try:
        # SCP the .ko
        if on_output:
            on_output(f"scp {ko_path} ...")
        remote_tmp = f"/tmp/{module}.ko"
        out, err, rc = _run_shell(
            f"{scp_base} '{ko_path}' '{target.user}@{target.host}:{remote_tmp}'",
            timeout=60,
        )
        if rc != 0:
            return f"SCP 失败: {err or out}"

        # Remote install
        remote_cmds = [
            f"sudo cp '{remote_tmp}' /lib/modules/{target.kernel_version}/extra/{module}.ko",
            f"sudo chmod 644 /lib/modules/{target.kernel_version}/extra/{module}.ko",
            f"sudo depmod -a",
            f"ls -lh /lib/modules/{target.kernel_version}/extra/{module}.ko",
        ]
        remote_script = " && ".join(remote_cmds)
        out, err, rc = _run_shell(f"{ssh_base} '{remote_script}'", timeout=30)

        if on_output:
            for line in out.strip().splitlines():
                if line.strip():
                    on_output(f"  {line}")

        if rc == 0:
            if on_output:
                on_output("✅ 推送完成")
            return "推送成功"
        else:
            return f"远程命令失败: {err}"

    except Exception as e:
        return f"推送异常: {str(e)}"


def remote_load_test(
    module: str,
    target: JetsonConnection,
    on_output: callable = None,
) -> str:
    """Run modprobe on the Jetson to test loading the module."""
    module = normalize_module_name(module)
    identity_file = f"-i {WORKSPACE}/jetson_key" if (WORKSPACE / "jetson_key").exists() else ""
    ssh_opts = f"-o StrictHostKeyChecking=no -o ConnectTimeout=5"
    ssh_base = f"ssh {identity_file} {ssh_opts} -p {target.port} {target.user}@{target.host}"

    tests = [
        ("dmesg (before)", f"sudo dmesg -C && echo 'cleared'"),
        ("modprobe", f"sudo modprobe {module} 2>&1"),
        ("dmesg (after)", "sudo dmesg | tail -20"),
        ("lsmod", f"lsmod | grep {module}"),
        ("ls /dev", f"ls /dev/{module[:16]}* 2>/dev/null || echo 'no device node'"),
    ]

    results = []
    for label, cmd in tests:
        if on_output:
            on_output(f"  [{label}]")
        out, err, rc = _run_shell(f"{ssh_base} '{cmd}'", timeout=30)
        output = out.strip() if out.strip() else err.strip() if err.strip() else "(无输出)"
        if on_output:
            for line in output.splitlines()[:10]:
                on_output(f"    {line}")
        results.append((label, rc, output[:200]))

    all_ok = all(r[1] == 0 or "no device" in r[2] for r in results)
    if all_ok:
        return "✅ 模块加载成功"
    else:
        failed = [r[0] for r in results if r[1] != 0 and "no device" not in r[2]]
        return f"⚠️ 加载有问题: {', '.join(failed) if failed else '未知错误'}"


# =============================================================================
# Quick search across all modules
# =============================================================================

def search_modules(query: str, bsp_version: str = "R36.4.4") -> list[dict]:
    """
    Quick fuzzy search for modules matching `query` across:
    - Makefile obj-m rules
    - Kconfig config names
    - Source filenames

    Returns an empty list when the BSP version has no extracted kernel
    source. Callers must check `_bsp_ready(bsp_version)` separately to
    distinguish "nothing matched" from "BSP not downloaded yet" — see the
    GET /api/module/search handler.
    """
    ksrc = _find_kernel_source(f"R{bsp_version.lstrip('R')}")
    if not ksrc:
        return []

    results = []

    # Search Makefiles for obj-m
    out, _, _ = _run_shell(
        f'cd "{ksrc}" && grep -rhE "^obj-m.*" --include="Makefile" 2>/dev/null | '
        f'grep -i "{query}" | '
        f'sed -nE "s/.*[[:space:]]+([a-zA-Z0-9_-]+)\\.o.*/\\1/p" | sort -u',
        timeout=30,
    )
    for name in out.strip().splitlines():
        if name and name not in [r["name"] for r in results]:
            results.append({"name": name, "type": "obj-m", "match": "makefile"})

    # Search Kconfig names
    out, _, _ = _run_shell(
        f'cd "{ksrc}" && grep -rhi "^config.*{query}" --include="Kconfig*" 2>/dev/null | '
        f'sed -nE "s/.*config ([[:space:]]*[A-Za-z0-9_]+).*/\\1/p" | sort -u',
        timeout=30,
    )
    for cfg in out.strip().splitlines():
        if cfg and cfg.lower().startswith(query.lower()[:4]):
            name = cfg.lower().replace("config", "").strip()
            if name not in [r["name"] for r in results]:
                results.append({"name": name, "type": "kconfig", "match": "kconfig"})

    # Search source filenames
    out, _, _ = _run_shell(
        f'cd "{ksrc}" && find drivers net fs sound crypto block -type f -name "*{query}*" 2>/dev/null | head -20',
        timeout=15,
    )
    for path in out.strip().splitlines():
        name = os.path.splitext(os.path.basename(path))[0]
        if name not in [r["name"] for r in results]:
            results.append({"name": name, "type": "source", "match": path})

    return results[:20]  # limit to 20 results


# URL base — direct download CDN, not the redirector
_NVIDIA_DOWNLOAD_BASE = "https://developer.download.nvidia.com/embedded/L4T"

# ─────────────────────────────────────────────────────────────────
# Verified BSP URL table — maps R<version> -> (url_rel_path, jetpack_label)
# url_rel_path: ends with "source/" (singular, JetPack 7.1) or "sources/" (plural)
# Full URL: <base>/<url_rel_path>/<archive_name>
#   archive_name = BSP_ARCHIVE_NAMES.get(key, "public_sources.tbz2")
#
# Key findings from live HTTP verification:
#   - All paths use capital "Release" on developer.download.nvidia.com
#   - R38.4.0 (JetPack 7.1):  singular "source/"
#   - All other 35.x/36.x/38.x/39.x: plural "sources/"
#   - R35.2.1 (JetPack 5.1): public_sources.tbz2 de-listed; use kernel src tarball
# Source: https://developer.nvidia.com/embedded/jetpack-archive
# ─────────────────────────────────────────────────────────────────
BSP_URL_TABLE = {
    # JetPack 7.1 (L4T 38.4 — Thor, singular "source/")
    "R38.4.0":  ("r38_Release_v4.0/source/", "JetPack 7.1"),
    # JetPack 7.0 / 7.2 (L4T 38.x / 39.x — Thor, plural "sources/")
    "R39.2.0":  ("r39_Release_v2.0/sources/", "JetPack 7.2"),
    "R39.2":    ("r39_Release_v2.0/sources/", "JetPack 7.2"),
    "R38.2.1":  ("r38_Release_v2.1/sources/", "JetPack 7.0"),
    "R38.2.0":  ("r38_Release_v2.0/sources/", "JetPack 7.0"),
    # JetPack 6.x (L4T 36.x)
    "R36.5.2":  ("r36_Release_v5.2/sources/", "JetPack 6.2.3"),
    "R36.5.0":  ("r36_Release_v5.0/sources/", "JetPack 6.2.2"),
    "R36.4.4":  ("r36_Release_v4.4/sources/", "JetPack 6.2.1"),
    "R36.4.3":  ("r36_Release_v4.3/sources/", "JetPack 6.2"),
    "R36.4.0":  ("r36_Release_v4.0/sources/", "JetPack 6.1"),
    "R36.3.0":  ("r36_Release_v3.0/sources/", "JetPack 6.0"),
    "R36.2.0":  ("r36_Release_v2.0/sources/", "JetPack 6.0 DP"),
    # JetPack 5.x (L4T 35.x)
    "R35.6.5":  ("r35_Release_v6.5/sources/", "JetPack 5.1.7"),
    "R35.6.4":  ("r35_Release_v6.4/sources/", "JetPack 5.1.6"),
    "R35.6.2":  ("r35_Release_v6.2/sources/", "JetPack 5.1.5"),
    "R35.6.1":  ("r35_Release_v6.1/sources/", "JetPack 5.1.5"),
    "R35.6.0":  ("r35_Release_v6.0/sources/", "JetPack 5.1.4"),
    "R35.5.0":  ("r35_Release_v5.0/sources/", "JetPack 5.1.3"),
    "R35.4.1":  ("r35_Release_v4.1/sources/", "JetPack 5.1.2"),
    "R35.3.1":  ("r35_Release_v3.1/sources/", "JetPack 5.1.1"),
    # R35.2.1 (JetPack 5.1): public_sources.tbz2 de-listed; uses kernel source tarball
    "R35.2.1":  ("r35_Release_v2.1/sources/", "JetPack 5.1"),
    "R35.1.0":  ("r35_Release_v1.0/sources/", "JetPack 5.0"),
}

# Per-version archive filenames (only R35.2.1 differs from the default)
BSP_ARCHIVE_NAMES: dict[str, str] = {
    "R35.2.1": "ubuntu_focal-l4t_aarch64_src.tbz2",  # 6.9 GB kernel source
}


def get_bsp_jetpack_version(version: str) -> str:
    """Map BSP version to JetPack version string."""
    entry = BSP_URL_TABLE.get(version)
    if entry:
        return entry[1]
    # Fallback: guess from major version
    v = version.lstrip("rR")
    major = v.split(".")[0]
    fallbacks = {
        "39": "JetPack 7.x (Thor)", "38": "JetPack 7.x (Thor)",
        "36": "JetPack 6.x", "35": "JetPack 5.x",
        "34": "JetPack 5.0 DP", "32": "JetPack 4.6.x",
    }
    return fallbacks.get(major, f"JetPack {version.lstrip('R')}")
