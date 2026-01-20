#!/bin/bash

# Azure Monitor Agent - Test Data Sender
# This script sends test data to Log Analytics workspaces to verify end-to-end functionality
# Note: Requires workspace ID and key for authentication

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

usage() {
    echo "Usage: $0 -w WORKSPACE_ID -k WORKSPACE_KEY [-t LOG_TYPE] [-d DATA]"
    echo ""
    echo "Options:"
    echo "  -w WORKSPACE_ID    Log Analytics Workspace ID"
    echo "  -k WORKSPACE_KEY   Log Analytics Workspace Primary Key"  
    echo "  -t LOG_TYPE        Custom log type name (default: AMAConnectivityTest_CL)"
    echo "  -d DATA            Custom JSON data (default: test message)"
    echo "  -h                 Show this help message"
    echo ""
    echo "Example:"
    echo "  $0 -w a1b2c3d4-e5f6-7890-abcd-ef1234567890 -k 'your-workspace-key-here'"
    echo ""
    echo "Note: You can find your workspace ID and key in the Azure portal:"
    echo "  Log Analytics workspace > Settings > Agents management"
}

# Function to generate HMAC-SHA256 signature for Log Analytics authentication
generate_signature() {
    local workspace_id=$1
    local workspace_key=$2
    local date_string=$3
    local content_length=$4
    local method="POST"
    local content_type="application/json"
    local resource="/api/logs"
    
    local string_to_sign="$method\n$content_length\n$content_type\nx-ms-date:$date_string\n$resource"
    
    # Generate signature
    echo -n "$string_to_sign" | openssl dgst -sha256 -hmac "$(echo "$workspace_key" | base64 -d)" -binary | base64
}

# Function to send test data to Log Analytics
send_test_data() {
    local workspace_id=$1
    local workspace_key=$2
    local log_type=$3
    local test_data=$4
    
    local date_string=$(date -u +"%a, %d %b %Y %H:%M:%S GMT")
    local content_length=${#test_data}
    local signature=$(generate_signature "$workspace_id" "$workspace_key" "$date_string" "$content_length")
    local authorization="SharedKey $workspace_id:$signature"
    
    local url="https://$workspace_id.ods.opinsights.azure.com/api/logs?api-version=2016-04-01"
    
    print_status "INFO" "Sending test data to Log Analytics workspace: $workspace_id"
    print_status "INFO" "Log type: $log_type"
    print_status "INFO" "Data size: $content_length bytes"
    
    local response
    local http_code
    
    if response=$(curl -s -w "%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        -H "Authorization: $authorization" \
        -H "Log-Type: $log_type" \
        -H "x-ms-date: $date_string" \
        -H "time-generated-field: TimeGenerated" \
        -d "$test_data" \
        "$url" 2>&1); then
        
        http_code=$(echo "$response" | tail -c 4)
        response_body=$(echo "$response" | head -c -4)
        
        case "$http_code" in
            "200")
                print_status "SUCCESS" "Test data sent successfully (HTTP 200)"
                print_status "INFO" "Data should appear in Log Analytics within 5-10 minutes"
                print_status "INFO" "Query: $log_type | where TimeGenerated > ago(1h)"
                return 0
                ;;
            "202")
                print_status "SUCCESS" "Test data accepted for processing (HTTP 202)"
                print_status "INFO" "Data should appear in Log Analytics within 5-10 minutes" 
                print_status "INFO" "Query: $log_type | where TimeGenerated > ago(1h)"
                return 0
                ;;
            "400")
                print_status "ERROR" "Bad request (HTTP 400): $response_body"
                return 1
                ;;
            "401")
                print_status "ERROR" "Authentication failed (HTTP 401): Check workspace ID and key"
                return 1
                ;;
            "403")
                print_status "ERROR" "Forbidden (HTTP 403): Check permissions"
                return 1
                ;;
            "413")
                print_status "ERROR" "Payload too large (HTTP 413): Reduce data size"
                return 1
                ;;
            "429")
                print_status "ERROR" "Too many requests (HTTP 429): Rate limited"
                return 1
                ;;
            "500")
                print_status "ERROR" "Internal server error (HTTP 500): $response_body"
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

