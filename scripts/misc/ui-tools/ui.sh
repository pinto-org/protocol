#!/usr/bin/env bash
# =============================================================================
# Pinto Protocol Development Environment - User Interface
# =============================================================================

# Prevent double sourcing
[[ -n "${_PINTO_UI_LOADED:-}" ]] && return 0
_PINTO_UI_LOADED=1

# Ensure dependencies are loaded
[[ -z "${_PINTO_COMMON_LOADED:-}" ]] && die "ui.sh requires common.sh to be sourced first"
[[ -z "${_PINTO_PLATFORM_LOADED:-}" ]] && die "ui.sh requires platform.sh to be sourced first"
[[ -z "${_PINTO_TOOLS_LOADED:-}" ]] && die "ui.sh requires tools.sh to be sourced first"

# =============================================================================
# User Interface Functions
# =============================================================================

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
# Status Display Functions
# =============================================================================

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
    # Ensure all flags have defaults (defensive programming for set -u)
    : "${FLAG_YES:=false}"
    : "${FLAG_DRY_RUN:=false}"
    : "${FLAG_NO_BREW:=false}"
    : "${FLAG_NO_VERIFY:=false}"
    : "${FLAG_VERBOSE:=false}"
    : "${FLAG_FORCE:=false}"
    : "${FLAG_SKIP_NETWORK:=false}"
    : "${FOUNDRY_CHANNEL:=$DEFAULT_FOUNDRY_CHANNEL}"
    : "${NODE_MIN:=$DEFAULT_NODE_MIN}"
    
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