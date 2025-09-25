#!/usr/bin/env bash
# =============================================================================
# Pinto Protocol Development Environment - Common Utilities
# =============================================================================

# Prevent double sourcing
[[ -n "${_PINTO_COMMON_LOADED:-}" ]] && return 0
_PINTO_COMMON_LOADED=1

# =============================================================================
# Configuration and Global Variables
# =============================================================================

# Script configuration
readonly SCRIPT_NAME="$(basename "${0:-$BASH_SOURCE}")"
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

# =============================================================================
# Cleanup Function
# =============================================================================

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
# Logging Functions
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

# Note: Debug output (set -x) is enabled in parse_args() when --verbose is passed

# =============================================================================
# Utility Functions
# =============================================================================

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

# =============================================================================
# System Check Functions
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