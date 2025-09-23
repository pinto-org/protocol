#!/usr/bin/env bash
set -Eeuo pipefail

# Enable pipefail to catch errors in pipes
set -o pipefail

# =============================================================================
# Pinto Protocol Development Environment Setup Script
# =============================================================================
# This script automatically installs and configures development tools required
# for the Pinto Protocol interface and backend development.
#
# Supported platforms: macOS (Intel/ARM), Linux (Ubuntu/Debian/Fedora/Arch/SUSE)
# Tools installed: Node.js, Rust, Foundry
#
# Usage: ./scripts/misc/initialize-tools.sh [OPTIONS]
# =============================================================================

# Script configuration
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="1.0.0"

# Default configuration
DEFAULT_NODE_MIN="20.12.0"
DEFAULT_FOUNDRY_CHANNEL="stable"

# CLI flags (with defaults)
FLAG_YES=false
FLAG_DRY_RUN=false
FLAG_NO_BREW=false
FLAG_NO_VERIFY=false
FLAG_VERBOSE=false
FLAG_FORCE=false
FLAG_SKIP_NETWORK=false
FOUNDRY_CHANNEL="$DEFAULT_FOUNDRY_CHANNEL"
NODE_MIN="$DEFAULT_NODE_MIN"

# Global state tracking
NEEDS_SHELL_RELOAD=false
PROFILE_FILE=""
OS_TYPE=""
PACKAGE_MANAGER=""
TEMP_FILES=()
LOCK_FILE="/tmp/pinto-initialize-tools.lock"

