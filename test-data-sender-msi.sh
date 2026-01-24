#!/bin/bash

# Azure Monitor Agent - Enhanced Data Sender with MSI Token Authentication
# This script replicates the actual AMA authentication flow using IMDS/MSI tokens
# Usage: ./test-data-sender-msi.sh [-t LOG_TYPE] [-d DATA] [-r RESOURCE] [--verbose]

set -euo pipefail

# Parse verbose flag first
VERBOSE=false
for arg in "$@"; do
    if [[ "$arg" == "--verbose" ]]; then
        VERBOSE=true
        break
    fi
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CONFIG_DIR="/etc/opt/microsoft/azuremonitoragent/config-cache/configchunks"

# IMDS endpoints
AZURE_IMDS_METADATA="http://169.254.169.254/metadata/instance/compute?api-version=2020-06-01"
AZURE_IMDS_TOKEN="http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01"
ARC_IMDS_METADATA="http://127.0.0.1:40342/metadata/instance/compute?api-version=2020-06-01"
ARC_IMDS_TOKEN="http://127.0.0.1:40342/metadata/identity/oauth2/token?api-version=2019-11-01"

# Default resource for Log Analytics token
DEFAULT_RESOURCE="https://api.loganalytics.io"

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

usage() {
    echo "Usage: $0 [-t LOG_TYPE] [-d DATA] [-r RESOURCE] [-w WORKSPACE_ID] [--verbose]"
    echo ""
    echo "Options:"
    echo "  -t LOG_TYPE      Custom log type name (default: AMAConnectivityTest_CL)"
    echo "  -d DATA          Custom JSON data (default: test message)"
    echo "  -r RESOURCE      OAuth resource URL (default: https://api.loganalytics.io)"
    echo "  -w WORKSPACE_ID  Specific workspace ID (auto-detected from DCR if not provided)"
    echo "  --verbose        Show detailed HTTP requests and responses"
    echo "  -h               Show this help message"
    echo ""
    echo "This script uses Managed Identity/MSI authentication just like the real AMA agent."
    echo "It will automatically detect if running on Azure VM or Azure Arc and use appropriate IMDS endpoints."
}

# Function to detect if we're on Azure Arc
is_arc_installed() {
    [ -f "/var/opt/azcmagent/localconfig.json" ] || command -v azcmagent >/dev/null 2>&1
}

