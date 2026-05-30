#!/bin/bash
# ---------------------------------------------------------
# Looking Glass Auto-Manager (Install / Uninstall)
# Idempotent: safe to re-run; only changes state when needed.
# Features: Modular, Leveled Logging (Color), Pre-flight checks,
#           SELinux/AppArmor, Smart Wayland/X11 Detection.
# No auxiliary backup files are created.
# ---------------------------------------------------------

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_SOURCE_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
INSTALLED_PATH="/usr/local/bin/looking-glass-setup"
DRY_RUN=false
YES=false
MODE="install"
LOG_FILE="/var/log/looking-glass-setup.log"
NO_TUI=false
TUI_BACKEND="none"
VM_NAME=""
LG_SHMEM_SIZE=""
VBIOS_DIR="/var/lib/libvirt/vbios"
VBIOS_FILE=""

# --- Colors -----------------------------------------------------------------
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_CYAN='\033[0;36m'
C_NC='\033[0m'

# --- Leveled Logging --------------------------------------------------------
log() {
    local level
    local msg
    local timestamp
    local color
    local prefix
    level="$1"
    msg="$2"
    color="${C_NC}"
    prefix="[MSG]"

    case "$level" in
        INFO)    color="${C_CYAN}"   ; prefix="[INFO]" ;;
        SUCCESS) color="${C_GREEN}"  ; prefix="[OK]" ;;
        WARN)    color="${C_YELLOW}" ; prefix="[WARN]" ;;
        ERROR)   color="${C_RED}"    ; prefix="[ERROR]" ;;
    esac

    printf "${color}%s %s${C_NC}\n" "$prefix" "$msg" >&2

    if [[ "$DRY_RUN" == false ]]; then
        timestamp="[$(date +'%Y-%m-%d %H:%M:%S')]"
        (
            printf "%s %s %s\n" "$timestamp" "$prefix" "$msg" >> "$LOG_FILE"
        ) 2>/dev/null || true
    fi
}

cleanup_on_error() {
    local exit_code
    exit_code=$?
    log "ERROR" "Script failed at line ${BASH_LINENO[0]} (exit code: $exit_code)."
    exit "$exit_code"
}

trap cleanup_on_error ERR
trap 'log "WARN" "Interrupted by user."; exit 130' INT TERM

# --- Helpers ----------------------------------------------------------------
run_or_simulate() {
    if [[ "$DRY_RUN" == true ]]; then
        log "INFO" "[DRY-RUN] Would run: $*"
    else
        "$@"
    fi
}

confirm_or_exit() {
    local msg
    msg="$1"
    if [[ "$YES" == true ]]; then
        return 0
    fi
    if [[ "$TUI_BACKEND" != "none" && "$TUI_BACKEND" != "" ]]; then
        if ! tui_yesno "Looking Glass Setup" "$msg"; then
            log "WARN" "Aborted by user."
            exit 0
        fi
        return 0
    fi
    echo ""
    printf "${C_YELLOW}? %s [y/N] ${C_NC}" "$msg"
    read -r answer
    case "$answer" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) log "WARN" "Aborted by user." && exit 0 ;;
    esac
}

write_tmpfiles_idempotent() {
    local file
    local content
    local existing
    file="$1"
    content="$2"
    if [[ -f "$file" ]]; then
        existing="$(head -n 1 "$file")"
        if [[ "$existing" == "$content" ]]; then
            log "SUCCESS" "tmpfiles config already up to date."
            return 0
        fi
        log "INFO" "Updating tmpfiles config…"
    else
        log "INFO" "Creating tmpfiles config…"
    fi
    if [[ "$DRY_RUN" == true ]]; then
        log "INFO" "[DRY-RUN] Would write to $file: $content"
    else
        echo "$content" > "$file"
    fi
}

append_apparmor_rule_idempotent() {
    local file
    local rule
    file="$1"
    rule="$2"
    if [[ ! -f "$file" ]]; then
        log "WARN" "AppArmor local abstraction file missing; skipping."
        return 0
    fi
    if grep -qF "$rule" "$file" 2>/dev/null; then
        log "SUCCESS" "AppArmor rule already present in $(basename "$file")."
        return 0
    fi
    if [[ "$DRY_RUN" == true ]]; then
        log "INFO" "[DRY-RUN] Would append to $file: $rule"
    else
        printf '%s\n' "$rule" >> "$file"
    fi
}

# --- Self-deployment --------------------------------------------------------
is_script_installed() {
    if [[ -f "$INSTALLED_PATH" ]] && [[ "$(realpath "$INSTALLED_PATH" 2>/dev/null || echo "")" == "$(realpath "$SCRIPT_SOURCE_PATH" 2>/dev/null || echo "__source__")" ]]; then
        return 0
    fi
    return 1
}

install_script() {
    detect_tui_backend
    log "INFO" "Deploying script to $INSTALLED_PATH …"
    if [[ "$DRY_RUN" == true ]]; then
        log "INFO" "[DRY-RUN] Would copy $SCRIPT_SOURCE_PATH -> $INSTALLED_PATH and chmod +x"
        return 0
    fi
    if [[ ! -f "$SCRIPT_SOURCE_PATH" ]]; then
        log "ERROR" "Cannot locate source script at $SCRIPT_SOURCE_PATH"
        return 1
    fi
    if cp -f "$SCRIPT_SOURCE_PATH" "$INSTALLED_PATH"; then
        chmod +x "$INSTALLED_PATH"
        log "SUCCESS" "Script installed. You can now run: looking-glass-setup [OPTIONS]"
        log "INFO" "TUI backend: ${TUI_BACKEND}"
        install_shell_completions
        log "INFO" ""
        log "INFO" "Quick reference for installed command:"
        log "INFO" "  sudo looking-glass-setup              # Interactive TUI menu"
        log "INFO" "  sudo looking-glass-setup --install    # Install Looking Glass"
        log "INFO" "  sudo looking-glass-setup --uninstall    # Uninstall Looking Glass"
        log "INFO" "  sudo looking-glass-setup --self-remove  # Remove this script from PATH"
        log "INFO" "  sudo looking-glass-setup --dry-run      # Preview changes without applying"
        log "INFO" "  sudo looking-glass-setup --yes          # Skip all confirmation prompts"
        log "INFO" "  sudo looking-glass-setup --help         # Show full help"
        log "INFO" "  sudo looking-glass-setup --enable-rebar    # Enable ReBAR 64-bit MMIO on VM"
        log "INFO" "  sudo looking-glass-setup --disable-rebar   # Disable ReBAR 64-bit MMIO on VM"
        log "INFO" "  sudo looking-glass-setup --dump-vbios      # Dump GPU VBIOS ROM"
        log "INFO" "  sudo looking-glass-setup --inject-vbios  # Inject VBIOS into VM GPU passthrough"
        log "INFO" "  sudo looking-glass-setup --remove-vbios  # Remove VBIOS from VM GPU passthrough"
    else
        log "ERROR" "Failed to copy script to $INSTALLED_PATH. Are you root?"
        return 1
    fi
}

remove_script() {
    log "INFO" "Removing deployed script from $INSTALLED_PATH …"
    if [[ "$DRY_RUN" == true ]]; then
        log "INFO" "[DRY-RUN] Would remove $INSTALLED_PATH and desktop entry"
        return 0
    fi
    if [[ -f "$INSTALLED_PATH" ]]; then
        if rm -f "$INSTALLED_PATH"; then
            log "SUCCESS" "Removed $INSTALLED_PATH"
        else
            log "ERROR" "Failed to remove $INSTALLED_PATH. Are you root?"
            return 1
        fi
    else
        log "INFO" "No installed script found at $INSTALLED_PATH."
    fi
    # Clean up desktop entry if present
    if [[ -f /usr/local/share/applications/looking-glass-client.desktop ]]; then
        rm -f /usr/local/share/applications/looking-glass-client.desktop
        log "SUCCESS" "Removed desktop shortcut."
    fi
    # Clean up user Desktop copy
    local target_user target_home desktop_dir
    target_user="${REAL_USER:-${SUDO_USER:-}}"
    if [[ -z "$target_user" || "$target_user" == "root" ]]; then
        target_user="${USER:-}"
    fi
    if [[ -n "$target_user" && "$target_user" != "root" ]]; then
        target_home="$(getent passwd "$target_user" | cut -d: -f6)"
        desktop_dir="$target_home/Desktop"
        if [[ -f "$desktop_dir/looking-glass-client.desktop" ]]; then
            rm -f "$desktop_dir/looking-glass-client.desktop"
            log "SUCCESS" "Removed desktop shortcut from $desktop_dir."
        fi
    fi
    # Clean up shell completions
    if [[ -f /usr/share/fish/vendor_completions.d/looking-glass-setup.fish ]]; then
        rm -f /usr/share/fish/vendor_completions.d/looking-glass-setup.fish
        log "SUCCESS" "Removed Fish completions."
    fi
    if [[ -f /usr/share/bash-completion/completions/looking-glass-setup ]]; then
        rm -f /usr/share/bash-completion/completions/looking-glass-setup
        log "SUCCESS" "Removed Bash completions."
    fi
}

create_desktop_entry() {
    local desktop_file
    desktop_file="/usr/local/share/applications/looking-glass-client.desktop"
    log "INFO" "Creating application-menu shortcut for Looking Glass client…"
    if [[ "$DRY_RUN" == true ]]; then
        log "INFO" "[DRY-RUN] Would write $desktop_file"
        return 0
    fi
    mkdir -p "$(dirname "$desktop_file")"
    cat > "$desktop_file" <<'DESKTOP'
[Desktop Entry]
Name=Looking Glass Client
Comment=Low-latency KVM Frame Relay
Exec=looking-glass-client
Type=Application
Terminal=false
Icon=video-display
Categories=System;Emulator;
DESKTOP
    log "SUCCESS" "Desktop entry created at $desktop_file"

    # Also place a shortcut on the user's Desktop
    local target_user target_home desktop_dir
    target_user="${REAL_USER:-${SUDO_USER:-}}"
    if [[ -z "$target_user" || "$target_user" == "root" ]]; then
        target_user="${USER:-}"
    fi
    if [[ -n "$target_user" && "$target_user" != "root" ]]; then
        target_home="$(getent passwd "$target_user" | cut -d: -f6)"
        desktop_dir="$target_home/Desktop"
        if [[ -d "$desktop_dir" ]]; then
            cp -f "$desktop_file" "$desktop_dir/looking-glass-client.desktop"
            chown "$target_user:" "$desktop_dir/looking-glass-client.desktop" 2>/dev/null || true
            chmod +x "$desktop_dir/looking-glass-client.desktop" 2>/dev/null || true
            log "SUCCESS" "Desktop shortcut created at $desktop_dir/looking-glass-client.desktop"
        else
            log "WARN" "Desktop directory not found for user $target_user; skipping desktop shortcut."
        fi
    fi
}

install_shell_completions() {
    log "INFO" "Installing shell completions…"
    if [[ "$DRY_RUN" == true ]]; then
        log "INFO" "[DRY-RUN] Would install Fish and Bash completions."
        return 0
    fi

    # Fish completions
    local fish_dir="/usr/share/fish/vendor_completions.d"
    if command -v fish >/dev/null 2>&1 || [[ -d "$(dirname "$fish_dir")" ]]; then
        if [[ ! -d "$fish_dir" ]]; then
            mkdir -p "$fish_dir" 2>/dev/null || true
        fi
        if [[ -d "$fish_dir" ]]; then
            cat > "$fish_dir/looking-glass-setup.fish" <<'FISH'
complete -c looking-glass-setup -l install-script -d "Copy script to /usr/local/bin"
complete -c looking-glass-setup -l self-remove -d "Remove installed script"
complete -c looking-glass-setup -l create-shortcut -d "Add .desktop entry"
complete -c looking-glass-setup -l uninstall -l eject -d "Uninstall Looking Glass"
complete -c looking-glass-setup -l install-completions -d "Install shell completions"
complete -c looking-glass-setup -l dry-run -d "Show what would be done"
complete -c looking-glass-setup -l no-tui -d "Disable TUI prompts"
complete -c looking-glass-setup -l yes -s y -d "Skip confirmations"
complete -c looking-glass-setup -l vm-name -d "Target VM by name (e.g. --vm-name GAMING)"
complete -c looking-glass-setup -l shmem-size -d "Pool size in MB: 64/128/256/512"
complete -c looking-glass-setup -l enable-rebar -d "Enable ReBAR 64-bit MMIO on VM"
complete -c looking-glass-setup -l disable-rebar -d "Disable ReBAR 64-bit MMIO on VM"
complete -c looking-glass-setup -l dump-vbios -d "Dump GPU VBIOS ROM"
complete -c looking-glass-setup -l inject-vbios -d "Inject VBIOS ROM into VM GPU passthrough"
complete -c looking-glass-setup -l remove-vbios -d "Remove VBIOS ROM from VM GPU passthrough"
complete -c looking-glass-setup -l vbios-path -d "Path to VBIOS .rom file"
complete -c looking-glass-setup -l help -s h -d "Show help"
FISH
            log "SUCCESS" "Fish completions installed to $fish_dir"
        else
            log "WARN" "Could not create $fish_dir; skipping Fish completions."
        fi
    else
        log "INFO" "Fish not detected; skipping Fish completions."
    fi

    # Bash completions
    local bash_dir="/usr/share/bash-completion/completions"
    if command -v bash >/dev/null 2>&1 || [[ -d "$(dirname "$bash_dir")" ]]; then
        if [[ ! -d "$bash_dir" ]]; then
            mkdir -p "$bash_dir" 2>/dev/null || true
        fi
        if [[ -d "$bash_dir" ]]; then
            cat > "$bash_dir/looking-glass-setup" <<'BASH'
_looking_glass_setup_completions() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local opts="--install-script --self-remove --create-shortcut --uninstall --eject --install-completions --dry-run --no-tui --yes -y --vm-name --shmem-size --enable-rebar --disable-rebar --dump-vbios --inject-vbios --remove-vbios --vbios-path --help -h"
    COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
}
complete -F _looking_glass_setup_completions looking-glass-setup
BASH
            log "SUCCESS" "Bash completions installed to $bash_dir"
        else
            log "WARN" "Could not create $bash_dir; skipping Bash completions."
        fi
    else
        log "INFO" "Bash completions directory not found; skipping Bash completions."
    fi
}

