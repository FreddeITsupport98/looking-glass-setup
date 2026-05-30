# Looking Glass Setup
 small script should be helper for looking glass setup follow upp vfio-script

## Table of Contents
- [Overview](#overview)
- [Quick Start](#quick-start)
- [Self-Deployment](#self-deployment)
- [Usage](#usage)
- [How It Works](#how-it-works)
- [Testing](#testing)
- [Changelog](#changelog)

## Overview
This script automates the installation and configuration of Looking Glass for Linux GPU passthrough setups. It supports Fedora/RHEL, Arch Linux, and Ubuntu/Debian.

## Quick Start

```bash
sudo ./look-setup.sh
```

## Self-Deployment

The script can install itself to `/usr/local/bin/looking-glass-setup` so you can run it from anywhere.

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

> **Main TUI Menu:** When you run `sudo ./look-setup.sh` with no extra flags and a TUI backend is available (whiptail or dialog), an interactive menu appears first so you can choose Install, Uninstall, Create Shortcut, Deploy Script, or Exit before anything is modified.

## Usage

```
Usage: sudo ./look-setup.sh [OPTIONS]
```
Options:
  --install-script       Copy this script to /usr/local/bin/looking-glass-setup.
  --self-remove          Remove the installed script from /usr/local/bin/looking-glass-setup.
  --create-shortcut      Add a .desktop entry for looking-glass-client.
  --install-completions  Install Fish and Bash shell completions.
  --uninstall, --eject   Uninstall Looking Glass and remove shared-memory config.
  --dry-run              Show what would be done without touching the system.
  --no-tui               Disable TUI (whiptail/dialog) and use plain text prompts.
  --yes, -y              Skip confirmation prompts (use with caution!).
  --vm-name <name>       Explicitly target a VM by name (bypasses auto-select).
  --shmem-size <MB>      Shared-memory pool size (default: 64). Common: 64 (1080p), 128 (1440p), 256 (4K), 512 (UW 4K).
  --enable-rebar         Enable ReBAR 64-bit MMIO (64GB aperture) on a VM.
  --disable-rebar        Disable ReBAR 64-bit MMIO configuration from a VM.
  --dump-vbios           Dump GPU VBIOS ROM from a PCI passthrough GPU.
  --inject-vbios         Inject VBIOS ROM into a VM's GPU passthrough block.
  --remove-vbios         Remove VBIOS ROM injection from a VM's GPU passthrough.
  --vbios-path <file>    Path to a VBIOS .rom file for injection.
  --help, -h             Show this help text.
```

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

### ReBAR Memory

ReBAR (Resizable BAR) allows the CPU to access the entire GPU VRAM instead of a small 256MB window. For passthrough VMs with large GPUs (8GB+), enabling ReBAR in the BIOS can cause a black screen if the VM's PCI MMIO aperture is too small. The script automates the libvirt QEMU workaround:

- **Enable** — `sudo ./look-setup.sh --enable-rebar` (or via TUI menu) targets the VM, adds the QEMU namespace, and injects the `X-PciMmio64Mb=65536` fw_cfg parameter. This expands the aperture to 64GB.
- **Disable** — `sudo ./look-setup.sh --disable-rebar` cleanly removes the injected XML block.
- **Pre-check** — The script refuses to double-inject; it checks the VM XML for existing ReBAR configuration before adding anything.
- **Requirement** — You must still enable *Above 4G Decoding* and *Resize BAR* in the VM BIOS / UEFI for this to take effect. The script only prepares the virtual motherboard to accommodate it.

### VBIOS ROM Injection

For completely headless GPU passthrough (no VirtIO display attached), some GPUs (especially AMD RX 6000-series and newer) require their physical VBIOS ROM to be available to the virtual BIOS during boot. Without it, the VM may black-screen because the virtual motherboard cannot initialize the GPU.

- **Dump** — `sudo ./look-setup.sh --dump-vbios` detects GPUs bound to `vfio-pci` via `lspci` + `/sys/bus/pci/devices/<addr>/driver`, lets you pick one in the TUI (tagged `[PASSTHROUGH]` for vfio-pci devices), enables the sysfs ROM node, reads it, validates the size (>64KB), and saves it to `/var/lib/libvirt/vbios/vbios_<addr>.rom`. If no vfio-pci GPUs are found, it falls back to all VGA/3D controllers. If the selected GPU is bound to `vfio-pci`, the script prints specific rebinding instructions because the ROM sysfs node is disabled under that driver.
- **Inject** — `sudo ./look-setup.sh --inject-vbios` (or via install flow / TUI) scans for `.rom` files in `/var/lib/libvirt/vbios/` and inserts `<rom file='...'/>` into every PCI `<hostdev>` block of the VM XML. If a `<rom>` tag already exists, it replaces the path. Before writing, the script checks whether the exact same ROM path is already configured; if so, it skips re-definition and reports success.
- **Remove** — `sudo ./look-setup.sh --remove-vbios` deletes the `<rom file='...'/>` tags from all PCI `<hostdev>` blocks. If no VBIOS is configured, it exits cleanly with an informative message.
- **Pre-check** — The install pipeline checks whether the VM already has a VBIOS `<rom>` tag. If yes, it offers keep/remove; if no, it offers inject/skip. It also verifies the VM actually has a PCI passthrough device before offering injection. The standalone `--inject-vbios` path also skips if the same ROM is already present.
- **Requirement** — A full cold shutdown (not restart) of the VM is required after injection for the ROM to be read by the virtual BIOS.

### Uninstall Safety

The uninstall flow is aggressively defensive:

1. Stops any running `looking-glass-client` processes.
2. Removes the `tmpfiles` config and the `/dev/shm/looking-glass` node.
3. Removes the package via the detected package manager (or notes that dependencies remain on Ubuntu).
4. Removes the user INI config.
5. Removes the AppArmor rule and reloads the profile.
6. **Orphan VM scan** — Iterates over **all** libvirt VMs and checks their XML for `ivshmem-plain`. If any are found, it logs a **CRITICAL** alert listing every affected VM and warns that the VM will refuse to boot because the backing shared-memory file is gone. This prevents the "uninstall bricks the VM" trap.
7. If the script was installed to `/usr/local/bin`, it optionally prompts to self-remove via TUI or CLI.
8. Cleans up the desktop shortcut, Fish completions, and Bash completions.

### Why These Design Choices?

- **Non-destructive INI merging** — Users often hand-tune their Looking Glass configs (resolution, spice ports, keybinds). Blindly overwriting the entire file would destroy their work. The merge logic preserves every existing line.
- **Session-loop Wayland detection** — A user might SSH in to run the installer. `loginctl` would list the SSH session first, which has no graphical type. Stopping at the first match would falsely report X11 and skip the `fractionalScale=yes` optimization. Looping through all sessions fixes this.
- **Numeric TUI tags** — `whiptail` and `dialog` treat the argument list as alternating `tag description` pairs. If a VM is named `Windows 10`, the raw name splits into tag=`Windows`, description=`10`, shifting every subsequent entry. Using numeric tags and mapping back to the array eliminates this entirely.
- **Git clone instead of tarball** — The official Looking Glass repository uses submodules for some dependencies. Downloading a GitHub release tarball omits them, causing cryptic build failures. `git clone --recurse-submodules` guarantees a complete source tree.
- **64 MB shmem** — The upstream example uses 32 MB. For 1080p this is fine, but for 4K the frame buffer exceeds 32 MB, causing stuttering or black frames. Bumping to 64 MB removes that bottleneck without being wasteful.
- **Independent file copy** — `cp -f` creates a new inode. The installed copy is not a hardlink or symlink. Editing or deleting the source repository will never break the system-installed binary.

## Testing

A regression test suite is included under `tests/`.

```bash
bash tests/run_tests.sh
```

Tests cover argument parsing, self-deployment detection, INI merging, display server detection, idempotency, and TUI menu safety.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for a detailed history of changes.
