# Azure Monitor Agent Connectivity Test Script

## Overview

This script (`test-ama-connectivity.sh`) is designed to help troubleshoot Azure Monitor Agent (AMA) connectivity issues on Linux systems. It analyzes the agent's Data Collection Rule (DCR) configurations and tests connectivity to all Log Analytics workspaces and Azure Monitor endpoints that the agent needs to communicate with.

## What the Script Does

The script performs the following comprehensive tests:

1. **DCR Configuration Analysis**: 
   - Parses all DCR files in `/etc/opt/microsoft/azuremonitoragent/config-cache/configchunks/`
   - Extracts Log Analytics workspace IDs, regions, and endpoint configurations
   - Identifies agent settings including proxy configuration

2. **Connectivity Tests**:
   - **DNS Resolution**: Verifies that all endpoints can be resolved
   - **SSL Handshake**: Tests SSL/TLS connectivity to all endpoints
   - **Handler Endpoints**: Tests Azure Monitor handler endpoints with HTTP ping
   - **Log Analytics Ingestion**: Simulates data ingestion to Log Analytics workspaces
   - **Metrics Endpoints**: Tests connectivity to Azure Monitor metrics endpoints

3. **Cloud Environment Detection**:
   - Automatically detects Azure Commercial (.com), Government (.us), or China (.cn) clouds
   - Adjusts endpoint URLs accordingly

4. **Proxy Support**:
   - Detects and uses proxy configuration from environment variables or agent settings
   - Supports both authenticated and unauthenticated proxies

## Prerequisites

The script requires the following commands to be available:
- `curl` - for HTTP/HTTPS testing
- `openssl` - for SSL connectivity testing
- `jq` - for JSON parsing
- `nslookup` - for DNS resolution testing

### Installation Commands

**Ubuntu/Debian:**
```bash
sudo apt update && sudo apt install curl openssl jq dnsutils
```

**RHEL/CentOS/Fedora:**
```bash
sudo yum install curl openssl jq bind-utils
# or for newer versions:
sudo dnf install curl openssl jq bind-utils
```

**SLES:**
```bash
sudo zypper install curl openssl jq bind-utils
```

## Usage

### Basic Usage
```bash
# Make the script executable
chmod +x test-ama-connectivity.sh

# Run the connectivity test
sudo ./test-ama-connectivity.sh
```

### Sample Output
```
[INFO] Azure Monitor Agent Connectivity Test Script
[INFO] This script tests connectivity to all Log Analytics workspaces configured for AMA

[INFO] Checking prerequisites...
[SUCCESS] All prerequisites met
[INFO] Parsing DCR configuration files from /etc/opt/microsoft/azuremonitoragent/config-cache/configchunks...
[INFO] Processing config file: dcr-12345678-abcd-1234-efgh-123456789012.json
[INFO] Found Log Analytics workspace: a1b2c3d4-e5f6-7890-abcd-ef1234567890
[INFO] Found region: eastus
[SUCCESS] Parsed 3 DCR configuration files
[INFO] Found 1 workspace(s), 2 region(s), 1 metrics region(s)

[INFO] Starting connectivity tests...
[INFO] Testing Global Handler endpoint: global.handler.control.monitor.azure.com
[INFO] Testing DNS resolution for global.handler.control.monitor.azure.com
[SUCCESS] DNS resolution successful for global.handler.control.monitor.azure.com
[INFO] Testing SSL connection to global.handler.control.monitor.azure.com:443
[SUCCESS] SSL connection and verification successful for global.handler.control.monitor.azure.com
[INFO] Testing HTTP ping: https://global.handler.control.monitor.azure.com/ping
[SUCCESS] HTTP ping successful for global.handler.control.monitor.azure.com (Response: Healthy)

[INFO] Testing Log Analytics workspace: a1b2c3d4-e5f6-7890-abcd-ef1234567890
[INFO] Simulating data ingestion to: a1b2c3d4-e5f6-7890-abcd-ef1234567890.ods.opinsights.azure.com
[SUCCESS] Log Analytics endpoint is reachable (HTTP 401 - authentication required as expected)

[INFO] === CONNECTIVITY TEST REPORT ===

[INFO] Configuration Summary:
  - Log Analytics Workspaces: 1 (a1b2c3d4-e5f6-7890-abcd-ef1234567890)
  - Regions: 2 (eastus westus2)
  - Metrics Regions: 1 (eastus)
  - Cloud Environment: Azure.com
  - Proxy: None

[INFO] Test Results:
  - Total Tests: 5
  - Passed: 5
  - Failed: 0

[SUCCESS] All connectivity tests passed! Azure Monitor Agent should be able to send data successfully.
```

