from __future__ import annotations

import fnmatch
import json
import logging
import os
import shutil
import subprocess
from datetime import datetime
from pathlib import Path
from typing import Callable, List, Optional

try:
    from smb.SMBConnection import SMBConnection
except ImportError:  # pragma: no cover
    SMBConnection = None  # type: ignore

logger = logging.getLogger(__name__)

WORKSPACE = Path(__file__).resolve().parents[3]
DATA_DIR = WORKSPACE / "web" / "data"
DATA_DIR.mkdir(parents=True, exist_ok=True)

CONFIG_FILE = DATA_DIR / "firmware_sync_config.json"
STATE_FILE = DATA_DIR / "firmware_sync_state.json"
PENDING_FILE = DATA_DIR / "firmware_sync_pending.json"

DEFAULT_CONFIG = {
    "nas_host": "192.168.1.77",
    "nas_share": "red_2t",
    "nas_user": "shuisheng",
    "nas_pass": "",
    "nas_subdir": "jetson/release",
    "onedrive_remote": "onedrive",
    "onedrive_path": "firmware/release",
    "firmware_patterns": ["*.bin", "*.img", "*.zip", "*.tar", "*.tar.gz", "*.xz", "*.7z", "*.tbz2"],
}


def _load_json(path: Path) -> dict:
    if path.exists():
        try:
            with open(path, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            pass
    return {}


def _save_json(path: Path, data: dict) -> None:
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
def load_config() -> dict:
    cfg = DEFAULT_CONFIG.copy()
    if CONFIG_FILE.exists():
        try:
            with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                cfg.update(json.load(f))
        except Exception:
            pass
    return cfg


def save_config(cfg: dict) -> None:
    with open(CONFIG_FILE, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
    try:
        os.chmod(CONFIG_FILE, 0o600)
    except Exception:
        pass


# ---------------------------------------------------------------------------
# State / Pending
# ---------------------------------------------------------------------------
def get_state() -> dict:
    return _load_json(STATE_FILE)


def save_state(state: dict) -> None:
    _save_json(STATE_FILE, state)


def get_pending() -> dict:
    return _load_json(PENDING_FILE)


def save_pending(pending: dict) -> None:
    _save_json(PENDING_FILE, pending)


# ---------------------------------------------------------------------------
# SMB helpers
# ---------------------------------------------------------------------------
def _match_patterns(name: str, patterns: List[str]) -> bool:
    return any(fnmatch.fnmatch(name, pat) for pat in patterns)


def _smb_conn(cfg: dict) -> SMBConnection:
    if SMBConnection is None:
        raise RuntimeError("pysmb 未安装")
    conn = SMBConnection(
        cfg["nas_user"],
        cfg["nas_pass"],
        "bsp-workbench",
        cfg["nas_host"],
        use_ntlm_v2=True,
        is_direct_tcp=True,
    )
    if not conn.connect(cfg["nas_host"], 445):
        raise ConnectionError(f"无法连接 SMB: {cfg['nas_host']}")
    return conn


def list_nas_files(cfg: Optional[dict] = None) -> List[dict]:
    cfg = cfg or load_config()
    conn = _smb_conn(cfg)
    try:
        subdir = cfg.get("nas_subdir", "").strip("/")
        path = "/" + subdir if subdir else "/"
        files = []
        patterns = cfg.get("firmware_patterns", DEFAULT_CONFIG["firmware_patterns"])
        for f in conn.listPath(cfg["nas_share"], path):
            if f.filename in (".", "..") or f.isDirectory:
                continue
            if not _match_patterns(f.filename, patterns):
                continue
            files.append(
                {
                    "name": f.filename,
                    "path": f"{subdir}/{f.filename}" if subdir else f.filename,
                    "size": f.file_size,
                    "mtime": (
                        f.last_write_time.timestamp()
                        if hasattr(f.last_write_time, "timestamp")
                        else float(f.last_write_time)
                    ),
                }
            )
        return files
    finally:
        conn.close()


def test_nas_connection(cfg: Optional[dict] = None) -> dict:
    cfg = cfg or load_config()
    try:
        files = list_nas_files(cfg)
        return {"ok": True, "count": len(files)}
    except Exception as e:
        return {"ok": False, "error": str(e)}


# ---------------------------------------------------------------------------
# Scan
# ---------------------------------------------------------------------------
def scan(log_cb: Optional[Callable[[str], None]] = None) -> dict:
    cfg = load_config()
    if log_cb:
        log_cb("开始扫描 NAS...")
    files = list_nas_files(cfg)
    if log_cb:
        log_cb(f"NAS 上共有 {len(files)} 个固件文件")

    state = get_state()
    pending = get_pending()
    new_pending = []

    for f in files:
        key = f["path"]
        old = state.get(key)
        if old and old.get("size") == f["size"] and old.get("mtime") == f["mtime"]:
            continue
        pending[key] = {
            "name": f["name"],
            "size": f["size"],
            "mtime": f["mtime"],
            "path": f["path"],
            "detected_at": datetime.utcnow().isoformat() + "Z",
        }
        new_pending.append(pending[key])

    # 清理已不存在的待上传项
    keys = {f["path"] for f in files}
    for key in list(pending.keys()):
        if key not in keys:
            del pending[key]

    save_pending(pending)
    if log_cb:
        log_cb(f"新增 {len(new_pending)} 个待上传固件")
    return {"total": len(files), "new": len(new_pending), "pending": list(pending.values())}


# ---------------------------------------------------------------------------
# Upload
# ---------------------------------------------------------------------------
def _rclone_bin() -> str:
    rclone = shutil.which("rclone")
    if rclone:
        return rclone
    raise RuntimeError("未找到 rclone，请先安装 rclone 并配置 OneDrive 远程")


def _obscure_password(password: str) -> str:
    """使用 rclone obscure 对密码进行混淆。"""
    try:
        result = subprocess.run(
            ["rclone", "obscure", password],
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout.strip()
    except Exception:
        return password


def _rclone_cmd(key: str, cfg: dict) -> List[str]:
    """构造 rclone 命令，从 SMB 直接 copy 到 OneDrive。"""
    item = get_pending().get(key)
    if not item:
        raise ValueError(f"{key} 不在待上传列表")
    subdir = cfg.get("nas_subdir", "").strip("/")
    pass_obscured = _obscure_password(cfg.get("nas_pass", ""))
    src_remote = (
        f":smb,host={cfg['nas_host']},user={cfg['nas_user']},pass={pass_obscured},"
        f"domain=,root={cfg['nas_share']}:{subdir}/{item['name']}"
    )
    dest = f"{cfg['onedrive_remote']}:{cfg['onedrive_path']}/{item['name']}"
    return [_rclone_bin(), "copyto", src_remote, dest, "--stats-one-line"]


def check_rclone_remote(cfg: Optional[dict] = None) -> dict:
    """检查 rclone 是否安装，以及配置的 OneDrive remote 是否存在。"""
    cfg = cfg or load_config()
    if shutil.which("rclone") is None:
        return {"ok": False, "error": "未找到 rclone，请先安装 rclone"}
    remote = cfg.get("onedrive_remote", "onedrive")
    try:
        result = subprocess.run(
            ["rclone", "listremotes", "--long"],
            check=True,
            capture_output=True,
            text=True,
        )
        remotes = [line.strip() for line in result.stdout.splitlines() if line.strip()]
        if f"{remote}:" not in remotes:
            return {
                "ok": False,
                "error": f"rclone 中未找到 remote '{remote}'，请先运行 'rclone config' 配置 OneDrive",
            }
        return {"ok": True, "remote": remote, "remotes": remotes}
    except subprocess.CalledProcessError as exc:
        return {"ok": False, "error": exc.stderr.strip() if exc.stderr else str(exc)}


def upload_file(key: str, log_cb: Optional[Callable[[str], None]] = None) -> bool:
    cfg = load_config()
    pending = get_pending()
    if key not in pending:
        if log_cb:
            log_cb(f"❌ {key} 不在待上传列表")
        return False
    item = pending[key]

    try:
        _rclone_bin()
    except RuntimeError as exc:
        if log_cb:
            log_cb(f"❌ {exc}")
        return False

    remote_check = check_rclone_remote(cfg)
    if not remote_check["ok"]:
        if log_cb:
            log_cb(f"❌ {remote_check['error']}")
        return False

    cmd = _rclone_cmd(key, cfg)
    if log_cb:
        log_cb(f"开始上传 {item['name']} ...")
    try:
        result = subprocess.run(cmd, check=True, capture_output=True, text=True)
        if result.stderr:
            if log_cb:
                log_cb(result.stderr.strip())
    except subprocess.CalledProcessError as exc:
        if log_cb:
            log_cb(f"❌ 上传失败: {exc.stderr.strip() if exc.stderr else exc}")
        return False
    except Exception as exc:
        if log_cb:
            log_cb(f"❌ 上传异常: {exc}")
        return False

    # 移到已上传状态
    state = get_state()
    state[key] = {
        "name": item["name"],
        "size": item["size"],
        "mtime": item["mtime"],
        "path": item["path"],
        "uploaded_at": datetime.utcnow().isoformat() + "Z",
    }
    del pending[key]
    save_state(state)
    save_pending(pending)
    if log_cb:
        log_cb(f"✅ 上传完成: {item['name']}")
    return True


def upload_pending(log_cb: Optional[Callable[[str], None]] = None) -> dict:
    pending = get_pending()
    results = {"success": 0, "failed": 0, "details": []}
    for key in list(pending.keys()):
        ok = upload_file(key, log_cb=log_cb)
        if ok:
            results["success"] += 1
        else:
            results["failed"] += 1
            results["details"].append(key)
    if log_cb:
        log_cb(f"上传完成：{results['success']} 成功，{results['failed']} 失败")
    return results


# ---------------------------------------------------------------------------
# Mount helper (optional, for CIFS fallback)
# ---------------------------------------------------------------------------
def mount_command(cfg: Optional[dict] = None) -> str:
    cfg = cfg or load_config()
    mp = "/mnt/nas_firmware"
    return (
        f"sudo mount -t cifs -o username='{cfg['nas_user']},password=***,"
        f"vers=3.0,uid=1000,gid=1000,rw,file_mode=0664 "
        f"//{cfg['nas_host']}/{cfg['nas_share']} {mp}"
    )
