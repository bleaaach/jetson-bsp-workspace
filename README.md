# Jetson BSP Module Workflow

Scripts for downloading Jetson Linux sources, cross-compiling in-tree
kernel modules for Jetson Linux, and optionally deploying them to a target.

The repository intentionally excludes NVIDIA BSP archives, extracted source
trees, toolchains, build output, firmware, and other generated artifacts.
Run `download-jetson-bsp-sources.sh` or `jetson-bsp-workflow.sh download`
to obtain the required BSP inputs locally.

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
