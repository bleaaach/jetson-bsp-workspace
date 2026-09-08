"""
ssh.py - Paramiko-backed SSH for the Jetson BSP web UI.

Replaces the old shell-based ssh/scp/sshpass approach with a real SSH
client so we get working password auth, PTY terminals with resize, and
sftp pushes. Passwords are only ever held in this process (per request /
per terminal session) and are never persisted.

Python 3.8 compatible.
"""
from __future__ import annotations

import os
import queue
import threading
from pathlib import Path
from typing import Optional, Callable

import paramiko
from paramiko import SSHClient, AutoAddPolicy, SFTPClient

WORKSPACE = Path("/home/seeed/bsp-workspace")

DEFAULT_PORT = 22
DEFAULT_USER = "nvidia"
RETURN_EVERY = 10  # terminal read loop yields control every N bytes


class SSHError(Exception):
    """A connection/auth failure with a user-presentable message."""


def _resolve_key_path(key_path: Optional[str]) -> Optional[str]:
    """Return an existing private-key path, or None to fall back to agent/~/.ssh."""
    if key_path:
        p = Path(key_path).expanduser()
        if p.exists():
            return str(p)
        return None

    # Legacy workspace key, mirrors the old ssh -i jetson_key behavior.
    ws_key = WORKSPACE / "jetson_key"
    if ws_key.exists():
        return str(ws_key)
    return None


def _connect(host: str, port: int, user: str, password: str,
             key_path: Optional[str], timeout: int = 8,
             allow_agent: bool = True) -> SSHClient:
    if not host:
        raise SSHError("host required")

    client = SSHClient()
    client.set_missing_host_key_policy(AutoAddPolicy())

    key = _resolve_key_path(key_path)
    kwargs = dict(
        hostname=host,
        port=int(port) or DEFAULT_PORT,
        username=user or DEFAULT_USER,
        timeout=timeout,
        banner_timeout=timeout,
        auth_timeout=timeout,
        look_for_keys=key is None,   # only search ~/.ssh when no explicit key
        allow_agent=allow_agent,
    )
    if key:
        kwargs["key_filename"] = key
    if password:
        kwargs["password"] = password

    try:
        client.connect(**kwargs)
        return client
    except paramiko.AuthenticationException:
        raise SSHError("认证失败：用户名/密码或密钥不正确")
    except Exception as e:  # socket, timeout, banner, refused, etc.
        raise SSHError(f"SSH 连接失败: {str(e).splitlines()[0]}")


def remote_exec(client: SSHClient, command: str, timeout: int = 30):
    """Run a command; return (stdout, stderr, exit_code)."""
    stdin, stdout, stderr = client.exec_command(command, timeout=timeout)
    out = stdout.read().decode("utf-8", "replace")
    err = stderr.read().decode("utf-8", "replace")
    return out, err, stdout.channel.recv_exit_status()


def test_connection(host: str, port: int = 22, user: str = "nvidia",
                    password: str = "", key_path: Optional[str] = None,
                    timeout: int = 8) -> dict:
    """Probe a device and return its identity + loaded modules."""
    result = {
        "host": host, "port": int(port) or 22, "user": user or "nvidia",
        "online": False, "kernel_version": "", "os_version": "",
        "loaded_modules": [], "error": "",
    }
    try:
        client = _connect(host, port, user, password, key_path, timeout)
    except SSHError as e:
        result["error"] = str(e)
        return result
    try:
        out, err, rc = remote_exec(
            client,
            "echo OK; uname -r; grep PRETTY_NAME /etc/os-release",
            timeout=timeout,
        )
        if rc != 0 or "OK" not in out:
            result["error"] = (err or out or "连接成功但探测失败").strip()
            return result

        lines = [l for l in out.strip().splitlines() if l]
        # line[0] is "OK"
        if len(lines) >= 2:
            result["kernel_version"] = lines[1].strip()
        for line in lines[2:]:
            if "PRETTY_NAME" in line:
                result["os_version"] = line.split("=", 1)[-1].strip().strip('"')
                break

        out_mod, _, _ = remote_exec(client, "lsmod | tail -n +2", timeout=timeout)
        result["loaded_modules"] = [
            l.split()[0] for l in out_mod.strip().splitlines() if l
        ]
        result["online"] = True
        return result
    except Exception as e:
        result["error"] = str(e)
        return result
    finally:
        client.close()


