<p align="center">
  <img src="icon/icon.jpg" alt="Looking Glass Setup" width="400">
</p>

> 🚀 **Step 1 — VFIO Passthrough Required**
>
> If you haven't set up your VFIO GPU passthrough yet, **start here first**:
> 👉 [FreddeITsupport98/VFIO-passthrough](https://github.com/FreddeITsupport98/VFIO-passthrough)
>
> This Looking Glass setup assumes you already have a working passthrough. Complete the VFIO guide above **before** returning to this repo.

---

# Looking Glass Setup

A comprehensive, idempotent auto-manager for Looking Glass on Linux GPU passthrough (VFIO) setups. Supports Fedora/RHEL, Arch Linux, and Ubuntu/Debian with interactive TUI menus, dry-run mode, and deep safety guards.

## Table of Contents
- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Self-Deployment](#self-deployment)
- [Step-by-Step Workflows](#step-by-step-workflows)
  - [1. Fresh Install](#1-fresh-install)
  - [2. Fix Shared Memory Mismatch](#2-fix-shared-memory-mismatch)
  - [3. Enable ReBAR on a VM](#3-enable-rebar-on-a-vm)
  - [4. Dump and Inject VBIOS](#4-dump-and-inject-vbios)
  - [5. Resize Shared Memory Pool](#5-resize-shared-memory-pool)
  - [6. Uninstall Safely](#6-uninstall-safely)
- [CLI Reference](#cli-reference)
- [TUI Menu Reference](#tui-menu-reference)
- [How It Works](#how-it-works)
  - [Execution Pipeline](#execution-pipeline)
  - [Shared Memory Management](#shared-memory-management)
  - [ReBAR 64-bit MMIO](#rebar-64-bit-mmio)
  - [VBIOS ROM Handling](#vbios-rom-handling)
  - [Idempotency & Safety](#idempotency--safety)
  - [SELinux, AppArmor, and Permissions](#selinux-apparmor-and-permissions)
  - [TUI Backend & Fallbacks](#tui-backend--fallbacks)
- [Troubleshooting](#troubleshooting)
- [Testing](#testing)
- [Changelog](#changelog)

## Overview

This script automates the full lifecycle of Looking Glass on a Linux KVM host:

- **Install** — detects your distro, installs or compiles `looking-glass-client`, creates the shared-memory backing file, hardens permissions, and injects the `ivshmem-plain` device into your libvirt VM XML.
- **Configure** — enables ReBAR (Resizable BAR) MMIO aperture, dumps and injects GPU VBIOS ROMs for headless boot, and resizes the shared-memory pool to match your resolution.
- **Repair** — detects and fixes mismatches between the VM's expected `ivshmem` size and the actual `/dev/shm/looking-glass` backing file (the most common QEMU startup crash).
- **Uninstall** — removes packages, config files, and shared-memory nodes, with an **orphan VM scan** that warns if any VM still references the removed `ivshmem` device.

The script is **idempotent**: you can run it repeatedly; it only changes state when needed. It supports `--dry-run` to preview every action without touching the system.

## Prerequisites

1. A **bare-metal** Linux host (the script refuses to run inside a VM).
2. **Root access** (the script auto-elevates with `sudo` if not root).
3. A working VFIO GPU passthrough setup with at least one libvirt VM.
4. `python3` is strongly recommended for XML transformations (perl is a fallback).
5. For the smoothest experience, install `whiptail` or `dialog` (the script can auto-install `newt` on Fedora).

## Quick Start

Run with no arguments to get the interactive TUI menu:

```bash
sudo ./look-setup.sh
```

Or run a specific action directly:

```bash
# Full install pipeline
sudo ./look-setup.sh --install --yes --vm-name GAMING --shmem-size 128

# Fix a shared-memory mismatch
sudo ./look-setup.sh --fix-shmem --vm-name GAMING

# Enable ReBAR 64-bit MMIO
sudo ./look-setup.sh --enable-rebar --vm-name GAMING

# Dump a GPU VBIOS
sudo ./look-setup.sh --dump-vbios

# Inject a VBIOS into a VM
sudo ./look-setup.sh --inject-vbios --vm-name GAMING

# Uninstall everything
sudo ./look-setup.sh --uninstall
```

## Self-Deployment

Install the script to `/usr/local/bin/looking-glass-setup` so you can run it from anywhere:

**Install the script:**
```bash
sudo ./look-setup.sh --install-script
```

**After installation, run directly:**
```bash
sudo looking-glass-setup [OPTIONS]
```

**Remove the installed script:**
```bash
sudo looking-glass-setup --self-remove
```

**Create a desktop shortcut:**
```bash
sudo looking-glass-setup --create-shortcut
```

> **Note:** If you run from source without installing, the script will prompt to deploy itself. You can always decline and continue running from the source file. The installer also drops Fish and Bash completions automatically when it deploys.

---

## Step-by-Step Workflows

### 1. Fresh Install

This is the standard path for a new host or a new VM.

**Step 1 — Start the interactive installer:**

```bash
sudo ./look-setup.sh
```

If `whiptail` or `dialog` is available, a menu appears. Choose **"Install Looking Glass"**.

**Step 2 — Environment checks:**

The script verifies:
- You are on bare metal (not inside a VM).
- `SUDO_USER` is detected so file ownership is preserved.
- A virtualization group (`kvm`, `libvirt`, or `qemu`) exists for permissions.
- `systemd-tmpfiles` is available for persistent shared-memory creation.

**Step 3 — Hardware pre-flight:**

Non-blocking warnings are printed if:
- `/dev/kvm` is missing (BIOS virtualization may be disabled).
- IOMMU groups are missing (bootloader `iommu=pt` may be missing).
- `vfio_pci` module is not loaded.

If KVM is built into the kernel (no loaded `kvm` module), the script detects this and logs an info message instead of a false warning.

**Step 4 — Package installation:**

- **Fedora/RHEL** — enables the `agnelo/looking-glass` COPR and installs `looking-glass-client` via `dnf`.
- **Arch Linux** — installs build deps via `pacman`, then uses `yay` or `paru` to install `looking-glass` from the AUR.
- **Ubuntu/Debian** — installs build deps via `apt`, then clones the official Looking Glass repo with `--recurse-submodules`, builds with `cmake`, and copies the binary to `/usr/local/bin/looking-glass-client`.

**Step 5 — Shared memory setup:**

The script writes `/etc/tmpfiles.d/10-looking-glass.conf` with the syntax:

```
f /dev/shm/looking-glass 0666 <qemu-user> <qemu-group> -
```

This is **idempotent**: if the file already exists with the exact same content, nothing is rewritten. Then `systemd-tmpfiles --create` is executed to create the node immediately.

**Step 6 — Security hardening:**

- **SELinux** — applies `chcon -t svirt_tmpfs_t` immediately. For reboot persistence, runs `semanage fcontext -a -t svirt_tmpfs_t` (warns if `semanage` is missing).
- **AppArmor** — injects `/dev/shm/looking-glass rw,` into `/etc/apparmor.d/local/abstractions/libvirt-qemu` idempotently, then reloads AppArmor.

**Step 7 — User config:**

Detects Wayland vs X11 by querying **all** `loginctl` sessions for the target user (fixes the SSH/tmux blindspot where a headless session is listed first). Writes `~/.looking-glass-client.ini` with non-destructive INI merging:

```ini
[app]
shmFile=/dev/shm/looking-glass

[spice]
enable=yes
audio=yes

[wayland]
fractionalScale=yes   # only if Wayland is detected
```

**Step 8 — VM auto-configuration:**

Lists all libvirt VMs in a TUI menu (numeric tags so spaces in VM names do not break the menu). You pick the target VM.

The script checks the VM XML for existing `ivshmem-plain` devices. If **more than one** is found (e.g., from a previous incomplete swap), it warns and **loops removal** until none remain, then attaches the correct single device. If one exists with a different size than requested, it removes the old device before attaching the new one.

A **cold shutdown** (not restart) is required after this step for the new hardware to appear.

**Step 9 — ReBAR prompt (optional):**

If the VM does not already have ReBAR configured, the script offers to enable it. See the [ReBAR section](#rebar-64-bit-mmio) for details.

**Step 10 — VBIOS prompt (optional):**

If the VM does not already have a VBIOS injected, the script offers to inject one. It auto-discovers dumped ROM files in `/var/lib/libvirt/vbios/` and can also auto-extract from the host GPU. See the [VBIOS section](#vbios-rom-handling) for details.

---

### 2. Fix Shared Memory Mismatch

This is the most common repair path. If QEMU crashes on VM start with:

```
shmmem-shmem0 backing store size 0x4000000 is too small for 'size' option 0x20000000
```

The VM expects a larger `ivshmem` device than the current `/dev/shm/looking-glass` file provides.

**Option A — Interactive menu:**

```bash
sudo looking-glass-setup
# Choose "Fix Shared Memory Mismatch"
# Pick the VM (e.g., GAMING)
```

**Option B — Direct CLI:**

```bash
sudo looking-glass-setup --fix-shmem --vm-name GAMING
```

**What happens:**

1. The script reads the VM XML and extracts the exact `<size unit='M'>` value the VM expects.
2. It checks the current size of `/dev/shm/looking-glass`.
3. If the backing file is already large enough, it reports success and exits.
4. If the backing file is too small, it:
   - Removes the old `/dev/shm/looking-glass` node (to avoid SELinux `svirt_tmpfs_t` EPERM).
   - Recreates and resizes it to match the VM's expected size.
   - Sets ownership to `qemu:qemu` (or `root:root` if the group is missing).
   - Sets permissions to `666`.
   - Re-applies the SELinux `svirt_tmpfs_t` context.
5. You can now start the VM without the QEMU crash.

> **Why remove first?** On SELinux Enforcing systems, the existing node may have a restrictive type (e.g., `svirt_tmpfs_t`) that blocks even root from resizing. Removing and recreating gives a clean writable tmpfs node.

---

### 3. Enable ReBAR on a VM

ReBAR (Resizable BAR) allows the CPU to access the entire GPU VRAM. For passthrough VMs with large GPUs (8GB+), enabling ReBAR in the host BIOS can cause a black screen if the VM's PCI MMIO aperture is too small.

**Enable ReBAR:**

```bash
sudo looking-glass-setup --enable-rebar --vm-name GAMING
```

**Disable ReBAR:**

```bash
sudo looking-glass-setup --disable-rebar --vm-name GAMING
```

**What happens:**

- **Enable** — The script dumps the VM XML, adds `xmlns:qemu="http://libvirt.org/schemas/domain/qemu/1.0"` to `<domain>` if missing, and inserts a `<qemu:commandline>` block with:

  ```xml
  <qemu:arg value='-fw_cfg'/>
  <qemu:arg value='opt/ovmf/X-PciMmio64Mb,string=65536'/>
  ```

  This creates a **64GB PCI MMIO aperture**. The script then redefines the VM.

- **Disable** — The script removes the ReBAR `<qemu:commandline>` block and cleans up the `xmlns:qemu` namespace when no other QEMU elements remain.

- **Pre-check** — The script checks the VM XML before modifying it. If ReBAR is already enabled, it offers to keep or disable it; if not enabled, it offers to enable or skip.

- **Requirement** — You must still enable *Above 4G Decoding* and *Resize BAR* in the VM BIOS/UEFI for this to take effect. The script only prepares the virtual motherboard to accommodate it.

- **Cold shutdown** is required after enable/disable for the change to take effect.

---

### 4. Dump and Inject VBIOS

Some GPUs (especially AMD RX 6000-series and newer) require their physical VBIOS ROM to be available to the virtual BIOS during boot. Without it, the VM may black-screen when no VirtIO display is attached.

#### 4a. Dump the VBIOS from a physical GPU

```bash
sudo looking-glass-setup --dump-vbios
```

**What happens:**

1. The script scans for GPUs bound to `vfio-pci` via `lspci` + `/sys/bus/pci/devices/<addr>/driver`.
2. If no `vfio-pci` GPUs are found, it falls back to all VGA/3D controllers.
3. A TUI menu lets you pick the GPU. The menu shows the driver name next to each GPU; `vfio-pci` devices are tagged `[PASSTHROUGH]`.
4. The script enables the sysfs ROM node (`echo 1 > /sys/.../rom`), reads the ROM, and copies it to `/var/lib/libvirt/vbios/vbios_<addr>.rom`.
5. A **progress bar** is shown during the read:
   - If `pv` is installed, it uses `pv -s <size>` for a real progress bar.
   - Otherwise, it uses GNU `dd status=progress`.
   - If neither is available, it falls back to `cp` with a plain info message.
6. After copying, the script runs **structural validation**:
   - Minimum size check: the ROM must be at least 64 KiB.
   - ROM header check: the first two bytes must be `0x55 0xAA` (standard x86 ROM signature).
   - PCI data structure check: the ROM must contain the `PCIR` signature.
   - If any check fails, the dump is **deleted** and the ROM sysfs node is reset.

> **Note:** If the GPU is bound to `vfio-pci`, the ROM sysfs node is disabled. The script detects this and prints specific rebinding instructions. You can also let the auto-extraction path handle temporary rebinding automatically.

#### 4b. Auto-extract VBIOS during install

During the install pipeline, when the VBIOS configuration step runs, if no `.rom` files exist in `/var/lib/libvirt/vbios/`, the script attempts **auto-extraction** from the host GPU:

1. It parses the VM XML to find PCI passthrough GPU addresses.
2. It first tries GPUs bound to native drivers (no rebind needed).
3. For GPUs bound to `vfio-pci`:
   - If the VM is **running**, it skips rebind to avoid crashing the VM.
   - If the VM is **shut down**, it temporarily unbinds the GPU from `vfio-pci`, dumps the ROM, then rebinds it back.
   - With `--yes`, it proceeds automatically; otherwise it asks for confirmation.

#### 4c. Inject the VBIOS into a VM

```bash
sudo looking-glass-setup --inject-vbios --vm-name GAMING
```

**What happens:**

1. The script scans `/var/lib/libvirt/vbios/` for `.rom` files.
2. If multiple exist, a TUI picker is shown. If only one exists, it is auto-selected.
3. The script parses the VM XML and inserts `<rom file='...'/>` into every `<hostdev type='pci'>` block.
4. If a `<rom>` tag already exists, it replaces the path.
5. Before writing, the script checks whether the exact same ROM path is already configured; if so, it skips re-definition and reports success.
6. The VM is redefined with the modified XML.

**Remove VBIOS:**

```bash
sudo looking-glass-setup --remove-vbios --vm-name GAMING
```

**Cold shutdown** is required after injection or removal for the change to take effect.

---

### 5. Resize Shared Memory Pool

If you upgrade your monitor resolution (e.g., from 1080p to 4K), you need a larger shared-memory pool.

**During install:**

Pass `--shmem-size` explicitly:

```bash
sudo looking-glass-setup --install --shmem-size 256 --vm-name GAMING
```

Or use the interactive menu when the script prompts you to change the existing ivshmem size.

**Size guide:**

| Size  | Resolution                    |
|-------|-------------------------------|
| 64 MB | Full HD / 1080p               |
| 128 MB| 1440p / QHD                   |
| 256 MB| 4K / UHD                      |
| 512 MB| Ultrawide 4K / High Refresh   |

**What happens:**

1. The script removes the old `ivshmem-plain` device from the VM XML (looping until none remain, to avoid duplicates).
2. It attaches a new device with the requested size.
3. It resizes `/dev/shm/looking-glass` to match.
4. It reapplies ownership (`qemu:qemu`), permissions (`666`), and SELinux context (`svirt_tmpfs_t`).

---

### 6. Uninstall Safely

```bash
sudo looking-glass-setup --uninstall
```

**What happens:**

1. Stops any running `looking-glass-client` processes (`TERM`, then `KILL` if needed).
2. Removes `/etc/tmpfiles.d/10-looking-glass.conf` and the `/dev/shm/looking-glass` node.
3. Removes the package via the detected package manager (or notes that dependencies remain on Ubuntu).
4. Removes the user INI config (`~/.looking-glass-client.ini`).
5. Removes the AppArmor rule and reloads the profile.
6. **Orphan VM scan** — iterates over **all** libvirt VMs and checks their XML for `ivshmem-plain`. If any are found, it logs a **CRITICAL** alert listing every affected VM and warns that the VM will refuse to boot because the backing shared-memory file is gone.
7. ReBAR orphan scan — warns if any VM still has `X-PciMmio64Mb` configured.
8. VBIOS orphan scan — warns if any VM still has `<rom file=` configured.
9. Optionally prompts to self-remove the script from `/usr/local/bin`.
10. Cleans up desktop shortcuts, Fish completions, and Bash completions.

---

## CLI Reference

```
Usage: sudo ./look-setup.sh [OPTIONS]

Options:
  --install-script       Copy this script to /usr/local/bin/looking-glass-setup.
  --self-remove          Remove the installed script from /usr/local/bin.
  --create-shortcut      Add a .desktop entry for looking-glass-client.
  --install-completions  Install Fish and Bash shell completions.
  --uninstall, --eject   Uninstall Looking Glass and remove shared-memory config.
  --dry-run              Show what would be done without touching the system.
  --no-tui               Disable TUI (whiptail/dialog) and use plain text prompts.
  --yes, -y              Skip confirmation prompts (use with caution!).
  --vm-name <name>       Explicitly target a VM by name (bypasses auto-select).
  --shmem-size <MB>      Shared-memory pool size (default: 64).
                         Common: 64 (1080p), 128 (1440p), 256 (4K), 512 (UW 4K).
  --enable-rebar         Enable ReBAR 64-bit MMIO (64GB aperture) on a VM.
  --disable-rebar        Disable ReBAR 64-bit MMIO configuration from a VM.
  --dump-vbios           Dump GPU VBIOS ROM from a PCI passthrough GPU.
  --inject-vbios         Inject VBIOS ROM into a VM's GPU passthrough block.
  --remove-vbios         Remove VBIOS ROM injection from a VM's GPU passthrough.
  --fix-shmem            Resize /dev/shm/looking-glass to match VM ivshmem
                         size and fix ownership/permissions/SELinux.
  --vbios-path <file>    Path to a VBIOS .rom file for injection.
  --help, -h             Show this help text.
```

---

## TUI Menu Reference

When you run `sudo looking-glass-setup` with no extra flags and a TUI backend is available, the following menu appears:

| Menu Item                     | Action                                              |
|-------------------------------|-----------------------------------------------------|
| Install Looking Glass         | Full install pipeline (packages, shmem, VM, etc.)   |
| Uninstall Looking Glass       | Full uninstall pipeline with orphan VM scan           |
| Create Desktop Shortcut       | Write .desktop entry and exit                         |
| Install Script to PATH        | Copy to /usr/local/bin and exit                     |
| Enable ReBAR on VM            | Enable ReBAR 64-bit MMIO on selected VM             |
| Disable ReBAR on VM           | Disable ReBAR on selected VM                        |
| Dump GPU VBIOS                | Extract VBIOS ROM from a physical GPU               |
| Inject VBIOS to VM            | Inject a ROM file into the VM's PCI passthrough     |
| Remove VBIOS from VM          | Remove ROM injection from the VM                    |
| Fix Shared Memory Mismatch    | Resize shmem backing file to match VM ivshmem     |
| Exit                          | Quit without changes                                |

If `whiptail`/`dialog` fails (e.g., TTY issues under `sudo sh`), the script automatically falls back to a plain text prompt with the same numbered options.

---

## How It Works

This section is a deep-dive into the internal mechanics, safety guarantees, and design decisions baked into the script. If you want to understand *why* it does what it does, read this.

### Execution Flow

When you run the script it follows a strict pipeline:

1. **Argument Parsing (`parse_args`)** — Every flag is parsed in a `while` loop. Unknown flags immediately abort with an error. Flags like `--install-script`, `--self-remove`, `--create-shortcut`, and `--install-completions` are treated as one-shot actions: they execute and exit immediately without touching anything else. This prevents accidental side-effects when the user only wanted a single task.

2. **TUI Backend Detection (`detect_tui_backend`)** — Before any user interaction, the script probes the system for `whiptail` or `dialog`. If neither is found, or if `--no-tui` / `--dry-run` / `--yes` are set, it falls back to plain text prompts. The detected backend is stored in `TUI_BACKEND` and reused for every subsequent interactive call.

3. **Main Menu (`show_main_menu`)** — If no explicit action flag was passed, the script presents an interactive menu (whiptail/dialog or plain text) with five choices:
   - **Install Looking Glass** — proceeds to the full install pipeline.
   - **Uninstall Looking Glass** — proceeds to the full uninstall pipeline.
   - **Create Desktop Shortcut** — writes the `.desktop` file and exits.
   - **Install Script to PATH** — copies the script to `/usr/local/bin/looking-glass-setup` and exits.
   - **Exit** — does nothing and exits cleanly.

4. **Environment Checks (`detect_environment`)** — Before any system modification, the script verifies:
   - **Root privileges** — required for writing system files, installing packages, and modifying libvirt XML.
   - **Bare-metal host** — uses `systemd-detect-virt`, DMI vendor strings, and product name heuristics to reject virtual machines. Looking Glass is a bare-metal client; running the installer inside a VM would be nonsensical.
   - **Non-root user detection** — reads `SUDO_USER` to identify the actual desktop user so file ownership can be preserved.
   - **Virtualization group detection** — scans for `kvm`, `libvirt`, or `qemu` groups in that precedence order. The first match is used for shared-memory permissions.
   - **`systemd-tmpfiles` availability** — warns if absent, because the persistent shared-memory node relies on it.

5. **Pre-flight Hardware (`preflight_hardware`)** — Non-blocking checks that log warnings if KVM, IOMMU, or VFIO kernel modules are missing. These do **not** abort the script; the user may be running the installer before BIOS configuration is complete.

6. **Package Installation (`do_install`)** — The script detects the package manager (`dnf`, `pacman`, `apt`) and takes the appropriate path:
   - **Fedora/RHEL** — enables the `agnelo/looking-glass` COPR if not already active, then installs `looking-glass-client` via `dnf`.
   - **Arch Linux** — installs build dependencies via `pacman`, then uses `yay` or `paru` (as the detected non-root user) to install `looking-glass` from the AUR. If no AUR helper is found, it warns and continues.
   - **Ubuntu/Debian** — installs all build dependencies via `apt`, then calls `compile_from_source()` which clones the official Looking Glass repository with `--recurse-submodules`, builds the client with `cmake` + `make`, and copies the binary to `/usr/local/bin/looking-glass-client`.

7. **Shared Memory (`setup_shared_memory`)** — Writes a `systemd-tmpfiles` rule to `/etc/tmpfiles.d/10-looking-glass.conf` with the syntax `f /dev/shm/looking-glass 0660 <user> <group> -`. This is **idempotent**: if the file already exists with the exact same content, nothing is rewritten. After writing, `systemd-tmpfiles --create` is executed to create the node immediately (with a graceful fallback if `systemd-tmpfiles` is missing).

8. **Security Hardening (`setup_security`)** —
   - **SELinux** — if active, applies `chcon -t svirt_tmpfs_t` to the shared-memory node immediately. For reboot persistence, it runs `semanage fcontext -a -t svirt_tmpfs_t` (with a warning if `semanage` is missing).
   - **AppArmor** — if `aa-status` is present, the script injects `/dev/shm/looking-glass rw,` into `/etc/apparmor.d/local/abstractions/libvirt-qemu` using an idempotent append function that skips the line if it already exists, then reloads AppArmor.

9. **User Config (`generate_user_config`)** — Detects the desktop session type (Wayland vs X11) by querying **all** `loginctl` sessions for the target user, not just the first one. This fixes the SSH/tmux blindspot: if a headless session is listed first, the loop continues until it finds a graphical one. The result is used to write a `~/.looking-glass-client.ini` with non-destructive INI merging.

10. **VM Auto-Configuration (`configure_libvirt_vm`)** — If `virsh` is available and connected, the script lists all VMs, presents them in a TUI menu with numeric indices (so VM names with spaces do not break the menu), and lets the user pick one. It checks the VM XML for existing `ivshmem-plain` devices. If **more than one** is found (e.g. from a previous incomplete swap), the script warns and **loops removal** until none remain, then attaches the correct single device. If only one exists with a different size than requested, it removes the old device before attaching the new one. The temporary XML file is protected by a trap that cleans it up on `SIGINT`/`SIGTERM`. After attachment, the script warns that a **full cold shutdown** (not a restart) is required for the hardware to appear.

11. **ReBAR VM Configuration (`configure_vm_rebar`)** — Prompts to enable or disable ReBAR 64-bit MMIO on the target VM. When enabled, the script adds `xmlns:qemu="http://libvirt.org/schemas/domain/qemu/1.0"` to the `<domain>` element and inserts `<qemu:commandline>` with `-fw_cfg opt/ovmf/X-PciMmio64Mb,string=65536` between `</devices>` and `</domain>`. This creates a 64GB PCI MMIO aperture so large GPUs (e.g., 16GB with ReBAR) do not black-screen. The script first checks whether the VM already has the ReBAR block. If it does, it offers to keep or remove it; if not, it offers to enable or skip. Disable removes the block and cleans up the namespace when no other QEMU elements remain. Both enable and disable use python3 for precise XML transformation, with perl as a fallback. The installer also warns that a full cold shutdown is required for the change to take effect.

12. **VBIOS ROM Injection (`configure_vm_vbios`)** — Prompts to inject or remove a GPU VBIOS ROM file into the VM's PCI passthrough `<hostdev>` block. This is required for completely headless operation (no VirtIO display attached) on some AMD GPUs that need their physical VBIOS to boot. The script can dump the VBIOS from a physical GPU via `/sys/bus/pci/devices/<addr>/rom` (`--dump-vbios`), stores it in `/var/lib/libvirt/vbios/`, and then injects `<rom file='...'/>` into every `<hostdev type='pci'>` block of the VM XML. If a `<rom>` tag already exists, it replaces the path. Removal deletes the `<rom>` tags. The injection uses python3 regex-based XML transformation and warns that a full cold shutdown is required. During the install pipeline, the script auto-discovers dumped ROM files and presents a TUI selector when multiple exist.

13. **Shell Completions (`install_shell_completions`)** — Installs Fish completions to `/usr/share/fish/vendor_completions.d/looking-glass-setup.fish` and Bash completions to `/usr/share/bash-completion/completions/looking-glass-setup`. Both are generated from the current flag list and are cleaned up during `--self-remove`.

### Idempotency & Safety

The script is designed to be **safe to re-run** without side effects:

- **Idempotent writes** — `write_tmpfiles_idempotent` hashes the first line of the target file; if it matches, the file is left untouched.
- **Idempotent appending** — `append_apparmor_rule_idempotent` greps for the exact rule before writing.
- **Idempotent INI merging** — `merge_ini_setting` scans the target section for an existing key; if found, it does **not** overwrite the user's value. It only appends missing keys or missing sections. After a temp-file rewrite, it restores the original `uid:gid` ownership so the desktop user retains write access.
- **Dry-run mode** — `--dry-run` prints every action without executing it. The `run_or_simulate` wrapper is used for every destructive command.
- **Confirmation gates** — `confirm_or_exit` pauses before any package install, uninstall, or system modification unless `--yes` is passed.
- **Error traps** — `set -euo pipefail` is active. An `ERR` trap logs the exact line number and exit code. `INT`/`TERM` traps log a clean abort message.
- **Process termination** — During uninstall, the script uses `pgrep` to detect `looking-glass-client`, then sends `TERM` followed by `KILL` if needed, using `pkill -x` (POSIX, no dependency on `killall`).

### Shared Memory Management

The shared-memory file is the frame buffer between the guest GPU and the host `looking-glass-client`. The script manages it through three layers:

- **Persistence** — `systemd-tmpfiles` recreates the node on every boot with the correct permissions.
- **Resizing** — The script removes the old node before resizing to avoid SELinux EPERM, then recreates and re-applies context.
- **Mismatch Repair** — The `--fix-shmem` path detects when the VM XML expects a different size than the backing file and reconciles them automatically.

### ReBAR 64-bit MMIO

ReBAR allows the CPU to access the entire GPU VRAM. For passthrough VMs with large GPUs, the default PCI MMIO aperture (256MB) is too small, causing black screens.

- **Enable** — Expands the aperture to 64GB via QEMU `fw_cfg`.
- **Disable** — Removes the configuration cleanly.
- **Requirement** — *Above 4G Decoding* and *Resize BAR* must still be enabled in the VM BIOS/UEFI.

### VBIOS ROM Handling

For completely headless GPU passthrough (no VirtIO display), some GPUs need their physical VBIOS available to the virtual BIOS.

- **Dump** — Reads from `/sys/bus/pci/devices/<addr>/rom` with progress bar (`pv` or `dd status=progress`). Validates structurally (`0x55 0xAA` header + `PCIR` signature). Removes invalid dumps automatically.
- **Auto-extract** — During install, attempts to extract from native-driver GPUs first. For `vfio-pci` GPUs, temporarily rebinds, dumps, and rebinds back (only if VM is shut down).
- **Inject** — Inserts `<rom file='...'/>` into every PCI `<hostdev>` block. Replaces existing `<rom>` paths. Skips if the same path is already present.
- **Remove** — Deletes `<rom>` tags from all PCI `<hostdev>` blocks.

### SELinux, AppArmor, and Permissions

- **SELinux** — The shared-memory node is labeled `svirt_tmpfs_t` so QEMU can access it. The script applies this immediately with `chcon` and persistently with `semanage fcontext`.
- **AppArmor** — A local abstraction rule is appended to `/etc/apparmor.d/local/abstractions/libvirt-qemu` granting read/write access to `/dev/shm/looking-glass`. This is done idempotently and the profile is reloaded.
- **Ownership** — The shared-memory node is owned by the `qemu` user and group (or `root` if `qemu` does not exist) with mode `666` so both the host client and guest QEMU can access it.

### TUI Backend & Fallbacks

- **Auto-detection** — `whiptail` is preferred, then `dialog`. If neither is found, the script attempts to auto-install `newt` (Fedora), `whiptail` (Debian), or `libnewt` (Arch).
- **Failure fallback** — If `whiptail`/`dialog` exits with a code other than 0 (success) or 1 (user cancel), the script assumes a TTY allocation failure and falls back to plain text prompts automatically.
- **Numeric tags** — VM names with spaces are handled by using numeric indices as TUI tags and mapping back to the VM array, preventing off-by-one menu corruption.

### Why These Design Choices?

- **Non-destructive INI merging** — Users often hand-tune their Looking Glass configs (resolution, spice ports, keybinds). Blindly overwriting the entire file would destroy their work. The merge logic preserves every existing line.
- **Session-loop Wayland detection** — A user might SSH in to run the installer. `loginctl` would list the SSH session first, which has no graphical type. Stopping at the first match would falsely report X11 and skip the `fractionalScale=yes` optimization. Looping through all sessions fixes this.
- **Numeric TUI tags** — `whiptail` and `dialog` treat the argument list as alternating `tag description` pairs. If a VM is named `Windows 10`, the raw name splits into tag=`Windows`, description=`10`, shifting every subsequent entry. Using numeric tags and mapping back to the array eliminates this entirely.
- **Git clone instead of tarball** — The official Looking Glass repository uses submodules for some dependencies. Downloading a GitHub release tarball omits them, causing cryptic build failures. `git clone --recurse-submodules` guarantees a complete source tree.
- **64 MB shmem** — The upstream example uses 32 MB. For 1080p this is fine, but for 4K the frame buffer exceeds 32 MB, causing stuttering or black frames. Bumping to 64 MB removes that bottleneck without being wasteful.
- **Independent file copy** — `cp -f` creates a new inode. The installed copy is not a hardlink or symlink. Editing or deleting the source repository will never break the system-installed binary.

## Troubleshooting

### 1. QEMU crashes on VM start with “backing store size … is too small”

**Cause:** The VM XML expects an `ivshmem-plain` size larger than the current `/dev/shm/looking-glass` file.

**Fix:**
```bash
sudo looking-glass-setup --fix-shmem --vm-name <VM>
```
Or run the TUI and choose **Fix Shared Memory Mismatch**. The script reads the expected size from the VM XML, removes the old node (to avoid SELinux EPERM), and recreates it with correct ownership and permissions.

### 2. Black screen inside the VM after install

**Cause:** The guest GPU was not initialized because the VM was only restarted, not fully shut down.

**Fix:** Perform a **full cold shutdown** (power off, not restart) of the VM. The new `ivshmem-plain`, ReBAR, or VBIOS device only appears on a cold boot.

### 3. SELinux blocks QEMU from accessing `/dev/shm/looking-glass`

**Symptom:** The VM starts but the Looking Glass client shows a black frame, or QEMU logs an AVC denial.

**Fix:** The script applies `chcon -t svirt_tmpfs_t` immediately and `semanage fcontext` for reboot persistence. If `semanage` is missing, install `policycoreutils-python-utils` (Fedora) or `selinux-policy-devel` and re-run the installer.

### 4. TUI menu is garbled or does not appear

**Cause:** `whiptail` or `dialog` failed to allocate a TTY (common under `sudo sh` or SSH).

**Fix:** Use `--no-tui` for plain text prompts, or run from a local terminal. The script also auto-detects the failure and falls back to text mode when `whiptail` exits with an unexpected code.

### 5. VBIOS dump is 0 bytes or fails validation

**Cause:** The GPU is bound to `vfio-pci`, which disables the sysfs ROM node.

**Fix:**
- Run `--dump-vbios` and select a GPU still bound to a native driver (e.g., `amdgpu` or `nvidia`).
- Or let the install pipeline auto-extract: it temporarily rebinds the GPU away from `vfio-pci`, dumps the ROM, and rebinds back (only when the VM is shut down).
- If the dump is under 64 KiB or fails the `0x55 0xAA` / `PCIR` checks, the script auto-deletes it. Try another GPU or verify with `rom-parser`.

### 6. VM refuses to boot after uninstall

**Cause:** The uninstaller removed `/dev/shm/looking-glass`, but a VM still has `ivshmem-plain` in its XML.

**Fix:** Re-run the installer with `--install --vm-name <VM>` to re-attach the shared-memory device, or manually edit the VM XML and remove the `<shmem>` block. The uninstaller prints a **CRITICAL** alert with every affected VM name when this orphan condition is detected.

## Testing

A regression test suite is included under `tests/`.

```bash
bash tests/run_tests.sh
```

Tests cover argument parsing, self-deployment detection, INI merging, display server detection, idempotency, and TUI menu safety.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for a detailed history of changes.