show_main_menu() {
    local choice
    local menu_items=()
    menu_items+=("install" "Install Looking Glass")
    menu_items+=("uninstall" "Uninstall Looking Glass")
    menu_items+=("shortcut" "Create Desktop Shortcut")
    menu_items+=("deploy" "Install Script to PATH")
    menu_items+=("enable_rebar" "Enable ReBAR on VM")
    menu_items+=("disable_rebar" "Disable ReBAR on VM")
    menu_items+=("dump_vbios" "Dump GPU VBIOS")
    menu_items+=("inject_vbios" "Inject VBIOS to VM")
    menu_items+=("remove_vbios" "Remove VBIOS from VM")
    menu_items+=("exit" "Exit")
    choice="$(tui_menu "Looking Glass Manager" "Select an action:" "" "${menu_items[@]}")"
    case "$choice" in
        install)
            MODE="install"
            ;;
        uninstall)
            MODE="uninstall"
            ;;
        shortcut)
            if [[ $EUID -ne 0 ]]; then
                log "ERROR" "This action must be run as root. Please use sudo."
                exit 1
            fi
            create_desktop_entry
            exit 0
            ;;
        deploy)
            if [[ $EUID -ne 0 ]]; then
                log "ERROR" "This action must be run as root. Please use sudo."
                exit 1
            fi
            install_script
            exit 0
            ;;
        enable_rebar)
            if [[ $EUID -ne 0 ]]; then
                log "ERROR" "This action must be run as root. Please use sudo."
                exit 1
            fi
            do_rebar_standalone "enable"
            exit 0
            ;;
        disable_rebar)
            if [[ $EUID -ne 0 ]]; then
                log "ERROR" "This action must be run as root. Please use sudo."
                exit 1
            fi
            do_rebar_standalone "disable"
            exit 0
            ;;
        dump_vbios)
            do_vbios_dump_standalone
            ;;
        inject_vbios)
            if [[ $EUID -ne 0 ]]; then
                log "ERROR" "This action must be run as root. Please use sudo."
                exit 1
            fi
            do_vbios_inject_standalone "inject"
            exit 0
            ;;
        remove_vbios)
            if [[ $EUID -ne 0 ]]; then
                log "ERROR" "This action must be run as root. Please use sudo."
                exit 1
            fi
            do_vbios_inject_standalone "remove"
            exit 0
            ;;
        exit|"")
            log "INFO" "Exiting."
            exit 0
            ;;
    esac
}

maybe_prompt_install() {
    if is_script_installed; then
        return 0
    fi
    if [[ "$YES" == true ]]; then
        install_script
        return 0
    fi

    local choice
    choice="$(tui_menu "Deploy Script" "How would you like to run this script?" "" \
        "install" "Install to $INSTALLED_PATH" \
        "source"  "Run from source (do not install)")"
    case "$choice" in
        install)
            install_script
            ;;
        source|""|"exit")
            log "INFO" "Running from source without installing."
            ;;
    esac
}

# --- TUI Helpers ------------------------------------------------------------
detect_tui_backend() {
    if [[ "$NO_TUI" == true || "$YES" == true || "$DRY_RUN" == true ]]; then
        TUI_BACKEND="none"
        return
    fi
    if command -v whiptail >/dev/null 2>&1; then
        TUI_BACKEND="whiptail"
        return
    fi
    if command -v dialog >/dev/null 2>&1; then
        TUI_BACKEND="dialog"
        return
    fi

    # Try to auto-install whiptail for interactive menus
    log "INFO" "No TUI backend found; trying to install whiptail…"
    if command -v dnf >/dev/null 2>&1; then
        if dnf install -y newt >/dev/null 2>&1; then
            TUI_BACKEND="whiptail"
            log "SUCCESS" "Installed whiptail (newt) for interactive menus."
            return
        fi
    elif command -v apt-get >/dev/null 2>&1; then
        if apt-get update >/dev/null 2>&1 && apt-get install -y whiptail >/dev/null 2>&1; then
            TUI_BACKEND="whiptail"
            log "SUCCESS" "Installed whiptail for interactive menus."
            return
        fi
    elif command -v pacman >/dev/null 2>&1; then
        if pacman -S --noconfirm --needed libnewt >/dev/null 2>&1; then
            TUI_BACKEND="whiptail"
            log "SUCCESS" "Installed whiptail (libnewt) for interactive menus."
            return
        fi
    fi

    TUI_BACKEND="none"
}

tui_yesno() {
    local title="$1"
    local text="$2"
    case "$TUI_BACKEND" in
        whiptail)
            whiptail --title "$title" --yesno "$text" 10 60
            ;;
        dialog)
            dialog --title "$title" --yesno "$text" 10 60
            ;;
        *)
            return 1
            ;;
    esac
}

