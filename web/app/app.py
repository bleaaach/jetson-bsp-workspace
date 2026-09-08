"""
app.py - FastAPI backend for Jetson BSP Web UI.
Serves the SPA and exposes BSP query/build/push/device/config APIs.

Web backend is read-mostly over the workspace shell scripts; long-running
actions (build, download, push) run in background threads and stream
Server-Sent Events keyed by job_id.

NOTE: no `from __future__ import annotations` here — run_server.py loads this
module via importlib with a custom name ("_app_module"), which breaks
pydantic's forward-reference resolution for Optional[...] fields.
"""

import asyncio
import queue
import sys
import threading
import uuid
from pathlib import Path
from typing import Optional

# run_server.py loads this module via importlib spec (module name "_app_module"),
# so its sibling modules in this directory are NOT on sys.path. Add them.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from fastapi import FastAPI, HTTPException, Query, WebSocket
from fastapi.responses import HTMLResponse, FileResponse, JSONResponse, StreamingResponse
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from bsp import (
    get_bsp_versions, query_module, search_modules,
    build_module, download_bsp, init_bsp,
    normalize_module_name, get_bsp_jetpack_version, get_bsp_catalog,
    get_available_bsp_versions_online, bsp_status,
    ModuleQueryResult,
)
from firmware_build import (
    BuildStage,
    build_firmware, check_recovery_mode,
    hybrid_backup, hybrid_prepare_app_only, hybrid_generate_qspi,
    hybrid_assemble_mfi, hybrid_flash,
    get_firmware_status, get_hybrid_status,
)
import ssh as sshmod
import store
import configs as configsmod
import firmware_sync as fwsync

# =============================================================================
# App Setup
# =============================================================================

