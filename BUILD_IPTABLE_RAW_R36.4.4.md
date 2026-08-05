# Build And Test `iptable_raw.ko` For Jetson Linux R36.4.4

This procedure builds the IPv4 raw table module for a Seeed reComputer Mini AGX Orin J501 running Jetson Linux R36.4.4.

The requested kernel configuration is:

```text
CONFIG_IP_NF_RAW=m
```

The output module is `iptable_raw.ko`. It depends on `x_tables.ko` and `ip_tables.ko`.

## 1. Confirm The Device Release

Run these commands on the Jetson before building anything on the host PC:

```bash
cat /etc/nv_tegra_release
uname -r
```

Expected values for this document:

```text
# R36 (release), REVISION: 4.4, ...
5.15.148-tegra
```

Do not use source code or a module from a different Jetson Linux release. Kernel module vermagic must match the running kernel.

## 2. Download The Complete BSP Source Bundle

The NVIDIA R36.4.4 release page is:

```text
https://developer.nvidia.com/embedded/jetson-linux-r3644
```

Download **Driver Package (BSP) Sources**, named `public_sources.tbz2`. The generic downloader in this workspace discovers the official release page and source link instead of constructing a download URL:

```bash
cd /home/seeed/bsp-workspace
./download-jetson-bsp-sources.sh R36.4.4
```

The archive is stored at:

```text
/home/seeed/bsp-workspace/Downloads/R36.4.4/public_sources.tbz2
```

Verify it:

```bash
file Downloads/R36.4.4/public_sources.tbz2
tar -tjf Downloads/R36.4.4/public_sources.tbz2 >/dev/null
```

## 3. Extract The Kernel Source

`public_sources.tbz2` is a nested archive. Extract `kernel_src.tbz2`, then extract the full kernel tree:

```bash
mkdir -p /tmp/r3644-source
tar -xjf Downloads/R36.4.4/public_sources.tbz2 \
  -C /tmp/r3644-source Linux_for_Tegra/source/kernel_src.tbz2

mkdir -p Source/R36.4.4
tar -xjf /tmp/r3644-source/Linux_for_Tegra/source/kernel_src.tbz2 \
  -C Source/R36.4.4
```

The kernel source directory is then:

```text
Source/R36.4.4/kernel/kernel-jammy-src
```

For the prepared workspace used here, it is located at:

```text
Source/R36.4.4/kernel-jammy-src
```

Confirm the configuration and build rule:

```bash
rg -n 'CONFIG_IP_NF_RAW=m' \
  Source/R36.4.4/kernel-jammy-src/arch/arm64/configs/defconfig
rg -n 'CONFIG_IP_NF_RAW' \
  Source/R36.4.4/kernel-jammy-src/net/ipv4/netfilter/Makefile
```

For R36.4.4, NVIDIA's arm64 `defconfig` already sets `CONFIG_IP_NF_RAW=m`.

## 4. Install The Cross Toolchain And Host Dependencies

Use the Bootlin gcc 11.3 toolchain linked by the official R36.4.4 release page:

```bash
mkdir -p toolchain
curl -fL --retry 3 --retry-delay 5 \
  -o toolchain/aarch64--glibc--stable-2022.08-1.tar.bz2 \
  https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v3.0/toolchain/aarch64--glibc--stable-2022.08-1.tar.bz2
tar -xjf toolchain/aarch64--glibc--stable-2022.08-1.tar.bz2 -C toolchain
```

The compiler prefix is:

```text
/home/seeed/bsp-workspace/toolchain/aarch64--glibc--stable-2022.08-1/bin/aarch64-buildroot-linux-gnu-
```

The kernel configuration tools require `flex`, `bison`, and `m4`. Install them system-wide when sudo is available:

```bash
sudo apt update
sudo apt install -y flex bison m4 libssl-dev bc
```

The supplied build script also supports workspace-local copies under `tools/host/` when system package installation is unavailable.

## 5. Build The Module

Run the prepared build script:

```bash
cd /home/seeed/bsp-workspace
./build-iptable-raw-r36.4.4.sh
```

The script does the following:

1. Generates the R36.4.4 arm64 default configuration.
2. Preserves `CONFIG_IP_NF_RAW=m`.
3. Sets `CONFIG_LOCALVERSION="-tegra"` so module vermagic matches the Jetson kernel.
4. Builds `Image` to generate `vmlinux` and module version symbols.
5. Builds `x_tables.ko`, `ip_tables.ko`, and `iptable_raw.ko` together so modpost resolves their module-to-module symbols.

The output module is:

```text
/home/seeed/bsp-workspace/Build/R36.4.4-iptable-raw/net/ipv4/netfilter/iptable_raw.ko
```

Validate it on the host PC:

```bash
modinfo Build/R36.4.4-iptable-raw/net/ipv4/netfilter/iptable_raw.ko \
  | grep -E '^(depends|vermagic):'
```

Expected output:

```text
depends:        x_tables,ip_tables
vermagic:       5.15.148-tegra SMP preempt mod_unload modversions aarch64
```

## 6. Copy And Install On The Jetson

Copy the module to the Jetson, replacing `<JETSON_IP>` with its reachable address:

```bash
scp Build/R36.4.4-iptable-raw/net/ipv4/netfilter/iptable_raw.ko \
  seeed@<JETSON_IP>:/tmp/
```

On the Jetson:

```bash
sudo install -D -m 644 /tmp/iptable_raw.ko \
  /lib/modules/$(uname -r)/kernel/net/ipv4/netfilter/iptable_raw.ko
sudo depmod -a
sudo modprobe -v iptable_raw
```

Normally `x_tables.ko` and `ip_tables.ko` are already installed in the NVIDIA image and are automatically loaded as dependencies. Do not overwrite them unless they are absent or you are deploying all three modules from the same matching build.

## 7. Verify Successful Loading

On the Jetson:

```bash
lsmod | grep -E 'iptable_raw|ip_tables|x_tables'
sudo iptables -t raw -L -n -v
```

A successful result includes a line similar to:

```text
iptable_raw            16384  0
```

For this J501 build, the observed loaded dependency chain was:

```text
iptable_raw            16384  0
ip_tables              32768  3 iptable_filter,iptable_raw,iptable_nat
x_tables               49152  11 ... iptable_raw,ip_tables ...
```

If loading fails, collect the kernel error immediately:

```bash
dmesg -T | tail -50
```

To unload the module after testing:

```bash
sudo modprobe -r iptable_raw
```