# Cleanup function
cleanup() {
    local exit_code=$?
    # Use safer array length check for set -u
    if [[ ${#TEMP_FILES[@]:-0} -gt 0 ]]; then
        log_debug "Cleaning up temporary files..."
        for temp_file in "${TEMP_FILES[@]}"; do
            [[ -f "$temp_file" ]] && rm -f "$temp_file" 2>/dev/null || true
        done
    fi
    # Remove lock file
    rm -f "$LOCK_FILE" 2>/dev/null || true
    exit $exit_code
}

# Set trap for cleanup on exit
trap cleanup EXIT INT TERM

# =============================================================================
# Utility Functions
# =============================================================================

# Check network connectivity
check_network() {
    log_info "Checking network connectivity..."
    
    # Check multiple endpoints we'll need for installations
    local endpoints=(
        "https://github.com"
        "https://sh.rustup.rs"
        "https://foundry.paradigm.xyz"
    )
    
    local connectivity=false
    for endpoint in "${endpoints[@]}"; do
        if curl -Is --connect-timeout 5 --max-time 10 "$endpoint" >/dev/null 2>&1; then
            connectivity=true
            break
        fi
    done
    
    if [[ "$connectivity" == "false" ]]; then
        die "No network connectivity detected. Please check your internet connection."
    fi
    
    log_debug "Network connectivity check passed"
}

# Check available disk space (in MB)
check_disk_space() {
    local required_mb="${1:-2048}"  # Default 2GB
    local available_mb
    
    # Use df -k for portability across all systems
    # df -k reports in 1K blocks, so divide by 1024 for MB
    local available_kb
    available_kb=$(df -k "$HOME" 2>/dev/null | tail -1 | awk '{print $4}')
    
    if [[ -z "$available_kb" ]] || ! [[ "$available_kb" =~ ^[0-9]+$ ]]; then
        log_warn "Could not determine available disk space, continuing anyway"
        return 0
    fi
    
    available_mb=$((available_kb / 1024))
    
    if (( available_mb < required_mb )); then
        die "Insufficient disk space. Required: ${required_mb}MB, Available: ${available_mb}MB"
    fi
    
    log_debug "Disk space check passed: ${available_mb}MB available"
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

log_info() {
    log "INFO: $*"
}

log_warn() {
    log "WARN: $*"
}

log_error() {
    log "ERROR: $*"
}

log_debug() {
    if [[ "$FLAG_VERBOSE" == "true" ]]; then
        log "DEBUG: $*"
    fi
}

die() {
    log_error "$*"
    exit 1
}

# Enable debug output if verbose flag is set
if [[ "$FLAG_VERBOSE" == "true" ]]; then
    set -x
fi

# Check if running on WSL
is_wsl() {
    [[ -n "${WSL_DISTRO_NAME:-}" ]] || [[ -n "${WSLENV:-}" ]] || ([[ -f /proc/version ]] && grep -qi microsoft /proc/version 2>/dev/null)
}

# Version comparison function (returns 0 if v1 >= v2)
# Pure bash implementation to avoid sort -V dependency
version_gte() {
    local v1="$1"
    local v2="$2"
    
    # Strip v prefix and any non-numeric suffixes
    v1="${v1#v}"
    v2="${v2#v}"
    v1="${v1%%[^0-9.]*}"
    v2="${v2%%[^0-9.]*}"
    
    # Split versions into arrays
    local IFS='.'
    local v1_parts=($v1)
    local v2_parts=($v2)
    
    # Compare each part
    local i
    for ((i = 0; i < ${#v1_parts[@]} || i < ${#v2_parts[@]}; i++)); do
        local part1="${v1_parts[i]:-0}"
        local part2="${v2_parts[i]:-0}"
        
        # Remove leading zeros for numeric comparison
        part1=$((10#$part1))
        part2=$((10#$part2))
        
        if ((part1 > part2)); then
            return 0
        elif ((part1 < part2)); then
            return 1
        fi
    done
    
    return 0
}

# Prompt user for confirmation
confirm() {
    local prompt="$1"
    if [[ "$FLAG_YES" == "true" ]]; then
        log_info "Auto-confirming: $prompt"
        return 0
    fi
    
    # Check if stdin is available
    if [[ ! -t 0 ]]; then
        log_error "Cannot read user input (stdin not available). Use --yes flag for non-interactive mode."
        return 1
    fi
    
    echo -n "$prompt [y/N] "
    read -r response
    case "$response" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# =============================================================================
# OS Detection and Package Manager Setup
# =============================================================================

detect_os() {
    log_debug "Detecting operating system..."
    
    case "$(uname -s)" in
        Darwin)
            OS_TYPE="macos"
            if [[ "$FLAG_NO_BREW" == "true" ]]; then
                if ! command -v brew >/dev/null 2>&1; then
                    die "Homebrew not found and --no-brew specified. Please install Homebrew or remove --no-brew flag."
                fi
            fi
            PACKAGE_MANAGER="brew"
            ;;
        Linux)
            if is_wsl; then
                log_info "Windows Subsystem for Linux detected"
            fi
            
            OS_TYPE="linux"
            detect_linux_package_manager
            ;;
        CYGWIN*|MINGW*|MSYS*)
            die "Native Windows is not supported. Please use WSL (Windows Subsystem for Linux)."
            ;;
        *)
            die "Unsupported operating system: $(uname -s)"
            ;;
    esac
    
    log_info "Detected OS: $OS_TYPE (package manager: $PACKAGE_MANAGER)"
}

detect_linux_package_manager() {
    log_debug "Detecting Linux package manager..."
    
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        
        case "$ID" in
            ubuntu|debian|pop|elementary)
                PACKAGE_MANAGER="apt"
                ;;
            fedora|centos|rhel|rocky|almalinux)
                PACKAGE_MANAGER="dnf"
                ;;
            arch|manjaro|endeavouros)
                PACKAGE_MANAGER="pacman"
                ;;
            opensuse*|sles)
                PACKAGE_MANAGER="zypper"
                ;;
            *)
                log_warn "Unknown Linux distribution: $ID. Attempting to detect package manager..."
                ;;
        esac
    fi
    
    # Fallback detection
    if [[ -z "$PACKAGE_MANAGER" ]]; then
        if command -v apt >/dev/null 2>&1; then
            PACKAGE_MANAGER="apt"
        elif command -v dnf >/dev/null 2>&1; then
            PACKAGE_MANAGER="dnf"
        elif command -v pacman >/dev/null 2>&1; then
            PACKAGE_MANAGER="pacman"
        elif command -v zypper >/dev/null 2>&1; then
            PACKAGE_MANAGER="zypper"
        else
            die "Could not detect package manager. Supported: apt, dnf, pacman, zypper"
        fi
    fi
}

# =============================================================================
# Shell Profile Management
# =============================================================================

detect_shell_profile() {
    log_debug "Detecting shell profile..."
    
    # Determine the user's login shell
    local login_shell
    login_shell=$(basename "${SHELL:-/bin/bash}")
    
    # Choose profile file based on shell and OS
    case "$login_shell" in
        zsh)
            PROFILE_FILE="$HOME/.zshrc"
            ;;
        bash)
            # macOS uses .bash_profile for login shells
            # Linux typically uses .bashrc
            if [[ "$OS_TYPE" == "macos" ]]; then
                PROFILE_FILE="$HOME/.bash_profile"
            else
                # On Linux, prefer .bashrc
                PROFILE_FILE="$HOME/.bashrc"
            fi
            ;;
        *)
            die "Unsupported shell: $login_shell. This script only supports bash and zsh."
            ;;
    esac
    
    # Create profile file if it doesn't exist
    if [[ ! -f "$PROFILE_FILE" ]]; then
        log_info "Creating shell profile: $PROFILE_FILE"
        touch "$PROFILE_FILE"
    fi
    
    log_info "Using shell profile: $PROFILE_FILE"
}