tui_menu() {
    local title="$1"
    local text="$2"
    local default_item="${3:-}"
    shift 3
    local result=""
    case "$TUI_BACKEND" in
        whiptail)
            if [[ -n "$default_item" ]]; then
                result=$(whiptail --title "$title" --default-item "$default_item" --menu "$text" 20 70 10 "$@" 3>&1 1>&2 2>&3) || true
            else
                result=$(whiptail --title "$title" --menu "$text" 20 70 10 "$@" 3>&1 1>&2 2>&3) || true
            fi
            ;;
        dialog)
            if [[ -n "$default_item" ]]; then
                result=$(dialog --title "$title" --default-item "$default_item" --menu "$text" 20 70 10 "$@" 3>&1 1>&2 2>&3) || true
            else
                result=$(dialog --title "$title" --menu "$text" 20 70 10 "$@" 3>&1 1>&2 2>&3) || true
            fi
            ;;
        *)
            printf "\n" >&2
            printf "${C_CYAN}━━ %s ━━${C_NC}\n" "$title" >&2
            printf "  %s\n\n" "$text" >&2
            local i=1
            local tags=() items=()
            while [[ $# -gt 0 ]]; do
                tags+=("$1")
                items+=("$2")
                local marker="  "
                if [[ "$1" == "$default_item" ]]; then
                    marker="=>"
                fi
                printf "  ${C_YELLOW}%d) %s${C_NC} %s\n" "$i" "$marker" "$2" >&2
                shift 2
                i=$((i+1))
            done
            printf "\n" >&2
            read -rp "Enter number (or leave blank to cancel): " choice < /dev/tty
            [[ -z "$choice" ]] && { printf ''; return; }
            if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 && "$choice" -le ${#tags[@]} ]]; then
                result="${tags[$((choice-1))]}"
            fi
            ;;
    esac
    printf '%s' "$result"
}

# --- Core Functions ---------------------------------------------------------
detect_environment() {
    local IS_VM
    local vendor
    local product
    local grp

    log "INFO" "Running environment and pre-flight checks…"

    # Root Check
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "This script must be run as root. Please use sudo."
        exit 1
    fi

    # VM Detection
    IS_VM=false
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        if systemd-detect-virt -q; then IS_VM=true; fi
    elif [[ -f /sys/class/dmi/id/sys_vendor ]]; then
        vendor="$(tr '[:upper:]' '[:lower:]' < /sys/class/dmi/id/sys_vendor)"
        if [[ "$vendor" == *"qemu"* || "$vendor" == *"virtualbox"* || "$vendor" == *"vmware"* || "$vendor" == *"innotek"* || "$vendor" == *"bochs"* ]]; then
            IS_VM=true
        fi
    elif [[ -f /sys/class/dmi/id/product_name ]]; then
        product="$(tr '[:upper:]' '[:lower:]' < /sys/class/dmi/id/product_name)"
        if [[ "$product" == *"virtual"* || "$product" == *"vmware"* || "$product" == *"kvm"* || "$product" == *"qemu"* ]]; then
            IS_VM=true
        fi
    fi

    if [[ "$IS_VM" == true ]]; then
        log "ERROR" "Virtual Machine detected! Looking Glass Client must run on bare-metal."
        exit 1
    fi
    log "SUCCESS" "Bare-metal host verified."

    # User Detection
    REAL_USER=${SUDO_USER:-${USER:-}}
    if [[ -z "$REAL_USER" || "$REAL_USER" == "root" ]]; then
        log "WARN" "Could not detect non-root user. Files may be owned by root."
        confirm_or_exit "Continue anyway?"
    elif ! id -u "$REAL_USER" >/dev/null 2>&1; then
        log "WARN" "User '$REAL_USER' does not exist on this system."
        confirm_or_exit "Continue anyway?"
    fi

    # Group Detection
    VIRT_GROUP=""
    for grp in kvm libvirt qemu; do
        if getent group "$grp" >/dev/null 2>&1; then
            VIRT_GROUP="$grp"
            break
        fi
    done
    if [[ -z "$VIRT_GROUP" ]]; then
        log "WARN" "Could not find a standard virtualization group (kvm, libvirt, qemu)."
        confirm_or_exit "Continue without a virtualization group?"
    else
        log "SUCCESS" "Using virtualization group: $VIRT_GROUP"
    fi

    if ! command -v systemd-tmpfiles >/dev/null 2>&1; then
        log "WARN" "'systemd-tmpfiles' not found. Shared-memory configuration may not be applied."
        confirm_or_exit "Continue anyway?"
    fi
}

preflight_hardware() {
    log "INFO" "Running Pre-Flight Hardware Checks…"
    if [[ ! -c /dev/kvm ]]; then
        log "WARN" "KVM (/dev/kvm) not detected. Hardware virtualization may be disabled in your BIOS."
    fi
    if [[ ! -d /sys/kernel/iommu_groups ]] || [[ -z "$(ls -A /sys/kernel/iommu_groups 2>/dev/null || true)" ]]; then
        log "WARN" "IOMMU groups not found. VFIO GPU passthrough will not work until IOMMU is enabled in your bootloader."
    fi
    if ! lsmod | grep -q "kvm"; then
        log "WARN" "KVM kernel module is not loaded. Virtualization may be disabled in BIOS."
    fi
    if ! lsmod | grep -q "vfio_pci"; then
        log "WARN" "vfio_pci kernel module is not loaded. GPU Passthrough may not be configured."
    fi
}

detect_display_server() {
    local display_type="x11"
    if command -v loginctl >/dev/null 2>&1 && [[ -n "${REAL_USER:-}" && "$REAL_USER" != "root" ]]; then
        local session_ids
        session_ids="$(loginctl list-sessions --no-legend | awk -v user="$REAL_USER" '$3==user {print $1}')"
        local sid session_type
        for sid in $session_ids; do
            session_type="$(loginctl show-session "$sid" -p Type --value 2>/dev/null || true)"
            if [[ "${session_type,,}" == "wayland" ]]; then
                display_type="wayland"
                break
            fi
        done
    fi
    printf '%s' "$display_type"
}

is_lg_binary_valid() {
    local bin="$1"
    [[ -f "$bin" && -s "$bin" ]] || return 1
    if command -v file >/dev/null 2>&1; then
        file "$bin" | grep -q "ELF" || return 1
    fi
    return 0
}

compile_from_source() {
    local src_dir build_dir
    src_dir="/tmp/looking-glass-setup-src"
    build_dir="$src_dir/client/build"

    if is_lg_binary_valid /usr/local/bin/looking-glass-client; then
        log "SUCCESS" "looking-glass-client already present and valid in /usr/local/bin/."
        return 0
    fi

    if [[ -f /usr/local/bin/looking-glass-client ]]; then
        log "WARN" "Existing /usr/local/bin/looking-glass-client appears corrupt or incomplete. Removing and recompiling…"
        rm -f /usr/local/bin/looking-glass-client
    fi

    log "INFO" "Cloning Looking Glass source and submodules…"
    if [[ "$DRY_RUN" == true ]]; then
        log "INFO" "[DRY-RUN] Would git clone --recurse-submodules and install to /usr/local/bin/"
        return 0
    fi

    if ! command -v git >/dev/null 2>&1; then
        log "ERROR" "git is not installed. Cannot download source code."
        return 1
    fi

    rm -rf "$src_dir"
    if ! git clone --recurse-submodules https://github.com/gnif/LookingGlass.git "$src_dir"; then
        log "ERROR" "Failed to clone Looking Glass repository."
        rm -rf "$src_dir"
        return 1
    fi

    log "INFO" "Building Looking Glass client…"
    if [[ -d "$build_dir" ]]; then
        rm -rf "$build_dir"
    fi
    mkdir -p "$build_dir"

    local build_cmd="make"
    local cmake_generator="Unix Makefiles"
    if command -v ninja >/dev/null 2>&1; then
        build_cmd="ninja"
        cmake_generator="Ninja"
    fi

    if ! (cd "$build_dir" && cmake -G "$cmake_generator" -DENABLE_BACKTRACE=no ../); then
        log "ERROR" "CMake configuration failed."
        rm -rf "$src_dir"
        return 1
    fi

    if [[ "$build_cmd" == "ninja" ]]; then
        log "INFO" "Using Ninja — native progress will be shown."
        if ! (cd "$build_dir" && ninja -j"$(nproc)"); then
            log "ERROR" "Build failed. Check dependencies and try again."
            rm -rf "$src_dir"
            return 1
        fi
    else
        log "INFO" "Compiling with progress bar (this may take a few minutes)…"
        local tmp_out
        tmp_out=$(mktemp) || { log "ERROR" "Failed to create temporary file."; rm -rf "$src_dir"; return 1; }

        (cd "$build_dir" && make -j"$(nproc)" >"$tmp_out" 2>&1; printf '%s\n' "$?" >"$tmp_out.exit") &
        local make_pid=$!

        local total_cmds current percent filled empty bar_width
        bar_width=40
        total_cmds=$(cd "$build_dir" && make -n -j"$(nproc)" 2>/dev/null | grep -c $'^\t' || true)
        total_cmds=${total_cmds:-0}
        if [[ "$total_cmds" -lt 1 ]]; then
            total_cmds=$(find "$src_dir" -type f \( -name '*.c' -o -name '*.cpp' \) | wc -l)
        fi
        [[ "$total_cmds" -lt 1 ]] && total_cmds=200

        while kill -0 "$make_pid" 2>/dev/null; do
            current=$(wc -l <"$tmp_out" 2>/dev/null || echo 0)
            percent=$((current * 100 / total_cmds))
            [[ "$percent" -gt 100 ]] && percent=100
            filled=$((percent * bar_width / 100))
            empty=$((bar_width - filled))
            printf '\r\033[K\033[0;36m[%s%s] %3d%%\033[0m' "$(printf '#%.0s' $(seq 1 $filled))" "$(printf ' %.0s' $(seq 1 $empty))" "$percent"
            sleep 0.5
        done

        wait "$make_pid" 2>/dev/null || true
        local make_exit
        make_exit=$(cat "$tmp_out.exit" 2>/dev/null || echo 1)
        rm -f "$tmp_out.exit"
        printf '\n'

        if [[ "$make_exit" -ne 0 ]]; then
            cat "$tmp_out"
            rm -f "$tmp_out"
            log "ERROR" "Build failed. Check dependencies and try again."
            rm -rf "$src_dir"
            return 1
        fi
        rm -f "$tmp_out"
    fi

    log "INFO" "Installing binary to /usr/local/bin/…"
    if ! cp "$build_dir/looking-glass-client" /usr/local/bin/looking-glass-client; then
        log "ERROR" "Failed to install binary to /usr/local/bin/."
        rm -rf "$src_dir"
        return 1
    fi
    chmod +x /usr/local/bin/looking-glass-client

    rm -rf "$src_dir"
    log "SUCCESS" "looking-glass-client compiled and installed."
}

setup_shared_memory() {
    local desired_line
    local qemu_user="qemu"
    local qemu_group="qemu"
    if ! id -u "$qemu_user" >/dev/null 2>&1; then
        qemu_user="root"
    fi
    if ! getent group "$qemu_group" >/dev/null 2>&1; then
        qemu_group="root"
    fi

    log "INFO" "Configuring persistent shared memory (owner: $qemu_user:$qemu_group, mode: 666)"
    desired_line="f /dev/shm/looking-glass 0666 $qemu_user $qemu_group -"
    write_tmpfiles_idempotent "/etc/tmpfiles.d/10-looking-glass.conf" "$desired_line"
    if command -v systemd-tmpfiles >/dev/null 2>&1; then
        run_or_simulate systemd-tmpfiles --create /etc/tmpfiles.d/10-looking-glass.conf
    else
        log "WARN" "systemd-tmpfiles unavailable; shared-memory node will be created on next boot by systemd."
    fi
}

resize_shared_memory() {
    local size="${1:-64}"
    local qemu_user="qemu"
    local qemu_group="qemu"
    if ! id -u "$qemu_user" >/dev/null 2>&1; then
        qemu_user="root"
    fi
    if ! getent group "$qemu_group" >/dev/null 2>&1; then
        qemu_group="root"
    fi

    log "INFO" "Resizing shared-memory file to ${size}MB for VM compatibility…"
    if [[ "$DRY_RUN" == true ]]; then
        log "INFO" "[DRY-RUN] Would resize /dev/shm/looking-glass to ${size}MB and set permissions."
        return 0
    fi

    if [[ ! -e /dev/shm/looking-glass ]]; then
        touch /dev/shm/looking-glass
    fi

    local resized=false
    if truncate -s "${size}M" /dev/shm/looking-glass 2>/dev/null; then
        resized=true
    elif fallocate -l "${size}M" /dev/shm/looking-glass 2>/dev/null; then
        resized=true
    else
        log "WARN" "Failed to resize /dev/shm/looking-glass (it may be in use by a running VM). Try shutting down the VM and re-running."
    fi

    if [[ -e /dev/shm/looking-glass ]]; then
        chown "$qemu_user:$qemu_group" /dev/shm/looking-glass 2>/dev/null || true
        chmod 666 /dev/shm/looking-glass 2>/dev/null || true
    fi

    if command -v getenforce >/dev/null 2>&1 && command -v chcon >/dev/null 2>&1; then
        local selinux_state
        selinux_state="$(getenforce)"
        if [[ "$selinux_state" != "Disabled" ]]; then
            chcon -t svirt_tmpfs_t /dev/shm/looking-glass 2>/dev/null || true
        fi
    fi

    if [[ "$resized" == true ]]; then
        log "SUCCESS" "Shared-memory file resized to ${size}MB and permissions applied."
    else
        log "WARN" "Shared-memory resize incomplete — VM may fail to start. Fix permissions or stop the VM, then re-run."
    fi
}

setup_security() {
    local selinux_state
    local local_apparmor

    if command -v getenforce >/dev/null 2>&1 && command -v chcon >/dev/null 2>&1; then
        selinux_state="$(getenforce)"
        if [[ "$selinux_state" != "Disabled" ]]; then
            if [[ -e /dev/shm/looking-glass ]]; then
                log "INFO" "Applying SELinux context to shared memory…"
                run_or_simulate chcon -t svirt_tmpfs_t /dev/shm/looking-glass || true
            fi
            if command -v semanage >/dev/null 2>&1; then
                if [[ "$DRY_RUN" == false ]]; then
                    semanage fcontext -a -t svirt_tmpfs_t "/dev/shm/looking-glass" 2>/dev/null || true
                fi
            else
                log "WARN" "'semanage' not found. SELinux context will not survive a reboot. Install policycoreutils-python-utils for persistence."
            fi
        fi
    fi

    if command -v aa-status >/dev/null 2>&1; then
        local_apparmor="/etc/apparmor.d/local/abstractions/libvirt-qemu"
        if [[ -d "$(dirname "$local_apparmor")" ]]; then
            if [[ ! -f "$local_apparmor" ]]; then
                if [[ "$DRY_RUN" == false ]]; then
                    touch "$local_apparmor"
                fi
            fi
            append_apparmor_rule_idempotent "$local_apparmor" "/dev/shm/looking-glass rw,"
            if [[ "$DRY_RUN" == false ]]; then
                systemctl reload apparmor 2>/dev/null || true
            fi
        fi
    fi
}

merge_ini_setting() {
    local file section key value
    file="$1"
    section="$2"
    key="$3"
    value="$4"
    if [[ "$DRY_RUN" == true ]]; then
        log "INFO" "[DRY-RUN] Would ensure [$section] $key=$value in $file"
        return 0
    fi
    if [[ ! -f "$file" ]]; then
        printf "[%s]\n%s=%s\n" "$section" "$key" "$value" > "$file"
        return 0
    fi

    if ! grep -q "^\[${section}\]$" "$file"; then
        printf "\n[%s]\n%s=%s\n" "$section" "$key" "$value" >> "$file"
        return 0
    fi

    local in_section=false
    local key_exists=false
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "[$section]" ]]; then
            in_section=true
            continue
        fi
        if [[ "$in_section" == true && "$line" =~ ^\[.*\]$ ]]; then
            break
        fi
        if [[ "$in_section" == true && "${line#"$key="}" != "$line" ]]; then
            key_exists=true
            break
        fi
    done < "$file" || true

    if [[ "$key_exists" == true ]]; then
        return 0
    fi

    local tmp_file orig_stat
    orig_stat=""
    if [[ -f "$file" ]]; then
        orig_stat="$(stat -c '%u:%g' "$file" 2>/dev/null || true)"
    fi
    tmp_file="$(mktemp)"
    local inserted=false
    while IFS= read -r line || [[ -n "$line" ]]; do
        printf '%s\n' "$line" >> "$tmp_file"
        if [[ "$inserted" == false && "$line" == "[$section]" ]]; then
            printf '%s=%s\n' "$key" "$value" >> "$tmp_file"
            inserted=true
        fi
    done < "$file"
    mv "$tmp_file" "$file"
    if [[ -n "$orig_stat" ]]; then
        chown "$orig_stat" "$file" 2>/dev/null || true
    fi
}

generate_user_config() {
    local USER_HOME
    local CONF_FILE
    local display_type

    if [[ -n "${REAL_USER:-}" && "$REAL_USER" != "root" ]]; then
        USER_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
        CONF_FILE="$USER_HOME/.looking-glass-client.ini"
        display_type="$(detect_display_server)"
        log "INFO" "Ensuring configuration for $REAL_USER (display: $display_type)…"
        if [[ "$DRY_RUN" == false ]]; then
            if [[ ! -f "$CONF_FILE" ]]; then
                touch "$CONF_FILE"
            fi
            chown "$REAL_USER":"$(id -gn "$REAL_USER")" "$CONF_FILE"
        fi
        merge_ini_setting "$CONF_FILE" "app" "shmFile" "/dev/shm/looking-glass"
        merge_ini_setting "$CONF_FILE" "spice" "enable" "yes"
        merge_ini_setting "$CONF_FILE" "spice" "audio" "yes"
        if [[ "$display_type" == "wayland" ]]; then
            merge_ini_setting "$CONF_FILE" "wayland" "fractionalScale" "yes"
        fi
    fi
}

get_vm_shmem_size() {
    local vm_name="$1"
    local virsh_cmd="$2"
    local size
    size="$($virsh_cmd dumpxml --inactive "$vm_name" 2>/dev/null | grep -oP "(?<=<size unit='M'>)[^<]+" | head -n 1 || true)"
    printf '%s' "$size"
}

vm_has_rebar_config() {
    local vm_name="$1"
    local virsh_cmd="$2"
    local xml
    xml="$($virsh_cmd dumpxml --inactive "$vm_name" 2>/dev/null || true)"
    if [[ "$xml" == *"xmlns:qemu="* && "$xml" == *"<qemu:commandline>"* && "$xml" == *"opt/ovmf/X-PciMmio64Mb"* ]]; then
        return 0
    fi
    return 1
}

enable_vm_rebar() {
    local vm_name="$1"
    local virsh_cmd="$2"
    local dry="${3:-false}"

    if [[ "$dry" == true ]]; then
        log "INFO" "[DRY-RUN] Would enable ReBAR 64-bit MMIO on VM '$vm_name'."
        return 0
    fi

    log "INFO" "Enabling ReBAR 64-bit MMIO (64GB aperture) on VM '$vm_name'…"

    local tmp_xml orig_xml
    tmp_xml="$(mktemp)"
    orig_xml="$(mktemp)"
    local _TRAPPED_REBAR_TMP="$tmp_xml $orig_xml"
    _rebar_cleanup_trap() {
        local _f
        for _f in "$tmp_xml" "$orig_xml"; do
            [[ -n "$_f" ]] && rm -f "$_f" >/dev/null 2>&1 || true
        done
        _TRAPPED_REBAR_TMP=""
        trap 'log "WARN" "Interrupted by user."; exit 130' INT TERM
    }
    trap '_rebar_cleanup_trap' INT TERM

    if ! $virsh_cmd dumpxml --inactive "$vm_name" > "$orig_xml" 2>/dev/null; then
        log "ERROR" "Failed to dump XML for VM '$vm_name'."
        rm -f "$tmp_xml" "$orig_xml"
        _TRAPPED_REBAR_TMP=""
        trap 'log "WARN" "Interrupted by user."; exit 130' INT TERM
        return 1
    fi

    if command -v python3 >/dev/null 2>&1; then
        python3 - "$orig_xml" "$tmp_xml" <<'PYEOF'
import sys, re
infile, outfile = sys.argv[1], sys.argv[2]
with open(infile, 'r') as f:
    content = f.read()

# Add namespace to <domain> if missing
if 'xmlns:qemu=' not in content:
    content = re.sub(r'(<domain\s+[^>]*)>', r'\1 xmlns:qemu="http://libvirt.org/schemas/domain/qemu/1.0">', content, count=1)

# Add qemu:commandline before </domain> if missing
if 'opt/ovmf/X-PciMmio64Mb' not in content:
    rebar_block = '''  <qemu:commandline>
    <qemu:arg value='-fw_cfg'/>
    <qemu:arg value='opt/ovmf/X-PciMmio64Mb,string=65536'/>
  </qemu:commandline>
'''
    content = content.replace('</domain>', rebar_block + '</domain>', 1)

with open(outfile, 'w') as f:
    f.write(content)
PYEOF
    elif command -v perl >/dev/null 2>&1; then
        perl -0777 -pe "
            s/(<domain\\s+[^>]*)>/\\1 xmlns:qemu=\\\"http:\\/\\/libvirt.org\\/schemas\\/domain\\/qemu\\/1.0\\\">/ if !/xmlns:qemu=/;
            s/<\\/domain>/  <qemu:commandline>\\n    <qemu:arg value='-fw_cfg'\\/>\\n    <qemu:arg value='opt\\/ovmf\\/X-PciMmio64Mb,string=65536'\\/>\\n  <\\/qemu:commandline>\\n<\\/domain>/ if !/opt\\/ovmf\\/X-PciMmio64Mb/;
        " "$orig_xml" > "$tmp_xml"
    else
        log "ERROR" "Neither python3 nor perl is available. Cannot modify VM XML."
        rm -f "$tmp_xml" "$orig_xml"
        _TRAPPED_REBAR_TMP=""
        trap 'log "WARN" "Interrupted by user."; exit 130' INT TERM
        return 1
    fi

    if ! $virsh_cmd define "$tmp_xml" 2>/dev/null; then
        log "ERROR" "Failed to redefine VM '$vm_name' with ReBAR configuration."
        rm -f "$tmp_xml" "$orig_xml"
        _TRAPPED_REBAR_TMP=""
        trap 'log "WARN" "Interrupted by user."; exit 130' INT TERM
        return 1
    fi

    rm -f "$tmp_xml" "$orig_xml"
    _TRAPPED_REBAR_TMP=""
    trap 'log "WARN" "Interrupted by user."; exit 130' INT TERM

    log "SUCCESS" "ReBAR 64-bit MMIO (64GB aperture) enabled on VM '$vm_name'."
    log "WARN" "IMPORTANT: Shut down (not restart) VM '$vm_name' fully for ReBAR to take effect."
}

