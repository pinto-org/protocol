#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# Pinto Protocol Development Environment Setup Script
# =============================================================================
# This script automatically installs and configures development tools required
# for the Pinto Protocol interface and backend development.
#
# Supported platforms: macOS (Intel/ARM), Linux (Ubuntu/Debian/Fedora/Arch/SUSE)
# Tools installed: Node.js, Rust, Foundry, Git, Pinto Protocol repo
#
# Usage: ./scripts/initialize-tools.sh [OPTIONS]
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
FOUNDRY_CHANNEL="$DEFAULT_FOUNDRY_CHANNEL"
NODE_MIN="$DEFAULT_NODE_MIN"

# Global state tracking
NEEDS_SHELL_RELOAD=false
PROFILE_FILE=""
OS_TYPE=""
PACKAGE_MANAGER=""

# =============================================================================
# Utility Functions
# =============================================================================

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
    [[ -n "${WSL_DISTRO_NAME:-}" ]] || [[ -n "${WSLENV:-}" ]] || [[ -f /proc/version ]] && grep -qi microsoft /proc/version 2>/dev/null
}

# Version comparison function (returns 0 if v1 >= v2)
version_gte() {
    local v1="$1"
    local v2="$2"
    
    # Handle the case where version might have extra characters
    v1=$(echo "$v1" | sed 's/^v//' | sed 's/[^0-9.].*//')
    v2=$(echo "$v2" | sed 's/^v//' | sed 's/[^0-9.].*//')
    
    printf '%s\n%s\n' "$v2" "$v1" | sort -V -C 2>/dev/null
}

# Prompt user for confirmation
confirm() {
    local prompt="$1"
    if [[ "$FLAG_YES" == "true" ]]; then
        log_info "Auto-confirming: $prompt"
        return 0
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
    
    # Choose profile file based on shell
    case "$login_shell" in
        zsh)
            PROFILE_FILE="$HOME/.zshrc"
            ;;
        bash)
            # Prefer .bashrc if it exists, otherwise .bash_profile
            if [[ -f "$HOME/.bashrc" ]]; then
                PROFILE_FILE="$HOME/.bashrc"
            else
                PROFILE_FILE="$HOME/.bash_profile"
            fi
            ;;
        *)
            die "Unsupported shell: $login_shell. This script only supports bash and zsh."
            ;;
    esac
    
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
        awk "/$start_marker/,/$end_marker/ { next } { print }" "$PROFILE_FILE" > "$temp_file"
        mv "$temp_file" "$PROFILE_FILE"
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
    
    local install_script
    install_script=$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)
    /bin/bash -c "$install_script"
    
    # Add Homebrew to PATH for current session
    if [[ -f "/opt/homebrew/bin/brew" ]]; then
        # Apple Silicon
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -f "/usr/local/bin/brew" ]]; then
        # Intel Mac
        eval "$(/usr/local/bin/brew shellenv)"
    fi
}

run_package_manager_command() {
    local action="$1"
    local packages="${2:-}"
    
    if [[ "$FLAG_DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would run: $PACKAGE_MANAGER $action $packages"
        return 0
    fi
    
    case "$PACKAGE_MANAGER" in
        brew)
            case "$action" in
                install) brew install $packages ;;
                update) brew update ;;
                *) die "Unknown brew action: $action" ;;
            esac
            ;;
        apt)
            case "$action" in
                install) sudo apt-get install -y $packages ;;
                update) sudo apt-get update ;;
                *) die "Unknown apt action: $action" ;;
            esac
            ;;
        dnf)
            case "$action" in
                install) sudo dnf install -y $packages ;;
                update) sudo dnf update -y ;;
                *) die "Unknown dnf action: $action" ;;
            esac
            ;;
        pacman)
            case "$action" in
                install) sudo pacman -S --noconfirm $packages ;;
                refresh) sudo pacman -Sy ;;
                *) die "Unknown pacman action: $action" ;;
            esac
            ;;
        zypper)
            case "$action" in
                install) sudo zypper install -y $packages ;;
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
                        # Ensure corepack is enabled
                        corepack enable 2>/dev/null || true
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
    
    # Install nvm
    local nvm_version="v0.39.7"
    curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/$nvm_version/install.sh" | bash
    
    # Source nvm for current session
    export NVM_DIR="$HOME/.nvm"
    # shellcheck source=/dev/null
    [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"
    
    # Install and use Node.js
    local node_version="20"
    nvm install "$node_version"
    nvm alias default "$node_version"
    nvm use default
    
    # Enable corepack for yarn
    corepack enable
}

install_nodejs_via_nvm() {
    if [[ "$FLAG_DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would install Node.js via nvm"
        return 0
    fi
    
    # Source nvm if not already loaded
    export NVM_DIR="$HOME/.nvm"
    # shellcheck source=/dev/null
    [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"
    
    local node_version="20"
    nvm install "$node_version"
    nvm alias default "$node_version"
    nvm use default
    
    # Enable corepack for yarn
    corepack enable
}

install_rust() {
    log_info "Installing Rust..."
    
    if [[ "$FLAG_DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would install Rust stable via rustup"
        return 0
    fi
    
    # Install rustup
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
    
    # Source cargo env for current session
    # shellcheck source=/dev/null
    source "$HOME/.cargo/env"
    
    # Update PATH
    update_path_in_profile 'export PATH="$HOME/.cargo/bin:$PATH"'
}

install_foundry() {
    log_info "Installing Foundry..."
    
    if [[ "$FLAG_DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would install Foundry ($FOUNDRY_CHANNEL channel)"
        return 0
    fi
    
    # Install foundryup
    curl -L https://foundry.paradigm.xyz | bash
    
    # Source foundry env for current session
    export PATH="$HOME/.foundry/bin:$PATH"
    
    # Install foundry tools
    foundryup --version "$FOUNDRY_CHANNEL"
    
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
                version=$(forge --version 2>/dev/null | head -n1 | awk '{print $2}' || echo "unknown")
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
    
    
    printf '%s\n' "${plan[@]}"
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
        # shellcheck source=/dev/null
        source "$PROFILE_FILE" 2>/dev/null || true
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
        log_info "✓ Foundry $(forge --version | head -n1 | awk '{print $2}')"
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
    echo "1. Install dependencies: yarn install"
    echo "2. Generate types: yarn generate"
    echo "3. Start development: yarn dev"
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