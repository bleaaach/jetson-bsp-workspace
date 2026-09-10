# AGENTS.md — Working in this repo

Fast orientation for AI agents and new maintainers. Read fully before editing.

## Machine facts

- Workspace root: `/media/seeed/bsp-ssd1/bsp-workspace` — on the **external SSD** (`/dev/sdc1`, 234 GB, label `bsp-ssd`).
- The repo is one directory below the SSD root. Siblings hold big material:
  - `../repos/Linux_for_Tegra` — Seeed BSP git repo (own origin: `Seeed-Studio/Linux_for_Tegra`)
  - `../bsp/R36.4.3/Linux_for_Tegra` — full flashable BSP (~136 GB, rootfs + MFI inside)
- Internal SSD partitions (NVMe 1 TB):
  - `/` = `nvme0n1p8` (18 GB, **usually 100% full**) — do not write large files here
  - `/home` = `nvme0n1p9` (121 GB)
  - `Data` (Windows D:) = `nvme0n1p4`, NTFS, not automounted
- `/tmp` lives on `/` and is typically full. **Always set `TMPDIR=/media/seeed/bsp-ssd1/tmp` before builds** or the compiler dies with "no space left on device". It is already exported in `~/.bashrc`.
- GitHub direct connections frequently time out. A local clash proxy runs at `127.0.0.1:7897`. Use `git -c http.proxy=http://127.0.0.1:7897 …` or `curl -x http://127.0.0.1:7897 …` when network calls fail. The Seeed repo has `http.proxy` configured locally so lazy fetches work.

## Layout

```text
/ media/seeed/bsp-ssd1/
├── bsp-workspace/                 ← this git repo (scripts/web/docs only; ~134 files)
│   ├── build-jetson-module.sh     generic in-tree module cross-build: <module> [config] [deps]
│   ├── build-iptable-raw-r36.4.4.sh  full-kernel build for iptable_raw.ko (R36.4.4)
│   ├── build-rtw89-8852be.sh      rtw89/8852be driver build (jp6.2/jp7.2/jp5.1.3)
│   ├── jetson-bsp-workflow.sh     orchestrator: download|init|query|build|push
│   ├── jetson-firmware-build.sh   kernel/firmware rebuild & rootfs install
│   ├── setup-workspace.sh         rebuild ALL BSP inputs after fresh clone
│   ├── download-jetson-bsp-sources.sh  fetch NVIDIA public_sources.tbz2
│   ├── test-jetson-modules.sh / push-test-jetson.sh   module test/push helpers
│   ├── web/                       FastAPI module manager (uvicorn, port 18420)
│   ├── docs/                      investigation notes, one .md per topic
│   ├── Downloads/<ver>/           NVIDIA tarballs + compat symlinks (gitignored)
│   ├── Source/<ver>/              kernel source (gitignored)
│   ├── Build/<ver>-<module>/      build trees & outputs (gitignored)
│   └── toolchain/ tools/          cross compiler + host tools (gitignored)
├── repos/Linux_for_Tegra/         Seeed BSP: clone of Seeed-Studio/Linux_for_Tegra, checked out e.g. r36.4.3
├── bsp/R36.4.3/Linux_for_Tegra/   full flashable BSP: NVIDIA base + Seeed overlay + rootfs
├── sources/  builds/              reserved (shared build trees)
└── tmp/                           TMPDIR for compiles
```

Compatibility symlinks (do not replace with copies):
- `bsp-workspace/Linux_for_Tegra` → `repos/Linux_for_Tegra`
- `Downloads/R36.4.3/Linux_for_Tegra` → `repos/Linux_for_Tegra`
- `Downloads/R36.4.3/plus/Linux_for_Tegra` → `bsp/R36.4.3/Linux_for_Tegra`
- `Source/R36.4.3/kernel/kernel-jammy-src` → `bsp/R36.4.3/Linux_for_Tegra/source/kernel/kernel-jammy-src` (hardlink-preserving rsync must not follow it as if it were a real dir)

## Module build flow

1. Kernel source lives at `Source/<ver>/kernel/kernel-jammy-src` (may be a symlink into the BSP tree). Detect via `find_kernel_source()` in `build-jetson-module.sh`; candidates cover `kernel-jammy-src`, `kernel/kernel-jammy-src`, `kernel-noble`.
2. One build tree per module under `Build/<ver>-<module>/`; modules share `Build/<ver>-shared/` symbol tables when available. Full-kernel scripts (`build-iptable-raw-*`, `build-rtw89-*`) produce their own trees because they rebuild vmlinux/module.symvers.
3. Symbol table pitfall: out-of-tree modules need the kernel's `Module.symvers`/`vmlinux.symvers`. If `dev_coredumpsg` or similar is "undefined", the symbol table predates a full kernel build — reuse one from a full-kernel build tree (`Build/<ver>-*/vmlinux.symvers`, e.g. `R36.4.4-iptable-raw/` or `R36.4.4-rtw89-8852be/kbuild/`).
4. Output `.ko` files: query them with `find Build -name '*.ko'`. Deploy dirs: `Build/<ver>-rtw89-8852be/deploy/` etc.

## Constraints & rules of operation

- **Do not modify anything under `repos/`, `bsp/`, `Source/`, `toolchain/` unless explicitly asked.** They are upstream-checked-out or generated material. `repos/Linux_for_Tegra` is a git checkout with its own remote; its files belong to Seeed's repo. Our repo's tracked files are the scripts, `web/`, `docs/`, and this file.
- Never commit `Downloads/`, `Source/`, `Build/`, `toolchain/`, `tools/`, `*.tbz2`, `Linux_for_Tegra`, `Reference/`, `web/data/` — all gitignored. The GitHub repo is intentionally lightweight; heavy inputs are rebuilt by `setup-workspace.sh`.
- Always set `TMPDIR=/media/seeed/bsp-ssd1/tmp` for compile commands (root `/` is full).
- Proxy: use `http://127.0.0.1:7897` for github.com / developer.nvidia.com if the direct connection stalls.
- `jetson-bsp-workflow.sh query <module>` prints a 4-axis report (source files, Kconfig, .config state, compiled .ko). Useful before editing build scripts.
- The web UI runs on port 18420 (`cd web && python3 run_server.py`); data persists in `web/data/` (gitignored).
- R36.4.3 is the flashable release on this machine (J401). R36.4.4 exists as kernel source only (no full BSP tree).