disable_vm_rebar() {
    local vm_name="$1"
    local virsh_cmd="$2"
    local dry="${3:-false}"

    if [[ "$dry" == true ]]; then
        log "INFO" "[DRY-RUN] Would disable ReBAR 64-bit MMIO on VM '$vm_name'."
        return 0
    fi

    log "INFO" "Disabling ReBAR 64-bit MMIO on VM '$vm_name'…"

    local tmp_xml orig_xml
    tmp_xml="$(mktemp)"
    orig_xml="$(mktemp)"
    local _TRAPPED_REBAR_TMP="$tmp_xml $orig_xml"
    _rebar_cleanup_trap() {
        local _f
        for _f in "$tmp_xml" "$orig_xml"; do
            [[ -n "$_f" ]] && rm -f "$_f" >/dev/null 2>&1 || true
        done
        _TRAPPED_REBAR_TMP=""
        trap 'log "WARN" "Interrupted by user."; exit 130' INT TERM
    }
    trap '_rebar_cleanup_trap' INT TERM

    if ! $virsh_cmd dumpxml --inactive "$vm_name" > "$orig_xml" 2>/dev/null; then
        log "ERROR" "Failed to dump XML for VM '$vm_name'."
        rm -f "$tmp_xml" "$orig_xml"
        _TRAPPED_REBAR_TMP=""
        trap 'log "WARN" "Interrupted by user."; exit 130' INT TERM
        return 1
    fi

    if command -v python3 >/dev/null 2>&1; then
        python3 - "$orig_xml" "$tmp_xml" <<'PYEOF'
import sys, re
infile, outfile = sys.argv[1], sys.argv[2]
with open(infile, 'r') as f:
    content = f.read()

# Remove qemu:commandline block containing X-PciMmio64Mb
content = re.sub(
    r'\s*<qemu:commandline>\s*<qemu:arg[^>]*?/>\s*<qemu:arg[^>]*?X-PciMmio64Mb[^>]*?/>\s*</qemu:commandline>',
    '',
    content,
    flags=re.DOTALL
)

# Remove xmlns:qemu if no more qemu: elements
if '<qemu:' not in content:
    content = re.sub(r'\s+xmlns:qemu="http://libvirt\.org/schemas/domain/qemu/1\.0"', '', content)

with open(outfile, 'w') as f:
    f.write(content)
PYEOF
    elif command -v perl >/dev/null 2>&1; then
        perl -0777 -pe "
            s/\\s*<qemu:commandline>.*?<\\/qemu:commandline>//s;
            s/\\s+xmlns:qemu=\\\"http:\\/\\/libvirt\\.org\\/schemas\\/domain\\/qemu\\/1\\.0\\\"//g if !/<qemu:/;
        " "$orig_xml" > "$tmp_xml"
    else
        log "ERROR" "Neither python3 nor perl is available. Cannot modify VM XML."
        rm -f "$tmp_xml" "$orig_xml"
        _TRAPPED_REBAR_TMP=""
        trap 'log "WARN" "Interrupted by user."; exit 130' INT TERM
        return 1
    fi

    if ! $virsh_cmd define "$tmp_xml" 2>/dev/null; then
        log "ERROR" "Failed to redefine VM '$vm_name' after removing ReBAR configuration."
        rm -f "$tmp_xml" "$orig_xml"
        _TRAPPED_REBAR_TMP=""
        trap 'log "WARN" "Interrupted by user."; exit 130' INT TERM
        return 1
    fi

    rm -f "$tmp_xml" "$orig_xml"
    _TRAPPED_REBAR_TMP=""
    trap 'log "WARN" "Interrupted by user."; exit 130' INT TERM

    log "SUCCESS" "ReBAR 64-bit MMIO disabled on VM '$vm_name'."
}

configure_vm_rebar() {
    local vm_list selected_vm
    local virsh_cmd="virsh"

    if ! command -v virsh >/dev/null 2>&1; then
        log "INFO" "virsh not found. Skipping ReBAR VM configuration."
        return 0
    fi

    if virsh -c qemu:///system list --all >/dev/null 2>&1; then
        virsh_cmd="virsh -c qemu:///system"
        log "INFO" "Using libvirt system connection (qemu:///system)."
    elif virsh -c qemu:///session list --all >/dev/null 2>&1; then
        virsh_cmd="virsh -c qemu:///session"
        log "INFO" "Using libvirt session connection (qemu:///session)."
    else
        log "WARN" "Cannot connect to libvirt. Skipping ReBAR configuration."
        return 0
    fi

    log "INFO" "Scanning libvirt virtual machines for ReBAR configuration…"
    mapfile -t vm_list < <($virsh_cmd list --all --name | grep -v '^$' || true)
    if [[ ${#vm_list[@]} -eq 0 ]]; then
        log "WARN" "No libvirt VMs found. Skipping ReBAR configuration."
        return 0
    fi

    local selected_vm=""
    if [[ -n "$VM_NAME" ]]; then
        local vm_found=false
        for vm in "${vm_list[@]}"; do
            if [[ "$vm" == "$VM_NAME" ]]; then
                vm_found=true
                break
            fi
        done
        if [[ "$vm_found" == true ]]; then
            selected_vm="$VM_NAME"
            log "INFO" "Using explicitly specified VM '$selected_vm' (--vm-name)."
        else
            log "WARN" "VM '$VM_NAME' not found. Falling back to selection."
        fi
    fi

    if [[ -z "$selected_vm" ]]; then
        local menu_items=()
        local vm i=1
        for vm in "${vm_list[@]}"; do
            local state rebar_info
            state="$($virsh_cmd domstate "$vm" 2>/dev/null || echo "unknown")"
            if vm_has_rebar_config "$vm" "$virsh_cmd"; then
                rebar_info=" [ReBAR enabled]"
            else
                rebar_info=" [ReBAR not configured]"
            fi
            menu_items+=("$i" "$vm ($state)${rebar_info}")
            i=$((i+1))
        done
        menu_items+=("0" "Skip ReBAR configuration")

        local selected_idx
        selected_idx="$(tui_menu "Select VM for ReBAR" "Which VM should have ReBAR 64-bit MMIO configured?" "" "${menu_items[@]}")"
        if [[ -z "$selected_idx" || "$selected_idx" == "0" ]]; then
            log "INFO" "Skipping ReBAR configuration."
            return 0
        fi
        selected_vm="${vm_list[$((selected_idx-1))]}"
    fi

    log "INFO" "Targeting VM: $selected_vm"

    if vm_has_rebar_config "$selected_vm" "$virsh_cmd"; then
        log "SUCCESS" "VM '$selected_vm' already has ReBAR 64-bit MMIO configured."
        local action
        if [[ "$YES" == true ]]; then
            action="keep"
        elif [[ "$TUI_BACKEND" != "none" && "$TUI_BACKEND" != "" && "$DRY_RUN" != true ]]; then
            action="$(tui_menu "ReBAR Configuration" "VM '$selected_vm' already has ReBAR enabled. What do you want to do?" "" \
                "keep" "Keep current ReBAR configuration" \
                "disable" "Disable ReBAR configuration")"
        else
            action="keep"
        fi
        case "$action" in
            disable)
                disable_vm_rebar "$selected_vm" "$virsh_cmd" "$DRY_RUN"
                ;;
            keep|"")
                log "INFO" "Kept existing ReBAR configuration on '$selected_vm'."
                ;;
        esac
    else
        log "INFO" "VM '$selected_vm' does not have ReBAR configured."
        local action
        if [[ "$YES" == true ]]; then
            action="enable"
        elif [[ "$TUI_BACKEND" != "none" && "$TUI_BACKEND" != "" && "$DRY_RUN" != true ]]; then
            action="$(tui_menu "ReBAR Configuration" "Enable ReBAR 64-bit MMIO (64GB aperture) on VM '$selected_vm'?" "" \
                "enable" "Enable ReBAR (recommended for large GPUs)" \
                "skip" "Skip ReBAR configuration")"
        else
            if [[ "$DRY_RUN" == true ]]; then
                action="enable"
            else
                log "INFO" "ReBAR not configured. Use --enable-rebar or run interactively to enable."
                action="skip"
            fi
        fi
        case "$action" in
            enable)
                enable_vm_rebar "$selected_vm" "$virsh_cmd" "$DRY_RUN"
                ;;
            skip|"")
                log "INFO" "Skipped ReBAR configuration for '$selected_vm'."
                ;;
        esac
    fi
}