# Update PATH in shell profile with managed block
update_path_in_profile() {
    local new_paths="$1"
    
    if [[ -z "$new_paths" ]]; then
        log_debug "No new paths to add to profile"
        return 0
    fi
    
    # Create profile file if it doesn't exist
    if [[ ! -f "$PROFILE_FILE" ]]; then
        log_info "Creating shell profile: $PROFILE_FILE"
        touch "$PROFILE_FILE"
    fi
    
    # Markers for managed block
    local start_marker="# BEGIN Pinto Tools PATH - Managed by initialize-tools.sh"
    local end_marker="# END Pinto Tools PATH - Managed by initialize-tools.sh"
    
    # Remove existing managed block
    if grep -q "$start_marker" "$PROFILE_FILE" 2>/dev/null; then
        log_debug "Removing existing managed PATH block"
        # Use a temp file for cross-platform compatibility
        local temp_file
        temp_file=$(mktemp)
        TEMP_FILES+=("$temp_file")
        
        # Create backup
        local backup_file="${PROFILE_FILE}.backup.$(date +%s)"
        cp "$PROFILE_FILE" "$backup_file" || die "Failed to create backup of $PROFILE_FILE"
        
        # Remove the managed block
        if ! awk "/$start_marker/,/$end_marker/ { next } { print }" "$PROFILE_FILE" > "$temp_file"; then
            die "Failed to process $PROFILE_FILE"
        fi
        
        # Only move if awk succeeded and file is not empty
        if [[ -s "$temp_file" ]] || [[ ! -s "$PROFILE_FILE" ]]; then
            mv "$temp_file" "$PROFILE_FILE" || die "Failed to update $PROFILE_FILE"
        else
            log_warn "Processed file is empty, keeping original"
            rm -f "$temp_file"
        fi
    fi
    
    # Add new managed block
    log_info "Adding managed PATH block to $PROFILE_FILE"
    cat >> "$PROFILE_FILE" << EOF

$start_marker
# Auto-generated PATH exports for development tools
$new_paths
$end_marker
EOF
    
    NEEDS_SHELL_RELOAD=true
}

# =============================================================================
# Package Manager Operations
# =============================================================================

ensure_package_manager_ready() {
    log_debug "Ensuring package manager is ready..."
    
    case "$PACKAGE_MANAGER" in
        brew)
            if ! command -v brew >/dev/null 2>&1; then
                if [[ "$FLAG_NO_BREW" == "true" ]]; then
                    die "Homebrew not found and --no-brew specified"
                fi
                install_homebrew
            else
                # Ensure brew is in PATH for current session
                setup_homebrew_path
            fi
            ;;
        apt)
            if ! command -v curl >/dev/null 2>&1; then
                log_info "Installing curl via apt..."
                run_package_manager_command "update"
                run_package_manager_command "install" "curl"
            fi
            ;;
        dnf)
            if ! command -v curl >/dev/null 2>&1; then
                log_info "Installing curl via dnf..."
                run_package_manager_command "install" "curl"
            fi
            ;;
        pacman)
            if ! command -v curl >/dev/null 2>&1; then
                log_info "Installing curl via pacman..."
                run_package_manager_command "refresh"
                run_package_manager_command "install" "curl"
            fi
            ;;
        zypper)
            if ! command -v curl >/dev/null 2>&1; then
                log_info "Installing curl via zypper..."
                run_package_manager_command "refresh"
                run_package_manager_command "install" "curl"
            fi
            ;;
    esac
}

