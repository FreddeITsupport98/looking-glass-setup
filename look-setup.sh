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

    printf "${color}%s %s${C_NC}\n" "$prefix" "$msg"

    if [[ "$DRY_RUN" == false ]]; then
        timestamp="[$(date +'%Y-%m-%d %H:%M:%S')]"
        printf "%s %s %s\n" "$timestamp" "$prefix" "$msg" >> "$LOG_FILE" 2>/dev/null || true
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
        install_shell_completions
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
        rm -f "$INSTALLED_PATH"
        log "SUCCESS" "Removed $INSTALLED_PATH"
    else
        log "INFO" "No installed script found at $INSTALLED_PATH."
    fi
    # Clean up desktop entry if present
    if [[ -f /usr/local/share/applications/looking-glass-client.desktop ]]; then
        rm -f /usr/local/share/applications/looking-glass-client.desktop
        log "SUCCESS" "Removed desktop shortcut."
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
    local opts="--install-script --self-remove --create-shortcut --uninstall --eject --install-completions --dry-run --no-tui --yes -y --help -h"
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
    menu_items+=("exit" "Exit")
    choice="$(tui_menu "Looking Glass Manager" "Select an action:" "${menu_items[@]}")"
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
    if [[ "$TUI_BACKEND" != "none" && "$TUI_BACKEND" != "" ]]; then
        if tui_yesno "Deploy Script" "Install this script to $INSTALLED_PATH so you can run it from anywhere?"; then
            install_script
        else
            log "INFO" "Running from source without installing."
        fi
        return 0
    fi
    echo ""
    printf "${C_YELLOW}? Install this script to %s so you can run it from anywhere? [y/N] ${C_NC}" "$INSTALLED_PATH"
    read -r answer
    case "$answer" in
        [yY]|[yY][eE][sS])
            install_script
            ;;
        *)
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
    elif command -v dialog >/dev/null 2>&1; then
        TUI_BACKEND="dialog"
    else
        TUI_BACKEND="none"
    fi
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
    shift 2
    local result=""
    case "$TUI_BACKEND" in
        whiptail)
            result=$(whiptail --title "$title" --menu "$text" 20 70 10 "$@" 3>&1 1>&2 2>&3) || true
            ;;
        dialog)
            result=$(dialog --title "$title" --menu "$text" 20 70 10 "$@" 3>&1 1>&2 2>&3) || true
            ;;
        *)
            log "INFO" "$text"
            local i=1
            local tags=() items=()
            while [[ $# -gt 0 ]]; do
                tags+=("$1")
                items+=("$2")
                printf "  %d) %s\n" "$i" "$2"
                shift 2
                i=$((i+1))
            done
            read -rp "Enter number (or leave blank to cancel): " choice
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

compile_from_source() {
    local src_dir build_dir
    src_dir="/tmp/looking-glass-setup-src"
    build_dir="$src_dir/client/build"

    if [[ -x /usr/local/bin/looking-glass-client ]]; then
        log "SUCCESS" "looking-glass-client already present in /usr/local/bin/."
        return 0
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
    mkdir -p "$build_dir"
    if ! (cd "$build_dir" && cmake ../ && make -j"$(nproc)"); then
        log "ERROR" "Build failed. Check dependencies and try again."
        rm -rf "$src_dir"
        return 1
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
    log "INFO" "Configuring persistent shared memory for user: ${REAL_USER:-<unknown>}"
    desired_line="f /dev/shm/looking-glass 0660 ${REAL_USER:-root} ${VIRT_GROUP:-root} -"
    write_tmpfiles_idempotent "/etc/tmpfiles.d/10-looking-glass.conf" "$desired_line"
    if command -v systemd-tmpfiles >/dev/null 2>&1; then
        run_or_simulate systemd-tmpfiles --create /etc/tmpfiles.d/10-looking-glass.conf
    else
        log "WARN" "systemd-tmpfiles unavailable; shared-memory node will be created on next boot by systemd."
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

configure_libvirt_vm() {
    local vm_list selected_vm
    if ! command -v virsh >/dev/null 2>&1; then
        log "INFO" "virsh not found. Skipping libvirt VM configuration."
        return 0
    fi
    if ! virsh list --all >/dev/null 2>&1; then
        log "WARN" "Cannot connect to libvirt. Skipping VM configuration."
        return 0
    fi

    log "INFO" "Scanning libvirt virtual machines…"
    mapfile -t vm_list < <(virsh list --all --name | grep -v '^$' || true)
    if [[ ${#vm_list[@]} -eq 0 ]]; then
        log "WARN" "No libvirt VMs found. Skipping VM configuration."
        return 0
    fi

    local menu_items=()
    local vm i=1
    for vm in "${vm_list[@]}"; do
        local state
        state="$(virsh domstate "$vm" 2>/dev/null || echo "unknown")"
        menu_items+=("$i" "$vm ($state)")
        i=$((i+1))
    done
    menu_items+=("0" "Skip VM configuration")

    local selected_idx
    selected_idx="$(tui_menu "Select VM" "Which VM should have the Looking Glass shared memory device attached?" "${menu_items[@]}")"
    if [[ -z "$selected_idx" || "$selected_idx" == "0" ]]; then
        log "INFO" "Skipping VM XML automation."
        return 0
    fi
    selected_vm="${vm_list[$((selected_idx-1))]}"

    log "INFO" "Targeting VM: $selected_vm"

    log "INFO" "Checking VM '$selected_vm' for existing shmem device…"
    if virsh dumpxml "$selected_vm" 2>/dev/null | grep -q "model type='ivshmem-plain'"; then
        log "SUCCESS" "VM '$selected_vm' already has an ivshmem-plain device attached."
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log "INFO" "[DRY-RUN] Would attach shmem device to VM '$selected_vm'."
        return 0
    fi

    local tmp_xml
    tmp_xml="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp_xml' >/dev/null 2>&1 || true; trap 'log \"WARN\" \"Interrupted by user.\"; exit 130' INT TERM" INT TERM
    cat > "$tmp_xml" <<'XMLEOF'
<shmem name='looking-glass'>
  <model type='ivshmem-plain'/>
  <size unit='M'>64</size>
</shmem>
XMLEOF

    log "INFO" "Attaching Looking Glass shmem device to VM '$selected_vm'…"
    if virsh attach-device --config "$selected_vm" "$tmp_xml" >/dev/null 2>&1; then
        log "SUCCESS" "Successfully injected <shmem> hardware into VM '$selected_vm'."
        log "WARN" "IMPORTANT: If '$selected_vm' is currently running, you MUST fully shut it down (not just restart) for the new hardware to appear."
    else
        log "WARN" "Failed to attach shmem device to VM '$selected_vm'. You may need to add it manually."
    fi
    rm -f "$tmp_xml"
    trap 'log "WARN" "Interrupted by user."; exit 130' INT TERM
}

do_install() {
    log "INFO" "Starting Installation Sequence…"
    confirm_or_exit "This will install software and modify system files. Proceed?"

    preflight_hardware

    log "INFO" "Detecting package manager for installation…"
    if command -v dnf >/dev/null 2>&1; then
        log "INFO" "Detected Fedora/RHEL (dnf)"
        if { dnf copr list 2>/dev/null || true; } | grep -q agnelo/looking-glass; then
            log "SUCCESS" "COPR agnelo/looking-glass already enabled."
        else
            run_or_simulate dnf copr enable -y agnelo/looking-glass
        fi
        if rpm -q looking-glass-client >/dev/null 2>&1; then
            log "SUCCESS" "looking-glass-client already installed."
        else
            run_or_simulate dnf install -y looking-glass-client
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
        run_or_simulate apt-get install -y build-essential pkg-config binutils-dev cmake fonts-freefont-ttf \
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
    install_shell_completions

    log "SUCCESS" "Installation complete! You can now run 'looking-glass-client'."
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
        while IFS= read -r vm_name; do
            [[ -z "$vm_name" ]] && continue
            if virsh dumpxml "$vm_name" 2>/dev/null | grep -q "model type='ivshmem-plain'"; then
                orphan_vms+=("$vm_name")
            fi
        done < <(virsh list --all --name 2>/dev/null || true)

        if [[ ${#orphan_vms[@]} -gt 0 ]]; then
            log "ERROR" "CRITICAL: The following VMs still have the Looking Glass memory device attached:"
            for vm_name in "${orphan_vms[@]}"; do
                log "ERROR" "  -> $vm_name"
            done
            log "WARN" "You MUST manually remove the 'ivshmem' device from these VMs in virt-manager."
            log "WARN" "If you do not remove it, the VMs will refuse to boot because the shared memory file is gone!"
        fi
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
