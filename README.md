# Jetson BSP Module Workflow

Scripts for downloading Jetson Linux sources, cross-compiling in-tree
kernel modules for Jetson Linux, and optionally deploying them to a target.

The repository intentionally excludes NVIDIA BSP archives, extracted source
trees, toolchains, build output, firmware, and other generated artifacts.
Run `setup-workspace.sh` to rebuild every required input from official
sources after a fresh clone, or `download-jetson-bsp-sources.sh` /
`jetson-bsp-workflow.sh download` to fetch just the BSP archives.

## Directory layout

The repo has two levels: this git repo (scripts, web app, docs) and the
sibling directories that hold large/generated material. The SSD root is
one level above the repo (`/media/seeed/bsp-ssd1`).

```text
<ssd-root>/
├── bsp-workspace/            ← this git repo (scripts/web/docs, ~134 files)
│   ├── Scripts               build-*.sh, jetson-*.sh, setup-workspace.sh
│   ├── web/                  FastAPI module manager UI
│   ├── docs/                 investigation notes
│   ├── Downloads/<ver>/      NVIDIA tarballs + compat symlinks (gitignored)
│   ├── Source/<ver>/         kernel source (gitignored)
│   ├── Build/                per-module build trees + deploy dirs (gitignored)
│   └── toolchain/, tools/    cross toolchain + host tools (gitignored)
├── repos/Linux_for_Tegra/    Seeed BSP git repo (own origin, tracked by Seeed)
├── bsp/<ver>/Linux_for_Tegra/  full flashable BSP (NVIDIA base + Seeed + rootfs)
├── sources/                  kernel source home (symlink target for versions with a BSP)
└── builds/                   planned shared build trees (reserved)

Compatibility symlinks keep old paths working:
  bsp-workspace/Linux_for_Tegra                    → repos/Linux_for_Tegra
  Downloads/<ver>/Linux_for_Tegra                  → repos/Linux_for_Tegra
  Downloads/<ver>/plus/Linux_for_Tegra             → bsp/<ver>/Linux_for_Tegra
  Source/<ver>/kernel/kernel-jammy-src           → bsp/<ver>/Linux_for_Tegra/source/kernel/kernel-jammy-src (when BSP exists)
```

Every symlink target is stable; scripts resolve paths through them, so the
repo needs no per-machine edits.

## Basic usage

```bash
./jetson-bsp-workflow.sh info
./jetson-bsp-workflow.sh query pl2303
./jetson-bsp-workflow.sh build pl2303
```

Set `JETSON_BSP_VERSION` to select a BSP release. Set `JETSON_HOST` only
when deploying to a Jetson target.

## Source-To-Production BSP Workflow

`jetson-bsp-release-workflow.sh` combines the source-build and DIY-BSP
processes into one explicit pipeline:

```text
prepare -> build -> flash development device -> configure it -> backup -> package -> massflash
```

The script runs against an extracted `Linux_for_Tegra` workspace. Set the
cross-toolchain prefix before building, then validate the selected board:

```bash
export CROSS_COMPILE="$PWD/aarch64--glibc--stable-2022.08-1/bin/aarch64-buildroot-linux-gnu-"
./jetson-bsp-release-workflow.sh validate --board recomputer-orin-j401
./jetson-bsp-release-workflow.sh build --board recomputer-orin-j401
```

`flash`, `backup`, and `package` require `--yes`. They require a Jetson in
recovery mode. After `flash`, boot the development Jetson and install or
configure the runtime content that the final image must contain. Return it to
recovery mode, then build a mass-flash package:

```bash
./jetson-bsp-release-workflow.sh pipeline --board recomputer-orin-j401 \
    --massflash 5 --yes
```

The workflow orchestration can be checked without a Jetson or NVIDIA BSP
inputs:

```bash
./tests/test-release-workflow.sh
```

This test verifies command wiring and arguments with a temporary fixture. A
real build still requires a complete extracted NVIDIA BSP, and flash/backup
verification requires hardware in recovery mode.

## Scope

The current build path targets drivers already present and registered in the
selected NVIDIA kernel source tree. Standalone DKMS or vendor drivers need a
separate out-of-tree build integration.