install_homebrew() {
    log_info "Installing Homebrew..."
    if [[ "$FLAG_DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would install Homebrew"
        return 0
    fi
    
    # Download script to temp file first
    local temp_script
    temp_script=$(mktemp)
    TEMP_FILES+=("$temp_script")
    
    log_debug "Downloading Homebrew install script..."
    if ! curl -fsSL --connect-timeout 30 --max-time 300 \
        "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh" \
        -o "$temp_script"; then
        die "Failed to download Homebrew install script"
    fi
    
    # Verify script is not empty
    if [[ ! -s "$temp_script" ]]; then
        die "Downloaded Homebrew script is empty"
    fi
    
    # Run the install script
    if ! /bin/bash "$temp_script"; then
        die "Homebrew installation failed"
    fi
    
    # Set up Homebrew in current session
    setup_homebrew_path
}

# Setup Homebrew PATH for current session
setup_homebrew_path() {
    local brew_prefix=""
    
    # Find brew installation
    if [[ -x "/opt/homebrew/bin/brew" ]]; then
        # Apple Silicon
        brew_prefix="/opt/homebrew"
    elif [[ -x "/usr/local/bin/brew" ]]; then
        # Intel Mac
        brew_prefix="/usr/local"
    elif command -v brew >/dev/null 2>&1; then
        # Already in PATH
        brew_prefix=$(brew --prefix 2>/dev/null || echo "")
    fi
    
    if [[ -n "$brew_prefix" ]] && [[ -x "$brew_prefix/bin/brew" ]]; then
        log_debug "Setting up Homebrew environment from $brew_prefix"
        eval "\$($brew_prefix/bin/brew shellenv)"
        
        # Also update PATH in profile if needed
        local brew_path_export="eval \"\\\$(${brew_prefix}/bin/brew shellenv)\""
        if ! grep -q "$brew_prefix/bin/brew shellenv" "$PROFILE_FILE" 2>/dev/null; then
            update_path_in_profile "$brew_path_export"
        fi
    else
        log_warn "Could not find Homebrew installation"
    fi
}

run_package_manager_command() {
    local action="$1"
    local packages="${2:-}"
    
    if [[ "$FLAG_DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would run: $PACKAGE_MANAGER $action $packages"
        return 0
    fi
    
    # Check for sudo if needed
    if [[ "$PACKAGE_MANAGER" != "brew" ]] && [[ "$action" == "install" ]]; then
        if ! command -v sudo >/dev/null 2>&1; then
            die "sudo is required for package installation but not found"
        fi
    fi
    
    case "$PACKAGE_MANAGER" in
        brew)
            case "$action" in
                install) 
                    # Split packages intentionally - package names must not contain spaces
                    # shellcheck disable=SC2086
                    brew install $packages 
                    ;;
                update) brew update ;;
                *) die "Unknown brew action: $action" ;;
            esac
            ;;
        apt)
            case "$action" in
                install) 
                    # Split packages intentionally - package names must not contain spaces
                    # shellcheck disable=SC2086
                    sudo apt-get install -y $packages 
                    ;;
                update) sudo apt-get update ;;
                *) die "Unknown apt action: $action" ;;
            esac
            ;;
        dnf)
            case "$action" in
                install) 
                    # Split packages intentionally - package names must not contain spaces
                    # shellcheck disable=SC2086
                    sudo dnf install -y $packages 
                    ;;
                update) sudo dnf update -y ;;
                *) die "Unknown dnf action: $action" ;;
            esac
            ;;
        pacman)
            case "$action" in
                install) 
                    # Split packages intentionally - package names must not contain spaces
                    # shellcheck disable=SC2086
                    sudo pacman -S --noconfirm $packages 
                    ;;
                refresh) sudo pacman -Sy ;;
                *) die "Unknown pacman action: $action" ;;
            esac
            ;;
        zypper)
            case "$action" in
                install) 
                    # Split packages intentionally - package names must not contain spaces
                    # shellcheck disable=SC2086
                    sudo zypper install -y $packages 
                    ;;
                refresh) sudo zypper refresh ;;
                *) die "Unknown zypper action: $action" ;;
            esac
            ;;
        *)
            die "Unknown package manager: $PACKAGE_MANAGER"
            ;;
    esac
}

# =============================================================================
# Tool Installation Functions
# =============================================================================

install_nodejs() {
    log_info "Installing Node.js..."
    
    local new_path_exports=""
    
    # Check if nvm is already available
    if command -v nvm >/dev/null 2>&1 || [[ -s "$HOME/.nvm/nvm.sh" ]]; then
        log_info "nvm detected, using it to install Node.js"
        install_nodejs_via_nvm
        new_path_exports='export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"'
    else
        case "$OS_TYPE" in
            macos)
                if [[ "$PACKAGE_MANAGER" == "brew" ]]; then
                    log_info "Installing Node.js via Homebrew..."
                    if [[ "$FLAG_DRY_RUN" == "false" ]]; then
                        run_package_manager_command "install" "node@20"
                        # Ensure corepack is enabled if available
                        if command -v corepack >/dev/null 2>&1; then
                            log_debug "Enabling corepack..."
                            corepack enable || log_warn "Failed to enable corepack"
                        fi
                    fi
                else
                    install_nvm_and_node
                    new_path_exports='export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"'
                fi
                ;;
            linux)
                # On Linux, prefer nvm for better version management
                install_nvm_and_node
                new_path_exports='export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"'
                ;;
        esac
    fi
    
    # Update PATH if we installed nvm
    if [[ -n "$new_path_exports" ]]; then
        update_path_in_profile "$new_path_exports"
    fi
}

