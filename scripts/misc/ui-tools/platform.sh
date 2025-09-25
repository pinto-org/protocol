#!/usr/bin/env bash
# =============================================================================
# Pinto Protocol Development Environment - Platform Management
# =============================================================================

# Prevent double sourcing
[[ -n "${_PINTO_PLATFORM_LOADED:-}" ]] && return 0
_PINTO_PLATFORM_LOADED=1

# Ensure common.sh is loaded
[[ -z "${_PINTO_COMMON_LOADED:-}" ]] && die "platform.sh requires common.sh to be sourced first"

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
    
    # Ensure PROFILE_FILE is set
    if [[ -z "${PROFILE_FILE:-}" ]]; then
        die "PROFILE_FILE not set. Please run detect_shell_profile() first"
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
        if [[ -n "${PROFILE_FILE:-}" ]] && ! grep -q "$brew_prefix/bin/brew shellenv" "$PROFILE_FILE" 2>/dev/null; then
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