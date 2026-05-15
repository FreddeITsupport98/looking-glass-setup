# Looking Glass Setup
 small script should be helper for looking glass setup follow upp vfio-script

## Table of Contents
- [Overview](#overview)
- [Quick Start](#quick-start)
- [Self-Deployment](#self-deployment)
- [Usage](#usage)
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

Options:
  --install-script       Copy this script to /usr/local/bin/looking-glass-setup.
  --self-remove          Remove the installed script from /usr/local/bin/looking-glass-setup.
  --create-shortcut      Add a .desktop entry for looking-glass-client.
  --install-completions  Install Fish and Bash shell completions.
  --uninstall, --eject   Uninstall Looking Glass and remove shared-memory config.
  --dry-run              Show what would be done without touching the system.
  --no-tui               Disable TUI (whiptail/dialog) and use plain text prompts.
  --yes, -y              Skip confirmation prompts (use with caution!).
  --help, -h             Show this help text.
```

## Testing

A regression test suite is included under `tests/`.

```bash
bash tests/run_tests.sh
```

Tests cover argument parsing, self-deployment detection, INI merging, display server detection, idempotency, and TUI menu safety.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for a detailed history of changes.
