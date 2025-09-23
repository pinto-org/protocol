#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# Pinto Protocol Development Environment Setup Script
# =============================================================================
# This script automatically installs and configures development tools required
# for the Pinto Protocol interface and backend development.
#
# Supported platforms: macOS (Intel/ARM), Linux (Ubuntu/Debian/Fedora/Arch/SUSE)
# Tools installed: Node.js, Rust, Foundry
#
# To make Executable: chmod +x scripts/misc/initialize-tools.sh
#
# Dry Run: ./scripts/misc/initialize-tools.sh --dry-run
# Usage: ./scripts/misc/initialize-tools.sh [OPTIONS]
# =============================================================================

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$SCRIPT_DIR/ui-tools"

# Verify module directory exists
if [[ ! -d "$MODULE_DIR" ]]; then
    echo "ERROR: Module directory not found: $MODULE_DIR" >&2
    exit 1
fi

# Source modules in order
for module in common platform tools ui; do
    module_path="$MODULE_DIR/${module}.sh"
    if [[ ! -f "$module_path" ]]; then
        echo "ERROR: Required module not found: $module_path" >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$module_path"
done

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
        
        # Only process if plan is not empty
        if [[ -n "$plan" ]]; then
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
        fi
        
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