# Function to get workspaces from DCR config (for reference)
list_configured_workspaces() {
    if [ ! -d "$CONFIG_DIR" ]; then
        print_status "WARNING" "DCR config directory not found: $CONFIG_DIR"
        return
    fi
    
    print_status "INFO" "Configured Log Analytics workspaces found in DCR:"
    
    local workspaces
    workspaces=$(find "$CONFIG_DIR" -type f -name "*.json" -exec jq -r '.channels[]?.endpoint // empty' {} \; 2>/dev/null | \
                grep "ods.opinsights.azure" | \
                sed 's|.*https://\([^.]*\)\.ods.*|\1|' | \
                sort -u)
    
    if [ -z "$workspaces" ]; then
        print_status "WARNING" "No workspaces found in DCR configuration"
    else
        echo "$workspaces" | while read -r workspace; do
            echo "  - $workspace"
        done
    fi
}

main() {
    local workspace_id=""
    local workspace_key=""
    local log_type="AMAConnectivityTest_CL"
    local custom_data=""
    
    # Parse command line arguments
    while getopts "w:k:t:d:h" opt; do
        case $opt in
            w) workspace_id="$OPTARG" ;;
            k) workspace_key="$OPTARG" ;;
            t) log_type="$OPTARG" ;;
            d) custom_data="$OPTARG" ;;
            h) usage; exit 0 ;;
            \?) echo "Invalid option -$OPTARG" >&2; usage; exit 1 ;;
        esac
    done
    
    # Check prerequisites
    if ! command -v curl >/dev/null 2>&1; then
        print_status "ERROR" "curl is required but not installed"
        exit 1
    fi
    
    if ! command -v openssl >/dev/null 2>&1; then
        print_status "ERROR" "openssl is required but not installed"
        exit 1
    fi
    
    if ! command -v base64 >/dev/null 2>&1; then
        print_status "ERROR" "base64 is required but not installed"
        exit 1
    fi
    
    # Show configured workspaces if available
    list_configured_workspaces
    echo ""
    
    # Validate required parameters
    if [ -z "$workspace_id" ] || [ -z "$workspace_key" ]; then
        print_status "ERROR" "Workspace ID and key are required"
        echo ""
        usage
        exit 1
    fi
    
    # Validate workspace ID format (should be a GUID)
    if ! echo "$workspace_id" | grep -qE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'; then
        print_status "ERROR" "Invalid workspace ID format. Expected GUID format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
        exit 1
    fi
    
    # Prepare test data
    if [ -z "$custom_data" ]; then
        custom_data=$(cat <<EOF
[
    {
        "TimeGenerated": "$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")",
        "Computer": "$(hostname)",
        "TestMessage": "Azure Monitor Agent connectivity test",
        "Source": "AMA-ConnectivityTestScript",
        "Severity": "Informational",
        "TestId": "$(uuidgen 2>/dev/null || echo "$(date +%s)-$(hostname)")",
        "Version": "1.0"
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
    
    print_status "INFO" "Azure Monitor Agent - Test Data Sender"
    print_status "INFO" "This will send test data to verify end-to-end log ingestion"
    echo ""
    
    # Send the test data
    if send_test_data "$workspace_id" "$workspace_key" "$log_type" "$custom_data"; then
        echo ""
        print_status "SUCCESS" "Test completed successfully!"
        print_status "INFO" "To verify data ingestion:"
        print_status "INFO" "1. Wait 5-10 minutes for data to appear"
        print_status "INFO" "2. Go to Log Analytics workspace in Azure portal"
        print_status "INFO" "3. Run query: $log_type | where TimeGenerated > ago(1h)"
    else
        echo ""
        print_status "ERROR" "Test failed. Check error messages above."
        exit 1
    fi
}

main "$@"