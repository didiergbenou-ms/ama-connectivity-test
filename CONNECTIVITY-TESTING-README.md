# Azure Monitor Agent - Connectivity Testing Scripts

This directory contains comprehensive testing scripts to troubleshoot Azure Monitor Agent (AMA) connectivity issues on Linux systems.

## Quick Start

### Run Directly from GitHub (Recommended)

```bash
# Interactive menu - choose your test
curl -sSL https://raw.githubusercontent.com/didiergbenou-ms/ama-connectivity-test/main/install-and-run.sh | bash

# Quick connectivity test
curl -sSL https://raw.githubusercontent.com/didiergbenou-ms/ama-connectivity-test/main/install-and-run.sh | bash -s quick

# Comprehensive test (requires sudo)
curl -sSL https://raw.githubusercontent.com/didiergbenou-ms/ama-connectivity-test/main/install-and-run.sh | bash -s comprehensive

# MSI authentication test (replicates real AMA behavior)
curl -sSL https://raw.githubusercontent.com/didiergbenou-ms/ama-connectivity-test/main/install-and-run.sh | bash -s msi

# Download all scripts for local use
curl -sSL https://raw.githubusercontent.com/didiergbenou-ms/ama-connectivity-test/main/install-and-run.sh | bash -s download
```

### Run Locally (if you've downloaded the scripts)

```bash
# Quick test - basic connectivity check
./quick-connectivity-test.sh

# Comprehensive test - detailed analysis and reporting  
./test-ama-connectivity.sh

# End-to-end test - send actual test data (requires workspace credentials)
./test-data-sender.sh -w YOUR_WORKSPACE_ID -k YOUR_WORKSPACE_KEY

# MSI authentication test (uses Managed Identity like real AMA)
./test-data-sender-msi.sh
```

## Scripts Overview

### 1. `test-ama-connectivity.sh` - Comprehensive Connectivity Test
**Purpose**: Complete analysis and testing of all AMA endpoints
**Features**:
- Parses DCR configurations from `/etc/opt/microsoft/azuremonitoragent/config-cache/configchunks/`
- Tests DNS resolution, SSL handshake, and HTTP connectivity
- Supports proxy detection and configuration
- Detects Azure cloud environments (Commercial, Government, China)
- Provides detailed troubleshooting reports

**Usage**:
```bash
sudo ./test-ama-connectivity.sh
```

### 2. `quick-connectivity-test.sh` - Fast Basic Test
**Purpose**: Quick verification of endpoint reachability
**Features**:
- Rapid testing of all configured endpoints
- Simple pass/fail output
- Minimal dependencies
- Good for quick health checks

**Usage**:
```bash
./quick-connectivity-test.sh
```

### 3. `test-data-sender.sh` - End-to-End Data Ingestion Test
**Purpose**: Verify complete log ingestion pipeline
**Features**:
- Sends actual test data to Log Analytics
- Verifies authentication and data format
- Tests complete ingestion workflow
- Requires workspace credentials

**Usage**:
```bash
# Send test data
./test-data-sender.sh -w a1b2c3d4-e5f6-7890-abcd-ef1234567890 -k "your-workspace-key"

# Send custom data
./test-data-sender.sh -w WORKSPACE_ID -k WORKSPACE_KEY -t MyCustomLog_CL -d '[{"Message":"Test"}]'
```

## Verifying Test Data in Log Analytics

After running `test-data-sender.sh`, look for your test messages in Log Analytics:

### Log Table and Fields
- **Default Table**: `AMAConnectivityTest_CL`
- **Key Fields**: 
  - `TestMessage`: "Azure Monitor Agent connectivity test"
  - `Source`: "AMA-ConnectivityTestScript" 
  - `Computer`: Your hostname
  - `TestId`: Unique identifier for each test

### KQL Queries to Find Test Data

**Basic search for test messages:**
```kusto
AMAConnectivityTest_CL
| where TimeGenerated > ago(1h)
| project TimeGenerated, Computer, TestMessage, Source, TestId
```

**Search across all tables for test data:**
```kusto
search "AMA-ConnectivityTestScript"
| where TimeGenerated > ago(6h)
```