install_nvm_and_node() {
    log_info "Installing nvm and Node.js..."
    
    if [[ "$FLAG_DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would install nvm and Node.js $NODE_MIN"
        return 0
    fi
    
    # Download nvm install script
    local nvm_version="v0.39.7"
    local temp_script
    temp_script=$(mktemp)
    TEMP_FILES+=("$temp_script")
    
    log_debug "Downloading nvm install script..."
    if ! curl -fsSL --connect-timeout 30 --max-time 300 \
        "https://raw.githubusercontent.com/nvm-sh/nvm/$nvm_version/install.sh" \
        -o "$temp_script"; then
        die "Failed to download nvm install script"
    fi
    
    # Verify script is not empty
    if [[ ! -s "$temp_script" ]]; then
        die "Downloaded nvm script is empty"
    fi
    
    # Run the install script
    if ! bash "$temp_script"; then
        die "nvm installation failed"
    fi
    
    # Source nvm for current session
    export NVM_DIR="$HOME/.nvm"
    if [[ -f "$NVM_DIR/nvm.sh" ]]; then
        # shellcheck source=/dev/null
        source "$NVM_DIR/nvm.sh"
    else
        log_warn "nvm.sh not found immediately after installation, continuing anyway"
    fi
    
    # Install and use Node.js
    local node_version="20"
    nvm install "$node_version"
    nvm alias default "$node_version"
    nvm use default
    
    # Enable corepack for yarn if available
    if command -v corepack >/dev/null 2>&1; then
        corepack enable || log_warn "Failed to enable corepack"
    else
        log_debug "corepack not available, skipping"
    fi
}

install_nodejs_via_nvm() {
    if [[ "$FLAG_DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would install Node.js via nvm"
        return 0
    fi
    
    # Source nvm if not already loaded
    export NVM_DIR="$HOME/.nvm"
    if [[ -f "$NVM_DIR/nvm.sh" ]]; then
        # shellcheck source=/dev/null
        source "$NVM_DIR/nvm.sh"
    else
        log_warn "nvm.sh not found, installation may have failed"
        return 1
    fi
    
    local node_version="20"
    nvm install "$node_version"
    nvm alias default "$node_version"
    nvm use default
    
    # Enable corepack for yarn if available
    if command -v corepack >/dev/null 2>&1; then
        corepack enable || log_warn "Failed to enable corepack"
    else
        log_debug "corepack not available, skipping"
    fi
}

install_rust() {
    log_info "Installing Rust..."
    
    if [[ "$FLAG_DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would install Rust stable via rustup"
        return 0
    fi
    
    # Download rustup install script
    local temp_script
    temp_script=$(mktemp)
    TEMP_FILES+=("$temp_script")
    
    log_debug "Downloading rustup install script..."
    if ! curl --proto '=https' --tlsv1.2 -sSf --connect-timeout 30 --max-time 300 \
        "https://sh.rustup.rs" -o "$temp_script"; then
        die "Failed to download rustup install script"
    fi
    
    # Verify script is not empty
    if [[ ! -s "$temp_script" ]]; then
        die "Downloaded rustup script is empty"
    fi
    
    # Run the install script
    if ! sh "$temp_script" -y --default-toolchain stable; then
        die "rustup installation failed"
    fi
    
    # Source cargo env for current session if it exists
    if [[ -f "$HOME/.cargo/env" ]]; then
        # shellcheck source=/dev/null
        source "$HOME/.cargo/env"
    fi
    
    # Update PATH
    update_path_in_profile 'export PATH="$HOME/.cargo/bin:$PATH"'
}

install_foundry() {
    log_info "Installing Foundry..."
    
    if [[ "$FLAG_DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would install Foundry ($FOUNDRY_CHANNEL channel)"
        return 0
    fi
    
    # Download foundry install script
    local temp_script
    temp_script=$(mktemp)
    TEMP_FILES+=("$temp_script")
    
    log_debug "Downloading foundry install script..."
    if ! curl -L --connect-timeout 30 --max-time 300 \
        "https://foundry.paradigm.xyz" -o "$temp_script"; then
        die "Failed to download foundry install script"
    fi
    
    # Verify script is not empty
    if [[ ! -s "$temp_script" ]]; then
        die "Downloaded foundry script is empty"
    fi
    
    # Run the install script
    if ! bash "$temp_script"; then
        die "foundryup installation failed"
    fi
    
    # Source foundry env for current session
    export PATH="$HOME/.foundry/bin:$PATH"
    
    # Install foundry tools
    if command -v foundryup >/dev/null 2>&1; then
        foundryup --version "$FOUNDRY_CHANNEL" || die "Failed to install foundry tools"
    else
        die "foundryup not found after installation"
    fi
    
    # Update PATH
    update_path_in_profile 'export PATH="$HOME/.foundry/bin:$PATH"'
}


# =============================================================================
# Tool Detection and Inventory
# =============================================================================

get_tool_status() {
    local tool="$1"
    
    case "$tool" in
        node)
            if command -v node >/dev/null 2>&1; then
                local version
                version=$(node --version 2>/dev/null | sed 's/^v//')
                local manager="system"
                
                # Detect if using nvm
                if [[ -n "${NVM_DIR:-}" ]] && [[ "$(which node)" == *"$NVM_DIR"* ]]; then
                    manager="nvm"
                elif [[ "$(which node)" == *"/usr/local/bin"* ]] || [[ "$(which node)" == *"/opt/homebrew/bin"* ]]; then
                    manager="brew"
                fi
                
                if version_gte "$version" "$NODE_MIN"; then
                    echo "✓ $version ($manager)"
                else
                    echo "✗ $version ($manager) - needs >=$NODE_MIN"
                fi
            else
                echo "✗ Not installed"
            fi
            ;;
        rust)
            if command -v rustc >/dev/null 2>&1; then
                local version
                version=$(rustc --version 2>/dev/null | awk '{print $2}')
                local toolchain="unknown"
                if command -v rustup >/dev/null 2>&1; then
                    toolchain=$(rustup show active-toolchain 2>/dev/null | awk '{print $1}' || echo "unknown")
                fi
                echo "✓ $version ($toolchain)"
            else
                echo "✗ Not installed"
            fi
            ;;
        foundry)
            if command -v forge >/dev/null 2>&1 && command -v anvil >/dev/null 2>&1; then
                local version
                # Extract version using sed for portability
                version="unknown"
                if command -v forge >/dev/null 2>&1; then
                    local forge_output
                    forge_output=$(forge --version 2>/dev/null || echo "")
                    # Use sed for compatibility with older bash versions
                    version=$(echo "$forge_output" | sed -n 's/.*forge[[:space:]]\+\([0-9.]\+\).*/\1/p')
                    if [[ -z "$version" ]]; then
                        # Try alternate pattern
                        version=$(echo "$forge_output" | sed -n 's/.*Version:[[:space:]]*\([0-9.]\+\).*/\1/p')
                    fi
                    if [[ -z "$version" ]]; then
                        # Fallback to awk
                        version=$(echo "$forge_output" | head -n1 | awk '{print $2}' || echo "unknown")
                    fi
                fi
                echo "✓ $version"
            else
                echo "✗ Not installed"
            fi
            ;;
    esac
}

print_inventory() {
    echo
    echo "=== Current Tool Status ==="
    printf "%-12s %-50s\n" "Tool" "Status"
    printf "%-12s %-50s\n" "----" "------"
    printf "%-12s %-50s\n" "Node.js" "$(get_tool_status node)"
    printf "%-12s %-50s\n" "Rust" "$(get_tool_status rust)"
    printf "%-12s %-50s\n" "Foundry" "$(get_tool_status foundry)"
    echo
}

get_installation_plan() {
    local plan=()
    
    # Check Node.js
    if ! command -v node >/dev/null 2>&1; then
        plan+=("Install Node.js $NODE_MIN via nvm")
    else
        local version
        version=$(node --version 2>/dev/null | sed 's/^v//')
        if ! version_gte "$version" "$NODE_MIN"; then
            plan+=("Upgrade Node.js from $version to >=$NODE_MIN")
        fi
    fi
    
    # Check Rust
    if ! command -v rustc >/dev/null 2>&1; then
        plan+=("Install Rust stable via rustup")
    elif ! command -v rustup >/dev/null 2>&1; then
        plan+=("Install rustup for Rust toolchain management")
    fi
    
    # Check Foundry
    if ! command -v forge >/dev/null 2>&1 || ! command -v anvil >/dev/null 2>&1; then
        plan+=("Install Foundry ($FOUNDRY_CHANNEL channel)")
    fi
    
    
    # Handle empty array case for set -u
    if [[ ${#plan[@]:-0} -gt 0 ]]; then
        printf '%s\n' "${plan[@]}"
    fi
}

print_plan() {
    echo
    echo "=== Installation Plan ==="
    local plan
    plan=$(get_installation_plan)
    
    if [[ -z "$plan" ]]; then
        echo "✓ All tools are already installed and up to date!"
        return 0
    fi
    
    local i=1
    while IFS= read -r action; do
        echo "$i. $action"
        ((i++))
    done <<< "$plan"
    
    echo
    return 1
}

# =============================================================================
# Verification Functions
# =============================================================================

verify_installation() {
    log_info "Verifying installation..."
    
    local failed=false
    
    # Source the profile to get updated PATH
    if [[ "$NEEDS_SHELL_RELOAD" == "true" ]] && [[ -f "$PROFILE_FILE" ]]; then
        log_debug "Sourcing profile: $PROFILE_FILE"
        # Create a subshell to test sourcing
        if ! (source "$PROFILE_FILE" 2>/dev/null); then
            log_warn "Profile contains errors, attempting to source anyway"
        fi
        # shellcheck source=/dev/null
        source "$PROFILE_FILE" 2>/dev/null || true
        # Re-export critical paths manually as fallback (avoid duplicates)
        for dir in "$HOME/.cargo/bin" "$HOME/.foundry/bin"; do
            if [[ -d "$dir" ]] && [[ ":$PATH:" != *":$dir:"* ]]; then
                export PATH="$dir:$PATH"
            fi
        done
        if [[ -d "$HOME/.nvm" ]]; then
            export NVM_DIR="$HOME/.nvm"
            [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh" 2>/dev/null || true
        fi
    fi
    
    # Verify Node.js
    if ! command -v node >/dev/null 2>&1; then
        log_error "Node.js not found after installation"
        failed=true
    else
        local version
        version=$(node --version 2>/dev/null | sed 's/^v//')
        if ! version_gte "$version" "$NODE_MIN"; then
            log_error "Node.js version $version is below minimum $NODE_MIN"
            failed=true
        else
            log_info "✓ Node.js $version"
        fi
    fi
    
    # Verify npm/yarn
    if ! command -v npm >/dev/null 2>&1; then
        log_error "npm not found"
        failed=true
    else
        log_info "✓ npm $(npm --version)"
    fi
    
    # Verify Rust
    if ! command -v cargo >/dev/null 2>&1; then
        log_error "Rust/Cargo not found after installation"
        failed=true
    else
        log_info "✓ Rust $(rustc --version | awk '{print $2}')"
    fi
    
    # Verify Foundry
    if ! command -v forge >/dev/null 2>&1 || ! command -v anvil >/dev/null 2>&1; then
        log_error "Foundry tools not found after installation"
        failed=true
    else
        # Extract version using sed for portability
        local foundry_version="unknown"
        if command -v forge >/dev/null 2>&1; then
            local forge_output
            forge_output=$(forge --version 2>/dev/null || echo "")
            # Use sed instead of bash regex for compatibility
            foundry_version=$(echo "$forge_output" | sed -n 's/.*forge[[:space:]]\+\([0-9.]\+\).*/\1/p')
            if [[ -z "$foundry_version" ]]; then
                foundry_version="unknown"
            fi
        fi
        log_info "✓ Foundry $foundry_version"
    fi
    
    
    if [[ "$failed" == "true" ]]; then
        return 1
    fi
    
    return 0
}

print_final_summary() {
    echo
    echo "=== Installation Complete ==="
    echo
    echo "🐚 Shell profile updated: $PROFILE_FILE"
    echo
    echo "Next steps:"
    echo "1. Restart your terminal or run: source $PROFILE_FILE"
    echo "2. Install dependencies: yarn install"
    echo "3. Generate types: yarn generate"
    echo "4. Start development: yarn dev"
    echo
}

# =============================================================================
# CLI Argument Parsing
# =============================================================================

usage() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

Pinto Protocol Development Environment Setup Script v$SCRIPT_VERSION

This script installs and configures development tools required for Pinto Protocol:
- Node.js >= $DEFAULT_NODE_MIN (via nvm preferred)
- Rust stable (via rustup)
- Foundry (via foundryup)

OPTIONS:
    -y, --yes                Auto-confirm all prompts
    --dry-run               Show what would be done without making changes
    --channel=CHANNEL       Foundry channel: stable|nightly (default: $DEFAULT_FOUNDRY_CHANNEL)
    --node-min=VERSION      Minimum Node.js version (default: $DEFAULT_NODE_MIN)
    --no-brew               On macOS, don't auto-install Homebrew
    --no-verify             Skip provenance/attestation checks
    --skip-network-check    Skip network connectivity check (for offline environments)
    --force                 Overwrite existing directories/repositories
    --verbose               Enable debug output
    -h, --help              Show this help message

EXAMPLES:
    $SCRIPT_NAME                                # Interactive installation
    $SCRIPT_NAME --yes --dry-run               # Show plan without installing
    $SCRIPT_NAME --channel=nightly --verbose   # Use Foundry nightly with debug output

EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -y|--yes)
                FLAG_YES=true
                shift
                ;;
            --dry-run)
                FLAG_DRY_RUN=true
                shift
                ;;
            --channel=*)
                FOUNDRY_CHANNEL="${1#*=}"
                if [[ "$FOUNDRY_CHANNEL" != "stable" && "$FOUNDRY_CHANNEL" != "nightly" ]]; then
                    die "Invalid Foundry channel: $FOUNDRY_CHANNEL. Must be 'stable' or 'nightly'"
                fi
                shift
                ;;
            --node-min=*)
                NODE_MIN="${1#*=}"
                shift
                ;;
            --no-brew)
                FLAG_NO_BREW=true
                shift
                ;;
            --no-verify)
                FLAG_NO_VERIFY=true
                shift
                ;;
            --skip-network-check)
                FLAG_SKIP_NETWORK=true
                shift
                ;;
            --force)
                FLAG_FORCE=true
                shift
                ;;
            --verbose)
                FLAG_VERBOSE=true
                set -x
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown option: $1. Use --help for usage information."
                ;;
        esac
    done
}

