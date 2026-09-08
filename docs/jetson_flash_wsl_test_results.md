# Jetson WSL2 Flash - Solution Found!

**Date:** August 26, 2026
**Environment:** WSL2 (Ubuntu) + Windows USB passthrough
**Device:** Jetson Orin (recomputer-orin-j401) in RCM mode
**USB Device:** NVIDIA Corp. APX (0955:7423)

## TL;DR - Solution Found! ✅

**The problem was:** Multiple sequential USB bulk transfers timeout in WSL2.
**The solution:** Send the entire RCM boot blob (78MB) in ONE bulk transfer!

## How It Works

```
OLD (broken):
  1. Send BCT (8KB) → OK
  2. Send MB1 (280KB) → TIMEOUT ❌
  3. Send PSC_BL1 (123KB) → TIMEOUT ❌
  
NEW (works):
  1. Combine BCT + MB1 + PSC_BL1 + BCT_MB1 → 78MB blob
  2. Send blob in ONE bulk transfer → OK ✅
  3. Device boots into L4T initrd ✅
```

## Quick Start

```bash
# 1. Generate RCM boot blob (no device needed)
./jetson_flash_wsl.sh prepare

# 2. Put device in RCM mode, then:
./jetson_flash_wsl.sh blob-flash

# 3. Wait for device to boot into initrd, then:
cd Linux_for_Tegra
sudo ./flash.sh recomputer-orin-j401 mmcblk0p1
```

## Step-by-Step Guide

### Step 1: Generate RCM Boot Blob (No Device Needed)

```bash
cd /home/seeed/bsp-workspace
./jetson_flash_wsl.sh prepare
```

This creates `Linux_for_Tegra/bootloader/rcmboot_blob/blob.bin` (78MB).

### Step 2: Put Device in RCM Mode

1. Power off the Jetson device
2. Hold the **FORCE_RECOVERY** button
3. Press and release the **POWER** button
4. Release **FORCE_RECOVERY**

The device should now appear as `0955:7423 NVIDIA Corp. APX` in `lsusb`.

### Step 3: Attach USB to WSL2

On Windows PowerShell:
```powershell
# Find the USB bus ID
usbipd list

# Attach to WSL
usbipd bind --busid <BUSID>
wsl -- cd ~ && sudo usbipd attach --busid <BUSID> -d $(wslvar HOSTNAME)
```

In WSL:
```bash
# Attach USB
sudo usbipd attach --busid 1-1 2>/dev/null || true

# Verify device
lsusb | grep 0955
```

### Step 4: Send RCM Boot Blob

```bash
./jetson_flash_wsl.sh blob-flash
```

Or directly with Python:
```bash
python3 jetson_blob_flash.py
```

This will:
1. Connect to the device
2. Send the 78MB blob in ONE bulk transfer
3. Send RCM boot command
4. Device will boot into L4T initrd

### Step 5: Run Full Flash

After the device boots into initrd, the USB device ID will change to something like `0955:7c19`.

```bash
cd Linux_for_Tegra
sudo ./flash.sh recomputer-orin-j401 mmcblk0p1
```

## Why This Works

| Method | Transfer Count | Result |
|--------|----------------|--------|
| Official l4t_initrd_flash.sh | 20+ sequential | ❌ Timeout |
| tegrarcm_v2 --download blob | 1 large | ✅ Works |
| jetson_blob_flash.py | 1 large (78MB) | ✅ Works |

**Key insight:** WSL2 USB passthrough can handle **one** large bulk transfer (tested up to 78MB).
The problem is multiple sequential transfers where the tool expects fast responses.

## Files

| File | Purpose |
|------|---------|
| `jetson_flash_wsl.sh` | Main tool with all commands |
| `jetson_blob_flash.py` | Python tool to send blob in one transfer |
| `jetson_flash_windows.ps1` | Windows SDK Manager launcher |
| `host_run_flash.sh` | Official NVIDIA flash wrapper |

## Commands

```bash
./jetson_flash_wsl.sh detect      # Detect device in RCM mode
./jetson_flash_wsl.sh status       # Show detailed status
./jetson_flash_wsl.sh prepare      # Generate RCM boot blob
./jetson_flash_wsl.sh blob-flash  # Send blob in ONE transfer ⭐
./jetson_flash_wsl.sh flash        # Full flash (try blob-flash first!)
```

## Troubleshooting

### Device not detected
- Make sure device is in RCM mode
- Check `lsusb | grep 0955`
- Try re-attaching USB: `sudo usbipd detach --busid 1-1 && sudo usbipd attach --busid 1-1`

### Blob send fails
- Try detaching and re-attaching USB
- Make sure only one process is using the device
- Check timeout: some large transfers may need more time

### Device doesn't boot into initrd
- Wait 30 seconds after blob send
- Check device serial console for output
- Device may need more time to process the 78MB blob

## Alternative: Windows SDK Manager

If the WSL2 method doesn't work, use Windows SDK Manager:

```powershell
.\jetson_flash_windows.ps1 -LaunchSDK
```

## Technical Details

### RCM Boot Blob Structure

```
blob.bin (78MB) contains:
├── br_bct_BR.bct (8KB)
├── mb1_t234_prod_aligned_sigheader.bin.encrypt (280KB)
├── psc_bl1_t234_prod_aligned_sigheader.bin.encrypt (123KB)
├── mb1_bct_MB1_sigheader.bct.encrypt (17KB)
├── spe_t234_prod.bin (if applicable)
├── xusb_t234_prod.bin (if applicable)
└── boot chain data
```

### USB Endpoints

```
Device: 0955:7423 NVIDIA Corp. APX (RCM mode)
Endpoints:
  - OUT: 0x01 (Bulk OUT)
  - IN: 0x81 (Bulk IN)
Interface: 0
```

## Success Criteria

The workflow is successful when:
1. ✅ Blob send completes without timeout
2. ✅ Device disconnects after RCM boot command
3. ✅ Device reappears as 0955:7c19 (L4T initrd mode)
4. ✅ `./flash.sh` can write to eMMC/SSD
