#!/bin/bash

# Azure Monitor Agent Quick Connectivity Test
# A simplified version for quick endpoint testing

set -euo pipefail

# Parse command line arguments
VERBOSE=false
if [[ "${1:-}" == "--verbose" ]]; then
    VERBOSE=true
    shift
fi

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
    
    if [ "$VERBOSE" = "true" ]; then
        print_status "INFO" "Testing $name ($endpoint)"
        
        # DNS Test
        print_status "INFO" "DNS Resolution: nslookup $endpoint"
        if nslookup "$endpoint" 2>&1; then
            print_status "SUCCESS" "DNS resolution successful for $endpoint"
        else
            print_status "ERROR" "DNS resolution failed for $endpoint"
            return 1
        fi
        
        # SSL Test
        print_status "INFO" "SSL Test: openssl s_client -connect $endpoint:443 -brief"
        local ssl_output
        ssl_output=$(timeout 10 openssl s_client -connect "$endpoint:443" -brief 2>&1)
        local ssl_exit_code=$?
        
        echo "SSL Output:"
        echo "$ssl_output"
        echo ""
        
        if [ $ssl_exit_code -eq 0 ]; then
            print_status "SUCCESS" "SSL connection successful for $endpoint"
        else
            print_status "ERROR" "SSL connection failed for $endpoint (exit code: $ssl_exit_code)"
        fi
        
        # HTTP Test
        print_status "INFO" "HTTP Test: curl -v --max-time 10 -k https://$endpoint"
        if curl -v --max-time 10 -k "https://$endpoint" 2>&1; then
            print_status "SUCCESS" "HTTP connection successful for $endpoint"
            echo ""
            return 0
        else
            print_status "ERROR" "HTTP connection failed for $endpoint"
            echo ""
            return 1
        fi
    else
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
    if [ "$VERBOSE" = "true" ]; then
        print_status "INFO" "Verbose mode enabled - showing detailed command output"
    fi
    echo ""
    
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