# =============================================================================
# Main Function
# =============================================================================

main() {
    echo "Pinto Protocol Development Environment Setup v$SCRIPT_VERSION"
    echo "============================================================="
    
    # Parse command line arguments
    parse_args "$@"
    
    # Check for concurrent execution with atomic lock creation
    if ! (set -C; echo $$ > "$LOCK_FILE") 2>/dev/null; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "unknown")
        # Check if the process is still running
        if [[ "$lock_pid" != "unknown" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            die "Another instance of this script is already running (PID: $lock_pid). Please wait for it to complete."
        else
            # Stale lock file, force overwrite
            log_debug "Removing stale lock file"
            echo $$ > "$LOCK_FILE" || die "Failed to create lock file"
        fi
    fi
    
    # Check prerequisites early
    if [[ "$FLAG_DRY_RUN" == "false" ]]; then
        if [[ "$FLAG_SKIP_NETWORK" == "false" ]]; then
            check_network         # Ensure we have internet connectivity
        fi
        check_disk_space 2048 # Require at least 2GB
    fi
    
    # Detect operating system and package manager
    detect_os
    
    # Detect shell profile
    detect_shell_profile
    
    # Show current status
    print_inventory
    
    # Show installation plan
    if ! print_plan; then
        # Tools need to be installed
        if [[ "$FLAG_DRY_RUN" == "true" ]]; then
            log_info "Dry run mode - no changes will be made"
            exit 0
        fi
        
        if ! confirm "Proceed with installation?"; then
            log_info "Installation cancelled by user"
            exit 0
        fi
        
        # Ensure package manager and dependencies are ready
        ensure_package_manager_ready
        
        # Install tools based on what's needed
        local plan
        plan=$(get_installation_plan)
        
        while IFS= read -r action; do
            case "$action" in
                *"Node.js"*)
                    install_nodejs
                    ;;
                *"Rust"*)
                    install_rust
                    ;;
                *"Foundry"*)
                    install_foundry
                    ;;
            esac
        done <<< "$plan"
        
        # Verify everything was installed correctly
        if ! verify_installation; then
            die "Installation verification failed"
        fi
        
        # Print final summary
        print_final_summary
        
    else
        # All tools already installed
        log_info "All development tools are ready!"
        if [[ "$FLAG_DRY_RUN" == "true" ]]; then
            exit 0
        fi
    fi
    
    log_info "Setup complete! 🎉"
}

# =============================================================================
# Script Entry Point
# =============================================================================

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi