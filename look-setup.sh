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
DRY_RUN=false
YES=false
MODE="install"
LOG_FILE="/var/log/looking-glass-setup.log"

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
    local display_type
    display_type="x11"
    if [[ -n "${REAL_USER:-}" && "$REAL_USER" != "root" ]]; then
        if sudo -u "$REAL_USER" bash -c 'echo "$XDG_SESSION_TYPE"' 2>/dev/null | grep -iq "wayland"; then
            display_type="wayland"
        fi
    fi
    printf '%s' "$display_type"
}

setup_shared_memory() {
    local desired_line
    log "INFO" "Configuring persistent shared memory for user: ${REAL_USER:-<unknown>}"
    desired_line="f /dev/shm/looking-glass 0660 ${REAL_USER:-root} ${VIRT_GROUP:-root} -"
    write_tmpfiles_idempotent "/etc/tmpfiles.d/10-looking-glass.conf" "$desired_line"
    run_or_simulate systemd-tmpfiles --create /etc/tmpfiles.d/10-looking-glass.conf
}

setup_security() {
    local selinux_state
    local local_apparmor

    if command -v getenforce >/dev/null 2>&1 && command -v chcon >/dev/null 2>&1; then
        selinux_state="$(getenforce)"
        if [[ "$selinux_state" != "Disabled" && -e /dev/shm/looking-glass ]]; then
            log "INFO" "Applying SELinux context to shared memory…"
            run_or_simulate chcon -t svirt_tmpfs_t /dev/shm/looking-glass || true
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

generate_user_config() {
    local USER_HOME
    local CONF_FILE
    local display_type

    if [[ -n "${REAL_USER:-}" && "$REAL_USER" != "root" ]]; then
        USER_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
        CONF_FILE="$USER_HOME/.looking-glass-client.ini"
        if [[ ! -f "$CONF_FILE" ]]; then
            display_type="$(detect_display_server)"
            log "INFO" "Generating $display_type optimized configuration for $REAL_USER…"
            if [[ "$DRY_RUN" == false ]]; then
                if [[ "$display_type" == "wayland" ]]; then
                    cat <<'CONFEOF' > "$CONF_FILE"
[app]
shmFile=/dev/shm/looking-glass

[spice]
enable=yes
audio=yes

[wayland]
fractionalScale=yes
CONFEOF
                else
                    cat <<'CONFEOF' > "$CONF_FILE"
[app]
shmFile=/dev/shm/looking-glass

[spice]
enable=yes
audio=yes
CONFEOF
                fi
                chown "$REAL_USER":"$REAL_USER" "$CONF_FILE"
            fi
        else
            log "SUCCESS" "Configuration file $CONF_FILE already exists, skipping generation."
        fi
    fi
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
        run_or_simulate pacman -S --noconfirm --needed base-devel
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
        run_or_simulate apt-get install -y binutils-dev cmake fonts-freefont-ttf libsdl2-dev libsdl2-ttf-dev \
        libspice-protocol-dev libfontconfig1-dev libgmp-dev libwayland-dev \
        wayland-protocols libx11-dev libxext-dev libxfixes-dev libxi-dev \
        libxinerama-dev libxss-dev libxcursor-dev libxpresent-dev libxkbcommon-dev \
        libglvnd-dev libegl1-mesa-dev
        log "WARN" "Dependencies installed. You will need to compile the client from source (check looking-glass.io)."
    else
        log "ERROR" "Unsupported package manager. Please install manually."
        exit 1
    fi

    setup_shared_memory
    setup_security
    generate_user_config

    log "SUCCESS" "Installation complete! You can now run 'looking-glass-client'."
}

do_uninstall() {
    log "INFO" "Starting Uninstall Sequence…"
    confirm_or_exit "This will remove packages and delete shared-memory config. Proceed?"

    if pgrep -x looking-glass-client >/dev/null 2>&1; then
        log "INFO" "Stopping looking-glass-client process(es)…"
        run_or_simulate killall -TERM looking-glass-client || true
        sleep 1
        if pgrep -x looking-glass-client >/dev/null 2>&1; then
            run_or_simulate killall -KILL looking-glass-client || true
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
  --uninstall, --eject   Uninstall Looking Glass and remove shared-memory config.
  --dry-run              Show what would be done without touching the system.
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
log "INFO" "Starting Looking Glass Manager (mode: ${MODE})…"
detect_environment

if [[ "$MODE" == "uninstall" ]]; then
    do_uninstall
else
    do_install
fi
