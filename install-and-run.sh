#!/bin/bash

# Azure Monitor Agent Connectivity Tests - GitHub Installer/Runner
# This script downloads and runs AMA connectivity tests directly from GitHub
# Usage: curl -sSL https://raw.githubusercontent.com/YOUR-USERNAME/YOUR-REPO/main/install-and-run.sh | bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration - Update these URLs to point to your GitHub repository
GITHUB_BASE_URL="https://raw.githubusercontent.com/didiergbenou-ms/ama-connectivity-test/main"
TEMP_DIR="/tmp/ama-connectivity-tests"

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

# Function to download a file from GitHub
download_file() {
    local filename=$1
    local url="${GITHUB_BASE_URL}/${filename}"
    
    print_status "INFO" "Downloading $filename..."
    if curl -sSL "$url" -o "${TEMP_DIR}/$filename"; then
        chmod +x "${TEMP_DIR}/$filename"
        return 0
    else
        print_status "ERROR" "Failed to download $filename from $url"
        return 1
    fi
}

# Function to check prerequisites
check_prerequisites() {
    local missing=()
    
    if ! command -v curl >/dev/null 2>&1; then
        missing+=("curl")
    fi
    
    if ! command -v jq >/dev/null 2>&1; then
        missing+=("jq")
    fi
    
    if [ ${#missing[@]} -ne 0 ]; then
        print_status "ERROR" "Missing required commands: ${missing[*]}"
        print_status "INFO" "Install with:"
        print_status "INFO" "  Ubuntu/Debian: sudo apt update && sudo apt install ${missing[*]} dnsutils"
        print_status "INFO" "  RHEL/CentOS: sudo yum install ${missing[*]} bind-utils"
        print_status "INFO" "  SLES: sudo zypper install ${missing[*]} bind-utils"
        return 1
    fi
    return 0
}

# Function to show menu
show_menu() {
    echo ""
    echo "Azure Monitor Agent Connectivity Tests"
    echo "======================================"
    echo ""
    echo "1) Quick Connectivity Test (fast, basic checks)"
    echo "2) Comprehensive Connectivity Test (detailed analysis)"
    echo "3) Real AMA Authentication Test (uses Managed Identity like actual agent)"
    echo "4) Download all scripts for local use"
    echo "5) Exit"
    echo ""
}

# Function to run quick test
run_quick_test() {
    print_status "INFO" "Running Quick Connectivity Test..."
    if download_file "quick-connectivity-test.sh"; then
        "${TEMP_DIR}/quick-connectivity-test.sh"
    fi
}

# Function to run comprehensive test
run_comprehensive_test() {
    print_status "INFO" "Running Comprehensive Connectivity Test..."
    if download_file "test-ama-connectivity.sh"; then
        sudo "${TEMP_DIR}/test-ama-connectivity.sh"
    fi
}

# Function to run real AMA authentication test
run_real_ama_auth_test() {
    print_status "INFO" "Running Real AMA Authentication Test..."
    print_status "INFO" "This test uses Managed Identity authentication exactly like the actual Azure Monitor Agent"
    if download_file "test-data-sender-msi.sh"; then
        "${TEMP_DIR}/test-data-sender-msi.sh"
    fi
}

# Function to download all scripts
download_all_scripts() {
    print_status "INFO" "Downloading all scripts for local use..."
    
    local scripts=(
        "test-ama-connectivity.sh"
        "quick-connectivity-test.sh" 
        "test-data-sender-msi.sh"
        "AMA-CONNECTIVITY-TEST.md"
        "CONNECTIVITY-TESTING-README.md"
    )
    
    local download_dir="./ama-connectivity-tests"
    mkdir -p "$download_dir"
    
    for script in "${scripts[@]}"; do
        if curl -sSL "${GITHUB_BASE_URL}/$script" -o "${download_dir}/$script"; then
            chmod +x "${download_dir}/$script" 2>/dev/null || true
            print_status "SUCCESS" "Downloaded $script"
        else
            print_status "WARNING" "Failed to download $script"
        fi
    done
    
    print_status "SUCCESS" "Scripts downloaded to: $download_dir"
    print_status "INFO" "Usage: cd $download_dir && ./quick-connectivity-test.sh"
}

# Function to cleanup
cleanup() {
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}

# Main function
main() {
    # Setup cleanup on exit
    trap cleanup EXIT
    
    print_status "INFO" "Azure Monitor Agent Connectivity Tests - GitHub Runner"
    print_status "INFO" "This script downloads and runs connectivity tests from GitHub"
    
    # Check prerequisites
    if ! check_prerequisites; then
        exit 1
    fi
    
    # Create temp directory
    mkdir -p "$TEMP_DIR"
    
    # Handle command line arguments
    case "${1:-}" in
        "quick"|"--quick"|"-q")
            run_quick_test
            exit 0
            ;;
        "comprehensive"|"--comprehensive"|"-c") 
            run_comprehensive_test
            exit 0
            ;;
        "auth"|"--auth"|"-a"|"msi"|"--msi"|"-m")
            run_real_ama_auth_test
            exit 0
            ;;
        "download"|"--download")
            download_all_scripts
            exit 0
            ;;
        "help"|"--help"|"-h")
            echo "Usage: $0 [quick|comprehensive|auth|download]"
            echo ""
            echo "Options:"
            echo "  quick          Run quick connectivity test"
            echo "  comprehensive  Run comprehensive connectivity test (requires sudo)"
            echo "  auth|msi       Run real AMA authentication test (uses Managed Identity)" 
            echo "  download       Download all scripts for local use"
            echo "  (no option)    Show interactive menu"
            exit 0
            ;;
    esac
    
    # Interactive mode
    while true; do
        show_menu
        read -p "Select an option (1-5): " choice < /dev/tty
        
        case $choice in
            1)
                run_quick_test
                ;;
            2)
                run_comprehensive_test
                ;;
            3)
                run_real_ama_auth_test
                ;;
            4)
                download_all_scripts
                ;;
            5)
                print_status "INFO" "Goodbye!"
                exit 0
                ;;
            *)
                print_status "ERROR" "Invalid option. Please select 1-5."
                ;;
        esac
        
        echo ""
        read -p "Press Enter to continue..." < /dev/tty
    done
}

main "$@"