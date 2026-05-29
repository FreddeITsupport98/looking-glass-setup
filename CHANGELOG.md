# Changelog

All notable changes to this project are documented in this file.

## Unreleased

- **2026-05-29 19:04** — Added ReBAR 64-bit MMIO VM configuration support.
  - New functions `vm_has_rebar_config()`, `enable_vm_rebar()`, `disable_vm_rebar()`, `configure_vm_rebar()`, and `do_rebar_standalone()`.
  - Adds `xmlns:qemu` namespace to `<domain>` if missing, and inserts `<qemu:commandline>` with `-fw_cfg opt/ovmf/X-PciMmio64Mb,string=65536` before `</domain>`.
  - Disable removes the ReBAR block and cleans up `xmlns:qemu` when no other QEMU elements remain.
  - Both enable and disable use python3 (preferred) or perl as XML transform fallback. Clean temp-file traps on INT/TERM.
  - `configure_vm_rebar()` checks if the VM already has ReBAR — if yes, offers keep/disable; if no, offers enable/skip.
  - Integrated into the install pipeline so ReBAR is prompted automatically after ivshmem setup.
  - New CLI flags: `--enable-rebar` and `--disable-rebar` (standalone actions, target via `--vm-name`).
  - New TUI menu items: "Enable ReBAR on VM" and "Disable ReBAR on VM".
  - Updated Fish and Bash completions.
  - Uninstaller scans for orphan `X-PciMmio64Mb` configs and warns if found.

- **2026-05-21 19:12** — Fixed IVSHMEM duplicate device bug: when switching memory bridge sizes, the old device was not fully removed before attaching a new one, causing two `ivshmem-plain` devices to appear in the VM XML (e.g., bus 0xa device 0x1 and 0x2). Windows then dumped video into bridge 0 while the Linux client read from bridge 1, resulting in a permanently "paused" stream. The fix:
  - `remove_shmem_from_vm()` now loops up to 10 times, removing every matching `ivshmem-plain` device until none remain.
  - The first removal attempt uses a size-aware XML snippet (`<size unit='M'>…</size>`) for precise matching; subsequent fallback attempts use the generic snippet.
  - `get_vm_shmem_size()` now uses `head -n 1` to return only the first `<size>` value, preventing multi-device ambiguity.
  - `configure_libvirt_vm()` now counts `ivshmem-plain` occurrences and warns if duplicates are detected before cleanup.
  - Added `resize_shared_memory()` to resize `/dev/shm/looking-glass` to the target pool size so the new device matches the backing file.
- **2026-05-15 20:43** — Added Fish and Bash shell completions via `install_shell_completions()`, automatically installed when deploying the script. Also adds `--install-completions` standalone flag.
- **2026-05-15 20:43** — Added interactive main TUI menu (`show_main_menu()`) that appears on first run when no explicit action flags are provided, letting users choose Install, Uninstall, Shortcut, Deploy, or Exit via whiptail/dialog/fallback text.
- **2026-05-15 20:38** — Added self-deployment (`--install-script`, `--self-remove`, `--create-shortcut`) allowing the script to copy itself to `/usr/local/bin/looking-glass-setup` and optionally create a `.desktop` shortcut for the Looking Glass client.
- **2026-05-15 20:38** — Added regression test suite (`tests/run_tests.sh`) covering argument parsing, self-deployment, INI merging, display server detection, idempotency, and TUI menu safety.
- **2026-05-15 20:35** — Fixed six critical bugs:
  - **INI ownership preservation**: `merge_ini_setting()` now captures original `stat -c '%u:%g'` and restores ownership after `mv` from temp file, preventing silent root takeover of the user's config.
  - **systemd-tmpfiles crash guard**: `setup_shared_memory()` now checks if `systemd-tmpfiles` exists before calling it, logging a clear fallback message instead of aborting.
  - **killall → pkill**: Replaced `killall` with POSIX `pkill -x` in `do_uninstall()` to avoid crashes on minimal systems lacking `killall`.
  - **TUI menu with spaces**: `configure_libvirt_vm()` now uses numeric indices as tags for `whiptail`/`dialog`, then maps back to the VM array, fixing off-by-one breakage when VM names contain spaces.
  - **Glob-safe INI key matching**: Replaced `== "$key="*` with `${line#"$key="}` prefix removal to prevent accidental glob expansion on keys containing `*`, `?`, or `[`.
  - **Temp XML leak on interrupt**: Added a temporary `trap` around `mktemp`/`virsh attach-device` that cleans up `tmp_xml` on `INT`/`TERM`, then restores the original interrupt handler.
- **2026-05-15 20:33** — Fixed orphan VM hardware trap: `do_uninstall()` now scans all VMs for `ivshmem-plain` devices and emits a `CRITICAL` alert if any remain, warning the user that the VM will refuse to boot without the shared memory file.
- **2026-05-15 20:33** — Fixed SSH/TMUX Wayland blindspot: `detect_display_server()` now iterates over **all** user sessions via `loginctl` instead of stopping at the first match, correctly detecting Wayland even when a headless SSH or tmux session is listed first.
- **2026-05-15 20:28** — Fixed four edge-case bugs:
  - SELinux context now persists across reboots via `semanage fcontext -a -t svirt_tmpfs_t` with fallback warning if `semanage` is missing.
  - Source compilation switched from tarball/curl to `git clone --recurse-submodules` to avoid missing submodule build crashes.
  - Added cold-boot warning after `virsh attach-device` success, reminding the user to fully shut down (not restart) the VM.
  - Increased shared memory device size from `32` to `64` MB for 4K throughput headroom.
- **2026-05-15 20:26** — Added six major features:
  - Non-destructive INI merging (`merge_ini_setting()`) that injects missing keys/sections without overwriting existing user settings.
  - TUI backend auto-detection (`whiptail`/`dialog`) with `--no-tui` override flag.
  - Ubuntu/Debian source compilation bridge (`compile_from_source()`) that clones, builds, and installs `looking-glass-client` to `/usr/local/bin/`.
  - Libvirt VM auto-configuration (`configure_libvirt_vm()`) with TUI menu selection, idempotent `ivshmem-plain` duplication guard, and `--config` attachment.
  - Wayland/X11 display server auto-detection with `fractionalScale=yes` injection for Wayland sessions.
  - Hardware pre-flight checks for KVM, IOMMU, and VFIO kernel modules.
- **2026-05-15 20:26** — Initial safety hardening: added idempotency, `--dry-run`, confirmation prompts, `set -euo pipefail`, `trap` handlers for `ERR`/`INT`/`TERM`, dynamic virtualization group detection (kvm → libvirt → qemu), SELinux `svirt_tmpfs_t`, AppArmor rule injection, and AUR auto-install support.

## [Initial]

- Script created as a basic helper for Looking Glass setup following a VFIO workflow.