## Understanding Test Results

### Success Scenarios
- **DNS Resolution**: All endpoints resolve successfully
- **SSL Connection**: SSL handshakes complete without errors
- **Handler Endpoints**: Return "Healthy" response to ping
- **Log Analytics**: Return HTTP 401/403 (authentication required) - this is expected and indicates reachability
- **Metrics Endpoints**: Successfully connect

### Common Failure Scenarios and Solutions

#### DNS Resolution Failures
```
[ERROR] DNS resolution failed for eastus.handler.control.monitor.azure.com
```
**Solutions:**
- Check DNS server configuration
- Verify internet connectivity
- Check if custom DNS is blocking Azure endpoints

#### SSL Connection Failures
```
[ERROR] SSL connection failed for global.handler.control.monitor.azure.com
```
**Solutions:**
- Check firewall rules (port 443 outbound)
- Verify TLS/SSL isn't being blocked by security appliances
- Check if corporate proxy is interfering with SSL

#### HTTP Ping Failures
```
[ERROR] HTTP ping failed for global.handler.control.monitor.azure.com: Connection timeout
```
**Solutions:**
- Check network security groups (NSGs) in Azure
- Verify outbound internet access on port 443
- Check proxy configuration

#### Proxy-Related Issues
```
[ERROR] HTTP ping failed for eastus.handler.control.monitor.azure.com: Proxy authentication required
```
**Solutions:**
- Configure proxy credentials in agent settings
- Check proxy server connectivity
- Verify proxy allows Azure Monitor endpoints

## Endpoints Tested

The script tests connectivity to these endpoint types:

### Handler Endpoints
- Global: `global.handler.control.monitor.azure.com`
- Regional: `{region}.handler.control.monitor.azure.com`

### Log Analytics Endpoints  
- Workspace ingestion: `{workspace-id}.ods.opinsights.azure.com`

### Metrics Endpoints
- Management: `management.azure.com`
- Regional metrics: `{region}.monitoring.azure.com`

### Cloud-Specific Variants
- **Azure Government**: `.us` suffix
- **Azure China**: `.cn` suffix

## Integration with Azure Monitor Agent

This script mimics the same connectivity tests that the Azure Monitor Agent performs internally. It uses the same:

1. **Configuration Sources**: Reads DCR files from the same locations
2. **Endpoint Construction**: Uses the same URL patterns and formats
3. **Test Methods**: Uses similar SSL, DNS, and HTTP testing approaches
4. **Proxy Handling**: Follows the same proxy detection and usage logic

## Troubleshooting Tips

### If All Tests Pass But Agent Still Fails
1. **Check Agent Service Status**:
   ```bash
   sudo systemctl status azuremonitoragent
   sudo journalctl -u azuremonitoragent -f
   ```

2. **Verify DCR Associations**:
   - Check in Azure portal that DCRs are properly associated with the VM
   - Ensure the agent has retrieved the latest configuration

3. **Check Agent Logs**:
   ```bash
   sudo tail -f /var/opt/microsoft/azuremonitoragent/log/mdsd.log
   sudo tail -f /var/log/azure/Microsoft.Azure.Monitor.AzureMonitorLinuxAgent/extension.log
   ```

### If Tests Fail
1. **Network Issues**:
   - Check firewall rules (both local and Azure NSGs)
   - Verify DNS configuration
   - Test basic internet connectivity

2. **Proxy Issues**:
   - Verify proxy server is accessible
   - Check proxy credentials
   - Ensure proxy allows Azure endpoints

3. **Certificate Issues**:
   - Update system certificates
   - Check if corporate firewalls are doing SSL inspection

## Script Maintenance

This script is based on analysis of the Azure Monitor Agent source code (version as of January 2026). As the agent evolves, the endpoints or configuration formats may change. Key areas to monitor:

- **Configuration File Locations**: Currently `/etc/opt/microsoft/azuremonitoragent/config-cache/configchunks/`
- **Endpoint URLs**: Handler, Log Analytics, and metrics endpoints
- **DCR JSON Structure**: The format of channels and settings within DCR files

## Security Considerations

- The script does not transmit any actual log data or sensitive information
- It only performs connectivity tests similar to what the agent does
- Proxy credentials are handled securely and not logged
- The script should be run with appropriate privileges to read agent configuration files

## Contributing

To improve this script:
1. Monitor Azure Monitor Agent updates for configuration changes
2. Test against different cloud environments (Gov, China)
3. Add support for new endpoint types as they are introduced
4. Enhance error reporting and troubleshooting guidance