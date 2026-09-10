#!/usr/bin/env python3
"""
Jetson BSP Web Server
Serves the BSP Module Manager UI on port 18420.
"""

import argparse
import sys
from pathlib import Path

# Ensure app/ is importable
sys.path.insert(0, str(Path(__file__).parent))

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Jetson BSP Web Server")
    parser.add_argument("--host", default="0.0.0.0", help="Bind host (default: 0.0.0.0)")
    parser.add_argument("--port", type=int, default=18420, help="Port (default: 18420)")
    parser.add_argument("--reload", action="store_true", help="Enable auto-reload")
    parser.add_argument("--dir", default="/media/seeed/bsp-ssd1/bsp-workspace", help="Workspace directory")
    args = parser.parse_args()

    import uvicorn
    # app/ package and app.py file share a name — import the module explicitly.
    import importlib.util
    spec = importlib.util.spec_from_file_location("_app_module", Path(__file__).parent / "app" / "app.py")
    _app_mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(_app_mod)
    uvicorn.run(
        _app_mod.app,
        host=args.host,
        port=args.port,
        reload=args.reload,
        log_level="info",
    )
