#!/usr/bin/env bash
# =============================================================================
# Pinto Protocol Development Environment - Tool Installation Functions
# =============================================================================

# Prevent double sourcing
[[ -n "${_PINTO_TOOLS_LOADED:-}" ]] && return 0
_PINTO_TOOLS_LOADED=1

# Ensure dependencies are loaded
[[ -z "${_PINTO_COMMON_LOADED:-}" ]] && die "tools.sh requires common.sh to be sourced first"
[[ -z "${_PINTO_PLATFORM_LOADED:-}" ]] && die "tools.sh requires platform.sh to be sourced first"

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
# Tool Status Functions
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