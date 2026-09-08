"""
configs.py - Read/check/edit kernel .config build configurations.

Each build config lives at Build/<BSP>-<suffix>/.config. Editing is done via
the kernel's own `scripts/config` helper so we don't corrupt formatting, then
`olddefconfig` resolves dependencies.
"""
from __future__ import annotations

import os
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

WORKSPACE = Path("/home/seeed/bsp-workspace")
BUILD_DIR = WORKSPACE / "Build"
SOURCE_DIR = WORKSPACE / "Source"


@dataclass
class BuildConfig:
    bsp_version: str
    suffix: str          # e.g. "default", "qmi_wwan"
    path: str            # absolute path to .config
    kernel_source: str = ""  # absolute path to kernel tree, if found

    @property
    def name(self) -> str:
        return f"{self.bsp_version}-{self.suffix}"


def _find_kernel_source(version: str) -> str:
    """Locate the kernel tree for a BSP version (mirrors bsp.py)."""
    v = version.strip().lstrip("rR")
    version = f"R{v}"
    candidates = [
        SOURCE_DIR / version / "kernel-jammy-src",
        SOURCE_DIR / version / "kernel_src",
        SOURCE_DIR / version / "kernel" / "kernel-jammy-src",
        SOURCE_DIR / version / "kernel" / "kernel_src",
        SOURCE_DIR / version / "kernel" / "kernel-noble",
        SOURCE_DIR / version / "kernel_src" / "kernel",
    ]
    for c in candidates:
        if (c / "Makefile").exists():
            return str(c)

    src = SOURCE_DIR / version
    if src.exists():
        for root, dirs, files in os.walk(src):
            dirs[:] = [d for d in dirs if d not in {"kernel_src", "scripts", "tools", "BUILD", "build"}]
            if "Makefile" in files:
                return root
    return ""


def list_build_configs() -> list[BuildConfig]:
    """Enumerate every Build/<BSP>-<suffix>/.config on disk."""
    out: list[BuildConfig] = []
    if not BUILD_DIR.exists():
        return out
    for d in sorted(BUILD_DIR.iterdir(), key=lambda p: p.name):
        if not d.is_dir():
            continue
        cfg = d / ".config"
        if not cfg.exists():
            continue
        # Name is <BSP>-<suffix> or possibly just <BSP>. We store the whole
        # dir name and let callers split off a leading Rxx.x.x version.
        m = re.match(r"^(R\d+\.\d+(?:\.\d+)?)[-_.]?(.*)$", d.name)
        if not m:
            continue
        bsp_version, suffix = m.group(1), (m.group(2) or "default")
        kernel = _find_kernel_source(bsp_version)
        out.append(BuildConfig(
            bsp_version=bsp_version,
            suffix=suffix,
            path=str(cfg),
            kernel_source=kernel,
        ))
    return out


def get_config(name: str) -> Optional[BuildConfig]:
    """Resolve a config by its "<BSP>-<suffix>" name."""
    for cfg in list_build_configs():
        if cfg.name == name:
            return cfg
    return None


def _run(cmd: str, timeout: int = 60) -> tuple[str, str, int]:
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True,
                           timeout=timeout, cwd=str(WORKSPACE))
        return r.stdout, r.stderr, r.returncode
    except subprocess.TimeoutExpired:
        return "", "timed out", 124


def read_config_key(cfg: BuildConfig, config_name: str) -> dict:
    """Read a CONFIG_xxx key from a .config file."""
    config_name = config_name.strip()
    if not config_name.startswith("CONFIG_"):
        config_name = f"CONFIG_{config_name}"
    path = Path(cfg.path)
    if not path.exists():
        return {"config_name": config_name, "value": "", "raw_line": ""}

    raw = ""
    value = ""
    text = path.read_text(encoding="utf-8", errors="replace")
    for line in text.splitlines():
        if line.startswith(f"{config_name}="):
            raw, value = line, line.split("=", 1)[1].strip()
            break
        if line.startswith(f"# {config_name} is not set"):
            raw, value = line, "not set"
            break
    return {"config_name": config_name, "value": value, "raw_line": raw}


def set_config_key(cfg: BuildConfig, config_name: str, value: str) -> dict:
    """Set a CONFIG key to y/m/n/not-set and re-run olddefconfig.

    Uses kernel `scripts/config` so edits are atomic and well-formed.
    """
    config_name = config_name.strip()
    if not config_name.startswith("CONFIG_"):
        config_name = f"CONFIG_{config_name}"
    value = value.strip().lower()
    if value not in ("y", "m", "n", "not set", "not-set"):
        return {"ok": False, "error": f"非法取值: {value} (y/m/n)"}

    kernel_src = cfg.kernel_source or _find_kernel_source(cfg.bsp_version)
    if not kernel_src:
        return {"ok": False, "error": f"未找到 {cfg.bsp_version} 内核源码，无法运行 scripts/config"}

    script = f'"{kernel_src}/scripts/config" --file "{cfg.path}"'
    if value in ("n", "not set", "not-set"):
        cmd = f'{script} --disable {config_name}'
    elif value == "m":
        cmd = f'{script} --module {config_name}'
    else:
        cmd = f'{script} --enable {config_name}'

    out, err, rc = _run(cmd, timeout=30)
    if rc != 0:
        return {"ok": False, "error": (err or out).strip() or "scripts/config 失败"}

    # Re-run olddefconfig to resolve dependencies. Best effort: if the
    # toolchain env isn't right it may fail, but the raw edit is already in.
    env_pre = "export ARCH=arm64; "
    cross = WORKSPACE / "toolchain" / "aarch64--glibc--stable-2022.08-1" / "bin" / "aarch64-buildroot-linux-gnu-"
    if (Path(str(cross) + "gcc")).exists():
        env_pre += f'export CROSS_COMPILE="{cross}"; '
    host_tools = WORKSPACE / "tools" / "host" / "bin"
    if host_tools.exists():
        env_pre += f'export PATH="{host_tools}:$PATH"; '
    olddef = f'{env_pre} make -C "{kernel_src}" O="{Path(cfg.path).parent}" olddefconfig'
    _run(olddef, timeout=180)

    result = read_config_key(cfg, config_name)
    result["ok"] = True
    return result