**Find messages from specific computer:**
```kusto
AMAConnectivityTest_CL
| where Computer == "your-hostname"
| where TimeGenerated > ago(2h)
```

### Expected Timeline
- **Data appears**: 5-10 minutes after sending (can take up to 15 minutes initially)
- **Search window**: Look within last 1-2 hours after test
- **Retention**: Standard Log Analytics retention (30-90 days default)

## Prerequisites

Install required tools:

**Ubuntu/Debian**:
```bash
sudo apt update && sudo apt install curl openssl jq dnsutils
```

**RHEL/CentOS/Fedora**:
```bash
sudo yum install curl openssl jq bind-utils
```

**SLES**:
```bash
sudo zypper install curl openssl jq bind-utils
```

## Understanding Results

### Successful Tests
- **DNS Resolution**: ✓ All endpoints resolve correctly
- **SSL Connection**: ✓ TLS handshakes complete successfully  
- **Handler Ping**: ✓ Azure Monitor handlers respond "Healthy"
- **Log Analytics**: ✓ Endpoints are reachable (HTTP 401/403 expected without auth)

### Common Issues

| Problem | Cause | Solution |
|---------|--------|----------|
| DNS Resolution Failed | DNS server issues | Check DNS configuration, verify internet connectivity |
| SSL Connection Failed | Firewall blocking port 443 | Check firewall rules, NSGs, and security appliances |
| Handler Ping Failed | Network connectivity | Verify outbound HTTPS access, check proxy settings |
| Log Analytics Unreachable | Blocked endpoints | Check NSGs, firewall rules for `*.ods.opinsights.azure.*` |

## Endpoints Tested

### Handler Endpoints
- `global.handler.control.monitor.azure.com` - Global control plane
- `{region}.handler.control.monitor.azure.com` - Regional handlers

### Log Analytics Endpoints
- `{workspace-id}.ods.opinsights.azure.com` - Data ingestion endpoints

### Metrics Endpoints  
- `management.azure.com` - Azure Resource Manager
- `{region}.monitoring.azure.com` - Regional metrics collection

### Cloud Variants
- **Azure Government**: `.us` suffix
- **Azure China**: `.cn` suffix

## Troubleshooting Workflow

1. **Run Quick Test First**:
   ```bash
   ./quick-connectivity-test.sh
   ```

2. **If Issues Found, Run Comprehensive Test**:
   ```bash
   sudo ./test-ama-connectivity.sh
   ```

3. **If Connectivity OK, Test End-to-End**:
   ```bash
   ./test-data-sender.sh -w YOUR_WORKSPACE_ID -k YOUR_WORKSPACE_KEY
   ```

4. **Check Agent Status**:
   ```bash
   sudo systemctl status azuremonitoragent
   sudo journalctl -u azuremonitoragent -f
   ```

## Integration with Azure Monitor Agent

These scripts are based on deep analysis of the AMA source code and replicate the same connectivity tests the agent performs:

- **Configuration Parsing**: Uses same DCR file locations and JSON structure
- **Endpoint Construction**: Follows same URL patterns and cloud detection logic  
- **Test Methods**: Mirrors agent's DNS, SSL, and HTTP testing approaches
- **Proxy Handling**: Implements same proxy detection and authentication logic

## Files

- `test-ama-connectivity.sh` - Main comprehensive connectivity test script
- `quick-connectivity-test.sh` - Fast basic connectivity test  
- `test-data-sender.sh` - End-to-end data ingestion test
- `AMA-CONNECTIVITY-TEST.md` - Detailed documentation and troubleshooting guide

## Source Code Analysis

This implementation is based on analysis of the Azure Monitor Agent Linux extension source code, specifically:

- **Configuration Handling**: `agent.py` and DCR processing logic
- **Endpoint Detection**: `ama_tst/modules/helpers.py` - DCR workspace parsing
- **Connectivity Testing**: `ama_tst/modules/connect/check_endpts.py` - endpoint testing logic
- **Agent Communication**: Handler endpoints, Log Analytics ingestion patterns

The scripts replicate the agent's behavior to provide accurate troubleshooting capabilities that mirror the actual data flow the agent uses.