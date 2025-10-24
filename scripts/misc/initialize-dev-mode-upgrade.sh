#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# Pinto Protocol Local Development with Upgrades Script
# =============================================================================
# This script starts a local development environment with:
# 1. Anvil forked from Base mainnet
# 2. Latest protocol upgrade deployment
# 3. Hardhat server for development
#
# Usage: ./scripts/misc/initialize-dev-mode-upgrade.sh [RPC_URL] [FORK_BLOCK_NUMBER]
#   RPC_URL: Base mainnet RPC URL (defaults to BASE_RPC env var or https://base.llamarpc.com)
#   FORK_BLOCK_NUMBER: Block number to fork from (optional, uses latest if omitted)
#
# Examples:
#   ./scripts/misc/initialize-dev-mode-upgrade.sh
#   ./scripts/misc/initialize-dev-mode-upgrade.sh https://mainnet.base.org
#   ./scripts/misc/initialize-dev-mode-upgrade.sh https://mainnet.base.org 12345678
#
# To make executable: chmod +x scripts/misc/initialize-dev-mode-upgrade.sh
# =============================================================================

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Process management
ANVIL_PID=""
HARDHAT_PID=""
CLEANUP_DONE=false

# Configuration
readonly CHAIN_ID=1337
readonly ANVIL_PORT=8545
readonly MAX_WAIT_TIME=30
readonly SCRIPT_NAME="$(basename "$0")"
readonly DEFAULT_RPC="https://base.llamarpc.com"

# Command line parameters
RPC_URL="${1:-}"
FORK_BLOCK_NUMBER="${2:-}"

# =============================================================================
# Logging Functions
# =============================================================================

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1"
}

# =============================================================================
# Cleanup and Signal Handling
# =============================================================================

cleanup() {
    if [[ "$CLEANUP_DONE" == "true" ]]; then
        return 0
    fi
    CLEANUP_DONE=true

    log_info "Shutting down processes..."

    # Kill hardhat server
    if [[ -n "$HARDHAT_PID" ]] && kill -0 "$HARDHAT_PID" 2>/dev/null; then
        log_debug "Stopping hardhat-server (PID: $HARDHAT_PID)"
        kill -TERM "$HARDHAT_PID" 2>/dev/null || true
        sleep 2
        kill -KILL "$HARDHAT_PID" 2>/dev/null || true
    fi

    # Kill anvil
    if [[ -n "$ANVIL_PID" ]] && kill -0 "$ANVIL_PID" 2>/dev/null; then
        log_debug "Stopping anvil (PID: $ANVIL_PID)"
        kill -TERM "$ANVIL_PID" 2>/dev/null || true
        sleep 2
        kill -KILL "$ANVIL_PID" 2>/dev/null || true
    fi

    log_info "Cleanup completed"
}

# Set up signal handlers
trap cleanup EXIT INT TERM

# =============================================================================
# Validation Functions
# =============================================================================

check_prerequisites() {
    log_info "Checking prerequisites..."

    # Determine RPC URL to use
    if [[ -z "$RPC_URL" ]]; then
        if [[ -n "${BASE_RPC:-}" ]]; then
            RPC_URL="$BASE_RPC"
            log_debug "Using BASE_RPC environment variable: $RPC_URL"
        else
            RPC_URL="$DEFAULT_RPC"
            log_debug "Using default RPC: $RPC_URL"
        fi
    else
        log_debug "Using provided RPC: $RPC_URL"
    fi

    # Check if required commands exist
    local missing_commands=()

    if ! command -v anvil &> /dev/null; then
        missing_commands+=("anvil")
    fi

    if ! command -v npx &> /dev/null; then
        missing_commands+=("npx")
    fi

    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing_commands[*]}"
        log_error "Please install Foundry and Node.js"
        exit 1
    fi

    # Check if we're in the right directory
    if [[ ! -f "hardhat.config.js" ]]; then
        log_error "hardhat.config.js not found. Are you in the protocol root directory?"
        exit 1
    fi

    log_info "Prerequisites check passed ✅"
}

# =============================================================================
# Anvil Management
# =============================================================================

start_anvil() {
    log_info "Starting Anvil fork from Base mainnet..."
    log_debug "Using RPC: $RPC_URL"
    log_debug "Chain ID: $CHAIN_ID"
    log_debug "Port: $ANVIL_PORT"

    if [[ -n "$FORK_BLOCK_NUMBER" ]]; then
        log_debug "Fork block number: $FORK_BLOCK_NUMBER"
    else
        log_debug "Using latest block"
    fi

    # Build anvil command
    local anvil_cmd=("anvil" \
        "--fork-url" "$RPC_URL" \
        "--chain-id" "$CHAIN_ID" \
        "--disable-gas-limit" \
        "--port" "$ANVIL_PORT" \
        "--host" "0.0.0.0")

    # Add fork block number if provided
    if [[ -n "$FORK_BLOCK_NUMBER" ]]; then
        anvil_cmd+=("--fork-block-number" "$FORK_BLOCK_NUMBER")
    fi

    # Start anvil in background
    "${anvil_cmd[@]}" > /dev/null 2>&1 &

    ANVIL_PID=$!
    log_debug "Anvil started with PID: $ANVIL_PID"
}

