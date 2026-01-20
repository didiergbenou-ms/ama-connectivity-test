#!/bin/bash

# Azure Monitor Agent Quick Connectivity Test
# A simplified version for quick endpoint testing

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CONFIG_DIR="/etc/opt/microsoft/azuremonitoragent/config-cache/configchunks"

print_status() {
    local status=$1
    local message=$2
    case $status in
        "INFO") echo -e "${BLUE}[INFO]${NC} $message" ;;
        "SUCCESS") echo -e "${GREEN}[SUCCESS]${NC} $message" ;;
        "WARNING") echo -e "${YELLOW}[WARNING]${NC} $message" ;;
        "ERROR") echo -e "${RED}[ERROR]${NC} $message" ;;
    esac
}

# Quick test function
quick_test() {
    local endpoint=$1
    local name=$2
    
    printf "%-50s" "$name: "
    
    # Test DNS and basic connectivity
    if curl -s --max-time 10 -k "https://$endpoint" >/dev/null 2>&1 || \
       curl -s --max-time 10 -k "https://$endpoint/ping" >/dev/null 2>&1; then
        echo -e "${GREEN}PASS${NC}"
        return 0
    else
        echo -e "${RED}FAIL${NC}"
        return 1
    fi
}

# Extract workspace IDs from DCR configs
get_workspaces() {
    if [ ! -d "$CONFIG_DIR" ]; then
        print_status "ERROR" "DCR config directory not found: $CONFIG_DIR"
        exit 1
    fi
    
    find "$CONFIG_DIR" -type f -name "*.json" -exec jq -r '.channels[]?.endpoint // empty' {} \; 2>/dev/null | \
    grep "ods.opinsights.azure" | \
    sed 's|.*https://\([^.]*\)\.ods.*|\1|' | \
    sort -u
}

# Extract regions from DCR configs  
get_regions() {
    find "$CONFIG_DIR" -type f -name "*.json" -exec jq -r '.channels[]?.tokenEndpointUri // empty' {} \; 2>/dev/null | \
    sed -n 's|.*Location=\([^&]*\).*|\1|p' | \
    sort -u
}

main() {
    echo "Azure Monitor Agent - Quick Connectivity Test"
    echo "=============================================="
    
    # Check prerequisites
    if ! command -v jq >/dev/null 2>&1; then
        print_status "ERROR" "jq is required but not installed"
        exit 1
    fi
    
    if ! command -v curl >/dev/null 2>&1; then
        print_status "ERROR" "curl is required but not installed"  
        exit 1
    fi
    
    # Get configuration
    local workspaces=($(get_workspaces))
    local regions=($(get_regions))
    
    if [ ${#workspaces[@]} -eq 0 ]; then
        print_status "ERROR" "No Log Analytics workspaces found in DCR configurations"
        exit 1
    fi
    
    print_status "INFO" "Found ${#workspaces[@]} workspace(s), ${#regions[@]} region(s)"
    echo ""
    
    # Test endpoints
    local failed=0
    
    # Test global handler
    if ! quick_test "global.handler.control.monitor.azure.com" "Global Handler"; then
        failed=$((failed + 1))
    fi
    
    # Test regional handlers
    for region in "${regions[@]}"; do
        if ! quick_test "$region.handler.control.monitor.azure.com" "Regional Handler ($region)"; then
            failed=$((failed + 1))
        fi
    done
    
    # Test Log Analytics endpoints
    for workspace in "${workspaces[@]}"; do
        if ! quick_test "$workspace.ods.opinsights.azure.com" "Log Analytics ($workspace)"; then
            failed=$((failed + 1))
        fi
    done
    
    # Test management endpoint
    if ! quick_test "management.azure.com" "Management Endpoint"; then
        failed=$((failed + 1))
    fi
    
    echo ""
    if [ $failed -eq 0 ]; then
        print_status "SUCCESS" "All endpoints are reachable!"
    else
        print_status "ERROR" "$failed endpoint(s) failed connectivity test"
        echo ""
        print_status "INFO" "Run the full test script (test-ama-connectivity.sh) for detailed diagnostics"
    fi
}

main "$@"