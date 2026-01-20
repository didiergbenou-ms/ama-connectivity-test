#!/bin/bash

# Azure Monitor Agent Connectivity Test Script
# This script tests connectivity to all Log Analytics workspaces and endpoints 
# configured for the Azure Monitor Agent by parsing DCR configurations and 
# mimicking the agent's communication patterns.

set -euo pipefail

# Parse command line arguments
VERBOSE=false
if [[ "${1:-}" == "--verbose" ]]; then
    VERBOSE=true
    shift
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration paths (from agent source code analysis)
CONFIG_DIR="/etc/opt/microsoft/azuremonitoragent/config-cache/configchunks"
PROXY_CONFIG_FILE="/etc/opt/microsoft/azuremonitoragent/proxy.conf"

# Global variables to collect endpoints and configuration
declare -a WORKSPACE_IDS=()
declare -a REGIONS=()
declare -a ME_REGIONS=()
declare -a DCE_ENDPOINTS=()
declare -A AGENT_SETTINGS=()

# URL suffix (default is .com, can be .us for Azure Gov or .cn for Azure China)
URL_SUFFIX=".com"

# Proxy settings
PROXY_ADDRESS=""
PROXY_USERNAME=""
PROXY_PASSWORD=""

# Test results tracking
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# Function to print colored output
print_status() {
    local status=$1
    local message=$2
    case $status in
        "INFO")
            echo -e "${BLUE}[INFO]${NC} $message"
            ;;
        "SUCCESS")
            echo -e "${GREEN}[SUCCESS]${NC} $message"
            ;;
        "WARNING")
            echo -e "${YELLOW}[WARNING]${NC} $message"
            ;;
        "ERROR")
            echo -e "${RED}[ERROR]${NC} $message"
            ;;
    esac
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check prerequisites
check_prerequisites() {
    print_status "INFO" "Checking prerequisites..."
    
    local missing_commands=()
    
    if ! command_exists curl; then
        missing_commands+=("curl")
    fi
    
    if ! command_exists openssl; then
        missing_commands+=("openssl")
    fi
    
    if ! command_exists jq; then
        missing_commands+=("jq")
    fi
    
    if ! command_exists nslookup; then
        missing_commands+=("nslookup")
    fi
    
    if [ ${#missing_commands[@]} -ne 0 ]; then
        print_status "ERROR" "Missing required commands: ${missing_commands[*]}"
        print_status "INFO" "Please install the missing commands and retry:"
        print_status "INFO" "  Ubuntu/Debian: sudo apt update && sudo apt install curl openssl jq dnsutils"
        print_status "INFO" "  RHEL/CentOS: sudo yum install curl openssl jq bind-utils"
        print_status "INFO" "  SLES: sudo zypper install curl openssl jq bind-utils"
        exit 1
    fi
    
    if [ ! -d "$CONFIG_DIR" ]; then
        print_status "ERROR" "Azure Monitor Agent configuration directory not found: $CONFIG_DIR"
        print_status "INFO" "Please ensure Azure Monitor Agent is installed and configured."
        exit 1
    fi
    
    print_status "SUCCESS" "All prerequisites met"
}

# Function to load proxy configuration
load_proxy_config() {
    print_status "INFO" "Checking for proxy configuration..."
    
    # Check environment variables first
    if [ -n "${https_proxy:-}" ] || [ -n "${HTTPS_PROXY:-}" ]; then
        PROXY_ADDRESS="${https_proxy:-${HTTPS_PROXY:-}}"
        print_status "INFO" "Found proxy in environment: $PROXY_ADDRESS"
    fi
    
    # Check if proxy config file exists (this is a common location)
    if [ -f "$PROXY_CONFIG_FILE" ]; then
        # Parse proxy configuration if it exists
        if [ -s "$PROXY_CONFIG_FILE" ]; then
            source "$PROXY_CONFIG_FILE" 2>/dev/null || true
        fi
    fi
    
    # Check agent settings for proxy configuration
    if [ -n "${AGENT_SETTINGS[MDSD_PROXY_ADDRESS]:-}" ]; then
        PROXY_ADDRESS="${AGENT_SETTINGS[MDSD_PROXY_ADDRESS]}"
        PROXY_USERNAME="${AGENT_SETTINGS[MDSD_PROXY_USERNAME]:-}"
        PROXY_PASSWORD="${AGENT_SETTINGS[MDSD_PROXY_PASSWORD]:-}"
        print_status "INFO" "Found proxy in agent settings: $PROXY_ADDRESS"
    fi
}

# Function to parse DCR configuration files
parse_dcr_configs() {
    print_status "INFO" "Parsing DCR configuration files from $CONFIG_DIR..."
    
    local config_count=0
    local workspace_set=()
    local region_set=()
    local me_region_set=()
    
    if [ ! "$(ls -A "$CONFIG_DIR" 2>/dev/null)" ]; then
        print_status "ERROR" "No DCR configuration files found in $CONFIG_DIR"
        exit 1
    fi
    
    for config_file in "$CONFIG_DIR"/*; do
        if [ ! -f "$config_file" ]; then
            continue
        fi
        
        print_status "INFO" "Processing config file: $(basename "$config_file")"
        
        if ! jq . "$config_file" >/dev/null 2>&1; then
            print_status "WARNING" "Skipping invalid JSON file: $(basename "$config_file")"
            continue
        fi
        
        config_count=$((config_count + 1))
        
        # Check if this is an AgentSettings DCR
        local kind=$(jq -r '.kind // empty' "$config_file")
        if [ "$kind" = "AgentSettings" ]; then
            print_status "INFO" "Processing AgentSettings DCR"
            
            # Parse agent settings
            local settings=$(jq -r '.settings // empty' "$config_file")
            if [ -n "$settings" ] && [ "$settings" != "null" ]; then
                # The settings field can be a JSON string or array
                if echo "$settings" | jq . >/dev/null 2>&1; then
                    # Parse settings array
                    while IFS=$'\t' read -r name value; do
                        if [ -n "$name" ] && [ "$name" != "null" ]; then
                            AGENT_SETTINGS["$name"]="$value"
                        fi
                    done < <(echo "$settings" | jq -r '.[] | [.name, .value] | @tsv')
                fi
            fi
            continue
        fi
        
        # Process data collection channels
        local channels=$(jq -r '.channels[]?' "$config_file" 2>/dev/null)
        if [ -z "$channels" ]; then
            print_status "INFO" "No channels found in $(basename "$config_file")"
            continue
        fi
        
        # Extract ODS (Log Analytics) endpoints
        while IFS=$'\t' read -r protocol endpoint token_endpoint; do
            if [ "$protocol" = "ods" ] && [ -n "$endpoint" ] && [ "$endpoint" != "null" ]; then
                # Extract workspace ID from endpoint
                local workspace_id=$(echo "$endpoint" | sed -n 's|.*https://\([^.]*\)\.ods\.opinsights\.azure.*|\1|p')
                if [ -n "$workspace_id" ]; then
                    if [[ ! " ${workspace_set[*]} " =~ " ${workspace_id} " ]]; then
                        workspace_set+=("$workspace_id")
                        print_status "INFO" "Found Log Analytics workspace: $workspace_id"
                    fi
                fi
                
                # Extract region from token endpoint
                if [ -n "$token_endpoint" ] && [ "$token_endpoint" != "null" ]; then
                    local region=$(echo "$token_endpoint" | sed -n 's|.*Location=\([^&]*\).*|\1|p')
                    if [ -n "$region" ]; then
                        if [[ ! " ${region_set[*]} " =~ " ${region} " ]]; then
                            region_set+=("$region")
                            print_status "INFO" "Found region: $region"
                        fi
                    fi
                fi
                
                # Check URL suffix for government/china clouds
                if [[ "$endpoint" == *".us"* ]]; then
                    URL_SUFFIX=".us"
                    print_status "INFO" "Detected Azure Government cloud (.us)"
                elif [[ "$endpoint" == *".cn"* ]]; then
                    URL_SUFFIX=".cn"
                    print_status "INFO" "Detected Azure China cloud (.cn)"
                fi
            elif [ "$protocol" = "me" ] && [ -n "$endpoint" ] && [ "$endpoint" != "null" ]; then
                # Extract ME (Metrics) region
                local me_region=$(echo "$endpoint" | sed -n 's|.*https://\([^.]*\)\.monitoring\.azure.*|\1|p')
                if [ -n "$me_region" ]; then
                    if [[ ! " ${me_region_set[*]} " =~ " ${me_region} " ]]; then
                        me_region_set+=("$me_region")
                        print_status "INFO" "Found metrics region: $me_region"
                    fi
                fi
            fi
        done < <(jq -r '.channels[]? | select(.protocol != null) | [.protocol, .endpoint, .tokenEndpointUri] | @tsv' "$config_file" 2>/dev/null)
    done
    
    # Convert sets to arrays
    WORKSPACE_IDS=("${workspace_set[@]}")
    REGIONS=("${region_set[@]}")
    ME_REGIONS=("${me_region_set[@]}")
    
    if [ ${#WORKSPACE_IDS[@]} -eq 0 ]; then
        print_status "ERROR" "No Log Analytics workspaces found in DCR configurations"
        exit 1
    fi
    
    print_status "SUCCESS" "Parsed $config_count DCR configuration files"
    print_status "INFO" "Found ${#WORKSPACE_IDS[@]} workspace(s), ${#REGIONS[@]} region(s), ${#ME_REGIONS[@]} metrics region(s)"
}

# Function to construct curl command with proxy support
build_curl_command() {
    local url=$1
    local cmd="curl -s -S -k --max-time 30"
    
    if [ -n "$PROXY_ADDRESS" ]; then
        cmd="$cmd -x $PROXY_ADDRESS"
        if [ -n "$PROXY_USERNAME" ] && [ -n "$PROXY_PASSWORD" ]; then
            cmd="$cmd -U $PROXY_USERNAME:$PROXY_PASSWORD"
        fi
    fi
    
    cmd="$cmd $url"
    echo "$cmd"
}

# Function to test DNS resolution
test_dns_resolution() {
    local endpoint=$1
    
    if [ "$VERBOSE" = "true" ]; then
        print_status "INFO" "Testing DNS resolution: nslookup $endpoint"
        if nslookup "$endpoint" 2>&1; then
            print_status "SUCCESS" "DNS resolution successful for $endpoint"
            return 0
        else
            print_status "ERROR" "DNS resolution failed for $endpoint"
            return 1
        fi
    else
        print_status "INFO" "Testing DNS resolution for $endpoint"
        if nslookup "$endpoint" >/dev/null 2>&1; then
            print_status "SUCCESS" "DNS resolution successful for $endpoint"
            return 0
        else
            print_status "ERROR" "DNS resolution failed for $endpoint"
            return 1
        fi
    fi
}

# Function to test SSL connection
test_ssl_connection() {
    local endpoint=$1
    
    if [ "$VERBOSE" = "true" ]; then
        print_status "INFO" "Testing SSL connection: openssl s_client -connect $endpoint:443 -brief"
    else
        print_status "INFO" "Testing SSL connection to $endpoint:443"
    fi
    
    local ssl_cmd="echo | openssl s_client -connect $endpoint:443 -brief"
    
    # Add proxy support if configured and no authenticated proxy
    if [ -n "$PROXY_ADDRESS" ] && [ -z "$PROXY_USERNAME" ]; then
        local proxy_host=$(echo "$PROXY_ADDRESS" | sed 's|http://||')
        ssl_cmd="echo | openssl s_client -connect $endpoint:443 -proxy $proxy_host -brief"
    fi
    
    local ssl_output
    if [ "$VERBOSE" = "true" ]; then
        if ssl_output=$($ssl_cmd 2>&1); then
            echo "SSL Output:"
            echo "$ssl_output"
            if echo "$ssl_output" | grep -q "CONNECTION ESTABLISHED"; then
                if echo "$ssl_output" | grep -q "Verification: OK"; then
                    print_status "SUCCESS" "SSL connection and verification successful for $endpoint"
                    return 0
                else
                    print_status "WARNING" "SSL connection established but verification failed for $endpoint"
                    return 0
                fi
            else
                print_status "ERROR" "SSL connection failed for $endpoint"
                return 1
            fi
        else
            print_status "ERROR" "SSL connection test failed for $endpoint: $ssl_output"
            return 1
        fi
    else
        if ssl_output=$($ssl_cmd 2>&1); then
            if echo "$ssl_output" | grep -q "CONNECTION ESTABLISHED"; then
                if echo "$ssl_output" | grep -q "Verification: OK"; then
                    print_status "SUCCESS" "SSL connection and verification successful for $endpoint"
                    return 0
                else
                    print_status "WARNING" "SSL connection established but verification failed for $endpoint"
                    return 0
                fi
            else
                print_status "ERROR" "SSL connection failed for $endpoint"
                print_status "ERROR" "SSL output: $ssl_output"
                return 1
            fi
        else
            print_status "ERROR" "SSL connection test failed for $endpoint: $ssl_output"
            return 1
        fi
    fi
}

# Function to test endpoint with ping
test_endpoint_ping() {
    local endpoint=$1
    local endpoint_type=$2
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    
    print_status "INFO" "Testing $endpoint_type endpoint: $endpoint"
    
    # Test DNS resolution first
    if ! test_dns_resolution "$endpoint"; then
        FAILED_TESTS=$((FAILED_TESTS + 1))
        return 1
    fi
    
    # Test SSL connection (skip for authenticated proxy as per agent logic)
    if [ -z "$PROXY_USERNAME" ]; then
        if ! test_ssl_connection "$endpoint"; then
            FAILED_TESTS=$((FAILED_TESTS + 1))
            return 1
        fi
    else
        print_status "INFO" "Skipping SSL test due to authenticated proxy"
    fi
    
    # Test HTTP ping for handler endpoints only
    if [[ "$endpoint" == *"handler.control.monitor"* ]]; then
        local ping_url="https://$endpoint/ping"
        local curl_cmd=$(build_curl_command "$ping_url")
        
        print_status "INFO" "Testing HTTP ping: $ping_url"
        
        local response
        if response=$(eval "$curl_cmd" 2>&1); then
            if [ "$response" = "Healthy" ]; then
                print_status "SUCCESS" "HTTP ping successful for $endpoint (Response: $response)"
                PASSED_TESTS=$((PASSED_TESTS + 1))
                return 0
            else
                print_status "WARNING" "HTTP ping returned unexpected response for $endpoint (Response: $response)"
                PASSED_TESTS=$((PASSED_TESTS + 1))
                return 0
            fi
        else
            print_status "ERROR" "HTTP ping failed for $endpoint: $response"
            FAILED_TESTS=$((FAILED_TESTS + 1))
            return 1
        fi
    else
        # For non-handler endpoints (Log Analytics, etc.), we can't test ping but we've tested connectivity
        print_status "SUCCESS" "Connectivity test passed for $endpoint"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        return 0
    fi
}

# Function to test IMDS endpoints
test_imds_endpoints() {
    print_status "INFO" "Testing Instance Metadata Service (IMDS) connectivity..."
    
    local imds_endpoint=""
    local token_endpoint=""
    local metadata_header="Metadata: true"
    
    # Detect environment
    if [ -f "/var/opt/azcmagent/localconfig.json" ] || command -v azcmagent >/dev/null 2>&1; then
        print_status "INFO" "Detected Azure Arc environment"
        imds_endpoint="http://127.0.0.1:40342/metadata/instance/compute?api-version=2020-06-01"
        token_endpoint="http://127.0.0.1:40342/metadata/identity/oauth2/token?api-version=2019-11-01&resource=https%3A%2F%2Fmanagement.azure.com%2F"
    else
        print_status "INFO" "Detected Azure VM environment" 
        imds_endpoint="http://169.254.169.254/metadata/instance/compute?api-version=2020-06-01"
        token_endpoint="http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fmanagement.azure.com%2F"
    fi
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    
    # Test metadata endpoint
    print_status "INFO" "Testing IMDS metadata endpoint: $imds_endpoint"
    
    local metadata_response
    if metadata_response=$(curl -s -H "$metadata_header" --noproxy "*" --max-time 10 "$imds_endpoint" 2>&1); then
        # Parse metadata response
        local location resource_id
        location=$(echo "$metadata_response" | jq -r '.location // empty' 2>/dev/null)
        resource_id=$(echo "$metadata_response" | jq -r '.resourceId // empty' 2>/dev/null)
        
        if [ -n "$location" ] && [ -n "$resource_id" ]; then
            print_status "SUCCESS" "IMDS metadata endpoint accessible"
            print_status "INFO" "VM Location: $location"
            print_status "INFO" "Resource ID: ${resource_id:0:50}..."
        else
            print_status "WARNING" "IMDS metadata responded but data incomplete"
        fi
        
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        print_status "ERROR" "IMDS metadata endpoint failed: $metadata_response"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        return 1
    fi
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    
    # Test MSI token endpoint (this will fail without proper permissions but shows reachability)
    print_status "INFO" "Testing MSI token endpoint accessibility (auth expected to fail)"
    
    local token_response
    if token_response=$(curl -s -H "$metadata_header" --noproxy "*" --max-time 10 "$token_endpoint" 2>&1); then
        # Parse token response - we expect this to work or give a specific auth error
        if echo "$token_response" | jq -e '.error // .access_token' >/dev/null 2>&1; then
            print_status "SUCCESS" "MSI token endpoint is accessible (auth response received)"
            
            # Check if we actually got a token (would mean managed identity is working)
            if echo "$token_response" | jq -e '.access_token' >/dev/null 2>&1; then
                print_status "SUCCESS" "Managed Identity token acquisition successful!"
            else
                print_status "INFO" "MSI endpoint reachable (no managed identity configured or insufficient permissions)"
            fi
        else
            print_status "WARNING" "MSI token endpoint returned unexpected response: $token_response"
        fi
        
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        print_status "ERROR" "MSI token endpoint failed: $token_response"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        return 1
    fi
    
    return 0
}

# Function to test Log Analytics ingestion endpoint
test_log_analytics_ingestion() {
    local workspace_id=$1
    local endpoint="$workspace_id.ods.opinsights.azure$URL_SUFFIX"
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    
    print_status "INFO" "Testing Log Analytics workspace: $workspace_id"
    print_status "INFO" "Simulating data ingestion to: $endpoint"
    
    # Test basic connectivity first
    if ! test_dns_resolution "$endpoint"; then
        FAILED_TESTS=$((FAILED_TESTS + 1))
        return 1
    fi
    
    if [ -z "$PROXY_USERNAME" ]; then
        if ! test_ssl_connection "$endpoint"; then
            FAILED_TESTS=$((FAILED_TESTS + 1))
            return 1
        fi
    fi
    
    # Create a test log entry (mimicking what the agent sends)
    local test_data='{"TimeGenerated":"'$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")'","Computer":"'$(hostname)'","TestMessage":"AMA Connectivity Test","Source":"ConnectivityTestScript"}'
    local data_type="AMAConnectivityTest_CL"
    
    # Build the ingestion URL (this is how the agent sends data)
    local ingest_url="https://$endpoint/api/logs?api-version=2016-04-01"
    
    # Note: We can't actually send data without proper authentication (workspace key or token)
    # But we can test if the endpoint is reachable and returns the expected authentication error
    local curl_cmd=$(build_curl_command "$ingest_url")
    curl_cmd="$curl_cmd -X POST -H 'Content-Type: application/json' -H 'Log-Type: $data_type' -d '$test_data'"
    
    print_status "INFO" "Testing ingestion endpoint accessibility (authentication expected to fail)"
    
    local response
    local http_code
    if response=$(eval "$curl_cmd -w '%{http_code}' -o /dev/null" 2>&1); then
        # Extract HTTP code (should be 401 or 403 for auth failure, which means endpoint is reachable)
        http_code=$(echo "$response" | tail -n1)
        
        case "$http_code" in
            "401"|"403")
                print_status "SUCCESS" "Log Analytics endpoint is reachable (HTTP $http_code - authentication required as expected)"
                PASSED_TESTS=$((PASSED_TESTS + 1))
                return 0
                ;;
            "200"|"204")
                print_status "SUCCESS" "Log Analytics endpoint is reachable and accepting data (HTTP $http_code)"
                PASSED_TESTS=$((PASSED_TESTS + 1))
                return 0
                ;;
            *)
                print_status "WARNING" "Log Analytics endpoint reachable but returned HTTP $http_code"
                PASSED_TESTS=$((PASSED_TESTS + 1))
                return 0
                ;;
        esac
    else
        print_status "ERROR" "Failed to reach Log Analytics ingestion endpoint: $response"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        return 1
    fi
}

# Function to run all connectivity tests
run_connectivity_tests() {
    print_status "INFO" "Starting connectivity tests..."
    
    # Test IMDS endpoints
    print_status "INFO" "Testing IMDS (Instance Metadata Service) connectivity..."
    test_imds_endpoints
    
    # Test global handler endpoint
    local global_endpoint="global.handler.control.monitor.azure$URL_SUFFIX"
    test_endpoint_ping "$global_endpoint" "Global Handler"
    
    # Test regional handler endpoints
    for region in "${REGIONS[@]}"; do
        local regional_endpoint="$region.handler.control.monitor.azure$URL_SUFFIX"
        test_endpoint_ping "$regional_endpoint" "Regional Handler ($region)"
    done
    
    # Test Log Analytics endpoints with ingestion simulation
    for workspace_id in "${WORKSPACE_IDS[@]}"; do
        test_log_analytics_ingestion "$workspace_id"
    done
    
    # Test metrics endpoints
    local management_endpoint="management.azure$URL_SUFFIX"
    test_endpoint_ping "$management_endpoint" "Management"
    
    for me_region in "${ME_REGIONS[@]}"; do
        local metrics_endpoint="$me_region.monitoring.azure$URL_SUFFIX"
        test_endpoint_ping "$metrics_endpoint" "Metrics ($me_region)"
    done
}

# Function to generate test report
generate_report() {
    echo ""
    print_status "INFO" "=== CONNECTIVITY TEST REPORT ==="
    echo ""
    
    print_status "INFO" "Configuration Summary:"
    echo "  - Log Analytics Workspaces: ${#WORKSPACE_IDS[@]} (${WORKSPACE_IDS[*]})"
    echo "  - Regions: ${#REGIONS[@]} (${REGIONS[*]})"
    echo "  - Metrics Regions: ${#ME_REGIONS[@]} (${ME_REGIONS[*]:-None})"
    echo "  - Cloud Environment: Azure$URL_SUFFIX"
    echo "  - Proxy: ${PROXY_ADDRESS:-None}"
    echo ""
    
    print_status "INFO" "Test Results:"
    echo "  - Total Tests: $TOTAL_TESTS"
    echo "  - Passed: $PASSED_TESTS"
    echo "  - Failed: $FAILED_TESTS"
    echo ""
    
    if [ $FAILED_TESTS -eq 0 ]; then
        print_status "SUCCESS" "All connectivity tests passed! Azure Monitor Agent should be able to send data successfully."
        echo ""
        print_status "INFO" "If the agent is still not sending data, consider checking:"
        echo "  - Agent service status: systemctl status azuremonitoragent"
        echo "  - Agent logs: journalctl -u azuremonitoragent -f"
        echo "  - DCR associations and configuration"
        echo "  - Firewall rules and network security groups"
        return 0
    else
        print_status "ERROR" "$FAILED_TESTS test(s) failed. The agent may have connectivity issues."
        echo ""
        print_status "INFO" "Troubleshooting suggestions:"
        echo "  - Check firewall rules for the failed endpoints"
        echo "  - Verify proxy configuration if using a proxy"
        echo "  - Check network security groups in Azure"
        echo "  - Verify DNS resolution for failed endpoints"
        echo "  - Check if the VM has internet connectivity"
        return 1
    fi
}

# Main execution
main() {
    print_status "INFO" "Azure Monitor Agent Connectivity Test Script"
    print_status "INFO" "This script tests connectivity to all Log Analytics workspaces configured for AMA"
    echo ""
    
    check_prerequisites
    parse_dcr_configs
    load_proxy_config
    run_connectivity_tests
    generate_report
}

# Script execution with error handling
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    set -euo pipefail
    trap 'print_status "ERROR" "Script failed on line $LINENO"' ERR
    main "$@"
fi