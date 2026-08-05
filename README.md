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

## Scope

The current build path targets drivers already present and registered in the
selected NVIDIA kernel source tree. Standalone DKMS or vendor drivers need a
separate out-of-tree build integration.