# Function to get managed identity configuration from agent settings
get_managed_identity_config() {
    print_status "INFO" "Checking for managed identity configuration in DCR..."
    
    if [ ! -d "$CONFIG_DIR" ]; then
        return 1
    fi
    
    # Look for AgentSettings DCR with managed identity config
    local mi_config=""
    for config_file in "$CONFIG_DIR"/*; do
        if [ ! -f "$config_file" ]; then
            continue
        fi
        
        local kind=$(jq -r '.kind // empty' "$config_file" 2>/dev/null)
        if [ "$kind" = "AgentSettings" ]; then
            local settings=$(jq -r '.settings // empty' "$config_file" 2>/dev/null)
            if [ -n "$settings" ] && [ "$settings" != "null" ]; then
                # Parse managed identity settings
                mi_config=$(echo "$settings" | jq -r '.[] | select(.name == "MANAGED_IDENTITY") | .value' 2>/dev/null)
                if [ -n "$mi_config" ] && [ "$mi_config" != "null" ]; then
                    echo "$mi_config"
                    return 0
                fi
            fi
        fi
    done
    
    return 1
}

# Function to get access token from IMDS
get_access_token() {
    local resource=$1
    local managed_identity=${2:-}
    
    print_status "INFO" "Acquiring access token from IMDS..."
    
    local token_url=""
    local metadata_header="Metadata: true"
    
    if is_arc_installed; then
        print_status "INFO" "Detected Azure Arc environment"
        token_url="$ARC_IMDS_TOKEN"
        
        # For Arc, we need to do challenge-response authentication
        print_status "INFO" "Performing Arc challenge-response authentication..."
        
        # First, get the challenge token
        local challenge_response
        if [ "$VERBOSE" = "true" ]; then
            print_status "INFO" "Sending Arc challenge request: curl -s -D - -H \"$metadata_header\" \"$token_url&resource=...\""
            challenge_response=$(curl -s -D - -H "$metadata_header" \
                "$token_url&resource=$(printf '%s' "$resource" | jq -sRr @uri)" 2>&1)
            echo "Challenge Response:"
            echo "$challenge_response"
        else
            challenge_response=$(curl -s -D - -H "$metadata_header" \
                "$token_url&resource=$(printf '%s' "$resource" | jq -sRr @uri)" 2>/dev/null)
        fi
        
        local challenge_path=$(echo "$challenge_response" | grep -i "www-authenticate" | cut -d "=" -f 2 | tr -d '\r\n')
        
        if [ -z "$challenge_path" ] || [ ! -f "$challenge_path" ]; then
            print_status "ERROR" "Failed to get Arc challenge token path"
            return 1
        fi
        
        local challenge_token=$(cat "$challenge_path")
        
        # Now get the actual token with the challenge
        local token_response
        if [ "$VERBOSE" = "true" ]; then
            print_status "INFO" "Getting Arc token: curl -s -H \"$metadata_header\" -H \"Authorization: Basic $challenge_token\" \"$token_url&resource=...\""
            token_response=$(curl -s -H "$metadata_header" \
                -H "Authorization: Basic $challenge_token" \
                "$token_url&resource=$(printf '%s' "$resource" | jq -sRr @uri)" 2>&1)
            echo "Token Response:"
            echo "$token_response"
        else
            token_response=$(curl -s -H "$metadata_header" \
                -H "Authorization: Basic $challenge_token" \
                "$token_url&resource=$(printf '%s' "$resource" | jq -sRr @uri)" 2>/dev/null)
        fi
        
    else
        print_status "INFO" "Detected Azure VM environment"
        token_url="$AZURE_IMDS_TOKEN"
        
        # Build token request URL
        local full_url="$token_url&resource=$(printf '%s' "$resource" | jq -sRr @uri)"
        
        # Add managed identity parameters if specified
        if [ -n "$managed_identity" ]; then
            # Parse managed identity format: identifier_name#identifier_value
            local id_name=$(echo "$managed_identity" | cut -d'#' -f1)
            local id_value=$(echo "$managed_identity" | cut -d'#' -f2)
            
            case "$id_name" in
                "client_id")
                    full_url="${full_url}&client_id=${id_value}"
                    ;;
                "mi_res_id")
                    full_url="${full_url}&mi_res_id=${id_value}"
                    ;;
                "object_id")
                    full_url="${full_url}&object_id=${id_value}"
                    ;;
            esac
            
            print_status "INFO" "Using user-assigned managed identity: $id_name=$id_value"
        else
            print_status "INFO" "Using system-assigned managed identity"
        fi
        
        # Get token from IMDS
        local token_response
        if [ "$VERBOSE" = "true" ]; then
            print_status "INFO" "Getting Azure VM token: curl -s -H \"$metadata_header\" --noproxy \"*\" \"$full_url\""
            token_response=$(curl -s -H "$metadata_header" --noproxy "*" "$full_url" 2>&1)
            echo "Token Response:"
            echo "$token_response"
        else
            token_response=$(curl -s -H "$metadata_header" --noproxy "*" "$full_url" 2>/dev/null)
        fi
    fi
    
    # Parse token response
    local access_token
    access_token=$(echo "$token_response" | jq -r '.access_token // empty' 2>/dev/null)
    
    if [ "$VERBOSE" = "true" ]; then
        if [ -n "$access_token" ] && [ "$access_token" != "null" ]; then
            local token_preview="${access_token:0:20}..."
            print_status "SUCCESS" "Access token acquired: $token_preview"
            
            # Show token expiry if available
            local expires_on=$(echo "$token_response" | jq -r '.expires_on // empty' 2>/dev/null)
            if [ -n "$expires_on" ] && [ "$expires_on" != "null" ]; then
                local expires_date=$(date -d "@$expires_on" 2>/dev/null || echo "Invalid date")
                print_status "INFO" "Token expires: $expires_date"
            fi
        fi
    fi
    
    if [ -z "$access_token" ] || [ "$access_token" = "null" ]; then
        print_status "ERROR" "Failed to acquire access token"
        if [ "$VERBOSE" = "true" ]; then
            print_status "ERROR" "IMDS response: $token_response"
        fi
        return 1
    fi
    
    print_status "SUCCESS" "Successfully acquired access token"
    echo "$access_token"
    return 0
}

# Function to test IMDS connectivity  
test_imds_connectivity() {
    print_status "INFO" "Testing IMDS connectivity..."
    
    local metadata_url=""
    local metadata_header="Metadata: true"
    
    if is_arc_installed; then
        metadata_url="$ARC_IMDS_METADATA"
        print_status "INFO" "Testing Arc HIMDS endpoint: $metadata_url"
    else
        metadata_url="$AZURE_IMDS_METADATA"
        print_status "INFO" "Testing Azure IMDS endpoint: $metadata_url"
    fi
    
    local response
    if response=$(curl -s -H "$metadata_header" --noproxy "*" --max-time 10 "$metadata_url" 2>&1); then
        # Parse key metadata fields
        local location region resource_id
        location=$(echo "$response" | jq -r '.location // empty' 2>/dev/null)
        resource_id=$(echo "$response" | jq -r '.resourceId // empty' 2>/dev/null)
        
        if [ -n "$location" ] && [ -n "$resource_id" ]; then
            print_status "SUCCESS" "IMDS connectivity verified"
            print_status "INFO" "Location: $location"
            print_status "INFO" "Resource ID: $resource_id"
            return 0
        else
            print_status "WARNING" "IMDS responded but metadata incomplete: $response"
            return 0  # Still allow continuation
        fi
    else
        print_status "ERROR" "IMDS connectivity failed: $response"
        return 1
    fi
}

# Function to get workspaces from DCR config
get_workspaces_from_dcr() {
    if [ ! -d "$CONFIG_DIR" ]; then
        print_status "WARNING" "DCR config directory not found: $CONFIG_DIR"
        return 1
    fi
    
    print_status "INFO" "Extracting workspace information from DCR configurations..."
    
    local workspaces=()
    
    for config_file in "$CONFIG_DIR"/*; do
        if [ ! -f "$config_file" ]; then
            continue
        fi
        
        # Extract workspace IDs from ODS endpoints
        while IFS= read -r endpoint; do
            if [ -n "$endpoint" ] && [[ "$endpoint" == *".ods.opinsights.azure"* ]]; then
                local workspace_id=$(echo "$endpoint" | sed -n 's|.*https://\([^.]*\)\.ods.*|\1|p')
                if [ -n "$workspace_id" ]; then
                    workspaces+=("$workspace_id")
                fi
            fi
        done < <(jq -r '.channels[]? | select(.protocol == "ods") | .endpoint // empty' "$config_file" 2>/dev/null)
    done
    
    if [ ${#workspaces[@]} -eq 0 ]; then
        print_status "ERROR" "No workspaces found in DCR configurations"
        return 1
    fi
    
    print_status "SUCCESS" "Found ${#workspaces[@]} workspace(s): ${workspaces[*]}"
    echo "${workspaces[0]}"  # Return first workspace
    return 0
}

# Function to send data with MSI token authentication
send_data_with_msi_token() {
    local workspace_id=$1
    local log_type=$2
    local test_data=$3
    local resource=$4
    local managed_identity=${5:-}
    
    # Test IMDS connectivity first
    if ! test_imds_connectivity; then
        print_status "ERROR" "IMDS connectivity test failed. Cannot proceed with MSI authentication."
        return 1
    fi
    
    # Get access token
    local access_token
    if ! access_token=$(get_access_token "$resource" "$managed_identity"); then
        return 1
    fi
    
    local date_string=$(date -u +"%a, %d %b %Y %H:%M:%S GMT")
    local url="https://$workspace_id.ods.opinsights.azure.com/api/logs?api-version=2016-04-01"
    
    print_status "INFO" "Sending test data with MSI token authentication..."
    print_status "INFO" "Workspace: $workspace_id"
    print_status "INFO" "Log type: $log_type"
    print_status "INFO" "Auth method: Managed Identity (MSI) Token"
    
    local response
    local http_code
    
    if [ "$VERBOSE" = "true" ]; then
        print_status "INFO" "Sending HTTP POST: curl -X POST -H \"Content-Type: application/json\" -H \"Authorization: Bearer [TOKEN]\" -H \"Log-Type: $log_type\" \"$url\""
        print_status "INFO" "Request data: $test_data"
        
        response=$(curl -v -w "%{http_code}" \
            -X POST \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $access_token" \
            -H "Log-Type: $log_type" \
            -H "x-ms-date: $date_string" \
            -H "time-generated-field: TimeGenerated" \
            -d "$test_data" \
            "$url" 2>&1)
    else
        response=$(curl -s -w "%{http_code}" \
            -X POST \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $access_token" \
            -H "Log-Type: $log_type" \
            -H "x-ms-date: $date_string" \
            -H "time-generated-field: TimeGenerated" \
            -d "$test_data" \
            "$url" 2>&1)
    fi
    
    if [ $? -eq 0 ]; then
        
        http_code=$(echo "$response" | tail -c 4)
        response_body=$(echo "$response" | head -c -4)
        
        if [ "$VERBOSE" = "true" ]; then
            echo ""
            echo "HTTP Response Code: $http_code"
            echo "Response Body: $response_body"
            echo ""
        fi
        
        case "$http_code" in
            "200"|"202")
                print_status "SUCCESS" "Test data sent successfully (HTTP $http_code)"
                print_status "INFO" "Data should appear in Log Analytics within 5-10 minutes"
                print_status "INFO" "Query: $log_type | where TimeGenerated > ago(1h)"
                return 0
                ;;
            "401")
                print_status "ERROR" "Authentication failed (HTTP 401): Token may be invalid or expired"
                return 1
                ;;
            "403")
                print_status "ERROR" "Forbidden (HTTP 403): Check managed identity permissions"
                return 1
                ;;
            *)
                print_status "ERROR" "Unexpected response (HTTP $http_code): $response_body"
                return 1
                ;;
        esac
    else
        print_status "ERROR" "Failed to send request: $response"
        return 1
    fi
}

main() {
    local log_type="AMAConnectivityTest_CL"
    local custom_data=""
    local resource="$DEFAULT_RESOURCE"
    local workspace_id=""
    
    # Filter out --verbose flag before processing other arguments
    local filtered_args=()
    for arg in "$@"; do
        if [[ "$arg" != "--verbose" ]]; then
            filtered_args+=("$arg")
        fi
    done
    
    # Parse command line arguments (excluding --verbose which was handled earlier)
    set -- "${filtered_args[@]}"  # Set positional parameters to filtered args
    while getopts "t:d:r:w:h" opt; do
        case $opt in
            t) log_type="$OPTARG" ;;
            d) custom_data="$OPTARG" ;;
            r) resource="$OPTARG" ;;
            w) workspace_id="$OPTARG" ;;
            h) usage; exit 0 ;;
            \?) echo "Invalid option -${OPTARG:-unknown}" >&2; usage; exit 1 ;;
        esac
    done
    
    # Check prerequisites
    if ! command -v curl >/dev/null 2>&1; then
        print_status "ERROR" "curl is required but not installed"
        exit 1
    fi
    
    if ! command -v jq >/dev/null 2>&1; then
        print_status "ERROR" "jq is required but not installed"
        exit 1
    fi
    
    print_status "INFO" "Azure Monitor Agent - Enhanced Data Sender with MSI Authentication"
    print_status "INFO" "This script replicates the actual AMA authentication flow using IMDS/MSI tokens"
    echo ""
    
    # Auto-detect workspace if not provided
    if [ -z "$workspace_id" ]; then
        if ! workspace_id=$(get_workspaces_from_dcr); then
            print_status "ERROR" "Could not auto-detect workspace ID. Use -w parameter to specify manually."
            exit 1
        fi
    fi
    
    # Get managed identity configuration
    local managed_identity=""
    if managed_identity=$(get_managed_identity_config); then
        print_status "INFO" "Found managed identity configuration: $managed_identity"
    else
        print_status "INFO" "No specific managed identity configured, using system-assigned identity"
    fi
    
    # Prepare test data
    if [ -z "$custom_data" ]; then
        custom_data=$(cat <<EOF
[
    {
        "TimeGenerated": "$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")",
        "Computer": "$(hostname)",
        "TestMessage": "Azure Monitor Agent MSI authentication test",
        "Source": "AMA-MSI-ConnectivityTestScript",
        "AuthMethod": "ManagedIdentity",
        "Environment": "$(if is_arc_installed; then echo "AzureArc"; else echo "AzureVM"; fi)",
        "Severity": "Informational",
        "TestId": "$(uuidgen 2>/dev/null || echo "$(date +%s)-$(hostname)")",
        "Version": "2.0"
    }
]
EOF
)
    fi
    
    # Validate JSON
    if ! echo "$custom_data" | jq . >/dev/null 2>&1; then
        print_status "ERROR" "Invalid JSON data provided"
        exit 1
    fi
    
    # Send data with MSI authentication
    if send_data_with_msi_token "$workspace_id" "$log_type" "$custom_data" "$resource" "$managed_identity"; then
        echo ""
        print_status "SUCCESS" "MSI authentication test completed successfully!"
        print_status "INFO" "This confirms that:"
        print_status "INFO" "  ✓ IMDS/HIMDS endpoint is accessible"
        print_status "INFO" "  ✓ Managed identity is properly configured"
        print_status "INFO" "  ✓ MSI token acquisition works"
        print_status "INFO" "  ✓ Log Analytics ingestion with token auth succeeds"
    else
        echo ""
        print_status "ERROR" "MSI authentication test failed."
        print_status "INFO" "Common issues:"
        print_status "INFO" "  - Managed identity not enabled on VM/Arc server"
        print_status "INFO" "  - Missing 'Log Analytics Contributor' role assignment"
        print_status "INFO" "  - IMDS endpoint blocked by firewall"
        print_status "INFO" "  - Incorrect managed identity configuration"
        exit 1
    fi
}

main "$@"