def push_module(module: str, host: str, port: int, user: str,
                password: str, key_path: Optional[str],
                ko_path: str, on_output: Optional[Callable[[str], None]] = None) -> dict:
    """Upload a compiled .ko via sftp, install under /lib/modules/<uname -r>/extra,
    then run depmod. Returns {"ok": bool, "detail": str, "kernel_version": str}."""
    module = module.strip().rstrip(".ko")
    ko_path = str(Path(ko_path).expanduser())

    def log(line: str):
        if on_output:
            on_output(line)

    if not Path(ko_path).exists():
        return {"ok": False, "detail": f"本地 .ko 不存在: {ko_path}", "kernel_version": ""}

    client = _connect(host, port, user, password, key_path)
    try:
        out, err, rc = remote_exec(client, "uname -r", timeout=15)
        if rc != 0:
            return {"ok": False, "detail": f"无法读取内核版本: {err or out}", "kernel_version": ""}
        kernver = out.strip()

        log(f"推送 {Path(ko_path).name} -> {user}@{host}:/tmp/")
        sftp: SFTPClient = client.open_sftp()
        try:
            remote_tmp = f"/tmp/{Path(ko_path).name}"
            sftp.put(ko_path, remote_tmp)
        finally:
            sftp.close()
        log("上传完成")

        target = f"/lib/modules/{kernver}/extra/{Path(ko_path).name}"
        install_cmd = (
            f"sudo mkdir -p /lib/modules/{kernver}/extra && "
            f"sudo cp -f '{remote_tmp}' '{target}' && "
            f"sudo chmod 644 '{target}' && "
            f"sudo depmod -a && "
            f"ls -lh '{target}'"
        )
        log(f"安装: {target}")
        out, err, rc = remote_exec(client, install_cmd, timeout=60)
        for line in out.strip().splitlines():
            if line.strip():
                log(f"  {line}")
        if rc != 0:
            return {"ok": False, "detail": f"远程安装失败: {err or out}", "kernel_version": kernver}

        log("✅ 推送完成")
        return {"ok": True, "detail": "推送成功", "kernel_version": kernver}
    except SSHError as e:
        return {"ok": False, "detail": str(e), "kernel_version": ""}
    finally:
        client.close()


def remote_load_test(module: str, host: str, port: int, user: str,
                     password: str, key_path: Optional[str],
                     on_output: Optional[Callable[[str], None]] = None) -> dict:
    """Run modprobe + dmesg on the device and report the outcome."""
    module = module.strip().rstrip(".ko")

    def log(line: str):
        if on_output:
            on_output(line)

    client = _connect(host, port, user, password, key_path)
    try:
        tests = [
            ("dmesg (before)", "sudo dmesg -C && echo cleared"),
            ("modprobe", f"sudo modprobe {module} 2>&1"),
            ("dmesg (after)", "sudo dmesg | tail -20"),
            ("lsmod", f"lsmod | grep -w {module}"),
            ("ls /dev", f"ls /dev/{module[:16]}* 2>/dev/null || echo 'no device node'"),
        ]
        results = []
        for label, cmd in tests:
            log(f"  [{label}]")
            out, err, rc = remote_exec(client, cmd, timeout=60)
            text = (out or err or "(无输出)").strip()
            for line in text.splitlines()[:10]:
                log(f"    {line}")
            results.append((label, rc, text[:200]))

        all_ok = all(rc == 0 or "no device" in text for _, rc, text in results)
        if all_ok:
            return {"ok": True, "summary": "✅ 模块加载成功"}
        failed = [lbl for lbl, rc, text in results if rc != 0 and "no device" not in text]
        return {"ok": False, "summary": f"⚠️ 加载有问题: {', '.join(failed) if failed else '未知错误'}"}
    except SSHError as e:
        return {"ok": False, "summary": str(e)}
    finally:
        client.close()


# =============================================================================
# Interactive terminal session
# =============================================================================

class TerminalSession:
    """A paramiko interactive shell bridged to an output queue.

    The reader runs in a background thread and pushes raw bytes into
    `out_q`; callers drain that queue and feed input via `send` / resize
    via `resize`.
    """

    def __init__(self, host: str, port: int, user: str, password: str,
                 key_path: Optional[str], cols: int = 80, rows: int = 24):
        self.client = _connect(host, port, user, password, key_path, timeout=10)
        self.chan = self.client.invoke_shell(
            term=os.environ.get("TERM", "xterm-256color"),
            width=int(cols) or 80,
            height=int(rows) or 24,
        )
        self.chan.settimeout(0.0)  # non-blocking reads
        self.out_q: "queue.Queue[bytes]" = queue.Queue()
        self._reader = threading.Thread(target=self._read_loop, daemon=True)
        self._reader.start()

    def _read_loop(self):
        try:
            while True:
                if self.chan.recv_ready():
                    data = self.chan.recv(8192)
                    if data:
                        self.out_q.put(data)
                elif self.chan.exit_status_ready():
                    # Drain whatever is left, then signal EOF.
                    while self.chan.recv_ready():
                        data = self.chan.recv(8192)
                        if data:
                            self.out_q.put(data)
                    self.out_q.put(None)
                    return
        except Exception:
            self.out_q.put(None)

    def read(self, timeout: float = 0.2):
        """Blocking pop of one chunk; returns None on EOF. Call from executor."""
        try:
            return self.out_q.get(timeout=timeout)
        except queue.Empty:
            return b""

    def send(self, data: str):
        if self.chan.active:
            self.chan.send(data.encode("utf-8", "replace"))

    def resize(self, cols: int, rows: int):
        try:
            self.chan.resize_pty(width=int(cols) or 80, height=int(rows) or 24)
        except Exception:
            pass

    def close(self):
        try:
            self.chan.close()
        except Exception:
            pass
        try:
            self.client.close()
        except Exception:
            pass