app = FastAPI(title="Jetson BSP Module Manager", version="2.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

WORKSPACE = Path("/home/seeed/bsp-workspace")
STATIC_DIR = Path(__file__).resolve().parent / "static"
TEMPLATE_DIR = Path(__file__).resolve().parent / "templates"

app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")


@app.get("/", response_class=HTMLResponse)
def index():
    html = TEMPLATE_DIR / "index.html"
    if not html.exists():
        return HTMLResponse("index.html missing", status_code=500)
    return HTMLResponse(html.read_text(encoding="utf-8"))


# SSE event queues (job_id -> queue)
sse_queues: dict = {}
sse_lock = threading.Lock()


# =============================================================================
# Pydantic Models
# =============================================================================

class QueryRequest(BaseModel):
    module: str
    bsp_version: str = "R36.4.4"


class BuildRequest(BaseModel):
    module: str
    bsp_version: str = "R36.4.4"
    config_suffix: str = ""
    seed_config: str = ""


class DownloadRequest(BaseModel):
    version: str
    init: bool = True


class ConnectionTestRequest(BaseModel):
    host: str
    port: int = 22
    user: str = "nvidia"
    password: str = ""
    key_path: str = ""


class PushRequest(BaseModel):
    module: str
    ko_path: str = ""
    host: str = ""
    port: int = 22
    user: str = "nvidia"
    password: str = ""
    key_path: str = ""
    device_id: Optional[int] = None
    test_load: bool = True


class BatchPushRequest(BaseModel):
    module: str
    ko_path: str = ""
    device_ids: list = []
    password: str = ""
    key_path: str = ""
    test_load: bool = True


class DeviceRequest(BaseModel):
    name: str
    host: str
    port: int = 22
    user: str = "nvidia"
    key_path: str = ""
    note: str = ""


class ConfigSetRequest(BaseModel):
    config_name: str
    value: str


# =============================================================================
# SSE Helpers
# =============================================================================

def _sse_payload(event: str, data: dict) -> str:
    import json as _json
    return f"event: {event}\ndata: {_json.dumps(data)}\n\n"


def emit(job_id: str, event: str, data: dict):
    """Thread-safe SSE emission to a job's queue (structured dict)."""
    with sse_lock:
        q = sse_queues.get(job_id)
        if q:
            try:
                q.put_nowait({"event": event, "data": data})
            except Exception:
                pass


def get_queue(job_id: str) -> queue.Queue:
    with sse_lock:
        q = sse_queues.get(job_id)
        if q is None:
            q = queue.Queue()
            sse_queues[job_id] = q
        return q


def cleanup_queue(job_id: str):
    with sse_lock:
        sse_queues.pop(job_id, None)


def _resolve_ko_path(module: str, ko_path: str = "") -> str:
    """Return an absolute path to a built .ko for `module`, if any."""
    if ko_path:
        p = Path(ko_path).expanduser()
        return str(p) if p.is_absolute() else str(WORKSPACE / p)
    name = normalize_module_name(module)
    for cand in (WORKSPACE / "Build").rglob(f"{name}.ko"):
        return str(cand)
    return ""


def _job_stream(job_id: str, terminal_events=()):
    """Generic SSE generator over a job's queue. Yields until a terminal event."""
    async def gen():
        import json as _json
        q = get_queue(job_id)
        yield "event: connected\ndata: " + _json.dumps({"job_id": job_id}) + "\n\n"
        try:
            while True:
                try:
                    msg = await asyncio.wait_for(
                        asyncio.get_event_loop().run_in_executor(
                            None, lambda: q.get(timeout=600)), timeout=610)
                except (asyncio.TimeoutError, queue.Empty):
                    yield "event: ping\ndata: {}\n\n"
                    continue
                event = msg.get("event", "message")
                data = msg.get("data", {})
                yield f"event: {event}\ndata: {_json.dumps(data)}\n\n"
                if event in terminal_events:
                    break
        except Exception:
            pass
        finally:
            cleanup_queue(job_id)

    return StreamingResponse(
        gen(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


# =============================================================================
# Info / Status
# =============================================================================

@app.get("/api/bsp/versions")
def api_bsp_versions():
    versions = get_bsp_versions()
    meta = getattr(get_bsp_versions, "_last_meta", {}) or {}
    return {
        "versions": [
            {
                "version": v.version,
                "ready": v.ready,
                "kernel_path": v.kernel_path,
                "build_configs": v.build_configs,
                "total_size": v.total_size,
                "jetpack": meta.get(v.version, {}).get("jetpack")
                            or get_bsp_jetpack_version(v.version),
                "downloaded": meta.get(v.version, {}).get("downloaded", False),
                "in_catalog": meta.get(v.version, {}).get("in_catalog", False),
                "platform": meta.get(v.version, {}).get("platform", ""),
            }
            for v in versions
        ]
    }


@app.get("/api/bsp/versions/catalog")
def api_bsp_versions_catalog():
    return {"versions": get_bsp_catalog()}


@app.get("/api/bsp/versions/online")
def api_bsp_versions_online():
    try:
        versions = get_available_bsp_versions_online()
        return {"versions": versions}
    except Exception as e:
        return {"versions": [], "error": str(e)}


# =============================================================================
# Module Query
# =============================================================================

@app.get("/api/module/search")
def api_module_search(q: str = Query(..., min_length=1), bsp_version: str = Query("R36.4.4")):
    status = bsp_status(bsp_version)
    results = search_modules(q, bsp_version) if status["state"] == "ready" else []
    return {"results": results, "bsp_status": status}


@app.post("/api/module/query")
def api_module_query(req: QueryRequest):
    result = query_module(req.module, req.bsp_version)
    return serialize_query_result(result)


@app.get("/api/module/query/{module}")
def api_module_query_get(module: str, bsp_version: str = "R36.4.4"):
    result = query_module(module, bsp_version)
    return serialize_query_result(result)


# =============================================================================
# Build
# =============================================================================

@app.get("/api/build/{module}")
def api_build_get(module: str, bsp_version: str = "R36.4.4",
                  config_suffix: str = "", seed_config: str = ""):
    job_id = str(uuid.uuid4())[:8]
    get_queue(job_id)

    def output_cb(line: str):
        emit(job_id, "log", {"line": line})

    threading.Thread(
        target=_do_build,
        args=(module, bsp_version, config_suffix, seed_config, output_cb, job_id),
        daemon=True,
    ).start()

    return JSONResponse({
        "job_id": job_id, "module": module,
        "bsp_version": bsp_version, "status": "started",
    })


@app.post("/api/build")
def api_build(req: BuildRequest):
    return api_build_get(req.module, req.bsp_version, req.config_suffix, req.seed_config)


@app.get("/api/build/stream/{job_id}")
def api_build_stream(job_id: str):
    return _job_stream(job_id, terminal_events=("done",))


def _do_build(module: str, bsp_version: str, config_suffix: str,
              seed_config: str, output_cb, job_id: str):
    db_id = store.create_job("build", module)
    try:
        result = build_module(module, bsp_version, config_suffix, output_cb, seed_config)
    except Exception as e:  # never leave the SSE hanging on an unexpected error
        result = f"编译异常: {e}"
    success = result == "编译成功"
    store.finish_job(db_id, "ok" if success else "error", result)
    emit(job_id, "done", {
        "status": "success" if success else "error",
        "message": result,
    })


# =============================================================================
# Download & Init BSP
# =============================================================================

@app.post("/api/bsp/download")
def api_bsp_download(req: DownloadRequest):
    job_id = str(uuid.uuid4())[:8]
    get_queue(job_id)

    def progress_cb(msg: str):
        emit(job_id, "progress", {"message": msg})

    def do_download():
        db_id = store.create_job("download", req.version)
        result = download_bsp(req.version, progress_cb)
        if req.init and ("已存在" in result or "完成" in result):
            init_result = init_bsp(req.version, progress_cb)
            ok = not init_result.startswith("error:")
            store.finish_job(db_id, "ok" if ok else "error", init_result)
            emit(job_id, "log", {"line": init_result})
            emit(job_id, "done", {"status": "ok" if ok else "error", "message": init_result})
        else:
            store.finish_job(db_id, "ok", result)
            emit(job_id, "done", {"status": "ok", "message": result})

    threading.Thread(target=do_download, daemon=True).start()
    return JSONResponse({"job_id": job_id, "status": "started"})


@app.get("/api/bsp/download/stream/{job_id}")
def api_bsp_download_stream(job_id: str):
    # Downloads use a string-serialized SSE queue historically; reuse the
    # generic streamer which forwards raw payloads.
    return _job_stream(job_id, terminal_events=("done",))


# =============================================================================
# Devices (paramiko-backed, passwords never persisted)
# =============================================================================

@app.get("/api/devices")
def api_devices():
    return {"devices": store.list_devices()}


@app.post("/api/devices")
def api_devices_create(req: DeviceRequest):
    dev = store.save_device(req.name, req.host, req.port, req.user, req.key_path, req.note)
    return {"device": dev}


@app.put("/api/devices/{device_id}")
def api_devices_update(device_id: int, req: DeviceRequest):
    if store.get_device(device_id) is None:
        raise HTTPException(404, "设备不存在")
    dev = store.save_device(req.name, req.host, req.port, req.user, req.key_path,
                            req.note, device_id=device_id)
    return {"device": dev}


@app.delete("/api/devices/{device_id}")
def api_devices_delete(device_id: int):
    store.delete_device(device_id)
    return {"ok": True}


class DeviceTestRequest(BaseModel):
    password: str = ""
    key_path: str = ""


@app.post("/api/devices/test")
def api_devices_test(req: ConnectionTestRequest):
    """Test connectivity; password is supplied per-call and never stored."""
    result = sshmod.test_connection(req.host, req.port, req.user, req.password, req.key_path)
    return result


@app.post("/api/devices/{device_id}/test")
def api_device_test(device_id: int, req: DeviceTestRequest):
    dev = store.get_device(device_id)
    if dev is None:
        raise HTTPException(404, "设备不存在")
    key_path = req.key_path or dev["key_path"]
    result = sshmod.test_connection(dev["host"], dev["port"], dev["user"],
                                    req.password, key_path)
    result["device_id"] = device_id
    return result


# =============================================================================
# Push (paramiko: sftp install + optional load test)
# =============================================================================

@app.post("/api/ssh/push")
def api_ssh_push(req: PushRequest):
    job_id = str(uuid.uuid4())[:8]
    get_queue(job_id)

    def _fail(message: str):
        emit(job_id, "done", {"status": "error", "message": message})

    # Resolve credentials: an explicit host wins, otherwise a saved device.
    if req.host:
        host, port, user, key_path = req.host, req.port, req.user, req.key_path
    elif req.device_id is not None:
        dev = store.get_device(req.device_id)
        if dev is None:
            _fail("设备不存在")
            return JSONResponse({"job_id": job_id, "status": "started"})
        host, port, user, key_path = dev["host"], dev["port"], dev["user"], dev["key_path"]
    else:
        _fail("请指定主机或设备")
        return JSONResponse({"job_id": job_id, "status": "started"})

    def output_cb(line: str):
        emit(job_id, "log", {"line": line})

    def do_push():
        db_id = store.create_job("push", host)
        ko_path = _resolve_ko_path(req.module, req.ko_path)
        if not ko_path:
            msg = f"未找到 {req.module}.ko，请先编译"
            store.finish_job(db_id, "error", msg)
            emit(job_id, "log", {"line": f"❌ {msg}"})
            emit(job_id, "done", {"status": "error", "message": msg})
            return
        r = sshmod.push_module(req.module, host, port, user, req.password,
                               key_path, ko_path, output_cb)
        if not r["ok"]:
            store.finish_job(db_id, "error", r["detail"])
            emit(job_id, "log", {"line": f"❌ {r['detail']}"})
            emit(job_id, "done", {"status": "error", "message": r["detail"]})
            return
        if req.test_load:
            output_cb("--- 运行加载测试 ---")
            lr = sshmod.remote_load_test(req.module, host, port, user,
                                         req.password, key_path, output_cb)
            store.finish_job(db_id, "ok" if lr["ok"] else "error", lr["summary"])
            emit(job_id, "done", {"status": "ok" if lr["ok"] else "error",
                                  "message": lr["summary"]})
        else:
            store.finish_job(db_id, "ok", "推送成功")
            emit(job_id, "done", {"status": "ok", "message": "推送成功"})

    threading.Thread(target=do_push, daemon=True).start()
    return JSONResponse({"job_id": job_id, "status": "started"})


@app.post("/api/push/batch")
def api_push_batch(req: BatchPushRequest):
    """Push one .ko to multiple saved devices sequentially, streaming per-device."""
    if not req.device_ids:
        raise HTTPException(422, "device_ids 不能为空")

    job_id = str(uuid.uuid4())[:8]
    get_queue(job_id)

    def output_cb(line: str):
        emit(job_id, "log", {"line": line})

    def do_batch():
        unchecked = [(i, store.get_device(i)) for i in req.device_ids]
        devices = [(i, d) for i, d in unchecked if d is not None]
        if not devices:
            emit(job_id, "done", {"status": "error", "message": "没有有效设备"})
            return
        ko_path = _resolve_ko_path(req.module, req.ko_path)
        if not ko_path:
            msg = f"未找到 {req.module}.ko，请先编译"
            emit(job_id, "log", {"line": f"❌ {msg}"})
            emit(job_id, "done", {"status": "error", "message": msg})
            return
        db_id = store.create_job("push", f"{len(devices)} 台设备")
        results = []
        for i, dev in devices:
            output_cb(f"━━ 设备 {dev['name']} ({dev['host']}) ━━")
            r = sshmod.push_module(req.module, dev["host"], dev["port"], dev["user"],
                                   req.password, req.key_path or dev["key_path"],
                                   ko_path, output_cb)
            if r["ok"] and req.test_load:
                r = sshmod.remote_load_test(req.module, dev["host"], dev["port"],
                                            dev["user"], req.password,
                                            req.key_path or dev["key_path"], output_cb)
            results.append(r["ok"])
        ok_count = sum(results)
        store.finish_job(db_id, "ok" if ok_count == len(results) else "error",
                         f"{ok_count}/{len(results)} 台成功")
        emit(job_id, "done", {
            "status": "ok" if ok_count == len(results) else "error",
            "message": f"{ok_count}/{len(results)} 台设备推送成功",
        })

    threading.Thread(target=do_batch, daemon=True).start()
    return JSONResponse({"job_id": job_id, "status": "started"})


@app.get("/api/push/batch/stream/{job_id}")
def api_push_batch_stream(job_id: str):
    return _job_stream(job_id, terminal_events=("done",))


@app.get("/api/ssh/stream/{job_id}")
def api_ssh_stream(job_id: str):
    return _job_stream(job_id, terminal_events=("done",))


# =============================================================================
# .config editing
# =============================================================================

@app.get("/api/configs")
def api_configs():
    cfgs = configsmod.list_build_configs()
    return {"configs": [
        {"name": c.name, "bsp_version": c.bsp_version, "suffix": c.suffix,
         "kernel_ready": bool(c.kernel_source)}
        for c in cfgs
    ]}


@app.get("/api/configs/{name}")
def api_config_get(name: str):
    cfg = configsmod.get_config(name)
    if cfg is None:
        raise HTTPException(404, "构建配置不存在")
    return {"name": cfg.name, "bsp_version": cfg.bsp_version, "suffix": cfg.suffix}


@app.get("/api/configs/{name}/key")
def api_config_key_get(name: str, config: str = Query(...)):
    cfg = configsmod.get_config(name)
    if cfg is None:
        raise HTTPException(404, "构建配置不存在")
    return configsmod.read_config_key(cfg, config)


@app.post("/api/configs/{name}/key")
def api_config_key_set(name: str, req: ConfigSetRequest):
    cfg = configsmod.get_config(name)
    if cfg is None:
        raise HTTPException(404, "构建配置不存在")
    return configsmod.set_config_key(cfg, req.config_name, req.value)


# =============================================================================
# Jobs history
# =============================================================================

@app.get("/api/jobs")
def api_jobs(limit: int = 50):
    return {"jobs": store.list_jobs(limit)}


# =============================================================================
# Serializers
# =============================================================================

def serialize_query_result(r: ModuleQueryResult) -> dict:
    def serialize_source(s):
        if s is None:
            return None
        return {
            "files": s.files,
            "kconfig_name": s.kconfig_name,
            "kconfig_file": s.kconfig_file,
            "kconfig_help": s.kconfig_help,
            "makefile_rules": s.makefile_rules,
            "extra_configs": s.extra_configs,
        }

    def serialize_config(s):
        if s is None:
            return None
        return {
            "config_name": s.config_name,
            "value": s.value,
            "build_config": s.build_config,
            "status_label": s.status_label,
            "status_color": s.status_color,
            "raw_line": s.raw_line,
        }

    def serialize_ko(k):
        return {
            "path": k.path,
            "size": k.size,
            "vermagic": k.vermagic,
            "build_config": k.build_config,
        }

    return {
        "module": r.module,
        "bsp_version": r.bsp_version,
        "available": r.available,
        "source": serialize_source(r.source),
        "config_status": serialize_config(r.config_status),
        "compiled_kos": [serialize_ko(k) for k in r.compiled_kos],
        "summary": r.summary,
        "bsp_status": bsp_status(r.bsp_version),
    }


# =============================================================================
# WebSocket / SSH Terminal (paramiko PTY)
# =============================================================================

@app.websocket("/ws/terminal")
async def ws_terminal(ws: WebSocket):
    """
    Real SSH terminal over paramiko.
    Client -> Server:
      {"type": "connect", "host": "", "port": 22, "user": "", "password": "",
       "key_path": "", "cols": 80, "rows": 24}
      {"type": "input", "data": "..."}
      {"type": "resize", "cols": 80, "rows": 24}
      {"type": "disconnect"}
    Server -> Client:
      {"type": "output", "data": "..."}
      {"type": "error", "data": "..."}
    """
    await ws.accept()
    session = None
    reader_task = None

    async def pump():
        loop = asyncio.get_event_loop()
        try:
            while session is not None:
                chunk = await loop.run_in_executor(None, session.read, 0.2)
                if chunk is None:
                    await ws.send_json({"type": "output", "data": "\r\n[Session closed]\r\n"})
                    break
                if chunk:
                    await ws.send_json({"type": "output",
                                        "data": chunk.decode("utf-8", "replace")})
        except Exception:
            pass

    try:
        while True:
            msg = await ws.receive_json()
            msg_type = msg.get("type", "")

            if msg_type == "connect":
                host = msg.get("host", "")
                if not host:
                    await ws.send_json({"type": "error", "data": "host required"})
                    continue
                try:
                    session = sshmod.TerminalSession(
                        host, msg.get("port", 22), msg.get("user", "nvidia"),
                        msg.get("password", ""), msg.get("key_path", ""),
                        cols=msg.get("cols", 80), rows=msg.get("rows", 24),
                    )
                    await ws.send_json({"type": "output",
                                        "data": f"[Connected to {msg.get('user', 'nvidia')}@{host}]\r\n"})
                    reader_task = asyncio.create_task(pump())
                except sshmod.SSHError as e:
                    await ws.send_json({"type": "error", "data": str(e)})
                    session = None

            elif msg_type == "input":
                if session:
                    session.send(msg.get("data", ""))

            elif msg_type == "resize":
                if session:
                    session.resize(msg.get("cols", 80), msg.get("rows", 24))

            elif msg_type == "disconnect":
                break

    except Exception as e:
        try:
            await ws.send_json({"type": "error", "data": str(e)})
        except Exception:
            pass
    finally:
        if reader_task:
            reader_task.cancel()
        if session:
            session.close()
        session = None

# =============================================================================
# Firmware Sync
# =============================================================================

class FirmwareConfigRequest(BaseModel):
    nas_host: str = "192.168.1.77"
    nas_share: str = "red_2t"
    nas_user: str = "shuisheng"
    nas_pass: str = ""
    nas_subdir: str = "jetson/release"
    onedrive_remote: str = "onedrive"
    onedrive_path: str = "firmware/release"
    firmware_patterns: str = "*.bin,*.img,*.zip,*.tar,*.tar.gz,*.xz,*.7z,*.tbz2"


@app.get("/api/firmware/config")
def api_firmware_config():
    cfg = fwsync.load_config()
    cfg = dict(cfg)
    cfg["nas_pass"] = "******" if cfg.get("nas_pass") else ""
    return {"config": cfg}


@app.post("/api/firmware/config")
def api_firmware_config_set(req: FirmwareConfigRequest):
    cfg = fwsync.load_config()
    new_cfg = req.dict()
    new_cfg["firmware_patterns"] = [p.strip() for p in new_cfg["firmware_patterns"].split(",") if p.strip()]
    if not new_cfg.get("nas_pass"):
        new_cfg["nas_pass"] = cfg.get("nas_pass", "")
    fwsync.save_config(new_cfg)
    return {"ok": True, "config": fwsync.load_config()}


@app.get("/api/firmware/test")
def api_firmware_test():
    return fwsync.test_nas_connection()


@app.get("/api/firmware/pending")
def api_firmware_pending():
    return {"pending": list(fwsync.get_pending().values())}


@app.get("/api/firmware/status")
def api_firmware_status():
    return {"uploaded": list(fwsync.get_state().values())}


@app.get("/api/firmware/remote")
def api_firmware_remote():
    return fwsync.check_rclone_remote()


@app.post("/api/firmware/scan")
def api_firmware_scan():
    result = fwsync.scan()
    return result


@app.post("/api/firmware/upload-pending")
def api_firmware_upload_pending():
    job_id = str(uuid.uuid4())[:8]
    get_queue(job_id)

    def do_upload():
        def log_cb(line: str):
            emit(job_id, "log", {"line": line})
        try:
            fwsync.upload_pending(log_cb=log_cb)
            emit(job_id, "done", {"status": "ok", "message": "上传完成"})
        except Exception as e:
            emit(job_id, "done", {"status": "error", "message": str(e)})

    threading.Thread(target=do_upload, daemon=True).start()
    return JSONResponse({"job_id": job_id, "status": "started"})


class FirmwareUploadRequest(BaseModel):
    key: str


@app.post("/api/firmware/upload")
def api_firmware_upload(req: FirmwareUploadRequest):
    key = req.key
    job_id = str(uuid.uuid4())[:8]
    get_queue(job_id)

    def do_upload():
        def log_cb(line: str):
            emit(job_id, "log", {"line": line})
        try:
            ok = fwsync.upload_file(key, log_cb=log_cb)
            if ok:
                emit(job_id, "done", {"status": "ok", "message": f"{key} 上传完成"})
            else:
                emit(job_id, "done", {"status": "error", "message": f"{key} 上传失败"})
        except Exception as e:
            emit(job_id, "done", {"status": "error", "message": str(e)})

    threading.Thread(target=do_upload, daemon=True).start()
    return JSONResponse({"job_id": job_id, "status": "started"})


@app.get("/api/firmware/upload/stream/{job_id}")
def api_firmware_upload_stream(job_id: str):
    return _job_stream(job_id, terminal_events=("done",))


# =============================================================================
# Firmware Build APIs (Thor BSP + DIY Hybrid BSP)
# =============================================================================

class ThorBuildRequest(BaseModel):
    """Thor 固件编译请求"""
    bsp_version: str = "R38.4.0"
    stage: str = "all"  # prepare, build, flash, cleanup, all
    default_user: str = "seeed"
    default_password: str = "seeed"
    default_hostname: str = "jetson"
    board_id: str = "3834"
    board_sku: str = "0008"
    fab: str = "400"
    board_rev: str = "G.5"
    chip_sku: str = "00:00:00:A0"


class HybridBackupRequest(BaseModel):
    """Hybrid BSP 备份请求"""
    bsp_version: str = "R36.4.3"
    source_board: str = "jetson-orin-nano-devkit-nvme"


class HybridConfigRequest(BaseModel):
    """Hybrid BSP 配置请求"""
    bsp_version: str = "R36.4.3"
    target_board: str = "recomputer-orin-j401"  # or recomputer-orin-super-j401
    module_sku: str = "0005"
    fab: str = "300"
    board_rev: str = "V.2"


# ---- Status APIs ----

@app.get("/api/firmware/thor/status")
def api_thor_status():
    """获取 Thor 固件编译状态"""
    return get_firmware_status()


@app.get("/api/firmware/hybrid/status")
def api_hybrid_status():
    """获取 Hybrid BSP 状态"""
    return get_hybrid_status()


@app.get("/api/firmware/thor/bsp-urls")
def api_thor_bsp_urls():
    """获取 Thor BSP 下载链接"""
    return {"urls": {}}


# ---- Thor Build APIs ----

@app.post("/api/firmware/thor/build")
def api_thor_build(req: ThorBuildRequest):
    """Thor 固件编译/烧录"""
    job_id = str(uuid.uuid4())[:8]
    get_queue(job_id)

    def do_build():
        def progress_cb(prog):
            emit(job_id, "progress", {
                "stage": prog.stage.value,
                "message": prog.message,
                "percentage": prog.percentage,
            })
            if prog.error:
                emit(job_id, "error", {"message": prog.error})
            if prog.done:
                emit(job_id, "done", {
                    "status": "error" if prog.error else "ok",
                    "message": prog.message,
                })

        # 映射 stage 字符串到枚举
        stage_map = {
            "prepare": BuildStage.PREPARE,
            "build": BuildStage.BUILD,
            "flash": BuildStage.FLASH,
            "cleanup": BuildStage.CLEANUP,
            "all": BuildStage.PREPARE,  # all 会自动执行后续阶段
        }
        stage = stage_map.get(req.stage, BuildStage.PREPARE)

        # 板子配置参数（build_firmware 的 kwargs 支持 board_id/board_sku/fab/board_rev/chip_sku）
        config_kwargs = dict(
            board_id=req.board_id,
            board_sku=req.board_sku,
            fab=req.fab,
            board_rev=req.board_rev,
            chip_sku=req.chip_sku,
        )

        db_id = store.create_job("thor_build", f"{req.bsp_version} {req.stage}")

        def run_stage(which_stage):
            return build_firmware(
                req.target_board or "jetson-agx-thor-devkit",
                which_stage,
                progress_cb,
                **config_kwargs,
            )

        try:
            if req.stage == "all":
                # 一键全流程
                ok, msg = run_stage(BuildStage.PREPARE)
                if not ok:
                    store.finish_job(db_id, "error", msg)
                    emit(job_id, "done", {"status": "error", "message": msg})
                    return

                ok, msg = run_stage(BuildStage.BUILD)
                if not ok:
                    store.finish_job(db_id, "error", msg)
                    emit(job_id, "done", {"status": "error", "message": msg})
                    return

                ok, msg = run_stage(BuildStage.FLASH)
                store.finish_job(db_id, "ok" if ok else "error", msg)
                emit(job_id, "done", {
                    "status": "ok" if ok else "error",
                    "message": msg,
                })
            else:
                ok, msg = run_stage(stage)
                store.finish_job(db_id, "ok" if ok else "error", msg)
                emit(job_id, "done", {
                    "status": "ok" if ok else "error",
                    "message": msg,
                })
        except Exception as e:
            store.finish_job(db_id, "error", str(e))
            emit(job_id, "done", {"status": "error", "message": str(e)})

    threading.Thread(target=do_build, daemon=True).start()
    return JSONResponse({"job_id": job_id, "status": "started"})


@app.api_route("/api/firmware/thor/check-recovery", methods=["GET", "POST"])
def api_thor_check_recovery():
    """检查 Thor Recovery 模式"""
    devices = check_recovery_mode()
    device = devices.get("thor")
    if device is None:
        return {
            "connected": False,
            "description": "未检测到 Thor Recovery 设备",
            "vendor_id": "",
            "product_id": "",
        }
    return {
        "connected": device.connected,
        "description": device.description,
        "vendor_id": device.vendor_id,
        "product_id": device.product_id,
    }


@app.get("/api/firmware/thor/build/stream/{job_id}")
def api_thor_build_stream(job_id: str):
    return _job_stream(job_id, terminal_events=("done", "error"))


# ---- Hybrid BSP APIs ----

@app.post("/api/firmware/hybrid/backup")
def api_hybrid_backup(req: HybridBackupRequest):
    """Hybrid BSP: 备份 DevKit"""
    job_id = str(uuid.uuid4())[:8]
    get_queue(job_id)

    def do_backup():
        def progress_cb(prog):
            emit(job_id, "progress", {
                "stage": prog.stage.value,
                "message": prog.message,
                "percentage": prog.percentage,
            })

        db_id = store.create_job("hybrid_backup", req.source_board)

        try:
            ok, msg = hybrid_backup(req.source_board, progress_cb)
            store.finish_job(db_id, "ok" if ok else "error", msg)
            emit(job_id, "done", {
                "status": "ok" if ok else "error",
                "message": msg,
            })
        except Exception as e:
            store.finish_job(db_id, "error", str(e))
            emit(job_id, "done", {"status": "error", "message": str(e)})

    threading.Thread(target=do_backup, daemon=True).start()
    return JSONResponse({"job_id": job_id, "status": "started"})


@app.post("/api/firmware/hybrid/prepare-app")
def api_hybrid_prepare_app(req: HybridConfigRequest):
    """Hybrid BSP: 准备 APP-only (移除 DevKit QSPI)"""
    job_id = str(uuid.uuid4())[:8]
    get_queue(job_id)

    def do_prepare():
        def progress_cb(prog):
            emit(job_id, "progress", {
                "stage": prog.stage.value,
                "message": prog.message,
                "percentage": prog.percentage,
            })

        db_id = store.create_job("hybrid_prepare", req.target_board)

        try:
            ok, msg = hybrid_prepare_app_only(req.target_board, progress_cb)
            store.finish_job(db_id, "ok" if ok else "error", msg)
            emit(job_id, "done", {
                "status": "ok" if ok else "error",
                "message": msg,
            })
        except Exception as e:
            store.finish_job(db_id, "error", str(e))
            emit(job_id, "done", {"status": "error", "message": str(e)})

    threading.Thread(target=do_prepare, daemon=True).start()
    return JSONResponse({"job_id": job_id, "status": "started"})


@app.post("/api/firmware/hybrid/generate-qspi")
def api_hybrid_generate_qspi(req: HybridConfigRequest):
    """Hybrid BSP: 生成目标板 QSPI"""
    job_id = str(uuid.uuid4())[:8]
    get_queue(job_id)

    def do_generate():
        def progress_cb(prog):
            emit(job_id, "progress", {
                "stage": prog.stage.value,
                "message": prog.message,
                "percentage": prog.percentage,
            })

        db_id = store.create_job("hybrid_qspi", req.target_board)

        try:
            ok, msg = hybrid_generate_qspi(req.target_board, None, progress_cb)
            store.finish_job(db_id, "ok" if ok else "error", msg)
            emit(job_id, "done", {
                "status": "ok" if ok else "error",
                "message": msg,
            })
        except Exception as e:
            store.finish_job(db_id, "error", str(e))
            emit(job_id, "done", {"status": "error", "message": str(e)})

    threading.Thread(target=do_generate, daemon=True).start()
    return JSONResponse({"job_id": job_id, "status": "started"})


@app.post("/api/firmware/hybrid/assemble")
def api_hybrid_assemble(req: HybridConfigRequest):
    """Hybrid BSP: 组装 mfi"""
    job_id = str(uuid.uuid4())[:8]
    get_queue(job_id)

    def do_assemble():
        def progress_cb(prog):
            emit(job_id, "progress", {
                "stage": prog.stage.value,
                "message": prog.message,
                "percentage": prog.percentage,
            })

        db_id = store.create_job("hybrid_assemble", req.target_board)

        try:
            ok, msg = hybrid_assemble_mfi(req.target_board, progress_cb)
            store.finish_job(db_id, "ok" if ok else "error", msg)
            emit(job_id, "done", {
                "status": "ok" if ok else "error",
                "message": msg,
            })
        except Exception as e:
            store.finish_job(db_id, "error", str(e))
            emit(job_id, "done", {"status": "error", "message": str(e)})

    threading.Thread(target=do_assemble, daemon=True).start()
    return JSONResponse({"job_id": job_id, "status": "started"})


@app.post("/api/firmware/hybrid/flash")
def api_hybrid_flash(req: HybridConfigRequest):
    """Hybrid BSP: 烧录"""
    job_id = str(uuid.uuid4())[:8]
    get_queue(job_id)

    def do_flash():
        def progress_cb(prog):
            emit(job_id, "progress", {
                "stage": prog.stage.value,
                "message": prog.message,
                "percentage": prog.percentage,
            })

        db_id = store.create_job("hybrid_flash", req.target_board)

        try:
            ok, msg = hybrid_flash(req.target_board, progress_cb)
            store.finish_job(db_id, "ok" if ok else "error", msg)
            emit(job_id, "done", {
                "status": "ok" if ok else "error",
                "message": msg,
            })
        except Exception as e:
            store.finish_job(db_id, "error", str(e))
            emit(job_id, "done", {"status": "error", "message": str(e)})

    threading.Thread(target=do_flash, daemon=True).start()
    return JSONResponse({"job_id": job_id, "status": "started"})


@app.api_route("/api/firmware/hybrid/check-recovery", methods=["GET", "POST"])
def api_hybrid_check_recovery():
    """检查 Orin Nano Recovery 模式"""
    devices = check_recovery_mode()
    device = devices.get("orin")
    if device is None:
        return {
            "connected": False,
            "description": "未检测到 Orin Recovery 设备",
            "vendor_id": "",
            "product_id": "",
        }
    return {
        "connected": device.connected,
        "description": device.description,
        "vendor_id": device.vendor_id,
        "product_id": device.product_id,
    }


@app.get("/api/firmware/hybrid/stream/{job_id}")
def api_hybrid_stream(job_id: str):
    return _job_stream(job_id, terminal_events=("done", "error"))