wait_for_anvil() {
    log_info "Waiting for Anvil to be ready..."
    local elapsed=0

    while [[ $elapsed -lt $MAX_WAIT_TIME ]]; do
        if curl -s -X POST \
            -H "Content-Type: application/json" \
            --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
            "http://localhost:$ANVIL_PORT" > /dev/null 2>&1; then
            log_info "Anvil is ready! ✅"
            return 0
        fi

        # Check if anvil process is still running
        if ! kill -0 "$ANVIL_PID" 2>/dev/null; then
            log_error "Anvil process died unexpectedly"
            return 1
        fi

        sleep 1
        ((elapsed++))

        # Show progress every 5 seconds
        if [[ $((elapsed % 5)) -eq 0 ]]; then
            log_debug "Still waiting... (${elapsed}s/${MAX_WAIT_TIME}s)"
        fi
    done

    log_error "Anvil failed to start within $MAX_WAIT_TIME seconds"
    return 1
}

# =============================================================================
# Upgrade Deployment
# =============================================================================

run_upgrade() {
    log_info "Running latest upgrade on localhost network..."

    if ! npx hardhat runLatestUpgrade --network localhost; then
        log_error "Upgrade deployment failed"
        return 1
    fi

    log_info "Upgrade deployment completed ✅"
}

# =============================================================================
# Hardhat Server Management
# =============================================================================

start_hardhat_server() {
    log_info "Starting Hardhat server..."

    # Check if hardhat-server script exists
    if [[ -f "scripts/hardhat-server.js" ]]; then
        node scripts/hardhat-server.js > /dev/null 2>&1 &
        HARDHAT_PID=$!
        log_debug "Hardhat server started with PID: $HARDHAT_PID"
    elif command -v yarn &> /dev/null && grep -q '"hardhat-server"' package.json; then
        yarn hardhat-server > /dev/null 2>&1 &
        HARDHAT_PID=$!
        log_debug "Hardhat server started with PID: $HARDHAT_PID (via yarn)"
    else
        log_warn "Could not find hardhat-server script or yarn command"
        log_warn "Skipping hardhat server startup"
        return 0
    fi

    # Give it a moment to start
    sleep 2

    # Check if it's running
    if kill -0 "$HARDHAT_PID" 2>/dev/null; then
        log_info "Hardhat server is running ✅"
    else
        log_warn "Hardhat server may have failed to start"
        HARDHAT_PID=""
    fi
}

# =============================================================================
# Status Display
# =============================================================================

show_status() {
    log_info "Development environment status:"
    echo -e "  ${GREEN}•${NC} Anvil: Running on http://localhost:$ANVIL_PORT (PID: $ANVIL_PID)"
    echo -e "  ${GREEN}•${NC} Chain ID: $CHAIN_ID"
    echo -e "  ${GREEN}•${NC} Fork URL: $RPC_URL"
    if [[ -n "$FORK_BLOCK_NUMBER" ]]; then
        echo -e "  ${GREEN}•${NC} Fork Block: $FORK_BLOCK_NUMBER"
    else
        echo -e "  ${GREEN}•${NC} Fork Block: Latest"
    fi

    if [[ -n "$HARDHAT_PID" ]] && kill -0 "$HARDHAT_PID" 2>/dev/null; then
        echo -e "  ${GREEN}•${NC} Hardhat Server: Running (PID: $HARDHAT_PID)"
    fi

    echo ""
    echo -e "${BLUE}You can now:${NC}"
    echo "  • Deploy contracts to http://localhost:$ANVIL_PORT"
    echo "  • Run tests against the forked environment"
    echo "  • Use hardhat tasks with --network localhost"
    echo ""
    echo -e "${YELLOW}Press Ctrl+C to stop all processes${NC}"
}

# =============================================================================
# Main Function
# =============================================================================

main() {
    echo "🚀 Pinto Protocol Development Environment with Upgrades"
    echo "======================================================="

    # Validate environment
    check_prerequisites

    # Start anvil
    start_anvil

    # Wait for anvil to be ready
    if ! wait_for_anvil; then
        log_error "Failed to start Anvil"
        exit 1
    fi

    # Run upgrade
    if ! run_upgrade; then
        log_error "Failed to run upgrade"
        exit 1
    fi

    # Start hardhat server
    start_hardhat_server

    # Show status
    show_status

    # Keep the script running and monitor processes
    log_info "Environment is ready! Monitoring processes..."

    while true; do
        # Check if anvil is still running
        if ! kill -0 "$ANVIL_PID" 2>/dev/null; then
            log_error "Anvil process died"
            exit 1
        fi

        # Check hardhat server if it was started
        if [[ -n "$HARDHAT_PID" ]] && ! kill -0 "$HARDHAT_PID" 2>/dev/null; then
            log_warn "Hardhat server process died"
            HARDHAT_PID=""
        fi

        sleep 5
    done
}

# =============================================================================
# Script Entry Point
# =============================================================================

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