do_rebar_standalone() {
    local action="$1"

    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "This action must be run as root. Please use sudo."
        exit 1
    fi

    local virsh_cmd="virsh"
    if ! command -v virsh >/dev/null 2>&1; then
        log "ERROR" "virsh not found. Cannot configure ReBAR."
        exit 1
    fi

    if virsh -c qemu:///system list --all >/dev/null 2>&1; then
        virsh_cmd="virsh -c qemu:///system"
    elif virsh -c qemu:///session list --all >/dev/null 2>&1; then
        virsh_cmd="virsh -c qemu:///session"
    else
        log "ERROR" "Cannot connect to libvirt. Cannot configure ReBAR."
        exit 1
    fi

    local vm_list selected_vm
    mapfile -t vm_list < <($virsh_cmd list --all --name | grep -v '^$' || true)
    if [[ ${#vm_list[@]} -eq 0 ]]; then
        log "ERROR" "No libvirt VMs found."
        exit 1
    fi

    selected_vm=""
    if [[ -n "$VM_NAME" ]]; then
        for vm in "${vm_list[@]}"; do
            if [[ "$vm" == "$VM_NAME" ]]; then
                selected_vm="$VM_NAME"
                break
            fi
        done
        if [[ -z "$selected_vm" ]]; then
            log "ERROR" "VM '$VM_NAME' not found."
            exit 1
        fi
    else
        local menu_items=()
        local vm i=1
        for vm in "${vm_list[@]}"; do
            local state rebar_info
            state="$($virsh_cmd domstate "$vm" 2>/dev/null || echo "unknown")"
            if vm_has_rebar_config "$vm" "$virsh_cmd"; then
                rebar_info=" [ReBAR enabled]"
            else
                rebar_info=" [ReBAR not configured]"
            fi
            menu_items+=("$i" "$vm ($state)${rebar_info}")
            i=$((i+1))
        done
        menu_items+=("0" "Cancel")

        local selected_idx
        selected_idx="$(tui_menu "Select VM for ReBAR" "Which VM should be modified?" "" "${menu_items[@]}")"
        if [[ -z "$selected_idx" || "$selected_idx" == "0" ]]; then
            log "INFO" "Cancelled."
            exit 0
        fi
        selected_vm="${vm_list[$((selected_idx-1))]}"
    fi

    if [[ "$action" == "enable" ]]; then
        if vm_has_rebar_config "$selected_vm" "$virsh_cmd"; then
            log "SUCCESS" "VM '$selected_vm' already has ReBAR 64-bit MMIO configured."
            exit 0
        fi
        enable_vm_rebar "$selected_vm" "$virsh_cmd" "$DRY_RUN"
    else
        if ! vm_has_rebar_config "$selected_vm" "$virsh_cmd"; then
            log "WARN" "VM '$selected_vm' does not have ReBAR configured. Nothing to disable."
            exit 0
        fi
        disable_vm_rebar "$selected_vm" "$virsh_cmd" "$DRY_RUN"
    fi
}

detect_vfio_gpus() {
    local gpus=()
    if command -v lspci >/dev/null 2>&1; then
        while IFS= read -r line; do
            local addr driver_path driver_name
            addr="$(echo "$line" | awk '{print $1}')"
            [[ -z "$addr" ]] && continue
            driver_path="/sys/bus/pci/devices/$addr/driver"
            driver_name=""
            if [[ -L "$driver_path" ]]; then
                driver_name="$(basename "$(readlink -f "$driver_path" 2>/dev/null)" 2>/dev/null || true)"
            fi
            if [[ "$driver_name" == "vfio-pci" ]]; then
                gpus+=("$addr")
            fi
        done < <(lspci -D -nn | grep -iE 'vga compatible controller|3d controller' || true)
    fi
    printf '%s\n' "${gpus[@]}"
}

detect_all_gpus() {
    local gpus=()
    if command -v lspci >/dev/null 2>&1; then
        while IFS= read -r line; do
            local addr
            addr="$(echo "$line" | awk '{print $1}')"
            [[ -n "$addr" ]] && gpus+=("$addr")
        done < <(lspci -D -nn | grep -iE 'vga compatible controller|3d controller' || true)
    fi
    printf '%s\n' "${gpus[@]}"
}

get_gpu_driver_name() {
    local pci_addr="$1"
    local driver_path="/sys/bus/pci/devices/$pci_addr/driver"
    if [[ -L "$driver_path" ]]; then
        basename "$(readlink -f "$driver_path" 2>/dev/null)" 2>/dev/null || true
    fi
}


get_vm_vbios_rom_path() {
    local vm_name="$1"
    local virsh_cmd="$2"
    local xml
    xml="$($virsh_cmd dumpxml --inactive "$vm_name" 2>/dev/null || true)"
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "
import sys, re
xml = sys.argv[1]
matches = re.findall(r\"<hostdev[^>]*type\\s*=\\s*['\\\"]pci['\\\"][^>]*>.*?</hostdev>\", xml, flags=re.DOTALL)
for m in matches:
    rom = re.search(r\"<rom\\s+file\\s*=\\s*['\\\"]([^'\\\"]*)['\\\"]\\s*/>\", m)
    if rom:
        print(rom.group(1))
        break
" "$xml" 2>/dev/null || true
    fi
}

vm_has_vbios_config() {
    local vm_name="$1"
    local virsh_cmd="$2"
    local xml
    xml="$($virsh_cmd dumpxml --inactive "$vm_name" 2>/dev/null || true)"
    if [[ "$xml" == *"<hostdev"* && "$xml" == *"type='pci'"* && "$xml" == *"<rom file="* ]]; then
        return 0
    fi
    return 1
}

vm_vbios_is_same_rom() {
    local vm_name="$1"
    local virsh_cmd="$2"
    local rom_path="$3"
    local existing_rom
    existing_rom="$(get_vm_vbios_rom_path "$vm_name" "$virsh_cmd")"
    if [[ "$existing_rom" == "$rom_path" ]]; then
        return 0
    fi
    return 1
}


dump_vbios() {
    local pci_addr="$1"
    local target_dir="${2:-$VBIOS_DIR}"
    local rom_file="/sys/bus/pci/devices/$pci_addr/rom"
    local output_file="$target_dir/vbios_${pci_addr//:/_}.rom"

    if [[ "$DRY_RUN" == true ]]; then
        log "INFO" "[DRY-RUN] Would dump VBIOS from $pci_addr to $output_file"
        printf '%s' "$output_file"
        return 0
    fi

    if [[ ! -d "$target_dir" ]]; then
        mkdir -p "$target_dir" || {
            log "ERROR" "Cannot create $target_dir"
            return 1
        }
    fi

    if [[ ! -f "$rom_file" ]]; then
        log "WARN" "ROM sysfs node not found at $rom_file."
        log "INFO" "The GPU must be bound to a driver that exposes the ROM (e.g., amdgpu) for dumping."
        log "INFO" "If currently bound to vfio-pci, you may need to temporarily rebind to amdgpu first."
        return 1
    fi

    log "INFO" "Enabling ROM reading for $pci_addr…"
    if ! echo 1 > "$rom_file" 2>/dev/null; then
        local drv
        drv="$(get_gpu_driver_name "$pci_addr")"
        if [[ "$drv" == "vfio-pci" ]]; then
            log "WARN" "GPU $pci_addr is bound to vfio-pci — the ROM sysfs node is disabled."
            log "INFO" "To dump the VBIOS, temporarily rebind the GPU to its native driver:"
            log "INFO" "  echo '$pci_addr' > /sys/bus/pci/drivers/vfio-pci/unbind"
            log "INFO" "  echo 1 > /sys/bus/pci/rescan   # or bind to native driver manually"
        else
            log "WARN" "Cannot enable ROM reading for $pci_addr (driver: ${drv:-unknown})."
        fi
        return 1
    fi

    log "INFO" "Reading VBIOS from $pci_addr…"
    if cat "$rom_file" > "$output_file" 2>/dev/null; then
        local rom_size
        rom_size="$(stat -c %s "$output_file" 2>/dev/null || echo 0)"
        if [[ "$rom_size" -lt 65536 ]]; then
            log "WARN" "Dumped ROM is only ${rom_size} bytes — likely invalid. Removing."
            rm -f "$output_file"
            echo 0 > "$rom_file" 2>/dev/null || true
            return 1
        fi
        log "SUCCESS" "VBIOS dumped: $output_file (${rom_size} bytes)"
        echo 0 > "$rom_file" 2>/dev/null || true
        printf '%s' "$output_file"
        return 0
    else
        log "ERROR" "Failed to read ROM from $pci_addr."
        echo 0 > "$rom_file" 2>/dev/null || true
        return 1
    fi
}

do_vbios_dump_standalone() {
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "This action must be run as root. Please use sudo."
        exit 1
    fi

    local gpus=()
    while IFS= read -r addr; do
        [[ -n "$addr" ]] && gpus+=("$addr")
    done < <(detect_vfio_gpus)

    if [[ ${#gpus[@]} -eq 0 ]]; then
        log "WARN" "No GPUs bound to vfio-pci detected. Falling back to all VGA/3D controllers."
        while IFS= read -r addr; do
            [[ -n "$addr" ]] && gpus+=("$addr")
        done < <(detect_all_gpus)
    fi

    if [[ ${#gpus[@]} -eq 0 ]]; then
        log "ERROR" "No VGA/3D controller GPUs detected via lspci."
        exit 1
    fi

    local selected_addr=""
    if [[ ${#gpus[@]} -eq 1 ]]; then
        selected_addr="${gpus[0]}"
        local drv
        drv="$(get_gpu_driver_name "$selected_addr")"
        log "INFO" "Only one GPU detected: $selected_addr (driver: ${drv:-unknown})"
    else
        local menu_items=()
        local i=1
        for addr in "${gpus[@]}"; do
            local desc drv
            desc="$(lspci -D -s "$addr" 2>/dev/null | cut -d' ' -f2- || echo "Unknown")"
            drv="$(get_gpu_driver_name "$addr")"
            if [[ "$drv" == "vfio-pci" ]]; then
                menu_items+=("$i" "$addr — $desc [PASSTHROUGH]")
            else
                menu_items+=("$i" "$addr — $desc [driver: ${drv:-none}]")
            fi
            i=$((i+1))
        done
        menu_items+=("0" "Cancel")
        local selected_idx
        selected_idx="$(tui_menu "Dump VBIOS" "Select GPU to dump VBIOS from:" "" "${menu_items[@]}")"
        if [[ -z "$selected_idx" || "$selected_idx" == "0" ]]; then
            log "INFO" "Cancelled."
            exit 0
        fi
        selected_addr="${gpus[$((selected_idx-1))]}"
    fi

    if [[ "$DRY_RUN" == true ]]; then
        dump_vbios "$selected_addr" "$VBIOS_DIR"
        exit 0
    fi

    confirm_or_exit "This will attempt to read the VBIOS ROM from $selected_addr. Continue?"
    local result
    result="$(dump_vbios "$selected_addr" "$VBIOS_DIR")"
    if [[ -n "$result" && -f "$result" ]]; then
        log "SUCCESS" "VBIOS saved to: $result"
    else
        log "ERROR" "VBIOS dump failed."
        exit 1
    fi
    exit 0
}


inject_vbios_to_vm() {
    local vm_name="$1"
    local virsh_cmd="$2"
    local rom_path="$3"
    local dry="${4:-false}"

    if [[ "$dry" == true ]]; then
        log "INFO" "[DRY-RUN] Would inject VBIOS $rom_path into VM '$vm_name'."
        return 0
    fi

    # Idempotency: check if the exact same ROM is already injected
    if vm_vbios_is_same_rom "$vm_name" "$virsh_cmd" "$rom_path"; then
        log "SUCCESS" "VM '$vm_name' already has VBIOS '$rom_path' injected in all PCI passthrough devices."
        return 0
    fi

    log "INFO" "Injecting VBIOS $rom_path into VM '$vm_name'…"

    local tmp_xml orig_xml
    tmp_xml="$(mktemp)"
    orig_xml="$(mktemp)"
    local _TRAPPED_VBIOS_TMP="$tmp_xml $orig_xml"
    _vbios_cleanup_trap() {
        local _f
        for _f in "$tmp_xml" "$orig_xml"; do
            [[ -n "$_f" ]] && rm -f "$_f" >/dev/null 2>&1 || true
        done
        _TRAPPED_VBIOS_TMP=""
        trap 'log "WARN" "Interrupted by user."; exit 130' INT TERM
    }
    trap '_vbios_cleanup_trap' INT TERM

    if ! $virsh_cmd dumpxml --inactive "$vm_name" > "$orig_xml" 2>/dev/null; then
        log "ERROR" "Failed to dump XML for VM '$vm_name'."
        rm -f "$tmp_xml" "$orig_xml"
        _TRAPPED_VBIOS_TMP=""
        trap 'log "WARN" "Interrupted by user."; exit 130' INT TERM
        return 1
    fi

    if command -v python3 >/dev/null 2>&1; then
        python3 - "$orig_xml" "$tmp_xml" "$rom_path" <<'PYEOF'
import sys, re
infile, outfile, rom_path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(infile, 'r') as f:
    content = f.read()

def inject_rom_block(match):
    block = match.group(0)
    if re.search(r"<rom\s+file\s*=\s*['\"]", block):
        block = re.sub(r"<rom\s+file\s*=\s*['\"][^'\"]*['\"]\s*/>", f"<rom file='{rom_path}'/>", block)
        return block
    block = block.replace('</source>', f"</source>\n  <rom file='{rom_path}'/>", 1)
    return block

content = re.sub(
    r"<hostdev[^>]*type\s*=\s*['\"]pci['\"][^>]*>.*?</hostdev>",
    inject_rom_block,
    content,
    flags=re.DOTALL
)

with open(outfile, 'w') as f:
    f.write(content)
PYEOF
    else
        log "ERROR" "python3 is required for VBIOS XML injection."
        rm -f "$tmp_xml" "$orig_xml"
        _TRAPPED_VBIOS_TMP=""
        trap 'log "WARN" "Interrupted by user."; exit 130' INT TERM
        return 1
    fi

    if ! $virsh_cmd define "$tmp_xml" 2>/dev/null; then
        log "ERROR" "Failed to redefine VM '$vm_name' with VBIOS injection."
        rm -f "$tmp_xml" "$orig_xml"
        _TRAPPED_VBIOS_TMP=""
        trap 'log "WARN" "Interrupted by user."; exit 130' INT TERM
        return 1
    fi

    rm -f "$tmp_xml" "$orig_xml"
    _TRAPPED_VBIOS_TMP=""
    trap 'log "WARN" "Interrupted by user."; exit 130' INT TERM

    log "SUCCESS" "VBIOS injected into VM '$vm_name'."
    log "WARN" "IMPORTANT: Shut down (not restart) VM '$vm_name' fully for VBIOS to take effect."
}

remove_vbios_from_vm() {
    local vm_name="$1"
    local virsh_cmd="$2"
    local dry="${3:-false}"

    if [[ "$dry" == true ]]; then
        log "INFO" "[DRY-RUN] Would remove VBIOS injection from VM '$vm_name'."
        return 0
    fi

    if ! vm_has_vbios_config "$vm_name" "$virsh_cmd"; then
        log "SUCCESS" "VM '$vm_name' does not have any VBIOS injection configured. Nothing to remove."
        return 0
    fi

    log "INFO" "Removing VBIOS injection from VM '$vm_name'…"

    local tmp_xml orig_xml
    tmp_xml="$(mktemp)"
    orig_xml="$(mktemp)"
    local _TRAPPED_VBIOS_TMP="$tmp_xml $orig_xml"
    _vbios_cleanup_trap() {
        local _f
        for _f in "$tmp_xml" "$orig_xml"; do
            [[ -n "$_f" ]] && rm -f "$_f" >/dev/null 2>&1 || true
        done
        _TRAPPED_VBIOS_TMP=""
        trap 'log "WARN" "Interrupted by user."; exit 130' INT TERM
    }
    trap '_vbios_cleanup_trap' INT TERM

    if ! $virsh_cmd dumpxml --inactive "$vm_name" > "$orig_xml" 2>/dev/null; then
        log "ERROR" "Failed to dump XML for VM '$vm_name'."
        rm -f "$tmp_xml" "$orig_xml"
        _TRAPPED_VBIOS_TMP=""
        trap 'log "WARN" "Interrupted by user."; exit 130' INT TERM
        return 1
    fi

    if command -v python3 >/dev/null 2>&1; then
        python3 - "$orig_xml" "$tmp_xml" <<'PYEOF'
import sys, re
infile, outfile = sys.argv[1], sys.argv[2]
with open(infile, 'r') as f:
    content = f.read()

def remove_rom_block(match):
    block = match.group(0)
    block = re.sub(r"\s*<rom\s+file\s*=\s*['\"][^'\"]*['\"]\s*/>", "", block)
    return block

content = re.sub(
    r"<hostdev[^>]*type\s*=\s*['\"]pci['\"][^>]*>.*?</hostdev>",
    remove_rom_block,
    content,
    flags=re.DOTALL
)

with open(outfile, 'w') as f:
    f.write(content)
PYEOF
    else
        log "ERROR" "python3 is required for VBIOS XML removal."
        rm -f "$tmp_xml" "$orig_xml"
        _TRAPPED_VBIOS_TMP=""
        trap 'log "WARN" "Interrupted by user."; exit 130' INT TERM
        return 1
    fi

    if ! $virsh_cmd define "$tmp_xml" 2>/dev/null; then
        log "ERROR" "Failed to redefine VM '$vm_name' after removing VBIOS."
        rm -f "$tmp_xml" "$orig_xml"
        _TRAPPED_VBIOS_TMP=""
        trap 'log "WARN" "Interrupted by user."; exit 130' INT TERM
        return 1
    fi

    rm -f "$tmp_xml" "$orig_xml"
    _TRAPPED_VBIOS_TMP=""
    trap 'log "WARN" "Interrupted by user."; exit 130' INT TERM

    log "SUCCESS" "VBIOS removed from VM '$vm_name'."
}

find_vbios_files() {
    local dir="${1:-$VBIOS_DIR}"
    if [[ -d "$dir" ]]; then
        find "$dir" -maxdepth 1 -type f -name '*.rom' 2>/dev/null | sort
    fi
}

select_vbios_file() {
    local files=()
    while IFS= read -r f; do
        [[ -n "$f" ]] && files+=("$f")
    done < <(find_vbios_files)

    if [[ ${#files[@]} -eq 0 ]]; then
        printf '%s' ""
        return
    fi

    if [[ ${#files[@]} -eq 1 ]]; then
        printf '%s' "${files[0]}"
        return
    fi

    local menu_items=()
    local i=1
    for f in "${files[@]}"; do
        menu_items+=("$i" "$(basename "$f")")
        i=$((i+1))
    done
    menu_items+=("0" "Cancel / Provide path manually")

    local selected_idx
    selected_idx="$(tui_menu "Select VBIOS" "Which VBIOS file should be injected?" "" "${menu_items[@]}")"
    if [[ -z "$selected_idx" || "$selected_idx" == "0" ]]; then
        printf '%s' ""
        return
    fi
    printf '%s' "${files[$((selected_idx-1))]}"
}

configure_vm_vbios() {
    local vm_list selected_vm
    local virsh_cmd="virsh"

    if ! command -v virsh >/dev/null 2>&1; then
        log "INFO" "virsh not found. Skipping VBIOS VM configuration."
        return 0
    fi

    if virsh -c qemu:///system list --all >/dev/null 2>&1; then
        virsh_cmd="virsh -c qemu:///system"
    elif virsh -c qemu:///session list --all >/dev/null 2>&1; then
        virsh_cmd="virsh -c qemu:///session"
    else
        log "WARN" "Cannot connect to libvirt. Skipping VBIOS configuration."
        return 0
    fi

    log "INFO" "Scanning libvirt virtual machines for VBIOS configuration…"
    mapfile -t vm_list < <($virsh_cmd list --all --name | grep -v '^$' || true)
    if [[ ${#vm_list[@]} -eq 0 ]]; then
        log "WARN" "No libvirt VMs found. Skipping VBIOS configuration."
        return 0
    fi

    local selected_vm=""
    if [[ -n "$VM_NAME" ]]; then
        local vm_found=false
        for vm in "${vm_list[@]}"; do
            if [[ "$vm" == "$VM_NAME" ]]; then
                vm_found=true
                break
            fi
        done
        if [[ "$vm_found" == true ]]; then
            selected_vm="$VM_NAME"
            log "INFO" "Using explicitly specified VM '$selected_vm' (--vm-name)."
        else
            log "WARN" "VM '$VM_NAME' not found. Falling back to selection."
        fi
    fi

    if [[ -z "$selected_vm" ]]; then
        local menu_items=()
        local vm i=1
        for vm in "${vm_list[@]}"; do
            local state vbios_info
            state="$($virsh_cmd domstate "$vm" 2>/dev/null || echo "unknown")"
            if vm_has_vbios_config "$vm" "$virsh_cmd"; then
                vbios_info=" [VBIOS injected]"
            else
                vbios_info=" [VBIOS not configured]"
            fi
            menu_items+=("$i" "$vm ($state)${vbios_info}")
            i=$((i+1))
        done
        menu_items+=("0" "Skip VBIOS configuration")

        local selected_idx
        selected_idx="$(tui_menu "Select VM for VBIOS" "Which VM should have VBIOS configured?" "" "${menu_items[@]}")"
        if [[ -z "$selected_idx" || "$selected_idx" == "0" ]]; then
            log "INFO" "Skipping VBIOS configuration."
            return 0
        fi
        selected_vm="${vm_list[$((selected_idx-1))]}"
    fi

    log "INFO" "Targeting VM: $selected_vm"

    local has_gpu=false
    if $virsh_cmd dumpxml --inactive "$selected_vm" 2>/dev/null | grep -q "type='pci'"; then
        if $virsh_cmd dumpxml --inactive "$selected_vm" 2>/dev/null | grep -q "<hostdev.*type='pci'"; then
            has_gpu=true
        fi
    fi
    if [[ "$has_gpu" == false ]]; then
        log "WARN" "VM '$selected_vm' has no PCI passthrough (GPU) devices. VBIOS injection requires a GPU passthrough block."
        return 0
    fi

    if vm_has_vbios_config "$selected_vm" "$virsh_cmd"; then
        log "SUCCESS" "VM '$selected_vm' already has VBIOS injected."
        local action
        if [[ "$YES" == true ]]; then
            action="keep"
        elif [[ "$TUI_BACKEND" != "none" && "$TUI_BACKEND" != "" && "$DRY_RUN" != true ]]; then
            action="$(tui_menu "VBIOS Configuration" "VM '$selected_vm' already has VBIOS injected. What do you want to do?" "" \
                "keep" "Keep current VBIOS configuration" \
                "remove" "Remove VBIOS configuration")"
        else
            action="keep"
        fi
        case "$action" in
            remove)
                remove_vbios_from_vm "$selected_vm" "$virsh_cmd" "$DRY_RUN"
                ;;
            keep|"")
                log "INFO" "Kept existing VBIOS configuration on '$selected_vm'."
                ;;
        esac
    else
        log "INFO" "VM '$selected_vm' does not have VBIOS configured."
        local action
        if [[ "$YES" == true ]]; then
            action="inject"
        elif [[ "$TUI_BACKEND" != "none" && "$TUI_BACKEND" != "" && "$DRY_RUN" != true ]]; then
            action="$(tui_menu "VBIOS Configuration" "Inject VBIOS into GPU passthrough on VM '$selected_vm'?" "" \
                "inject" "Inject VBIOS (recommended for headless boot)" \
                "skip" "Skip VBIOS configuration")"
        else
            if [[ "$DRY_RUN" == true ]]; then
                action="inject"
            else
                log "INFO" "VBIOS not configured. Use --inject-vbios or run interactively to inject."
                action="skip"
            fi
        fi
        case "$action" in
        inject)
                local rom_path=""
                if [[ -n "$VBIOS_FILE" && -f "$VBIOS_FILE" ]]; then
                    rom_path="$VBIOS_FILE"
                    log "INFO" "Using VBIOS file from --vbios-path: $rom_path"
                else
                    rom_path="$(select_vbios_file)"
                    if [[ -z "$rom_path" ]]; then
                        local found_files
                        found_files="$(find_vbios_files | head -n 1)"
                        if [[ -n "$found_files" && -f "$found_files" ]]; then
                            log "INFO" "Auto-selecting first VBIOS file: $found_files"
                            rom_path="$found_files"
                        else
                            log "WARN" "No VBIOS .rom files found in $VBIOS_DIR."
                            log "INFO" "Dump a VBIOS first with: sudo $SCRIPT_NAME --dump-vbios"
                            log "INFO" "Or specify a path with --vbios-path <file>"
                            return 0
                        fi
                    fi
                fi

                if [[ -z "$rom_path" || ! -f "$rom_path" ]]; then
                    log "WARN" "No valid VBIOS file selected. Skipping injection."
                    return 0
                fi

                # Pre-check: if already injected with same ROM, skip
                if vm_vbios_is_same_rom "$selected_vm" "$virsh_cmd" "$rom_path"; then
                    log "SUCCESS" "VM '$selected_vm' already has VBIOS '$rom_path' injected."
                else
                    inject_vbios_to_vm "$selected_vm" "$virsh_cmd" "$rom_path" "$DRY_RUN"
                fi
                ;;
            skip|"")
                log "INFO" "Skipped VBIOS configuration for '$selected_vm'."
                ;;
        esac
    fi
}

do_vbios_inject_standalone() {
    local action="$1"

    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "This action must be run as root. Please use sudo."
        exit 1
    fi

    local virsh_cmd="virsh"
    if ! command -v virsh >/dev/null 2>&1; then
        log "ERROR" "virsh not found. Cannot configure VBIOS."
        exit 1
    fi

    if virsh -c qemu:///system list --all >/dev/null 2>&1; then
        virsh_cmd="virsh -c qemu:///system"
    elif virsh -c qemu:///session list --all >/dev/null 2>&1; then
        virsh_cmd="virsh -c qemu:///session"
    else
        log "ERROR" "Cannot connect to libvirt. Cannot configure VBIOS."
        exit 1
    fi

    local vm_list selected_vm
    mapfile -t vm_list < <($virsh_cmd list --all --name | grep -v '^$' || true)
    if [[ ${#vm_list[@]} -eq 0 ]]; then
        log "ERROR" "No libvirt VMs found."
        exit 1
    fi

    selected_vm=""
    if [[ -n "$VM_NAME" ]]; then
        for vm in "${vm_list[@]}"; do
            if [[ "$vm" == "$VM_NAME" ]]; then
                selected_vm="$VM_NAME"
                break
            fi
        done
        if [[ -z "$selected_vm" ]]; then
            log "ERROR" "VM '$VM_NAME' not found."
            exit 1
        fi
    else
        local menu_items=()
        local vm i=1
        for vm in "${vm_list[@]}"; do
            local state vbios_info
            state="$($virsh_cmd domstate "$vm" 2>/dev/null || echo "unknown")"
            if vm_has_vbios_config "$vm" "$virsh_cmd"; then
                vbios_info=" [VBIOS injected]"
            else
                vbios_info=" [VBIOS not configured]"
            fi
            menu_items+=("$i" "$vm ($state)${vbios_info}")
            i=$((i+1))
        done
        menu_items+=("0" "Cancel")

        local selected_idx
        selected_idx="$(tui_menu "Select VM for VBIOS" "Which VM should be modified?" "" "${menu_items[@]}")"
        if [[ -z "$selected_idx" || "$selected_idx" == "0" ]]; then
            log "INFO" "Cancelled."
            exit 0
        fi
        selected_vm="${vm_list[$((selected_idx-1))]}"
    fi

    if [[ "$action" == "inject" ]]; then
        local rom_path=""
        if [[ -n "$VBIOS_FILE" && -f "$VBIOS_FILE" ]]; then
            rom_path="$VBIOS_FILE"
        else
            rom_path="$(select_vbios_file)"
            if [[ -z "$rom_path" ]]; then
                local found_files
                found_files="$(find_vbios_files | head -n 1)"
                if [[ -n "$found_files" && -f "$found_files" ]]; then
                    rom_path="$found_files"
                else
                    log "ERROR" "No VBIOS .rom files found in $VBIOS_DIR. Use --dump-vbios or --vbios-path."
                    exit 1
                fi
            fi
        fi

        # Pre-check: if already injected with same ROM, skip
        if vm_vbios_is_same_rom "$selected_vm" "$virsh_cmd" "$rom_path"; then
            log "SUCCESS" "VM '$selected_vm' already has VBIOS '$rom_path' injected."
            exit 0
        fi

        inject_vbios_to_vm "$selected_vm" "$virsh_cmd" "$rom_path" "$DRY_RUN"
    else
        if ! vm_has_vbios_config "$selected_vm" "$virsh_cmd"; then
            log "WARN" "VM '$selected_vm' does not have VBIOS configured. Nothing to remove."
            exit 0
        fi
        remove_vbios_from_vm "$selected_vm" "$virsh_cmd" "$DRY_RUN"
    fi
}

remove_shmem_from_vm() {
    local vm_name="$1"
    local virsh_cmd="$2"
    local dry="${3:-false}"
    local size="${4:-}"

    if [[ "$dry" == true ]]; then
        log "INFO" "[DRY-RUN] Would remove ivshmem device(s) from VM '$vm_name'."
        return 0
    fi

    local tmp_xml
    tmp_xml="$(mktemp)"
    _TRAPPED_TMP_XML="$tmp_xml"
    _trapped_cleanup() {
        if [[ -n "${_TRAPPED_TMP_XML:-}" ]]; then
            rm -f "$_TRAPPED_TMP_XML" >/dev/null 2>&1 || true
        fi
        _TRAPPED_TMP_XML=""
        trap 'log "WARN" "Interrupted by user."; exit 130' INT TERM
    }
    trap '_trapped_cleanup' INT TERM

    local removed_count=0
    local attempt=0
    local max_attempts=10

    while [[ "$attempt" -lt "$max_attempts" ]]; do
        if ! $virsh_cmd dumpxml --inactive "$vm_name" 2>/dev/null | grep -q "model type='ivshmem-plain'"; then
            break
        fi

        attempt=$((attempt + 1))

        if [[ "$attempt" -eq 1 && -n "$size" ]]; then
            cat > "$tmp_xml" <<XMLEOF
<shmem name='looking-glass'>
  <model type='ivshmem-plain'/>
  <size unit='M'>${size}</size>
</shmem>
XMLEOF
        else
            cat > "$tmp_xml" <<'XMLEOF'
<shmem name='looking-glass'>
  <model type='ivshmem-plain'/>
</shmem>
XMLEOF
        fi

        log "INFO" "Removing ivshmem device from VM '$vm_name' (attempt ${attempt})…"
        if $virsh_cmd detach-device --config "$vm_name" "$tmp_xml"; then
            removed_count=$((removed_count + 1))
            log "SUCCESS" "Removed ivshmem device (attempt ${attempt})."
        else
            log "WARN" "Failed to detach ivshmem device from VM '$vm_name' (attempt ${attempt})."
            if [[ "$attempt" -gt 1 ]]; then
                break
            fi
        fi
    done

    if [[ "$removed_count" -eq 0 ]]; then
        log "WARN" "No ivshmem devices were removed from VM '$vm_name'."
    else
        log "SUCCESS" "Removed ${removed_count} ivshmem device(s) from VM '$vm_name'."
    fi

    rm -f "$tmp_xml"
    _TRAPPED_TMP_XML=""
    trap 'log "WARN" "Interrupted by user."; exit 130' INT TERM
}

attach_shmem_to_vm() {
    local vm_name="$1"
    local virsh_cmd="$2"
    local size="$3"
    local dry="${4:-false}"

    if [[ "$dry" == true ]]; then
        log "INFO" "[DRY-RUN] Would attach ${size}MB shmem device to VM '$vm_name'."
        return 0
    fi

    local tmp_xml
    tmp_xml="$(mktemp)"
    _TRAPPED_TMP_XML="$tmp_xml"
    _trapped_cleanup() {
        if [[ -n "${_TRAPPED_TMP_XML:-}" ]]; then
            rm -f "$_TRAPPED_TMP_XML" >/dev/null 2>&1 || true
        fi
        _TRAPPED_TMP_XML=""
        trap 'log "WARN" "Interrupted by user."; exit 130' INT TERM
    }
    trap '_trapped_cleanup' INT TERM
    cat > "$tmp_xml" <<XMLEOF
<shmem name='looking-glass'>
  <model type='ivshmem-plain'/>
  <size unit='M'>${size}</size>
</shmem>
XMLEOF

    log "INFO" "Attaching ${size}MB Looking Glass shmem device to VM '$vm_name'…"
    if $virsh_cmd attach-device --config "$vm_name" "$tmp_xml"; then
        log "SUCCESS" "Successfully injected <shmem> hardware into VM '$vm_name'."
        log "WARN" "IMPORTANT: If '$vm_name' is currently running, you MUST fully shut it down (not just restart) for the new hardware to appear."
        if ! $virsh_cmd dumpxml --inactive "$vm_name" 2>/dev/null | grep -q "model type='ivshmem-plain'"; then
            log "WARN" "Device attachment reported success but ivshmem device is not present in VM persistent XML."
        fi
    else
        log "WARN" "Failed to attach shmem device to VM '$vm_name'. You may need to add it manually."
    fi
    rm -f "$tmp_xml"
    _TRAPPED_TMP_XML=""
    trap 'log "WARN" "Interrupted by user."; exit 130' INT TERM
}

shmem_size_menu() {
    local current_size="${1:-}"
    local prompt="${2:-Select the shared-memory pool size for your target resolution:}"
    local default_item="64"
    local result=""

    # Map size to default menu tag
    if [[ "$current_size" == "128" ]]; then
        default_item="128"
    elif [[ "$current_size" == "256" ]]; then
        default_item="256"
    elif [[ "$current_size" == "512" ]]; then
        default_item="512"
    fi

    if [[ -n "$current_size" && "$current_size" != "" ]]; then
        prompt="Current size: ${current_size}MB. ${prompt}"
    fi

    local -a menu_args=(
        "Shared Memory Size"
        "$prompt"
        "$default_item"
        "64" "64 MB  — Full HD / 1080p"
        "128" "128 MB — 1440p / QHD"
        "256" "256 MB — 4K / UHD"
        "512" "512 MB — Ultrawide 4K / High Refresh"
    )
    result="$(tui_menu "${menu_args[@]}")"
    printf '%s' "$result"
}

configure_libvirt_vm() {
    local vm_list selected_vm
    local virsh_cmd="virsh"

    if ! command -v virsh >/dev/null 2>&1; then
        log "INFO" "virsh not found. Skipping libvirt VM configuration."
        return 0
    fi

    # Detect correct libvirt URI (system vs session)
    if virsh -c qemu:///system list --all >/dev/null 2>&1; then
        virsh_cmd="virsh -c qemu:///system"
        log "INFO" "Using libvirt system connection (qemu:///system)."
    elif virsh -c qemu:///session list --all >/dev/null 2>&1; then
        virsh_cmd="virsh -c qemu:///session"
        log "INFO" "Using libvirt session connection (qemu:///session)."
    else
        log "WARN" "Cannot connect to libvirt. Skipping VM configuration."
        return 0
    fi

    log "INFO" "Scanning libvirt virtual machines…"
    mapfile -t vm_list < <($virsh_cmd list --all --name | grep -v '^$' || true)
    if [[ ${#vm_list[@]} -eq 0 ]]; then
        log "WARN" "No libvirt VMs found. Skipping VM configuration."
        return 0
    fi

    local selected_vm=""

    # Only --vm-name bypasses the interactive menu; otherwise force user to choose
    if [[ -n "$VM_NAME" ]]; then
        local vm_found=false
        for vm in "${vm_list[@]}"; do
            if [[ "$vm" == "$VM_NAME" ]]; then
                vm_found=true
                break
            fi
        done
        if [[ "$vm_found" == true ]]; then
            selected_vm="$VM_NAME"
            log "INFO" "Using explicitly specified VM '$selected_vm' (--vm-name)."
        else
            log "WARN" "VM '$VM_NAME' not found. Falling back to selection."
        fi
    fi

    # Always show interactive selection unless --vm-name was valid
    if [[ -z "$selected_vm" ]]; then
        local menu_items=()
        local vm i=1
        for vm in "${vm_list[@]}"; do
            local state shmem_info
            state="$($virsh_cmd domstate "$vm" 2>/dev/null || echo "unknown")"
            if $virsh_cmd dumpxml --inactive "$vm" 2>/dev/null | grep -q "model type='ivshmem-plain'"; then
                local cur_size
                cur_size="$(get_vm_shmem_size "$vm" "$virsh_cmd")"
                shmem_info=" [ivshmem ${cur_size}MB]"
            else
                shmem_info=""
            fi
            menu_items+=("$i" "$vm ($state)${shmem_info}")
            i=$((i+1))
        done
        menu_items+=("0" "Skip VM configuration")

        local selected_idx
        selected_idx="$(tui_menu "Select VM" "Which VM should have the Looking Glass shared memory device attached?" "" "${menu_items[@]}")"
        if [[ -z "$selected_idx" || "$selected_idx" == "0" ]]; then
            log "INFO" "Skipping VM XML automation."
            return 0
        fi
        selected_vm="${vm_list[$((selected_idx-1))]}"
    fi

    log "INFO" "Targeting VM: $selected_vm"

    # Detect existing shmem configuration on this VM
    local has_shmem=false
    local current_size=""
    if $virsh_cmd dumpxml --inactive "$selected_vm" 2>/dev/null | grep -q "model type='ivshmem-plain'"; then
        has_shmem=true
        current_size="$(get_vm_shmem_size "$selected_vm" "$virsh_cmd")"
        log "INFO" "Detected existing ivshmem device on '$selected_vm' with size: ${current_size}MB."
        local ivshmem_count
        ivshmem_count="$($virsh_cmd dumpxml --inactive "$selected_vm" 2>/dev/null | grep -c "model type='ivshmem-plain'" || echo 0)"
        if [[ "$ivshmem_count" -gt 1 ]]; then
            log "WARN" "Found ${ivshmem_count} ivshmem devices on '$selected_vm' (possible duplicate from a previous swap). All will be removed before attaching the new device."
        fi
    fi

    # Determine what size to use
    local target_size=""

    if [[ -n "$LG_SHMEM_SIZE" && "$LG_SHMEM_SIZE" != "" ]]; then
        # User explicitly passed --shmem-size: use it directly
        target_size="$LG_SHMEM_SIZE"
        if [[ "$has_shmem" == true && "$target_size" != "$current_size" ]]; then
            log "INFO" "Replacing existing ${current_size}MB ivshmem with ${target_size}MB (--shmem-size)."
            remove_shmem_from_vm "$selected_vm" "$virsh_cmd" "$DRY_RUN" "$current_size"
        elif [[ "$has_shmem" == true && "$target_size" == "$current_size" ]]; then
            log "SUCCESS" "VM '$selected_vm' already has ${target_size}MB ivshmem-plain device attached."
            return 0
        fi
    elif [[ "$has_shmem" == true && "$YES" != true && "$DRY_RUN" != true ]]; then
        # Interactive: VM already has shmem — ask user what to do
        local action
        action="$(tui_menu "VM Configuration" "VM '$selected_vm' already has a ${current_size}MB ivshmem device. What do you want to do?" "" \
            "keep" "Keep current settings (${current_size}MB)" \
            "change" "Change shared-memory size" \
            "remove" "Remove ivshmem device")"
        case "$action" in
            keep|"")
                log "SUCCESS" "Kept existing ivshmem device on '$selected_vm' (${current_size}MB)."
                LG_SHMEM_SIZE="$current_size"
                return 0
                ;;
            change)
                target_size="$(shmem_size_menu "$current_size")"
                if [[ -z "$target_size" ]]; then
                    target_size="$current_size"
                fi
                if [[ "$target_size" != "$current_size" ]]; then
                    remove_shmem_from_vm "$selected_vm" "$virsh_cmd" "$DRY_RUN" "$current_size"
                else
                    log "SUCCESS" "Size unchanged (${current_size}MB)."
                    LG_SHMEM_SIZE="$current_size"
                    return 0
                fi
                ;;
            remove)
                remove_shmem_from_vm "$selected_vm" "$virsh_cmd" "$DRY_RUN" "$current_size"
                LG_SHMEM_SIZE=""
                return 0
                ;;
        esac
    elif [[ "$has_shmem" == false ]]; then
        # No shmem yet — prompt for size unless --shmem-size was given
        if [[ -n "$LG_SHMEM_SIZE" && "$LG_SHMEM_SIZE" != "" ]]; then
            target_size="$LG_SHMEM_SIZE"
        elif [[ "$YES" != true && "$DRY_RUN" != true ]]; then
            target_size="$(shmem_size_menu "")"
            if [[ -z "$target_size" ]]; then
                target_size="64"
            fi
        else
            target_size="64"
        fi
    fi

    LG_SHMEM_SIZE="$target_size"

    if [[ "$DRY_RUN" == true ]]; then
        if [[ "$has_shmem" == true ]]; then
            log "INFO" "[DRY-RUN] Would replace ${current_size}MB with ${target_size}MB on VM '$selected_vm'."
        else
            log "INFO" "[DRY-RUN] Would attach ${target_size}MB shmem device to VM '$selected_vm'."
        fi
        return 0
    fi

    attach_shmem_to_vm "$selected_vm" "$virsh_cmd" "$target_size" "$DRY_RUN"
}

do_install() {
    log "INFO" "Starting Installation Sequence…"
    confirm_or_exit "This will install software and modify system files. Proceed?"

    preflight_hardware

    log "INFO" "Detecting package manager for installation…"
    if command -v dnf >/dev/null 2>&1; then
        log "INFO" "Detected Fedora/RHEL (dnf)"
        if [[ -x /usr/local/bin/looking-glass-client ]]; then
            log "SUCCESS" "looking-glass-client already present."
        elif rpm -q looking-glass-client >/dev/null 2>&1; then
            log "SUCCESS" "looking-glass-client already installed via dnf."
        else
            local copr_worked=false
            if { dnf copr list 2>/dev/null || true; } | grep -q agnelo/looking-glass; then
                log "SUCCESS" "COPR agnelo/looking-glass already enabled."
                copr_worked=true
            elif [[ "$DRY_RUN" == true ]]; then
                log "INFO" "[DRY-RUN] Would run: dnf copr enable -y agnelo/looking-glass"
                copr_worked=true
            elif dnf copr enable -y agnelo/looking-glass >/dev/null 2>&1; then
                log "SUCCESS" "COPR agnelo/looking-glass enabled."
                copr_worked=true
            else
                log "WARN" "COPR agnelo/looking-glass is unavailable for this release."
            fi

            if [[ "$copr_worked" == true ]]; then
                if [[ "$DRY_RUN" == true ]]; then
                    log "INFO" "[DRY-RUN] Would run: dnf install -y looking-glass-client"
                elif dnf install -y looking-glass-client >/dev/null 2>&1; then
                    log "SUCCESS" "looking-glass-client installed via dnf."
                else
                    log "WARN" "dnf install failed. Will try source compilation."
                    copr_worked=false
                fi
            fi

            if [[ "$copr_worked" == false ]]; then
                log "INFO" "Installing build dependencies for source compilation…"
                if [[ "$DRY_RUN" == true ]]; then
                    log "INFO" "[DRY-RUN] Would install Fedora build deps and compile from source."
                else
                    local fedora_deps=(cmake gcc gcc-c++ git make pkgconf ninja-build mesa-libEGL-devel sdl2-compat-devel SDL2_ttf-devel fontconfig-devel gmp-devel libglvnd-devel libX11-devel libXcursor-devel libXext-devel libXfixes-devel libXi-devel libXinerama-devel libXpresent-devel libXrandr-devel libxkbcommon-devel libXScrnSaver-devel wayland-devel wayland-protocols-devel pipewire-devel pulseaudio-libs-devel libsamplerate-devel nettle-devel libzstd-devel binutils-devel spice-protocol)
                    if dnf install -y "${fedora_deps[@]}"; then
                        compile_from_source
                    else
                        log "WARN" "Failed to install build dependencies. Please install them manually and re-run."
                    fi
                fi
            fi
        fi

    elif command -v pacman >/dev/null 2>&1; then
        log "INFO" "Detected Arch Linux (pacman)"
        run_or_simulate pacman -S --noconfirm --needed base-devel cmake gcc pkgconf sdl2 sdl2_ttf \
        spice-protocol fontconfig gmp wayland-protocols libx11 libxext libxfixes libxi \
        libxinerama libxss libxcursor libxpresent libxkbcommon libglvnd
        if ! pacman -Q looking-glass >/dev/null 2>&1; then
            if command -v yay >/dev/null 2>&1 && [[ -n "$REAL_USER" && "$REAL_USER" != "root" ]]; then
                log "INFO" "Installing looking-glass from AUR via yay as user $REAL_USER…"
                run_or_simulate sudo -u "$REAL_USER" yay -S --noconfirm --needed looking-glass
            elif command -v paru >/dev/null 2>&1 && [[ -n "$REAL_USER" && "$REAL_USER" != "root" ]]; then
                log "INFO" "Installing looking-glass from AUR via paru as user $REAL_USER…"
                run_or_simulate sudo -u "$REAL_USER" paru -S --noconfirm --needed looking-glass
            else
                log "WARN" "No AUR helper (yay/paru) detected or no valid non-root user found. Please install 'looking-glass' from the AUR manually."
            fi
        else
            log "SUCCESS" "looking-glass already installed."
        fi

    elif command -v apt >/dev/null 2>&1; then
        log "INFO" "Detected Ubuntu/Debian (apt)"
        log "INFO" "Installing all required build dependencies…"
        run_or_simulate apt-get update
        run_or_simulate apt-get install -y build-essential pkg-config binutils-dev cmake ninja-build fonts-freefont-ttf \
        libsdl2-dev libsdl2-ttf-dev libspice-protocol-dev libfontconfig1-dev libgmp-dev \
        libwayland-dev wayland-protocols libx11-dev libxext-dev libxfixes-dev libxi-dev \
        libxinerama-dev libxss-dev libxcursor-dev libxpresent-dev libxkbcommon-dev \
        libglvnd-dev libegl1-mesa-dev
        compile_from_source
    else
        log "ERROR" "Unsupported package manager. Please install manually."
        exit 1
    fi

    setup_shared_memory
    setup_security
    generate_user_config
    configure_libvirt_vm
    resize_shared_memory "${LG_SHMEM_SIZE:-64}"
    configure_vm_rebar
    configure_vm_vbios
    install_shell_completions
    create_desktop_entry

    # Final install verification summary
    log "SUCCESS" "Installation complete! You can now run 'looking-glass-client'."
    log "INFO" ""
    log "INFO" "────────── Verify These Items ──────────"
    if [[ -x /usr/local/bin/looking-glass-client ]]; then
        log "INFO" "  looking-glass-client: /usr/local/bin/looking-glass-client"
    fi
    if [[ -f /etc/tmpfiles.d/10-looking-glass.conf ]]; then
        log "INFO" "  Shared-memory config: /etc/tmpfiles.d/10-looking-glass.conf"
    fi
    if [[ -e /dev/shm/looking-glass ]]; then
        log "INFO" "  Shared-memory node:   /dev/shm/looking-glass"
    fi
    if [[ -f /usr/local/share/applications/looking-glass-client.desktop ]]; then
        log "INFO" "  Desktop shortcut:       /usr/local/share/applications/looking-glass-client.desktop"
    fi
    if [[ -n "${REAL_USER:-}" && "$REAL_USER" != "root" ]]; then
        local _uh
        _uh="$(getent passwd "$REAL_USER" | cut -d: -f6)"
        if [[ -f "$_uh/Desktop/looking-glass-client.desktop" ]]; then
            log "INFO" "  User Desktop shortcut: $_uh/Desktop/looking-glass-client.desktop"
        fi
        if [[ -f "$_uh/.looking-glass-client.ini" ]]; then
            log "INFO" "  User config file:       $_uh/.looking-glass-client.ini"
        fi
    fi
    log "INFO" "  Command to run:         looking-glass-client"
    if [[ -n "${selected_vm:-}" ]]; then
        log "INFO" "  Target VM:              $selected_vm"
    fi
    log "INFO" "  Shared-memory size:     ${LG_SHMEM_SIZE}MB"
    log "INFO" "────────────────────────────────────────"
}

do_uninstall() {
    log "INFO" "Starting Uninstall Sequence…"
    confirm_or_exit "This will remove packages and delete shared-memory config. Proceed?"

    if pgrep -x looking-glass-client >/dev/null 2>&1; then
        log "INFO" "Stopping looking-glass-client process(es)…"
        run_or_simulate pkill -x -TERM looking-glass-client || true
        sleep 1
        if pgrep -x looking-glass-client >/dev/null 2>&1; then
            run_or_simulate pkill -x -KILL looking-glass-client || true
        fi
    else
        log "INFO" "No running looking-glass-client process found."
    fi

    if [[ -f /etc/tmpfiles.d/10-looking-glass.conf ]]; then
        run_or_simulate rm -f /etc/tmpfiles.d/10-looking-glass.conf
        log "SUCCESS" "Removed tmpfiles config."
    else
        log "INFO" "No tmpfiles config found."
    fi

    if [[ -e /dev/shm/looking-glass ]]; then
        if [[ -f /dev/shm/looking-glass ]]; then
            run_or_simulate rm -f /dev/shm/looking-glass
            log "SUCCESS" "Shared memory node removed."
        else
            log "WARN" "/dev/shm/looking-glass exists but is not a regular file. Not removing."
        fi
    else
        log "INFO" "No /dev/shm/looking-glass node found."
    fi

    if command -v dnf >/dev/null 2>&1; then
        if rpm -q looking-glass-client >/dev/null 2>&1; then
            log "INFO" "Removing looking-glass-client via dnf…"
            run_or_simulate dnf remove -y looking-glass-client
        else
            log "INFO" "Package looking-glass-client not installed."
        fi
        if { dnf copr list 2>/dev/null || true; } | grep -q agnelo/looking-glass; then
            run_or_simulate dnf copr disable -y agnelo/looking-glass
        else
            log "INFO" "COPR agnelo/looking-glass not enabled."
        fi
    elif command -v pacman >/dev/null 2>&1; then
        if pacman -Q looking-glass >/dev/null 2>&1; then
            log "INFO" "Removing looking-glass via pacman…"
            run_or_simulate pacman -Rns --noconfirm looking-glass
        else
            log "INFO" "Package looking-glass not installed."
        fi
    elif command -v apt >/dev/null 2>&1; then
        log "INFO" "Note: On Ubuntu, LG is usually compiled from source. Dependencies remain installed."
    fi

    if [[ -f /usr/local/bin/looking-glass-client ]]; then
        log "INFO" "Removing compiled looking-glass-client binary…"
        run_or_simulate rm -f /usr/local/bin/looking-glass-client
        log "SUCCESS" "Removed /usr/local/bin/looking-glass-client"
    fi

    if [[ -f /usr/local/share/applications/looking-glass-client.desktop ]]; then
        log "INFO" "Removing desktop shortcut…"
        run_or_simulate rm -f /usr/local/share/applications/looking-glass-client.desktop
        log "SUCCESS" "Removed desktop shortcut."
    fi
    # Remove user Desktop copy
    local target_user target_home desktop_dir
    target_user="${REAL_USER:-${SUDO_USER:-}}"
    if [[ -z "$target_user" || "$target_user" == "root" ]]; then
        target_user="${USER:-}"
    fi
    if [[ -n "$target_user" && "$target_user" != "root" ]]; then
        target_home="$(getent passwd "$target_user" | cut -d: -f6)"
        desktop_dir="$target_home/Desktop"
        if [[ -f "$desktop_dir/looking-glass-client.desktop" ]]; then
            run_or_simulate rm -f "$desktop_dir/looking-glass-client.desktop"
            log "SUCCESS" "Removed desktop shortcut from $desktop_dir."
        fi
    fi

    if [[ -n "${REAL_USER:-}" && "$REAL_USER" != "root" ]]; then
        local USER_HOME
        local CONF_FILE
        USER_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
        CONF_FILE="$USER_HOME/.looking-glass-client.ini"
        if [[ -f "$CONF_FILE" ]]; then
            run_or_simulate rm -f "$CONF_FILE"
            log "SUCCESS" "Removed $CONF_FILE"
        fi
    fi

    if command -v aa-status >/dev/null 2>&1; then
        local local_apparmor
        local_apparmor="/etc/apparmor.d/local/abstractions/libvirt-qemu"
        if [[ -f "$local_apparmor" ]] && grep -qF "/dev/shm/looking-glass" "$local_apparmor" 2>/dev/null; then
            if [[ "$DRY_RUN" == false ]]; then
                sed -i '/\/dev\/shm\/looking-glass/d' "$local_apparmor"
            fi
            log "SUCCESS" "Removed AppArmor rule from local libvirt-qemu abstraction."
            if command -v systemctl >/dev/null 2>&1; then
                run_or_simulate systemctl reload apparmor || true
            fi
        fi
    fi

    # VM Orphan Hardware Check
    if command -v virsh >/dev/null 2>&1; then
        local orphan_vms=()
        local vm_name
        local virsh_uninstall="virsh"
        if virsh -c qemu:///system list --all >/dev/null 2>&1; then
            virsh_uninstall="virsh -c qemu:///system"
        elif virsh -c qemu:///session list --all >/dev/null 2>&1; then
            virsh_uninstall="virsh -c qemu:///session"
        fi
        while IFS= read -r vm_name; do
            [[ -z "$vm_name" ]] && continue
            if $virsh_uninstall dumpxml "$vm_name" 2>/dev/null | grep -q "model type='ivshmem-plain'"; then
                orphan_vms+=("$vm_name")
            fi
        done < <($virsh_uninstall list --all --name 2>/dev/null || true)

        if [[ ${#orphan_vms[@]} -gt 0 ]]; then
            log "ERROR" "CRITICAL: The following VMs still have the Looking Glass memory device attached:"
            for vm_name in "${orphan_vms[@]}"; do
                log "ERROR" "  -> $vm_name"
            done
            log "WARN" "You MUST manually remove the 'ivshmem' device from these VMs in virt-manager."
            log "WARN" "If you do not remove it, the VMs will refuse to boot because the shared memory file is gone!"
        fi

        # ReBAR orphan check
        while IFS= read -r vm_name; do
            [[ -z "$vm_name" ]] && continue
            if $virsh_uninstall dumpxml "$vm_name" 2>/dev/null | grep -q "X-PciMmio64Mb"; then
                log "WARN" "VM '$vm_name' still has ReBAR 64-bit MMIO configuration (X-PciMmio64Mb)."
                log "WARN" "You may want to remove this manually in virt-manager if ReBAR is no longer needed."
            fi
        done < <($virsh_uninstall list --all --name 2>/dev/null || true)

        # VBIOS orphan check
        while IFS= read -r vm_name; do
            [[ -z "$vm_name" ]] && continue
            if $virsh_uninstall dumpxml "$vm_name" 2>/dev/null | grep -q "<rom file="; then
                log "WARN" "VM '$vm_name' still has VBIOS ROM injection configured."
                log "WARN" "You may want to remove this manually in virt-manager if VBIOS is no longer needed."
            fi
        done < <($virsh_uninstall list --all --name 2>/dev/null || true)
    fi

    log "SUCCESS" "Looking Glass has been successfully uninstalled."
}

# --- Argument parsing -------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --eject|--uninstall)
                MODE="uninstall"
                shift
                ;;
            --install-script)
                install_script
                exit 0
                ;;
            --self-remove)
                remove_script
                exit 0
                ;;
            --create-shortcut)
                create_desktop_entry
                exit 0
                ;;
            --install-completions)
                install_shell_completions
                exit 0
                ;;
            --no-tui)
                NO_TUI=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --yes|-y)
                YES=true
                shift
                ;;
            --vm-name)
                if [[ -z "${2:-}" || "${2:0:1}" == "-" ]]; then
                    log "ERROR" "--vm-name requires a value."
                    exit 1
                fi
                VM_NAME="$2"
                shift 2
                ;;
            --shmem-size)
                if [[ -z "${2:-}" || "${2:0:1}" == "-" ]]; then
                    log "ERROR" "--shmem-size requires a value."
                    exit 1
                fi
                LG_SHMEM_SIZE="$2"
                shift 2
                ;;
            --enable-rebar)
                do_rebar_standalone "enable"
                exit 0
                ;;
            --disable-rebar)
                do_rebar_standalone "disable"
                exit 0
                ;;
            --dump-vbios)
                do_vbios_dump_standalone
                ;;
            --inject-vbios)
                do_vbios_inject_standalone "inject"
                exit 0
                ;;
            --remove-vbios)
                do_vbios_inject_standalone "remove"
                exit 0
                ;;
            --vbios-path)
                if [[ -z "${2:-}" || "${2:0:1}" == "-" ]]; then
                    log "ERROR" "--vbios-path requires a value."
                    exit 1
                fi
                VBIOS_FILE="$2"
                shift 2
                ;;
            --help|-h)
                cat <<EOF
Usage: sudo ./${SCRIPT_NAME} [OPTIONS]

Options:
  --install-script       Copy this script to $INSTALLED_PATH.
  --self-remove          Remove the installed script from $INSTALLED_PATH.
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
EOF
                exit 0
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                exit 1
                ;;
        esac
    done
}

# --- Main -------------------------------------------------------------------
parse_args "$@"

# Auto-elevate with sudo if not running as root
if [[ $EUID -ne 0 ]]; then
    log "INFO" "Not running as root. Re-launching with sudo…"
    exec sudo "${BASH_SOURCE[0]}" "$@"
fi

detect_tui_backend
log "INFO" "Starting Looking Glass Manager (mode: ${MODE})…"

# Show interactive main menu when no explicit mode or action was requested
if [[ "$MODE" == "install" && "$NO_TUI" == false && "$DRY_RUN" == false && "$YES" == false && "$TUI_BACKEND" != "none" && "$TUI_BACKEND" != "" ]]; then
    show_main_menu
fi

if [[ "$MODE" == "uninstall" ]]; then
    detect_environment
    do_uninstall
    if is_script_installed && [[ "$YES" != true ]]; then
        if [[ "$TUI_BACKEND" != "none" && "$TUI_BACKEND" != "" ]]; then
            if tui_yesno "Self-Remove" "Also remove this script ($INSTALLED_PATH)?"; then
                remove_script
            fi
        else
            echo ""
            printf "${C_YELLOW}? Also remove this script (%s)? [y/N] ${C_NC}" "$INSTALLED_PATH"
            read -r answer
            case "$answer" in
                [yY]|[yY][eE][sS]) remove_script ;;
            esac
        fi
    fi
else
    detect_environment
    maybe_prompt_install
    do_install
fi
